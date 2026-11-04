#requires -Version 5.1
<#
.SYNOPSIS
    Autostart-Manager – zeigt Autostart-Programme (Registry Run-Schlüssel und Autostart-Ordner)
    und schaltet sie einzeln ab oder an.

.DESCRIPTION
    Portabel, keine Installation: nutzt nur PowerShell 5.1 und WPF, beides ist in Windows enthalten.
    Deaktivieren erfolgt wie im Task-Manager über ...\Explorer\StartupApproved.
    Der eigentliche Autostart-Eintrag bleibt dabei unverändert erhalten.

    Start: Start-AutostartManager.cmd (Doppelklick)
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:AppVersion   = '1.0.0'
$script:ScriptPath   = $PSCommandPath
$script:AppDir       = $PSScriptRoot
$script:Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
$script:ApprovedPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:IsAdmin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                           [Security.Principal.WindowsBuiltInRole]::Administrator)
$script:SessionBackupDone = $false
$script:StateFilter  = 'all'
$script:SearchText   = ''
$script:SysInfo      = $null
$script:Shell        = $null
$script:LogLoading   = $false

# Erfasste Autostart-Quellen und der jeweils zuständige StartupApproved-Unterschlüssel
$script:Sources = @(
    [pscustomobject]@{ Id = 'HKCU_Run';      Kind = 'Registry'; Hive = 'HKCU'; Approved = 'Run'
                       Path = 'Software\Microsoft\Windows\CurrentVersion\Run'
                       Label = 'HKCU Run'; Scope = 'Benutzer' }
    [pscustomobject]@{ Id = 'HKLM_Run';      Kind = 'Registry'; Hive = 'HKLM'; Approved = 'Run'
                       Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
                       Label = 'HKLM Run'; Scope = 'Alle Benutzer' }
    [pscustomobject]@{ Id = 'HKLM_Run32';    Kind = 'Registry'; Hive = 'HKLM'; Approved = 'Run32'
                       Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
                       Label = 'HKLM Run (32-Bit)'; Scope = 'Alle Benutzer' }
    [pscustomobject]@{ Id = 'User_Folder';   Kind = 'Folder';   Hive = 'HKCU'; Approved = 'StartupFolder'
                       Path = [Environment]::GetFolderPath('Startup')
                       Label = 'Startordner'; Scope = 'Benutzer' }
    [pscustomobject]@{ Id = 'Common_Folder'; Kind = 'Folder';   Hive = 'HKLM'; Approved = 'StartupFolder'
                       Path = [Environment]::GetFolderPath('CommonStartup')
                       Label = 'Startordner (alle)'; Scope = 'Alle Benutzer' }
)

#region Ablage und Protokoll ---------------------------------------------------------------

function Initialize-DataDir {
    # Bevorzugt neben dem Skript (portabel). Ist der Ordner schreibgeschützt: %LOCALAPPDATA%.
    $dir = $script:AppDir
    try {
        $probe = Join-Path $dir ('.schreibtest_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x')
        [IO.File]::Delete($probe)
    } catch {
        $dir = Join-Path $env:LOCALAPPDATA 'AutostartManager'
    }
    $script:DataDir   = $dir
    $script:LogDir    = Join-Path $dir 'logs'
    $script:BackupDir = Join-Path $dir 'backups'
    foreach ($d in $script:LogDir, $script:BackupDir) {
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'FEHLER')][string]$Level = 'INFO'
    )
    $line = '{0}  {1,-6} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $file = Join-Path $script:LogDir ('autostart_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    try { [IO.File]::AppendAllText($file, $line + [Environment]::NewLine, $script:Utf8NoBom) } catch { }
}

#endregion

#region Registry ---------------------------------------------------------------------------

function Open-BaseKey([string]$Hive) {
    $h = if ($Hive -eq 'HKCU') { [Microsoft.Win32.RegistryHive]::CurrentUser } else { [Microsoft.Win32.RegistryHive]::LocalMachine }
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($h, [Microsoft.Win32.RegistryView]::Registry64)
}

function Get-ApprovedBytes([string]$Hive, [string]$Sub, [string]$ValueName) {
    $base = Open-BaseKey $Hive
    try {
        $key = $base.OpenSubKey("$($script:ApprovedPath)\$Sub")
        if ($null -eq $key) { return $null }
        try { $val = $key.GetValue($ValueName) } finally { $key.Close() }
        if ($val -is [byte[]]) { return , $val }
        return $null
    } finally { $base.Close() }
}

function Test-ApprovedEnabled($Bytes) {
    # Kein Wert = aktiv. Erstes Byte gerade (02/06) = aktiv, ungerade (03/07) = deaktiviert.
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $true }
    return (($Bytes[0] % 2) -eq 0)
}

function Set-ApprovedState([string]$Hive, [string]$Sub, [string]$ValueName, [bool]$Enabled) {
    # Gleiches Format wie der Task-Manager: 4 Byte Status + 8 Byte FILETIME (Zeitpunkt der Deaktivierung)
    $data = New-Object byte[] 12
    if ($Enabled) {
        $data[0] = 2
    } else {
        $data[0] = 3
        [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($data, 4)
    }
    $base = Open-BaseKey $Hive
    try {
        $key = $base.CreateSubKey("$($script:ApprovedPath)\$Sub")
        try { $key.SetValue($ValueName, $data, [Microsoft.Win32.RegistryValueKind]::Binary) } finally { $key.Close() }
    } finally { $base.Close() }
}

#endregion

#region Erfassung ---------------------------------------------------------------------------

function Get-Shell {
    if (-not $script:Shell) { $script:Shell = New-Object -ComObject WScript.Shell }
    $script:Shell
}

function Complete-ExePath([string]$Path) {
    $p = $Path.Trim().Trim('"')
    if (-not $p) { return $null }
    try {
        if (-not [IO.Path]::IsPathRooted($p)) {
            foreach ($dir in @([Environment]::SystemDirectory, $env:windir)) {
                foreach ($c in @((Join-Path $dir $p), (Join-Path $dir "$p.exe"))) {
                    if ([IO.File]::Exists($c)) { return $c }
                }
            }
            return $p
        }
        if ([IO.File]::Exists($p)) { return $p }
        if ([IO.File]::Exists("$p.exe")) { return "$p.exe" }
    } catch { }
    return $p
}

function Resolve-ExePath([string]$Command) {
    # Ermittelt die Programmdatei aus einer Befehlszeile (mit/ohne Anführungszeichen, mit Argumenten)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $cmd = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        $cand = if ($end -gt 1) { $cmd.Substring(1, $end - 1) } else { $cmd.Trim('"') }
        return (Resolve-HostedFile (Complete-ExePath $cand) $cmd)
    }
    $parts = $cmd -split ' '
    for ($i = 1; $i -le $parts.Count; $i++) {
        $full = Complete-ExePath ($parts[0..($i - 1)] -join ' ')
        if ($full -and [IO.File]::Exists($full)) { return (Resolve-HostedFile $full $cmd) }
    }
    return (Complete-ExePath $parts[0])
}

