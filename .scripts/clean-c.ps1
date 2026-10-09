#Requires -Version 7
param(
    [switch]$WhatIf,
    [string]$PodmanMachine = 'podman-machine-default',
    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'clean-c\cleanup-state.json'),
    [string]$ElevatedJob
)

$ErrorActionPreference = 'Stop'
$SystemDrive = $env:SystemDrive
$SystemRoot = $env:SystemRoot
$script:ProgressFile = $null

function Format-Size([Nullable[long]]$Bytes) {
    if ($null -eq $Bytes) { return '?' }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-Free([string]$Drive = $SystemDrive) { [System.IO.DriveInfo]::new($Drive).AvailableFreeSpace }

function Get-RowDrives([hashtable]$Row) { $Row.Drives ?? @($SystemDrive) }

function Format-DriveFree([string[]]$Drives) {
    ($Drives | ForEach-Object { "$_ free $(Format-Size (Get-Free $_))" }) -join ', '
}

function Get-FolderSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    [long]($sum ?? 0)
}

function Send-Progress([string]$Id, [int]$Pct, [string]$Text) {
    if ($script:ProgressFile) {
        @{ t = 'pct'; id = $Id; pct = $Pct; text = $Text } | ConvertTo-Json -Compress |
            Add-Content -LiteralPath $script:ProgressFile
    } else {
        Write-Progress -Activity $Id -Status $Text -PercentComplete ([Math]::Clamp($Pct, 0, 100))
    }
}

function Send-Log([string]$Text) {
    if ($script:ProgressFile) {
        @{ t = 'log'; text = $Text } | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:ProgressFile
    } else {
        Write-Host "      $Text" -ForegroundColor DarkGray
    }
}

function Invoke-Native([string]$Id, [string]$Exe, [string[]]$Arguments) {
    Send-Progress $Id 0 "$Exe $($Arguments -join ' ')"
    $global:LASTEXITCODE = 0
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" -split "`r" } | ForEach-Object {
        $line = $_.Trim()
        if (-not $line) { return }
        if ($line -match '(\d+(?:\.\d+)?)\s*(%|percent)') { Send-Progress $Id ([int][double]$Matches[1]) $line }
        else { Send-Log $line }
    }
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
}

$WindowsTemp = Join-Path $SystemRoot 'Temp'
$WuDownload = Join-Path $SystemRoot 'SoftwareDistribution\Download'
$HiberFile = Join-Path "$SystemDrive\" 'hiberfil.sys'
$WindowsOld = Join-Path "$SystemDrive\" 'Windows.old'

$AllowedClearRoots = @(
    [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\'),
    $WindowsTemp,
    $WuDownload
)

function Clear-FolderContents([string]$Id, [string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notin $AllowedClearRoots) { throw "Refusing to clear '$full': not in the allowed list." }
    if (-not (Test-Path -LiteralPath $full)) { return }
    $items = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
    $skipped = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        Send-Progress $Id ([int](100 * $i / [Math]::Max($items.Count, 1))) "$($i + 1)/$($items.Count) $($items[$i].Name)"
        try { Remove-Item -LiteralPath $items[$i].FullName -Recurse -Force -ErrorAction Stop }
        catch { $skipped++ }
    }
    if ($skipped) { Send-Log "$skipped item(s) in use or locked were skipped." }
}

function Get-State {
    $state = (Test-Path -LiteralPath $StatePath) ? (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable) : $null
    $state ?? @{}
}

function Set-State([hashtable]$State) {
    if ($State.Count) {
        New-Item -ItemType Directory -Force (Split-Path $StatePath -Parent) | Out-Null
        $State | ConvertTo-Json | Set-Content -LiteralPath $StatePath
    } elseif (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath }
}

function Get-PodmanVhdx {
    $p = (Get-WslDistros | Where-Object Name -eq $PodmanMachine).Vhdx
    if ($p -and (Test-Path -LiteralPath $p)) { $p }
}

function Get-PodmanDf {
    try { podman system df --format json 2>$null | ConvertFrom-Json } catch { $null }
}

function Get-WslDistros {
    $running = @(($null | wsl --list --running --quiet 2>$null) -replace "`0", '' | Where-Object { $_.Trim() }) | ForEach-Object Trim
    Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.GetValue('DistributionName')
        $base = $_.GetValue('BasePath')
        if (-not $name -or -not $base) { return }
        $vhdx = Join-Path ($base -replace '^\\\\\?\\', '') 'ext4.vhdx'
        [pscustomobject]@{
            Name      = $name
            Vhdx      = $vhdx
            Running   = $name -in $running
            LastWrite = (Test-Path -LiteralPath $vhdx) ? (Get-Item -LiteralPath $vhdx).LastWriteTime : $null
        }
    }
}

