// AER managed shadow host. FreeRDP supplies RDP/TLS/codecs; this subsystem
// supplies bounded primary-monitor DXGI frames and permission-gated SendInput.
// No service, driver, RDS API, desktop switching, elevation or OS logon.
#include <winsock2.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#undef NIIF_NONE
#undef NIIF_INFO
#undef NIIF_WARNING
#undef NIIF_ERROR
#undef NIIF_NOSOUND
#undef NIIF_LARGE_ICON
#include <freerdp/config.h>
#include <freerdp/server/shadow.h>
#include <freerdp/server/cliprdr.h>
#include <winpr/wlog.h>
#include <cjson/cJSON.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <mutex>
#include <vector>
#include <set>

using Microsoft::WRL::ComPtr;
static constexpr size_t MAX_CLIP = 1024 * 1024;
struct Host {
  bool synthetic = false, input = false, clipboard = false;
  UINT width = 640, height = 480;
  ULONGLONG deadline = 0;
  std::string user, password, stateDir;
  HANDLE stop = nullptr;
  std::atomic<bool> stopping{false};
  std::atomic<bool> authenticated{false};
  std::atomic<unsigned> tick{0};
  std::thread capture;
  std::mutex clipLock, inputLock;
  std::set<WORD> heldKeys;
  std::set<WORD> heldUnicode;
  DWORD heldMouse = 0;
  std::wstring clipText;
  DWORD clipSequence = 0;
  CliprdrServerContext* clip = nullptr;
  rdpShadowServer* server = nullptr;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutputDuplication> duplication;
  ComPtr<ID3D11Texture2D> staging;
} host;

static bool normalDesktop() {
  if (host.synthetic) return true;
  static const bool ordinaryUser = [] {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
    TOKEN_ELEVATION elevation{}; DWORD access = 0, returned = 0;
    const bool ok = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &returned) &&
      GetTokenInformation(token, TokenUIAccess, &access, sizeof(access), &returned) &&
      !elevation.TokenIsElevated && !access;
    CloseHandle(token); return ok;
  }();
  if (!ordinaryUser) return false;
  DWORD session = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0) return false;
  USEROBJECTFLAGS station{}; DWORD size = 0;
  if (!GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS, &station, sizeof(station), &size) ||
    !(station.dwFlags & WSF_VISIBLE)) return false;
  const auto desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return false;
  wchar_t name[128]{}; DWORD needed = 0;
  const bool ok = GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed) &&
                  _wcsicmp(name, L"Default") == 0;
  CloseDesktop(desktop);
  return ok;
}
static void releaseInput() {
  std::lock_guard<std::mutex> guard(host.inputLock);
  if (!host.synthetic && normalDesktop()) {
    for (const WORD code : host.heldKeys) {
      INPUT e{}; e.type = INPUT_KEYBOARD; e.ki.wScan = code & 0xff;
      e.ki.dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP | ((code & 0x100) ? KEYEVENTF_EXTENDEDKEY : 0);
      SendInput(1, &e, sizeof(e));
    }
    for (const WORD code : host.heldUnicode) {
      INPUT e{}; e.type = INPUT_KEYBOARD; e.ki.wScan = code; e.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      SendInput(1, &e, sizeof(e));
    }
    if (host.heldMouse) { INPUT e{}; e.type = INPUT_MOUSE; e.mi.dwFlags = host.heldMouse; SendInput(1, &e, sizeof(e)); }
  }
  host.heldKeys.clear(); host.heldUnicode.clear(); host.heldMouse = 0;
}
static void stopHost() {
  if (host.stopping.exchange(true)) return;
  // The agent can close relay/files immediately even if FreeRDP is still
  // joining an encoder/client thread. Contains no session data.
  puts("STOPPING"); fflush(stdout);
  if (host.stop) SetEvent(host.stop);
}
static bool allowedInput() {
  if (!host.input || host.stopping) return false;
  if (!normalDesktop()) { stopHost(); return false; }
  return true;
}

