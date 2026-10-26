param(
    [switch]$VerifyOnly,
    [switch]$ListOnly,
    [switch]$PlanOnly,
    [switch]$Apply,
    [switch]$Accept,
    [switch]$ConsoleSelection,
    [switch]$FaultAfterUpdate,
    [string]$SelectApps,
    [string]$ProfileRoot = $env:USERPROFILE,
    [string]$PackageRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

function Find-Application([string]$Name, [string]$Profile) {
    $commandName = $Name.ToLowerInvariant()
    if ($Name -eq 'OpenCode') { $commandName = 'opencode' }
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $onPath = Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates.Add($onPath.Source) }
    $npm = Join-Path $Profile ('AppData\Roaming\npm\' + $commandName + '.cmd')
    if ((Test-Path -LiteralPath $npm -PathType Leaf) -and -not $candidates.Contains($npm)) { $candidates.Add($npm) }
    if ($Name -eq 'Codex') {
        $standalone = Join-Path $Profile 'AppData\Local\Programs\OpenAI\Codex\bin\codex.exe'
        if ((Test-Path -LiteralPath $standalone -PathType Leaf) -and -not $candidates.Contains($standalone)) { $candidates.Add($standalone) }
    }
    if ($Name -eq 'OpenCode') {
        $desktop = Join-Path $Profile 'AppData\Local\Programs\@opencode-aidesktop\OpenCode.exe'
        if ((Test-Path -LiteralPath $desktop -PathType Leaf) -and -not $candidates.Contains($desktop)) { $candidates.Add($desktop) }
    }
    $target = switch ($Name) {
        'Codex' {
            $homePath = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $Profile '.codex' }
            Join-Path $homePath 'AGENTS.md'
        }
        'Claude' {
            $homePath = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $Profile '.claude' }
            Join-Path $homePath 'CLAUDE.md'
        }
        'OpenCode' {
            $configBase = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $Profile '.config' }
            Join-Path (Join-Path $configBase 'opencode') 'AGENTS.md'
        }
    }
    foreach ($candidate in $candidates) {
        try {
            $raw = if ($candidate -like '*.exe' -and $Name -eq 'OpenCode') {
                (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion
            } else {
                (& $candidate --version 2>$null | Out-String)
            }
            $match = [regex]::Match([string]$raw, '\d+\.\d+(?:\.\d+){0,2}')
            if ($match.Success) {
                $version = $match.Value
                $status = 'detected'
                if ($Name -eq 'OpenCode' -and [int]($version.Split('.')[0]) -ne 1) { $status = 'review' }
                return [pscustomobject]@{ name = $Name; status = $status; version = $version; executable = $candidate; rulesTarget = $target }
            }
        }
        catch { }
    }
    if ($Name -eq 'Codex' -and $candidates.Count -eq 0 -and
        $Profile -eq [IO.Path]::GetFullPath($env:USERPROFILE)) {
        $appx = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($appx -and $appx.Version) {
            return [pscustomobject]@{ name = $Name; status = 'detected'; version = [string]$appx.Version; executable = 'appx:OpenAI.Codex'; rulesTarget = $target }
        }
    }
    if ($candidates.Count -gt 0) {
        return [pscustomobject]@{ name = $Name; status = 'review'; version = 'unknown'; executable = $candidates[0]; rulesTarget = $target }
    }
    return [pscustomobject]@{ name = $Name; status = 'absent'; version = ''; executable = ''; rulesTarget = $target }
}

function Assert-SafeTarget([string]$Profile, [string]$Target, [bool]$LeafFile) {
    $base = [IO.Path]::GetFullPath($Profile).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Target)
    $baseItem = Get-Item -LiteralPath $base -Force
    if (-not $baseItem.PSIsContainer -or ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Profile root must be an ordinary directory'
    }
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Target escapes profile' }
    $current = $base
    $parts = @($full.Substring($base.Length).TrimStart('\').Split('\') | Where-Object { $_ })
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked target path is forbidden: $current" }
            $isLeaf = $current.Equals($full, [StringComparison]::OrdinalIgnoreCase)
            if (($isLeaf -and $LeafFile -and $item.PSIsContainer) -or
                ((-not $isLeaf -or -not $LeafFile) -and -not $item.PSIsContainer)) {
                throw "Target path has wrong type: $current"
            }
        }
    }
}

