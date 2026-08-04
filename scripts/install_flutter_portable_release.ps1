param(
    [string]$SourceRoot = "",
    [string]$InstallRoot = "",
    [string]$ShortcutPath = "",
    [string]$AppUserModelId = "TransVortex.Desktop",
    [string]$AppName = "TransVortex",
    [int]$ServiceCheckTimeoutSeconds = 30,
    [switch]$Force,
    [switch]$VerifyOnly,
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

function Test-PathInsideDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $fullPath = Get-FullPath -Path $Path
    $fullDirectory = Get-FullPath -Path $Directory
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-InstallPathSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = Get-FullPath -Path $Path
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "InstallRoot has no parent directory: $fullPath"
    }
    if ($fullPath -eq (Get-FullPath -Path $parent)) {
        throw "InstallRoot must not be a drive or parent root: $fullPath"
    }
}

function Assert-RequiredPackagePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $requiredPaths = @(
        "TransVortex.exe",
        "flutter_windows.dll",
        "flutter_local_notifications_windows.dll",
        "data\flutter_assets\FontManifest.json",
        "LICENSE",
        "licenses\fonts\NotoSansSC-OFL.txt",
        "licenses\fonts\LXGWWenKaiLite-OFL.txt",
        "runtime\app_runtime.json",
        "runtime\python\python.exe",
        "runtime\python\Lib\site-packages\transvortex\app_service.py",
        "runtime\python\Lib\site-packages\transvortex\app\desktop_api.py",
        "tools\ffmpeg\ffmpeg_runtime.json",
        "tools\ffmpeg\bin\ffmpeg.exe",
        "tools\ffmpeg\bin\ffprobe.exe",
        "tools\ffmpeg\SOURCE_NOTICE.txt",
        "pipeline.yaml",
        "providers.yaml"
    )
    $missing = @(
        $requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_)) }
    )
    if ($missing.Count -gt 0) {
        throw "Portable package missing required paths: $($missing -join ', ')"
    }
}

function Assert-NoLocalSecrets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $forbiddenNames = @(
        ".env",
        ".imagegen.env",
        ".env.imagegen",
        "providers.local.yaml",
        "auth.json"
    )
    $matches = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
            Where-Object { $forbiddenNames -contains $_.Name } |
            ForEach-Object { $_.FullName }
    )
    if ($matches.Count -gt 0) {
        throw "Install source or target contains forbidden local/secret files: $($matches -join ', ')"
    }
}

function Remove-GeneratedPackageFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $cacheDirs = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force |
            Where-Object {
                $_.PSIsContainer -and
                (($_.Name -in @("__pycache__", ".pytest_cache")) -or ($_.Name -like "*.egg-info"))
            }
    )
    foreach ($cacheDir in $cacheDirs) {
        if (Test-PathInsideDirectory -Path $cacheDir.FullName -Directory $Root) {
            Remove-Item -LiteralPath $cacheDir.FullName -Recurse -Force
        }
    }

    $compiledFiles = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
            Where-Object { $_.Extension -in @(".pyc", ".pyo") }
    )
    foreach ($compiledFile in $compiledFiles) {
        if (Test-PathInsideDirectory -Path $compiledFile.FullName -Directory $Root) {
            Remove-Item -LiteralPath $compiledFile.FullName -Force
        }
    }

    foreach ($rootName in @("artifacts", "output", "tmp", "DemoTest")) {
        $rootGeneratedPath = Join-Path $Root $rootName
        if (Test-Path -LiteralPath $rootGeneratedPath) {
            Remove-Item -LiteralPath $rootGeneratedPath -Recurse -Force
        }
    }
}

