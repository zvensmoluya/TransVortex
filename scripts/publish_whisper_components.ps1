param(
    [Parameter(Mandatory = $true)]
    [string]$BuildManifest,
    [string]$Repository = "zvensmoluya/TransVortex",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifestPath = (Resolve-Path -LiteralPath $BuildManifest).Path
$manifestDirectory = Split-Path -Parent $manifestPath
$manifest = Get-Content -LiteralPath $manifestPath -Encoding utf8 -Raw | ConvertFrom-Json
$catalogPath = Join-Path $repoRoot "src\transvortex\resources\asr_components.json"
$catalog = Get-Content -LiteralPath $catalogPath -Encoding utf8 -Raw | ConvertFrom-Json
$tag = [string]$manifest.release_tag
if ([string]::IsNullOrWhiteSpace($tag)) { throw "Build manifest has no release_tag." }

& gh auth status
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated." }

$existing = & gh release view $tag --repo $Repository --json tagName 2>$null
if ($LASTEXITCODE -ne 0) {
    & gh release create $tag --repo $Repository --title "TransVortex ASR components $tag" --notes "Managed faster-whisper runtime and optional NVIDIA acceleration for Windows x64."
    if ($LASTEXITCODE -ne 0) { throw "Could not create GitHub Release $tag." }
} elseif (-not $Force) {
    throw "GitHub Release $tag already exists. Pass -Force to replace matching assets."
}

foreach ($asset in @($manifest.assets)) {
    $assetPathValue = [string]$asset.path
    $assetPathCandidate = if ([System.IO.Path]::IsPathRooted($assetPathValue)) {
        $assetPathValue
    } else {
        Join-Path $manifestDirectory $assetPathValue
    }
    $assetPath = (Resolve-Path -LiteralPath $assetPathCandidate).Path
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $actualSize = (Get-Item -LiteralPath $assetPath).Length
    if ($actualHash -ne [string]$asset.sha256 -or $actualSize -ne [int64]$asset.size) {
        throw "Build asset changed after manifest creation: $assetPath"
    }
    $uploadArgs = @("release", "upload", $tag, $assetPath, "--repo", $Repository)
    if ($Force) { $uploadArgs += "--clobber" }
    & gh @uploadArgs
    if ($LASTEXITCODE -ne 0) { throw "Could not upload ASR component: $assetPath" }
}

foreach ($asset in @($manifest.assets)) {
    $url = "https://github.com/$Repository/releases/download/$tag/$($asset.asset_name)"
    if ($asset.kind -eq "runtime") {
        $catalog.runtime.artifact.published = $true
        $catalog.runtime.artifact.url = $url
        $catalog.runtime.artifact.size = [int64]$asset.size
        $catalog.runtime.artifact.sha256 = [string]$asset.sha256
    } elseif ($asset.kind -eq "accelerator") {
        $target = @($catalog.accelerators) | Where-Object { $_.id -eq $asset.id } | Select-Object -First 1
        if ($null -eq $target) { throw "Accelerator is missing from catalog: $($asset.id)" }
        $target.artifact.published = $true
        $target.artifact.url = $url
        $target.artifact.size = [int64]$asset.size
        $target.artifact.sha256 = [string]$asset.sha256
    }
}

[System.IO.File]::WriteAllText(
    $catalogPath,
    (($catalog | ConvertTo-Json -Depth 20) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

$result = [ordered]@{
    ok = $true
    repository = $Repository
    release_tag = $tag
    asset_count = @($manifest.assets).Count
    catalog_path = $catalogPath
    catalog_published = $true
}
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { [pscustomobject]$result }
