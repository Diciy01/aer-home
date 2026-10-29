/* aer_rdp — see aer_rdp.h. Built against FreeRDP 3.x (tested with 3.32). */
#if !defined(_WIN32)
#define _GNU_SOURCE /* nftw */
#endif
#include "aer_rdp.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>
#include <winpr/interlocked.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/user.h>

#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/channels.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>

#if defined(_WIN32)
#include <winpr/crypto.h>
#include <winpr/path.h>
#else
#include <ftw.h>
#include <unistd.h>
#endif

#define AER_RDP_ABI 1
#define QUEUE_MAX 1024
#define CLIP_MAX_BYTES (1024U * 1024U)

typedef struct
{
	UINT8 kind; /* 1 mouse, 2 key, 3 unicode */
	UINT16 flags;
	UINT16 x, y;
	UINT32 code;
	BOOL down;
} AerInput;

struct AerRdp
{
	rdpContext* ctx;
	HANDLE thread;
	HANDLE stop;
	HANDLE wake;
	CRITICAL_SECTION lock;
	volatile LONG state;
	char error[256];
	char pin[65];
	char cfgdir[512];

	/* frame */
	BYTE* frame;
	size_t frame_cap;
	UINT32 fw, fh, fstride;
	UINT64 seq;

	/* input queue */
	AerInput queue[QUEUE_MAX];
	int qn;

	/* clipboard */
	BOOL clip_allowed;
	CliprdrClientContext* clip;
	BOOL clip_ready;
	char* local_text;
	BOOL local_dirty;
	char* remote_text;
	UINT64 remote_seq;
};

typedef struct
{
	rdpClientContext common;
	AerRdp* owner;
} AerContext;

static AerRdp* owner_of(rdpContext* ctx)
{
	return ((AerContext*)ctx)->owner;
}

static void set_error(AerRdp* r, const char* msg)
{
	EnterCriticalSection(&r->lock);
	if (r->error[0] == '\0')
		snprintf(r->error, sizeof(r->error), "%s", msg);
	LeaveCriticalSection(&r->lock);
}

/* ---- certificate pin ---- */

static void normalize_fp(const char* in, char* out, size_t cap)
{
	size_t n = 0;
	for (; in && *in && n + 1 < cap; in++)
		if (isxdigit((unsigned char)*in))
			out[n++] = (char)tolower((unsigned char)*in);
	out[n] = '\0';
}

