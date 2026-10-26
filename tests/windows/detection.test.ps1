param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path (Join-Path $Root 'dist\test-scratch') ('harness detection ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldPath = $env:PATH
$oldCodexHome = $env:CODEX_HOME
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-Json([string]$Installer, [string]$Profile, [string[]]$Options) {
    $raw = & $ps -NoProfile -File $Installer -PackageRoot (Split-Path -Parent $Installer) -ProfileRoot $Profile @Options
    if ($LASTEXITCODE -ne 0) { throw "Installer failed: $($raw -join ' ')" }
    $json = $raw -join "`n"
    $parsed = ConvertFrom-Json -InputObject $json
    foreach ($item in $parsed) { Write-Output $item }
}

try {
    $out = Join-Path $scratch 'package output'
    & (Join-Path $Root 'tools\build-windows-release.ps1') -OutputDirectory $out | Out-Null
    $extract = Join-Path $scratch 'extracted'
    Expand-Archive -LiteralPath (Join-Path $out 'agent-harness-windows-v0.4.2.zip') -DestinationPath $extract
    $installer = Join-Path $extract 'install.ps1'
    $profile = Join-Path $scratch 'fictional profile'
    New-Item -ItemType Directory -Path $profile | Out-Null
    $bin = Join-Path $scratch 'fixture bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    $env:PATH = $bin + ';' + $PSHOME + ';C:\Windows\System32;C:\Windows'
    $empty = Invoke-Json $installer $profile @('-ListOnly')
    if (@($empty | Where-Object { $_.status -eq 'detected' }).Count -ne 0) { throw 'Empty profile detected an app' }
    if (Test-Path -LiteralPath (Join-Path $profile '.agents')) { throw 'ListOnly wrote to profile' }

    [IO.File]::WriteAllText((Join-Path $bin 'codex.cmd'), "@echo off`r`necho codex-cli 0.163.0`r`n")
    [IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'), "@echo off`r`necho Claude Code 2.1.268`r`n")
    $npm = Join-Path $profile 'AppData\Roaming\npm'
    New-Item -ItemType Directory -Path $npm -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $npm 'opencode.cmd'), "@echo off`r`necho opencode 1.18.11`r`n")
    $env:CODEX_HOME = Join-Path $profile 'custom codex home'
    $found = @(Invoke-Json $installer $profile @('-ListOnly'))
    if (@($found | Where-Object { $_.status -eq 'detected' }).Count -ne 3) {
        throw "Three apps were not detected: $($found | ConvertTo-Json -Compress -Depth 4)"
    }
    $codex = @($found | Where-Object { $_.name -eq 'Codex' })[0]
    if ($codex.version -cne '0.163.0' -or $codex.rulesTarget -cne (Join-Path $env:CODEX_HOME 'AGENTS.md')) {
        throw 'Codex version or override target is wrong'
    }
    $opencode = @($found | Where-Object { $_.name -eq 'OpenCode' })[0]
    if ($opencode.executable -cne (Join-Path $npm 'opencode.cmd')) { throw 'OpenCode outside PATH was not found' }
    $plan = @(Invoke-Json $installer $profile @('-PlanOnly', '-SelectApps', 'Codex'))
    if ($plan.Count -ne 1 -or $plan[0].name -cne 'Codex') { throw 'Selection did not keep only Codex' }
    if (Test-Path -LiteralPath (Join-Path $profile '.agents')) { throw 'PlanOnly wrote to profile' }

    $numbered = '1,3' | & $ps -NoProfile -File $installer -PackageRoot $extract -ProfileRoot $profile -PlanOnly -ConsoleSelection 2>&1
    if ($LASTEXITCODE -ne 0 -or ($numbered -join ' ') -notmatch 'Codex' -or
        ($numbered -join ' ') -notmatch 'OpenCode' -or ($numbered -join ' ') -match '"name"\s*:\s*"Claude"') {
        throw "Numbered fallback selection failed: $($numbered -join ' ')"
    }
    if (Test-Path -LiteralPath (Join-Path $profile '.agents')) { throw 'Fallback selection wrote to profile' }

    [IO.File]::WriteAllText((Join-Path $npm 'opencode.cmd'), "@echo off`r`necho opencode 2.0.0`r`n")
    $unsupported = @(Invoke-Json $installer $profile @('-ListOnly'))
    if (@($unsupported | Where-Object { $_.name -eq 'OpenCode' -and $_.status -eq 'review' }).Count -ne 1) {
        throw 'Unsupported OpenCode major was not held for review'
    }
    Write-Output 'Detection.Tests: PASS'
}
finally {
    $env:PATH = $oldPath
    $env:CODEX_HOME = $oldCodexHome
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath((Join-Path $Root 'dist\test-scratch'))
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
