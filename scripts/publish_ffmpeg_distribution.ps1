param(
    [Parameter(Mandatory = $true)]
    [string]$BuildManifest,
    [string]$Repository = "",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$manifestPath = (Resolve-Path -LiteralPath $BuildManifest).Path
$manifestDirectory = Split-Path -Parent $manifestPath
$manifest = Get-Content -LiteralPath $manifestPath -Encoding utf8 -Raw | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 1 -or [string]$manifest.component -ne "transvortex-ffmpeg-distribution") {
    throw "Unsupported FFmpeg distribution manifest: $manifestPath"
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = [string]$manifest.repository
}
$tag = [string]$manifest.release_tag
if ([string]::IsNullOrWhiteSpace($Repository) -or [string]::IsNullOrWhiteSpace($tag)) {
    throw "FFmpeg distribution manifest has no repository or release tag."
}

$verifiedAssets = @(
    foreach ($asset in @($manifest.assets)) {
        $assetPathValue = [string]$asset.path
        $assetPathCandidate = if ([System.IO.Path]::IsPathRooted($assetPathValue)) {
            $assetPathValue
        } else {
            Join-Path $manifestDirectory $assetPathValue
        }
        $assetPath = (Resolve-Path -LiteralPath $assetPathCandidate).Path
        $assetFile = Get-Item -LiteralPath $assetPath
        $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($assetFile.Name -ne [string]$asset.asset_name) {
            throw "FFmpeg distribution asset name mismatch: $assetPath"
        }
        if ($assetFile.Length -ne [int64]$asset.size -or $actualHash -ne [string]$asset.sha256) {
            throw "FFmpeg distribution asset changed after manifest creation: $assetPath"
        }
        [pscustomobject]@{
            Kind = [string]$asset.kind
            Name = [string]$asset.asset_name
            Path = $assetPath
            Size = [int64]$asset.size
            Sha256 = [string]$asset.sha256
        }
    }
)
if ($verifiedAssets.Count -ne 2 -or ((@($verifiedAssets.Kind | Sort-Object) -join ',') -ne 'binary,corresponding_source')) {
    throw "FFmpeg distribution must publish exactly one binary and one corresponding-source asset."
}

& gh auth status | Out-Host
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated." }

$existing = & gh release view $tag --repo $Repository --json tagName 2>$null
if ($LASTEXITCODE -ne 0) {
    $sourceDescription = if ([bool]$manifest.public_distribution_source_ready) {
        "Complete corresponding FFmpeg source and exact BtbN build-control scripts."
    } else {
        "FFmpeg source and exact BtbN build-control scripts for traceability; external-library corresponding sources are not yet included."
    }
    $notes = @"
Pinned Windows x64 FFmpeg runtime used by TransVortex.

Included assets:
- Original unmodified BtbN $($manifest.version) LGPL shared binary archive.
- $sourceDescription

The binary and source assets are versioned together and verified by SHA-256 in the TransVortex release manifest.
"@
    & gh release create $tag `
        --repo $Repository `
        --title "TransVortex FFmpeg runtime $($manifest.version)" `
        --notes $notes
    if ($LASTEXITCODE -ne 0) { throw "Could not create GitHub Release $tag." }
} elseif (-not $Force) {
    throw "GitHub Release $tag already exists. Pass -Force to replace matching assets."
}

foreach ($asset in $verifiedAssets) {
    $uploadArgs = @("release", "upload", $tag, $asset.Path, "--repo", $Repository)
    if ($Force) { $uploadArgs += "--clobber" }
    & gh @uploadArgs
    if ($LASTEXITCODE -ne 0) { throw "Could not upload FFmpeg distribution asset: $($asset.Path)" }
}

$remoteJson = & gh api "repos/$Repository/releases/tags/$tag"
if ($LASTEXITCODE -ne 0) { throw "Could not read the published FFmpeg release $tag." }
$remote = $remoteJson | ConvertFrom-Json
$remoteAssets = @($remote.assets)
foreach ($asset in $verifiedAssets) {
    $remoteAsset = $remoteAssets | Where-Object { [string]$_.name -eq $asset.Name } | Select-Object -First 1
    if ($null -eq $remoteAsset) {
        throw "Published FFmpeg release is missing asset: $($asset.Name)"
    }
    if ([int64]$remoteAsset.size -ne $asset.Size) {
        throw "Published FFmpeg asset size mismatch: $($asset.Name)"
    }
    $remoteDigest = [string]$remoteAsset.digest
    if (-not [string]::IsNullOrWhiteSpace($remoteDigest) -and $remoteDigest -ne "sha256:$($asset.Sha256)") {
        throw "Published FFmpeg asset digest mismatch: $($asset.Name)"
    }
}

$result = [ordered]@{
    ok = $true
    repository = $Repository
    release_tag = $tag
    release_url = [string]$remote.html_url
    asset_count = $verifiedAssets.Count
    assets = @(
        foreach ($asset in $verifiedAssets) {
            [ordered]@{
                kind = $asset.Kind
                name = $asset.Name
                size = $asset.Size
                sha256 = $asset.Sha256
                url = "https://github.com/$Repository/releases/download/$tag/$($asset.Name)"
            }
        }
    )
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { [pscustomobject]$result }
