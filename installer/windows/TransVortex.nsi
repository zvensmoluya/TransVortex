Unicode True
RequestExecutionLevel user
ManifestDPIAware true
ManifestSupportedOS all
CRCCheck force
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "nsDialogs.nsh"
!include "StrFunc.nsh"

${Using:StrFunc} StrTrimNewLines

!ifndef APP_SOURCE
  !error "APP_SOURCE must point to the validated installer payload"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE must point to the installer executable"
!endif
!ifndef APP_VERSION
  !define APP_VERSION "0.1.0"
!endif
!ifndef APP_FILE_VERSION
  !define APP_FILE_VERSION "0.1.0.1"
!endif
!ifndef ESTIMATED_SIZE_KB
  !define ESTIMATED_SIZE_KB 0
!endif
!ifndef LICENSE_FILE
  !error "LICENSE_FILE must point to the TransVortex license"
!endif
!ifndef APP_ICON
  !error "APP_ICON must point to the TransVortex icon"
!endif
!ifndef INSTALLER_WELCOME_BITMAP
  !error "INSTALLER_WELCOME_BITMAP must point to the branded NSIS welcome bitmap"
!endif
!ifndef INSTALLER_HEADER_BITMAP
  !error "INSTALLER_HEADER_BITMAP must point to the branded NSIS header bitmap"
!endif
!ifndef ASR_CONFIG_READER
  !error "ASR_CONFIG_READER must point to the installer ASR config reader"
!endif

!define APP_NAME "TransVortex"
!define APP_PUBLISHER "TransVortex Contributors"
!define APP_ID "TransVortex"
!define APP_MUTEX "Local\TransVortex.Desktop.89E122A8-7AB7-4D0F-9661-0EC5A881F65B"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
!define APP_REGISTRY_KEY "Software\TransVortex"

!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_BGCOLOR "FAF8FC"
!define MUI_TEXTCOLOR "2E2A33"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_RIGHT
!define MUI_HEADERIMAGE_BITMAP "${INSTALLER_HEADER_BITMAP}"
!define MUI_HEADERIMAGE_UNBITMAP "${INSTALLER_HEADER_BITMAP}"
!define MUI_HEADERIMAGE_BITMAP_STRETCH "NoStretchNoCrop"
!define MUI_HEADERIMAGE_UNBITMAP_STRETCH "NoStretchNoCrop"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${INSTALLER_WELCOME_BITMAP}"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "${INSTALLER_WELCOME_BITMAP}"
!define MUI_WELCOMEFINISHPAGE_BITMAP_STRETCH "NoStretchNoCrop"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP_STRETCH "NoStretchNoCrop"

Name "${APP_NAME}"
Caption "${APP_NAME} 安装程序"
BrandingText "${APP_NAME} ${APP_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\TransVortex"
InstallDirRegKey HKCU "${APP_REGISTRY_KEY}" "InstallLocation"
Icon "${APP_ICON}"
UninstallIcon "${APP_ICON}"
SetFont /LANG=2052 "Segoe UI" 9
AllowRootDirInstall false
ShowInstDetails nevershow
ShowUninstDetails nevershow

VIProductVersion "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 用户级安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyright (C) 2026 Zven. Apache-2.0 licensed."

Var ProductRoot

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\TransVortex.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动 TransVortex"
!define MUI_WELCOMEPAGE_TITLE "欢迎来到 TransVortex"
!define MUI_WELCOMEPAGE_TEXT "安静的个人字幕译制工作间。$\r$\n$\r$\n安装程序将准备固定运行环境、媒体工具和桌面入口；语音识别模型可在应用内按需下载。"
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_HEADER_TEXT "许可协议"
!define MUI_PAGE_HEADER_SUBTEXT "请阅读 TransVortex 的开源许可。"
!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!define MUI_DIRECTORYPAGE_TEXT_TOP "请选择 TransVortex 产品根目录。安装器会在该目录下建立独立的 App、Data 和 Resources；升级只替换 App。"
!define MUI_DIRECTORYPAGE_TEXT_DESTINATION "TransVortex 产品根目录"
!define MUI_DIRECTORYPAGE_VARIABLE $ProductRoot
!define MUI_PAGE_CUSTOMFUNCTION_PRE DirectoryPagePrepare
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE DirectoryPageLeave
!define MUI_PAGE_HEADER_TEXT "选择 TransVortex 存放位置"
!define MUI_PAGE_HEADER_SUBTEXT "程序、工作数据和识别资源使用相互隔离的子目录。"
!insertmacro MUI_PAGE_DIRECTORY
Page custom WorkspacePageCreate WorkspacePageLeave
!define MUI_PAGE_HEADER_TEXT "正在准备 TransVortex"
!define MUI_PAGE_HEADER_SUBTEXT "安装固定运行环境、媒体工具，并准备工作数据位置。"
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "TransVortex 已准备好"
!define MUI_FINISHPAGE_TEXT "安装已经完成。首次启动后可配置翻译服务，并按需准备本机语音识别资源。"
!insertmacro MUI_PAGE_FINISH

!define MUI_UNCONFIRMPAGE_TEXT_TOP "将从此电脑移除 TransVortex 程序。下一步可以选择是否同时清理下载资源、设置、任务和凭据。"
!insertmacro MUI_UNPAGE_CONFIRM
UninstPage custom un.CleanupPageCreate un.CleanupPageLeave
!define MUI_PAGE_HEADER_TEXT "正在卸载 TransVortex"
!define MUI_PAGE_HEADER_SUBTEXT "移除程序文件，并按你的选择清理本地内容。"
!insertmacro MUI_UNPAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "TransVortex 已卸载"
!define MUI_FINISHPAGE_TEXT "程序已经移除。未选择清理的配置、任务、凭据和外部模型仍保留在原位置。"
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "SimpChinese"

Var StagingDir
Var PreviousDir
Var HadPreviousInstall
Var ShortcutBackup
Var WorkspaceDialog
Var WorkspacePathInput
Var WorkspaceBrowseButton
Var WorkspaceNoticeLabel
Var WorkspaceRoot
Var WorkspaceLocked
Var AsrStorageRoot
Var ModernInstallLayout
Var CleanupDialog
Var CleanupAsrCheckbox
Var CleanupSettingsCheckbox
Var CleanupTasksCheckbox
Var CleanupCredentialsCheckbox
Var CleanupAsrRootLabel
Var CleanupNoticeLabel
Var CleanupRemoveAsr
Var CleanupRemoveSettings
Var CleanupRemoveTasks
Var CleanupRemoveCredentials
Var CleanupReport
Var CleanupArgs
Var CleanupMessage
Var CleanupFailure
Var RunningAppPid

