#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

int RunShellIntegrationCommandIfRequested() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return -1;
  }

  int exit_code = -1;
  if (argc == 3 &&
      ::wcscmp(argv[1], L"--set-shortcut-app-user-model-id") == 0) {
    exit_code = SetShortcutAppUserModelId(argv[2]) ? EXIT_SUCCESS
                                                    : EXIT_FAILURE;
  }
  ::LocalFree(argv);
  return exit_code;
}

}  // namespace

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
  const int shell_command_result = RunShellIntegrationCommandIfRequested();
  if (shell_command_result >= 0) {
    ::CoUninitialize();
    return shell_command_result;
  }

  HANDLE app_mutex = ::CreateMutexW(nullptr, FALSE, kTransVortexAppMutexName);
  SetTransVortexAppUserModelId();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"TransVortex", origin, size)) {
    if (app_mutex != nullptr) {
      ::CloseHandle(app_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (app_mutex != nullptr) {
    ::CloseHandle(app_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
