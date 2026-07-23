from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_gui_maintenance_uses_windowless_python() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert 'runtime\\python\\python.exe" -B -m' not in installer
    assert installer.count('ExecWait \'"$INSTDIR\\runtime\\python\\pythonw.exe"') == 4
    assert "-m transvortex.app.workspace_storage" in installer
    assert "-m transvortex.app.asr_storage" in installer
    assert installer.count("-m transvortex.app.uninstall_cleanup") == 2


def test_installer_keeps_asr_resources_next_to_the_selected_install_drive() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )

    assert '${GetParent} "$INSTDIR"' in installer
    assert 'StrCpy $AsrStorageRoot "$0\\TransVortexResources"' in installer
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