Function IsAppRunning
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX}") p .r0'
  IntPtrCmp $0 0 app_not_running
  System::Call 'kernel32::CloseHandle(p r0)'
  Push "1"
  Return

app_not_running:
  Push "0"
FunctionEnd

Function WaitForAppExit
  StrCpy $1 "0"

wait_for_app_exit_check:
  Call IsAppRunning
  Pop $0
  StrCmp $0 "0" wait_for_app_exit_done
  Sleep 250
  IntOp $1 $1 + 1
  IntCmp $1 40 wait_for_app_exit_timeout wait_for_app_exit_check wait_for_app_exit_timeout

wait_for_app_exit_done:
  Push "closed"
  Return

wait_for_app_exit_timeout:
  Push "running"
FunctionEnd

Function RequestRunningAppShutdown
  Call IsAppRunning
  Pop $0
  StrCmp $0 "0" running_app_shutdown_done

  StrCpy $2 "0"

running_app_find_window:
  FindWindow $0 "FLUTTER_RUNNER_WIN32_WINDOW" "${APP_NAME}"
  StrCmp $0 0 0 running_app_window_found
  Sleep 250
  IntOp $2 $2 + 1
  IntCmp $2 20 running_app_shutdown_failed running_app_find_window running_app_shutdown_failed

running_app_window_found:
  System::Call 'user32::GetWindowThreadProcessId(p r0, *i .r1) i .r2'
  StrCpy $RunningAppPid "$1"
  StrCmp $RunningAppPid "0" running_app_shutdown_failed

  ; The user (or an explicit /CLOSEAPP caller) has approved stopping this exact
  ; application process and its Local Service / worker child processes.
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /PID $RunningAppPid /T /F'
  Pop $2
  Pop $3
  Call WaitForAppExit
  Pop $0
  StrCmp $0 "closed" running_app_shutdown_done running_app_shutdown_failed

running_app_shutdown_done:
  Push "closed"
  Return

running_app_shutdown_failed:
  Push "failed"
FunctionEnd

Function CheckAppNotRunning
check_again:
  Call IsAppRunning
  Pop $0
  StrCmp $0 "0" not_running
  IfSilent silent_running interactive_running

interactive_running:
  MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON1 \
    "TransVortex 正在运行，更新前需要关闭。$\r$\n$\r$\n确认后，安装程序会结束 TransVortex 及其本地服务，再继续更新。正在处理的任务将被中断，已落盘进度可稍后继续；未保存的界面编辑可能丢失。$\r$\n$\r$\n是否关闭 TransVortex 并继续更新？" \
    IDYES close_running_app IDNO cancel_install

silent_running:
  ${GetParameters} $1
  ClearErrors
  ${GetOptions} "$1" "/CLOSEAPP" $2
  IfErrors silent_running_blocked close_running_app

silent_running_blocked:
  SetErrorLevel 10
  Quit

close_running_app:
  SetDetailsPrint textonly
  DetailPrint "正在关闭 TransVortex…"
  SetDetailsPrint none
  Call RequestRunningAppShutdown
  Pop $0
  StrCmp $0 "closed" check_again close_running_app_failed

close_running_app_failed:
  IfSilent silent_running_blocked interactive_close_failed

interactive_close_failed:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
    "安装程序未能关闭 TransVortex。请保存工作并从托盘菜单退出应用，然后点击“重试”；也可以取消本次更新。" \
    IDRETRY check_again IDCANCEL cancel_install

cancel_install:
  SetErrorLevel 10
  Quit

not_running:
FunctionEnd

Function NormalizeInstallDirectory
  ReadRegStr $0 HKCU "${APP_REGISTRY_KEY}" "InstallLocation"
  StrCmp $0 "" normalize_leaf
  IfFileExists "$0\TransVortex.exe" 0 normalize_leaf
  System::Call 'kernel32::lstrcmpiW(w "$INSTDIR", w "$0") i .r1'
  IntCmp $1 0 normalize_done normalize_leaf normalize_leaf

normalize_leaf:
  ${GetFileName} "$INSTDIR" $1
  System::Call 'kernel32::lstrcmpiW(w "$1", w "${APP_NAME}") i .r2'
  IntCmp $2 0 normalize_product_root
  System::Call 'kernel32::lstrcmpiW(w "$1", w "App") i .r2'
  IntCmp $2 0 normalize_app_leaf
  StrCpy $INSTDIR "$INSTDIR\${APP_NAME}\App"
  Goto normalize_done

normalize_product_root:
  StrCpy $INSTDIR "$INSTDIR\App"
  Goto normalize_done

normalize_app_leaf:
  ${GetParent} "$INSTDIR" $1
  ${GetFileName} "$1" $2
  System::Call 'kernel32::lstrcmpiW(w "$2", w "${APP_NAME}") i .r3'
  IntCmp $3 0 normalize_done
  StrCpy $INSTDIR "$INSTDIR\${APP_NAME}\App"

normalize_done:
FunctionEnd

Function ResolveInstallLayout
  StrCpy $ProductRoot ""
  StrCpy $ModernInstallLayout "0"
  ${GetFileName} "$INSTDIR" $0
  System::Call 'kernel32::lstrcmpiW(w "$0", w "App") i .r1'
  IntCmp $1 0 install_layout_app install_layout_done install_layout_done

install_layout_app:
  ${GetParent} "$INSTDIR" $0
  ${GetFileName} "$0" $1
  System::Call 'kernel32::lstrcmpiW(w "$1", w "${APP_NAME}") i .r2'
  IntCmp $2 0 install_layout_modern install_layout_done install_layout_done

install_layout_modern:
  StrCpy $ProductRoot "$0"
  StrCpy $ModernInstallLayout "1"

install_layout_done:
FunctionEnd