function Invoke-InstalledServiceCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [int]$TimeoutSeconds = 15
    )

    $runtimeRoot = Join-Path $Root "runtime"
    $runtimeManifestPath = Join-Path $runtimeRoot "app_runtime.json"
    $pythonPath = Join-Path $runtimeRoot "python\python.exe"
    $runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Encoding utf8 -Raw | ConvertFrom-Json
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
    $psi.Environment["TRANSVORTEX_MEDIA_TOOLS_DIR"] = Join-Path $Root "tools\ffmpeg\bin"
    $escapedRoot = $Root.Replace('"', '\"')
    $psi.Arguments = "-m transvortex.app_service --root `"$escapedRoot`" --no-pump"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $startedAt = Get-Date
    try {
        if (-not $process.Start()) {
            throw "Could not start installed Local Service process."
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
            throw "Installed Local Service did not exit after service.shutdown within $TimeoutSeconds seconds."
        }
        $stdoutText = $process.StandardOutput.ReadToEnd()
        $stderrText = $process.StandardError.ReadToEnd()
    } finally {
        if ($process -ne $null -and -not $process.HasExited) {
            try {
                $process.Kill()
            } catch {
            }
        }
    }

    $responses = @(
        $stdoutText -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $errors = @(
        $responses |
            Where-Object { ($_.PSObject.Properties.Name -contains "error") -and $null -ne $_.error } |
            ForEach-Object { $_.error }
    )
    $info = $responses | Where-Object { $_.id -eq 1 } | Select-Object -First 1
    $health = $responses | Where-Object { $_.id -eq 2 } | Select-Object -First 1
    $shutdown = $responses | Where-Object { $_.id -eq 3 } | Select-Object -First 1
    if ($responses.Count -ne 3 -or $errors.Count -gt 0) {
        throw "Installed Local Service RPC check failed. Responses=$($responses.Count) Errors=$($errors.Count) Stdout=$stdoutText Stderr=$stderrText"
    }
    if ($info.result.service -ne "transvortex.app_service") {
        throw "Unexpected service.info service: $($info.result.service)"
    }
    if ($health.result.service -ne "transvortex.app_service") {
        throw "Unexpected service.health service: $($health.result.service)"
    }
    if ([string]$info.result.app_version -ne [string]$runtimeManifest.version) {
        throw "App runtime version mismatch. Manifest=$($runtimeManifest.version) Service=$($info.result.app_version)"
    }
    if ([int]$info.result.protocol_version -ne [int]$runtimeManifest.protocol_version) {
        throw "App runtime protocol mismatch. Manifest=$($runtimeManifest.protocol_version) Service=$($info.result.protocol_version)"
    }
    if (-not [bool]$shutdown.result.ok) {
        throw "service.shutdown did not return ok=true."
    }

    return [ordered]@{
        ok = $true
        started_at = $startedAt.ToString("o")
        ended_at = (Get-Date).ToString("o")
        service = [string]$info.result.service
        protocol_version = $info.result.protocol_version
        python_executable = $pythonPath
        pythonpath_empty = $true
        runtime_version = [string]$runtimeManifest.version
        runtime_python_version = [string]$runtimeManifest.python_version
        health_status = [string]$health.result.status
        shutdown_ok = [bool]$shutdown.result.ok
        exit_code = $process.ExitCode
        stderr = $stderrText.Trim()
    }
}

function Test-InstalledFfmpeg {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $ffmpegRoot = Join-Path $Root "tools\ffmpeg"
    $manifest = Get-Content -LiteralPath (Join-Path $ffmpegRoot "ffmpeg_runtime.json") -Encoding utf8 -Raw | ConvertFrom-Json
    $ffmpegPath = Join-Path $ffmpegRoot "bin\ffmpeg.exe"
    $ffprobePath = Join-Path $ffmpegRoot "bin\ffprobe.exe"
    $ffmpegOutput = @(& $ffmpegPath -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Installed ffmpeg -version failed with exit code $LASTEXITCODE"
    }
    $ffprobeOutput = @(& $ffprobePath -version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Installed ffprobe -version failed with exit code $LASTEXITCODE"
    }
    $ffmpegHash = (Get-FileHash -LiteralPath $ffmpegPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ffprobeHash = (Get-FileHash -LiteralPath $ffprobePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ffmpegHash -ne [string]$manifest.ffmpeg_sha256 -or $ffprobeHash -ne [string]$manifest.ffprobe_sha256) {
        throw "Installed FFmpeg executable hash does not match ffmpeg_runtime.json."
    }
    return [ordered]@{
        ok = $true
        version = [string]$manifest.version
        variant = [string]$manifest.variant
        ffmpeg_version_line = [string]$ffmpegOutput[0]
        ffprobe_version_line = [string]$ffprobeOutput[0]
    }
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "Programs\TransVortex"
}
if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
    $ShortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "$AppName.lnk"
}

$sourceFullPath = Get-FullPath -Path $SourceRoot
$installFullPath = Get-FullPath -Path $InstallRoot
Assert-InstallPathSafe -Path $installFullPath
Assert-RequiredPackagePaths -Root $sourceFullPath
Assert-NoLocalSecrets -Root $sourceFullPath

if (Test-PathInsideDirectory -Path $installFullPath -Directory $sourceFullPath) {
    throw "InstallRoot must not be inside SourceRoot: $installFullPath"
}
if (Test-PathInsideDirectory -Path $sourceFullPath -Directory $installFullPath) {
    throw "SourceRoot must not be inside InstallRoot: $sourceFullPath"
}

if (-not $VerifyOnly) {
    if (Test-Path -LiteralPath $installFullPath) {
        if (-not $Force) {
            throw "InstallRoot already exists: $installFullPath. Pass -Force to replace it."
        }
        Remove-Item -LiteralPath $installFullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $installFullPath | Out-Null
    Get-ChildItem -LiteralPath $sourceFullPath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $installFullPath -Recurse -Force
    }
}

Assert-RequiredPackagePaths -Root $installFullPath
Remove-GeneratedPackageFiles -Root $installFullPath
Assert-NoLocalSecrets -Root $installFullPath
$serviceReport = Invoke-InstalledServiceCheck -Root $installFullPath -TimeoutSeconds $ServiceCheckTimeoutSeconds
$ffmpegReport = Test-InstalledFfmpeg -Root $installFullPath
Remove-GeneratedPackageFiles -Root $installFullPath
Assert-NoLocalSecrets -Root $installFullPath

$shortcutHelper = Join-Path $installFullPath "scripts\install_flutter_desktop_shortcut.ps1"
if (-not (Test-Path -LiteralPath $shortcutHelper)) {
    throw "Shortcut helper missing from installed package: $shortcutHelper"
}
$shortcutJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $shortcutHelper -ExePath (Join-Path $installFullPath "TransVortex.exe") -ShortcutPath $ShortcutPath -AppUserModelId $AppUserModelId -AppName $AppName -Json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Installed shortcut identity check failed: $($shortcutJson | Out-String)"
}
$shortcutReport = (($shortcutJson | Out-String).Trim() | ConvertFrom-Json)

$files = Get-ChildItem -LiteralPath $installFullPath -Recurse -File
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$report = [ordered]@{
    ok = $true
    install_type = "portable_user_install"
    installer = $false
    native_installer = $false
    installer_format_complete = $false
    msix = $false
    frontend_design_mvp_complete = $false
    completion_claim = "Portable package installed to a user-level directory and verified; this is not a native Windows installer."
    source_root = $sourceFullPath
    install_root = $installFullPath
    exe_path = Join-Path $installFullPath "TransVortex.exe"
    shortcut_path = $ShortcutPath
    file_count = $files.Count
    total_bytes = [int64]$totalBytes
    service_check = $serviceReport
    ffmpeg_check = $ffmpegReport
    shortcut_check = $shortcutReport
    python_runtime_included = $true
    python_runtime_manifest = "runtime\app_runtime.json"
    ffmpeg_included = $true
    verify_only = [bool]$VerifyOnly
    manual_acceptance_required = @(
        "real visible release window end-to-end run; record with scripts/accept_flutter_release_manual.ps1",
        "native Windows installer acceptance"
    )
}

if ($Json) {
    $report | ConvertTo-Json -Depth 10
} else {
    [pscustomobject]$report
}
