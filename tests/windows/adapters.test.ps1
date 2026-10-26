param([string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path (Join-Path $Root 'dist\test-scratch') ('harness adapters ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldPath = $env:PATH
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Run-Install([string]$Package, [string]$Profile, [string]$Names) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $ps -NoProfile -File (Join-Path $Package 'install.ps1') -PackageRoot $Package -ProfileRoot $Profile -SelectApps $Names -Apply -Accept 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ code = $code; output = ($raw -join "`n") }
}

function New-Profile([string]$Name) {
    $path = Join-Path $scratch $Name
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

try {
    $out = Join-Path $scratch 'build'
    & (Join-Path $Root 'tools\build-windows-release.ps1') -OutputDirectory $out | Out-Null
    $package = Join-Path $scratch 'package'
    Expand-Archive -LiteralPath (Join-Path $out 'agent-harness-windows-v0.4.3.zip') -DestinationPath $package
    $bin = Join-Path $scratch 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    foreach ($app in @('codex', 'claude', 'opencode')) {
        $version = if ($app -eq 'codex') { '0.163.0' } else { '1.18.11' }
        [IO.File]::WriteAllText((Join-Path $bin ($app + '.cmd')), "@echo off`r`necho $app $version`r`n")
    }
    $env:PATH = $bin + ';' + $PSHOME + ';C:\Windows\System32;C:\Windows'

    $claudeProfile = New-Profile 'claude profile'
    $claudeDir = Join-Path $claudeProfile '.claude'
    New-Item -ItemType Directory -Path $claudeDir | Out-Null
    $claudeFile = Join-Path $claudeDir 'CLAUDE.md'
    $original = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("Existing notes`r`n")
    [IO.File]::WriteAllBytes($claudeFile, $original)
    $claudeRun = Run-Install $package $claudeProfile 'Claude'
    if ($claudeRun.code -ne 0) { throw "Claude adapter failed: $($claudeRun.output)" }
    $after = [IO.File]::ReadAllBytes($claudeFile)
    if ($after.Length -le $original.Length) { throw 'Claude import was not appended' }
    for ($i = 0; $i -lt $original.Length; $i++) {
        if ($after[$i] -ne $original[$i]) { throw 'Claude original bytes changed' }
    }
    $expectedImport = '@' + (Join-Path $claudeProfile '.agents\AGENTS.md')
    $claudeText = [IO.File]::ReadAllText($claudeFile, [Text.Encoding]::UTF8)
    if ($claudeText.Split([string[]]@($expectedImport), [StringSplitOptions]::None).Length -ne 2) {
        throw 'Claude import was not added exactly once'
    }
    $backups = @(Get-ChildItem -LiteralPath $claudeDir -Filter 'CLAUDE.md.harness-backup-*' -File)
    if ($backups.Count -ne 1 -or
        -not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($backups[0].FullName))) {
        throw 'Exact Claude backup is missing'
    }
    if ((Run-Install $package $claudeProfile 'Claude').code -ne 0 -or
        [IO.File]::ReadAllBytes($claudeFile).Length -ne $after.Length) { throw 'Claude repeat added another import' }

    $noAdmin = New-Profile 'ordinary adapters'
    $firstAdapters = Run-Install $package $noAdmin 'Codex,OpenCode'
    if ($firstAdapters.code -ne 0) { throw "Codex and OpenCode require elevated rights: $($firstAdapters.output)" }
    $sharedRules = Join-Path $noAdmin '.agents\AGENTS.md'
    foreach ($relative in @('.codex\AGENTS.md', '.config\opencode\AGENTS.md')) {
        $adapter = Join-Path $noAdmin $relative
        $item = Get-Item -LiteralPath $adapter -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Adapter is a symlink: $adapter" }
        $text = [IO.File]::ReadAllText($adapter)
        if (-not $text.Contains($sharedRules)) { throw "Adapter does not reference shared rules: $adapter" }
    }
    $adapterMarkerPath = Join-Path $noAdmin '.agents\.harness-install.json'
    $adapterMarker = Get-Content -LiteralPath $adapterMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $adapterMarker.connections.Codex = 'error'
    $adapterMarker.connections.OpenCode = 'error'
    [IO.File]::WriteAllText($adapterMarkerPath, (ConvertTo-Json -InputObject $adapterMarker -Depth 8))
    $repeatAdapters = Run-Install $package $noAdmin 'Codex,OpenCode'
    if ($repeatAdapters.code -ne 0) { throw "Repeat adapter install failed: $($repeatAdapters.output)" }
    $repairedMarker = Get-Content -LiteralPath $adapterMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($repairedMarker.connections.Codex -cne 'connected' -or $repairedMarker.connections.OpenCode -cne 'connected') {
        throw 'Previous adapter error status was not repaired'
    }

    $blocked = New-Profile 'blocked codex profile'
    $codexDir = Join-Path $blocked '.codex'
    New-Item -ItemType Directory -Path $codexDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $codexDir 'AGENTS.md'), 'private codex rules')
    $opencodeDir = Join-Path $blocked '.config\opencode'
    New-Item -ItemType Directory -Path $opencodeDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $opencodeDir 'opencode.jsonc'), '{"theme":"owner"}')
    $partial = Run-Install $package $blocked 'Codex,Claude,OpenCode'
    if ($partial.code -ne 2 -or $partial.output -notmatch 'Codex: error' -or
        $partial.output -notmatch 'Claude: connected') { throw 'Partial result did not identify success and failure' }
    if ((Get-Content -LiteralPath (Join-Path $codexDir 'AGENTS.md') -Raw) -cne 'private codex rules') {
        throw 'Occupied Codex target was overwritten'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $blocked '.claude\CLAUDE.md'))) {
        throw "Claude did not continue after Codex failure: $($partial.output)"
    }
    if ((Get-Content -LiteralPath (Join-Path $opencodeDir 'opencode.jsonc') -Raw) -cne '{"theme":"owner"}') {
        throw 'OpenCode config was modified'
    }
    $partialMarker = Get-Content -LiteralPath (Join-Path $blocked '.agents\.harness-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($partialMarker.connections.Codex -cne 'error' -or $partialMarker.connections.Claude -cne 'connected') {
        throw 'Per-adapter marker status is incorrect'
    }

    $none = New-Profile 'all adapters blocked'
    New-Item -ItemType Directory -Path (Join-Path $none '.codex') | Out-Null
    [IO.File]::WriteAllText((Join-Path $none '.codex\AGENTS.md'), 'owner rules')
    $noConnection = Run-Install $package $none 'Codex'
    if ($noConnection.code -eq 0 -or (Test-Path -LiteralPath (Join-Path $none '.agents'))) {
        throw 'New payload was not rolled back after zero adapters connected'
    }

    $conflictingClaude = New-Profile 'conflicting claude'
    New-Item -ItemType Directory -Path (Join-Path $conflictingClaude '.claude') | Out-Null
    $otherImport = '@C:\other\AGENTS.md'
    [IO.File]::WriteAllText((Join-Path $conflictingClaude '.claude\CLAUDE.md'), $otherImport)
    $claudeConflict = Run-Install $package $conflictingClaude 'Claude'
    if ($claudeConflict.code -eq 0 -or
        (Get-Content -LiteralPath (Join-Path $conflictingClaude '.claude\CLAUDE.md') -Raw) -cne $otherImport) {
        throw 'Conflicting Claude import was not preserved'
    }

    $utf16Profile = New-Profile 'utf16 claude'
    New-Item -ItemType Directory -Path (Join-Path $utf16Profile '.claude') | Out-Null
    $utf16File = Join-Path $utf16Profile '.claude\CLAUDE.md'
    $utf16Bytes = [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("UTF16 notes`r`n")
    [IO.File]::WriteAllBytes($utf16File, $utf16Bytes)
    $utf16Run = Run-Install $package $utf16Profile 'Claude'
    if ($utf16Run.code -ne 0) { throw "UTF16 Claude import failed: $($utf16Run.output)" }
    $utf16After = [IO.File]::ReadAllBytes($utf16File)
    for ($i = 0; $i -lt $utf16Bytes.Length; $i++) {
        if ($utf16Bytes[$i] -ne $utf16After[$i]) { throw 'UTF16 original bytes changed' }
    }
    if (-not [Text.Encoding]::Unicode.GetString($utf16After, 2, $utf16After.Length - 2).Contains('@' + (Join-Path $utf16Profile '.agents\AGENTS.md'))) {
        throw 'UTF16 import missing'
    }

    $tokens = $null
    $parseErrors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'distribution\windows\install.ps1'), [ref]$tokens, [ref]$parseErrors)
    $undoDefinition = @($tree.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Undo-FreshPayload'
    }, $true))[0]
    Invoke-Expression $undoDefinition.Extent.Text
    $raced = New-Profile 'changed rollback marker'
    $racedAgents = Join-Path $raced '.agents'
    New-Item -ItemType Directory -Path $racedAgents | Out-Null
    $racedRule = Join-Path $racedAgents 'AGENTS.md'
    $racedMarker = Join-Path $racedAgents '.harness-install.json'
    [IO.File]::WriteAllText($racedRule, 'created by installer')
    [IO.File]::WriteAllText($racedMarker, 'original marker')
    $expectedMarkerHash = (Get-FileHash -LiteralPath $racedMarker -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($racedMarker, 'changed by another process')
    $racedPlan = @([pscustomobject]@{ status = 'create'; target = $racedRule;
        hash = (Get-FileHash -LiteralPath $racedRule -Algorithm SHA256).Hash.ToLowerInvariant() })
    $didRollback = Undo-FreshPayload $raced $racedPlan $false $expectedMarkerHash
    if ($didRollback -or -not (Test-Path -LiteralPath $racedRule) -or
        (Get-Content -LiteralPath $racedMarker -Raw) -cne 'changed by another process') {
        throw 'Rollback deleted files after marker changed concurrently'
    }
    Write-Output 'Adapters.Tests: PASS'
}
finally {
    $env:PATH = $oldPath
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath((Join-Path $Root 'dist\test-scratch'))
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