Function ResolvePreservedProductRoot
  Push $0
  Push $1
  Push $2
  Push $3
  Push $4

  StrCpy $ProductRoot ""
  ReadRegStr $0 HKCU "${APP_REGISTRY_KEY}" "WorkspaceLocation"
  StrCmp $0 "" preserved_product_root_done
  ${GetFileName} "$0" $1
  System::Call 'kernel32::lstrcmpiW(w "$1", w "Data") i .r2'
  IntCmp $2 0 0 preserved_product_root_done preserved_product_root_done
  ${GetParent} "$0" $2
  ${GetFileName} "$2" $1
  System::Call 'kernel32::lstrcmpiW(w "$1", w "${APP_NAME}") i .r3'
  IntCmp $3 0 0 preserved_product_root_done preserved_product_root_done
  IfFileExists "$0\.transvortex-workspace.json" 0 preserved_product_root_done

  ClearErrors
  FileOpen $3 "$0\.transvortex-workspace.json" r
  IfErrors preserved_product_root_done
  FileRead $3 $4
  ${StrTrimNewLines} $4 "$4"
  StrCmp $4 "{" 0 preserved_product_root_close
  FileRead $3 $4
  ${StrTrimNewLines} $4 "$4"
  StrCmp $4 '  "schema_version": 1,' 0 preserved_product_root_close
  FileRead $3 $4
  ${StrTrimNewLines} $4 "$4"
  StrCmp $4 '  "app_id": "${APP_ID}"' 0 preserved_product_root_close
  FileRead $3 $4
  ${StrTrimNewLines} $4 "$4"
  StrCmp $4 "}" 0 preserved_product_root_close
  FileClose $3
  StrCpy $ProductRoot "$2"
  Goto preserved_product_root_done

preserved_product_root_close:
  FileClose $3

preserved_product_root_done:
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

Function CheckInstallDirectorySafety
  StrCpy $2 "0"
  ReadRegStr $0 HKCU "${APP_REGISTRY_KEY}" "InstallLocation"
  StrCmp $0 "" check_target
  IfFileExists "$0\TransVortex.exe" 0 check_target
  System::Call 'kernel32::lstrcmpiW(w "$INSTDIR", w "$0") i .r1'
  IntCmp $1 0 registered_same registered_different registered_different

registered_same:
  StrCpy $2 "1"
  Goto check_target

registered_different:
  IfSilent registered_different_silent registered_different_interactive

registered_different_silent:
  SetErrorLevel 12
  Quit

registered_different_interactive:
  MessageBox MB_OK|MB_ICONEXCLAMATION \
    "已检测到安装在 $0 的 TransVortex。为避免遗留旧版本，升级时不能直接更改安装位置；请先卸载旧版本。"
  Abort

check_target:
  IfFileExists "$INSTDIR\*.*" target_not_empty target_safe

target_not_empty:
  ReadINIStr $0 "$INSTDIR\.transvortex-install.ini" "Install" "AppId"
  StrCmp $0 "${APP_ID}" target_safe

  ; Accept the one pre-marker installer layout only when the registry points
  ; to this exact directory and the fixed runtime layout is intact.
  StrCmp $2 "1" 0 target_unsafe
  IfFileExists "$INSTDIR\TransVortex.exe" 0 target_unsafe
  IfFileExists "$INSTDIR\Uninstall.exe" 0 target_unsafe
  IfFileExists "$INSTDIR\runtime\app_runtime.json" 0 target_unsafe
  Goto target_safe

target_unsafe:
  IfSilent target_unsafe_silent target_unsafe_interactive

target_unsafe_silent:
  SetErrorLevel 11
  Quit

target_unsafe_interactive:
  MessageBox MB_OK|MB_ICONSTOP \
    "目标目录已经包含其他文件，且无法确认它属于 TransVortex。请选择其他位置；安装程序会在所选位置下创建专用的 TransVortex 子目录。"
  Abort

target_safe:
FunctionEnd

Function DirectoryPageLeave
  StrCpy $INSTDIR "$ProductRoot"
  Call NormalizeInstallDirectory
  Call CheckInstallDirectorySafety
FunctionEnd

Function DirectoryPagePrepare
  StrCmp $ProductRoot "" 0 directory_page_ready
  Call ResolveInstallLayout
  StrCmp $ProductRoot "" 0 directory_page_ready
  Call ResolvePreservedProductRoot
  StrCmp $ProductRoot "" 0 directory_page_ready
  StrCpy $ProductRoot "$INSTDIR"

directory_page_ready:
FunctionEnd

Function ResolveWorkspaceRoot
  StrCmp $WorkspaceRoot "" 0 workspace_root_done
  StrCpy $WorkspaceLocked "0"
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} "$0" "/WORKSPACEROOT=" $1
  IfErrors workspace_root_from_registry
  StrCmp $1 "" workspace_root_from_registry
  StrCpy $WorkspaceRoot "$1"
  Goto check_workspace_content

workspace_root_from_registry:
  ReadRegStr $WorkspaceRoot HKCU "${APP_REGISTRY_KEY}" "WorkspaceLocation"
  StrCmp $WorkspaceRoot "" check_legacy_workspace check_workspace_content

check_legacy_workspace:
  IfFileExists "$LOCALAPPDATA\TransVortex\Workspace\Tasks\*.*" use_legacy_workspace
  IfFileExists "$LOCALAPPDATA\TransVortex\Workspace\Cache\*.*" use_legacy_workspace
  Call ResolveInstallLayout
  StrCmp $ModernInstallLayout "1" 0 use_classic_install_workspace
  StrCpy $WorkspaceRoot "$ProductRoot\Data"
  Goto workspace_root_done

use_classic_install_workspace:
  ${GetParent} "$INSTDIR" $0
  StrCmp $0 "" use_profile_workspace
  StrCpy $WorkspaceRoot "$0\TransVortexData"
  Goto workspace_root_done

use_profile_workspace:
  StrCpy $WorkspaceRoot "$LOCALAPPDATA\TransVortex\Workspace"
  Goto workspace_root_done

use_legacy_workspace:
  StrCpy $WorkspaceRoot "$LOCALAPPDATA\TransVortex\Workspace"
  StrCpy $WorkspaceLocked "1"
  Goto workspace_root_done

check_workspace_content:
  IfFileExists "$WorkspaceRoot\Tasks\*.*" lock_workspace_root
  IfFileExists "$WorkspaceRoot\Cache\*.*" lock_workspace_root workspace_root_done

lock_workspace_root:
  StrCpy $WorkspaceLocked "1"

workspace_root_done:
FunctionEnd