static DWORD aer_verify(freerdp* instance, const char* host, UINT16 port, const char* cn,
                        const char* subject, const char* issuer, const char* fingerprint,
                        DWORD flags)
{
	AerRdp* r = owner_of(instance->context);
	char got[129];
	(void)host;
	(void)port;
	(void)cn;
	(void)subject;
	(void)issuer;
	if ((flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0 || strlen(r->pin) != 64)
	{
		set_error(r, "certificate: no SHA-256 fingerprint to compare with the pin");
		return 0;
	}
	normalize_fp(fingerprint, got, sizeof(got));
	if (strcmp(got, r->pin) != 0)
	{
		set_error(r, "certificate does not match the pinned host certificate");
		return 0;
	}
	return 2; /* accept for this connection only; nothing is stored */
}

static DWORD aer_verify_changed(freerdp* instance, const char* host, UINT16 port, const char* cn,
                                const char* subject, const char* issuer, const char* fingerprint,
                                const char* old_subject, const char* old_issuer,
                                const char* old_fingerprint, DWORD flags)
{
	(void)old_subject;
	(void)old_issuer;
	(void)old_fingerprint;
	return aer_verify(instance, host, port, cn, subject, issuer, fingerprint, flags);
}

/* ---- clipboard (text only) ---- */

/* Own every retained buffer in this module. WinPR's *Alloc functions use
 * WinPR's CRT: freeing their result in an /MDd bridge linked to /MD WinPR
 * is invalid. The non-allocating conversion APIs work with caller buffers
 * on Windows and Linux, without requiring newer WinPR deallocator APIs. */
static WCHAR* clip_to_utf16(const char* text, size_t* length)
{
	const SSIZE_T count = ConvertUtf8ToWChar(text, NULL, 0);
	if (count < 0 || (size_t)count >= CLIP_MAX_BYTES / sizeof(WCHAR))
		return NULL;
	WCHAR* out = calloc((size_t)count + 1, sizeof(WCHAR));
	if (!out)
		return NULL;
	if (ConvertUtf8ToWChar(text, out, (size_t)count + 1) != count)
	{
		free(out);
		return NULL;
	}
	*length = (size_t)count;
	return out;
}

static char* clip_to_utf8(const WCHAR* text, size_t length)
{
	const SSIZE_T count = ConvertWCharNToUtf8(text, length, NULL, 0);
	if (count < 0 || (size_t)count >= CLIP_MAX_BYTES)
		return NULL;
	char* out = calloc((size_t)count + 1, sizeof(char));
	if (!out)
		return NULL;
	if (ConvertWCharNToUtf8(text, length, out, (size_t)count + 1) != count)
	{
		free(out);
		return NULL;
	}
	return out;
}

static UINT clip_send_format_list(AerRdp* r)
{
	CLIPRDR_FORMAT fmt = { CF_UNICODETEXT, NULL };
	CLIPRDR_FORMAT_LIST list = { 0 };
	CliprdrClientContext* c = r->clip;
	if (!c)
		return CHANNEL_RC_OK;
	EnterCriticalSection(&r->lock);
	BOOL have = r->local_text != NULL;
	LeaveCriticalSection(&r->lock);
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = have ? 1 : 0;
	list.formats = have ? &fmt : NULL;
	return c->ClientFormatList(c, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext* c, const CLIPRDR_MONITOR_READY* m)
{
	AerRdp* r = (AerRdp*)c->custom;
	CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
	CLIPRDR_CAPABILITIES caps = { 0 };
	(void)m;
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = 12;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
	caps.cCapabilitiesSets = 1;
	caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
	UINT rc = c->ClientCapabilities(c, &caps);
	if (rc != CHANNEL_RC_OK)
		return rc;
	r->clip_ready = TRUE;
	return clip_send_format_list(r);
}

static UINT clip_server_caps(CliprdrClientContext* c, const CLIPRDR_CAPABILITIES* caps)
{
	(void)c;
	(void)caps;
	return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST* list)
{
	CLIPRDR_FORMAT_LIST_RESPONSE resp = { 0 };
	BOOL text = FALSE;
	resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
	resp.common.msgFlags = CB_RESPONSE_OK;
	UINT rc = c->ClientFormatListResponse(c, &resp);
	if (rc != CHANNEL_RC_OK)
		return rc;
	for (UINT32 i = 0; i < list->numFormats; i++)
		if (list->formats[i].formatId == CF_UNICODETEXT)
			text = TRUE;
	if (!text)
		return CHANNEL_RC_OK;
	CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
	req.common.msgType = CB_FORMAT_DATA_REQUEST;
	req.requestedFormatId = CF_UNICODETEXT;
	return c->ClientFormatDataRequest(c, &req);
}

static UINT clip_server_format_list_response(CliprdrClientContext* c,
                                             const CLIPRDR_FORMAT_LIST_RESPONSE* resp)
{
	(void)c;
	(void)resp;
	return CHANNEL_RC_OK;
}

static UINT clip_server_data_response(CliprdrClientContext* c,
                                      const CLIPRDR_FORMAT_DATA_RESPONSE* resp)
{
	AerRdp* r = (AerRdp*)c->custom;
	if ((resp->common.msgFlags & CB_RESPONSE_OK) == 0 || !resp->requestedFormatData ||
	    resp->common.dataLen < sizeof(WCHAR) || resp->common.dataLen > CLIP_MAX_BYTES ||
	    resp->common.dataLen % sizeof(WCHAR) != 0)
		return CHANNEL_RC_OK;
	size_t wlen = resp->common.dataLen / sizeof(WCHAR);
	char* text = clip_to_utf8((const WCHAR*)resp->requestedFormatData, wlen);
	if (!text)
		return CHANNEL_RC_OK;
	EnterCriticalSection(&r->lock);
	free(r->remote_text);
	r->remote_text = text;
	r->remote_seq++;
	LeaveCriticalSection(&r->lock);
	return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext* c,
                                     const CLIPRDR_FORMAT_DATA_REQUEST* req)
{
	AerRdp* r = (AerRdp*)c->custom;
	CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
	WCHAR* w = NULL;
	size_t wlen = 0;
	resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
	EnterCriticalSection(&r->lock);
	if (req->requestedFormatId == CF_UNICODETEXT && r->local_text)
		w = clip_to_utf16(r->local_text, &wlen);
	LeaveCriticalSection(&r->lock);
	if (w)
	{
		resp.common.msgFlags = CB_RESPONSE_OK;
		resp.common.dataLen = (UINT32)((wlen + 1) * sizeof(WCHAR)); /* with the terminator */
		resp.requestedFormatData = (const BYTE*)w;
	}
	else
		resp.common.msgFlags = CB_RESPONSE_FAIL;
	UINT rc = c->ClientFormatDataResponse(c, &resp);
	free(w);
	return rc;
}

static void clip_init(AerRdp* r, CliprdrClientContext* c)
{
	c->custom = r;
	c->MonitorReady = clip_monitor_ready;
	c->ServerCapabilities = clip_server_caps;
	c->ServerFormatList = clip_server_format_list;
	c->ServerFormatListResponse = clip_server_format_list_response;
	c->ServerFormatDataResponse = clip_server_data_response;
	c->ServerFormatDataRequest = clip_server_data_request;
	r->clip = c;
}

/* ---- channels and paint ---- */

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	AerRdp* r = owner_of((rdpContext*)context);
	if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		if (r->clip_allowed)
			clip_init(r, (CliprdrClientContext*)e->pInterface);
		return;
	}
	freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	AerRdp* r = owner_of((rdpContext*)context);
	if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		r->clip = NULL;
		r->clip_ready = FALSE;
		return;
	}
	freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

