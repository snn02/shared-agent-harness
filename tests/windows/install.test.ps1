param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path (Join-Path $Root 'dist\test-scratch') ('harness install ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldPath = $env:PATH
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Run-Install([string]$Installer, [string]$Profile) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $ps -NoProfile -File $Installer -PackageRoot (Split-Path -Parent $Installer) -ProfileRoot $Profile -SelectApps Claude -Apply -Accept 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ code = $code; output = ($output -join "`n") }
}

try {
    $out = Join-Path $scratch 'package'
    & (Join-Path $Root 'tools\build-windows-release.ps1') -OutputDirectory $out | Out-Null
    $extract = Join-Path $scratch 'unpacked'
    Expand-Archive -LiteralPath (Join-Path $out 'agent-harness-windows-v0.4.2.zip') -DestinationPath $extract
    $installer = Join-Path $extract 'install.ps1'
    $bin = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    [IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'), "@echo off`r`necho Claude Code 2.1.268`r`n")
    $env:PATH = $bin + ';' + $PSHOME + ';C:\Windows\System32;C:\Windows'

    $fresh = Join-Path $scratch 'fresh profile'
    New-Item -ItemType Directory -Path $fresh | Out-Null
    $first = Run-Install $installer $fresh
    if ($first.code -ne 0) { throw "Fresh install failed: $($first.output)" }
    $agents = Join-Path $fresh '.agents'
    $rules = Join-Path $agents 'AGENTS.md'
    $personalRules = Join-Path $agents 'rules\personal.md'
    $marker = Join-Path $agents '.harness-install.json'
    if (-not (Test-Path -LiteralPath $rules) -or -not (Test-Path -LiteralPath $personalRules) -or
        -not (Test-Path -LiteralPath $marker)) { throw "Fresh install lacks rules, personal template or marker: $($first.output)" }
    if ((Get-Content -LiteralPath $personalRules -Raw -Encoding UTF8) -notmatch 'библиотек') {
        throw 'Personal template does not explain where to register the library'
    }
    $state = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.schema -ne 1 -or $state.version -cne '0.4.2' -or -not $state.files.'AGENTS.md'.baseHash) {
        throw 'Marker lacks the accepted base hash'
    }
    $before = (Get-FileHash -LiteralPath $rules -Algorithm SHA256).Hash
    $markerBefore = (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash
    $second = Run-Install $installer $fresh
    if ($second.code -ne 0 -or $before -cne (Get-FileHash -LiteralPath $rules -Algorithm SHA256).Hash -or
        $markerBefore -cne (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash) {
        throw 'Repeat install changed existing files'
    }
    [IO.File]::WriteAllText($personalRules, 'Owner-approved rule')
    $personalRepeat = Run-Install $installer $fresh
    if ($personalRepeat.code -ne 0 -or [IO.File]::ReadAllText($personalRules) -cne 'Owner-approved rule') {
        throw "Installer changed personal rules: $($personalRepeat.output)"
    }

    $answerProfile = Join-Path $scratch 'confirmation profile'
    New-Item -ItemType Directory -Path $answerProfile | Out-Null
    $declined = 'No' | & $ps -NoProfile -File $installer -PackageRoot $extract -ProfileRoot $answerProfile -SelectApps Claude -Apply 2>&1
    if (Test-Path -LiteralPath (Join-Path $answerProfile '.agents')) {
        throw "Negative answer wrote files: $($declined -join ' ')"
    }
    $approved = 'Yes' | & $ps -NoProfile -File $installer -PackageRoot $extract -ProfileRoot $answerProfile -SelectApps Claude -Apply 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $answerProfile '.agents\.harness-install.json'))) {
        throw "Mixed-case Yes did not install: $($approved -join ' ')"
    }

    $existing = Join-Path $scratch 'existing profile'
    $existingAgents = Join-Path $existing '.agents'
    New-Item -ItemType Directory -Path (Join-Path $existingAgents 'memory') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $extract 'payload\AGENTS.md') -Destination (Join-Path $existingAgents 'AGENTS.md')
    [IO.File]::WriteAllText((Join-Path $existingAgents 'memory\company.md'), 'private company profile')
    [IO.File]::WriteAllText((Join-Path $existingAgents 'my-notes.md'), 'untouched')
    $merge = Run-Install $installer $existing
    if ($merge.code -ne 2) { throw "Existing directory merge did not report a partial result: $($merge.output)" }
    if ((Get-Content -LiteralPath (Join-Path $existingAgents 'memory\company.md') -Raw) -cne 'private company profile' -or
        (Get-Content -LiteralPath (Join-Path $existingAgents 'my-notes.md') -Raw) -cne 'untouched') {
        throw 'Existing user data was changed'
    }
    $mergeState = Get-Content -LiteralPath (Join-Path $existingAgents '.harness-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($mergeState.files.'memory/company.md'.status -cne 'conflict') { throw 'Noncritical conflict not recorded' }

    $conflict = Join-Path $scratch 'root conflict profile'
    $conflictAgents = Join-Path $conflict '.agents'
    New-Item -ItemType Directory -Path $conflictAgents -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $conflictAgents 'AGENTS.md'), 'owner instructions')
    $blocked = Run-Install $installer $conflict
    if ($blocked.code -eq 0 -or (Get-Content -LiteralPath (Join-Path $conflictAgents 'AGENTS.md') -Raw) -cne 'owner instructions') {
        throw 'Conflicting root rules were accepted or changed'
    }
    if (Test-Path -LiteralPath (Join-Path $conflictAgents '.harness-install.json')) { throw 'Blocked install wrote marker' }

    $linkedProfile = Join-Path $scratch 'linked profile'
    New-Item -ItemType Directory -Path $linkedProfile | Out-Null
    $external = Join-Path $scratch 'external'
    New-Item -ItemType Directory -Path $external | Out-Null
    [IO.File]::WriteAllText((Join-Path $external 'sentinel.txt'), 'safe')
    $junction = Join-Path $linkedProfile '.agents'
    New-Item -ItemType Junction -Path $junction -Target $external | Out-Null
    $rejected = Run-Install $installer $linkedProfile
    [IO.Directory]::Delete($junction, $false)
    if ($rejected.code -eq 0 -or (Get-Content -LiteralPath (Join-Path $external 'sentinel.txt') -Raw) -cne 'safe') {
        throw 'Linked .agents was not rejected safely'
    }

    $profileTarget = Join-Path $scratch 'profile target'
    New-Item -ItemType Directory -Path $profileTarget | Out-Null
    $profileLink = Join-Path $scratch 'profile link'
    New-Item -ItemType Junction -Path $profileLink -Target $profileTarget | Out-Null
    $rootLinked = Run-Install $installer $profileLink
    [IO.Directory]::Delete($profileLink, $false)
    if ($rootLinked.code -eq 0 -or (Test-Path -LiteralPath (Join-Path $profileTarget '.agents'))) {
        throw 'Linked profile root was not rejected safely'
    }
    Write-Output 'Install.Tests: PASS'
}
finally {
    $env:PATH = $oldPath
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath((Join-Path $Root 'dist\test-scratch'))
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