Function WorkspacePageCreate
  !insertmacro MUI_HEADER_TEXT "确认最终存放位置" "任务资料和识别资源可能持续增长，请确认保存磁盘。"
  Call NormalizeInstallDirectory
  StrCpy $WorkspaceRoot ""
  Call ResolveWorkspaceRoot
  Call ResolveAsrStorageRoot
  nsDialogs::Create 1018
  Pop $WorkspaceDialog
  ${If} $WorkspaceDialog == error
    Abort
  ${EndIf}
  SetCtlColors $WorkspaceDialog "" "FAF8FC"

  ${NSD_CreateLabel} 0 0 100% 24u "安装器将按下面的最终路径落盘。配置和凭据仍保存在 Windows 用户目录。"
  Pop $0
  SetCtlColors $0 "2E2A33" "FAF8FC"

  ${NSD_CreateLabel} 0 28u 100% 12u "程序（升级时只替换这里）"
  Pop $0
  SetCtlColors $0 "2E2A33" "FAF8FC"
  ${NSD_CreateText} 0 41u 100% 13u "$INSTDIR"
  Pop $0
  EnableWindow $0 0

  ${NSD_CreateLabel} 0 60u 100% 12u "工作数据（任务、中间资料和恢复缓存）"
  Pop $0
  SetCtlColors $0 "2E2A33" "FAF8FC"
  ${NSD_CreateText} 0 73u 78% 13u "$WorkspaceRoot"
  Pop $WorkspacePathInput
  ${NSD_CreateButton} 80% 72u 20% 15u "浏览…"
  Pop $WorkspaceBrowseButton
  ${NSD_OnClick} $WorkspaceBrowseButton SelectWorkspaceDirectory

  ${NSD_CreateLabel} 0 92u 100% 12u "识别资源（运行组件、模型和下载断点）"
  Pop $0
  SetCtlColors $0 "2E2A33" "FAF8FC"
  ${NSD_CreateText} 0 105u 100% 13u "$AsrStorageRoot"
  Pop $0
  EnableWindow $0 0

  ${NSD_CreateLabel} 0 126u 100% 34u "程序升级不会删除工作数据或识别资源。工作数据安装后仍可在“应用设置”中安全迁移。"
  Pop $WorkspaceNoticeLabel
  SetCtlColors $WorkspaceNoticeLabel "5F5965" "FAF8FC"

  StrCmp $WorkspaceLocked "1" 0 show_workspace_dialog
  EnableWindow $WorkspacePathInput 0
  EnableWindow $WorkspaceBrowseButton 0
  ${NSD_SetText} $WorkspaceNoticeLabel "检测到已有任务或缓存，安装器将继续使用当前位置，不会在安装期间搬动数据。安装后可在“应用设置 → 工作数据”中查看占用、清理缓存或迁移位置。"

show_workspace_dialog:
  nsDialogs::Show
FunctionEnd

Function SelectWorkspaceDirectory
  ${NSD_GetText} $WorkspacePathInput $0
  nsDialogs::SelectFolderDialog "选择 TransVortex 工作数据文件夹" "$0"
  Pop $1
  StrCmp $1 "error" workspace_browse_done
  StrCmp $1 "" workspace_browse_done
  ${NSD_SetText} $WorkspacePathInput "$1"
workspace_browse_done:
FunctionEnd

Function ValidateWorkspaceRoot
  StrCmp $WorkspaceRoot "" workspace_invalid
  ${GetRoot} "$WorkspaceRoot" $0
  StrCmp $0 "" workspace_invalid
  System::Call 'kernel32::lstrcmpiW(w "$WorkspaceRoot", w "$0") i .r1'
  IntCmp $1 0 workspace_invalid
  System::Call 'kernel32::lstrcmpiW(w "$WorkspaceRoot", w "$INSTDIR") i .r1'
  IntCmp $1 0 workspace_inside_install
  System::Call 'shlwapi::PathIsPrefixW(w "$INSTDIR", w "$WorkspaceRoot") i .r1'
  IntCmp $1 0 workspace_valid workspace_inside_install workspace_inside_install

workspace_invalid:
  Abort "请选择一个专用的工作数据文件夹，不能直接使用磁盘根目录。"

workspace_inside_install:
  Abort "工作数据不能放在程序安装目录中；程序升级会整体替换该目录。请选择同级或其他位置。"

workspace_valid:
FunctionEnd

Function WorkspacePageLeave
  StrCmp $WorkspaceLocked "1" workspace_page_validate
  ${NSD_GetText} $WorkspacePathInput $WorkspaceRoot
workspace_page_validate:
  Call ValidateWorkspaceRoot
FunctionEnd

Function WriteWorkspaceConfig
  CreateDirectory "$WorkspaceRoot"
  IfErrors workspace_config_failed
  CreateDirectory "$LOCALAPPDATA\TransVortex\Config"
  IfErrors workspace_config_failed
  ClearErrors
  ExecWait '"$INSTDIR\runtime\python\pythonw.exe" -B -m transvortex.app.workspace_storage --config-root "$LOCALAPPDATA\TransVortex\Config" --workspace-root "$WorkspaceRoot"' $0
  IfErrors workspace_config_failed
  StrCmp $0 "0" workspace_config_ready workspace_config_failed

workspace_config_failed:
  Push "failed"
  Return

workspace_config_ready:
  WriteRegStr HKCU "${APP_REGISTRY_KEY}" "WorkspaceLocation" "$WorkspaceRoot"
  Push "ok"
FunctionEnd

Function ResolveAsrStorageRoot
  StrCpy $AsrStorageRoot ""
  Call ReadConfiguredAsrStorageRoot
  StrCmp $AsrStorageRoot "" 0 asr_storage_root_done
  ReadRegStr $AsrStorageRoot HKCU "${APP_REGISTRY_KEY}" "AsrStorageLocation"
  StrCmp $AsrStorageRoot "" check_legacy_asr_storage asr_storage_root_done

check_legacy_asr_storage:
  IfFileExists "$LOCALAPPDATA\TransVortex\Components\*.*" use_profile_asr_storage
  IfFileExists "$LOCALAPPDATA\TransVortex\Models\faster-whisper\*.*" use_profile_asr_storage
  IfFileExists "$LOCALAPPDATA\TransVortex\Downloads\ASR\*.*" use_profile_asr_storage
  Call ResolveInstallLayout
  StrCmp $ModernInstallLayout "1" 0 use_classic_install_asr_storage
  StrCpy $AsrStorageRoot "$ProductRoot\Resources"
  Goto asr_storage_root_done

use_classic_install_asr_storage:
  ${GetParent} "$INSTDIR" $0
  StrCmp $0 "" use_profile_asr_storage
  StrCpy $AsrStorageRoot "$0\TransVortexResources"
  Goto asr_storage_root_done

use_profile_asr_storage:
  StrCpy $AsrStorageRoot "$LOCALAPPDATA\TransVortex"

asr_storage_root_done:
FunctionEnd

