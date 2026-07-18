param(
    [Parameter(Mandatory = $true)]
    [string]$BuildManifest,
    [Parameter(Mandatory = $true)]
    [string]$ModelId,
    [Parameter(Mandatory = $true)]
    [string]$ModelPath,
    [string]$SessionRoot = "",
    [switch]$Force,
    [switch]$PlanOnly,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$sessionOwner = "TransVortex.ManagedAsrE2EStaging"
$sessionMarkerName = ".transvortex-managed-asr-e2e-session.json"

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

function Get-ObjectProperty {
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $value = [string](Get-ObjectProperty -InputObject $InputObject -Name $Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Context is missing a non-empty '$Name'."
    }
    return $value
}

function Get-RequiredPositiveInt64 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $rawValue = Get-ObjectProperty -InputObject $InputObject -Name $Name
    $value = [int64]0
    if ($null -eq $rawValue -or -not [int64]::TryParse([string]$rawValue, [ref]$value) -or $value -le 0) {
        throw "$Context has an invalid '$Name'; expected a positive integer."
    }
    return $value
}

function Get-RequiredSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $value = [string](Get-ObjectProperty -InputObject $InputObject -Name $Name)
    $value = $value.ToLowerInvariant()
    if ($value -notmatch '^[0-9a-f]{64}$') {
        throw "$Context has an invalid '$Name'; expected a 64-character SHA-256 digest."
    }
    return $value
}

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$BasePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "A non-empty path is required."
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = (Get-Location).Path
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        throw "$Description does not exist: $Path"
    }
}

function Assert-RegularFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "$Description is not a file: $Path"
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a symbolic link or reparse point: $Path"
    }
    return $item
}

function Assert-SafeLeafName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ($Value -notmatch '^[A-Za-z0-9._-]+$' -or $Value -in @('.', '..')) {
        throw "$Description is not a safe file-system name: $Value"
    }
}

function Get-SafeRelativeSegments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $normalized = $Value.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.StartsWith('/')) {
        throw "$Description is not a safe relative path: $Value"
    }
    $segments = @($normalized.Split('/'))
    foreach ($segment in $segments) {
        if (
            [string]::IsNullOrWhiteSpace($segment) -or
            $segment -in @('.', '..') -or
            $segment.IndexOfAny([char[]]'<>:"|?*') -ge 0 -or
            $segment.EndsWith('.') -or
            $segment.EndsWith(' ')
        ) {
            throw "$Description is not a safe relative path: $Value"
        }
    }
    return $segments
}

function Join-PathSegments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$Segments
    )

    $result = $Root
    foreach ($segment in $Segments) {
        $result = Join-Path $result $segment
    }
    return $result
}

function Assert-ModelSourceFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$Segments,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $current = $Root
    for ($index = 0; $index -lt $Segments.Count; $index += 1) {
        $current = Join-Path $current $Segments[$index]
        if (-not (Test-Path -LiteralPath $current)) {
            throw "$Description does not exist: $current"
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description traverses a symbolic link or reparse point: $current"
        }
        if ($index -lt ($Segments.Count - 1) -and -not $item.PSIsContainer) {
            throw "$Description has a non-directory parent: $current"
        }
        if ($index -eq ($Segments.Count - 1) -and $item.PSIsContainer) {
            throw "$Description is not a file: $current"
        }
    }
    return $current
}

function Assert-FileMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int64]$ExpectedSize,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $item = Assert-RegularFile -Path $Path -Description $Description
    if ([int64]$item.Length -ne $ExpectedSize) {
        throw "$Description size mismatch. Expected $ExpectedSize bytes, got $($item.Length): $Path"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne $ExpectedSha256) {
        throw "$Description SHA-256 mismatch. Expected $ExpectedSha256, got ${actualSha256}: $Path"
    }
}

function Read-JsonObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Assert-RegularFile -Path $Path -Description $Description | Out-Null
    try {
        $payload = Get-Content -LiteralPath $Path -Encoding utf8 -Raw | ConvertFrom-Json
    } catch {
        throw "$Description is not valid UTF-8 JSON: $Path. $($_.Exception.Message)"
    }
    if ($null -eq $payload -or $payload -is [System.Array]) {
        throw "$Description must contain one JSON object: $Path"
    }
    return $payload
}

