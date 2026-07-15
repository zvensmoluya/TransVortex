param(
    [string]$ChromePath = "",
    [string]$FfmpegPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
$brandingDir = Resolve-Path -LiteralPath (Join-Path $repoRoot "desktop_flutter\assets\branding")
$runnerResources = Resolve-Path -LiteralPath (Join-Path $repoRoot "desktop_flutter\windows\runner\resources")
$trayAssets = Resolve-Path -LiteralPath (Join-Path $repoRoot "desktop_flutter\assets\ui")

if ([string]::IsNullOrWhiteSpace($ChromePath)) {
    $chromeCandidates = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    $ChromePath = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($ChromePath) -or -not (Test-Path -LiteralPath $ChromePath)) {
    throw "Chrome or Edge is required to rasterize the SVG brand assets."
}
$resolvedChrome = (Resolve-Path -LiteralPath $ChromePath).Path

if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    $ffmpegCommand = Get-Command ffmpeg -ErrorAction Stop
    $FfmpegPath = $ffmpegCommand.Source
}
$resolvedFfmpeg = (Resolve-Path -LiteralPath $FfmpegPath).Path
$ffprobePath = Join-Path (Split-Path -Parent $resolvedFfmpeg) "ffprobe.exe"
if (-not (Test-Path -LiteralPath $ffprobePath)) {
    throw "ffprobe.exe was not found next to ffmpeg.exe."
}

$largeSvg = Join-Path $brandingDir "app_icon.svg"
$smallSvg = Join-Path $brandingDir "app_icon_small.svg"
$largePng = Join-Path $brandingDir "app_icon_1024.png"
$smallPng = Join-Path $brandingDir "app_icon_small_256.png"
$runnerIcon = Join-Path $runnerResources "app_icon.ico"
$trayIcon = Join-Path $trayAssets "app_icon.ico"

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$chromeProfile = [System.IO.Path]::GetFullPath(
    (Join-Path $tempBase ("transvortex_brand_assets_" + [System.Guid]::NewGuid().ToString("N")))
)
if (-not $chromeProfile.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create a Chrome profile outside the system temp directory."
}
New-Item -ItemType Directory -Force -Path $chromeProfile | Out-Null

function Invoke-SvgRaster {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [int]$Size
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    $uri = [System.Uri]::new((Resolve-Path -LiteralPath $InputPath).Path).AbsoluteUri
    $arguments = @(
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
        "--default-background-color=00000000",
        "--user-data-dir=$chromeProfile",
        "--window-size=$Size,$Size",
        "--screenshot=$OutputPath",
        $uri
    )
    $process = Start-Process -FilePath $resolvedChrome -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "Browser rasterization failed for '$InputPath' (exit $($process.ExitCode))."
    }
}

try {
    Invoke-SvgRaster -InputPath $largeSvg -OutputPath $largePng -Size 1024
    Invoke-SvgRaster -InputPath $smallSvg -OutputPath $smallPng -Size 256
} finally {
    if (Test-Path -LiteralPath $chromeProfile) {
        Remove-Item -LiteralPath $chromeProfile -Recurse -Force
    }
}

& $resolvedFfmpeg -v error -y -i $largePng -i $smallPng `
    -filter_complex "[0:v]scale=256:256:flags=lanczos,format=rgba[o256];[1:v]split=3[v48][v32][v16];[v48]scale=48:48:flags=lanczos,format=rgba[o48];[v32]scale=32:32:flags=lanczos,format=rgba[o32];[v16]scale=16:16:flags=lanczos,format=rgba[o16]" `
    -map "[o256]" -map "[o48]" -map "[o32]" -map "[o16]" `
    -c:v png -frames:v:0 1 -frames:v:1 1 -frames:v:2 1 -frames:v:3 1 $runnerIcon
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $runnerIcon)) {
    throw "ffmpeg could not build the multi-resolution Windows icon."
}
Copy-Item -LiteralPath $runnerIcon -Destination $trayIcon -Force

$probe = (& $ffprobePath -v error -show_entries stream=width,height,pix_fmt -of json $runnerIcon | Out-String | ConvertFrom-Json)
$actualSizes = @($probe.streams | ForEach-Object { "$($_.width)x$($_.height)" })
$expectedSizes = @("256x256", "48x48", "32x32", "16x16")
foreach ($expected in $expectedSizes) {
    if ($expected -notin $actualSizes) {
        throw "Generated icon is missing the $expected frame."
    }
}

[ordered]@{
    ok = $true
    large_source = $largeSvg
    small_source = $smallSvg
    large_png = $largePng
    small_png = $smallPng
    runner_icon = $runnerIcon
    tray_icon = $trayIcon
    ico_sizes = $actualSizes
} | ConvertTo-Json -Depth 3
