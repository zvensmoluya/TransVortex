from __future__ import annotations

from pathlib import Path

import yaml


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


def test_installer_confirmation_recomputes_the_normalized_product_layout() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )
    page_start = installer.index("Function WorkspacePageCreate")
    page_end = installer.index("FunctionEnd", page_start)
    page = installer[page_start:page_end]

    assert page.index("Call NormalizeInstallDirectory") < page.index(
        "Call ResolveWorkspaceRoot"
    )
    assert page.index('StrCpy $WorkspaceRoot ""') < page.index(
        "Call ResolveWorkspaceRoot"
    )


def test_installer_directory_page_exposes_product_root_instead_of_app_root() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )
    prepare_start = installer.index("Function DirectoryPagePrepare")
    prepare_end = installer.index("FunctionEnd", prepare_start)
    prepare = installer[prepare_start:prepare_end]
    leave_start = installer.index("Function DirectoryPageLeave")
    leave_end = installer.index("FunctionEnd", leave_start)
    leave = installer[leave_start:leave_end]

    assert '!define MUI_DIRECTORYPAGE_TEXT_DESTINATION "TransVortex 产品根目录"' in installer
    assert "!define MUI_DIRECTORYPAGE_VARIABLE $ProductRoot" in installer
    assert "!define MUI_PAGE_CUSTOMFUNCTION_PRE DirectoryPagePrepare" in installer
    assert prepare.index("Call ResolveInstallLayout") < prepare.index(
        'StrCpy $ProductRoot "$INSTDIR"'
    )
    assert leave.index('StrCpy $INSTDIR "$ProductRoot"') < leave.index(
        "Call NormalizeInstallDirectory"
    )


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


def test_installer_prefers_authoritative_asr_config_over_registry_hint() -> None:
    installer = (ROOT / "installer" / "windows" / "TransVortex.nsi").read_text(
        encoding="utf-8"
    )
    resolver_start = installer.index("Function ResolveAsrStorageRoot")
    resolver_end = installer.index("FunctionEnd", resolver_start)
    resolver = installer[resolver_start:resolver_end]
    reader_start = installer.index("Function ReadConfiguredAsrStorageRoot")
    reader_end = installer.index("FunctionEnd", reader_start)
    reader = installer[reader_start:reader_end]
    build_script = (
        ROOT / "scripts" / "build_windows_installer.ps1"
    ).read_text(encoding="utf-8")

    assert resolver.index("Call ReadConfiguredAsrStorageRoot") < resolver.index(
        'ReadRegStr $AsrStorageRoot HKCU "${APP_REGISTRY_KEY}" "AsrStorageLocation"'
    )
    assert 'IfFileExists "$INSTDIR\\runtime\\python\\python.exe"' in reader
    assert 'File /oname=resolve_asr_storage_config.py "${ASR_CONFIG_READER}"' in reader
    assert "nsExec::Exec" in reader
    assert 'ReadINIStr $AsrStorageRoot "$PLUGINSDIR\\asr-storage.ini"' in reader
    assert '"/DASR_CONFIG_READER=$asrConfigReaderPath"' in build_script


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


def test_release_pipeline_requires_the_agent_client_runtime_module() -> None:
    packaging = (ROOT / "scripts" / "package_flutter_release.ps1").read_text(
        encoding="utf-8"
    )

    assert '"python\\Lib\\site-packages\\transvortex\\app\\agent_client.py"' in packaging
    assert (
        '"runtime\\python\\Lib\\site-packages\\transvortex\\app\\agent_client.py"'
        in packaging
    )


def test_release_packages_an_empty_provider_seed_and_a_neutral_example() -> None:
    product_seed = yaml.safe_load(
        (ROOT / "providers.desktop.yaml").read_text(encoding="utf-8")
    )
    example = (ROOT / "providers.example.yaml").read_text(encoding="utf-8")
    packaging = (ROOT / "scripts" / "package_flutter_release.ps1").read_text(
        encoding="utf-8"
    )

    assert product_seed == {"providers": []}
    assert "gateway.example.invalid" in example
    assert (
        'Copy-RequiredFile -Source (Join-Path $repoRoot "providers.desktop.yaml") '
        '-Destination (Join-Path $packageRoot "providers.yaml")'
    ) in packaging
    assert 'providers_yaml_source = "providers.desktop.yaml"' in packaging
    assert "function Test-PackagedProviderSeed" in packaging
    assert "Portable product seed must contain zero provider connections" in packaging
    assert "provider_connection_count = $providerSeedReport.provider_connection_count" in packaging


def test_installer_acceptance_checks_new_default_storage_layout() -> None:
    acceptance = (ROOT / "scripts" / "accept_windows_installer.ps1").read_text(
        encoding="utf-8"
    )

    assert '$workspaceRoot = Join-Path $productRoot "Data"' in acceptance
    assert '$asrStorageRoot = Join-Path $productRoot "Resources"' in acceptance
    assert '$InstallRoot = Join-Path $acceptanceRoot "TransVortex"' in acceptance
    assert "Installed workspace does not match the product Data directory." in acceptance
    assert "Default ASR storage does not match the product Resources directory." in acceptance
    assert '"explicit_product_data_due_to_legacy_workspace"' in acceptance
    assert "clean_profile_default_workspace_exercised" in acceptance


def test_installer_acceptance_restores_preexisting_config_state() -> None:
    acceptance = (ROOT / "scripts" / "accept_windows_installer.ps1").read_text(
        encoding="utf-8"
    )

    assert "function Restore-ConfigState" in acceptance
    assert 'Join-Path $configRoot "workspace_storage.json"' in acceptance
    assert 'Join-Path $configRoot "asr_storage.json"' in acceptance
    assert "preexisting_config_restored = $true" in acceptance
    suspend_start = acceptance.index("$configSnapshotReady = $true")
    install_start = acceptance.index("New-Item -ItemType Directory -Force -Path $unsafeTarget")
    assert (
        acceptance.index(
            "Remove-Item -LiteralPath $snapshot.Path -Force",
            suspend_start,
        )
        < install_start
    )