static BOOL copy_frame(AerRdp* r)
{
	rdpGdi* gdi = r->ctx->gdi;
	if (!gdi || !gdi->primary_buffer)
		return TRUE;
	size_t need = (size_t)gdi->stride * gdi->height;
	EnterCriticalSection(&r->lock);
	if (need > r->frame_cap)
	{
		BYTE* p = realloc(r->frame, need);
		if (!p)
		{
			LeaveCriticalSection(&r->lock);
			return FALSE;
		}
		r->frame = p;
		r->frame_cap = need;
	}
	memcpy(r->frame, gdi->primary_buffer, need);
	r->fw = gdi->width;
	r->fh = gdi->height;
	r->fstride = gdi->stride;
	r->seq++;
	LeaveCriticalSection(&r->lock);
	return TRUE;
}

static BOOL aer_begin_paint(rdpContext* ctx)
{
	rdpGdi* gdi = ctx->gdi;
	if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd)
	{
		gdi->primary->hdc->hwnd->invalid->null = TRUE;
		gdi->primary->hdc->hwnd->ninvalid = 0;
	}
	return TRUE;
}

static BOOL aer_end_paint(rdpContext* ctx)
{
	return copy_frame(owner_of(ctx));
}

static BOOL aer_desktop_resize(rdpContext* ctx)
{
	rdpSettings* s = ctx->settings;
	if (!gdi_resize(ctx->gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
	                freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight)))
		return FALSE;
	return copy_frame(owner_of(ctx));
}

static BOOL aer_pre_connect(freerdp* instance)
{
	rdpContext* ctx = instance->context;
	if (PubSub_SubscribeChannelConnected(ctx->pubSub, on_channel_connected) < 0 ||
	    PubSub_SubscribeChannelDisconnected(ctx->pubSub, on_channel_disconnected) < 0)
		return FALSE;
	return TRUE;
}

static BOOL aer_post_connect(freerdp* instance)
{
	rdpContext* ctx = instance->context;
	if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
		return FALSE;
	ctx->update->BeginPaint = aer_begin_paint;
	ctx->update->EndPaint = aer_end_paint;
	ctx->update->DesktopResize = aer_desktop_resize;
	return copy_frame(owner_of(ctx));
}

