param(
    [string]$InstallerPath = "",
    [string]$InstallRoot = "",
    [string]$ReportPath = "",
    [int]$ServiceTimeoutSeconds = 20,
    [int]$LaunchWaitSeconds = 4,
    [switch]$KeepInstallOnFailure,
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

function Invoke-WaitingProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    return $process.ExitCode
}

function Assert-InstalledLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $required = @(
        "TransVortex.exe",
        "Uninstall.exe",
        "flutter_windows.dll",
        "data\flutter_assets\FontManifest.json",
        "runtime\app_runtime.json",
        "runtime\python\python.exe",
        "tools\ffmpeg\ffmpeg_runtime.json",
        "tools\ffmpeg\bin\ffmpeg.exe",
        "tools\ffmpeg\bin\ffprobe.exe",
        "tools\ffmpeg\SOURCE_NOTICE.txt",
        "installer_payload_manifest.json"
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_)) })
    if ($missing.Count -gt 0) {
        throw "Installed layout is incomplete: $($missing -join ', ')"
    }
    $powershellFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.ps1")
    if ($powershellFiles.Count -gt 0) {
        throw "Installed layout unexpectedly contains PowerShell scripts: $($powershellFiles.FullName -join ', ')"
    }
}

function Invoke-InstalledServiceCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ServiceRoot,
        [Parameter(Mandatory = $true)]
        [string]$IsolatedProfile,
        [int]$TimeoutSeconds
    )

    New-Item -ItemType Directory -Force -Path $ServiceRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root "pipeline.yaml") -Destination (Join-Path $ServiceRoot "pipeline.yaml") -Force
    Copy-Item -LiteralPath (Join-Path $Root "providers.yaml") -Destination (Join-Path $ServiceRoot "providers.yaml") -Force
    New-Item -ItemType Directory -Force -Path $IsolatedProfile | Out-Null

    $pythonPath = Join-Path $Root "runtime\python\python.exe"
    $mediaToolsDir = Join-Path $Root "tools\ffmpeg\bin"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pythonPath
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    } catch {
    }
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Environment["PYTHONIOENCODING"] = "utf-8"
    $psi.Environment["PYTHONUTF8"] = "1"
    $psi.Environment["PYTHONPATH"] = ""
    $psi.Environment["PYTHONNOUSERSITE"] = "1"
    $psi.Environment["TRANSVORTEX_MEDIA_TOOLS_DIR"] = $mediaToolsDir
    $psi.Environment["PATH"] = "$env:SystemRoot\System32;$env:SystemRoot"
    $psi.Environment["USERPROFILE"] = $IsolatedProfile
    $psi.Environment["HOME"] = $IsolatedProfile
    $escapedServiceRoot = $ServiceRoot.Replace('"', '\"')
    $psi.Arguments = "-m transvortex.app_service --root `"$escapedServiceRoot`" --no-pump"

    $resolverPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $resolverPsi.FileName = $pythonPath
    $resolverPsi.WorkingDirectory = $Root
    $resolverPsi.UseShellExecute = $false
    $resolverPsi.RedirectStandardOutput = $true
    $resolverPsi.RedirectStandardError = $true
    $resolverPsi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $resolverPsi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $resolverPsi.Environment["PYTHONIOENCODING"] = "utf-8"
    $resolverPsi.Environment["PYTHONUTF8"] = "1"
    $resolverPsi.Environment["PYTHONPATH"] = ""
    $resolverPsi.Environment["PYTHONNOUSERSITE"] = "1"
    $resolverPsi.Environment["TRANSVORTEX_MEDIA_TOOLS_DIR"] = ""
    $resolverPsi.Environment["PATH"] = "$env:SystemRoot\System32;$env:SystemRoot"
    $resolverPsi.Environment["USERPROFILE"] = $IsolatedProfile
    $resolverPsi.Environment["HOME"] = $IsolatedProfile
    $resolverPsi.Arguments = '-c "from transvortex.core.media import _run; print(_run([''ffmpeg'', ''-version'']).returncode); print(_run([''ffprobe'', ''-version'']).returncode)"'
    $resolverProcess = [System.Diagnostics.Process]::new()
    $resolverProcess.StartInfo = $resolverPsi
    if (-not $resolverProcess.Start()) {
        throw "Could not start installed media resolver check."
    }
    if (-not $resolverProcess.WaitForExit($TimeoutSeconds * 1000)) {
        try { $resolverProcess.Kill() } catch {}
        throw "Installed media resolver check did not stop within $TimeoutSeconds seconds."
    }
    $resolverStdout = $resolverProcess.StandardOutput.ReadToEnd().Trim()
    $resolverStderr = $resolverProcess.StandardError.ReadToEnd().Trim()
    $resolverLines = @($resolverStdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($resolverProcess.ExitCode -ne 0 -or $resolverLines.Count -ne 2 -or $resolverLines[0] -ne "0" -or $resolverLines[1] -ne "0") {
        throw "Installed media resolver check failed. Exit=$($resolverProcess.ExitCode) Stdout=$resolverStdout Stderr=$resolverStderr"
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) {
            throw "Could not start installed Local Service."
        }
        foreach ($line in @(
            '{"jsonrpc":"2.0","id":1,"method":"service.info","params":{}}',
            '{"jsonrpc":"2.0","id":2,"method":"service.health","params":{}}',
            '{"jsonrpc":"2.0","id":3,"method":"service.shutdown","params":{}}'
        )) {
            $process.StandardInput.WriteLine($line)
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Installed Local Service did not stop within $TimeoutSeconds seconds."
        }
        $stdoutText = $process.StandardOutput.ReadToEnd()
        $stderrText = $process.StandardError.ReadToEnd()
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            try { $process.Kill() } catch {}
        }
    }

    $responses = @(
        $stdoutText -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $errors = @($responses | Where-Object { $null -ne $_.error })
    if ($responses.Count -ne 3 -or $errors.Count -gt 0) {
        throw "Installed Local Service RPC failed. Responses=$($responses.Count) Errors=$($errors.Count) Stderr=$stderrText"
    }
    $info = $responses | Where-Object { $_.id -eq 1 } | Select-Object -First 1
    $health = $responses | Where-Object { $_.id -eq 2 } | Select-Object -First 1
    $shutdown = $responses | Where-Object { $_.id -eq 3 } | Select-Object -First 1
    if ($info.result.service -ne "transvortex.app_service" -or -not [bool]$shutdown.result.ok) {
        throw "Installed Local Service returned unexpected service or shutdown results."
    }
    if ($health.result.service -ne "transvortex.app_service") {
        throw "Installed Local Service returned an unexpected health payload."
    }

    return [ordered]@{
        ok = $true
        service = [string]$info.result.service
        app_version = [string]$info.result.app_version
        protocol_version = [int]$info.result.protocol_version
        python_executable = "runtime\python\python.exe"
        pythonpath_empty = $true
        restricted_path = $true
        automatic_bundled_media_resolution = $true
        ffmpeg_path = "tools\ffmpeg\bin\ffmpeg.exe"
        ffprobe_path = "tools\ffmpeg\bin\ffprobe.exe"
        shutdown_ok = [bool]$shutdown.result.ok
        exit_code = $process.ExitCode
        stderr = $stderrText.Trim()
    }
}

function Start-IsolatedInstalledApp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$IsolatedLocalAppData,
        [Parameter(Mandatory = $true)]
        [string]$IsolatedProfile
    )

    New-Item -ItemType Directory -Force -Path $IsolatedLocalAppData | Out-Null
    New-Item -ItemType Directory -Force -Path $IsolatedProfile | Out-Null
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $Root "TransVortex.exe"
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.Environment["LOCALAPPDATA"] = $IsolatedLocalAppData
    $psi.Environment["APPDATA"] = Join-Path $IsolatedProfile "AppData\Roaming"
    $psi.Environment["USERPROFILE"] = $IsolatedProfile
    $psi.Environment["HOME"] = $IsolatedProfile
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw "Could not start installed TransVortex.exe"
    }
    return $process
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $repoRoot "dist\installer\windows\TransVortex-Setup-1.0.0.exe"
}
$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$installerDirectory = Split-Path -Parent $resolvedInstaller
$installerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInstaller)
$installerManifestPath = Join-Path $installerDirectory "$installerBaseName.manifest.json"
if (-not (Test-Path -LiteralPath $installerManifestPath)) {
    throw "Installer build manifest not found: $installerManifestPath"
}
$installerManifest = Get-Content -LiteralPath $installerManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
if (-not [bool]$installerManifest.formal_installer) {
    throw "Installer manifest does not describe a formal installer."
}
$actualInstallerHash = (Get-FileHash -LiteralPath $resolvedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualInstallerHash -ne [string]$installerManifest.installer_sha256) {
    throw "Installer SHA-256 does not match its build manifest."
}

$acceptanceId = [guid]::NewGuid().ToString("N")
$acceptanceRoot = Join-Path $env:TEMP "transvortex-installer-acceptance-$acceptanceId"
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $acceptanceRoot "install"
}
$installFullPath = Get-FullPath -Path $InstallRoot
Assert-PathInsideDirectory -Path $installFullPath -Directory $acceptanceRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $installerDirectory "$installerBaseName.acceptance.json"
}
$reportFullPath = Get-FullPath -Path $ReportPath

$defaultInstallRoot = Join-Path $env:LOCALAPPDATA "Programs\TransVortex"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TransVortex"
$appKey = "HKCU:\Software\TransVortex"
if (Test-Path -LiteralPath $defaultInstallRoot) {
    throw "Refusing automated acceptance while the default TransVortex install exists: $defaultInstallRoot"
}
if ((Test-Path -LiteralPath $uninstallKey) -or (Test-Path -LiteralPath $appKey)) {
    throw "Refusing automated acceptance while TransVortex installer registry keys already exist."
}

$shortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "TransVortex.lnk"
$shortcutBackup = Join-Path $acceptanceRoot "previous-shortcut.lnk"
$hadShortcut = Test-Path -LiteralPath $shortcutPath
$userDataSentinelRoot = Join-Path $env:LOCALAPPDATA "TransVortex\InstallerAcceptance\$acceptanceId"
$userDataSentinel = Join-Path $userDataSentinelRoot "preserve.txt"
$serviceRoot = Join-Path $acceptanceRoot "service"
$isolatedProfile = Join-Path $acceptanceRoot "profile"
$isolatedLocalAppData = Join-Path $acceptanceRoot "local-app-data"
$installedApp = $null
$acceptanceSucceeded = $false
$installed = $false
New-Item -ItemType Directory -Force -Path $acceptanceRoot | Out-Null
if ($hadShortcut) {
    Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup -Force
}
New-Item -ItemType Directory -Force -Path $userDataSentinelRoot | Out-Null
Set-Content -LiteralPath $userDataSentinel -Value $acceptanceId -Encoding utf8

try {
    $freshInstallExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/D=$installFullPath")
    if ($freshInstallExit -ne 0) {
        throw "Fresh silent install failed with exit code $freshInstallExit"
    }
    $installed = $true
    Assert-InstalledLayout -Root $installFullPath

    $registry = Get-ItemProperty -LiteralPath $uninstallKey
    if (-not [string]::Equals((Get-FullPath -Path $registry.InstallLocation), $installFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Uninstall registry InstallLocation does not match the acceptance root."
    }
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw "Start menu shortcut was not created."
    }
    $shortcutJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "install_flutter_desktop_shortcut.ps1") -ExePath (Join-Path $installFullPath "TransVortex.exe") -ShortcutPath $shortcutPath -VerifyOnly -Json
    if ($LASTEXITCODE -ne 0) {
        throw "Start menu shortcut identity verification failed."
    }
    $shortcutReport = (($shortcutJson | Out-String).Trim() | ConvertFrom-Json)
    $serviceReport = Invoke-InstalledServiceCheck -Root $installFullPath -ServiceRoot $serviceRoot -IsolatedProfile $isolatedProfile -TimeoutSeconds $ServiceTimeoutSeconds

    $obsoleteMarker = Join-Path $installFullPath "obsolete-upgrade-marker.txt"
    Set-Content -LiteralPath $obsoleteMarker -Value "must be removed" -Encoding utf8
    $upgradeExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/D=$installFullPath")
    if ($upgradeExit -ne 0) {
        throw "Silent upgrade failed with exit code $upgradeExit"
    }
    if (Test-Path -LiteralPath $obsoleteMarker) {
        throw "Upgrade did not remove an obsolete file from the prior install."
    }
    Assert-InstalledLayout -Root $installFullPath

    $installedApp = Start-IsolatedInstalledApp -Root $installFullPath -IsolatedLocalAppData $isolatedLocalAppData -IsolatedProfile $isolatedProfile
    Start-Sleep -Seconds $LaunchWaitSeconds
    if ($installedApp.HasExited) {
        throw "Installed TransVortex.exe exited during launch acceptance with code $($installedApp.ExitCode)"
    }
    $mutex = [System.Threading.Mutex]::OpenExisting("Local\TransVortex.Desktop.89E122A8-7AB7-4D0F-9661-0EC5A881F65B")
    $mutex.Dispose()

    $blockedUpgradeExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/D=$installFullPath")
    if ($blockedUpgradeExit -ne 10) {
        throw "Running-process install protection returned $blockedUpgradeExit instead of 10."
    }
    $uninstallerPath = Join-Path $installFullPath "Uninstall.exe"
    $blockedUninstallExit = Invoke-WaitingProcess -FilePath $uninstallerPath -ArgumentList @("/S", "_?=$installFullPath")
    if ($blockedUninstallExit -ne 10 -or -not (Test-Path -LiteralPath $installFullPath)) {
        throw "Running-process uninstall protection failed. Exit=$blockedUninstallExit"
    }

    if (-not $installedApp.CloseMainWindow()) {
        $installedApp.Kill()
    }
    if (-not $installedApp.WaitForExit(10000)) {
        $installedApp.Kill()
        $installedApp.WaitForExit()
    }
    $installedApp = $null

    $uninstallExit = Invoke-WaitingProcess -FilePath $uninstallerPath -ArgumentList @("/S")
    if ($uninstallExit -ne 0) {
        throw "Silent uninstall failed with exit code $uninstallExit"
    }
    $installed = $false
    if (Test-Path -LiteralPath $installFullPath) {
        throw "Install root remains after uninstall: $installFullPath"
    }
    if ((Test-Path -LiteralPath $uninstallKey) -or (Test-Path -LiteralPath $appKey)) {
        throw "Installer registry keys remain after uninstall."
    }
    if (Test-Path -LiteralPath $shortcutPath) {
        throw "Start menu shortcut remains after uninstall."
    }
    if (-not (Test-Path -LiteralPath $userDataSentinel)) {
        throw "Uninstall removed the user-data sentinel."
    }
    $sentinelContent = (Get-Content -LiteralPath $userDataSentinel -Encoding utf8 -Raw).Trim()
    if ($sentinelContent -ne $acceptanceId) {
        throw "Uninstall changed the user-data sentinel."
    }

    $report = [ordered]@{
        ok = $true
        installer_sha256 = $actualInstallerHash
        app_version = [string]$installerManifest.app_version
        install_scope = "per_user"
        custom_install_root = $true
        fresh_install_exit_code = $freshInstallExit
        installed_layout_ok = $true
        installed_powershell_script_count = 0
        local_service = $serviceReport
        shortcut_app_user_model_id_ok = [bool]$shortcutReport.shortcut_app_user_model_id_ok
        upgrade_exit_code = $upgradeExit
        upgrade_removed_obsolete_file = $true
        visible_launch_ok = $true
        app_mutex_opened = $true
        running_install_block_exit_code = $blockedUpgradeExit
        running_uninstall_block_exit_code = $blockedUninstallExit
        uninstall_exit_code = $uninstallExit
        uninstall_removed_install_root = $true
        uninstall_removed_registry = $true
        uninstall_removed_shortcut = $true
        uninstall_preserved_user_data = $true
        signed = [bool]$installerManifest.signed
        public_release_ready = $false
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Utf8NoBom -Path $reportFullPath -Content ($report | ConvertTo-Json -Depth 10)
    $installerManifest.acceptance_complete = $true
    $installerManifest.public_release_ready = [bool]$installerManifest.signing_and_source_prerequisites_present
    $installerManifest | Add-Member -NotePropertyName acceptance_report -NotePropertyValue ([System.IO.Path]::GetFileName($reportFullPath)) -Force
    Write-Utf8NoBom -Path $installerManifestPath -Content ($installerManifest | ConvertTo-Json -Depth 10)
    $acceptanceSucceeded = $true
} finally {
    if ($null -ne $installedApp -and -not $installedApp.HasExited) {
        try { $installedApp.Kill() } catch {}
        try { $installedApp.WaitForExit(10000) | Out-Null } catch {}
    }
    if ($installed -and -not $KeepInstallOnFailure) {
        $uninstaller = Join-Path $installFullPath "Uninstall.exe"
        if (Test-Path -LiteralPath $uninstaller) {
            try { Invoke-WaitingProcess -FilePath $uninstaller -ArgumentList @("/S") | Out-Null } catch {}
        }
    }
    if ($hadShortcut -and (Test-Path -LiteralPath $shortcutBackup)) {
        Copy-Item -LiteralPath $shortcutBackup -Destination $shortcutPath -Force
    } elseif (-not $hadShortcut -and (Test-Path -LiteralPath $shortcutPath)) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    if (Test-Path -LiteralPath $userDataSentinelRoot) {
        Assert-PathInsideDirectory -Path $userDataSentinelRoot -Directory (Join-Path $env:LOCALAPPDATA "TransVortex\InstallerAcceptance")
        Remove-Item -LiteralPath $userDataSentinelRoot -Recurse -Force
    }
    if ((Test-Path -LiteralPath $acceptanceRoot) -and ($acceptanceSucceeded -or -not $KeepInstallOnFailure)) {
        Assert-PathInsideDirectory -Path $acceptanceRoot -Directory $env:TEMP
        Remove-Item -LiteralPath $acceptanceRoot -Recurse -Force
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$report
}
