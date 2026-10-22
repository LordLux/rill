#include <bitsdojo_window_windows/bitsdojo_window_plugin.h>
auto bdw = bitsdojo_window_configure(BDW_CUSTOM_FRAME | BDW_HIDE_ON_STARTUP);
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "log_capture.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // A release build's first process only launches the app and keeps its log.
  int launcher_exit_code = 0;
  if (RunAsLogLauncher(&launcher_exit_code)) {
    return launcher_exit_code;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger. Not in the launcher's child:
  // its output already goes to the launcher, which copies it to the console.
  if (::GetEnvironmentVariableW(L"RILL_LOG_FILE", nullptr, 0) == 0 &&
      !::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (!window.Create(L"Rill", origin, size)) {
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }  // The window, and with it the engine, is gone: this part takes ~100 ms.

  ::CoUninitialize();

  // **End the process here instead of returning into the C runtime's exit.**
  // Measured 2026-10-21 on the release build: a clean close ran to this point
  // (WM_DESTROY, the message loop, the window's destructor, all within ~100 ms)
  // and the process then never ended. It sat on one thread burning about half a
  // core, with every DLL still mapped, and the launcher waiting on it — so the
  // window closed, the app did not, and the in-app updater's installer could not
  // replace files a live process held ("Some applications could not be shut down",
  // twice). A debugger attach named it: `flutter_inappwebview_windows`'s DLL detach
  // releases a Direct3D 11 device and the Intel driver (`igd10um64xe`) spins inside
  // that. Returning from `wWinMain` runs it, and this does not (`todo.md` 97).
  // Nothing is lost: the engine has shut down, preferences and the credential
  // store write when set, and the sidecar and WebView2 are children that end with
  // their parent (the launcher's job object kills the rest).
  ::fflush(nullptr);
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);
  return EXIT_SUCCESS;  // not reached
}