Function ReadConfiguredAsrStorageRoot
  IfFileExists "$LOCALAPPDATA\TransVortex\Config\asr_storage.json" 0 configured_asr_storage_done
  IfFileExists "$INSTDIR\runtime\python\python.exe" 0 configured_asr_storage_done
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=resolve_asr_storage_config.py "${ASR_CONFIG_READER}"
  Delete "$PLUGINSDIR\asr-storage.ini"
  nsExec::Exec `"$INSTDIR\runtime\python\python.exe" -I -B "$PLUGINSDIR\resolve_asr_storage_config.py" --config-root "$LOCALAPPDATA\TransVortex\Config" --output-ini "$PLUGINSDIR\asr-storage.ini"`
  Pop $0
  StrCmp $0 "0" 0 configured_asr_storage_cleanup
  ReadINIStr $AsrStorageRoot "$PLUGINSDIR\asr-storage.ini" "Storage" "Root"

configured_asr_storage_cleanup:
  Delete "$PLUGINSDIR\asr-storage.ini"
  Delete "$PLUGINSDIR\resolve_asr_storage_config.py"

configured_asr_storage_done:
FunctionEnd

Function WriteAsrStorageConfig
  Call ResolveAsrStorageRoot
  StrCmp $AsrStorageRoot "" asr_storage_config_failed
  ClearErrors
  ExecWait '"$INSTDIR\runtime\python\pythonw.exe" -B -m transvortex.app.asr_storage --config-root "$LOCALAPPDATA\TransVortex\Config" --default-storage-root "$AsrStorageRoot"' $0
  IfErrors asr_storage_config_failed
  StrCmp $0 "0" asr_storage_config_ready asr_storage_config_failed

asr_storage_config_failed:
  Push "failed"
  Return

asr_storage_config_ready:
  Push "ok"
FunctionEnd

Function ValidateStagingPayload
  IfFileExists "$StagingDir\TransVortex.exe" +2
    Abort "安装内容不完整：缺少 TransVortex.exe"
  IfFileExists "$StagingDir\runtime\python\python.exe" +2
    Abort "安装内容不完整：缺少固定 Python runtime"
  IfFileExists "$StagingDir\runtime\python\pythonw.exe" +2
    Abort "安装内容不完整：缺少无窗口 Python runtime"
  IfFileExists "$StagingDir\runtime\app_runtime.json" +2
    Abort "安装内容不完整：缺少 Python runtime 清单"
  IfFileExists "$StagingDir\tools\ffmpeg\bin\ffmpeg.exe" +2
    Abort "安装内容不完整：缺少 ffmpeg.exe"
  IfFileExists "$StagingDir\tools\ffmpeg\bin\ffprobe.exe" +2
    Abort "安装内容不完整：缺少 ffprobe.exe"
  IfFileExists "$StagingDir\tools\ffmpeg\ffmpeg_runtime.json" +2
    Abort "安装内容不完整：缺少 FFmpeg runtime 清单"
  IfFileExists "$StagingDir\runtime\python\Lib\site-packages\transvortex\app\uninstall_cleanup.py" +2
    Abort "安装内容不完整：缺少卸载清理组件"
  IfFileExists "$StagingDir\runtime\python\Lib\site-packages\transvortex\app\workspace_storage.py" +2
    Abort "安装内容不完整：缺少工作区配置组件"
  IfFileExists "$StagingDir\runtime\python\Lib\site-packages\transvortex\app\asr_storage.py" +2
    Abort "安装内容不完整：缺少识别资源位置组件"
  IfFileExists "$StagingDir\runtime\python\Lib\site-packages\transvortex\app\agent_entry.py" +2
    Abort "安装内容不完整：缺少 Agent 入口组件"
  IfFileExists "$StagingDir\agent\README.md" +2
    Abort "安装内容不完整：缺少 Agent 文档入口"
  IfFileExists "$StagingDir\agent\AGENT_USAGE.md" +2
    Abort "安装内容不完整：缺少 Agent CLI 手册"
  IfFileExists "$StagingDir\agent\ADAPTATION_GUIDE.md" +2
    Abort "安装内容不完整：缺少 Agent 适配说明"
  IfFileExists "$StagingDir\agent\workflows\ASR_ENVIRONMENT_SETUP.md" +2
    Abort "安装内容不完整：缺少 ASR 环境准备说明"
  IfFileExists "$StagingDir\agent\references\setup_contract.schema.json" +2
    Abort "安装内容不完整：缺少 Agent setup contract schema"
  ReadINIStr $0 "$StagingDir\.transvortex-install.ini" "Install" "AppId"
  StrCmp $0 "${APP_ID}" +2
    Abort "安装内容不完整：缺少安装归属标记"
FunctionEnd

Function RollBackPayload
  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  RMDir /r "$INSTDIR"
  StrCmp $HadPreviousInstall "1" 0 rollback_done
  ClearErrors
  Rename "$PreviousDir" "$INSTDIR"
rollback_done:
  IfFileExists "$ShortcutBackup" 0 rollback_shortcut_done
    CopyFiles /SILENT "$ShortcutBackup" "$SMPROGRAMS\${APP_NAME}.lnk"
rollback_shortcut_done:
  Delete "$ShortcutBackup"
FunctionEnd

Section "${APP_NAME}" SecMain
  Call CheckAppNotRunning
  SetShellVarContext current
  SetDetailsPrint textonly
  DetailPrint "正在准备安全安装目录…"
  SetDetailsPrint none
  Call NormalizeInstallDirectory
  Call CheckInstallDirectorySafety
  Call ResolveWorkspaceRoot
  Call ValidateWorkspaceRoot
  StrCpy $StagingDir "$INSTDIR.__staging"
  StrCpy $PreviousDir "$INSTDIR.__previous"
  StrCpy $HadPreviousInstall "0"
  StrCpy $ShortcutBackup "$TEMP\TransVortex-installer-shortcut-backup.lnk"
  Delete "$ShortcutBackup"
  IfFileExists "$SMPROGRAMS\${APP_NAME}.lnk" 0 shortcut_backup_done
    CopyFiles /SILENT "$SMPROGRAMS\${APP_NAME}.lnk" "$ShortcutBackup"

shortcut_backup_done:

  IfFileExists "$INSTDIR\*.*" current_ready
  IfFileExists "$PreviousDir\*.*" 0 current_ready
    ClearErrors
    Rename "$PreviousDir" "$INSTDIR"