static void aer_post_disconnect(freerdp* instance)
{
	rdpContext* ctx = instance->context;
	(void)PubSub_UnsubscribeChannelConnected(ctx->pubSub, on_channel_connected);
	(void)PubSub_UnsubscribeChannelDisconnected(ctx->pubSub, on_channel_disconnected);
	gdi_free(instance);
}

static BOOL aer_client_new(freerdp* instance, rdpContext* context)
{
	(void)context;
	instance->PreConnect = aer_pre_connect;
	instance->PostConnect = aer_post_connect;
	instance->PostDisconnect = aer_post_disconnect;
	instance->VerifyCertificateEx = aer_verify;
	instance->VerifyChangedCertificateEx = aer_verify_changed;
	instance->LoadChannels = freerdp_client_load_channels;
	return TRUE;
}

static void aer_client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}

/* ---- connection thread ---- */

static void flush_input(AerRdp* r)
{
	AerInput q[QUEUE_MAX];
	int n;
	BOOL dirty;
	EnterCriticalSection(&r->lock);
	n = r->qn;
	memcpy(q, r->queue, sizeof(AerInput) * (size_t)n);
	r->qn = 0;
	dirty = r->local_dirty && r->clip_ready;
	if (dirty)
		r->local_dirty = FALSE;
	LeaveCriticalSection(&r->lock);
	rdpInput* in = r->ctx->input;
	for (int i = 0; i < n; i++)
	{
		switch (q[i].kind)
		{
			case 1:
				(void)freerdp_input_send_mouse_event(in, q[i].flags, q[i].x, q[i].y);
				break;
			case 2:
				(void)freerdp_input_send_keyboard_event_ex(in, q[i].down, FALSE, q[i].code);
				break;
			case 3:
				(void)freerdp_input_send_unicode_keyboard_event(
				    in, q[i].down ? 0 : KBD_FLAGS_RELEASE, (UINT16)q[i].code);
				break;
			default:
				break;
		}
	}
	if (dirty)
		(void)clip_send_format_list(r);
}

static void record_last_error(AerRdp* r)
{
	UINT32 code = freerdp_get_last_error(r->ctx);
	if (code != FREERDP_ERROR_SUCCESS)
		set_error(r, freerdp_get_last_error_string(code));
}

static DWORD WINAPI aer_thread(LPVOID arg)
{
	AerRdp* r = (AerRdp*)arg;
	freerdp* instance = r->ctx->instance;
	if (!freerdp_connect(instance))
	{
		record_last_error(r);
		set_error(r, "connection failed");
		InterlockedExchange(&r->state, AER_RDP_FAILED);
		return 0;
	}
	InterlockedExchange(&r->state, AER_RDP_CONNECTED);
	while (!freerdp_shall_disconnect_context(r->ctx))
	{
		HANDLE h[MAXIMUM_WAIT_OBJECTS] = { 0 };
		DWORD n = freerdp_get_event_handles(r->ctx, h, ARRAYSIZE(h) - 2);
		if (n == 0)
			break;
		h[n++] = r->stop;
		h[n++] = r->wake;
		if (WaitForMultipleObjects(n, h, FALSE, 100) == WAIT_FAILED)
			break;
		if (WaitForSingleObject(r->stop, 0) == WAIT_OBJECT_0)
			break;
		flush_input(r);
		if (!freerdp_check_event_handles(r->ctx))
		{
			record_last_error(r);
			break;
		}
	}
	(void)freerdp_disconnect(instance);
	InterlockedExchange(&r->state, AER_RDP_DISCONNECTED);
	return 0;
}

/* ---- public API ---- */

int aer_rdp_version(void)
{
	return AER_RDP_ABI;
}

AerRdp* aer_rdp_new(void)
{
	AerRdp* r = calloc(1, sizeof(AerRdp));
	if (!r)
		return NULL;
	InitializeCriticalSection(&r->lock);
	r->stop = CreateEvent(NULL, TRUE, FALSE, NULL);
	r->wake = CreateEvent(NULL, FALSE, FALSE, NULL);
	if (!r->stop || !r->wake)
	{
		aer_rdp_free(r);
		return NULL;
	}
	return r;
}

#if defined(_WIN32)
/* A fresh directory under %TEMP% (same role as mkdtemp): without it FreeRDP
 * would use %APPDATA%\FreeRDP, whose known_hosts2 is consulted before
 * VerifyCertificateEx and could accept a host the pin would reject. */