function Show-PodmanActivity([switch]$IncludeWsl) {
    $warn = @()
    $runningContainers = @(podman ps --format '{{.Names}}' 2>$null | Where-Object { $_ })
    $last = podman events --since 720h --until 0s --format json 2>$null | Select-Object -Last 1
    if ($last) {
        $e = $last | ConvertFrom-Json
        $when = [DateTimeOffset]::FromUnixTimeSeconds($e.time).LocalDateTime
        $desc = "$($e.Type) $($e.Status) $($e.Name)"
    } else {
        $up = podman machine inspect --format '{{.LastUp}}' $PodmanMachine 2>$null
        $when = $null
        if ($up -match '^(\S+ \S+?)(\.\d+)? ([+-]\d{2})(\d{2})') {
            try { $when = [DateTimeOffset]::Parse("$($Matches[1]) $($Matches[3]):$($Matches[4])").LocalDateTime } catch { }
        }
        $desc = 'machine last started (no events in the last 30 days)'
    }
    $ago = $when ? [int]((Get-Date) - $when).TotalMinutes : $null
    $whenText = $when ? ('{0:yyyy-MM-dd HH:mm} ({1} min ago: {2})' -f $when, $ago, $desc) : 'unknown'
    Write-Host ("     Podman:  {0} running container(s){1} · last activity {2}" -f
        $runningContainers.Count, ($runningContainers ? " ($($runningContainers -join ', '))" : ''), $whenText)
    if ($runningContainers) { $warn += "$($runningContainers.Count) container(s) running" }
    if ($null -ne $ago -and $ago -lt 30) { $warn += "Podman activity $ago min ago — a build or test run may be in progress" }

    if ($IncludeWsl) {
        $distros = @(Get-WslDistros)
        $run = $distros | Where-Object Running | ForEach-Object Name
        $stop = $distros | Where-Object { -not $_.Running } | ForEach-Object {
            "$($_.Name) (last write $($_.LastWrite ? $_.LastWrite.ToString('yyyy-MM-dd') : '?'))"
        }
        Write-Host "     WSL:     running → $($run ? ($run -join ', ') : 'none')"
        Write-Host "              stopped → $($stop ? ($stop -join ', ') : 'none')"
        $others = $run | Where-Object { $_ -ne $PodmanMachine }
        if ($others) { $warn += "other WSL distro(s) running: $($others -join ', ') — they will be shut down" }
    }
    foreach ($w in $warn) { Write-Host "     ⚠ $w" -ForegroundColor Yellow }
}