function Test-ExactText {
    param(
        [AllowNull()]
        [object]$Left,
        [AllowNull()]
        [object]$Right
    )

    return ([string]$Left -ceq [string]$Right)
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return (
        $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$catalogPath = Join-Path $repoRoot "src\transvortex\resources\asr_components.json"
$catalogPath = Resolve-ExistingPath -Path $catalogPath -Description "Product ASR catalog"
$catalog = Read-JsonObject -Path $catalogPath -Description "Product ASR catalog"

$catalogSchema = Get-ObjectProperty -InputObject $catalog -Name "schema_version"
if ([string]$catalogSchema -cne "1") {
    throw "Product ASR catalog schema_version must be 1."
}

$buildManifestPath = Resolve-ExistingPath -Path (Get-FullPath -Path $BuildManifest) -Description "ASR component build manifest"
$buildManifestPayload = Read-JsonObject -Path $buildManifestPath -Description "ASR component build manifest"
$buildSchema = Get-ObjectProperty -InputObject $buildManifestPayload -Name "schema_version"
if ([string]$buildSchema -cne "1") {
    throw "ASR component build manifest schema_version must be 1."
}
$buildManifestDirectory = Split-Path -Parent $buildManifestPath

Assert-SafeLeafName -Value $ModelId -Description "ModelId"
$modelEntries = @(
    @(Get-ObjectProperty -InputObject $catalog -Name "models") |
        Where-Object { Test-ExactText -Left (Get-ObjectProperty -InputObject $_ -Name "id") -Right $ModelId }
)
if ($modelEntries.Count -ne 1) {
    throw "Product ASR catalog must contain exactly one model with id '$ModelId'; found $($modelEntries.Count)."
}
$model = $modelEntries[0]
$modelRevision = Get-RequiredString -InputObject $model -Name "revision" -Context "Model '$ModelId'"
$modelRepository = Get-RequiredString -InputObject $model -Name "repository" -Context "Model '$ModelId'"
Assert-SafeLeafName -Value $modelRevision -Description "Model revision"

$modelRootCandidate = Get-FullPath -Path $ModelPath
$modelRoot = Resolve-ExistingPath -Path $modelRootCandidate -Description "Model source directory"
$modelRootItem = Get-Item -LiteralPath $modelRoot -Force -ErrorAction Stop
if (-not $modelRootItem.PSIsContainer) {
    throw "Model source path is not a directory: $modelRoot"
}
if (($modelRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Model source directory must not be a symbolic link or reparse point: $modelRoot"
}

if ([string]::IsNullOrWhiteSpace($SessionRoot)) {
    $SessionRoot = Join-Path $repoRoot "dist\managed-asr-e2e\$ModelId"
}
$sessionRootFull = Get-FullPath -Path $SessionRoot
$volumeRoot = [System.IO.Path]::GetPathRoot($sessionRootFull)
$trimCharacters = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
if (Test-ExactText -Left $sessionRootFull.TrimEnd($trimCharacters) -Right $volumeRoot.TrimEnd($trimCharacters)) {
    throw "SessionRoot must not be a file-system volume root: $sessionRootFull"
}
$sessionMarkerPath = Join-Path $sessionRootFull $sessionMarkerName
$sessionExists = Test-Path -LiteralPath $sessionRootFull
$sessionDisposition = "create"
if ($sessionExists) {
    $sessionItem = Get-Item -LiteralPath $sessionRootFull -Force -ErrorAction Stop
    if (-not $sessionItem.PSIsContainer) {
        throw "SessionRoot exists but is not a directory: $sessionRootFull"
    }
    if (($sessionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "SessionRoot must not be a symbolic link or reparse point: $sessionRootFull"
    }
    $sessionItems = @(Get-ChildItem -LiteralPath $sessionRootFull -Force)
    if ($sessionItems.Count -eq 0) {
        $sessionDisposition = "initialize_empty"
    } else {
        if (-not (Test-Path -LiteralPath $sessionMarkerPath -PathType Leaf)) {
            throw "Refusing non-empty SessionRoot without the TransVortex staging ownership marker: $sessionRootFull"
        }
        $existingMarker = Read-JsonObject -Path $sessionMarkerPath -Description "Session ownership marker"
        $markerOwner = Get-ObjectProperty -InputObject $existingMarker -Name "owner"
        $markerSchema = Get-ObjectProperty -InputObject $existingMarker -Name "schema_version"
        $markerRoot = Get-ObjectProperty -InputObject $existingMarker -Name "session_root"
        if (
            -not (Test-ExactText -Left $markerOwner -Right $sessionOwner) -or
            [string]$markerSchema -cne "1" -or
            -not (Test-ExactText -Left $markerRoot -Right $sessionRootFull)
        ) {
            throw "Refusing SessionRoot with an invalid or relocated TransVortex staging ownership marker: $sessionRootFull"
        }
        if (-not $Force) {
            throw "SessionRoot already contains an owned staging session. Pass -Force to replace it: $sessionRootFull"
        }
        $sessionDisposition = "replace_owned"
    }
}

$runtime = Get-ObjectProperty -InputObject $catalog -Name "runtime"
if ($null -eq $runtime) {
    throw "Product ASR catalog is missing runtime."
}
$expectedAssets = @()
$expectedAssets += [pscustomobject][ordered]@{
    kind = "runtime"
    entry = $runtime
    artifact = Get-ObjectProperty -InputObject $runtime -Name "artifact"
}
foreach ($accelerator in @(Get-ObjectProperty -InputObject $catalog -Name "accelerators")) {
    if ($null -eq $accelerator) {
        continue
    }
    $expectedAssets += [pscustomobject][ordered]@{
        kind = "accelerator"
        entry = $accelerator
        artifact = Get-ObjectProperty -InputObject $accelerator -Name "artifact"
    }
}

$manifestAssets = @(Get-ObjectProperty -InputObject $buildManifestPayload -Name "assets")
if ($manifestAssets.Count -ne $expectedAssets.Count) {
    throw "ASR component build manifest asset count mismatch. Expected $($expectedAssets.Count), got $($manifestAssets.Count)."
}
$manifestReleaseTag = Get-RequiredString -InputObject $buildManifestPayload -Name "release_tag" -Context "ASR component build manifest"
$verifiedComponents = @()
$seenAssetNames = @{}
foreach ($expected in $expectedAssets) {
    if ($null -eq $expected.artifact) {
        throw "Catalog $($expected.kind) '$((Get-ObjectProperty -InputObject $expected.entry -Name 'id'))' is missing artifact metadata."
    }
    $expectedId = Get-RequiredString -InputObject $expected.entry -Name "id" -Context "Catalog $($expected.kind)"
    $expectedVersion = Get-RequiredString -InputObject $expected.entry -Name "version" -Context "Catalog $($expected.kind) '$expectedId'"
    $expectedAssetName = Get-RequiredString -InputObject $expected.artifact -Name "asset_name" -Context "Catalog $($expected.kind) '$expectedId' artifact"
    $expectedReleaseTag = Get-RequiredString -InputObject $expected.artifact -Name "release_tag" -Context "Catalog $($expected.kind) '$expectedId' artifact"
    Assert-SafeLeafName -Value $expectedAssetName -Description "Catalog asset_name"
    if (-not $expectedAssetName.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Catalog asset_name must name a ZIP archive: $expectedAssetName"
    }
    if (-not (Test-ExactText -Left $expectedReleaseTag -Right $manifestReleaseTag)) {
        throw "Build manifest release_tag '$manifestReleaseTag' does not match catalog asset '$expectedAssetName' release_tag '$expectedReleaseTag'."
    }
    $assetNameKey = $expectedAssetName.ToLowerInvariant()
    if ($seenAssetNames.ContainsKey($assetNameKey)) {
        throw "Product ASR catalog contains a duplicate asset_name: $expectedAssetName"
    }
    $seenAssetNames[$assetNameKey] = $true

    $matches = @(
        $manifestAssets | Where-Object {
            (Test-ExactText -Left (Get-ObjectProperty -InputObject $_ -Name "kind") -Right $expected.kind) -and
            (Test-ExactText -Left (Get-ObjectProperty -InputObject $_ -Name "id") -Right $expectedId)
        }
    )
    if ($matches.Count -ne 1) {
        throw "Build manifest must contain exactly one $($expected.kind) asset for '$expectedId'; found $($matches.Count)."
    }
    $manifestAsset = $matches[0]
    $actualKind = Get-RequiredString -InputObject $manifestAsset -Name "kind" -Context "Build asset '$expectedId'"
    $actualId = Get-RequiredString -InputObject $manifestAsset -Name "id" -Context "Build asset '$expectedId'"
    $actualVersion = Get-RequiredString -InputObject $manifestAsset -Name "version" -Context "Build asset '$expectedId'"
    $actualAssetName = Get-RequiredString -InputObject $manifestAsset -Name "asset_name" -Context "Build asset '$expectedId'"
    if (
        -not (Test-ExactText -Left $actualKind -Right $expected.kind) -or
        -not (Test-ExactText -Left $actualId -Right $expectedId) -or
        -not (Test-ExactText -Left $actualVersion -Right $expectedVersion) -or
        -not (Test-ExactText -Left $actualAssetName -Right $expectedAssetName)
    ) {
        throw "Build asset identity does not match catalog $($expected.kind) '$expectedId'."
    }
    $assetSize = Get-RequiredPositiveInt64 -InputObject $manifestAsset -Name "size" -Context "Build asset '$expectedAssetName'"
    $assetSha256 = Get-RequiredSha256 -InputObject $manifestAsset -Name "sha256" -Context "Build asset '$expectedAssetName'"
    $manifestSourceValue = Get-RequiredString -InputObject $manifestAsset -Name "path" -Context "Build asset '$expectedAssetName'"
    $manifestSourceCandidate = Get-FullPath -Path $manifestSourceValue -BasePath $buildManifestDirectory
    $assetSourcePath = Resolve-ExistingPath -Path $manifestSourceCandidate -Description "Build asset '$expectedAssetName'"
    $assetSourceItem = Assert-RegularFile -Path $assetSourcePath -Description "Build asset '$expectedAssetName'"
    if (-not (Test-ExactText -Left $assetSourceItem.Name -Right $expectedAssetName)) {
        throw "Build asset file name does not match asset_name '$expectedAssetName': $assetSourcePath"
    }

    $catalogSizeRaw = Get-ObjectProperty -InputObject $expected.artifact -Name "size"
    $catalogSize = [int64]0
    if ($null -ne $catalogSizeRaw -and -not [int64]::TryParse([string]$catalogSizeRaw, [ref]$catalogSize)) {
        throw "Catalog asset '$expectedAssetName' has a malformed size; expected zero for unpublished assets or a positive integer."
    }
    $catalogPublished = (Get-ObjectProperty -InputObject $expected.artifact -Name "published") -eq $true
    if ($catalogSize -lt 0 -or ($catalogPublished -and $catalogSize -le 0)) {
        throw "Catalog asset '$expectedAssetName' has an invalid size."
    }
    if ($catalogSize -gt 0 -and $catalogSize -ne $assetSize) {
        throw "Build asset size does not match the published catalog size for '$expectedAssetName'."
    }
    $catalogShaRaw = [string](Get-ObjectProperty -InputObject $expected.artifact -Name "sha256")
    if (-not [string]::IsNullOrWhiteSpace($catalogShaRaw)) {
        $catalogSha = $catalogShaRaw.ToLowerInvariant()
        if ($catalogSha -notmatch '^[0-9a-f]{64}$' -or $catalogSha -cne $assetSha256) {
            throw "Build asset SHA-256 does not match the published catalog digest for '$expectedAssetName'."
        }
    }
    Assert-FileMatches -Path $assetSourcePath -ExpectedSize $assetSize -ExpectedSha256 $assetSha256 -Description "Build asset '$expectedAssetName'"

    $verifiedComponents += [pscustomobject][ordered]@{
        kind = $expected.kind
        id = $expectedId
        version = $expectedVersion
        asset_name = $expectedAssetName
        size = $assetSize
        sha256 = $assetSha256
        source_path = $assetSourcePath
        catalog_entry = $expected.entry
    }
}

$modelFiles = @(Get-ObjectProperty -InputObject $model -Name "files")
if ($modelFiles.Count -eq 0) {
    throw "Model '$ModelId' has no files in the product ASR catalog."
}
$verifiedModelFiles = @()
$seenModelPaths = @{}
$modelTotalSize = [int64]0
foreach ($modelFile in $modelFiles) {
    if ($null -eq $modelFile) {
        throw "Model '$ModelId' contains an invalid null file entry."
    }
    $relativePath = Get-RequiredString -InputObject $modelFile -Name "path" -Context "Model '$ModelId' file"
    $segments = @(Get-SafeRelativeSegments -Value $relativePath -Description "Model '$ModelId' file path")
    $normalizedRelativePath = $segments -join "/"
    $modelPathKey = $normalizedRelativePath.ToLowerInvariant()
    if ($seenModelPaths.ContainsKey($modelPathKey)) {
        throw "Model '$ModelId' contains a duplicate file path: $normalizedRelativePath"
    }
    $seenModelPaths[$modelPathKey] = $true
    $expectedSize = Get-RequiredPositiveInt64 -InputObject $modelFile -Name "size" -Context "Model '$ModelId' file '$normalizedRelativePath'"
    $expectedSha256 = Get-RequiredSha256 -InputObject $modelFile -Name "sha256" -Context "Model '$ModelId' file '$normalizedRelativePath'"
    $sourcePath = Assert-ModelSourceFile -Root $modelRoot -Segments $segments -Description "Model '$ModelId' file '$normalizedRelativePath'"
    Assert-FileMatches -Path $sourcePath -ExpectedSize $expectedSize -ExpectedSha256 $expectedSha256 -Description "Model '$ModelId' file '$normalizedRelativePath'"
    if ($modelTotalSize -gt ([int64]::MaxValue - $expectedSize)) {
        throw "Model '$ModelId' total size exceeds Int64."
    }
    $modelTotalSize += $expectedSize
    $verifiedModelFiles += [pscustomobject][ordered]@{
        relative_path = $normalizedRelativePath
        segments = $segments
        size = $expectedSize
        sha256 = $expectedSha256
        source_path = $sourcePath
    }
}

$localAppData = Join-Path $sessionRootFull "LocalAppData"
$transVortexAppData = Join-Path $localAppData "TransVortex"
$artifactDownloadRoot = Join-Path $transVortexAppData "Downloads\ASR\artifacts"
$modelDownloadRoot = Join-Path $transVortexAppData "Downloads\ASR\models\$ModelId\$modelRevision"
$stagedCatalogPath = Join-Path $sessionRootFull "catalog\asr_components.json"
$reportPath = Join-Path $sessionRootFull "stage_report.json"

$componentReportRows = @()
foreach ($component in $verifiedComponents) {
    $destinationPath = Join-Path $artifactDownloadRoot "$($component.asset_name).part"
    $localUrl = "https://local-staging.invalid/$([System.Uri]::EscapeDataString($component.asset_name))"
    $component.catalog_entry.artifact.published = $true
    $component.catalog_entry.artifact.size = [int64]$component.size
    $component.catalog_entry.artifact.sha256 = [string]$component.sha256
    $component.catalog_entry.artifact.url = $localUrl
    $componentReportRows += [pscustomobject][ordered]@{
        kind = $component.kind
        id = $component.id
        version = $component.version
        asset_name = $component.asset_name
        size = [int64]$component.size
        sha256 = $component.sha256
        url = $localUrl
        source_path = $component.source_path
        destination_part = $destinationPath
    }
}

$modelReportRows = @()
foreach ($modelFile in $verifiedModelFiles) {
    $destinationBase = Join-PathSegments -Root $modelDownloadRoot -Segments $modelFile.segments
    $modelReportRows += [pscustomobject][ordered]@{
        path = $modelFile.relative_path
        size = [int64]$modelFile.size
        sha256 = $modelFile.sha256
        source_path = $modelFile.source_path
        destination_part = "$destinationBase.part"
    }
}

$report = [ordered]@{
    schema_version = 1
    ok = $true
    plan_only = [bool]$PlanOnly
    side_effects_applied = $false
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    session = [ordered]@{
        root = $sessionRootFull
        disposition = $sessionDisposition
        ownership_marker = $sessionMarkerPath
        report_path = $reportPath
    }
    environment = [ordered]@{
        LOCALAPPDATA = $localAppData
        TRANSVORTEX_ASR_CATALOG = $stagedCatalogPath
    }
    catalog = [ordered]@{
        source_path = $catalogPath
        staged_path = $stagedCatalogPath
        source_unchanged = $true
        schema_version = 1
    }
    build_manifest = [ordered]@{
        path = $buildManifestPath
        schema_version = 1
        release_tag = $manifestReleaseTag
    }
    components = $componentReportRows
    model = [ordered]@{
        id = $ModelId
        repository = $modelRepository
        revision = $modelRevision
        source_root = $modelRoot
        download_root = $modelDownloadRoot
        file_count = $modelReportRows.Count
        total_size = $modelTotalSize
        files = $modelReportRows
    }
}

if (-not $PlanOnly) {
    if ($sessionDisposition -eq "replace_owned") {
        $sourcePaths = @($buildManifestPath)
        $sourcePaths += @($verifiedComponents | ForEach-Object { $_.source_path })
        $sourcePaths += @($modelReportRows | ForEach-Object { $_.source_path })
        foreach ($sourcePath in $sourcePaths) {
            if (Test-PathUnderRoot -Path ([string]$sourcePath) -Root $sessionRootFull) {
                throw "Refusing -Force because an input source is inside SessionRoot and would be deleted: $sourcePath"
            }
        }
        Remove-Item -LiteralPath $sessionRootFull -Recurse -Force
    }
    New-Item -ItemType Directory -Path $sessionRootFull -Force | Out-Null

    $marker = [ordered]@{
        schema_version = 1
        owner = $sessionOwner
        session_root = $sessionRootFull
        created_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Utf8NoBom -Path $sessionMarkerPath -Content (($marker | ConvertTo-Json -Depth 5) + "`n")

    New-Item -ItemType Directory -Path $artifactDownloadRoot -Force | Out-Null
    foreach ($component in $componentReportRows) {
        Copy-Item -LiteralPath $component.source_path -Destination $component.destination_part -Force
        Assert-FileMatches -Path $component.destination_part -ExpectedSize ([int64]$component.size) -ExpectedSha256 ([string]$component.sha256) -Description "Staged build asset '$($component.asset_name)'"
    }

    foreach ($modelFile in $modelReportRows) {
        $destinationParent = Split-Path -Parent $modelFile.destination_part
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $modelFile.source_path -Destination $modelFile.destination_part -Force
        Assert-FileMatches -Path $modelFile.destination_part -ExpectedSize ([int64]$modelFile.size) -ExpectedSha256 ([string]$modelFile.sha256) -Description "Staged model file '$($modelFile.path)'"
    }

    $stagedCatalogDirectory = Split-Path -Parent $stagedCatalogPath
    New-Item -ItemType Directory -Path $stagedCatalogDirectory -Force | Out-Null
    Write-Utf8NoBom -Path $stagedCatalogPath -Content (($catalog | ConvertTo-Json -Depth 30) + "`n")

    $report.side_effects_applied = $true
    Write-Utf8NoBom -Path $reportPath -Content (($report | ConvertTo-Json -Depth 30) + "`n")
}

if ($Json) {
    $report | ConvertTo-Json -Depth 30
} else {
    [pscustomobject]$report
}
