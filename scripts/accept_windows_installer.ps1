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

function Restore-ConfigState {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Snapshots,
        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot,
        [Parameter(Mandatory = $true)]
        [bool]$ConfigRootExisted
    )

    foreach ($snapshot in $Snapshots) {
        if ([bool]$snapshot.Existed) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $snapshot.Path) | Out-Null
            Copy-Item -LiteralPath $snapshot.Backup -Destination $snapshot.Path -Force
        } elseif (Test-Path -LiteralPath $snapshot.Path) {
            Remove-Item -LiteralPath $snapshot.Path -Force
        }
    }
    if (-not $ConfigRootExisted -and (Test-Path -LiteralPath $ConfigRoot)) {
        $remaining = @(Get-ChildItem -LiteralPath $ConfigRoot -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $ConfigRoot -Force
        }
    }
}

function Get-EffectiveInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedPath
    )

    $requestedFullPath = Get-FullPath -Path $RequestedPath
    $leaf = Split-Path -Leaf $requestedFullPath
    if ([string]::Equals($leaf, "App", [System.StringComparison]::OrdinalIgnoreCase)) {
        $parent = Split-Path -Parent $requestedFullPath
        if ([string]::Equals((Split-Path -Leaf $parent), "TransVortex", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $requestedFullPath
        }
    }
    if ([string]::Equals($leaf, "TransVortex", [System.StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path $requestedFullPath "App"
    }
    return Join-Path $requestedFullPath "TransVortex\App"
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
        ".transvortex-install.ini",
        "flutter_windows.dll",
        "data\flutter_assets\FontManifest.json",
        "runtime\app_runtime.json",
        "runtime\python\python.exe",
        "runtime\python\pythonw.exe",
        "runtime\python\Lib\site-packages\transvortex\app\uninstall_cleanup.py",
        "runtime\python\Lib\site-packages\transvortex\app\workspace_storage.py",
        "runtime\python\Lib\site-packages\transvortex\app\asr_storage.py",
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
    $installMarker = Get-Content -LiteralPath (Join-Path $Root ".transvortex-install.ini") -Raw
    if ($installMarker -notmatch '(?m)^AppId=TransVortex\s*$') {
        throw "Installed layout has an invalid TransVortex ownership marker."
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

function Invoke-InstalledUninstallCleanupCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$AcceptanceRoot
    )

    $cleanupRoot = Join-Path $AcceptanceRoot "uninstall-cleanup"
    $appDataRoot = Join-Path $cleanupRoot "AppData\Local\TransVortex"
    $customAsrRoot = Join-Path $cleanupRoot "asr-storage"
    $credentialFile = Join-Path $cleanupRoot "profile\.transvortex\auth.json"
    $credentialSentinel = Join-Path $cleanupRoot "profile\.transvortex\keep-cli-file.txt"
    $externalModel = Join-Path $cleanupRoot "external-model\model.bin"
    $customSentinel = Join-Path $customAsrRoot "keep-user-file.txt"
    $appSentinel = Join-Path $appDataRoot "keep-user-file.txt"
    $inspectReport = Join-Path $cleanupRoot "inspect.ini"
    $cleanupReport = Join-Path $cleanupRoot "cleanup.ini"
    $configRoot = Join-Path $appDataRoot "Config"
    $pythonPath = Join-Path $Root "runtime\python\python.exe"

    New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
    Write-Utf8NoBom -Path (Join-Path $configRoot "asr_storage.json") -Content (
        [ordered]@{
            schema_version = 1
            storage_root = $customAsrRoot
        } | ConvertTo-Json -Depth 3
    )
    foreach ($file in @(
        (Join-Path $customAsrRoot "Components\runtime\component.json"),
        (Join-Path $customAsrRoot "Models\faster-whisper\small\model.bin"),
        (Join-Path $customAsrRoot "Downloads\ASR\small\model.bin.part"),
        (Join-Path $appDataRoot "Components\orphan\component.json"),
        (Join-Path $appDataRoot "Workspace\Tasks\task-1\result.srt"),
        (Join-Path $appDataRoot "Workspace\Cache\task-1.wav"),
        $credentialFile,
        $credentialSentinel,
        $externalModel,
        $customSentinel,
        $appSentinel
    )) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        Set-Content -LiteralPath $file -Value "installer acceptance" -Encoding utf8
    }

    $inspectExit = Invoke-WaitingProcess -FilePath $pythonPath -ArgumentList @(
        "-m", "transvortex.app.uninstall_cleanup",
        "--inspect",
        "--app-data-root", "`"$appDataRoot`"",
        "--credential-file", "`"$credentialFile`"",
        "--report-ini", "`"$inspectReport`""
    )
    if ($inspectExit -ne 0 -or -not (Test-Path -LiteralPath $inspectReport)) {
        throw "Installed uninstall cleanup inspection failed. Exit=$inspectExit"
    }

    $cleanupExit = Invoke-WaitingProcess -FilePath $pythonPath -ArgumentList @(
        "-m", "transvortex.app.uninstall_cleanup",
        "--app-data-root", "`"$appDataRoot`"",
        "--credential-file", "`"$credentialFile`"",
        "--report-ini", "`"$cleanupReport`"",
        "--remove-asr-resources",
        "--remove-settings",
        "--remove-tasks",
        "--remove-credentials"
    )
    if ($cleanupExit -ne 0 -or -not (Test-Path -LiteralPath $cleanupReport)) {
        throw "Installed uninstall cleanup execution failed. Exit=$cleanupExit"
    }

    $removedTargets = @(
        (Join-Path $customAsrRoot "Components"),
        (Join-Path $customAsrRoot "Models\faster-whisper"),
        (Join-Path $customAsrRoot "Downloads\ASR"),
        (Join-Path $appDataRoot "Components"),
        (Join-Path $appDataRoot "Config"),
        (Join-Path $appDataRoot "Workspace"),
        $credentialFile
    )
    $remainingRemovedTargets = @($removedTargets | Where-Object { Test-Path -LiteralPath $_ })
    if ($remainingRemovedTargets.Count -gt 0) {
        throw "Installed uninstall cleanup left selected targets: $($remainingRemovedTargets -join ', ')"
    }
    foreach ($preserved in @($credentialSentinel, $externalModel, $customSentinel, $appSentinel)) {
        if (-not (Test-Path -LiteralPath $preserved)) {
            throw "Installed uninstall cleanup removed an unmanaged file: $preserved"
        }
    }

    return [ordered]@{
        ok = $true
        inspect_exit_code = $inspectExit
        cleanup_exit_code = $cleanupExit
        custom_asr_storage_removed = $true
        default_asr_remnants_removed = $true
        settings_removed = $true
        tasks_and_cache_removed = $true
        credentials_removed = $true
        external_model_preserved = $true
        unrelated_files_preserved = $true
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $installerOutputRoot = Join-Path $repoRoot "dist\installer\windows"
    $candidateManifests = @(
        Get-ChildItem -LiteralPath $installerOutputRoot -File -Filter "TransVortex-*-windows-x64-setup-*.manifest.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )
    if ($candidateManifests.Count -eq 0) {
        throw "No versioned Windows installer manifest was found under: $installerOutputRoot"
    }
    $manifestSuffix = ".manifest.json"
    $manifestFullName = $candidateManifests[0].FullName
    $InstallerPath = $manifestFullName.Substring(0, $manifestFullName.Length - $manifestSuffix.Length) + ".exe"
}
$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$installerDirectory = Split-Path -Parent $resolvedInstaller
$installerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInstaller)
$installerManifestPath = Join-Path $installerDirectory "$installerBaseName.manifest.json"
if (-not (Test-Path -LiteralPath $installerManifestPath)) {
    throw "Installer build manifest not found: $installerManifestPath"
}
$installerManifest = Get-Content -LiteralPath $installerManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
if (-not [bool]$installerManifest.native_installer -or -not [bool]$installerManifest.installer_format_complete) {
    throw "Installer manifest does not describe a complete native installer."
}
$actualInstallerHash = (Get-FileHash -LiteralPath $resolvedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualInstallerHash -ne [string]$installerManifest.installer_sha256) {
    throw "Installer SHA-256 does not match its build manifest."
}

$acceptanceId = [guid]::NewGuid().ToString("N")
$acceptanceRoot = Join-Path $env:TEMP "transvortex-installer-acceptance-$acceptanceId"
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $acceptanceRoot "install-parent"
}

function Wait-PathRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (Test-Path -LiteralPath $Path) {
        if ([DateTime]::UtcNow -ge $deadline) {
            return $false
        }
        Start-Sleep -Milliseconds 100
    }
    return $true
}