function Resolve-HostedFile([string]$ExePath, [string]$Command) {
    # Bei rundll32 ist die eigentliche Datei die DLL im ersten Argument (Herausgeber stimmt sonst nicht)
    if ([IO.Path]::GetFileName($ExePath) -ine 'rundll32.exe') { return $ExePath }
    if ($Command -match 'rundll32(\.exe)?"?\s+"?([^",]+)') {
        $dll = Complete-ExePath $Matches[2]
        if ($dll -and [IO.File]::Exists($dll)) { return $dll }
    }
    return $ExePath
}

function Update-EntryDisplay($Entry) {
    $Entry.StatusText = if ($Entry.Enabled) { 'Aktiv' } else { 'Deaktiviert' }
    $Entry.SwitchTip  = if (-not $Entry.CanModify) { 'Nur mit Administratorrechten änderbar' }
                        elseif ($Entry.Enabled) { 'Klicken zum Deaktivieren' }
                        else { 'Klicken zum Aktivieren' }
}

function New-AutostartEntry {
    param(
        $Source, [string]$ValueName, [string]$Name, [string]$Command, [string]$ExePath, [string]$Location,
        [string]$ValueKind = '', [string]$LnkTarget = '', [string]$LnkArgs = '', [string]$LnkWorkDir = ''
    )
    $enabled = Test-ApprovedEnabled (Get-ApprovedBytes $Source.Hive $Source.Approved $ValueName)
    $exists  = [bool]($ExePath -and [IO.File]::Exists($ExePath))
    $publisher = ''
    $description = ''
    if ($exists) {
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
            $publisher   = "$($vi.CompanyName)".Trim()
            $description = "$($vi.FileDescription)".Trim()
        } catch { }
    }
    $publisherText = if ($publisher) { $publisher } else { '–' }
    $missingText   = if ($exists) { '' } else { 'Datei fehlt' }

    $entry = [pscustomobject]@{
        Id            = '{0}|{1}' -f $Source.Id, $ValueName
        SourceId      = $Source.Id
        Kind          = $Source.Kind
        Hive          = $Source.Hive
        ApprovedSub   = $Source.Approved
        SourceLabel   = $Source.Label
        Scope         = $Source.Scope
        ValueName     = $ValueName
        ValueKind     = $ValueKind
        Name          = $Name
        Command       = $Command
        ExePath       = $ExePath
        FileExists    = $exists
        Location      = $Location
        Publisher     = $publisher
        PublisherText = $publisherText
        Description   = $description
        MissingText   = $missingText
        LnkTarget     = $LnkTarget
        LnkArgs       = $LnkArgs
        LnkWorkDir    = $LnkWorkDir
        Enabled       = $enabled
        CanModify     = (($Source.Hive -eq 'HKCU') -or $script:IsAdmin)
        StatusText    = ''
        SwitchTip     = ''
    }
    Update-EntryDisplay $entry
    $entry
}