static bool initDXGI() {
  if (!normalDesktop()) return false;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    nullptr, 0, D3D11_SDK_VERSION, &host.device, nullptr, &host.context))) return false;
  ComPtr<IDXGIDevice> dxgi; ComPtr<IDXGIAdapter> adapter;
  if (FAILED(host.device.As(&dxgi)) || FAILED(dxgi->GetAdapter(&adapter))) return false;
  ComPtr<IDXGIOutput> output;
  for (UINT i = 0;; ++i) {
    ComPtr<IDXGIOutput> next;
    if (FAILED(adapter->EnumOutputs(i, &next))) break;
    DXGI_OUTPUT_DESC desc{};
    if (SUCCEEDED(next->GetDesc(&desc)) && desc.AttachedToDesktop &&
      desc.DesktopCoordinates.left == 0 && desc.DesktopCoordinates.top == 0) { output = next; break; }
  }
  if (!output) return false;
  ComPtr<IDXGIOutput1> output1;
  if (FAILED(output.As(&output1)) || FAILED(output1->DuplicateOutput(host.device.Get(), &host.duplication))) return false;
  DXGI_OUTDUPL_DESC desc{}; host.duplication->GetDesc(&desc);
  if (desc.Rotation != DXGI_MODE_ROTATION_IDENTITY || desc.ModeDesc.Width > 8192 || desc.ModeDesc.Height > 8192) return false;
  host.width = desc.ModeDesc.Width; host.height = desc.ModeDesc.Height;
  D3D11_TEXTURE2D_DESC tex{};
  tex.Width = host.width; tex.Height = host.height; tex.MipLevels = 1; tex.ArraySize = 1;
  tex.Format = DXGI_FORMAT_B8G8R8A8_UNORM; tex.SampleDesc.Count = 1;
  tex.Usage = D3D11_USAGE_STAGING; tex.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  return SUCCEEDED(host.device->CreateTexture2D(&tex, nullptr, &host.staging));
}