$Rows = @(
    @{
        Id = 'user-temp'; Name = 'User temp'; Risk = 1; Admin = $false; Undo = '-'
        Command = "Remove contents of $env:TEMP"
        Consequence = 'None. Files in use are skipped.'
        Available = { $true }
        Measure = { Get-FolderSize $env:TEMP }
        Run = { Clear-FolderContents 'user-temp' $env:TEMP }
    }
    @{
        Id = 'windows-temp'; Name = 'Windows temp'; Risk = 1; Admin = $true; Undo = '-'
        Command = "Remove contents of $WindowsTemp"
        Consequence = 'None. Files in use are skipped. Size can only be measured elevated.'
        Available = { $true }
        Measure = { $null }
        Run = { Clear-FolderContents 'windows-temp' $WindowsTemp }
    }
    @{
        Id = 'recycle-bin'; Name = "Recycle Bin ($SystemDrive)"; Risk = 2; Admin = $false; Undo = '-'
        Command = "Clear-RecycleBin -DriveLetter $($SystemDrive[0]) -Force"
        Consequence = "Deleted files on $SystemDrive can no longer be restored from the Recycle Bin."
        Available = { $true }
        Measure = {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Get-FolderSize "$SystemDrive\`$Recycle.Bin\$sid"
        }
        Run = { Send-Progress 'recycle-bin' 0 'Emptying'; Clear-RecycleBin -DriveLetter $SystemDrive[0] -Force }
    }
    @{
        Id = 'wu-cache'; Name = 'Windows Update download cache'; Risk = 2; Admin = $true; Undo = '-'
        Command = "Stop wuauserv/bits, clear $WuDownload, restore services"
        Consequence = 'Pending updates are downloaded again. An in-progress update download restarts.'
        Available = { $true }
        Measure = { Get-FolderSize $WuDownload }
        Run = {
            $services = Get-Service wuauserv, bits
            $wasRunning = $services | Where-Object Status -eq 'Running'
            try {
                Send-Progress 'wu-cache' 0 'Stopping wuauserv, bits'
                $services | Stop-Service -Force
                Clear-FolderContents 'wu-cache' $WuDownload
            } finally {
                $wasRunning | Start-Service
            }
        }
    }
    @{
        Id = 'delivery-opt'; Name = 'Delivery Optimization cache'; Risk = 2; Admin = $true; Undo = '-'
        Command = 'Delete-DeliveryOptimizationCache -Force'
        Consequence = 'Windows stops sharing these update files with other PCs until they are downloaded again.'
        Available = { [bool](Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) }
        Measure = { try { [long](Get-DeliveryOptimizationPerfSnap).CacheSizeBytes } catch { $null } }
        Run = { Send-Progress 'delivery-opt' 0 'Deleting'; Delete-DeliveryOptimizationCache -Force }
    }
    @{
        Id = 'dism'; Name = 'Component store cleanup (DISM)'; Risk = 2; Admin = $true; Undo = '-'
        Command = 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup'
        Consequence = 'Superseded component versions are removed immediately instead of after 30 days. Can take 10+ minutes.'
        Available = { $true }
        Measure = { $null }
        Run = {
            Invoke-Native 'dism' 'Dism.exe' '/Online', '/Cleanup-Image', '/AnalyzeComponentStore'
            Invoke-Native 'dism' 'Dism.exe' '/Online', '/Cleanup-Image', '/StartComponentCleanup'
        }
    }
    @{
        Id = 'dism-resetbase'; Name = 'Component store cleanup + ResetBase'; Risk = 4; Admin = $true; Undo = 'IRREVERSIBLE'
        Supersedes = 'dism'
        Command = 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase'
        Consequence = 'All currently installed updates can no longer be uninstalled. Future updates are unaffected.'
        Available = { $true }
        Measure = { $null }
        Run = { Invoke-Native 'dism-resetbase' 'Dism.exe' '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase' }
    }
    @{
        Id = 'hibernation'; Name = 'Disable hibernation'; Risk = 3; Admin = $true; Undo = 'available'
        Command = 'powercfg /h off'
        Consequence = 'Hibernate and Fast Startup stop working. hiberfil.sys is deleted. Undo: powercfg /h on.'
        Available = { Test-Path -LiteralPath $HiberFile }
        Measure = { [long](Get-Item -LiteralPath $HiberFile -Force).Length }
        Run = {
            Invoke-Native 'hibernation' 'powercfg.exe' '/h', 'off'
            $s = Get-State; $s['hibernation'] = (Get-Date).ToString('s'); Set-State $s
        }
    }
    @{
        Id = 'hibernation-undo'; Name = 'Re-enable hibernation'; Risk = 1; Admin = $true; Undo = '-'; Hidden = $true
        Command = 'powercfg /h on'
        Consequence = 'Recreates hiberfil.sys and re-enables Hibernate and Fast Startup.'
        Available = { $true }
        Measure = { $null }
        Run = {
            Invoke-Native 'hibernation-undo' 'powercfg.exe' '/h', 'on'
            $s = Get-State; $s.Remove('hibernation'); Set-State $s
        }
    }
    @{
        Id = 'windows-old'; Name = 'Remove Windows.old'; Risk = 4; Admin = $true; Undo = 'IRREVERSIBLE'
        Command = 'cleanmgr /sagerun with "Previous Installations" selected'
        Consequence = 'You can no longer roll back to the previous Windows version.'
        Available = { Test-Path -LiteralPath $WindowsOld }
        Measure = { Get-FolderSize $WindowsOld }
        Run = {
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations'
            Set-ItemProperty -LiteralPath $key -Name StateFlags0099 -Value 2 -Type DWord
            try {
                Send-Progress 'windows-old' 0 'cleanmgr running (no percentage available)'
                Start-Process cleanmgr.exe -ArgumentList '/sagerun:99' -Wait
            } finally {
                Remove-ItemProperty -LiteralPath $key -Name StateFlags0099 -ErrorAction SilentlyContinue
            }
        }
    }
    @{
        Id = 'npm'; Name = 'npm cache'; Risk = 2; Admin = $false; Undo = '-'; Tool = 'npm'
        Command = 'npm cache clean --force'
        Consequence = 'Packages are downloaded again on next install.'
        Paths = { npm config get cache }
        Run = { Invoke-Native 'npm' 'npm' 'cache', 'clean', '--force' }
    }
    @{
        Id = 'pnpm'; Name = 'pnpm store (unreferenced)'; Risk = 2; Admin = $false; Undo = '-'; Tool = 'pnpm'
        Command = 'pnpm store prune'
        Consequence = 'Removes only packages no project references. Future installs may be slower. Size is unknown until it runs.'
        Paths = { pnpm store path }
        Measure = { $null }
        Run = { Invoke-Native 'pnpm' 'pnpm' 'store', 'prune' }
    }
    @{
        Id = 'yarn'; Name = 'yarn cache'; Risk = 2; Admin = $false; Undo = '-'; Tool = 'yarn'
        Command = 'yarn cache clean'
        Consequence = 'Packages are downloaded again on next install.'
        Paths = { yarn cache dir }
        Run = { Invoke-Native 'yarn' 'yarn' 'cache', 'clean' }
    }
    @{
        Id = 'nuget'; Name = 'NuGet caches'; Risk = 2; Admin = $false; Undo = '-'; Tool = 'dotnet'
        Command = 'dotnet nuget locals all --clear'
        Consequence = 'Packages are downloaded again on next restore.'
        Paths = { Get-NuGetLocals }
        Run = { Invoke-Native 'nuget' 'dotnet' 'nuget', 'locals', 'all', '--clear' }
    }
    @{
        Id = 'pip'; Name = 'pip cache'; Risk = 2; Admin = $false; Undo = '-'; Tool = 'pip'
        Command = 'pip cache purge'
        Consequence = 'Wheels are downloaded or rebuilt again on next install.'
        Paths = { pip cache dir }
        Run = { Invoke-Native 'pip' 'pip' 'cache', 'purge' }
    }
    @{
        Id = 'uv'; Name = 'uv cache'; Risk = 2; Admin = $false; Undo = '-'; Tool = 'uv'
        Command = 'uv cache clean'
        Consequence = 'Packages are downloaded again on next install. Fails if a uv process is running.'
        Paths = { uv cache dir }
        Run = { Invoke-Native 'uv' 'uv' 'cache', 'clean' }
    }
    @{
        Id = 'cargo'; Name = 'cargo registry (info only)'; Risk = 0; Admin = $false; Undo = '-'; InfoOnly = $true
        Command = 'none — cargo has no stable built-in cache clean'
        Consequence = 'Not selectable.'
        Available = { Test-Path -LiteralPath "$env:USERPROFILE\.cargo\registry" }
        Measure = { Get-FolderSize "$env:USERPROFILE\.cargo\registry" }
        Run = { }
    }
    @{
        Id = 'podman-images'; Name = 'Podman unused images/containers'; Risk = 2; Admin = $false; Undo = '-'; Podman = $true
        Command = 'podman system prune --all --force'
        Consequence = "Removes stopped containers and images no container uses; images are pulled/built again. Frees space inside the VM only — run 'Compact Podman vhdx' to return it to $SystemDrive."
        Available = { [bool](Get-Command podman -ErrorAction SilentlyContinue) }
        Measure = {
            $df = Get-PodmanDf
            if (-not $df) { return $null }
            [long](($df | Where-Object Type -in 'Images', 'Containers' | Measure-Object RawReclaimable -Sum).Sum)
        }
        Run = { Invoke-Native 'podman-images' 'podman' 'system', 'prune', '--all', '--force' }
    }
    @{
        Id = 'podman-volumes'; Name = 'Podman unused volumes'; Risk = 4; Admin = $false; Undo = 'IRREVERSIBLE'; Podman = $true
        Command = 'podman volume prune --force'
        Consequence = 'Deletes data in volumes no container uses (e.g. local database contents). Frees space inside the VM only.'
        Available = { [bool](Get-Command podman -ErrorAction SilentlyContinue) }
        Measure = {
            $df = Get-PodmanDf
            if (-not $df) { return $null }
            [long](($df | Where-Object Type -eq 'Local Volumes').RawReclaimable)
        }
        Run = { Invoke-Native 'podman-volumes' 'podman' 'volume', 'prune', '--force' }
    }
    @{
        Id = 'podman-compact'; Name = 'Compact Podman vhdx'; Risk = 3; Admin = $true; Undo = '-'; Podman = $true; PodmanWsl = $true
        Command = 'podman machine stop; wsl --shutdown; diskpart: attach vdisk readonly, compact vdisk, detach vdisk; podman machine start'
        Consequence = "Stops the Podman machine and ALL WSL distros for the duration. Returns space freed inside the VM to $SystemDrive."
        Available = { [bool](Get-PodmanVhdx) }
        Measure = {
            $vhdx = Get-PodmanVhdx
            if (-not (Get-WslDistros | Where-Object { $_.Name -eq $PodmanMachine -and $_.Running })) { return $null }
            $used = $null | wsl -d $PodmanMachine -- df -B1 --output=used / 2>$null | Select-Object -Last 1
            if ($used -match '^\s*(\d+)\s*$') { [Math]::Max([long]0, (Get-Item -LiteralPath $vhdx).Length - [long]$Matches[1]) } else { $null }
        }
        Before = {
            Write-Host '      Stopping Podman machine and WSL...'
            podman machine stop $PodmanMachine 2>&1 | Out-Null
            $null | wsl --shutdown 2>&1 | Out-Null
        }
        After = {
            Write-Host '      Starting Podman machine...'
            podman machine start $PodmanMachine 2>&1 | Out-Null
        }
        Run = {
            $vhdx = Get-PodmanVhdx
            if (-not $vhdx) { throw 'Podman vhdx not found.' }
            $scriptFile = New-TemporaryFile
            $detachFile = New-TemporaryFile
            try {
                Set-Content -LiteralPath $scriptFile "select vdisk file=`"$vhdx`"`nattach vdisk readonly`ncompact vdisk`ndetach vdisk"
                Set-Content -LiteralPath $detachFile "select vdisk file=`"$vhdx`"`ndetach vdisk noerr"
                Invoke-Native 'podman-compact' 'diskpart.exe' '/s', $scriptFile.FullName
            } finally {
                diskpart.exe /s $detachFile.FullName | Out-Null
                Remove-Item -LiteralPath $scriptFile, $detachFile -ErrorAction SilentlyContinue
            }
        }
    }
)

