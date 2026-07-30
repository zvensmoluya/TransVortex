param(
    [Parameter(Mandatory = $true)]
    [string]$BuildManifest,
    [string]$PinFile = "",
    [string]$Repository = "",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Get-RemoteRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GhPath,
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $remoteResponse = @(& $GhPath api "repos/$Repository/releases/tags/$Tag" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $failureText = $remoteResponse -join "`n"
        if ($failureText -match '(?i)HTTP\s+404|not\s+found') {
            return $null
        }
        throw "Could not read GitHub release $Tag in $Repository. $failureText"
    }
    return ($remoteResponse -join "`n") | ConvertFrom-Json
}

function Assert-RemoteAssets {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Remote,
        [Parameter(Mandatory = $true)]
        [object[]]$ExpectedAssets
    )

    $remoteAssets = @($Remote.assets)
    if ($remoteAssets.Count -ne $ExpectedAssets.Count) {
        throw "Published FFmpeg release contains an unexpected number of assets. Expected=$($ExpectedAssets.Count) Actual=$($remoteAssets.Count)"
    }
    foreach ($asset in $ExpectedAssets) {
        $matches = @($remoteAssets | Where-Object { [string]$_.name -eq $asset.Name })
        if ($matches.Count -ne 1) {
            throw "Published FFmpeg release does not contain exactly one expected asset: $($asset.Name)"
        }
        $remoteAsset = $matches[0]
        if ([int64]$remoteAsset.size -ne $asset.Size) {
            throw "Published FFmpeg asset size mismatch: $($asset.Name)"
        }
        $remoteDigest = [string]$remoteAsset.digest
        if ([string]::IsNullOrWhiteSpace($remoteDigest)) {
            throw "Published FFmpeg asset has no server-reported digest: $($asset.Name)"
        }
        if ($remoteDigest -ne "sha256:$($asset.Sha256)") {
            throw "Published FFmpeg asset digest mismatch: $($asset.Name)"
        }
    }
}

if ($Force) {
    throw "-Force is intentionally unsupported for pinned FFmpeg releases. Publish changed assets under a new release tag and update the pin instead of replacing an existing URL."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($PinFile)) {
    $PinFile = Join-Path $repoRoot "requirements\ffmpeg-runtime.json"
}
$pinPath = (Resolve-Path -LiteralPath $PinFile).Path
$pin = Get-Content -LiteralPath $pinPath -Encoding utf8 -Raw | ConvertFrom-Json
if ([int]$pin.schema_version -ne 1 -or [string]$pin.platform -ne "windows-x64") {
    throw "Unsupported FFmpeg runtime pin: $pinPath"
}
$sourcePin = $pin.corresponding_source
$pinnedRepository = [string]$sourcePin.repository
$tag = [string]$sourcePin.release_tag
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = $pinnedRepository
} elseif ($Repository -ne $pinnedRepository) {
    throw "Repository override does not match the immutable FFmpeg pin. Expected=$pinnedRepository Actual=$Repository"
}
if ([string]::IsNullOrWhiteSpace($Repository) -or [string]::IsNullOrWhiteSpace($tag)) {
    throw "FFmpeg runtime pin has no repository or release tag."
}
if ([bool]$sourcePin.public_distribution_ready -and -not [bool]$sourcePin.external_library_sources_included) {
    throw "FFmpeg source cannot be public-distribution ready without external library sources."
}

$manifestPath = (Resolve-Path -LiteralPath $BuildManifest).Path
$manifestDirectory = Split-Path -Parent $manifestPath
$manifest = Get-Content -LiteralPath $manifestPath -Encoding utf8 -Raw | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 1 -or [string]$manifest.component -ne "transvortex-ffmpeg-distribution") {
    throw "Unsupported FFmpeg distribution manifest: $manifestPath"
}
if ([string]$manifest.version -ne [string]$pin.version -or [string]$manifest.platform -ne [string]$pin.platform) {
    throw "FFmpeg distribution manifest version or platform does not match the immutable pin."
}
if ([string]$manifest.repository -ne $Repository -or [string]$manifest.release_tag -ne $tag) {
    throw "FFmpeg distribution manifest repository or release tag does not match the immutable pin."
}
if ([string]$manifest.corresponding_source_url -ne [string]$sourcePin.url) {
    throw "FFmpeg distribution manifest source URL does not match the immutable pin."
}
if ([bool]$manifest.public_distribution_source_ready -ne [bool]$sourcePin.public_distribution_ready) {
    throw "FFmpeg distribution manifest readiness does not match the immutable pin."
}