static UINT clipList(CliprdrServerContext* c, const CLIPRDR_FORMAT_LIST* list) {
  if (!host.clipboard || !normalDesktop() || host.stopping) return ERROR_ACCESS_DENIED;
  CLIPRDR_FORMAT_LIST_RESPONSE ack{}; ack.common.msgFlags = CB_RESPONSE_OK;
  if (c->ServerFormatListResponse(c, &ack) != CHANNEL_RC_OK) return ERROR_INTERNAL_ERROR;
  for (UINT32 i = 0; i < list->numFormats; ++i) {
    if (list->formats[i].formatId == CF_UNICODETEXT) {
      CLIPRDR_FORMAT_DATA_REQUEST req{}; req.requestedFormatId = CF_UNICODETEXT;
      return c->ServerFormatDataRequest(c, &req);
    }
  }
  return CHANNEL_RC_OK;
}
static UINT clipData(CliprdrServerContext*, const CLIPRDR_FORMAT_DATA_RESPONSE* data) {
  if (!host.clipboard || !normalDesktop() || host.stopping) return ERROR_ACCESS_DENIED;
  if (!(data->common.msgFlags & CB_RESPONSE_OK) || data->common.dataLen < 2 || data->common.dataLen > MAX_CLIP ||
    data->common.dataLen % 2 || !data->requestedFormatData) return ERROR_INVALID_DATA;
  std::vector<wchar_t> text(data->common.dataLen / 2);
  memcpy(text.data(), data->requestedFormatData, data->common.dataLen);
  if (text.back() != 0) return ERROR_INVALID_DATA;
  std::lock_guard<std::mutex> guard(host.clipLock);
  if (host.synthetic) { host.clipText = text.data(); ++host.tick; return CHANNEL_RC_OK; }
  if (!OpenClipboard(nullptr)) return CHANNEL_RC_OK;
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, data->common.dataLen);
  if (mem) {
    void* ptr = GlobalLock(mem);
    if (ptr) { memcpy(ptr, text.data(), data->common.dataLen); GlobalUnlock(mem);
      if (!EmptyClipboard() || !SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem);
    } else GlobalFree(mem);
  }
  host.clipSequence = GetClipboardSequenceNumber();
  CloseClipboard();
  return CHANNEL_RC_OK;
}
static UINT clipRequest(CliprdrServerContext* c, const CLIPRDR_FORMAT_DATA_REQUEST* request) {
  if (!host.clipboard || !normalDesktop() || host.stopping) return ERROR_ACCESS_DENIED;
  std::lock_guard<std::mutex> guard(host.clipLock);
  std::wstring text;
  if (request->requestedFormatId == CF_UNICODETEXT) {
    if (host.synthetic) text = host.clipText;
    else if (OpenClipboard(nullptr)) {
      HGLOBAL mem = GetClipboardData(CF_UNICODETEXT);
      const SIZE_T size = mem ? GlobalSize(mem) : 0;
      if (size >= 2 && size <= MAX_CLIP) {
        const auto ptr = static_cast<const wchar_t*>(GlobalLock(mem));
        if (ptr) { text.assign(ptr, wcsnlen(ptr, size / 2)); GlobalUnlock(mem); }
      }
      CloseClipboard();
    }
  }
  CLIPRDR_FORMAT_DATA_RESPONSE response{};
  response.common.msgFlags = request->requestedFormatId == CF_UNICODETEXT ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
  response.common.dataLen = static_cast<UINT32>((text.size() + 1) * sizeof(wchar_t));
  response.requestedFormatData = reinterpret_cast<const BYTE*>(text.c_str());
  return c->ServerFormatDataResponse(c, &response);
}
static void offerClipboard() {
  std::lock_guard<std::mutex> guard(host.clipLock);
  if (!host.clip || !host.clipboard || host.stopping || !normalDesktop()) return;
  const DWORD seq = host.synthetic ? host.tick.load() : GetClipboardSequenceNumber();
  if (seq == host.clipSequence) return;
  host.clipSequence = seq;
  CLIPRDR_FORMAT format{}; format.formatId = CF_UNICODETEXT;
  CLIPRDR_FORMAT_LIST list{}; list.numFormats = 1; list.formats = &format;
  if (host.clip->ServerFormatList(host.clip, &list) != CHANNEL_RC_OK) stopHost();
}