function Get-NuGetLocals {
    dotnet nuget locals all --list 2>$null | ForEach-Object {
        if ($_ -match '^[\w-]+:\s+(.+)$') { $Matches[1].Trim() }
    }
}

function Get-Row([string]$Id) { $Rows | Where-Object { $_.Id -eq $Id } }

function Resolve-CachePaths([hashtable]$Row) {
    if (-not (Get-Command $Row.Tool -ErrorAction SilentlyContinue)) { return $false }
    $Row.CachePaths = @(& $Row.Paths | ForEach-Object { "$_".Trim() } |
        Where-Object { $_ -and [System.IO.Path]::IsPathFullyQualified($_) })
    if (-not $Row.CachePaths) { return $false }
    $Row.Drives = @($Row.CachePaths | ForEach-Object { [System.IO.Path]::GetPathRoot($_).TrimEnd('\').ToUpper() } | Select-Object -Unique)
    $true
}

function Measure-Row([hashtable]$Row) {
    if ($Row.Measure) { return & $Row.Measure }
    [long](@($Row.CachePaths | ForEach-Object { Get-FolderSize $_ }) | Measure-Object -Sum).Sum
}

function Invoke-RestorePointCheck {
    $ps = @'
$ErrorActionPreference = 'Stop'
function Get-Recent {
    Get-ComputerRestorePoint | Where-Object {
        [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) -gt (Get-Date).AddHours(-24)
    } | Select-Object -Last 1
}
try {
    $r = Get-Recent
    if ($r) { "EXISTING $($r.Description)"; exit 0 }
    Checkpoint-Computer -Description 'clean-c' -RestorePointType MODIFY_SETTINGS
    $r = Get-Recent
    if ($r) { "CREATED $($r.Description)"; exit 0 }
    'FAILED no restore point found after Checkpoint-Computer'; exit 1
} catch { "FAILED $($_.Exception.Message)"; exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
    $out = powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded
    Send-Log "Restore point: $out"
    $LASTEXITCODE -eq 0
}

function Invoke-Row([hashtable]$Row) {
    $drives = Get-RowDrives $Row
    $before = [long](($drives | ForEach-Object { Get-Free $_ }) | Measure-Object -Sum).Sum
    $ok = $true; $err = $null
    try { & $Row.Run | Out-Null } catch { $ok = $false; $err = $_.Exception.Message }
    $after = [long](($drives | ForEach-Object { Get-Free $_ }) | Measure-Object -Sum).Sum
    [pscustomobject]@{ Id = $Row.Id; Ok = $ok; Error = $err; Freed = $after - $before }
}

if ($ElevatedJob) {
    $job = Get-Content -LiteralPath $ElevatedJob -Raw | ConvertFrom-Json
    $script:ProgressFile = $job.Progress
    $ids = @($job.Rows | Where-Object { Get-Row $_ })
    $needsRestorePoint = $ids | Where-Object { (Get-Row $_).Risk -ge 3 }
    $restoreOk = $needsRestorePoint ? (Invoke-RestorePointCheck) : $true
    foreach ($id in $ids) {
        $row = Get-Row $id
        if ($row.Risk -ge 3 -and -not $restoreOk) {
            @{ t = 'done'; id = $id; ok = $false; err = 'Aborted: no restore point available'; freed = 0 } |
                ConvertTo-Json -Compress | Add-Content -LiteralPath $script:ProgressFile
            continue
        }
        $r = Invoke-Row $row
        @{ t = 'done'; id = $id; ok = $r.Ok; err = $r.Error; freed = $r.Freed } |
            ConvertTo-Json -Compress | Add-Content -LiteralPath $script:ProgressFile
    }
    exit 0
}

function Show-Result($Row, [bool]$Ok, [string]$Err, [long]$Freed) {
    if ($Ok) {
        Write-Host ("  ✓ {0}: freed {1} ({2})" -f $Row.Name, (Format-Size ([Math]::Max($Freed, [long]0))), (Format-DriveFree (Get-RowDrives $Row))) -ForegroundColor Green
    } else {
        Write-Host ("  ✗ {0}: {1}" -f $Row.Name, $Err) -ForegroundColor Red
    }
}

function Invoke-ElevatedBatch([hashtable[]]$Batch) {
    $progress = Join-Path $env:TEMP "clean-c-$([guid]::NewGuid()).jsonl"
    $jobFile = Join-Path $env:TEMP "clean-c-$([guid]::NewGuid()).json"
    New-Item -ItemType File -Path $progress | Out-Null
    @{ Rows = @($Batch.Id); Progress = $progress } | ConvertTo-Json | Set-Content -LiteralPath $jobFile
    $freed = 0L
    try {
        Write-Host "  Rows needing admin: $(($Batch.Name) -join ', ') → one UAC prompt"
        try {
            $proc = Start-Process (Join-Path $PSHOME 'pwsh.exe') -Verb RunAs -PassThru -WindowStyle Minimized -ArgumentList @(
                '-NoProfile', '-File', "`"$PSCommandPath`"", '-ElevatedJob', "`"$jobFile`"",
                '-PodmanMachine', "`"$PodmanMachine`"", '-StatePath', "`"$StatePath`"")
        } catch {
            Write-Host "  ✗ Elevation failed: $($_.Exception.Message) Admin rows were not run." -ForegroundColor Red
            return 0L
        }
        $script:read = 0
        $script:batchFreed = 0L
        $script:doneIds = @()
        $handle = {
            try { $lines = @(Get-Content -LiteralPath $progress -ErrorAction Stop) } catch { return }
            for ($i = $script:read; $i -lt $lines.Count; $i++) {
                if (-not $lines[$i]) { $script:read = $i + 1; continue }
                try { $m = $lines[$i] | ConvertFrom-Json } catch { return }
                $script:read = $i + 1
                $name = (Get-Row $m.id).Name
                switch ($m.t) {
                    'log' { Write-Host "      $($m.text)" -ForegroundColor DarkGray }
                    'pct' { Write-Progress -Activity "[elevated] $name" -Status $m.text -PercentComplete ([Math]::Clamp([int]$m.pct, 0, 100)) }
                    'done' {
                        Write-Progress -Activity "[elevated] $name" -Completed
                        Show-Result (Get-Row $m.id) $m.ok $m.err ([long]$m.freed)
                        if ($m.ok) { $script:batchFreed += [long]$m.freed }
                        $script:doneIds += $m.id
                    }
                }
            }
        }
        while (-not $proc.HasExited) {
            . $handle
            Start-Sleep -Milliseconds 250
        }
        . $handle
        foreach ($row in $Batch | Where-Object { $_.Id -notin $script:doneIds }) {
            Show-Result $row $false 'no result reported (elevated process ended early)' 0
        }
        $freed = $script:batchFreed
    } finally {
        Remove-Item -LiteralPath $progress, $jobFile -ErrorAction SilentlyContinue
    }
    $freed
}

function Confirm-Row([hashtable]$Row) {
    Write-Host ''
    Write-Host ("[{0}] {1} — risk {2} — {3}{4}" -f $Row.Num, $Row.Name, $Row.Risk, (Format-Size $Row.Size),
        ($Row.Undo -eq 'IRREVERSIBLE' ? ' — IRREVERSIBLE' : '')) -ForegroundColor Cyan
    Write-Host "     Runs:        $($Row.Command)"
    if ($Row.CachePaths) { Write-Host "     Location:    $($Row.CachePaths -join ', ')" }
    Write-Host "     Consequence: $($Row.Consequence)"
    if ($Row.Undo -eq 'available') { Write-Host '     Undo:        available from the menu (U)' }
    if ($Row.Admin) { Write-Host '     Needs admin: yes (batched into one UAC prompt)' }
    if ($Row.Risk -ge 3 -and $Row.Admin) { Write-Host '     Safety:      a restore point is created (or one from the last 24 h reused) first; aborted if neither is possible' }
    if ($Row.Podman) { Show-PodmanActivity -IncludeWsl:([bool]$Row.PodmanWsl) }
    if ($WhatIf) { Write-Host '     WhatIf: not run.' -ForegroundColor Yellow; return $false }
    if ($Row.Risk -ge 3) { return (Read-Host '     Type YES to confirm') -ceq 'YES' }
    return (Read-Host '     Run? (y/n)') -match '^[yY]'
}

function Invoke-Selection([hashtable[]]$Selected) {
    $superseded = @($Selected | ForEach-Object { $_.Supersedes } | Where-Object { $_ })
    $Selected = @($Selected | Where-Object { $_.Id -notin $superseded })
    $confirmed = @($Selected | Where-Object { Confirm-Row $_ })
    if (-not $confirmed) { return 0L }
    Write-Host ''
    $total = 0L
    foreach ($row in $confirmed | Where-Object { -not $_.Admin }) {
        $r = Invoke-Row $row
        Write-Progress -Activity $row.Id -Completed
        Show-Result $row $r.Ok $r.Error $r.Freed
        if ($r.Ok) { $total += $r.Freed }
    }
    $admin = @($confirmed | Where-Object Admin)
    if ($admin) {
        $admin | Where-Object Before | ForEach-Object { & $_.Before }
        try { $total += Invoke-ElevatedBatch $admin }
        finally { $admin | Where-Object After | ForEach-Object { & $_.After } }
    }
    foreach ($row in $confirmed) { try { $row.Size = Measure-Row $row } catch { $row.Size = $null } }
    $total
}

function Invoke-UndoMenu {
    $state = Get-State
    if (-not $state.Count) { Write-Host '  Nothing to undo.'; return 0L }
    $undoRows = @($state.Keys | ForEach-Object { Get-Row "$_-undo" } | Where-Object { $_ })
    for ($i = 0; $i -lt $undoRows.Count; $i++) {
        $key = $undoRows[$i].Id -replace '-undo$', ''
        Write-Host ("  [{0}] {1} (done {2}) → {3}" -f ($i + 1), $undoRows[$i].Name, $state[$key], $undoRows[$i].Command)
    }
    $pick = Read-Host '  Undo which? (number, blank to cancel)'
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $undoRows.Count) { return 0L }
    $row = $undoRows[[int]$pick - 1]
    $row.Num = 'U'
    Invoke-Selection @($row)
}

$visible = @()
$candidates = @($Rows | Where-Object { -not $_.Hidden })
for ($i = 0; $i -lt $candidates.Count; $i++) {
    $row = $candidates[$i]
    Write-Progress -Activity 'Scanning' -Status $row.Name -PercentComplete (100 * $i / $candidates.Count)
    try {
        $available = $row.Paths ? (Resolve-CachePaths $row) : (& $row.Available)
        if (-not $available) { continue }
        $row.Size = Measure-Row $row
    } catch { $row.Size = $null }
    $visible += $row
}
Write-Progress -Activity 'Scanning' -Completed
$allDrives = @($visible | ForEach-Object { Get-RowDrives $_ } | Sort-Object -Unique)

$sessionFreed = 0L
while ($true) {
    $sorted = @($visible | Sort-Object @{ e = { $null -eq $_.Size } }, @{ e = { $_.Size }; Descending = $true })
    for ($i = 0; $i -lt $sorted.Count; $i++) { $sorted[$i].Num = $i + 1 }
    Write-Host ''
    if ($WhatIf) { Write-Host 'WhatIf mode: nothing will be changed.' -ForegroundColor Yellow }
    $sorted | ForEach-Object {
        [pscustomobject]@{
            '#'    = $_.Num
            Action = $_.Name
            Risk   = $_.InfoOnly ? '-' : $_.Risk
            Size   = Format-Size $_.Size
            Drive  = (Get-RowDrives $_) -join ','
            Undo   = $_.Undo
            Admin  = $_.Admin ? 'yes' : ''
        }
    } | Format-Table -AutoSize | Out-Host
    Write-Host ("{0} | freed this session {1}" -f (Format-DriveFree $allDrives), (Format-Size $sessionFreed))
    $choice = Read-Host 'Select (e.g. 1,2,5), U=undo, Q=quit'
    if ($null -eq $choice -or $choice.Trim() -match '^[qQ]$') { break }
    $choice = $choice.Trim()
    if ($choice -match '^[uU]$') { $sessionFreed += Invoke-UndoMenu; continue }
    $nums = $choice -split '\s*,\s*' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $selected = @($sorted | Where-Object { $_.Num -in $nums -and -not $_.InfoOnly })
    if (-not $selected) { Write-Host '  No valid rows selected.'; continue }
    $sessionFreed += Invoke-Selection $selected
}

Write-Host ("Done. Freed this session: {0}. {1}." -f (Format-Size $sessionFreed), (Format-DriveFree $allDrives)) -ForegroundColor Green
