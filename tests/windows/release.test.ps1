param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$builder = Join-Path $Root 'tools\build-windows-release.ps1'
$source = Join-Path $Root 'distribution\windows'
$scratch = Join-Path (Join-Path $Root 'dist\test-scratch') ('harness release test ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

function Expect-Failure([scriptblock]$Action, [string]$Name) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Expected failure: $Name" }
}

try {
    if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw 'Release builder is missing' }
    $sourceRun = & powershell.exe -NoProfile -File (Join-Path $source 'install.ps1') -VerifyOnly -PackageRoot $source 2>&1
    if ($LASTEXITCODE -ne 1 -or ($sourceRun -join ' ') -notmatch 'Unpack the complete .*\.zip.*install\.cmd') {
        throw "Source-tree launch lacks actionable guidance: $($sourceRun -join ' ')"
    }
    $one = Join-Path $scratch 'first output'
    $two = Join-Path $scratch 'second output'
    & $builder -SourceRoot $source -OutputDirectory $one -ExpectedVersion '0.4.2' | Out-Null
    & $builder -SourceRoot $source -OutputDirectory $two -ExpectedVersion '0.4.2' | Out-Null
    $direct = Join-Path $scratch 'direct invocation'
    $directOutput = & powershell.exe -NoProfile -File $builder -OutputDirectory $direct -ExpectedVersion '0.4.2' 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $direct 'agent-harness-windows-v0.4.2.zip'))) {
        throw "Direct builder invocation failed: $($directOutput -join ' ')"
    }
    $zip1 = Join-Path $one 'agent-harness-windows-v0.4.2.zip'
    if (-not (Test-Path -LiteralPath $zip1 -PathType Leaf)) { throw 'Versioned ZIP is missing' }
    $manifest1 = Get-Content -LiteralPath (Join-Path $one 'manifest.json') -Raw -Encoding UTF8
    $manifest2 = Get-Content -LiteralPath (Join-Path $two 'manifest.json') -Raw -Encoding UTF8
    if ($manifest1 -cne $manifest2) { throw 'Manifest is not reproducible' }
    $manifest = $manifest1 | ConvertFrom-Json
    if ($manifest.version -cne '0.4.2' -or $manifest.files.Count -ne 25) { throw 'Manifest version or file count is wrong' }
    if (-not (Test-Path -LiteralPath (Join-Path $one 'agent-harness-windows-v0.4.2.sha256'))) { throw 'ZIP checksum is missing' }

    $extract = Join-Path $scratch 'unpacked archive'
    Expand-Archive -LiteralPath $zip1 -DestinationPath $extract
    $packageFiles = @(Get-ChildItem -LiteralPath $extract -File -Recurse)
    if ($packageFiles.Count -ne 26) { throw 'ZIP contains unexpected file count' }
    if (-not (Test-Path -LiteralPath (Join-Path $extract 'readme.md')) -or
        (Test-Path -LiteralPath (Join-Path $extract 'payload\README.md'))) {
        throw 'Package documentation is in the wrong location'
    }
    if (@($packageFiles | Where-Object { $_.FullName -match '01-inputs|02-work|grilling|personal-agent-environment\.zip|library[\\/]sources[\\/]|memory[\\/](ideas|records)[\\/](?!README\.md)[^\\/]+\.md|history[\\/]' }).Count -ne 0) {
        throw 'ZIP contains project-private paths'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $extract 'payload\skills\memory-maintenance\SKILL.md'))) {
        throw 'Memory skill is missing from ZIP'
    }
    & powershell.exe -NoProfile -File (Join-Path $extract 'install.ps1') -VerifyOnly -PackageRoot $extract | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Extracted package did not verify' }
    $launch = 'call "' + (Join-Path $extract 'install.cmd') + '" -VerifyOnly <NUL'
    $launchOutput = & cmd.exe /d /c $launch 2>&1
    if ($LASTEXITCODE -ne 0 -or ($launchOutput -join ' ') -notmatch 'Package verification: PASS') {
        throw "Extracted install.cmd did not verify: $($launchOutput -join ' ')"
    }
    Add-Content -LiteralPath (Join-Path $extract 'payload\AGENTS.md') -Value 'tampered'
    & powershell.exe -NoProfile -File (Join-Path $extract 'install.ps1') -VerifyOnly -PackageRoot $extract | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Tampered payload was accepted' }

    $fixture = Join-Path $scratch 'source fixture'
    Copy-Item -LiteralPath $source -Destination $fixture -Recurse
    New-Item -ItemType File -Path (Join-Path $fixture 'private.txt') | Out-Null
    Expect-Failure { & $builder -SourceRoot $fixture -OutputDirectory (Join-Path $scratch 'bad-extra') } 'extra file'
    Remove-Item -LiteralPath (Join-Path $fixture 'private.txt')
    Remove-Item -LiteralPath (Join-Path $fixture 'payload\AGENTS.md')
    Expect-Failure { & $builder -SourceRoot $fixture -OutputDirectory (Join-Path $scratch 'bad-missing') } 'missing file'
    Copy-Item -LiteralPath (Join-Path $source 'payload\AGENTS.md') -Destination (Join-Path $fixture 'payload\AGENTS.md')
    Expect-Failure { & $builder -SourceRoot $fixture -OutputDirectory (Join-Path $scratch 'bad-version') -ExpectedVersion '0.4.0' } 'version mismatch'
    $linked = Join-Path $fixture 'payload\unexpected-link'
    New-Item -ItemType Junction -Path $linked -Target (Join-Path $source 'payload\memory') | Out-Null
    Expect-Failure { & $builder -SourceRoot $fixture -OutputDirectory (Join-Path $scratch 'bad-link') } 'linked directory'
    [IO.Directory]::Delete($linked, $false)
    Write-Output 'Release.Tests: PASS'
}
finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath((Join-Path $Root 'dist\test-scratch'))
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