current_ready:
  RMDir /r "$StagingDir"
  CreateDirectory "$StagingDir"
  SetOutPath "$StagingDir"
  SetDetailsPrint textonly
  DetailPrint "正在安装程序与固定运行环境…"
  SetDetailsPrint none
  File /r "${APP_SOURCE}\*.*"
  WriteINIStr "$StagingDir\.transvortex-install.ini" "Install" "AppId" "${APP_ID}"
  WriteINIStr "$StagingDir\.transvortex-install.ini" "Install" "Version" "${APP_VERSION}"
  WriteUninstaller "$StagingDir\Uninstall.exe"
  SetDetailsPrint textonly
  DetailPrint "正在校验安装内容…"
  SetDetailsPrint none
  Call ValidateStagingPayload
  SetOutPath "$TEMP"

  IfFileExists "$INSTDIR\*.*" 0 no_current_install
    RMDir /r "$PreviousDir"
    ClearErrors
    Rename "$INSTDIR" "$PreviousDir"
    IfErrors swap_failed
    StrCpy $HadPreviousInstall "1"

no_current_install:
  ClearErrors
  Rename "$StagingDir" "$INSTDIR"
  IfErrors restore_after_swap_failure

  SetDetailsPrint textonly
  DetailPrint "正在准备工作数据位置…"
  SetDetailsPrint none
  Call WriteWorkspaceConfig
  Pop $0
  StrCmp $0 "ok" workspace_config_ready_after_swap
  Goto post_workspace_config_failed

workspace_config_ready_after_swap:

  SetDetailsPrint textonly
  DetailPrint "正在准备识别资源位置…"
  SetDetailsPrint none
  Call WriteAsrStorageConfig
  Pop $0
  StrCmp $0 "ok" asr_storage_config_ready_after_swap
  Goto post_asr_storage_config_failed

asr_storage_config_ready_after_swap:

  SetDetailsPrint textonly
  DetailPrint "正在创建开始菜单入口…"
  SetDetailsPrint none
  SetOutPath "$INSTDIR"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\TransVortex.exe" \
    "" "$INSTDIR\TransVortex.exe" 0 SW_SHOWNORMAL "" "${APP_NAME}"
  IfErrors post_swap_failed
  ExecWait '"$INSTDIR\TransVortex.exe" --set-shortcut-app-user-model-id "$SMPROGRAMS\${APP_NAME}.lnk"' $0
  ${If} $0 != 0
    Goto post_swap_failed
  ${EndIf}

  SetDetailsPrint textonly
  DetailPrint "正在登记 Agent / CLI 入口…"
  SetDetailsPrint none
  ClearErrors
  ExecWait '"$INSTDIR\runtime\python\pythonw.exe" -B -m transvortex.app.agent_entry register --install-root "$INSTDIR" --config-root "$LOCALAPPDATA\TransVortex\Config"' $0
  IfErrors post_agent_entry_failed
  ${If} $0 != 0
    Goto post_agent_entry_failed
  ${EndIf}

  WriteRegStr HKCU "${APP_REGISTRY_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\TransVortex.exe,0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" ${ESTIMATED_SIZE_KB}

  RMDir /r "$PreviousDir"
  Delete "$ShortcutBackup"
  SetDetailsPrint textonly
  DetailPrint "TransVortex 已准备好。"
  Goto install_complete

post_workspace_config_failed:
  Call RollBackPayload
  Abort "无法准备工作数据位置。请确认所选磁盘已连接且目录可写。已恢复此前安装。"

post_asr_storage_config_failed:
  Call RollBackPayload
  Abort "无法准备识别资源位置。请确认安装磁盘已连接且目录可写。已恢复此前安装。"

post_swap_failed:
  Call RollBackPayload
  Abort "无法创建带正确 Windows 应用身份的开始菜单快捷方式。已恢复此前安装。"

post_agent_entry_failed:
  StrCmp $HadPreviousInstall "1" agent_entry_failure_rollback
  Delete "$LOCALAPPDATA\TransVortex\Agent\current.json"
  Delete "$LOCALAPPDATA\TransVortex\Agent\README.md"
  RMDir "$LOCALAPPDATA\TransVortex\Agent"
agent_entry_failure_rollback:
  Call RollBackPayload
  Abort "无法登记 Agent / CLI 入口。已恢复此前安装。"

restore_after_swap_failure:
  StrCmp $HadPreviousInstall "1" 0 swap_failed
  ClearErrors
  Rename "$PreviousDir" "$INSTDIR"

swap_failed:
  RMDir /r "$StagingDir"
  Delete "$ShortcutBackup"
  Abort "无法替换安装目录。请确认目录没有被其他程序占用。"

install_complete:
SectionEnd

Function un.onInit
  StrCpy $CleanupRemoveAsr "0"
  StrCpy $CleanupRemoveSettings "0"
  StrCpy $CleanupRemoveTasks "0"
  StrCpy $CleanupRemoveCredentials "0"
  StrCpy $CleanupFailure "0"
  StrCpy $CleanupMessage ""
  IfSilent parse_cleanup_options interactive_cleanup_defaults

interactive_cleanup_defaults:
  ; Re-downloadable app-owned resources are selected by default.
  StrCpy $CleanupRemoveAsr "1"

parse_cleanup_options:
  ${un.GetParameters} $0
  ClearErrors
  ${un.GetOptions} "$0" "/REMOVEASR" $1
  IfErrors remove_asr_option_done
  StrCpy $CleanupRemoveAsr "1"
remove_asr_option_done:
  ClearErrors
  ${un.GetOptions} "$0" "/REMOVESETTINGS" $1
  IfErrors remove_settings_option_done
  StrCpy $CleanupRemoveSettings "1"
remove_settings_option_done:
  ClearErrors
  ${un.GetOptions} "$0" "/REMOVETASKS" $1
  IfErrors remove_tasks_option_done
  StrCpy $CleanupRemoveTasks "1"
remove_tasks_option_done:
  ClearErrors
  ${un.GetOptions} "$0" "/REMOVECREDENTIALS" $1
  IfErrors cleanup_options_done
  StrCpy $CleanupRemoveCredentials "1"
cleanup_options_done:
FunctionEnd

