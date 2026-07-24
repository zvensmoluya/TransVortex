from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_gui_maintenance_uses_windowless_python() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert 'runtime\\python\\python.exe" -B -m' not in installer
    assert installer.count('ExecWait \'"$INSTDIR\\runtime\\python\\pythonw.exe"') == 5
    assert "-m transvortex.app.workspace_storage" in installer
    assert "-m transvortex.app.asr_storage" in installer
    assert "-m transvortex.app.agent_entry register" in installer
    assert installer.count("-m transvortex.app.uninstall_cleanup") == 2


def test_installer_registers_and_removes_only_owned_agent_locator_files() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert '"$LOCALAPPDATA\\TransVortex\\Agent\\current.json"' in installer
    assert '"$LOCALAPPDATA\\TransVortex\\Agent\\README.md"' in installer
    assert 'RMDir "$LOCALAPPDATA\\TransVortex\\Agent"' in installer
    assert 'RMDir /r "$LOCALAPPDATA\\TransVortex\\Agent"' not in installer
    assert 'agent\\workflows\\ASR_ENVIRONMENT_SETUP.md' in installer


def test_installer_uses_isolated_app_data_and_resource_directories() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert 'StrCpy $INSTDIR "$INSTDIR\\App"' in installer
    assert 'StrCpy $WorkspaceRoot "$ProductRoot\\Data"' in installer
    assert 'StrCpy $AsrStorageRoot "$ProductRoot\\Resources"' in installer
    assert '程序（升级时只替换这里）' in installer
    assert '工作数据（任务、中间资料和恢复缓存）' in installer
    assert '识别资源（运行组件、模型和下载断点）' in installer


def test_installer_preserves_classic_storage_defaults_for_existing_layouts() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert 'StrCpy $WorkspaceRoot "$0\\TransVortexData"' in installer
    assert 'StrCpy $AsrStorageRoot "$0\\TransVortexResources"' in installer
    assert 'ReadRegStr $0 HKCU "${APP_REGISTRY_KEY}" "InstallLocation"' in installer
    assert 'IntCmp $1 0 normalize_done normalize_leaf normalize_leaf' in installer
    assert '"AsrStorageLocation"' in installer
    assert "preserve_asr_storage_location:" in installer


def test_uninstaller_credential_copy_matches_shipped_product() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert '"删除保存的服务凭据"' in installer
    assert "CLI / Agent" not in installer


def test_release_pipeline_requires_windowless_python() -> None:
    required_in = (
        "scripts/build_app_runtime.ps1",
        "scripts/package_flutter_release.ps1",
        "scripts/build_windows_installer.ps1",
        "scripts/accept_windows_installer.ps1",
    )

    for relative_path in required_in:
        content = (ROOT / relative_path).read_text(encoding="utf-8")
        assert "pythonw.exe" in content, relative_path


def test_installer_acceptance_checks_new_default_storage_layout() -> None:
    acceptance = (ROOT / "scripts" / "accept_windows_installer.ps1").read_text(
        encoding="utf-8"
    )

    assert '$workspaceRoot = Join-Path $productRoot "Data"' in acceptance
    assert '$asrStorageRoot = Join-Path $productRoot "Resources"' in acceptance
    assert "Default workspace does not match the product Data directory." in acceptance
    assert "Default ASR storage does not match the product Resources directory." in acceptance
