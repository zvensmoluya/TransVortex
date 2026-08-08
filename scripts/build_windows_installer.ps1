param(
    [string]$OutputRoot = "",
    [string]$AppRuntimeRoot = "",
    [string]$FfmpegRuntimeRoot = "",
    [string]$MakensisPath = "",
    [string]$CertificateThumbprint = "",
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [string]$CorrespondingSourceUrl = "",
    [switch]$Build,
    [switch]$BuildAppRuntime,
    [switch]$BuildFfmpegRuntime,
    [switch]$AllowUnsigned,
    [switch]$ReleaseCandidate,
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Assert-PathInsideDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $fullPath = Get-FullPath -Path $Path
    $fullDirectory = Get-FullPath -Path $Directory
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $fullPath"
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Resolve-Makensis {
    param(
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $command = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} "NSIS\makensis.exe"),
        (Join-Path $env:ProgramFiles "NSIS\makensis.exe")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "NSIS makensis.exe was not found. Install NSIS 3.x on the build machine or pass -MakensisPath."
}

function Resolve-SignTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    $kitsBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kitsBin) {
        $matches = @(
            Get-ChildItem -LiteralPath $kitsBin -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" } |
                Where-Object { Test-Path -LiteralPath $_ }
        )
        if ($matches.Count -gt 0) {
            return $matches[0]
        }
    }
    throw "signtool.exe was not found, but a signing certificate was requested."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pubspecPath = Join-Path $repoRoot "desktop_flutter\pubspec.yaml"
$pubspecVersionLine = Get-Content -LiteralPath $pubspecPath -Encoding utf8 |
    Where-Object { $_ -match '^version:\s*' } |
    Select-Object -First 1
if ($pubspecVersionLine -notmatch '^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$') {
    throw "desktop_flutter/pubspec.yaml must use a numeric major.minor.patch+build version."
}
$appVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
$appFileVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
$releaseStage = "alpha"
$releaseChannel = if ($ReleaseCandidate -or -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) { "candidate" } else { "internal" }
if ([string]::IsNullOrWhiteSpace($CertificateThumbprint) -and -not $AllowUnsigned) {
    throw "No signing certificate was provided. Pass -AllowUnsigned to explicitly accept an unsigned installer; add -ReleaseCandidate when building the first public release candidate."
}
$unsignedReleaseAcknowledged = (
    [string]::IsNullOrWhiteSpace($CertificateThumbprint) -and
    [bool]$AllowUnsigned
)

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\installer\windows"
}
$outputFullPath = Get-FullPath -Path $OutputRoot
New-Item -ItemType Directory -Force -Path $outputFullPath | Out-Null
$workRoot = Join-Path $outputFullPath "work"
$payloadName = "TransVortex-installer-payload-$appVersion"
$payloadRoot = Join-Path $workRoot $payloadName
$artifactBaseName = "TransVortex-$appVersion-windows-x64-setup-$releaseChannel"
$installerPath = Join-Path $outputFullPath "$artifactBaseName.exe"
$installerManifestPath = Join-Path $outputFullPath "$artifactBaseName.manifest.json"
Assert-PathInsideDirectory -Path $workRoot -Directory $outputFullPath
Assert-PathInsideDirectory -Path $installerPath -Directory $outputFullPath

foreach ($generatedPath in @($installerPath, $installerManifestPath)) {
    if (Test-Path -LiteralPath $generatedPath) {
        if (-not $Force) {
            throw "Installer output already exists: $generatedPath. Pass -Force to replace it."
        }
        Remove-Item -LiteralPath $generatedPath -Force
    }
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$packageArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "package_flutter_release.ps1"),
    "-OutputRoot", $workRoot,
    "-PackageName", $payloadName,
    "-InstallerPayload",
    "-NoZip",
    "-Force"
)
if (-not [string]::IsNullOrWhiteSpace($AppRuntimeRoot)) {
    $packageArgs += @("-AppRuntimeRoot", $AppRuntimeRoot)
}
if (-not [string]::IsNullOrWhiteSpace($FfmpegRuntimeRoot)) {
    $packageArgs += @("-FfmpegRuntimeRoot", $FfmpegRuntimeRoot)
}
if ($Build) {
    $packageArgs += "-Build"
}
if ($BuildAppRuntime) {
    $packageArgs += "-BuildAppRuntime"
}
if ($BuildFfmpegRuntime) {
    $packageArgs += "-BuildFfmpegRuntime"
}
& powershell @packageArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Installer payload build failed with exit code $LASTEXITCODE"
}

