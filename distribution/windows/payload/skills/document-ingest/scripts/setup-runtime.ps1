param([string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'agent-harness\ingest-runtime'))

$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'Python 3.12 is required; install it before enabling ingest.' }
$version = (& $python.Source -c 'import sys; print(".".join(map(str, sys.version_info[:2])))').Trim()
if ($version -cne '3.12') { throw "Python 3.12 is required; detected $version" }
$root = [IO.Path]::GetFullPath($RuntimeRoot)
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
$venv = Join-Path $root '.venv'
if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe'))) { & $python.Source -m venv $venv }
$venvPython = Join-Path $venv 'Scripts\python.exe'
& $venvPython -m pip install --requirement (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Could not install pinned ingest dependencies' }
Write-Output "Ingest Python: $venvPython"
$tesseract = Get-Command tesseract -ErrorAction SilentlyContinue
if (-not $tesseract) {
    Write-Warning 'Tesseract not found; scanned PDF pages will have partial status.'
} else {
    $langs = @(& $tesseract.Source --list-langs 2>&1)
    foreach ($language in @('rus', 'eng')) {
        if ($langs -notcontains $language) { Write-Warning "Tesseract language model $language is missing." }
    }
}
