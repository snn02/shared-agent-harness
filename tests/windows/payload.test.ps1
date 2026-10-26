param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$package = Join-Path $Root 'distribution\windows'
$payload = Join-Path $package 'payload'
$expected = @(
    'AGENTS.md',
    'memory/profile.md',
    'memory/company.md',
    'memory/decisions.md',
    'memory/ideas/README.md',
    'memory/records/README.md',
    'rules/personal.md',
    'skills/memory-maintenance/SKILL.md',
    'skills/document-ingest/SKILL.md',
    'skills/document-ingest/scripts/ingest_model.py',
    'skills/document-ingest/scripts/document_store.py',
    'skills/document-ingest/scripts/extract_docx.py',
    'skills/document-ingest/scripts/extract_fb2.py',
    'skills/document-ingest/scripts/extract_pdf.py',
    'skills/document-ingest/scripts/ingest.py',
    'skills/document-ingest/scripts/requirements.txt',
    'skills/document-ingest/scripts/setup-runtime.ps1',
    'skills/source-to-knowledge/SKILL.md',
    'knowledge/README.md',
    'knowledge/index.md'
) | Sort-Object

if (-not (Test-Path -LiteralPath $payload -PathType Container)) { throw 'Payload directory is missing' }
$actual = @(Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object {
    $_.FullName.Substring($payload.Length + 1).Replace('\', '/')
} | Sort-Object)
if (($actual -join '|') -ne ($expected -join '|')) {
    throw "Payload file set differs: $($actual -join ', ')"
}
foreach ($item in Get-ChildItem -LiteralPath $payload -Recurse -Force) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Payload link is forbidden: $($item.FullName)" }
}
$version = (Get-Content -LiteralPath (Join-Path $package 'version.txt') -Raw).Trim()
if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw "Invalid package version: $version" }
$rules = Get-Content -LiteralPath (Join-Path $payload 'AGENTS.md') -Raw -Encoding UTF8
foreach ($term in @('knowledge/', 'memory/ideas', 'memory/records', 'approval')) {
    if ($rules -notmatch $term) { throw "AGENTS.md lacks $term" }
}
$text = Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
if (($text -join "`n") -match '(?i)C:\\Users\\|/Users/|BEGIN [A-Z ]*PRIVATE KEY|sk-proj-') {
    throw 'Payload contains a private path or secret marker'
}
$skill = Get-Content -LiteralPath (Join-Path $payload 'skills\memory-maintenance\SKILL.md') -Raw -Encoding UTF8
foreach ($term in @('одобрения', 'records/', 'Claude Code')) {
    if ($skill -notmatch [regex]::Escape($term)) { throw "Memory skill lacks $term" }
}
$company = Get-Content -LiteralPath (Join-Path $payload 'memory\company.md') -Raw -Encoding UTF8
if ($company -notmatch 'Профиль компании') { throw 'Company profile template is missing' }
$manual = @(Get-ChildItem -LiteralPath $package -Filter '*.md' -File)
if ($manual.Count -ne 2 -or -not (Test-Path -LiteralPath (Join-Path $package 'installation-guide.md')) -or
    -not (Test-Path -LiteralPath (Join-Path $package 'readme.md'))) {
    throw 'Package requires installation-guide.md and readme.md'
}
$instruction = Get-Content -LiteralPath (Join-Path $package 'installation-guide.md') -Raw -Encoding UTF8
foreach ($term in @('install.cmd', 'manifest.json', 'YES', 'readme.md')) {
    if ($instruction -notmatch [regex]::Escape($term)) { throw "Instruction lacks $term" }
}
if ($instruction -match 'Как наполнить знания|Get-FileHash|0\.3\.0|payload/AGENTS\.md') {
    throw 'Installation guide contains advanced or obsolete instructions'
}
$readme = Get-Content -LiteralPath (Join-Path $package 'readme.md') -Raw -Encoding UTF8
foreach ($term in @('Codex', 'Claude Code', 'OpenCode', 'memory/', 'knowledge/', 'Как начать наполнять знания',
        'memory-maintenance', 'document-ingest', 'source-to-knowledge')) {
    if ($readme -notmatch [regex]::Escape($term)) { throw "README lacks $term" }
}
Write-Output 'Payload.Tests: PASS'