$payloadManifestPath = Join-Path $payloadRoot "installer_payload_manifest.json"
if (-not (Test-Path -LiteralPath $payloadManifestPath)) {
    throw "Installer payload manifest not found: $payloadManifestPath"
}
$payloadManifest = Get-Content -LiteralPath $payloadManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
if ($payloadManifest.package_type -ne "installer_payload" -or -not [bool]$payloadManifest.ffmpeg_included) {
    throw "Installer payload manifest does not describe the required fixed runtime layout."
}
$payloadFfmpegManifestPath = Join-Path $payloadRoot "tools\ffmpeg\ffmpeg_runtime.json"
if (-not (Test-Path -LiteralPath $payloadFfmpegManifestPath)) {
    throw "Installer payload is missing its FFmpeg runtime manifest."
}
$payloadFfmpegManifest = Get-Content -LiteralPath $payloadFfmpegManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
$packagedCorrespondingSourceUrl = [string]$payloadFfmpegManifest.corresponding_source.url
$packagedCorrespondingSourceSha256 = [string]$payloadFfmpegManifest.corresponding_source.sha256
$packagedCorrespondingSourceSize = [int64]$payloadFfmpegManifest.corresponding_source.size
$packagedCorrespondingSourceScope = [string]$payloadFfmpegManifest.corresponding_source.scope
$packagedCorrespondingSourceAssetsPublished = [bool]$payloadFfmpegManifest.corresponding_source.assets_published
$packagedBuildInputScopeComplete = [bool]$payloadFfmpegManifest.corresponding_source.build_input_scope_complete
$packagedExternalLibrarySourcesIncluded = [bool]$payloadFfmpegManifest.corresponding_source.external_library_sources_included
$packagedLicenseReviewComplete = [bool]$payloadFfmpegManifest.corresponding_source.license_review_complete
$packagedCorrespondingSourceRecorded = (
    -not [string]::IsNullOrWhiteSpace($packagedCorrespondingSourceUrl) -and
    $packagedCorrespondingSourceSha256 -match '^[0-9a-f]{64}$' -and
    $packagedCorrespondingSourceSize -gt 0 -and
    -not [string]::IsNullOrWhiteSpace($packagedCorrespondingSourceScope)
)
if (-not $packagedCorrespondingSourceRecorded) {
    throw "Installer payload has no valid FFmpeg source-bundle record."
}
if ([bool]$payloadFfmpegManifest.public_distribution_source_ready -and -not $packagedExternalLibrarySourcesIncluded) {
    throw "Installer payload claims FFmpeg public source readiness without external library sources."
}
if ([bool]$payloadFfmpegManifest.public_distribution_source_ready -and $packagedCorrespondingSourceScope -eq "ffmpeg-core-and-build-scripts") {
    throw "Installer payload still has a traceability-only FFmpeg source scope but claims public readiness."
}
if ([bool]$payloadFfmpegManifest.public_distribution_source_ready -and
    (-not $packagedCorrespondingSourceAssetsPublished -or
        -not $packagedBuildInputScopeComplete -or
        -not $packagedLicenseReviewComplete)) {
    throw "Installer payload claims FFmpeg public readiness without published source assets, complete build inputs, and license review."
}
$packagedFfmpegPublicDistributionReady = (
    $packagedCorrespondingSourceRecorded -and
    [bool]$payloadFfmpegManifest.public_distribution_source_ready
)
if ([string]::IsNullOrWhiteSpace($CorrespondingSourceUrl)) {
    $CorrespondingSourceUrl = $packagedCorrespondingSourceUrl
} elseif ($CorrespondingSourceUrl -ne $packagedCorrespondingSourceUrl) {
    throw "CorrespondingSourceUrl does not match the source bundle pinned by the packaged FFmpeg runtime."
}
$windowlessPython = Join-Path $payloadRoot "runtime\python\pythonw.exe"
if (-not (Test-Path -LiteralPath $windowlessPython)) {
    throw "Installer payload is missing pythonw.exe for windowless maintenance tasks."
}
$uninstallCleanupModule = Join-Path $payloadRoot "runtime\python\Lib\site-packages\transvortex\app\uninstall_cleanup.py"
if (-not (Test-Path -LiteralPath $uninstallCleanupModule)) {
    throw "Installer payload is missing the uninstall cleanup module. Rebuild the app runtime with -BuildAppRuntime."
}
$workspaceStorageModule = Join-Path $payloadRoot "runtime\python\Lib\site-packages\transvortex\app\workspace_storage.py"
if (-not (Test-Path -LiteralPath $workspaceStorageModule)) {
    throw "Installer payload is missing the workspace storage module. Rebuild the app runtime with -BuildAppRuntime."
}
$asrStorageModule = Join-Path $payloadRoot "runtime\python\Lib\site-packages\transvortex\app\asr_storage.py"
if (-not (Test-Path -LiteralPath $asrStorageModule)) {
    throw "Installer payload is missing the ASR storage module. Rebuild the app runtime with -BuildAppRuntime."
}
$powershellPayloads = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter "*.ps1")
if ($powershellPayloads.Count -gt 0) {
    throw "Installer payload must not contain end-user PowerShell scripts: $($powershellPayloads.FullName -join ', ')"
}

