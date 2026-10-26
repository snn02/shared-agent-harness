param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path (Join-Path $Root 'dist\test-scratch') ('harness acceptance ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldPath = $env:PATH
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

try {
    $cyrillic = -join ([char[]]@(0x041F, 0x0440, 0x043E, 0x0444, 0x0438, 0x043B, 0x044C))
    $out = Join-Path $scratch 'release'
    & (Join-Path $Root 'tools\build-windows-release.ps1') -OutputDirectory $out | Out-Null
    $zip = Join-Path $out 'agent-harness-windows-v0.4.3.zip'
    $expectedHash = ((Get-Content -LiteralPath (Join-Path $out 'agent-harness-windows-v0.4.3.sha256') -Raw).Split(' ')[0]).Trim()
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHash) { throw 'Release SHA-256 differs' }
    $extract = Join-Path $scratch ('unpacked ' + $cyrillic)
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    $launcherPath = @(Get-ChildItem -LiteralPath $extract -Filter '*.cmd' -File)[0].FullName
    $launcher = Get-Content -LiteralPath $launcherPath -Raw
    if ($launcher -notmatch 'install\.ps1" %\*') { throw 'Launcher does not forward safe verification arguments' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /c ""' + $launcherPath + '" -VerifyOnly -PackageRoot "' + $extract + '""'
    $start.UseShellExecute = $false
    # cmd.exe does not reorder PowerShell 7's PSModulePath for Windows PowerShell 5.1.
    $start.EnvironmentVariables['PSModulePath'] = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.WriteLine('')
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        throw 'Launcher verification timed out'
    }
    $launchOutput = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0 -or $launchOutput -notmatch 'Package verification: PASS') {
        throw "Launcher verification failed: $launchOutput"
    }
    $check = & $ps -NoProfile -File (Join-Path $extract 'install.ps1') -VerifyOnly -PackageRoot $extract 2>&1
    if ($LASTEXITCODE -ne 0 -or ($check -join "`n") -notmatch 'PASS') { throw 'Extracted package did not verify' }

    $profile = Join-Path $scratch ($cyrillic + ' with spaces')
    $codexHome = Join-Path $profile '.codex'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $codexHome 'AGENTS.md'), 'Keep my existing rules')
    $bin = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    [IO.File]::WriteAllText((Join-Path $bin 'codex.cmd'), "@echo off`r`necho codex 0.3.0`r`n")
    [IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'), "@echo off`r`necho Claude Code 2.1.268`r`n")
    $env:PATH = $bin + ';' + $oldPath

    $installArgs = @('-NoProfile', '-File', (Join-Path $extract 'install.ps1'), '-PackageRoot', $extract,
        '-ProfileRoot', $profile, '-SelectApps', 'Codex,Claude', '-Apply', '-Accept')
    $first = & $ps @installArgs 2>&1
    if ($LASTEXITCODE -ne 2) { throw "Expected partial success, got $LASTEXITCODE`: $($first -join ' ')" }
    if ((Get-Content -LiteralPath (Join-Path $codexHome 'AGENTS.md') -Raw) -cne 'Keep my existing rules') {
        throw 'Occupied Codex rules were changed'
    }
    $shared = Join-Path $profile '.agents\AGENTS.md'
    if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) { throw 'Shared rules missing after partial install' }
    $claudeRules = Join-Path $profile '.claude\CLAUDE.md'
    $import = '@' + $shared
    $actualClaude = Get-Content -LiteralPath $claudeRules -Raw -Encoding UTF8
    if ($actualClaude -notmatch [regex]::Escape($import)) {
        throw "Claude import missing. Expected $import; actual $actualClaude; result $($first -join ' ')"
    }
    $markerPath = Join-Path $profile '.agents\.harness-install.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($marker.connections.Codex -cne 'error' -or $marker.connections.Claude -cne 'connected') {
        throw 'Partial adapter statuses were not recorded accurately'
    }
    $markerHash = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash
    $second = & $ps @installArgs 2>&1
    if ($LASTEXITCODE -ne 2 -or (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash -cne $markerHash) {
        throw "Repeat partial install was not stable: $($second -join ' ')"
    }
    if (@((Get-Content -LiteralPath $claudeRules -Encoding UTF8) | Where-Object { $_ -ceq $import }).Count -ne 1) {
        throw 'Claude import was duplicated'
    }
    Write-Output 'EndToEnd.Tests: PASS'
}
finally {
    $env:PATH = $oldPath
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath((Join-Path $Root 'dist\test-scratch'))
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