$expectedAssets = @{
    binary = [pscustomobject]@{
        Name = [string]$pin.binary.asset_name
        Size = [int64]$pin.binary.size
        Sha256 = [string]$pin.binary.sha256
    }
    corresponding_source = [pscustomobject]@{
        Name = [string]$sourcePin.asset_name
        Size = [int64]$sourcePin.size
        Sha256 = [string]$sourcePin.sha256
    }
}
$seenKinds = @{}
$verifiedAssets = @(
    foreach ($asset in @($manifest.assets)) {
        $kind = [string]$asset.kind
        if (-not $expectedAssets.ContainsKey($kind) -or $seenKinds.ContainsKey($kind)) {
            throw "FFmpeg distribution manifest contains an unexpected or duplicate asset kind: $kind"
        }
        $seenKinds[$kind] = $true
        $expected = $expectedAssets[$kind]
        if ([string]$asset.asset_name -ne $expected.Name -or
            [int64]$asset.size -ne $expected.Size -or
            [string]$asset.sha256 -ne $expected.Sha256) {
            throw "FFmpeg distribution asset does not match the immutable pin: $kind"
        }

        $assetPathValue = [string]$asset.path
        $assetPathCandidate = if ([System.IO.Path]::IsPathRooted($assetPathValue)) {
            $assetPathValue
        } else {
            Join-Path $manifestDirectory $assetPathValue
        }
        $assetPath = (Resolve-Path -LiteralPath $assetPathCandidate).Path
        $assetFile = Get-Item -LiteralPath $assetPath
        $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($assetFile.Name -ne $expected.Name) {
            throw "FFmpeg distribution asset name mismatch: $assetPath"
        }
        if ($assetFile.Length -ne $expected.Size -or $actualHash -ne $expected.Sha256) {
            throw "FFmpeg distribution asset changed after pin verification: $assetPath"
        }
        [pscustomobject]@{
            Kind = $kind
            Name = $expected.Name
            Path = $assetPath
            Size = $expected.Size
            Sha256 = $expected.Sha256
        }
    }
)
if ($verifiedAssets.Count -ne 2 -or $seenKinds.Count -ne 2) {
    throw "FFmpeg distribution must contain exactly one pinned binary and one pinned corresponding-source asset."
}

$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if ($null -eq $ghCommand) {
    throw "GitHub CLI was not found. Install gh and open a new PowerShell session before publishing."
}
$ghPath = $ghCommand.Source
& $ghPath auth status | Out-Host
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated." }

$remote = Get-RemoteRelease -GhPath $ghPath -Repository $Repository -Tag $tag
$createdRelease = $false
if ($null -eq $remote) {
    & $ghPath api "repos/$Repository" --silent
    if ($LASTEXITCODE -ne 0) {
        throw "Could not access GitHub repository $Repository."
    }

    $buildProvider = [string]$pin.binary.build_provider
    $distributionKind = [string]$manifest.distribution_kind
    $binaryDescription = if ($distributionKind -eq "transvortex-core" -or $buildProvider -eq "TransVortex") {
        "Reproducible TransVortex core binary archive built without optional external media libraries."
    } else {
        "Original unmodified BtbN $($manifest.version) LGPL shared binary archive."
    }
    $sourceDescription = if ([bool]$manifest.public_distribution_source_ready) {
        "Complete corresponding FFmpeg source and exact build-control scripts."
    } elseif ([bool]$sourcePin.build_input_scope_complete -and
        [bool]$sourcePin.external_library_sources_included -and
        @($sourcePin.external_library_sources_required).Count -eq 0) {
        "Complete technical build-input set for a core build with no optional external media libraries; application public-release readiness remains gated separately."
    } else {
        "FFmpeg source and exact BtbN build-control scripts for traceability; external-library corresponding sources are not yet included."
    }
    $notes = @"
Pinned Windows x64 FFmpeg runtime used by TransVortex.

Included assets:
- $binaryDescription
- $sourceDescription

The binary and source assets are versioned together and verified by SHA-256 in the TransVortex release manifest.
"@
    & $ghPath release create $tag `
        --repo $Repository `
        --title "TransVortex FFmpeg runtime $($manifest.version)" `
        --notes $notes `
        --draft
    if ($LASTEXITCODE -ne 0) { throw "Could not create draft GitHub Release $tag." }
    $createdRelease = $true

    foreach ($asset in $verifiedAssets) {
        & $ghPath release upload $tag $asset.Path --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "Could not upload FFmpeg distribution asset to draft release: $($asset.Path)" }
    }

    $remote = Get-RemoteRelease -GhPath $ghPath -Repository $Repository -Tag $tag
    if ($null -eq $remote) { throw "Could not read the draft FFmpeg release $tag after upload." }
    Assert-RemoteAssets -Remote $remote -ExpectedAssets $verifiedAssets

    & $ghPath release edit $tag --repo $Repository --draft=false
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg assets were verified, but the draft release could not be published: $tag" }
    $remote = Get-RemoteRelease -GhPath $ghPath -Repository $Repository -Tag $tag
    if ($null -eq $remote) { throw "Could not read the published FFmpeg release $tag." }
} elseif ([bool]$remote.draft) {
    throw "FFmpeg release $tag already exists as a draft. Inspect and recover that draft explicitly instead of replacing assets."
}

Assert-RemoteAssets -Remote $remote -ExpectedAssets $verifiedAssets

$result = [ordered]@{
    ok = $true
    repository = $Repository
    release_tag = $tag
    release_url = [string]$remote.html_url
    release_created = $createdRelease
    existing_release_verified = -not $createdRelease
    github_release_immutable = [bool]$remote.immutable
    publisher_allows_asset_replacement = $false
    public_distribution_source_ready = [bool]$manifest.public_distribution_source_ready
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