$payloadFiles = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File)
$payloadBytes = ($payloadFiles | Measure-Object -Property Length -Sum).Sum
$estimatedSizeKb = [int64][math]::Ceiling([double]$payloadBytes / 1KB)
$makensis = Resolve-Makensis -ExplicitPath $MakensisPath
$nsiPath = Join-Path $repoRoot "installer\windows\TransVortex.nsi"
$licensePath = Join-Path $repoRoot "LICENSE"
$iconPath = Join-Path $repoRoot "desktop_flutter\windows\runner\resources\app_icon.ico"
$welcomeBitmapPath = Join-Path $repoRoot "installer\windows\assets\installer_welcome.bmp"
$headerBitmapPath = Join-Path $repoRoot "installer\windows\assets\installer_header.bmp"
$asrConfigReaderPath = Join-Path $repoRoot "installer\windows\resolve_asr_storage_config.py"
foreach ($brandAsset in @($iconPath, $welcomeBitmapPath, $headerBitmapPath)) {
    if (-not (Test-Path -LiteralPath $brandAsset)) {
        throw "Installer brand asset not found: $brandAsset. Run scripts\build_brand_assets.ps1."
    }
}
if (-not (Test-Path -LiteralPath $asrConfigReaderPath)) {
    throw "Installer ASR config reader not found: $asrConfigReaderPath"
}

$nsisArgs = @(
    "/V3",
    "/INPUTCHARSET", "UTF8",
    "/DAPP_SOURCE=$payloadRoot",
    "/DOUTPUT_FILE=$installerPath",
    "/DAPP_VERSION=$appVersion",
    "/DAPP_FILE_VERSION=$appFileVersion",
    "/DESTIMATED_SIZE_KB=$estimatedSizeKb",
    "/DLICENSE_FILE=$licensePath",
    "/DAPP_ICON=$iconPath",
    "/DINSTALLER_WELCOME_BITMAP=$welcomeBitmapPath",
    "/DINSTALLER_HEADER_BITMAP=$headerBitmapPath",
    "/DASR_CONFIG_READER=$asrConfigReaderPath",
    $nsiPath
)
& $makensis @nsisArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "NSIS compiler failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "NSIS compiler did not create the installer: $installerPath"
}

$signed = $false
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $signTool = Resolve-SignTool
    & $signTool sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $installerPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode signing failed with exit code $LASTEXITCODE"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Installer signature validation failed: $($signature.Status) $($signature.StatusMessage)"
    }
    $signed = $true
}