static BOOL make_private_dir(char* out, size_t cap)
{
	char base[MAX_PATH];
	DWORD n = GetTempPathA(sizeof(base), base);
	if (n == 0 || n >= sizeof(base))
		return FALSE;
	for (int i = 0; i < 16; i++)
	{
		UINT32 rnd[2];
		if (winpr_RAND(rnd, sizeof(rnd)) < 0)
			return FALSE;
		snprintf(out, cap, "%saer-rdp-%08x%08x", base, rnd[0], rnd[1]);
		if (CreateDirectoryA(out, NULL)) /* inherits the user-only ACL of %TEMP% */
			return TRUE;
		if (GetLastError() != ERROR_ALREADY_EXISTS)
			break;
	}
	out[0] = '\0';
	return FALSE;
}
#else
static int remove_entry(const char* path, const struct stat* sb, int flag, struct FTW* ftw)
{
	(void)sb;
	(void)flag;
	(void)ftw;
	return remove(path);
}
#endif

int aer_rdp_connect(AerRdp* r, const char* host, int port, const char* user, const char* password,
                    const char* cert_sha256, int width, int height, int clipboard)
{
	if (!r || r->ctx || !host || port <= 0 || port > 65535)
		return -1;
	normalize_fp(cert_sha256, r->pin, sizeof(r->pin));
	if (strlen(r->pin) != 64)
	{
		set_error(r, "a SHA-256 certificate pin is required");
		r->state = AER_RDP_FAILED;
		return -1;
	}
	r->clip_allowed = clipboard != 0;
#if defined(_WIN32)
	if (!make_private_dir(r->cfgdir, sizeof(r->cfgdir)))
	{
		set_error(r, "could not create a private FreeRDP config directory");
		r->state = AER_RDP_FAILED;
		return -1;
	}
#else
	snprintf(r->cfgdir, sizeof(r->cfgdir), "%s/aer-rdp-XXXXXX",
	         getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	if (!mkdtemp(r->cfgdir))
		return -1;
#endif
	RDP_CLIENT_ENTRY_POINTS ep = { 0 };
	ep.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	ep.Version = RDP_CLIENT_INTERFACE_VERSION;
	ep.ContextSize = sizeof(AerContext);
	ep.ClientNew = aer_client_new;
	ep.ClientFree = aer_client_free;
	r->ctx = freerdp_client_context_new(&ep);
	if (!r->ctx)
		return -1;
	((AerContext*)r->ctx)->owner = r;
	rdpSettings* s = r->ctx->settings;
	if (width < 200 || width > 8192)
		width = 1280;
	if (height < 200 || height > 8192)
		height = 800;
	BOOL ok = freerdp_settings_set_string(s, FreeRDP_ServerHostname, host) &&
	          freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port) &&
	          freerdp_settings_set_string(s, FreeRDP_Username, user ? user : "") &&
	          freerdp_settings_set_string(s, FreeRDP_Password, password ? password : "") &&
	          freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)width) &&
	          freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)height) &&
	          freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32) &&
	          freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE) &&
	          freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE) &&
	          /* Fallback when the server has no GFX (FreeRDP server/shadow,
	           * the base of windows-shadow): surface bits with RemoteFX/NSC. */
	          freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE) &&
	          freerdp_settings_set_bool(s, FreeRDP_NSCodec, TRUE) &&
	          freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, r->clip_allowed) &&
	          freerdp_settings_set_bool(s, FreeRDP_AutoAcceptCertificate, FALSE) &&
	          freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, FALSE) &&
	          freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, FALSE) &&
	          freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE) &&
	          freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, FALSE) &&
	          (r->cfgdir[0] == '\0' || freerdp_settings_set_string(s, FreeRDP_ConfigPath, r->cfgdir));
	if (!ok)
	{
		set_error(r, "could not apply connection settings");
		return -1;
	}
	r->state = AER_RDP_CONNECTING;
	r->thread = CreateThread(NULL, 0, aer_thread, r, 0, NULL);
	if (!r->thread)
	{
		r->state = AER_RDP_FAILED;
		return -1;
	}
	return 0;
}

