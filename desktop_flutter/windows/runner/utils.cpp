#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <propkey.h>
#include <propvarutil.h>
#include <stdio.h>
#include <ShObjIdl_core.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

void SetTransVortexAppUserModelId() {
  // Best-effort shell identity for taskbar grouping and unpackaged toast paths.
  (void)::SetCurrentProcessExplicitAppUserModelID(kTransVortexAppUserModelId);
}

bool SetShortcutAppUserModelId(const wchar_t* shortcut_path) {
  if (shortcut_path == nullptr || shortcut_path[0] == L'\0') {
    return false;
  }

  IShellLinkW* shell_link = nullptr;
  HRESULT result = ::CoCreateInstance(CLSID_ShellLink, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&shell_link));
  if (FAILED(result)) {
    return false;
  }

  IPersistFile* persist_file = nullptr;
  result = shell_link->QueryInterface(IID_PPV_ARGS(&persist_file));
  if (SUCCEEDED(result)) {
    result = persist_file->Load(shortcut_path, STGM_READWRITE);
  }

  IPropertyStore* property_store = nullptr;
  if (SUCCEEDED(result)) {
    result = shell_link->QueryInterface(IID_PPV_ARGS(&property_store));
  }

  PROPVARIANT app_user_model_id;
  ::PropVariantInit(&app_user_model_id);
  if (SUCCEEDED(result)) {
    result = ::InitPropVariantFromString(kTransVortexAppUserModelId,
                                         &app_user_model_id);
  }
  if (SUCCEEDED(result)) {
    result = property_store->SetValue(PKEY_AppUserModel_ID,
                                      app_user_model_id);
  }
  if (SUCCEEDED(result)) {
    result = property_store->Commit();
  }
  if (SUCCEEDED(result)) {
    result = persist_file->Save(shortcut_path, TRUE);
  }

  ::PropVariantClear(&app_user_model_id);
  if (property_store != nullptr) {
    property_store->Release();
  }
  if (persist_file != nullptr) {
    persist_file->Release();
  }
  shell_link->Release();
  return SUCCEEDED(result);
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