Function un.CleanupPageCreate
  !insertmacro MUI_HEADER_TEXT "选择保留或清理的本地内容" "外部模型和用户导出的文件永远不会被卸载器删除。"
  InitPluginsDir
  StrCpy $CleanupReport "$PLUGINSDIR\transvortex-uninstall-inspection.ini"
  Delete "$CleanupReport"
  StrCpy $1 "$LOCALAPPDATA\TransVortex"
  StrCpy $2 "无法估算"
  StrCpy $3 "0"
  StrCpy $4 "0"
  StrCpy $5 "0"
  StrCpy $6 "0 B"
  StrCpy $7 "0"
  StrCpy $8 ""
  IfFileExists "$INSTDIR\runtime\python\pythonw.exe" 0 cleanup_inspection_unavailable

  ExecWait '"$INSTDIR\runtime\python\pythonw.exe" -B -m transvortex.app.uninstall_cleanup --inspect --app-data-root "$LOCALAPPDATA\TransVortex" --credential-file "$PROFILE\.transvortex\auth.json" --report-ini "$CleanupReport"' $0
  IfFileExists "$CleanupReport" 0 cleanup_inspection_unavailable
  ReadINIStr $1 "$CleanupReport" "Summary" "asr_root"
  ReadINIStr $2 "$CleanupReport" "Summary" "asr_size"
  ReadINIStr $3 "$CleanupReport" "Summary" "asr_present"
  ReadINIStr $4 "$CleanupReport" "Summary" "settings_present"
  ReadINIStr $5 "$CleanupReport" "Summary" "tasks_present"
  ReadINIStr $6 "$CleanupReport" "Summary" "task_size"
  ReadINIStr $7 "$CleanupReport" "Summary" "credentials_present"
  ReadINIStr $8 "$CleanupReport" "Summary" "message"
  Goto cleanup_inspection_ready

cleanup_inspection_unavailable:
  StrCpy $CleanupRemoveAsr "0"
  StrCpy $CleanupRemoveSettings "0"
  StrCpy $CleanupRemoveTasks "0"
  StrCpy $CleanupRemoveCredentials "0"
  StrCpy $8 "无法检查本地内容；卸载器将只移除程序。"

cleanup_inspection_ready:
  nsDialogs::Create 1018
  Pop $CleanupDialog
  ${If} $CleanupDialog == error
    Abort
  ${EndIf}
  SetCtlColors $CleanupDialog "" "FAF8FC"

  ${NSD_CreateLabel} 0 0 100% 18u "选择需要随程序一起移除的内容。下载资源默认清理，设置、任务和凭据默认保留。"
  Pop $0
  SetCtlColors $0 "2E2A33" "FAF8FC"

  ${NSD_CreateCheckbox} 0 24u 100% 12u "删除已下载的语音识别资源（约 $2）"
  Pop $CleanupAsrCheckbox
  SetCtlColors $CleanupAsrCheckbox "2E2A33" "FAF8FC"
  ${NSD_CreateLabel} 16u 38u 94% 16u "识别资源位置：$1"
  Pop $CleanupAsrRootLabel
  SetCtlColors $CleanupAsrRootLabel "6F6573" "FAF8FC"

  ${NSD_CreateCheckbox} 0 58u 100% 12u "删除应用设置与识别登记状态"
  Pop $CleanupSettingsCheckbox
  SetCtlColors $CleanupSettingsCheckbox "2E2A33" "FAF8FC"
  ${NSD_CreateCheckbox} 0 80u 100% 12u "删除任务工作区与恢复缓存（约 $6，不可撤销）"
  Pop $CleanupTasksCheckbox
  SetCtlColors $CleanupTasksCheckbox "2E2A33" "FAF8FC"
  ${NSD_CreateCheckbox} 0 102u 100% 12u "删除保存的服务凭据"
  Pop $CleanupCredentialsCheckbox
  SetCtlColors $CleanupCredentialsCheckbox "2E2A33" "FAF8FC"

  ${NSD_CreateLabel} 0 124u 100% 18u "用户自行添加的模型、原始媒体和已导出的字幕不会被删除。"
  Pop $0
  SetCtlColors $0 "6F6573" "FAF8FC"
  ${NSD_CreateLabel} 0 146u 100% 20u "$8"
  Pop $CleanupNoticeLabel
  SetCtlColors $CleanupNoticeLabel "D74F3E" "FAF8FC"

  StrCmp $3 "1" asr_cleanup_available asr_cleanup_unavailable
asr_cleanup_available:
  StrCmp $CleanupRemoveAsr "1" 0 +2
  ${NSD_Check} $CleanupAsrCheckbox
  Goto settings_cleanup_state
asr_cleanup_unavailable:
  StrCpy $CleanupRemoveAsr "0"
  ${NSD_Uncheck} $CleanupAsrCheckbox
  EnableWindow $CleanupAsrCheckbox 0

settings_cleanup_state:
  StrCmp $4 "1" settings_cleanup_available settings_cleanup_unavailable
settings_cleanup_available:
  StrCmp $CleanupRemoveSettings "1" 0 +2
  ${NSD_Check} $CleanupSettingsCheckbox
  Goto tasks_cleanup_state
settings_cleanup_unavailable:
  StrCpy $CleanupRemoveSettings "0"
  ${NSD_Uncheck} $CleanupSettingsCheckbox
  EnableWindow $CleanupSettingsCheckbox 0

tasks_cleanup_state:
  StrCmp $5 "1" tasks_cleanup_available tasks_cleanup_unavailable
tasks_cleanup_available:
  StrCmp $CleanupRemoveTasks "1" 0 +2
  ${NSD_Check} $CleanupTasksCheckbox
  Goto credentials_cleanup_state
tasks_cleanup_unavailable:
  StrCpy $CleanupRemoveTasks "0"
  ${NSD_Uncheck} $CleanupTasksCheckbox
  EnableWindow $CleanupTasksCheckbox 0

credentials_cleanup_state:
  StrCmp $7 "1" credentials_cleanup_available credentials_cleanup_unavailable
credentials_cleanup_available:
  StrCmp $CleanupRemoveCredentials "1" 0 +2
  ${NSD_Check} $CleanupCredentialsCheckbox
  Goto show_cleanup_dialog
credentials_cleanup_unavailable:
  StrCpy $CleanupRemoveCredentials "0"
  ${NSD_Uncheck} $CleanupCredentialsCheckbox
  EnableWindow $CleanupCredentialsCheckbox 0

show_cleanup_dialog:
  nsDialogs::Show
FunctionEnd