int aer_rdp_state(AerRdp* r)
{
	return r ? (int)InterlockedCompareExchange(&r->state, 0, 0) : AER_RDP_FAILED;
}

const char* aer_rdp_error(AerRdp* r)
{
	return r ? r->error : "no handle";
}

const uint8_t* aer_rdp_frame_lock(AerRdp* r, int* width, int* height, int* stride, uint64_t* seq)
{
	EnterCriticalSection(&r->lock);
	if (!r->frame || r->fw == 0)
	{
		LeaveCriticalSection(&r->lock);
		return NULL;
	}
	*width = (int)r->fw;
	*height = (int)r->fh;
	*stride = (int)r->fstride;
	*seq = r->seq;
	return r->frame; /* the caller must call aer_rdp_frame_unlock */
}

void aer_rdp_frame_unlock(AerRdp* r)
{
	LeaveCriticalSection(&r->lock);
}

static void enqueue(AerRdp* r, AerInput in)
{
	EnterCriticalSection(&r->lock);
	if (r->qn < QUEUE_MAX)
		r->queue[r->qn++] = in;
	LeaveCriticalSection(&r->lock);
	SetEvent(r->wake);
}

void aer_rdp_mouse(AerRdp* r, int flags, int x, int y)
{
	AerInput in = { 1, (UINT16)flags, (UINT16)(x < 0 ? 0 : x), (UINT16)(y < 0 ? 0 : y), 0, FALSE };
	enqueue(r, in);
}

void aer_rdp_key(AerRdp* r, int scancode, int down)
{
	AerInput in = { 2, 0, 0, 0, (UINT32)scancode, down != 0 };
	enqueue(r, in);
}

void aer_rdp_unicode(AerRdp* r, int codepoint, int down)
{
	AerInput in = { 3, 0, 0, 0, (UINT32)codepoint, down != 0 };
	enqueue(r, in);
}

int aer_rdp_clip_set(AerRdp* r, const char* utf8)
{
	if (!r->clip_allowed)
		return -1;
	if (utf8 && strlen(utf8) >= CLIP_MAX_BYTES)
		return -1;
	char* copy = utf8 ? _strdup(utf8) : NULL;
	if (utf8 && !copy)
		return -1;
	EnterCriticalSection(&r->lock);
	free(r->local_text);
	r->local_text = copy;
	r->local_dirty = TRUE;
	LeaveCriticalSection(&r->lock);
	SetEvent(r->wake);
	return 0;
}

char* aer_rdp_clip_get(AerRdp* r, uint64_t* seq)
{
	char* out = NULL;
	EnterCriticalSection(&r->lock);
	if (r->remote_text && r->remote_seq != *seq)
	{
		out = _strdup(r->remote_text);
		*seq = r->remote_seq;
	}
	LeaveCriticalSection(&r->lock);
	return out;
}

void aer_rdp_disconnect(AerRdp* r)
{
	if (!r)
		return;
	SetEvent(r->stop);
	if (r->ctx && aer_rdp_state(r) == AER_RDP_CONNECTING)
		(void)freerdp_abort_connect_context(r->ctx);
}

void aer_rdp_free(AerRdp* r)
{
	if (!r)
		return;
	aer_rdp_disconnect(r);
	if (r->thread)
	{
		(void)WaitForSingleObject(r->thread, INFINITE);
		(void)CloseHandle(r->thread);
	}
	if (r->ctx)
		freerdp_client_context_free(r->ctx);
	if (r->cfgdir[0])
	{
#if defined(_WIN32)
		(void)winpr_RemoveDirectory_RecursiveA(r->cfgdir);
#else
		(void)nftw(r->cfgdir, remove_entry, 8, FTW_DEPTH | FTW_PHYS);
#endif
	}
	(void)CloseHandle(r->stop);
	(void)CloseHandle(r->wake);
	DeleteCriticalSection(&r->lock);
	free(r->frame);
	free(r->local_text);
	free(r->remote_text);
	memset(r->pin, 0, sizeof(r->pin));
	free(r);
}

void aer_rdp_mem_free(void* p)
{
	free(p);
}
