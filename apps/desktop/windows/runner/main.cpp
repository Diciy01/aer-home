#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <cstdlib>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // Development aid (as on Linux): AER_WINDOW_SIZE=1920x1080 sets the initial
  // size for performance and screenshot checks at known resolutions.
  unsigned int width = 1280, height = 720;
  char requested[32];
  size_t len = 0;
  if (getenv_s(&len, requested, sizeof(requested), "AER_WINDOW_SIZE") == 0 &&
      len > 0) {
    unsigned int w = 0, h = 0;
    if (sscanf_s(requested, "%ux%u", &w, &h) == 2 && w >= 320 && h >= 240) {
      width = w;
      height = h;
    }
  }
  Win32Window::Size size(width, height);
  if (!window.Create(L"AER HOME", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