static int authenticate(rdpShadowSubsystem*, rdpShadowClient*, const char* user,
  const char*, const char* password) {
  // Called only inside the pinned TLS connection, before any desktop frames.
  if (!user || !password || host.stopping) return -1;
  const size_t len = strlen(password);
  unsigned diff = static_cast<unsigned>(len ^ host.password.size());
  for (size_t i = 0; i < host.password.size(); ++i)
    diff |= static_cast<unsigned char>(host.password[i]) ^ (i < len ? static_cast<unsigned char>(password[i]) : 0);
  return diff == 0 && host.user == user ? 1 : -1;
}
static BOOL connected(rdpShadowSubsystem*, rdpShadowClient* client) {
  if (!normalDesktop() || host.stopping) return FALSE;
  client->mayView = TRUE; client->mayInteract = host.input; client->inLobby = FALSE;
  host.authenticated = true;
  if (host.clipboard && WTSVirtualChannelManagerIsChannelJoined(client->vcm, "cliprdr")) {
    const auto c = cliprdr_server_context_new(client->vcm);
    if (!c) return FALSE;
    c->rdpcontext = &client->context; c->autoInitializationSequence = TRUE;
    c->streamFileClipEnabled = FALSE; c->canLockClipData = FALSE;
    c->ClientFormatList = clipList; c->ClientFormatDataResponse = clipData; c->ClientFormatDataRequest = clipRequest;
    if (c->Start(c) != CHANNEL_RC_OK) { cliprdr_server_context_free(c); return FALSE; }
    std::lock_guard<std::mutex> guard(host.clipLock); host.clip = c; host.clipSequence = 0;
  }
  return TRUE;
}
static void disconnected(rdpShadowSubsystem*, rdpShadowClient*) {
  host.authenticated = false;
  releaseInput();
  CliprdrServerContext* c = nullptr;
  { std::lock_guard<std::mutex> guard(host.clipLock); c = host.clip; host.clip = nullptr; }
  if (c) { c->Stop(c); cliprdr_server_context_free(c); }
}
static BOOL keyboard(rdpShadowSubsystem*, rdpShadowClient*, UINT16 flags, UINT8 code) {
  if (!allowedInput()) return TRUE;
  if (host.synthetic) { ++host.tick; return TRUE; }
  INPUT e{}; e.type = INPUT_KEYBOARD; e.ki.wScan = code; e.ki.dwFlags = KEYEVENTF_SCANCODE;
  if (flags & KBD_FLAGS_EXTENDED) e.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
  if (flags & KBD_FLAGS_RELEASE) e.ki.dwFlags |= KEYEVENTF_KEYUP;
  std::lock_guard<std::mutex> guard(host.inputLock);
  if (SendInput(1, &e, sizeof(e)) != 1) return TRUE; // UIPI denied: never elevate/retry.
  const WORD key = static_cast<WORD>(code | ((flags & KBD_FLAGS_EXTENDED) ? 0x100 : 0));
  if (flags & KBD_FLAGS_RELEASE) host.heldKeys.erase(key); else host.heldKeys.insert(key);
  return TRUE;
}
static BOOL unicodeKey(rdpShadowSubsystem*, rdpShadowClient*, UINT16 flags, UINT16 code) {
  if (!allowedInput()) return TRUE;
  if (host.synthetic) { ++host.tick; return TRUE; }
  INPUT e{}; e.type = INPUT_KEYBOARD; e.ki.wScan = code;
  e.ki.dwFlags = KEYEVENTF_UNICODE | ((flags & KBD_FLAGS_RELEASE) ? KEYEVENTF_KEYUP : 0);
  std::lock_guard<std::mutex> guard(host.inputLock);
  if (SendInput(1, &e, sizeof(e)) == 1) {
    if (flags & KBD_FLAGS_RELEASE) host.heldUnicode.erase(code); else host.heldUnicode.insert(code);
  }
  return TRUE;
}
static BOOL mouse(rdpShadowSubsystem*, rdpShadowClient*, UINT16 flags, UINT16 x, UINT16 y) {
  if (!allowedInput()) return TRUE;
  if (host.synthetic) { ++host.tick; return TRUE; }
  INPUT e{}; e.type = INPUT_MOUSE;
  if (flags & (PTR_FLAGS_WHEEL | PTR_FLAGS_HWHEEL)) {
    e.mi.dwFlags = flags & PTR_FLAGS_WHEEL ? MOUSEEVENTF_WHEEL : MOUSEEVENTF_HWHEEL;
    e.mi.mouseData = static_cast<DWORD>(static_cast<INT16>((flags & 0x1ff) | ((flags & PTR_FLAGS_WHEEL_NEGATIVE) ? 0xfe00 : 0)));
  } else {
    e.mi.dx = static_cast<LONG>((static_cast<UINT64>(x) * 65535) / (host.width - 1));
    e.mi.dy = static_cast<LONG>((static_cast<UINT64>(y) * 65535) / (host.height - 1));
    e.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;
    if (flags & PTR_FLAGS_BUTTON1) e.mi.dwFlags |= flags & PTR_FLAGS_DOWN ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
    if (flags & PTR_FLAGS_BUTTON2) e.mi.dwFlags |= flags & PTR_FLAGS_DOWN ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
    if (flags & PTR_FLAGS_BUTTON3) e.mi.dwFlags |= flags & PTR_FLAGS_DOWN ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
  }
  std::lock_guard<std::mutex> guard(host.inputLock);
  if (SendInput(1, &e, sizeof(e)) == 1) {
    const DWORD release = ((flags & PTR_FLAGS_BUTTON1) ? MOUSEEVENTF_LEFTUP : 0) |
      ((flags & PTR_FLAGS_BUTTON2) ? MOUSEEVENTF_RIGHTUP : 0) | ((flags & PTR_FLAGS_BUTTON3) ? MOUSEEVENTF_MIDDLEUP : 0);
    if (flags & PTR_FLAGS_DOWN) host.heldMouse |= release; else host.heldMouse &= ~release;
  }
  return TRUE;
}