function Get-AutostartEntries {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($src in $script:Sources) {
        try {
            if ($src.Kind -eq 'Registry') {
                $base = Open-BaseKey $src.Hive
                try {
                    $key = $base.OpenSubKey($src.Path)
                    if ($key) {
                        try {
                            foreach ($vn in $key.GetValueNames()) {
                                if ([string]::IsNullOrEmpty($vn)) { continue }
                                $kind = $key.GetValueKind($vn)
                                if ($kind -ne 'String' -and $kind -ne 'ExpandString') { continue }
                                $raw = [string]$key.GetValue($vn, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                                $list.Add((New-AutostartEntry -Source $src -ValueName $vn -Name $vn -Command $raw `
                                            -ExePath (Resolve-ExePath $raw) -Location ('{0}\{1}' -f $src.Hive, $src.Path) `
                                            -ValueKind $kind.ToString()))
                            }
                        } finally { $key.Close() }
                    }
                } finally { $base.Close() }
            } else {
                if (-not $src.Path -or -not [IO.Directory]::Exists($src.Path)) { continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $src.Path -File -Force)) {
                    if ($f.Name -ieq 'desktop.ini') { continue }
                    $cmd = $f.FullName; $exe = $f.FullName; $t = ''; $a = ''; $w = ''
                    if ($f.Extension -ieq '.lnk') {
                        try {
                            $sc = (Get-Shell).CreateShortcut($f.FullName)
                            $t = "$($sc.TargetPath)"; $a = "$($sc.Arguments)"; $w = "$($sc.WorkingDirectory)"
                        } catch { }
                        if ($t) {
                            $exe = $t
                            $cmd = if ($a) { '"{0}" {1}' -f $t, $a } else { '"{0}"' -f $t }
                        }
                    }
                    $list.Add((New-AutostartEntry -Source $src -ValueName $f.Name -Name $f.BaseName -Command $cmd `
                                -ExePath $exe -Location $f.FullName -LnkTarget $t -LnkArgs $a -LnkWorkDir $w))
                }
            }
        } catch {
            Write-Log ('Quelle "{0}" konnte nicht gelesen werden: {1}' -f $src.Label, $_.Exception.Message) 'WARN'
        }
    }
    return @($list | Sort-Object Name)
}

function Set-EntryState($Entry, [bool]$Enabled) {
    if (-not $Entry.CanModify) { throw 'Für Einträge aller Benutzer sind Administratorrechte nötig.' }
    Set-ApprovedState $Entry.Hive $Entry.ApprovedSub $Entry.ValueName $Enabled
    $Entry.Enabled = $Enabled
    Update-EntryDisplay $Entry
    $verb = if ($Enabled) { 'AKTIVIERT  ' } else { 'DEAKTIVIERT' }
    Write-Log ('{0} {1}  [{2}]  {3}' -f $verb, $Entry.Name, $Entry.SourceLabel, $Entry.Command)
}

#endregion

#region Sicherung und Wiederherstellung ----------------------------------------------------

function Export-RegBackup([string]$Target) {
    # Sicherheitsnetz: .reg-Export aller beteiligten Schlüssel (per Doppelklick wieder einspielbar)
    $ErrorActionPreference = 'Continue'
    $keys = @(
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
        "HKCU\$($script:ApprovedPath)\Run"
        "HKCU\$($script:ApprovedPath)\StartupFolder"
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        "HKLM\$($script:ApprovedPath)\Run"
        "HKLM\$($script:ApprovedPath)\Run32"
        "HKLM\$($script:ApprovedPath)\StartupFolder"
    )
    $sb  = New-Object System.Text.StringBuilder
    [void]$sb.Append("Windows Registry Editor Version 5.00`r`n")
    $tmp = [IO.Path]::GetTempFileName()
    try {
        foreach ($k in $keys) {
            & "$env:SystemRoot\System32\reg.exe" export $k $tmp /y 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $content = [IO.File]::ReadAllText($tmp, [Text.Encoding]::Unicode)
                $idx = $content.IndexOf("`r`n")
                if ($idx -ge 0) { [void]$sb.Append($content.Substring($idx + 2)) }
            }
        }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($Target, $sb.ToString(), [Text.Encoding]::Unicode)
}

function Backup-Autostart([string]$Reason = 'Manuell') {
    $entries = @(Get-AutostartEntries)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base  = Join-Path $script:BackupDir "autostart_$stamp"
    $n = 2
    while (Test-Path -LiteralPath "$base.json") { $base = Join-Path $script:BackupDir ('autostart_{0}_{1}' -f $stamp, $n); $n++ }

    $data = [ordered]@{
        Format   = 'AutostartManager-Backup'
        Version  = 1
        Created  = (Get-Date).ToString('s')
        Computer = $env:COMPUTERNAME
        User     = "$env:USERDOMAIN\$env:USERNAME"
        Reason   = $Reason
        Entries  = @(foreach ($e in $entries) {
            [ordered]@{
                Id = $e.Id; SourceId = $e.SourceId; ValueName = $e.ValueName; ValueKind = $e.ValueKind
                Name = $e.Name; Command = $e.Command; Location = $e.Location; Enabled = [bool]$e.Enabled
                LnkTarget = $e.LnkTarget; LnkArgs = $e.LnkArgs; LnkWorkDir = $e.LnkWorkDir
            }
        })
    }
    [IO.File]::WriteAllText("$base.json", ($data | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
    try { Export-RegBackup "$base.reg" } catch { Write-Log ('.reg-Export fehlgeschlagen: {0}' -f $_.Exception.Message) 'WARN' }
    Write-Log ('SICHERUNG   {0} ({1} Einträge, Anlass: {2})' -f (Split-Path -Leaf "$base.json"), $entries.Count, $Reason)
    return "$base.json"
}

function Read-BackupFile([string]$Path) {
    $b = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($b.Format -ne 'AutostartManager-Backup') { throw 'Die Datei ist keine gültige Sicherung des Autostart-Managers.' }
    $b
}

function Get-BackupList {
    foreach ($f in @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'autostart_*.json' -File | Sort-Object Name -Descending)) {
        try {
            $b = Read-BackupFile $f.FullName
            $items = @($b.Entries)
            $on = @($items | Where-Object { $_.Enabled }).Count
            $dt = [datetime]$b.Created
            [pscustomobject]@{
                Created  = $dt.ToString('dd.MM.yyyy  HH:mm:ss')
                SortKey  = $dt.ToString('yyyyMMddHHmmss')
                Reason   = $b.Reason
                Count    = $items.Count
                Active   = $on
                Disabled = $items.Count - $on
                File     = $f.Name
                Path     = $f.FullName
            }
        } catch {
            Write-Log ('Sicherung {0} nicht lesbar: {1}' -f $f.Name, $_.Exception.Message) 'WARN'
        }
    }
}

function Get-RestorePlan($Backup, $Current) {
    $map = @{}
    foreach ($c in $Current) { $map[$c.Id] = $c }
    foreach ($b in @($Backup.Entries)) {
        $src = $script:Sources | Where-Object { $_.Id -eq $b.SourceId } | Select-Object -First 1
        if (-not $src) { continue }
        $cur = $map[$b.Id]
        $action = $null
        if ($cur) {
            if ([bool]$cur.Enabled -ne [bool]$b.Enabled) { $action = if ($b.Enabled) { 'Aktivieren' } else { 'Deaktivieren' } }
        } else {
            $action = 'Neu anlegen'
        }
        if (-not $action) { continue }

        $can = $true; $reason = ''
        if ($src.Hive -eq 'HKLM' -and -not $script:IsAdmin) {
            $can = $false; $reason = 'Administratorrechte nötig'
        } elseif ($action -eq 'Neu anlegen' -and $src.Kind -eq 'Folder' -and -not $b.LnkTarget) {
            $can = $false; $reason = 'Datei lässt sich nicht neu erzeugen'
        } elseif ($action -eq 'Neu anlegen' -and $src.Kind -eq 'Registry' -and -not $b.Command) {
            $can = $false; $reason = 'Befehl fehlt in der Sicherung'
        }
        [pscustomobject]@{ Action = $action; Name = $b.Name; Label = $src.Label; Backup = $b; Source = $src
                           CanApply = $can; Reason = $reason }
    }
}

function Invoke-RestoreItem($Item) {
    $b = $Item.Backup
    $src = $Item.Source
    if ($Item.Action -eq 'Neu anlegen') {
        if ($src.Kind -eq 'Registry') {
            $kind = if ($b.ValueKind -eq 'ExpandString') { [Microsoft.Win32.RegistryValueKind]::ExpandString } else { [Microsoft.Win32.RegistryValueKind]::String }
            $base = Open-BaseKey $src.Hive
            try {
                $key = $base.CreateSubKey($src.Path)
                try { $key.SetValue($b.ValueName, [string]$b.Command, $kind) } finally { $key.Close() }
            } finally { $base.Close() }
        } else {
            $sc = (Get-Shell).CreateShortcut((Join-Path $src.Path $b.ValueName))
            $sc.TargetPath = $b.LnkTarget
            $sc.Arguments = "$($b.LnkArgs)"
            $sc.WorkingDirectory = "$($b.LnkWorkDir)"
            $sc.Save()
        }
    }
    Set-ApprovedState $src.Hive $src.Approved $b.ValueName ([bool]$b.Enabled)
}

#endregion

#region Systeminformationen -----------------------------------------------------------------

function Get-CimSafe([string]$Class, [string]$Filter) {
    try {
        if ($Filter) { @(Get-CimInstance -ClassName $Class -Filter $Filter -ErrorAction Stop) }
        else { @(Get-CimInstance -ClassName $Class -ErrorAction Stop) }
    } catch {
        Write-Log ('WMI-Abfrage {0} fehlgeschlagen: {1}' -f $Class, $_.Exception.Message) 'WARN'
        @()
    }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Format-Date($Value, [string]$Format = 'dd.MM.yyyy HH:mm') {
    if ($Value) { ([datetime]$Value).ToString($Format) } else { '–' }
}

function New-InfoRow([string]$Key, $Value, $Pct = $null) {
    [pscustomobject]@{ K = $Key; V = "$Value".Trim(); Pct = $Pct }
}

function Get-SystemInfo {
    $os    = @(Get-CimSafe 'Win32_OperatingSystem')[0]
    $cs    = @(Get-CimSafe 'Win32_ComputerSystem')[0]
    $bios  = @(Get-CimSafe 'Win32_BIOS')[0]
    $board = @(Get-CimSafe 'Win32_BaseBoard')[0]
    $cpus  = @(Get-CimSafe 'Win32_Processor')
    $gpus  = @(Get-CimSafe 'Win32_VideoController')
    $mem   = @(Get-CimSafe 'Win32_PhysicalMemory')
    $disks = @(Get-CimSafe 'Win32_LogicalDisk' 'DriveType=3')
    $nics  = @(Get-CimSafe 'Win32_NetworkAdapterConfiguration' 'IPEnabled=TRUE')
    $nt    = $null
    try { $nt = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' } catch { }

    $groups = New-Object System.Collections.Generic.List[object]

    # Betriebssystem
    $rows = @()
    if ($os) {
        $ver = ''
        $build = "$($os.BuildNumber)"
        if ($nt) {
            $ver = "$($nt.DisplayVersion)"
            if ($null -ne $nt.UBR) { $build = '{0}.{1}' -f $os.BuildNumber, $nt.UBR }
        }
        $verText = if ($ver) { '{0}  (Build {1})' -f $ver, $build } else { 'Build {0}' -f $build }
        $rows += New-InfoRow 'System' $os.Caption
        $rows += New-InfoRow 'Version' $verText
        $rows += New-InfoRow 'Architektur' $os.OSArchitecture
        $rows += New-InfoRow 'Installiert am' (Format-Date $os.InstallDate 'dd.MM.yyyy')
        $rows += New-InfoRow 'Letzter Start' (Format-Date $os.LastBootUpTime)
        if ($os.LastBootUpTime) {
            $up = (Get-Date) - $os.LastBootUpTime
            $rows += New-InfoRow 'Laufzeit' ('{0} Tage, {1} Std., {2} Min.' -f $up.Days, $up.Hours, $up.Minutes)
        }
    }
    $groups.Add([pscustomobject]@{ Title = 'Betriebssystem'; Rows = $rows })

    # Rechner
    $rows = @()
    $rows += New-InfoRow 'Rechnername' $env:COMPUTERNAME
    $rows += New-InfoRow 'Benutzer' "$env:USERDOMAIN\$env:USERNAME"
    if ($cs) {
        if ($cs.PartOfDomain) { $rows += New-InfoRow 'Domäne' $cs.Domain } else { $rows += New-InfoRow 'Arbeitsgruppe' $cs.Workgroup }
        $rows += New-InfoRow 'Hersteller' $cs.Manufacturer
        $rows += New-InfoRow 'Modell' $cs.Model
    }
    if ($board) { $rows += New-InfoRow 'Mainboard' ('{0} {1}' -f $board.Manufacturer, $board.Product) }
    if ($bios)  { $rows += New-InfoRow 'BIOS' ('{0}, Version {1}, {2}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, (Format-Date $bios.ReleaseDate 'dd.MM.yyyy')) }
    $groups.Add([pscustomobject]@{ Title = 'Rechner'; Rows = $rows })

    # Prozessor
    $rows = @()
    if ($cpus.Count -gt 0) {
        $c = $cpus[0]
        $rows += New-InfoRow 'Modell' ("$($c.Name)" -replace '\s+', ' ')
        $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $threads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $rows += New-InfoRow 'Kerne / Threads' ('{0} / {1}' -f $cores, $threads)
        if ($cpus.Count -gt 1) { $rows += New-InfoRow 'Sockel' $cpus.Count }
        if ($c.MaxClockSpeed) { $rows += New-InfoRow 'Max. Takt' ('{0:N2} GHz' -f ($c.MaxClockSpeed / 1000)) }
        if ($null -ne $c.LoadPercentage) { $rows += New-InfoRow 'Auslastung' ('{0} %' -f $c.LoadPercentage) $c.LoadPercentage }
    }
    $groups.Add([pscustomobject]@{ Title = 'Prozessor'; Rows = $rows })

    # Arbeitsspeicher
    $rows = @()
    if ($os -and $os.TotalVisibleMemorySize) {
        $total = [double]$os.TotalVisibleMemorySize * 1KB
        $free  = [double]$os.FreePhysicalMemory * 1KB
        $pct   = [math]::Round(($total - $free) / $total * 100)
        $rows += New-InfoRow 'Belegt' ('{0} von {1}  ({2} %)' -f (Format-Size ($total - $free)), (Format-Size $total), $pct) $pct
        $rows += New-InfoRow 'Verfügbar' (Format-Size $free)
    }
    if ($mem.Count -gt 0) {
        $modules = ($mem | Group-Object Capacity | ForEach-Object { '{0} × {1}' -f $_.Count, (Format-Size ([double]$_.Name)) }) -join ', '
        $speed = ($mem | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } |
                  Measure-Object -Maximum).Maximum
        if ($speed) { $modules = '{0}  ·  {1} MT/s' -f $modules, $speed }
        $rows += New-InfoRow 'Module' $modules
    }
    $groups.Add([pscustomobject]@{ Title = 'Arbeitsspeicher'; Rows = $rows })

    # Grafik
    $rows = @()
    $i = 0
    foreach ($g in $gpus) {
        $i++
        $detail = 'Treiber {0}' -f $g.DriverVersion
        if ($g.CurrentHorizontalResolution) { $detail += '  ·  {0} × {1}' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution }
        $key = if ($gpus.Count -gt 1) { 'Grafikkarte {0}' -f $i } else { 'Grafikkarte' }
        $rows += New-InfoRow $key ("$($g.Name)`n$detail")
    }
    $groups.Add([pscustomobject]@{ Title = 'Grafik'; Rows = $rows })

    # Datenträger
    $rows = @()
    foreach ($d in $disks) {
        if (-not $d.Size) { continue }
        $used = [double]$d.Size - [double]$d.FreeSpace
        $pct  = [math]::Round($used / [double]$d.Size * 100)
        $key  = if ($d.VolumeName) { '{0}  {1}' -f $d.DeviceID, $d.VolumeName } else { $d.DeviceID }
        $rows += New-InfoRow $key ('{0} frei von {1}  ·  {2}' -f (Format-Size $d.FreeSpace), (Format-Size $d.Size), $d.FileSystem) $pct
    }
    $groups.Add([pscustomobject]@{ Title = 'Datenträger'; Rows = $rows })

    # Netzwerk
    $rows = @()
    $i = 0
    foreach ($n in $nics) {
        $i++
        $ipv4 = @($n.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) -join ', '
        $gw   = @($n.DefaultIPGateway | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) -join ', '
        $lines = @("$($n.Description)")
        if ($ipv4) { $lines += 'IPv4 {0}' -f $ipv4 }
        if ($gw)   { $lines += 'Gateway {0}' -f $gw }
        if ($n.MACAddress) { $lines += 'MAC {0}' -f $n.MACAddress }
        $key = if ($nics.Count -gt 1) { 'Adapter {0}' -f $i } else { 'Adapter' }
        $rows += New-InfoRow $key ($lines -join "`n")
    }
    $groups.Add([pscustomobject]@{ Title = 'Netzwerk'; Rows = $rows })

    return @($groups | Where-Object { $_.Rows.Count -gt 0 })
}

function Format-SystemInfoText($Groups) {
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('Systeminformationen  {0}  {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'dd.MM.yyyy HH:mm')))
    $out.Add('')
    foreach ($g in $Groups) {
        $out.Add($g.Title)
        $out.Add(('-' * $g.Title.Length))
        foreach ($r in $g.Rows) {
            $v = $r.V -replace "`n", ("`r`n" + (' ' * 20))
            $out.Add(('{0,-18}  {1}' -f $r.K, $v))
        }
        $out.Add('')
    }
    $out -join "`r`n"
}

#endregion

#region Oberfläche: Hilfsfunktionen ----------------------------------------------------------

function ConvertTo-XamlText([string]$Text) {
    $s = [Security.SecurityElement]::Escape("$Text") -replace "`r?`n", '&#10;'
    if ($s.StartsWith('{')) { $s = '{}' + $s }
    $s
}

function New-InfoCard($Group) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="White" BorderBrush="#E3E3DF" BorderThickness="1" CornerRadius="4" Padding="18,14,18,12" Margin="0,0,0,14"><StackPanel>')
    [void]$sb.AppendFormat('<TextBlock Text="{0}" FontSize="13.5" FontWeight="SemiBold" Margin="0,0,0,8"/>', (ConvertTo-XamlText $Group.Title))
    foreach ($r in $Group.Rows) {
        $k = ConvertTo-XamlText $r.K
        [void]$sb.Append('<Grid Margin="0,4,0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>')
        [void]$sb.AppendFormat('<TextBlock Text="{0}" ToolTip="{0}" Foreground="#6B7075" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>', $k)
        [void]$sb.Append('<StackPanel Grid.Column="1">')
        [void]$sb.AppendFormat('<TextBlock Text="{0}" TextWrapping="Wrap"/>', (ConvertTo-XamlText $r.V))
        if ($null -ne $r.Pct) {
            $p = [int][math]::Max(0, [math]::Min(100, [double]$r.Pct))
            $color = if ($p -ge 90) { '#B3261E' } elseif ($p -ge 75) { '#B7791F' } else { '#1F6F78' }
            [void]$sb.AppendFormat('<Grid Height="5" Margin="0,6,0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="{0}*"/><ColumnDefinition Width="{1}*"/></Grid.ColumnDefinitions><Border Grid.ColumnSpan="2" Background="#E8E8E4" CornerRadius="2.5"/><Border Background="{2}" CornerRadius="2.5"/></Grid>', $p, (100 - $p), $color)
        }
        [void]$sb.Append('</StackPanel></Grid>')
    }
    [void]$sb.Append('</StackPanel></Border>')
    [Windows.Markup.XamlReader]::Parse($sb.ToString())
}

function Show-Message([string]$Text, [string]$Icon = 'Information') {
    [void][Windows.MessageBox]::Show($script:Window, $Text, 'Autostart-Manager', 'OK', $Icon)
}

function Confirm-Action([string]$Text) {
    ([Windows.MessageBox]::Show($script:Window, $Text, 'Autostart-Manager', 'YesNo', 'Question') -eq 'Yes')
}

function Set-Status([string]$Text) { $script:UI.TxtStatus.Text = $Text }

function Invoke-Guarded([scriptblock]$Action) {
    try { & $Action }
    catch {
        $msg = $_.Exception.Message
        Write-Log $msg 'FEHLER'
        Set-Status ('Fehler: {0}' -f $msg)
        Show-Message $msg 'Error'
    }
}

#endregion

#region Oberfläche: Seiten ------------------------------------------------------------------

function Update-Counts {
    $all = @($script:Entries)
    $on  = @($all | Where-Object { $_.Enabled }).Count
    $script:UI.TxtCounts.Text = '{0} Einträge  ·  {1} aktiv  ·  {2} deaktiviert' -f $all.Count, $on, ($all.Count - $on)
    $script:UI.TxtEmpty.Visibility = if ($script:View.IsEmpty) { 'Visible' } else { 'Collapsed' }
    $locked = @($all | Where-Object { -not $_.CanModify }).Count
    $script:UI.AdminHint.Visibility = if ($locked -gt 0) { 'Visible' } else { 'Collapsed' }
}

function Update-EntryList {
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $script:Entries.Clear()
        foreach ($e in @(Get-AutostartEntries)) { $script:Entries.Add($e) }
    } finally { $script:Window.Cursor = $null }
    Update-Counts
    Set-Status ('Autostart eingelesen um {0}' -f (Get-Date -Format 'HH:mm:ss'))
}

function Test-EntryFilter($Item) {
    if ($script:StateFilter -eq 'on'  -and -not $Item.Enabled) { return $false }
    if ($script:StateFilter -eq 'off' -and $Item.Enabled) { return $false }
    $q = $script:SearchText
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $hay = '{0} {1} {2} {3} {4}' -f $Item.Name, $Item.Publisher, $Item.Description, $Item.Command, $Item.SourceLabel
    return ($hay.IndexOf($q.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Invoke-SessionBackup {
    if ($script:SessionBackupDone) { return }
    try {
        [void](Backup-Autostart 'Automatisch (vor erster Änderung)')
        $script:SessionBackupDone = $true
    } catch {
        Write-Log ('Automatische Sicherung fehlgeschlagen: {0}' -f $_.Exception.Message) 'WARN'
    }
}

function Invoke-Toggle($Button, $Entry) {
    $want = [bool]$Button.IsChecked
    try {
        Invoke-SessionBackup
        Set-EntryState $Entry $want
        $state = if ($want) { 'aktiviert' } else { 'deaktiviert' }
        Set-Status ('"{0}" {1}.' -f $Entry.Name, $state)
    } catch {
        $Button.IsChecked = -not $want
        $msg = $_.Exception.Message
        if ($_.Exception -is [UnauthorizedAccessException] -or $_.Exception.InnerException -is [UnauthorizedAccessException]) {
            $msg = 'Zugriff verweigert. Für diesen Eintrag sind Administratorrechte nötig.'
        }
        Write-Log ('Umschalten von "{0}" fehlgeschlagen: {1}' -f $Entry.Name, $msg) 'FEHLER'
        Show-Message $msg 'Warning'
    }
    $script:View.Refresh()
    Update-Counts
}

function Open-EntryLocation($Entry) {
    $target = if ($Entry.Kind -eq 'Folder') { $Entry.Location } elseif ($Entry.FileExists) { $Entry.ExePath } else { $null }
    if ($target -and (Test-Path -LiteralPath $target)) {
        Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList ('/select,"{0}"' -f $target)
    } else {
        Show-Message ('Die Programmdatei wurde nicht gefunden:{0}{0}{1}' -f [Environment]::NewLine, $Entry.Command) 'Warning'
    }
}

function Request-SystemInfo {
    $ui = $script:UI
    $ui.SysColLeft.Children.Clear()
    $ui.SysColRight.Children.Clear()
    $ui.TxtSysLoading.Visibility = 'Visible'
    Set-Status 'Systeminformationen werden gelesen …'
    [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
        Invoke-Guarded {
            $script:Window.Cursor = [Windows.Input.Cursors]::Wait
            try {
                $script:SysInfo = @(Get-SystemInfo)
                Show-SystemInfo
                Set-Status ('Systeminformationen gelesen um {0}' -f (Get-Date -Format 'HH:mm:ss'))
            } finally {
                $script:Window.Cursor = $null
                $script:UI.TxtSysLoading.Visibility = 'Collapsed'
            }
        }
    })
}

function Show-SystemInfo {
    $ui = $script:UI
    $ui.SysColLeft.Children.Clear()
    $ui.SysColRight.Children.Clear()
    $wl = 0; $wr = 0
    foreach ($g in $script:SysInfo) {
        $card = New-InfoCard $g
        $weight = 2 + ($g.Rows | ForEach-Object { 1 + ([regex]::Matches($_.V, "`n")).Count } | Measure-Object -Sum).Sum
        if ($wl -le $wr) { [void]$ui.SysColLeft.Children.Add($card); $wl += $weight }
        else { [void]$ui.SysColRight.Children.Add($card); $wr += $weight }
    }
}

function Update-BackupList {
    $items = @(Get-BackupList)
    $script:UI.GridBackups.ItemsSource = $items
    $script:UI.TxtBackupEmpty.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $script:UI.TxtBackupPath.Text = 'Speicherort: {0}' -f $script:BackupDir
}

function Get-SelectedBackup {
    $sel = $script:UI.GridBackups.SelectedItem
    if (-not $sel) { Show-Message 'Bitte zuerst eine Sicherung in der Liste auswählen.'; return $null }
    $sel
}

function Restore-FromBackup([string]$Path) {
    $backup  = Read-BackupFile $Path
    $current = @(Get-AutostartEntries)
    $plan    = @(Get-RestorePlan $backup $current)
    $created = Format-Date $backup.Created 'dd.MM.yyyy HH:mm:ss'

    if ($plan.Count -eq 0) {
        Show-Message ('Der aktuelle Zustand entspricht bereits der Sicherung vom {0}.' -f $created)
        return
    }
    $doable  = @($plan | Where-Object { $_.CanApply })
    $skipped = @($plan | Where-Object { -not $_.CanApply })

    $nl = [Environment]::NewLine
    $text = 'Sicherung vom {0} ({1}) wiederherstellen?{2}{2}' -f $created, $backup.Reason, $nl
    if ($doable.Count -gt 0) {
        $text += 'Wird geändert:' + $nl
        foreach ($p in ($doable | Select-Object -First 15)) { $text += '   {0}: {1}  [{2}]{3}' -f $p.Action, $p.Name, $p.Label, $nl }
        if ($doable.Count -gt 15) { $text += '   … und {0} weitere{1}' -f ($doable.Count - 15), $nl }
    }
    if ($skipped.Count -gt 0) {
        $text += $nl + 'Wird übersprungen:' + $nl
        foreach ($p in ($skipped | Select-Object -First 10)) { $text += '   {0}  [{1}]: {2}{3}' -f $p.Name, $p.Label, $p.Reason, $nl }
    }
    if ($doable.Count -eq 0) {
        Show-Message ($text.Replace('wiederherstellen?', 'kann nicht angewendet werden.')) 'Warning'
        return
    }
    $text += $nl + 'Einträge, die seit der Sicherung neu hinzugekommen sind, bleiben unverändert.'
    if (-not (Confirm-Action $text)) { return }

    [void](Backup-Autostart 'Automatisch (vor Wiederherstellung)')
    $script:SessionBackupDone = $true
    $ok = 0; $fail = 0
    foreach ($p in $doable) {
        try {
            Invoke-RestoreItem $p
            $ok++
            Write-Log ('WIEDERHERG. {0}: {1}  [{2}]' -f $p.Action, $p.Name, $p.Label)
        } catch {
            $fail++
            Write-Log ('Wiederherstellung von "{0}" fehlgeschlagen: {1}' -f $p.Name, $_.Exception.Message) 'FEHLER'
        }
    }
    foreach ($p in $skipped) { Write-Log ('ÜBERSPRUNGEN {0}  [{1}]: {2}' -f $p.Name, $p.Label, $p.Reason) 'WARN' }
    Write-Log ('Wiederherstellung aus {0}: {1} angewendet, {2} Fehler, {3} übersprungen' -f (Split-Path -Leaf $Path), $ok, $fail, $skipped.Count)

    Update-EntryList
    Update-BackupList
    $summary = '{0} Änderung(en) angewendet.' -f $ok
    if ($fail -gt 0)           { $summary += '{0}{1} fehlgeschlagen – Details im Protokoll.' -f $nl, $fail }
    if ($skipped.Count -gt 0)  { $summary += '{0}{1} übersprungen.' -f $nl, $skipped.Count }
    Set-Status ('Wiederherstellung abgeschlossen: {0} angewendet' -f $ok)
    Show-Message $summary
}

function Update-LogFiles {
    $cmb = $script:UI.CmbLogFiles
    $prev = if ($cmb.SelectedItem) { $cmb.SelectedItem.Tag } else { $null }
    $script:LogLoading = $true
    try {
        $cmb.Items.Clear()
        foreach ($f in @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'autostart_*.log' -File | Sort-Object Name -Descending)) {
            $item = New-Object Windows.Controls.ComboBoxItem
            try { $item.Content = [datetime]::ParseExact($f.BaseName.Substring(10), 'yyyyMMdd', $null).ToString('dddd, dd.MM.yyyy') }
            catch { $item.Content = $f.Name }
            $item.Tag = $f.FullName
            [void]$cmb.Items.Add($item)
        }
    } finally { $script:LogLoading = $false }

    if ($cmb.Items.Count -eq 0) { $script:UI.TxtLog.Text = 'Noch keine Einträge.'; return }
    $index = 0
    for ($i = 0; $i -lt $cmb.Items.Count; $i++) { if ($cmb.Items[$i].Tag -eq $prev) { $index = $i } }
    $cmb.SelectedIndex = $index
}

function Show-LogFile([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    [array]::Reverse($lines)
    $script:UI.TxtLog.Text = $lines -join "`r`n"
    $script:UI.TxtLog.ScrollToHome()
}

function Show-Page([string]$Nav) {
    $pages = [ordered]@{ NavAutostart = 'PageAutostart'; NavSystem = 'PageSystem'; NavBackup = 'PageBackup'; NavLog = 'PageLog' }
    foreach ($k in $pages.Keys) {
        $script:UI[$pages[$k]].Visibility = if ($k -eq $Nav) { 'Visible' } else { 'Collapsed' }
    }
    switch ($Nav) {
        'NavSystem' { if (-not $script:SysInfo) { Request-SystemInfo } }
        'NavBackup' { Update-BackupList }
        'NavLog'    { Update-LogFiles }
    }
}

#endregion

#region Start --------------------------------------------------------------------------------

try {
    Initialize-DataDir

    $xamlText = [IO.File]::ReadAllText((Join-Path $script:AppDir 'MainWindow.xaml'), [Text.Encoding]::UTF8)
    $reader   = [Xml.XmlReader]::Create((New-Object IO.StringReader $xamlText))
    $window   = [Windows.Markup.XamlReader]::Load($reader)
    $script:Window = $window

    $ui = @{}
    foreach ($m in [regex]::Matches($xamlText, 'x:Name="([^"]+)"')) {
        $el = $window.FindName($m.Groups[1].Value)
        if ($el) { $ui[$m.Groups[1].Value] = $el }
    }
    $script:UI = $ui

    # Kopfbereich und Rechte
    $ui.TxtMachine.Text = $env:COMPUTERNAME
    $ui.TxtVersion.Text = 'Version {0}' -f $script:AppVersion
    if ($script:IsAdmin) {
        $ui.TxtRights.Text = 'Administrator'
        $ui.DotRights.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#5DB47F')
        $ui.BtnElevate.Visibility = 'Collapsed'
        $window.Title = 'Autostart-Manager (Administrator)'
    } else {
        $ui.TxtRights.Text = 'Standardbenutzer'
    }

    # Datenquelle der Autostart-Tabelle
    $script:Entries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:View    = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Entries)
    $script:View.Filter = [Predicate[object]]{ param($item) Test-EntryFilter $item }
    $ui.GridEntries.ItemsSource = $script:Entries

    # Schalter und "Anzeigen" in der Tabelle (gemeinsamer Handler für alle Zeilen)
    $ui.GridEntries.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -isnot [Windows.FrameworkElement] -or $null -eq $src.DataContext) { return }
        switch ("$($src.Tag)") {
            'toggle' { Invoke-Toggle $src $src.DataContext }
            'open'   { Invoke-Guarded { Open-EntryLocation $src.DataContext } }
        }
    })

    # Navigation
    foreach ($nav in 'NavAutostart', 'NavSystem', 'NavBackup', 'NavLog') {
        $ui[$nav].add_Checked({ param($s, $e) Invoke-Guarded { Show-Page $s.Name } })
    }

    # Suche und Filter
    $ui.TxtSearch.add_TextChanged({
        $script:SearchText = $script:UI.TxtSearch.Text
        $script:UI.TxtSearchHint.Visibility = if ($script:SearchText) { 'Collapsed' } else { 'Visible' }
        $script:View.Refresh()
        Update-Counts
    })
    $filterMap = @{ FltAll = 'all'; FltOn = 'on'; FltOff = 'off' }
    foreach ($f in $filterMap.Keys) {
        $ui[$f].add_Checked({
            param($s, $e)
            $script:StateFilter = @{ FltAll = 'all'; FltOn = 'on'; FltOff = 'off' }[$s.Name]
            $script:View.Refresh()
            Update-Counts
        })
    }

    # Buttons: ein Handler, Aktion je Button-Name
    $script:ClickActions = @{
        BtnRefresh = { Update-EntryList }
        BtnElevate = {
            try {
                $psExe = Join-Path $PSHOME 'powershell.exe'
                Start-Process -FilePath $psExe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $script:ScriptPath)
                Write-Log 'Neustart mit Administratorrechten angefordert.'
                $script:Window.Close()
            } catch {
                Write-Log 'Rechteanhebung abgebrochen.' 'WARN'
                Set-Status 'Rechteanhebung abgebrochen.'
            }
        }
        BtnSysCopy = {
            if (-not $script:SysInfo) { return }
            [Windows.Clipboard]::SetText((Format-SystemInfoText $script:SysInfo))
            Set-Status 'Systeminformationen in die Zwischenablage kopiert.'
        }
        BtnSysReload    = { $script:SysInfo = $null; Request-SystemInfo }
        BtnBackupCreate = {
            $p = Backup-Autostart 'Manuell'
            Update-BackupList
            Set-Status ('Sicherung erstellt: {0}' -f (Split-Path -Leaf $p))
        }
        BtnBackupRestore = {
            $sel = Get-SelectedBackup
            if ($sel) { Restore-FromBackup $sel.Path }
        }
        BtnBackupDelete = {
            $sel = Get-SelectedBackup
            if (-not $sel) { return }
            if (-not (Confirm-Action ('Sicherung vom {0} endgültig löschen?' -f $sel.Created))) { return }
            Remove-Item -LiteralPath $sel.Path -Force
            $reg = [IO.Path]::ChangeExtension($sel.Path, '.reg')
            if (Test-Path -LiteralPath $reg) { Remove-Item -LiteralPath $reg -Force }
            Write-Log ('SICHERUNG GELÖSCHT {0}' -f $sel.File)
            Update-BackupList
            Set-Status 'Sicherung gelöscht.'
        }
        BtnBackupFolder = { Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList ('"{0}"' -f $script:BackupDir) }
        BtnLogReload    = { Update-LogFiles }
        BtnLogFolder    = { Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList ('"{0}"' -f $script:LogDir) }
    }
    $clickHandler = [Windows.RoutedEventHandler]{
        param($s, $e)
        $action = $script:ClickActions[$s.Name]
        if ($action) { Invoke-Guarded $action }
    }
    foreach ($name in $script:ClickActions.Keys) { $ui[$name].add_Click($clickHandler) }

    $ui.CmbLogFiles.add_SelectionChanged({
        if ($script:LogLoading) { return }
        $item = $script:UI.CmbLogFiles.SelectedItem
        if ($item) { Invoke-Guarded { Show-LogFile $item.Tag } }
    })

    $window.add_ContentRendered({ Invoke-Guarded { Update-EntryList } })
    $window.add_Closed({ Write-Log 'Programm beendet.' })

    $rights = if ($script:IsAdmin) { 'Administrator' } else { 'Standardbenutzer' }
    Write-Log ('Programm gestartet (Version {0}, {1}\{2}, {3}, Daten: {4})' -f $script:AppVersion, $env:USERDOMAIN, $env:USERNAME, $rights, $script:DataDir)

    [void]$window.ShowDialog()
}
catch {
    $msg = $_.Exception.Message
    try { Write-Log ('Abbruch: {0}' -f $msg) 'FEHLER' } catch { }
    [void][Windows.MessageBox]::Show("Der Autostart-Manager konnte nicht gestartet werden:`n`n$msg", 'Autostart-Manager', 'OK', 'Error')
}

#endregion