function Read-Marker([string]$Profile) {
    $markerPath = Join-Path (Join-Path $Profile '.agents') '.harness-install.json'
    Assert-SafeTarget $Profile $markerPath $true
    if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'Installer marker is corrupt; no files will be replaced' }
    if ($marker.schema -ne 1 -or $marker.version -notmatch '^\d+\.\d+\.\d+$' -or -not $marker.files) {
        throw 'Installer marker has an invalid schema'
    }
    return $marker
}

function Get-PayloadPlan([string]$Profile, [string]$Package, $Manifest, $OldMarker) {
    $agents = Join-Path $Profile '.agents'
    Assert-SafeTarget $Profile $agents $false
    $plan = @()
    foreach ($entry in @($Manifest.files | Where-Object { $_.path.StartsWith('payload/') })) {
        $relative = $entry.path.Substring(8)
        $target = Join-Path $agents ($relative.Replace('/', '\'))
        Assert-SafeTarget $Profile $target $true
        $status = 'create'
        if (Test-Path -LiteralPath $target) {
            if ($relative -eq 'rules/personal.md') {
                $status = 'personal'
            }
            else {
                $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($currentHash -ceq $entry.sha256) { $status = 'adopted' } else { $status = 'conflict' }
                if ($status -eq 'conflict' -and $OldMarker) {
                    $prior = $OldMarker.files.PSObject.Properties[$relative]
                    if ($prior -and $prior.Value.baseHash) {
                        if ($currentHash -ceq $prior.Value.baseHash) { $status = 'update' }
                        elseif ($entry.sha256 -ceq $prior.Value.baseHash) { $status = 'local' }
                    }
                }
            }
        }
        $plan += [pscustomobject]@{ path = $relative; target = $target; source = (Join-Path $Package ($entry.path.Replace('/', '\'))); hash = $entry.sha256; status = $status }
    }
    return $plan
}

function Write-NewFile([string]$Source, [string]$Target) {
    $inputFile = [IO.File]::OpenRead($Source)
    try {
        $outputFile = [IO.File]::Open($Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputFile.CopyTo($outputFile) } finally { $outputFile.Dispose() }
    }
    finally { $inputFile.Dispose() }
}

function Sync-Payload([string]$Profile, [string]$Package, $Manifest, $Plan, $OldMarker) {
    $agents = Join-Path $Profile '.agents'
    $markerPath = Join-Path $agents '.harness-install.json'
    Assert-SafeTarget $Profile $markerPath $true
    if (@($Plan | Where-Object { $_.path -eq 'AGENTS.md' -and $_.status -eq 'conflict' }).Count -gt 0 -and -not $OldMarker) {
        throw 'Existing AGENTS.md differs; resolve it manually before connecting agents'
    }
    $planComplete = @($Plan | Where-Object { $_.status -eq 'conflict' }).Count -eq 0
    if ($OldMarker -and $OldMarker.version -ceq $Manifest.version -and $OldMarker.complete -eq $planComplete -and
        @($Plan | Where-Object { $_.status -eq 'create' -or $_.status -eq 'update' }).Count -eq 0) {
        Write-Output 'Same package version is already present; no managed files changed.'
        return
    }
    $created = New-Object 'System.Collections.Generic.List[string]'
    $madeDirs = New-Object 'System.Collections.Generic.List[string]'
    $updated = New-Object 'System.Collections.Generic.List[object]'
    try {
        $backupRun = $null
        if ($OldMarker) {
            $backupRoot = Join-Path $agents '.harness-backups'
            Assert-SafeTarget $Profile $backupRoot $false
            if (-not (Test-Path -LiteralPath $backupRoot)) {
                New-Item -ItemType Directory -Path $backupRoot | Out-Null
                $madeDirs.Add($backupRoot)
            }
            $backupRun = Join-Path $backupRoot ($OldMarker.version + '-to-' + $Manifest.version + '-' + [guid]::NewGuid().ToString('N'))
            Assert-SafeTarget $Profile $backupRun $false
            New-Item -ItemType Directory -Path $backupRun | Out-Null
            $madeDirs.Add($backupRun)
        }
        foreach ($entry in $Plan) {
            if ($entry.status -eq 'update') {
                Assert-SafeTarget $Profile $entry.target $true
                $prior = $OldMarker.files.PSObject.Properties[$entry.path].Value
                $currentHash = (Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($currentHash -cne $prior.baseHash) { throw "Managed file changed after preview: $($entry.path)" }
                $backup = Join-Path $backupRun ($entry.path.Replace('/', '\'))
                $backupParent = Split-Path -Parent $backup
                if (-not (Test-Path -LiteralPath $backupParent)) {
                    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
                    $madeDirs.Add($backupParent)
                }
                Assert-SafeTarget $Profile $backup $true
                [IO.File]::Copy($entry.target, $backup)
                if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -cne $prior.baseHash) {
                    throw "Backup verification failed: $($entry.path)"
                }
                $temporary = $entry.target + '.harness-tmp-' + [guid]::NewGuid().ToString('N')
                Assert-SafeTarget $Profile $temporary $true
                try {
                    Write-NewFile $entry.source $temporary
                    if ((Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $prior.baseHash) {
                        throw "Managed file changed during update: $($entry.path)"
                    }
                    $atomicBackup = $backup + '.atomic'
                    [IO.File]::Replace($temporary, $entry.target, $atomicBackup)
                    $updated.Add([pscustomobject]@{ target = $entry.target; backup = $backup; hash = $entry.hash })
                    if ($FaultAfterUpdate) { throw 'Injected test fault after file update' }
                    if (Test-Path -LiteralPath $atomicBackup) { Remove-Item -LiteralPath $atomicBackup }
                }
                finally {
                    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary }
                }
                if ((Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.hash) {
                    throw "Updated file hash differs: $($entry.path)"
                }
                continue
            }
            if ($entry.status -ne 'create') { continue }
            Assert-SafeTarget $Profile $entry.target $true
            $parent = Split-Path -Parent $entry.target
            $missing = New-Object 'System.Collections.Generic.List[string]'
            $cursor = $parent
            while (-not (Test-Path -LiteralPath $cursor)) {
                $missing.Add($cursor)
                $cursor = Split-Path -Parent $cursor
            }
            for ($i = $missing.Count - 1; $i -ge 0; $i--) {
                Assert-SafeTarget $Profile $missing[$i] $false
                New-Item -ItemType Directory -Path $missing[$i] | Out-Null
                $madeDirs.Add($missing[$i])
            }
            Assert-SafeTarget $Profile $entry.target $true
            Write-NewFile $entry.source $entry.target
            $created.Add($entry.target)
            $actualHash = (Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -cne $entry.hash) { throw "Payload changed during copy: $($entry.path)" }
        }
        $states = [ordered]@{}
        foreach ($entry in $Plan) {
            $priorHash = $null
            if ($OldMarker) {
                $priorProperty = $OldMarker.files.PSObject.Properties[$entry.path]
                if ($priorProperty) { $priorHash = $priorProperty.Value.baseHash }
            }
            $accepted = if ($entry.status -eq 'conflict' -or $entry.status -eq 'personal' -or $entry.status -eq 'local') { $priorHash } else { $entry.hash }
            $status = if ($entry.status -eq 'create') { 'created' } elseif ($entry.status -eq 'update') { 'updated' } else { $entry.status }
            $states[$entry.path] = [ordered]@{ baseHash = $accepted; status = $status }
        }
        if ($OldMarker) {
            foreach ($property in $OldMarker.files.PSObject.Properties) {
                if (-not $states.Contains($property.Name)) {
                    $states[$property.Name] = [ordered]@{ baseHash = $property.Value.baseHash; status = 'retired' }
                }
            }
        }
        $complete = $planComplete
        $connections = if ($OldMarker) { $OldMarker.connections } else { [ordered]@{} }
        $marker = [ordered]@{ schema = 1; version = $Manifest.version; complete = $complete; files = $states; connections = $connections }
        $json = (ConvertTo-Json -InputObject $marker -Depth 8) + "`n"
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        if (-not $OldMarker) {
            $stream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            $created.Add($markerPath)
        }
        else {
            $temporaryMarker = $markerPath + '.tmp-' + [guid]::NewGuid().ToString('N')
            $backupMarker = Join-Path $backupRun 'marker.json'
            $stream = [IO.File]::Open($temporaryMarker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            try { [IO.File]::Replace($temporaryMarker, $markerPath, $backupMarker) }
            finally { if (Test-Path -LiteralPath $temporaryMarker) { Remove-Item -LiteralPath $temporaryMarker } }
        }
        Write-Output 'Managed payload files were reconciled.'
    }
    catch {
        for ($i = $updated.Count - 1; $i -ge 0; $i--) {
            $entry = $updated[$i]
            if ((Test-Path -LiteralPath $entry.target -PathType Leaf) -and
                (Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.hash) {
                [IO.File]::Copy($entry.backup, $entry.target, $true)
            }
        }
        for ($i = $created.Count - 1; $i -ge 0; $i--) {
            $path = $created[$i]
            $matching = @($Plan | Where-Object { $_.target -eq $path })
            $safeToRemove = if ($matching.Count -gt 0) {
                (Test-Path -LiteralPath $path -PathType Leaf) -and
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $matching[0].hash
            } else { $path -eq $markerPath -and (Test-Path -LiteralPath $path -PathType Leaf) }
            if ($safeToRemove) { Remove-Item -LiteralPath $path }
        }
        for ($i = $madeDirs.Count - 1; $i -ge 0; $i--) {
            $path = $madeDirs[$i]
            if ((Test-Path -LiteralPath $path -PathType Container) -and
                @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) { Remove-Item -LiteralPath $path }
        }
        throw
    }
}

function Ensure-OrdinaryDirectory([string]$Profile, [string]$Directory) {
    Assert-SafeTarget $Profile $Directory $false
    if (-not (Test-Path -LiteralPath $Directory)) {
        $missing = New-Object 'System.Collections.Generic.List[string]'
        $cursor = $Directory
        while (-not (Test-Path -LiteralPath $cursor)) {
            $missing.Add($cursor)
            $cursor = Split-Path -Parent $cursor
        }
        for ($i = $missing.Count - 1; $i -ge 0; $i--) {
            Assert-SafeTarget $Profile $missing[$i] $false
            New-Item -ItemType Directory -Path $missing[$i] | Out-Null
        }
    }
    Assert-SafeTarget $Profile $Directory $false
}

function Connect-RuleAdapter([string]$Name, [string]$Profile, [string]$Target, [string]$Rules) {
    $parent = Split-Path -Parent $Target
    Assert-SafeTarget $Profile $parent $false
    Assert-SafeTarget $Profile $Rules $true
    $content = "# Shared agent harness`nBefore starting a task, read the shared rules at $Rules and follow them. Read that file again in each new session so updates take effect. If it is unavailable, tell the user instead of assuming its contents.`n"
    if ($Name -eq 'Codex') {
        $override = Join-Path $parent 'AGENTS.override.md'
        Assert-SafeTarget $Profile $override $true
        if ((Test-Path -LiteralPath $override -PathType Leaf) -and (Get-Item -LiteralPath $override).Length -gt 0) {
            throw 'Codex AGENTS.override.md would shadow the shared rules'
        }
    }
    if ($Name -eq 'OpenCode') {
        foreach ($file in @('opencode.json', 'opencode.jsonc')) {
            $config = Join-Path $parent $file
            Assert-SafeTarget $Profile $config $true
            if ((Test-Path -LiteralPath $config -PathType Leaf) -and
                (Get-Content -LiteralPath $config -Raw -Encoding UTF8) -match '"instructions"\s*:') {
                throw 'OpenCode config already defines instructions; review duplicate loading manually'
            }
        }
    }
    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $linkTarget = [string]$item.Target
            if (-not $linkTarget) { throw 'Existing adapter link has no readable target' }
            if ([IO.Path]::GetFullPath($linkTarget).Equals([IO.Path]::GetFullPath($Rules), [StringComparison]::OrdinalIgnoreCase)) {
                return 'already'
            }
            throw 'Existing adapter link points elsewhere'
        }
        Assert-SafeTarget $Profile $Target $true
        if ([IO.File]::ReadAllText($Target) -ceq $content) { return 'already' }
        throw 'Adapter target is already an ordinary file with different content'
    }
    Ensure-OrdinaryDirectory $Profile $parent
    $temporary = $Target + '.harness-tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, $content, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Target) { throw 'Adapter target appeared after preview' }
        [IO.File]::Move($temporary, $Target)
        return 'connected'
    }
    catch {
        throw
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary } }
}

function Decode-ClaudeFile([byte[]]$Bytes) {
    $skip = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $skip = 3
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
        $skip = 2
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true)
        $skip = 2
    }
    else { $encoding = New-Object System.Text.UTF8Encoding($false, $true) }
    $text = $encoding.GetString($Bytes, $skip, $Bytes.Length - $skip)
    return [pscustomobject]@{ encoding = $encoding; text = $text }
}

function Connect-ClaudeAdapter([string]$Profile, [string]$Target, [string]$Rules) {
    $parent = Split-Path -Parent $Target
    Assert-SafeTarget $Profile $parent $false
    Assert-SafeTarget $Profile $Target $true
    $exists = Test-Path -LiteralPath $Target -PathType Leaf
    $original = New-Object byte[] 0
    if ($exists) { $original = [IO.File]::ReadAllBytes($Target) }
    $decoded = Decode-ClaudeFile $original
    $import = '@' + $Rules
    $lines = @($decoded.text -split '\r?\n')
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('@') -and $trimmed.EndsWith('AGENTS.md', [StringComparison]::OrdinalIgnoreCase)) {
            if ($trimmed.Equals($import, [StringComparison]::OrdinalIgnoreCase)) { return 'already' }
            throw 'CLAUDE.md already imports another AGENTS.md'
        }
    }
    $newline = if ($decoded.text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($decoded.text.Length -eq 0) { $prefix = '' }
    elseif ($decoded.text.EndsWith("`n")) { $prefix = '' }
    else { $prefix = $newline }
    $suffix = $prefix + $import + $newline
    $append = $decoded.encoding.GetBytes($suffix)
    $combined = New-Object byte[] ($original.Length + $append.Length)
    [Array]::Copy($original, $combined, $original.Length)
    [Array]::Copy($append, 0, $combined, $original.Length, $append.Length)
    Ensure-OrdinaryDirectory $Profile $parent
    $temporary = $Target + '.harness-tmp-' + [guid]::NewGuid().ToString('N')
    $backup = $Target + '.harness-backup-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporary, $combined)
        if ($exists) {
            if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($Target))) {
                throw 'CLAUDE.md changed after preview'
            }
            [IO.File]::Replace($temporary, $Target, $backup)
        }
        else {
            if (Test-Path -LiteralPath $Target) { throw 'CLAUDE.md appeared after preview' }
            [IO.File]::Move($temporary, $Target)
        }
        return 'connected'
    }
    catch {
        if ($exists -and (Test-Path -LiteralPath $backup -PathType Leaf) -and
            (Test-Path -LiteralPath $Target -PathType Leaf) -and
            [Linq.Enumerable]::SequenceEqual([byte[]]$combined, [byte[]][IO.File]::ReadAllBytes($Target))) {
            [IO.File]::Copy($backup, $Target, $true)
        }
        elseif (-not $exists -and (Test-Path -LiteralPath $Target -PathType Leaf) -and
            [Linq.Enumerable]::SequenceEqual([byte[]]$combined, [byte[]][IO.File]::ReadAllBytes($Target))) {
            Remove-Item -LiteralPath $Target
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary }
    }
}

function Undo-FreshPayload([string]$Profile, $Plan, [bool]$RootExisted, [string]$ExpectedMarkerHash) {
    $agents = Join-Path $Profile '.agents'
    $marker = Join-Path $agents '.harness-install.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash -cne $ExpectedMarkerHash) {
        return $false
    }
    Remove-Item -LiteralPath $marker
    foreach ($entry in @($Plan | Where-Object { $_.status -eq 'create' })) {
        if ((Test-Path -LiteralPath $entry.target -PathType Leaf) -and
            (Get-FileHash -LiteralPath $entry.target -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.hash) {
            Remove-Item -LiteralPath $entry.target
        }
    }
    if (-not $RootExisted -and (Test-Path -LiteralPath $agents -PathType Container)) {
        $folders = @(Get-ChildItem -LiteralPath $agents -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($folder in $folders) {
            if (@(Get-ChildItem -LiteralPath $folder.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $folder.FullName }
        }
        if (@(Get-ChildItem -LiteralPath $agents -Force).Count -eq 0) { Remove-Item -LiteralPath $agents }
    }
    return $true
}

function Save-ConnectionStatus([string]$Profile, $Results) {
    $agents = Join-Path $Profile '.agents'
    $path = Join-Path $agents '.harness-install.json'
    $marker = Read-Marker $Profile
    $map = [ordered]@{}
    if ($marker.connections) {
        foreach ($property in $marker.connections.PSObject.Properties) { $map[$property.Name] = $property.Value }
    }
    $changed = $false
    foreach ($result in $Results) {
        $status = $result.status
        if ($status -eq 'already') { $status = 'connected' }
        if (-not $map.Contains($result.name) -or $map[$result.name] -cne $status) { $changed = $true }
        $map[$result.name] = $status
    }
    if (-not $changed) { return }
    $marker.connections = $map
    $json = (ConvertTo-Json -InputObject $marker -Depth 8) + "`n"
    $backupRoot = Join-Path $agents '.harness-backups'
    Ensure-OrdinaryDirectory $Profile $backupRoot
    $temporary = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backup = Join-Path $backupRoot ('marker-connections-' + [guid]::NewGuid().ToString('N') + '.json')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $json, $utf8)
    try { [IO.File]::Replace($temporary, $path, $backup) }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Read-ApplicationSelectionConsole($Applications) {
    Write-Host 'Найденные приложения:'
    for ($i = 0; $i -lt $Applications.Count; $i++) {
        Write-Host ("  {0}. {1} {2}" -f ($i + 1), $Applications[$i].name, $Applications[$i].version)
    }
    $answer = Read-Host 'Введите номера через запятую (например, 1,3); Enter отменяет'
    if ([string]::IsNullOrWhiteSpace($answer)) { return '' }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($token in @([regex]::Split($answer.Trim(), '[,;\s]+') | Where-Object { $_ })) {
        if ($token -notmatch '^[1-9][0-9]*$' -or [int]$token -gt $Applications.Count) {
            throw "Неверный номер приложения: $token"
        }
        $name = $Applications[[int]$token - 1].name
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    return ($names -join ',')
}

function Show-ApplicationSelectionDialog($Applications) {
    $form = $null
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
            return [pscustomobject]@{ status = 'unavailable'; names = '' }
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Выбор приложений'
        $form.ClientSize = New-Object System.Drawing.Size(560, (120 + 42 * $Applications.Count))
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ShowIcon = $false
        $form.TopMost = $true

        $instruction = New-Object System.Windows.Forms.Label
        $instruction.Text = 'Отметьте приложения, к которым подключить agent harness:'
        $instruction.SetBounds(20, 18, 520, 24)
        $form.Controls.Add($instruction)
        $boxes = @()
        for ($i = 0; $i -lt $Applications.Count; $i++) {
            $box = New-Object System.Windows.Forms.CheckBox
            $box.Text = ("{0}  {1}" -f $Applications[$i].name, $Applications[$i].version)
            $box.Tag = $Applications[$i].name
            $box.SetBounds(24, (55 + 42 * $i), 500, 28)
            $form.Controls.Add($box)
            $boxes += $box
        }
        $continue = New-Object System.Windows.Forms.Button
        $continue.Text = 'Продолжить'
        $continue.SetBounds(300, (68 + 42 * $Applications.Count), 110, 32)
        $continue.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($continue)
        $form.AcceptButton = $continue
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Отмена'
        $cancel.SetBounds(424, (68 + 42 * $Applications.Count), 110, 32)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($cancel)
        $form.CancelButton = $cancel

        $result = $form.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            return [pscustomobject]@{ status = 'cancelled'; names = '' }
        }
        $names = @($boxes | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag })
        return [pscustomobject]@{ status = 'selected'; names = ($names -join ',') }
    }
    catch {
        return [pscustomobject]@{ status = 'unavailable'; names = ''; reason = $_.Exception.Message }
    }
    finally { if ($form) { $form.Dispose() } }
}

try {
    $root = [IO.Path]::GetFullPath($PackageRoot)
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "manifest.json is missing next to install.cmd in '$root'. Unpack the complete agent-harness-windows-v*.zip into a separate folder and run install.cmd from its top level, not from payload or distribution/windows."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Manifest schema or version is invalid' }
    $version = (Get-Content -LiteralPath (Join-Path $root 'version.txt') -Raw -Encoding UTF8).Trim()
    if ($version -cne $manifest.version) { throw 'Manifest and version.txt differ' }
    $listed = @($manifest.files | ForEach-Object { $_.path })
    $launcher = @(Get-ChildItem -LiteralPath $root -Filter '*.cmd' -File -Force)
    if (-not (Test-Path -LiteralPath (Join-Path $root 'installation-guide.md') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $root 'readme.md') -PathType Leaf) -or
        $launcher.Count -ne 1) { throw 'Package documentation or launcher is missing' }
    $expectedFiles = @(
        'version.txt', 'install.ps1', 'installation-guide.md', 'readme.md', $launcher[0].Name,
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
    $sortedListed = @($listed | Sort-Object)
    if (($sortedListed -join '|') -cne ($expectedFiles -join '|') -or
        @($listed | Select-Object -Unique).Count -ne $expectedFiles.Count) { throw 'Manifest file list is invalid' }
    foreach ($entry in $manifest.files) {
        if ($entry.path -notmatch '^[^:\\]+$' -or $entry.path -match '(^|/)\.\.?(/|$)') { throw 'Unsafe manifest path' }
        $path = Join-Path $root ($entry.path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Package file is missing: $($entry.path)" }
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Package link is forbidden' }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne $entry.sha256) { throw "Checksum mismatch: $($entry.path)" }
    }
    $actual = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
        $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    } | Sort-Object)
    $expected = @(($listed + 'manifest.json') | Sort-Object)
    if (($actual -join '|') -cne ($expected -join '|')) { throw 'Unexpected package files' }
    if ($VerifyOnly) { Write-Output 'Package verification: PASS'; exit 0 }
    $profile = [IO.Path]::GetFullPath($ProfileRoot)
    if ($FaultAfterUpdate -and $profile.Equals([IO.Path]::GetFullPath($env:USERPROFILE), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fault injection is unavailable for the current user profile'
    }
    $apps = @('Codex', 'Claude', 'OpenCode') | ForEach-Object { Find-Application $_ $profile }
    if ($ListOnly) {
        ConvertTo-Json -InputObject ([object[]]$apps) -Depth 4
        exit 0
    }
    $available = @($apps | Where-Object { $_.status -eq 'detected' })
    if ($available.Count -eq 0) {
        Write-Output 'No supported application was confidently detected. No files were written.'
        exit 0
    }
    if (-not $PSBoundParameters.ContainsKey('SelectApps')) {
        if ($ConsoleSelection) {
            $SelectApps = Read-ApplicationSelectionConsole $available
        } else {
            $dialog = Show-ApplicationSelectionDialog $available
            if ($dialog.status -eq 'unavailable') {
                Write-Host 'Графический выбор недоступен; выберите приложения по номерам.'
                $SelectApps = Read-ApplicationSelectionConsole $available
            } else {
                $SelectApps = $dialog.names
            }
        }
    }
    $names = @($SelectApps.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $selected = @($available | Where-Object { $names -contains $_.name })
    if ($selected.Count -ne $names.Count) { throw 'Selection contains an absent or unsupported application' }
    if ($PlanOnly) { ConvertTo-Json -InputObject ([object[]]$selected) -Depth 4; exit 0 }
    if ($selected.Count -eq 0) { Write-Output 'Cancelled. No files were written.'; exit 0 }
    $oldMarker = Read-Marker $profile
    if ($oldMarker -and [version]$oldMarker.version -gt [version]$manifest.version) {
        throw 'This package is older than the recorded installation; downgrade is not automatic'
    }
    $filePlan = @(Get-PayloadPlan $profile $root $manifest $oldMarker)
    Write-Output ("Canonical rules: {0}" -f (Join-Path $profile '.agents\AGENTS.md'))
    $filePlan | ForEach-Object { Write-Output ("  {0}: {1}" -f $_.status, $_.target) }
    $ruleChange = @($filePlan | Where-Object { $_.path -eq 'AGENTS.md' -and
        ($_.status -eq 'update' -or $_.status -eq 'conflict') })
    if ($oldMarker -and $ruleChange.Count -gt 0) {
        Write-Output 'Shared rules difference preview (local console only):'
        $oldLines = @(Get-Content -LiteralPath $ruleChange[0].target -Encoding UTF8)
        $newLines = @(Get-Content -LiteralPath $ruleChange[0].source -Encoding UTF8)
        Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines | Select-Object -First 80 | ForEach-Object {
            $prefix = if ($_.SideIndicator -eq '=>') { '+' } else { '-' }
            Write-Output ("  {0} {1}" -f $prefix, $_.InputObject)
        }
    }
    $selected | ForEach-Object { Write-Output ("Connect {0} at {1}" -f $_.name, $_.rulesTarget) }
    $confirm = if ($Accept -and $Apply) { 'YES' } else { Read-Host 'Подтвердите изменения: введите YES (регистр не важен)' }
    if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm.Trim() -ine 'YES') {
        Write-Output 'Cancelled. No files were written.'
        exit 0
    }
    $agentsExisted = Test-Path -LiteralPath (Join-Path $profile '.agents') -PathType Container
    Sync-Payload $profile $root $manifest $filePlan $oldMarker
    $fileConflicts = @($filePlan | Where-Object { $_.status -eq 'conflict' })
    if (@($fileConflicts | Where-Object { $_.path -eq 'AGENTS.md' }).Count -gt 0) {
        Write-Output 'Adapter connections skipped: shared AGENTS.md differs from the accepted package base.'
        exit 2
    }
    $freshMarkerHash = if (-not $oldMarker) {
        (Get-FileHash -LiteralPath (Join-Path $profile '.agents\.harness-install.json') -Algorithm SHA256).Hash
    } else { '' }
    $sharedRules = Join-Path $profile '.agents\AGENTS.md'
    $results = @()
    foreach ($app in $selected) {
        try {
            $status = if ($app.name -eq 'Claude') {
                Connect-ClaudeAdapter $profile $app.rulesTarget $sharedRules
            } else {
                Connect-RuleAdapter $app.name $profile $app.rulesTarget $sharedRules
            }
            $results += [pscustomobject]@{ name = $app.name; status = $status; reason = '' }
        }
        catch {
            $results += [pscustomobject]@{ name = $app.name; status = 'error'; reason = $_.Exception.Message }
        }
    }
    $connected = @($results | Where-Object { $_.status -eq 'connected' -or $_.status -eq 'already' }).Count
    if ($connected -eq 0 -and -not $oldMarker) {
        if (Undo-FreshPayload $profile $filePlan $agentsExisted $freshMarkerHash) {
            Write-Output 'No application was connected; unchanged files created in this run were rolled back.'
        } else {
            Write-Output 'No application was connected; rollback was skipped because the marker changed after installation.'
        }
    }
    elseif ($connected -gt 0) { Save-ConnectionStatus $profile $results }
    foreach ($result in $results) {
        Write-Output ("{0}: {1} {2}" -f $result.name, $result.status, $result.reason)
    }
    Write-Output 'Static file checks are complete; application loading still needs a new-session check.'
    if ($connected -eq 0) { exit 1 }
    if ($fileConflicts.Count -gt 0 -or @($results | Where-Object { $_.status -eq 'error' }).Count -gt 0) { exit 2 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
