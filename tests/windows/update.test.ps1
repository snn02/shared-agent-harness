param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path (Join-Path $Root 'dist\test-scratch') ('harness update ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldPath = $env:PATH
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Run-Release([string]$Package, [string]$Profile, [bool]$Accept, [bool]$InjectFault = $false) {
    $args = @('-NoProfile', '-File', (Join-Path $Package 'install.ps1'), '-PackageRoot', $Package,
        '-ProfileRoot', $Profile, '-SelectApps', 'Claude', '-Apply')
    if ($Accept) { $args += '-Accept' }
    if ($InjectFault) { $args += '-FaultAfterUpdate' }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $ps @args 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ code = $code; output = ($output -join "`n") }
}

function New-Profile([string]$Name) {
    $path = Join-Path $scratch $Name
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

try {
    $builder = Join-Path $Root 'tools\build-windows-release.ps1'
    $v1Out = Join-Path $scratch 'old build'
    & $builder -OutputDirectory $v1Out -ExpectedVersion '0.4.3' | Out-Null
    $v1 = Join-Path $scratch 'old extracted'
    Expand-Archive -LiteralPath (Join-Path $v1Out 'agent-harness-windows-v0.4.3.zip') -DestinationPath $v1

    $v2Source = Join-Path $scratch 'new source'
    Copy-Item -LiteralPath (Join-Path $Root 'distribution\windows') -Destination $v2Source -Recurse
    [IO.File]::WriteAllText((Join-Path $v2Source 'version.txt'), "0.4.4`n")
    Add-Content -LiteralPath (Join-Path $v2Source 'payload\AGENTS.md') -Value "`nPilot update instruction." -Encoding UTF8
    $v2Out = Join-Path $scratch 'new build'
    & $builder -SourceRoot $v2Source -OutputDirectory $v2Out -ExpectedVersion '0.4.4' | Out-Null
    $v2 = Join-Path $scratch 'new extracted'
    Expand-Archive -LiteralPath (Join-Path $v2Out 'agent-harness-windows-v0.4.4.zip') -DestinationPath $v2

    $bin = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    [IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'), "@echo off`r`necho Claude Code 2.1.268`r`n")
    $env:PATH = $bin + ';' + $PSHOME + ';C:\Windows\System32;C:\Windows'

    $clean = New-Profile 'clean profile'
    if ((Run-Release $v1 $clean $true).code -ne 0) { throw 'Initial clean install failed' }
    $agentsRoot = Join-Path $clean '.agents'
    $personal = @{
        'custom\owned-file.txt' = 'owner file'
        'memory\ideas\owned-idea.md' = 'owner idea'
        'memory\source-notes\legacy-source.md' = 'owner legacy note'
        'knowledge\foundations\legacy-source.md' = 'owner legacy summary'
        'rules\personal.md' = 'owner rule'
        'history\entry.md' = 'owner history'
    }
    foreach ($relative in $personal.Keys) {
        $file = Join-Path $agentsRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
        [IO.File]::WriteAllText($file, $personal[$relative])
    }
    $localIndex = Join-Path $agentsRoot 'knowledge\index.md'
    Add-Content -LiteralPath $localIndex -Value "`n- [owner-source.md](owner-source.md) — approved source." -Encoding UTF8
    $localIndexBytes = [IO.File]::ReadAllBytes($localIndex)
    $oldRules = [IO.File]::ReadAllBytes((Join-Path $clean '.agents\AGENTS.md'))
    $updated = Run-Release $v2 $clean $true
    if ($updated.code -ne 0) { throw "Clean update failed: $($updated.output)" }
    if ($updated.output -notmatch 'Pilot update instruction') { throw 'Update preview did not show the changed rule' }
    $newText = Get-Content -LiteralPath (Join-Path $clean '.agents\AGENTS.md') -Raw -Encoding UTF8
    if ($newText -notmatch 'Pilot update instruction') { throw 'Unmodified rules did not update' }
    foreach ($relative in $personal.Keys) {
        if ([IO.File]::ReadAllText((Join-Path $agentsRoot $relative)) -cne $personal[$relative]) {
            throw "Personal file changed during update: $relative"
        }
    }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$localIndexBytes, [byte[]][IO.File]::ReadAllBytes($localIndex))) {
        throw 'Locally populated knowledge index changed during update'
    }
    $state = Get-Content -LiteralPath (Join-Path $clean '.agents\.harness-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.version -cne '0.4.4' -or -not $state.complete) { throw 'Successful update marker is wrong' }
    if ($state.files.'knowledge/index.md'.status -cne 'local') { throw 'Unchanged package file with local edits was not preserved as local' }
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $clean '.agents\.harness-backups') -Filter 'AGENTS.md' -File -Recurse)
    if ($backups.Count -ne 1 -or -not [Linq.Enumerable]::SequenceEqual([byte[]]$oldRules, [byte[]][IO.File]::ReadAllBytes($backups[0].FullName))) {
        throw 'Exact backup of prior rules is missing'
    }
    $newHash = (Get-FileHash -LiteralPath (Join-Path $clean '.agents\AGENTS.md') -Algorithm SHA256).Hash
    if ((Run-Release $v2 $clean $true).code -ne 0 -or
        $newHash -cne (Get-FileHash -LiteralPath (Join-Path $clean '.agents\AGENTS.md') -Algorithm SHA256).Hash) {
        throw 'Repeat of new release was not a no-op'
    }
    $older = Run-Release $v1 $clean $true
    if ($older.code -eq 0 -or $newHash -cne (Get-FileHash -LiteralPath (Join-Path $clean '.agents\AGENTS.md') -Algorithm SHA256).Hash) {
        throw 'Older package downgraded the installation'
    }

    $edited = New-Profile 'edited profile'
    if ((Run-Release $v1 $edited $true).code -ne 0) { throw 'Initial edited install failed' }
    $editedRules = Join-Path $edited '.agents\AGENTS.md'
    Add-Content -LiteralPath $editedRules -Value "`nOwner change." -Encoding UTF8
    $editedCompany = Join-Path $edited '.agents\memory\company.md'
    Add-Content -LiteralPath $editedCompany -Value "`nOwner-approved company context." -Encoding UTF8
    $partial = Run-Release $v2 $edited $true
    $partialState = Get-Content -LiteralPath (Join-Path $edited '.agents\.harness-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($partial.code -ne 2 -or $partial.output -notmatch 'Adapter connections skipped' -or
        -not (Get-Content -LiteralPath $editedRules -Raw -Encoding UTF8).Contains('Owner change.') -or
        -not (Get-Content -LiteralPath $editedCompany -Raw -Encoding UTF8).Contains('Owner-approved company context.') -or
        $partialState.complete -or $partialState.files.'AGENTS.md'.status -cne 'conflict') {
        throw "Local edit was not preserved as a partial update: $($partial.output)"
    }

    $missing = New-Profile 'missing file profile'
    if ((Run-Release $v1 $missing $true).code -ne 0) { throw 'Initial missing-file install failed' }
    Remove-Item -LiteralPath (Join-Path $missing '.agents\memory\company.md')
    if ((Run-Release $v2 $missing $true).code -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $missing '.agents\memory\company.md'))) {
        throw 'Missing managed file was not restored in new release'
    }

    $declined = New-Profile 'declined profile'
    if ((Run-Release $v1 $declined $true).code -ne 0) { throw 'Initial declined install failed' }
    $before = (Get-FileHash -LiteralPath (Join-Path $declined '.agents\AGENTS.md') -Algorithm SHA256).Hash
    $no = Run-Release $v2 $declined $false
    if ($no.code -ne 0 -or $before -cne (Get-FileHash -LiteralPath (Join-Path $declined '.agents\AGENTS.md') -Algorithm SHA256).Hash) {
        throw 'Declined update changed rules'
    }

    $broken = New-Profile 'broken marker profile'
    if ((Run-Release $v1 $broken $true).code -ne 0) { throw 'Initial broken-marker install failed' }
    [IO.File]::WriteAllText((Join-Path $broken '.agents\.harness-install.json'), '{invalid json')
    $refused = Run-Release $v2 $broken $true
    if ($refused.code -eq 0) { throw 'Corrupt marker was accepted' }

    $unmarked = New-Profile 'unmarked profile'
    if ((Run-Release $v1 $unmarked $true).code -ne 0) { throw 'Initial unmarked install failed' }
    $unmarkedRules = Join-Path $unmarked '.agents\AGENTS.md'
    $unmarkedHash = (Get-FileHash -LiteralPath $unmarkedRules -Algorithm SHA256).Hash
    Remove-Item -LiteralPath (Join-Path $unmarked '.agents\.harness-install.json')
    $unknownBase = Run-Release $v2 $unmarked $true
    if ($unknownBase.code -eq 0 -or $unmarkedHash -cne (Get-FileHash -LiteralPath $unmarkedRules -Algorithm SHA256).Hash) {
        throw 'An unmarked prior version was overwritten'
    }

    $retired = New-Profile 'retired file profile'
    if ((Run-Release $v1 $retired $true).code -ne 0) { throw 'Initial retired-file install failed' }
    $legacy = Join-Path $retired '.agents\memory\index.md'
    [IO.File]::WriteAllText($legacy, 'old managed file')
    $retiredMarkerPath = Join-Path $retired '.agents\.harness-install.json'
    $retiredMarker = Get-Content -LiteralPath $retiredMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $retiredMarker.files | Add-Member -NotePropertyName 'memory/index.md' -NotePropertyValue ([pscustomobject]@{
        baseHash = (Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash.ToLowerInvariant(); status = 'created'
    })
    [IO.File]::WriteAllText($retiredMarkerPath, (ConvertTo-Json -InputObject $retiredMarker -Depth 8))
    if ((Run-Release $v2 $retired $true).code -ne 0 -or (Get-Content -LiteralPath $legacy -Raw) -cne 'old managed file') {
        throw 'File retired from package was deleted or update failed'
    }
    $retiredState = Get-Content -LiteralPath $retiredMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($retiredState.files.'memory/index.md'.status -cne 'retired') { throw 'Retired file not recorded' }

    $fault = New-Profile 'fault profile'
    if ((Run-Release $v1 $fault $true).code -ne 0) { throw 'Initial fault-case install failed' }
    $faultRules = Join-Path $fault '.agents\AGENTS.md'
    $faultHash = (Get-FileHash -LiteralPath $faultRules -Algorithm SHA256).Hash
    $failedUpdate = Run-Release $v2 $fault $true $true
    $faultState = Get-Content -LiteralPath (Join-Path $fault '.agents\.harness-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($failedUpdate.code -eq 0 -or $faultHash -cne (Get-FileHash -LiteralPath $faultRules -Algorithm SHA256).Hash -or
        $faultState.version -cne '0.4.3') { throw 'Interrupted update did not restore the prior version' }
    Write-Output 'Update.Tests: PASS'
}
finally {
    $env:PATH = $oldPath
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath((Join-Path $Root 'dist\test-scratch'))
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