function Assert-AgentEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot,
        [Parameter(Mandatory = $true)]
        [string]$EntryRoot
    )

    $entryDocument = Join-Path $EntryRoot "README.md"
    $entryState = Join-Path $EntryRoot "current.json"
    if (-not (Test-Path -LiteralPath $entryDocument) -or -not (Test-Path -LiteralPath $entryState)) {
        throw "Installed Agent locator is incomplete."
    }
    $state = Get-Content -LiteralPath $entryState -Encoding utf8 -Raw | ConvertFrom-Json
    if (-not [bool]$state.registered -or [int]$state.schema_version -ne 1) {
        throw "Installed Agent locator metadata is invalid."
    }
    if (-not [string]::Equals((Get-FullPath -Path $state.install_root), (Get-FullPath -Path $Root), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Agent locator install_root does not match the installed app."
    }
    if (-not [string]::Equals((Get-FullPath -Path $state.config_root), (Get-FullPath -Path $ConfigRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Agent locator config_root does not match the installed app."
    }
    $argv = @($state.cli_argv_prefix)
    $expectedPython = Join-Path $Root "runtime\python\python.exe"
    if ($argv.Count -ne 6 -or
        -not [string]::Equals((Get-FullPath -Path $argv[0]), (Get-FullPath -Path $expectedPython), [System.StringComparison]::OrdinalIgnoreCase) -or
        $argv[1] -ne "-B" -or $argv[2] -ne "-m" -or $argv[3] -ne "transvortex.cli" -or
        $argv[4] -ne "--root" -or
        -not [string]::Equals((Get-FullPath -Path $argv[5]), (Get-FullPath -Path $ConfigRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Agent locator CLI argv prefix is invalid."
    }
    foreach ($documentPath in @(
        $state.documents.start,
        $state.documents.usage,
        $state.documents.adaptation,
        $state.documents.asr_environment_setup,
        $state.documents.setup_contract_schema
    )) {
        if (-not (Test-Path -LiteralPath ([string]$documentPath))) {
            throw "Agent locator references a missing document: $documentPath"
        }
    }
    return [ordered]@{
        schema_version = [int]$state.schema_version
        registered = [bool]$state.registered
        entry_document = $entryDocument
        entry_state = $entryState
        cli_argv_prefix_ok = $true
        documents_ok = $true
    }
}
$installerRequestedPath = Get-FullPath -Path $InstallRoot
$installFullPath = Get-EffectiveInstallRoot -RequestedPath $installerRequestedPath
$productRoot = Split-Path -Parent $installFullPath
Assert-PathInsideDirectory -Path $installerRequestedPath -Directory $acceptanceRoot
Assert-PathInsideDirectory -Path $installFullPath -Directory $acceptanceRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $installerDirectory "$installerBaseName.acceptance.json"
}
$reportFullPath = Get-FullPath -Path $ReportPath

$defaultProductRoot = Join-Path $env:LOCALAPPDATA "Programs\TransVortex"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TransVortex"
$appKey = "HKCU:\Software\TransVortex"
$agentEntryRoot = Join-Path $env:LOCALAPPDATA "TransVortex\Agent"
$agentEntryDocument = Join-Path $agentEntryRoot "README.md"
$agentEntryState = Join-Path $agentEntryRoot "current.json"
$configRoot = Join-Path $env:LOCALAPPDATA "TransVortex\Config"
$configRootExisted = Test-Path -LiteralPath $configRoot
$configBackupRoot = Join-Path $acceptanceRoot "config-backup"
$configSnapshots = @(
    [pscustomobject]@{
        Path = Join-Path $configRoot "workspace_storage.json"
        Backup = Join-Path $configBackupRoot "workspace_storage.json"
        Existed = Test-Path -LiteralPath (Join-Path $configRoot "workspace_storage.json")
    },
    [pscustomobject]@{
        Path = Join-Path $configRoot "asr_storage.json"
        Backup = Join-Path $configBackupRoot "asr_storage.json"
        Existed = Test-Path -LiteralPath (Join-Path $configRoot "asr_storage.json")
    }
)
$configSnapshotReady = $false
if (Test-Path -LiteralPath $defaultProductRoot) {
    throw "Refusing automated acceptance while the default TransVortex product root exists: $defaultProductRoot"
}
if ((Test-Path -LiteralPath $uninstallKey) -or (Test-Path -LiteralPath $appKey)) {
    throw "Refusing automated acceptance while TransVortex installer registry keys already exist."
}
if ((Test-Path -LiteralPath $agentEntryDocument) -or (Test-Path -LiteralPath $agentEntryState)) {
    throw "Refusing automated acceptance while a TransVortex Agent locator already exists."
}

$shortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "TransVortex.lnk"
$shortcutBackup = Join-Path $acceptanceRoot "previous-shortcut.lnk"
$hadShortcut = Test-Path -LiteralPath $shortcutPath
$userDataSentinelRoot = Join-Path $env:LOCALAPPDATA "TransVortex\InstallerAcceptance\$acceptanceId"
$userDataSentinel = Join-Path $userDataSentinelRoot "preserve.txt"
$serviceRoot = Join-Path $acceptanceRoot "service"
$isolatedProfile = Join-Path $acceptanceRoot "profile"
$isolatedLocalAppData = Join-Path $acceptanceRoot "local-app-data"
$workspaceRoot = Join-Path $productRoot "Data"
$asrStorageRoot = Join-Path $productRoot "Resources"
$legacyWorkspaceRoot = Join-Path $env:LOCALAPPDATA "TransVortex\Workspace"
$legacyWorkspaceDataPresent = (
    @(Get-ChildItem -LiteralPath (Join-Path $legacyWorkspaceRoot "Tasks") -Force -ErrorAction SilentlyContinue).Count -gt 0 -or
    @(Get-ChildItem -LiteralPath (Join-Path $legacyWorkspaceRoot "Cache") -Force -ErrorAction SilentlyContinue).Count -gt 0
)
$workspaceSelectionMode = if ($legacyWorkspaceDataPresent) {
    "explicit_product_data_due_to_legacy_workspace"
} else {
    "modern_default"
}
$unsafeParent = Join-Path $acceptanceRoot "unsafe-parent"
$unsafeTarget = Join-Path $unsafeParent "TransVortex\App"
$unsafeSentinel = Join-Path $unsafeTarget "unrelated-user-file.txt"
$relocatedParent = Join-Path $acceptanceRoot "relocated-parent"
$relocatedTarget = Join-Path $relocatedParent "TransVortex\App"
$installedApp = $null
$acceptanceSucceeded = $false
$installed = $false
$agentEntryReport = $null
New-Item -ItemType Directory -Force -Path $acceptanceRoot | Out-Null
if ($hadShortcut) {
    Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup -Force
}
New-Item -ItemType Directory -Force -Path $userDataSentinelRoot | Out-Null
Set-Content -LiteralPath $userDataSentinel -Value $acceptanceId -Encoding utf8

try {
    New-Item -ItemType Directory -Force -Path $configBackupRoot | Out-Null
    foreach ($snapshot in $configSnapshots) {
        if ([bool]$snapshot.Existed) {
            Copy-Item -LiteralPath $snapshot.Path -Destination $snapshot.Backup -Force
        }
    }
    $configSnapshotReady = $true
    foreach ($snapshot in $configSnapshots) {
        if (Test-Path -LiteralPath $snapshot.Path) {
            Remove-Item -LiteralPath $snapshot.Path -Force
        }
    }

    New-Item -ItemType Directory -Force -Path $unsafeTarget | Out-Null
    Set-Content -LiteralPath $unsafeSentinel -Value $acceptanceId -Encoding utf8
    $unsafeDirectoryExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/WORKSPACEROOT=$workspaceRoot", "/D=$unsafeParent")
    if ($unsafeDirectoryExit -ne 11) {
        throw "Unsafe non-application directory returned $unsafeDirectoryExit instead of 11."
    }
    if (-not (Test-Path -LiteralPath $unsafeSentinel) -or (Test-Path -LiteralPath (Join-Path $unsafeTarget "TransVortex.exe"))) {
        throw "Unsafe-directory protection changed an unrelated target directory."
    }
    $unsafeSentinelContent = (Get-Content -LiteralPath $unsafeSentinel -Encoding utf8 -Raw).Trim()
    if ($unsafeSentinelContent -ne $acceptanceId) {
        throw "Unsafe-directory protection changed the unrelated sentinel."
    }

    $freshInstallArguments = @("/S")
    if ($legacyWorkspaceDataPresent) {
        $freshInstallArguments += "/WORKSPACEROOT=$workspaceRoot"
    }
    $freshInstallArguments += "/D=$installerRequestedPath"
    $freshInstallExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList $freshInstallArguments
    if ($freshInstallExit -ne 0) {
        throw "Fresh silent install failed with exit code $freshInstallExit"
    }
    $installed = $true
    Assert-InstalledLayout -Root $installFullPath
    $agentEntryReport = Assert-AgentEntry -Root $installFullPath -ConfigRoot $configRoot -EntryRoot $agentEntryRoot

    $registry = Get-ItemProperty -LiteralPath $uninstallKey
    if (-not [string]::Equals((Get-FullPath -Path $registry.InstallLocation), $installFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Uninstall registry InstallLocation does not match the acceptance root."
    }
    $appRegistry = Get-ItemProperty -LiteralPath $appKey
    if (-not [string]::Equals((Get-FullPath -Path $appRegistry.WorkspaceLocation), (Get-FullPath -Path $workspaceRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installed workspace does not match the product Data directory."
    }
    if (-not [string]::Equals((Get-FullPath -Path $appRegistry.AsrStorageLocation), (Get-FullPath -Path $asrStorageRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Default ASR storage does not match the product Resources directory."
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
    $uninstallCleanupReport = Invoke-InstalledUninstallCleanupCheck -Root $installFullPath -AcceptanceRoot $acceptanceRoot

    $pathChangeExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/WORKSPACEROOT=$workspaceRoot", "/D=$relocatedParent")
    if ($pathChangeExit -ne 12 -or (Test-Path -LiteralPath $relocatedTarget)) {
        throw "Installed-path change protection failed. Exit=$pathChangeExit"
    }

    $obsoleteMarker = Join-Path $installFullPath "obsolete-upgrade-marker.txt"
    Set-Content -LiteralPath $obsoleteMarker -Value "must be removed" -Encoding utf8
    $upgradeExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/D=$installerRequestedPath")
    if ($upgradeExit -ne 0) {
        throw "Silent upgrade failed with exit code $upgradeExit"
    }
    if (Test-Path -LiteralPath $obsoleteMarker) {
        throw "Upgrade did not remove an obsolete file from the prior install."
    }
    Assert-InstalledLayout -Root $installFullPath
    $agentEntryReport = Assert-AgentEntry -Root $installFullPath -ConfigRoot $configRoot -EntryRoot $agentEntryRoot

    $installedApp = Start-IsolatedInstalledApp -Root $installFullPath -IsolatedLocalAppData $isolatedLocalAppData -IsolatedProfile $isolatedProfile
    Start-Sleep -Seconds $LaunchWaitSeconds
    if ($installedApp.HasExited) {
        throw "Installed TransVortex.exe exited during launch acceptance with code $($installedApp.ExitCode)"
    }
    $mutex = [System.Threading.Mutex]::OpenExisting("Local\TransVortex.Desktop.89E122A8-7AB7-4D0F-9661-0EC5A881F65B")
    $mutex.Dispose()

    $blockedUpgradeExit = Invoke-WaitingProcess -FilePath $resolvedInstaller -ArgumentList @("/S", "/D=$installerRequestedPath")
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
    if (-not (Wait-PathRemoved -Path $installFullPath)) {
        throw "Install root was not removed within the uninstall timeout: $installFullPath"
    }
    $installed = $false
    if (Test-Path -LiteralPath $installFullPath) {
        throw "Install root remains after uninstall: $installFullPath"
    }
    if (Test-Path -LiteralPath $uninstallKey) {
        throw "Uninstall registry key remains after uninstall."
    }
    $preservedWorkspace = (Get-ItemProperty -LiteralPath $appKey).WorkspaceLocation
    if (-not [string]::Equals((Get-FullPath -Path $preservedWorkspace), (Get-FullPath -Path $workspaceRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Uninstall did not preserve the selected workspace location."
    }
    if (Test-Path -LiteralPath $shortcutPath) {
        throw "Start menu shortcut remains after uninstall."
    }
    if ((Test-Path -LiteralPath $agentEntryDocument) -or (Test-Path -LiteralPath $agentEntryState)) {
        throw "TransVortex-owned Agent locator files remain after uninstall."
    }
    if (-not (Test-Path -LiteralPath $userDataSentinel)) {
        throw "Uninstall removed the user-data sentinel."
    }
    $sentinelContent = (Get-Content -LiteralPath $userDataSentinel -Encoding utf8 -Raw).Trim()
    if ($sentinelContent -ne $acceptanceId) {
        throw "Uninstall changed the user-data sentinel."
    }

    Restore-ConfigState `
        -Snapshots $configSnapshots `
        -ConfigRoot $configRoot `
        -ConfigRootExisted $configRootExisted
    $configSnapshotReady = $false

    $report = [ordered]@{
        ok = $true
        installer_sha256 = $actualInstallerHash
        app_version = [string]$installerManifest.app_version
        release_stage = [string]$installerManifest.release_stage
        release_channel = [string]$installerManifest.release_channel
        install_scope = "per_user"
        custom_install_root = $true
        dedicated_install_subdirectory = $true
        unified_product_root = $true
        workspace_is_product_data = $true
        workspace_selection_mode = $workspaceSelectionMode
        clean_profile_default_workspace_exercised = (-not $legacyWorkspaceDataPresent)
        default_asr_storage_is_product_resources = $true
        unsafe_directory_block_exit_code = $unsafeDirectoryExit
        unsafe_directory_preserved = $true
        installed_path_change_block_exit_code = $pathChangeExit
        fresh_install_exit_code = $freshInstallExit
        installed_layout_ok = $true
        install_ownership_marker_ok = $true
        installed_powershell_script_count = 0
        agent_entry = $agentEntryReport
        uninstall_removed_agent_entry = $true
        local_service = $serviceReport
        uninstall_cleanup_helper = $uninstallCleanupReport
        shortcut_app_user_model_id_ok = [bool]$shortcutReport.shortcut_app_user_model_id_ok
        upgrade_exit_code = $upgradeExit
        upgrade_removed_obsolete_file = $true
        visible_launch_ok = $true
        app_mutex_opened = $true
        running_install_block_exit_code = $blockedUpgradeExit
        running_uninstall_block_exit_code = $blockedUninstallExit
        uninstall_exit_code = $uninstallExit
        uninstall_removed_install_root = $true
        uninstall_removed_program_registry = $true
        uninstall_preserved_workspace_registry = $true
        uninstall_removed_shortcut = $true
        uninstall_preserved_user_data = $true
        preexisting_config_restored = $true
        silent_uninstall_cleanup_default = "preserve"
        signed = [bool]$installerManifest.signed
        public_release_ready = $false
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Utf8NoBom -Path $reportFullPath -Content ($report | ConvertTo-Json -Depth 10)
    $installerManifest.acceptance_complete = $true
    $installerManifest.public_release_ready = $false
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
    if ($configSnapshotReady) {
        Restore-ConfigState `
            -Snapshots $configSnapshots `
            -ConfigRoot $configRoot `
            -ConfigRootExisted $configRootExisted
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
    if ((-not $KeepInstallOnFailure -or $acceptanceSucceeded) -and (Test-Path -LiteralPath $appKey)) {
        Remove-Item -LiteralPath $appKey -Recurse -Force
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$report
}
