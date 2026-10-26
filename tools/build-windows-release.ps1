param(
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
if (-not $SourceRoot) { $SourceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'distribution\windows' }
$source = [IO.Path]::GetFullPath($SourceRoot)
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'SourceRoot is not a directory' }
if ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'SourceRoot is a link' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be outside SourceRoot'
}
$version = (Get-Content -LiteralPath (Join-Path $source 'version.txt') -Raw -Encoding UTF8).Trim()
if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'version.txt is invalid' }
if ($ExpectedVersion -and $version -cne $ExpectedVersion) { throw 'version.txt does not match requested release version' }

$launcher = @(Get-ChildItem -LiteralPath $source -Filter '*.cmd' -File -Force)
if (-not (Test-Path -LiteralPath (Join-Path $source 'installation-guide.md') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $source 'readme.md') -PathType Leaf) -or
    $launcher.Count -ne 1) { throw 'Package needs installation-guide.md, readme.md and one launcher' }
$allowed = @(
    'version.txt', 'install.ps1', 'installation-guide.md', 'readme.md', 'LICENSE', $launcher[0].Name,
    'payload/AGENTS.md',
    'payload/memory/profile.md', 'payload/memory/company.md',
    'payload/memory/decisions.md',
    'payload/memory/ideas/README.md',
    'payload/memory/records/README.md',
    'payload/rules/personal.md',
    'payload/skills/memory-maintenance/SKILL.md',
    'payload/skills/document-ingest/SKILL.md',
    'payload/skills/document-ingest/scripts/ingest_model.py',
    'payload/skills/document-ingest/scripts/document_store.py',
    'payload/skills/document-ingest/scripts/extract_docx.py',
    'payload/skills/document-ingest/scripts/extract_fb2.py',
    'payload/skills/document-ingest/scripts/extract_pdf.py',
    'payload/skills/document-ingest/scripts/ingest.py',
    'payload/skills/document-ingest/scripts/requirements.txt',
    'payload/skills/document-ingest/scripts/setup-runtime.ps1',
    'payload/skills/source-to-knowledge/SKILL.md',
    'payload/knowledge/README.md', 'payload/knowledge/index.md'
) | Sort-Object
$items = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
foreach ($item in $items) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package link is forbidden: $($item.FullName)" }
    $relative = $item.FullName.Substring($source.Length + 1).Replace('\', '/')
    if ($item.PSIsContainer) {
        if (@($allowed | Where-Object { $_.StartsWith($relative + '/', [StringComparison]::Ordinal) }).Count -eq 0) {
            throw "Unexpected directory: $relative"
        }
    }
}
$actual = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    $_.FullName.Substring($source.Length + 1).Replace('\', '/')
} | Sort-Object)
if (($actual -join '|') -cne ($allowed -join '|')) { throw 'Package file list does not match the allowlist' }

$files = @($allowed | ForEach-Object {
    $path = $_
    $file = Join-Path $source ($path.Replace('/', '\'))
    [ordered]@{ path = $path; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$manifest = [ordered]@{ schema = 1; version = $version; files = $files }
$json = (ConvertTo-Json -InputObject $manifest -Depth 5) + "`n"

New-Item -ItemType Directory -Path $output -Force | Out-Null
$stage = Join-Path $output ('stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($path in $allowed) {
        $target = Join-Path $stage ($path.Replace('/', '\'))
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath (Join-Path $source ($path.Replace('/', '\'))) -Destination $target
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'), $json, $utf8)
    $zip = Join-Path $output ('agent-harness-windows-v' + $version + '.zip')
    if (Test-Path -LiteralPath $zip) { throw 'Output ZIP already exists; choose an empty output directory' }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    [IO.File]::WriteAllText((Join-Path $output 'manifest.json'), $json, $utf8)
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $output ('agent-harness-windows-v' + $version + '.sha256')), "$hash  $(Split-Path -Leaf $zip)`n", $utf8)
    Write-Output $zip
}
finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    if ($resolved.StartsWith($output + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
