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
$releaseChannel = if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) { "internal" } else { "candidate" }
if ([string]::IsNullOrWhiteSpace($CertificateThumbprint) -and -not $AllowUnsigned) {
    throw "No signing certificate was provided. Pass -CertificateThumbprint for a signed candidate, or explicitly pass -AllowUnsigned for internal acceptance only."
}

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

$releasePrerequisitesPresent = $signed -and -not [string]::IsNullOrWhiteSpace($CorrespondingSourceUrl)
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
    install_scope = "per_user"
    default_install_root = "%LOCALAPPDATA%\Programs\TransVortex"
    dedicated_install_subdirectory = $true
    unsafe_existing_directory_rejected = $true
    install_path_change_requires_uninstall = $true
    end_user_powershell_required = $false
    python_runtime_included = $true
    ffmpeg_included = $true
    payload_manifest = "installer_payload_manifest.json"
    payload_file_count = $payloadFiles.Count
    payload_bytes = [int64]$payloadBytes
    atomic_directory_swap = $true
    running_process_mutex = "Local\\TransVortex.Desktop.89E122A8-7AB7-4D0F-9661-0EC5A881F65B"
    signed = $signed
    signing_required_for_public_release = $true
    ffmpeg_corresponding_source_url = $CorrespondingSourceUrl
    ffmpeg_corresponding_source_required_for_public_release = $true
    signing_and_source_prerequisites_present = $releasePrerequisitesPresent
    public_release_ready = $false
    acceptance_complete = $false
    acceptance_required = @(
        "dedicated application directory and unrelated-file preservation",
        "installed-path change rejection",
        "fresh silent install and installed Local Service RPC",
        "upgrade replacement and obsolete-file removal",
        "running-process install and uninstall protection",
        "Start menu shortcut AppUserModelID",
        "silent uninstall and user-data preservation"
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