$releaseCompliancePrerequisitesPresent = $packagedFfmpegPublicDistributionReady
$installerFile = Get-Item -LiteralPath $installerPath
$report = [ordered]@{
    ok = $true
    installer = $true
    native_installer = $true
    installer_format_complete = $true
    installer_framework = "NSIS"
    installer_path = $installerFile.Name
    installer_sha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    installer_bytes = [int64]$installerFile.Length
    app_version = $appVersion
    app_file_version = $appFileVersion
    release_stage = $releaseStage
    release_channel = $releaseChannel
    release_candidate = ($releaseChannel -eq "candidate")
    install_scope = "per_user"
    default_product_root = "%LOCALAPPDATA%\Programs\TransVortex"
    default_install_root = "%LOCALAPPDATA%\Programs\TransVortex\App"
    dedicated_install_subdirectory = $true
    workspace_location_selected_during_install = $true
    workspace_default = "%LOCALAPPDATA%\Programs\TransVortex\Data"
    asr_storage_default = "%LOCALAPPDATA%\Programs\TransVortex\Resources"
    workspace_default_follows_product_root = $true
    workspace_separate_from_install_root = $true
    workspace_config = "%LOCALAPPDATA%\TransVortex\Config\workspace_storage.json"
    silent_workspace_switch = "/WORKSPACEROOT=<path>"
    unsafe_existing_directory_rejected = $true
    install_path_change_requires_uninstall = $true
    end_user_powershell_required = $false
    python_runtime_included = $true
    ffmpeg_included = $true
    agent_entry_registered = $true
    agent_entry_stable_root = "%LOCALAPPDATA%\TransVortex\Agent"
    agent_entry_owned_files = @("README.md", "current.json")
    agent_native_extensions_modified = $false
    payload_manifest = "installer_payload_manifest.json"
    payload_file_count = $payloadFiles.Count
    payload_bytes = [int64]$payloadBytes
    atomic_directory_swap = $true
    branded_mui2_interface = $true
    internal_file_details_hidden = $true
    interactive_uninstall_cleanup = $true
    interactive_asr_cleanup_default = "remove"
    silent_uninstall_user_data_default = "preserve"
    uninstall_cleanup_switches = @(
        "/REMOVEASR",
        "/REMOVESETTINGS",
        "/REMOVETASKS",
        "/REMOVECREDENTIALS"
    )
    external_models_removed_by_uninstaller = $false
    agent_entry_removed_by_uninstaller = $true
    running_process_mutex = "Local\\TransVortex.Desktop.89E122A8-7AB7-4D0F-9661-0EC5A881F65B"
    interactive_running_app_prompt = $true
    confirmed_running_app_shutdown = "exact_process_tree"
    silent_running_app_default = "fail_exit_10"
    silent_close_app_switch = "/CLOSEAPP"
    signed = $signed
    signing_policy = "optional_for_initial_release"
    signing_required_for_public_release = $false
    unsigned_release_acknowledged = $unsignedReleaseAcknowledged
    ffmpeg_corresponding_source_url = $CorrespondingSourceUrl
    ffmpeg_corresponding_source_sha256 = $packagedCorrespondingSourceSha256
    ffmpeg_corresponding_source_bytes = $packagedCorrespondingSourceSize
    ffmpeg_corresponding_source_scope = $packagedCorrespondingSourceScope
    ffmpeg_corresponding_source_recorded = $packagedCorrespondingSourceRecorded
    ffmpeg_corresponding_source_assets_published = $packagedCorrespondingSourceAssetsPublished
    ffmpeg_build_input_scope_complete = $packagedBuildInputScopeComplete
    ffmpeg_external_library_sources_included = $packagedExternalLibrarySourcesIncluded
    ffmpeg_license_review_complete = $packagedLicenseReviewComplete
    ffmpeg_public_distribution_ready = $packagedFfmpegPublicDistributionReady
    ffmpeg_corresponding_source_required_for_public_release = $true
    release_compliance_prerequisites_present = $releaseCompliancePrerequisitesPresent
    public_release_ready = $false
    acceptance_complete = $false
    acceptance_required = @(
        "dedicated application directory and unrelated-file preservation",
        "installed-path change rejection",
        "fresh silent install and installed Local Service RPC",
        "upgrade replacement and obsolete-file removal",
        "running-process install block, confirmed close-and-upgrade, and uninstall protection",
        "Start menu shortcut AppUserModelID",
        "silent uninstall default preservation and explicit managed-data cleanup"
    )
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}
Write-Utf8NoBom -Path $installerManifestPath -Content ($report | ConvertTo-Json -Depth 10)
$report["manifest_path"] = $installerManifestPath

if ($Json) {
    $report | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$report
}