Function un.CleanupPageLeave
  ${NSD_GetState} $CleanupAsrCheckbox $0
  StrCpy $CleanupRemoveAsr "0"
  StrCmp $0 ${BST_CHECKED} 0 +2
  StrCpy $CleanupRemoveAsr "1"
  ${NSD_GetState} $CleanupSettingsCheckbox $0
  StrCpy $CleanupRemoveSettings "0"
  StrCmp $0 ${BST_CHECKED} 0 +2
  StrCpy $CleanupRemoveSettings "1"
  ${NSD_GetState} $CleanupTasksCheckbox $0
  StrCpy $CleanupRemoveTasks "0"
  StrCmp $0 ${BST_CHECKED} 0 +2
  StrCpy $CleanupRemoveTasks "1"
  ${NSD_GetState} $CleanupCredentialsCheckbox $0
  StrCpy $CleanupRemoveCredentials "0"
  StrCmp $0 ${BST_CHECKED} 0 +2
  StrCpy $CleanupRemoveCredentials "1"

  StrCmp $CleanupRemoveTasks "1" confirm_sensitive_cleanup
  StrCmp $CleanupRemoveCredentials "1" confirm_sensitive_cleanup cleanup_page_done
confirm_sensitive_cleanup:
  MessageBox MB_YESNO|MB_ICONEXCLAMATION \
    "任务工作区或凭据一旦删除将无法通过重新安装恢复。确定继续吗？" \
    IDYES cleanup_page_done
  Abort
cleanup_page_done:
FunctionEnd

Function un.CheckAppNotRunning
un_check_again:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX}") p .r0'
  IntPtrCmp $0 0 un_not_running
  System::Call 'kernel32::CloseHandle(p r0)'
  IfSilent un_silent_running un_interactive_running

un_interactive_running:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
    "TransVortex 正在运行。请先关闭应用，再点击“重试”。" \
    IDRETRY un_check_again IDCANCEL un_cancel

un_silent_running:
  SetErrorLevel 10
  Quit

un_cancel:
  Abort

un_not_running:
FunctionEnd

Function un.RunSelectedCleanup
  StrCmp $CleanupRemoveAsr "1" run_selected_cleanup
  StrCmp $CleanupRemoveSettings "1" run_selected_cleanup
  StrCmp $CleanupRemoveTasks "1" run_selected_cleanup
  StrCmp $CleanupRemoveCredentials "1" run_selected_cleanup cleanup_not_requested

run_selected_cleanup:
  SetDetailsPrint textonly
  DetailPrint "正在清理所选本地内容…"
  SetDetailsPrint none
  IfFileExists "$INSTDIR\runtime\python\pythonw.exe" cleanup_helper_ready cleanup_helper_missing

cleanup_helper_ready:
  InitPluginsDir
  StrCpy $CleanupReport "$PLUGINSDIR\transvortex-uninstall-cleanup.ini"
  Delete "$CleanupReport"
  StrCpy $CleanupArgs '--app-data-root "$LOCALAPPDATA\TransVortex" --credential-file "$PROFILE\.transvortex\auth.json" --report-ini "$CleanupReport"'
  StrCmp $CleanupRemoveAsr "1" 0 +2
  StrCpy $CleanupArgs '$CleanupArgs --remove-asr-resources'
  StrCmp $CleanupRemoveSettings "1" 0 +2
  StrCpy $CleanupArgs '$CleanupArgs --remove-settings'
  StrCmp $CleanupRemoveTasks "1" 0 +2
  StrCpy $CleanupArgs '$CleanupArgs --remove-tasks'
  StrCmp $CleanupRemoveCredentials "1" 0 +2
  StrCpy $CleanupArgs '$CleanupArgs --remove-credentials'
  ClearErrors
  ExecWait '"$INSTDIR\runtime\python\pythonw.exe" -B -m transvortex.app.uninstall_cleanup $CleanupArgs' $0
  IfErrors cleanup_failed
  IfFileExists "$CleanupReport" 0 cleanup_failed
  ReadINIStr $CleanupMessage "$CleanupReport" "Summary" "message"
  StrCmp $0 "0" cleanup_succeeded cleanup_failed

cleanup_succeeded:
  StrCmp $CleanupMessage "" cleanup_done
  IfSilent cleanup_done
  MessageBox MB_OK|MB_ICONEXCLAMATION "$CleanupMessage"
  Goto cleanup_done

cleanup_helper_missing:
  StrCpy $CleanupMessage "卸载清理组件缺失，所选本地内容可能仍保留。"
  Goto cleanup_failed_message

cleanup_failed:
  StrCmp $CleanupMessage "" 0 cleanup_failed_message
  ReadINIStr $CleanupMessage "$CleanupReport" "Summary" "message"
  StrCmp $CleanupMessage "" 0 cleanup_failed_message
  StrCpy $CleanupMessage "无法完成所选本地内容的清理。程序仍会继续卸载。"

cleanup_failed_message:
  StrCpy $CleanupFailure "1"
  IfSilent cleanup_done
  MessageBox MB_OK|MB_ICONEXCLAMATION "$CleanupMessage"
  Goto cleanup_done

cleanup_not_requested:
  SetDetailsPrint textonly
  DetailPrint "正在保留用户配置与本地内容…"
  SetDetailsPrint none

cleanup_done:
FunctionEnd

Section "Uninstall"
  Call un.CheckAppNotRunning
  SetShellVarContext current
  Call un.RunSelectedCleanup
  SetDetailsPrint textonly
  DetailPrint "正在移除 TransVortex 程序…"
  SetDetailsPrint none
  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegValue HKCU "${APP_REGISTRY_KEY}" "InstallLocation"
  StrCmp $CleanupRemoveTasks "1" 0 preserve_workspace_location
  DeleteRegValue HKCU "${APP_REGISTRY_KEY}" "WorkspaceLocation"
preserve_workspace_location:
  StrCmp $CleanupRemoveAsr "1" 0 preserve_asr_storage_location
  StrCmp $CleanupRemoveSettings "1" 0 preserve_asr_storage_location
  DeleteRegValue HKCU "${APP_REGISTRY_KEY}" "AsrStorageLocation"
preserve_asr_storage_location:
  DeleteRegKey /ifempty HKCU "${APP_REGISTRY_KEY}"
  Delete "$LOCALAPPDATA\TransVortex\Agent\current.json"
  Delete "$LOCALAPPDATA\TransVortex\Agent\README.md"
  RMDir "$LOCALAPPDATA\TransVortex\Agent"
  RMDir /r "$INSTDIR"
  RMDir /r "$INSTDIR.__staging"
  RMDir /r "$INSTDIR.__previous"
  StrCmp $CleanupFailure "1" 0 uninstall_complete
  SetErrorLevel 20
uninstall_complete:
  SetDetailsPrint textonly
  DetailPrint "TransVortex 程序已移除。"
SectionEnd