static void capture(rdpShadowSubsystem* sub) {
  auto surface = sub->server->surface;
  while (!host.stopping && WaitForSingleObject(host.stop, 50) == WAIT_TIMEOUT) {
    if (GetTickCount64() >= host.deadline) { stopHost(); break; }
    if (!normalDesktop()) { stopHost(); break; }
    if (!host.authenticated || ArrayList_Count(sub->server->clients) == 0) continue;
    if (host.synthetic) {
      const unsigned tick = host.tick.load();
      for (UINT y = 0; y < host.height; ++y) for (UINT x = 0; x < host.width; ++x) {
        BYTE* p = surface->data + y * surface->scanline + x * 4;
        p[0] = static_cast<BYTE>(x + tick); p[1] = static_cast<BYTE>(y + tick); p[2] = 0x90; p[3] = 0xff;
      }
    } else {
      DXGI_OUTDUPL_FRAME_INFO info{}; ComPtr<IDXGIResource> resource;
      const HRESULT hr = host.duplication->AcquireNextFrame(100, &info, &resource);
      if (hr == DXGI_ERROR_WAIT_TIMEOUT) { offerClipboard(); continue; }
      if (FAILED(hr)) { stopHost(); break; } // lost/locked/UAC: require a new local approval.
      ComPtr<ID3D11Texture2D> frame;
      bool ok = SUCCEEDED(resource.As(&frame));
      if (ok) {
        host.context->CopyResource(host.staging.Get(), frame.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        ok = SUCCEEDED(host.context->Map(host.staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
        if (ok) {
          for (UINT y = 0; y < host.height; ++y)
            memcpy(surface->data + y * surface->scanline, static_cast<BYTE*>(mapped.pData) + y * mapped.RowPitch, host.width * 4);
          host.context->Unmap(host.staging.Get(), 0);
        }
      }
      host.duplication->ReleaseFrame();
      if (!ok) { stopHost(); break; }
    }
    const RECTANGLE_16 rect{0, 0, static_cast<UINT16>(host.width), static_cast<UINT16>(host.height)};
    region16_union_rect(&surface->invalidRegion, &surface->invalidRegion, &rect);
    shadow_subsystem_frame_update(sub);
    region16_clear(&surface->invalidRegion);
    offerClipboard();
  }
}
static rdpShadowSubsystem* subsystemNew() {
  auto s = static_cast<rdpShadowSubsystem*>(calloc(1, sizeof(rdpShadowSubsystem)));
  if (s) { s->Authenticate = authenticate; s->ClientConnect = connected; s->ClientDisconnect = disconnected;
    s->KeyboardEvent = keyboard; s->UnicodeKeyboardEvent = unicodeKey; s->MouseEvent = mouse; }
  return s;
}
static int subsystemInit(rdpShadowSubsystem* s) {
  s->numMonitors = 1; s->captureFrameRate = 20; s->selectedMonitor = 0;
  s->monitors[0] = {0, 0, static_cast<INT32>(host.width - 1), static_cast<INT32>(host.height - 1), TRUE};
  s->virtualScreen = s->monitors[0]; return 1;
}
static int subsystemStart(rdpShadowSubsystem* s) { host.capture = std::thread(capture, s); return 1; }
static int subsystemStop(rdpShadowSubsystem*) { host.stopping = true; if (host.capture.joinable()) host.capture.join(); return 1; }
static int subsystemUninit(rdpShadowSubsystem*) { return 1; }
static UINT32 monitors(MONITOR_DEF* m, UINT32 count) {
  if (!count || !m) return 0;
  m[0] = {0, 0, static_cast<INT32>(host.width - 1), static_cast<INT32>(host.height - 1), TRUE}; return 1;
}
static int entry(RDP_SHADOW_ENTRY_POINTS* ep) {
  ep->New = subsystemNew; ep->Free = [](rdpShadowSubsystem* s) { free(s); };
  ep->Init = subsystemInit; ep->Uninit = subsystemUninit; ep->Start = subsystemStart; ep->Stop = subsystemStop; ep->EnumMonitors = monitors; return 1;
}
static LRESULT CALLBACK noticeProc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_CLOSE || (msg == WM_COMMAND && LOWORD(wp) == 1)) { stopHost(); return 0; }
  return DefWindowProcW(w, msg, wp, lp);
}

int wmain(int argc, wchar_t** argv) {
  if (argc == 2 && wcscmp(argv[1], L"--probe") == 0) return normalDesktop() ? 0 : 3;
  if (argc == 3 && wcscmp(argv[1], L"--consent") == 0) {
    if (!normalDesktop()) return 3;
    if (wcslen(argv[2]) == 0 || wcslen(argv[2]) > 4096) return 3;
    const int result = MessageBoxW(nullptr,
      argv[2],
      L"AER HOME - Remote access request", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2 | MB_SETFOREGROUND | MB_TOPMOST);
    return result == IDYES ? 0 : 4;
  }
  if (argc != 2 || wcscmp(argv[1], L"--config-stdin") != 0) return 2;
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  WLog_SetLogLevel(WLog_GetRoot(), WLOG_ERROR);
  char input[16384]{};
  if (!fgets(input, sizeof(input), stdin) || !strchr(input, '\n')) return 2;
  cJSON* config = cJSON_Parse(input);
  SecureZeroMemory(input, sizeof(input));
  if (!config) return 2;
  const auto str = [config](const char* key) -> const char* { const auto v = cJSON_GetObjectItemCaseSensitive(config, key); return cJSON_IsString(v) ? v->valuestring : ""; };
  host.user = str("user"); host.password = str("password"); host.stateDir = str("stateDir");
  host.synthetic = strcmp(str("mode"), "synthetic") == 0;
  if (!host.synthetic && strcmp(str("mode"), "desktop") != 0) { cJSON_Delete(config); return 2; }
  host.input = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(config, "input"));
  host.clipboard = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(config, "clipboard"));
  const auto p = cJSON_GetObjectItemCaseSensitive(config, "port");
  const int port = cJSON_IsNumber(p) ? p->valueint : 0;
  const auto ttl = cJSON_GetObjectItemCaseSensitive(config,"ttlMs");
  if (!cJSON_IsNumber(ttl) || ttl->valuedouble <= 0 || ttl->valuedouble > 86400000) { cJSON_Delete(config); return 2; }
  host.deadline = GetTickCount64() + static_cast<ULONGLONG>(ttl->valuedouble);
  if (port < 1 || port > 65535 || host.user.empty() || host.password.size() < 24 || host.stateDir.empty()) { cJSON_Delete(config); return 2; }
  // Only desktop mode touches DXGI/SendInput/Windows clipboard. Synthetic
  // exercises the same RDP authentication/codecs/channels, never the desktop.
  if (!host.synthetic && !initDXGI()) { cJSON_Delete(config); return 3; }
  shadow_subsystem_set_entry(entry);
  auto server = shadow_server_new(); if (!server) { cJSON_Delete(config); return 3; }
  host.server = server; server->port = static_cast<DWORD>(port);
  server->ConfigPath = _strdup(host.stateDir.c_str());
  server->ipcSocket = _strdup("bind-address,127.0.0.1"); // Never wildcard, no option to change it.
  server->authentication = TRUE; server->mayView = TRUE; server->mayInteract = host.input;
  server->maxClientsConnected = 1;
  auto settings = server->settings;
  const bool configured = freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE);
  const auto secret = cJSON_GetObjectItemCaseSensitive(config, "password");
  if (cJSON_IsString(secret)) SecureZeroMemory(secret->valuestring, strlen(secret->valuestring));
  cJSON_Delete(config);
  if (!configured || shadow_server_init(server) < 0) { shadow_server_free(server); return 3; }
  host.stop = server->StopEvent;
  HWND window = nullptr;
  if (!host.synthetic) {
    WNDCLASSW cls{}; cls.lpfnWndProc = noticeProc; cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"AerRemoteConsent"; cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassW(&cls);
    window = CreateWindowExW(WS_EX_TOPMOST, cls.lpszClassName, L"AER HOME - Remote access active",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE, 40, 40, 460, 160, nullptr, nullptr, cls.hInstance, nullptr);
    if (!window) { shadow_server_uninit(server); shadow_server_free(server); return 3; }
    CreateWindowW(L"STATIC", L"Remote desktop sharing is active.\nClose this window to stop access immediately.",
      WS_CHILD | WS_VISIBLE, 16, 14, 420, 45, window, nullptr, cls.hInstance, nullptr);
    if (!CreateWindowW(L"BUTTON", L"Stop remote access", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
      16, 68, 200, 30, window, reinterpret_cast<HMENU>(1), cls.hInstance, nullptr)) {
      DestroyWindow(window); shadow_server_uninit(server); shadow_server_free(server); return 3;
    }
    // The agent hides the console with STARTUPINFO/SW_HIDE. That startup
    // state also overrides the first top-level WS_VISIBLE/ShowWindow call.
    // Explicitly show the notice and fail closed before starting RDP if the
    // local Stop control is not actually visible and enabled.
    ShowWindow(window, SW_SHOW);
    const HWND stopButton = GetDlgItem(window, 1);
    if (!SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW) || !IsWindowVisible(window) ||
        !stopButton || !IsWindowVisible(stopButton) || !IsWindowEnabled(stopButton)) {
      DestroyWindow(window); shadow_server_uninit(server); shadow_server_free(server); return 3;
    }
    UpdateWindow(window);
  }
  if (shadow_server_start(server) < 0) { if (window) DestroyWindow(window); shadow_server_uninit(server); shadow_server_free(server); return 3; }
  // Only readiness and lifecycle are emitted. Credentials, clipboard and
  // input contents are never written to logs, argv, environment or a SAM file.
  puts("READY"); fflush(stdout);
  std::thread([] { char b[64]; while (fgets(b, sizeof(b), stdin)) {} stopHost(); }).detach();
  while (!host.stopping && WaitForSingleObject(host.stop, 50) == WAIT_TIMEOUT) {
    MSG msg{}; while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    if (GetTickCount64() >= host.deadline) stopHost();
    if (!normalDesktop()) stopHost();
    if (window && (!IsWindowVisible(window) || IsIconic(window))) stopHost();
  }
  stopHost();
  shadow_server_stop(server); shadow_server_uninit(server); shadow_server_free(server); host.stop = nullptr;
  if (window) DestroyWindow(window);
  host.staging.Reset(); host.duplication.Reset(); host.context.Reset(); host.device.Reset();
  SecureZeroMemory(host.password.data(), host.password.size());
  puts("CLOSED"); fflush(stdout);
  // The stdin watcher is blocked until the owning agent closes its pipe;
  // ExitProcess avoids running global destructors underneath that watcher.
  ExitProcess(0);
}
