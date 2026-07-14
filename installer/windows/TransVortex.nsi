Unicode True
RequestExecutionLevel user
ManifestDPIAware true
ManifestSupportedOS all
CRCCheck force
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef APP_SOURCE
  !error "APP_SOURCE must point to the validated installer payload"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE must point to the installer executable"
!endif
!ifndef APP_VERSION
  !define APP_VERSION "1.0.0"
!endif
!ifndef APP_FILE_VERSION
  !define APP_FILE_VERSION "1.0.0.1"
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

!define APP_NAME "TransVortex"
!define APP_PUBLISHER "TransVortex Contributors"
!define APP_ID "TransVortex"
!define APP_MUTEX "Local\TransVortex.Desktop.89E122A8-7AB7-4D0F-9661-0EC5A881F65B"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
!define APP_REGISTRY_KEY "Software\TransVortex"

Name "${APP_NAME}"
Caption "${APP_NAME} 安装程序"
BrandingText "${APP_NAME} ${APP_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\TransVortex"
InstallDirRegKey HKCU "${APP_REGISTRY_KEY}" "InstallLocation"
Icon "${APP_ICON}"
UninstallIcon "${APP_ICON}"
AllowRootDirInstall false
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 用户级安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Apache-2.0 licensed"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\TransVortex.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动 TransVortex"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Var StagingDir
Var PreviousDir
Var HadPreviousInstall
Var ShortcutBackup

Function CheckAppNotRunning
check_again:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX}") p .r0'
  IntPtrCmp $0 0 not_running
  System::Call 'kernel32::CloseHandle(p r0)'
  IfSilent silent_running interactive_running

interactive_running:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
    "TransVortex 正在运行。请先关闭应用，再点击“重试”。" \
    IDRETRY check_again IDCANCEL cancel_install

silent_running:
  SetErrorLevel 10
  Quit

cancel_install:
  Abort

not_running:
FunctionEnd

Function ValidateStagingPayload
  IfFileExists "$StagingDir\TransVortex.exe" +2
    Abort "安装内容不完整：缺少 TransVortex.exe"
  IfFileExists "$StagingDir\runtime\python\python.exe" +2
    Abort "安装内容不完整：缺少固定 Python runtime"
  IfFileExists "$StagingDir\runtime\app_runtime.json" +2
    Abort "安装内容不完整：缺少 Python runtime 清单"
  IfFileExists "$StagingDir\tools\ffmpeg\bin\ffmpeg.exe" +2
    Abort "安装内容不完整：缺少 ffmpeg.exe"
  IfFileExists "$StagingDir\tools\ffmpeg\bin\ffprobe.exe" +2
    Abort "安装内容不完整：缺少 ffprobe.exe"
  IfFileExists "$StagingDir\tools\ffmpeg\ffmpeg_runtime.json" +2
    Abort "安装内容不完整：缺少 FFmpeg runtime 清单"
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
  File /r "${APP_SOURCE}\*.*"
  WriteUninstaller "$StagingDir\Uninstall.exe"
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

  SetOutPath "$INSTDIR"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\TransVortex.exe" \
    "" "$INSTDIR\TransVortex.exe" 0 SW_SHOWNORMAL "" "${APP_NAME}"
  IfErrors post_swap_failed
  ExecWait '"$INSTDIR\TransVortex.exe" --set-shortcut-app-user-model-id "$SMPROGRAMS\${APP_NAME}.lnk"' $0
  ${If} $0 != 0
    Goto post_swap_failed
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
  Goto install_complete

post_swap_failed:
  Call RollBackPayload
  Abort "无法创建带正确 Windows 应用身份的开始菜单快捷方式。已恢复此前安装。"

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

Section "Uninstall"
  Call un.CheckAppNotRunning
  SetShellVarContext current
  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "${APP_REGISTRY_KEY}"
  RMDir /r "$INSTDIR"
  RMDir /r "$INSTDIR.__staging"
  RMDir /r "$INSTDIR.__previous"
SectionEnd
