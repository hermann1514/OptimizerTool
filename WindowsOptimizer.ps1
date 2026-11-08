#requires -Version 5.1
<#
.SYNOPSIS
    Windows-Optimizer – Autostart-Programme und Windows-Dienste anzeigen und einzeln abschalten,
    dazu Systeminformationen, Sicherung/Wiederherstellung und Protokoll.

.DESCRIPTION
    Portabel, keine Installation: nutzt nur PowerShell 5.1 und WPF, beides ist in Windows enthalten.
    Deaktivieren von Autostart-Einträgen: Der Eintrag wird in einen Ablagebereich verschoben
    (Unterschlüssel bzw. Unterordner "WindowsOptimizerDisabled"), den Windows nicht ausführt.
    Einschalten schreibt ihn unverändert zurück. Nichts wird endgültig gelöscht.

    Start: Start-WindowsOptimizer.cmd (Doppelklick)
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:AppName      = 'Windows-Optimizer'
$script:AppVersion   = '1.6.2'
$script:StoreName    = 'WindowsOptimizerDisabled'   # Ablage für deaktivierte Autostart-Einträge
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
$script:ServicesLoaded = $false
$script:SvcFilter    = 'all'
$script:SvcSearch    = ''
$script:OptLoaded    = $false
$script:OptFilter    = 'applicable'
$script:CitrixEnv    = $null
$script:OptTaskCache = $null
$script:OptCacheDrive   = $null    # $null = noch nicht gewählt, '' = bewusst kein Cache-Laufwerk
$script:OptDriveLoading = $false
$script:SmLoaded     = $false
$script:SmFilter     = 'all'
$script:SmSearch     = ''
$script:SmLastGroups = ''
$script:SwLoaded     = $false
$script:SwFilter     = 'all'
$script:SwSearch     = ''
$script:SwResults    = @{}       # Id -> letzte Fehlermeldung (bleibt beim Neu-Prüfen erhalten)
$script:SwQueue      = $null     # laufende Aktualisierung
$script:WgJob        = $null     # laufender winget-Prozess
$script:WingetPath   = ''

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
        $dir = Join-Path $env:LOCALAPPDATA 'WindowsOptimizer'
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

function Get-StoreLocation($Source) {
    # Ablage für deaktivierte Einträge: Unterschlüssel des Run-Schlüssels bzw. Unterordner des Autostart-Ordners.
    # Windows wertet weder Unterschlüssel von Run noch Unterordner des Autostart-Ordners aus.
    if ($Source.Kind -eq 'Registry') { '{0}\{1}' -f $Source.Path, $script:StoreName }
    else { Join-Path $Source.Path $script:StoreName }
}

function Update-EntryDisplay($Entry) {
    $Entry.Enabled     = (-not $Entry.InStore) -and (-not $Entry.ApprovedOff)
    $Entry.StatusText  = if ($Entry.Enabled) { 'Aktiv' } else { 'Deaktiviert' }
    $Entry.ApprovedText = if ($Entry.ApprovedOff) { 'nur Task-Manager-Sperre' } else { '' }
    $Entry.SwitchTip   = if (-not $Entry.CanModify) { 'Nur mit Administratorrechten änderbar' }
                         elseif ($Entry.ApprovedOff) { 'Nur per Task-Manager gesperrt – startet evtl. trotzdem. Klicken zum Aktivieren; endgültig abschalten über den Hinweis oben.' }
                         elseif ($Entry.Enabled) { 'Klicken zum Deaktivieren' }
                         else { 'Klicken zum Aktivieren' }
    $nl = [Environment]::NewLine
    $Entry.LocationTip = if ($Entry.InStore) {
                             'Deaktiviert – verschoben nach:{0}{1}{0}Windows führt Einträge in diesem Ablagebereich nicht aus.' -f $nl, $Entry.Location
                         } elseif ($Entry.ApprovedOff) {
                             'Eintrag: {1}{0}Nur per Task-Manager gesperrt ({2}\{3}\{4}) – wirkt nicht bei allen Programmen.' -f $nl, $Entry.Location, $Entry.Hive, $script:ApprovedPath, $Entry.ApprovedSub
                         } else {
                             'Eintrag: {0}' -f $Entry.Location
                         }
}

function New-AutostartEntry {
    param(
        $Source, [string]$ValueName, [string]$Name, [string]$Command, [string]$ExePath, [string]$Location,
        [string]$ValueKind = '', [string]$LnkTarget = '', [string]$LnkArgs = '', [string]$LnkWorkDir = '',
        [bool]$InStore = $false
    )
    # Alte Sperre über StartupApproved (Task-Manager) nur bei Einträgen, die noch aktiv eingetragen sind
    $approvedOff = (-not $InStore) -and -not (Test-ApprovedEnabled (Get-ApprovedBytes $Source.Hive $Source.Approved $ValueName))
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
        InStore       = $InStore
        ApprovedOff   = $approvedOff
        Enabled       = $false
        CanModify     = (($Source.Hive -eq 'HKCU') -or $script:IsAdmin)
        StatusText    = ''
        ApprovedText  = ''
        SwitchTip     = ''
        LocationTip   = ''
    }
    Update-EntryDisplay $entry
    $entry
}

function Read-RunEntries($Source, [string]$KeyPath, [bool]$InStore) {
    $base = Open-BaseKey $Source.Hive
    try {
        $key = $base.OpenSubKey($KeyPath)
        if (-not $key) { return }
        try {
            foreach ($vn in $key.GetValueNames()) {
                if ([string]::IsNullOrEmpty($vn)) { continue }
                $kind = $key.GetValueKind($vn)
                if ($kind -ne 'String' -and $kind -ne 'ExpandString') { continue }
                $raw = [string]$key.GetValue($vn, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                New-AutostartEntry -Source $Source -ValueName $vn -Name $vn -Command $raw -ExePath (Resolve-ExePath $raw) `
                    -Location ('{0}\{1}' -f $Source.Hive, $KeyPath) -ValueKind $kind.ToString() -InStore $InStore
            }
        } finally { $key.Close() }
    } finally { $base.Close() }
}

function Read-FolderEntries($Source, [string]$Folder, [bool]$InStore) {
    if (-not $Folder -or -not [IO.Directory]::Exists($Folder)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -Force)) {
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
        New-AutostartEntry -Source $Source -ValueName $f.Name -Name $f.BaseName -Command $cmd `
            -ExePath $exe -Location $f.FullName -LnkTarget $t -LnkArgs $a -LnkWorkDir $w -InStore $InStore
    }
}

function Get-AutostartEntries {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($src in $script:Sources) {
        try {
            if ($src.Kind -eq 'Registry') {
                $active = @(Read-RunEntries $src $src.Path $false)
                $stored = @(Read-RunEntries $src (Get-StoreLocation $src) $true)
            } else {
                if (-not $src.Path) { continue }
                $active = @(Read-FolderEntries $src $src.Path $false)
                $stored = @(Read-FolderEntries $src (Get-StoreLocation $src) $true)
            }
            foreach ($e in $active) { $list.Add($e) }
            # Hat sich ein Programm selbst neu eingetragen, gilt der aktive Eintrag; die alte Ablagekopie wird ausgeblendet
            $activeIds = @($active | ForEach-Object { $_.Id })
            foreach ($e in $stored) { if ($activeIds -notcontains $e.Id) { $list.Add($e) } }
        } catch {
            Write-Log ('Quelle "{0}" konnte nicht gelesen werden: {1}' -f $src.Label, $_.Exception.Message) 'WARN'
        }
    }
    return @($list | Sort-Object Name)
}

function Move-RunValue([string]$Hive, [string]$Path, [string]$ValueName, [bool]$ToStore) {
    # Verschiebt einen Run-Wert unverändert (Typ und Rohtext) zwischen Run und Ablage.
    # Rückgabe $true: Ziel existierte bereits beim Zurückschreiben (Programm hat sich neu eingetragen).
    $store = '{0}\{1}' -f $Path, $script:StoreName
    $from  = if ($ToStore) { $Path } else { $store }
    $to    = if ($ToStore) { $store } else { $Path }
    $base  = Open-BaseKey $Hive
    try {
        $src = $base.OpenSubKey($from, $true)
        if ($null -eq $src -or $src.GetValueNames() -notcontains $ValueName) { throw ('Eintrag „{0}“ wurde unter {1}\{2} nicht gefunden.' -f $ValueName, $Hive, $from) }
        try {
            $kind = $src.GetValueKind($ValueName)
            $data = $src.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $dst  = $base.CreateSubKey($to)
            try {
                $conflict = (-not $ToStore) -and ($dst.GetValueNames() -contains $ValueName)
                if (-not $conflict) { $dst.SetValue($ValueName, $data, $kind) }   # erst schreiben …
            } finally { $dst.Close() }
            $src.DeleteValue($ValueName)                                          # … dann löschen
            return $conflict
        } finally { $src.Close() }
    } finally { $base.Close() }
}

function Move-StartupFile([string]$Folder, [string]$FileName, [bool]$ToStore) {
    $store = Join-Path $Folder $script:StoreName
    $from  = if ($ToStore) { Join-Path $Folder $FileName } else { Join-Path $store $FileName }
    $to    = if ($ToStore) { Join-Path $store $FileName } else { Join-Path $Folder $FileName }
    if (-not [IO.File]::Exists($from)) { throw ('Datei „{0}“ wurde nicht gefunden.' -f $from) }
    if (-not [IO.Directory]::Exists((Split-Path -Parent $to))) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $to)) }
    if ([IO.File]::Exists($to)) {
        if ($ToStore) { [IO.File]::Delete($to) }                  # veraltete Ablagekopie ersetzen
        else { [IO.File]::Delete($from); return $true }          # aktiver Eintrag existiert bereits: er gewinnt
    }
    [IO.File]::Move($from, $to)
    return $false
}

function Set-EntryState($Entry, [bool]$Enabled) {
    if (-not $Entry.CanModify) { throw 'Für Einträge aller Benutzer sind Administratorrechte nötig.' }
    $src = $script:Sources | Where-Object { $_.Id -eq $Entry.SourceId } | Select-Object -First 1
    $conflict = $false
    if ($Enabled) {
        if ($Entry.InStore) {
            $conflict = if ($src.Kind -eq 'Registry') { Move-RunValue $src.Hive $src.Path $Entry.ValueName $false }
                        else { Move-StartupFile $src.Path $Entry.ValueName $false }
        }
        # Eine alte Task-Manager-Sperre würde den Eintrag sonst weiter blockieren
        if (-not (Test-ApprovedEnabled (Get-ApprovedBytes $src.Hive $src.Approved $Entry.ValueName))) {
            Set-ApprovedState $src.Hive $src.Approved $Entry.ValueName $true
        }
        $Entry.Location = if ($src.Kind -eq 'Registry') { '{0}\{1}' -f $src.Hive, $src.Path } else { Join-Path $src.Path $Entry.ValueName }
    } elseif (-not $Entry.InStore) {
        [void]$(if ($src.Kind -eq 'Registry') { Move-RunValue $src.Hive $src.Path $Entry.ValueName $true }
                else { Move-StartupFile $src.Path $Entry.ValueName $true })
        $Entry.Location = if ($src.Kind -eq 'Registry') { '{0}\{1}' -f $src.Hive, (Get-StoreLocation $src) }
                          else { Join-Path (Get-StoreLocation $src) $Entry.ValueName }
    }
    $Entry.InStore     = -not $Enabled
    $Entry.ApprovedOff = $false
    Update-EntryDisplay $Entry
    $verb = if ($Enabled) { 'AKTIVIERT  ' } else { 'DEAKTIVIERT' }
    $how  = if ($Enabled) { 'zurückgeschrieben' } else { 'in Ablage verschoben' }
    Write-Log ('{0} {1}  [{2}, {3}]  {4}' -f $verb, $Entry.Name, $Entry.SourceLabel, $how, $Entry.Command)
    if ($conflict) { Write-Log ('"{0}" war bereits wieder aktiv eingetragen – Ablagekopie verworfen, vorhandener Eintrag bleibt.' -f $Entry.Name) 'WARN' }
}

#endregion

#region Dienste ----------------------------------------------------------------------------

$script:ServicesPath = 'SYSTEM\CurrentControlSet\Services'
$script:StartTypeText = [ordered]@{
    'auto' = 'Automatisch'; 'delayed-auto' = 'Automatisch (verzögert)'; 'demand' = 'Manuell'; 'disabled' = 'Deaktiviert'
    'boot' = 'Boot'; 'system' = 'System'
}

# Einschätzung für Citrix-Server-VDA / RDS-Hosts (Windows Server 2016–2025, Windows 10/11 Multi-Session).
# Exakte Namen zuerst, dann Platzhalter (-like). Benutzerdienste über den Vorlagennamen (ohne _xxxxx).
# Grundlage: Citrix Optimizer, Microsoft Windows Desktop Optimization Tool (WDOT), Microsoft-Leitfaden
# "Security guidelines for system services in Windows Server" (gilt für Server OHNE Desktop-Nutzung –
# für RDS-Hosts wird bewusst abweichend eingestuft). Keine verbindliche Vorgabe.
# Stufen: Benötigt | Belassen | Prüfen | Deaktivierbar  (Fallback: Drittanbieter / Belassen / Prüfen)
$script:RdsHints = @(
    # ---------- Benötigt: RDS / Citrix ----------
    ,@('TermService',          'Benötigt', 'Remotedesktopdienste – Grundlage aller RDS-/ICA-Sitzungen.')
    ,@('SessionEnv',           'Benötigt', 'Konfiguration der Remotedesktopsitzungen.')
    ,@('UmRdpService',         'Benötigt', 'Geräteumleitung (Drucker, Laufwerke, Ports) in Remotesitzungen.')
    ,@('Tssdis',               'Benötigt', 'RD-Verbindungsbroker – nötig, wenn diese Rolle auf dem Server läuft.')
    ,@('TermServLicensing',    'Benötigt', 'RD-Lizenzierung – nötig, wenn dieser Server Lizenzserver ist.')
    ,@('BrokerAgent',          'Benötigt', 'Citrix Desktop Service – registriert den VDA am Delivery Controller.')
    ,@('picaSvc2',             'Benötigt', 'Citrix ICA-Dienst – HDX-Sitzungen.')
    ,@('ctxProfile',           'Benötigt', 'Citrix Profile Management.')
    ,@('cpsvc',                'Benötigt', 'Citrix Druck-Manager – Druckerzuordnung in Sitzungen.')
    ,@('CitrixTelemetryService', 'Prüfen', 'Citrix Telemetrie/Call Home (Citrix Scout) – deaktivierbar, wenn nicht genutzt.')
    ,@('CWAUpdaterService',    'Prüfen', 'Updater der Citrix Workspace-App – auf VDA/Images meist deaktiviert.')
    ,@('Ctx*',                 'Benötigt', 'Citrix-Komponente – auf einem VDA nicht deaktivieren.')
    ,@('Citrix*',              'Benötigt', 'Citrix-Komponente – auf einem VDA nicht deaktivieren.')
    ,@('Norskale*',            'Benötigt', 'Citrix Workspace Environment Management (WEM) Agent.')
    ,@('VMTools',              'Benötigt', 'VMware Tools – auf VMware-VMs benötigt.')
    ,@('VGAuthService',        'Benötigt', 'VMware Alias Manager – Teil der VMware Tools.')
    ,@('vmvss',                'Prüfen', 'VMware Snapshot Provider – nötig für anwendungskonsistente Backups über VMware.')
    ,@('xen*',                 'Benötigt', 'XenServer-/Citrix-Hypervisor-Gasttools.')
    ,@('vmic*',                'Prüfen', 'Hyper-V-Integrationsdienst – auf Hyper-V/Azure benötigt, sonst wirkungslos (MS: nicht deaktivieren).')
    ,@('HvHost',               'Prüfen', 'Hyper-V-Hostdienst – nur auf Hyper-V relevant (MS: nicht deaktivieren).')

    # ---------- Benötigt: Windows-Kern, Anmeldung, Shell ----------
    ,@('RpcSs',                'Benötigt', 'RPC – Kernkomponente von Windows.')
    ,@('RpcEptMapper',         'Benötigt', 'RPC-Endpunktzuordnung – Kernkomponente.')
    ,@('DcomLaunch',           'Benötigt', 'DCOM-Server-Prozessstart – Kernkomponente.')
    ,@('LSM',                  'Benötigt', 'Lokaler Sitzungs-Manager – verwaltet alle Benutzersitzungen.')
    ,@('PlugPlay',             'Benötigt', 'Plug & Play – auch für umgeleitete Geräte und Drucker nötig.')
    ,@('Power',                'Benötigt', 'Energieverwaltung – Kernkomponente.')
    ,@('ProfSvc',              'Benötigt', 'Benutzerprofildienst – ohne ihn keine Anmeldung.')
    ,@('UserManager',          'Benötigt', 'Benutzer-Manager – nötig für Anmeldung und Startmenü.')
    ,@('gpsvc',                'Benötigt', 'Gruppenrichtlinien.')
    ,@('SamSs',                'Benötigt', 'Sicherheitskontenverwaltung (MS: nicht deaktivieren).')
    ,@('KeyIso',               'Benötigt', 'CNG-Schlüsselisolation – Anmeldung, Zertifikate.')
    ,@('VaultSvc',             'Benötigt', 'Anmeldeinformationsverwaltung – gespeicherte Kennwörter für Office, Outlook, Teams.')
    ,@('TokenBroker',          'Benötigt', 'Web-Konto-Manager – Single Sign-On für Microsoft 365/Teams/OneDrive.')
    ,@('CryptSvc',             'Benötigt', 'Kryptografiedienste (Zertifikate, Signaturen).')
    ,@('Appinfo',              'Benötigt', 'Anwendungsinformationen – nötig für Rechteerhöhung (UAC).')
    ,@('SENS',                 'Benötigt', 'Systemereignisbenachrichtigung – An-/Abmeldeereignisse (Citrix nutzt diese).')
    ,@('EventSystem',          'Benötigt', 'COM+-Ereignissystem – Grundlage für SENS.')
    ,@('EventLog',             'Benötigt', 'Ereignisprotokoll.')
    ,@('Winmgmt',              'Benötigt', 'WMI – von Citrix Director, VDA und Monitoring genutzt.')
    ,@('WinRM',                'Benötigt', 'Windows-Remoteverwaltung – von Citrix Director/Studio genutzt (MS: nicht deaktivieren).')
    ,@('Schedule',             'Benötigt', 'Aufgabenplanung – auch von Citrix- und Windows-Komponenten genutzt.')
    ,@('BrokerInfrastructure', 'Benötigt', 'Infrastruktur für Hintergrundaufgaben – Kernkomponente.')
    ,@('SystemEventsBroker',   'Benötigt', 'Systemereignisbroker – nötig für Aufgabenplanung (MS: nicht deaktivieren).')
    ,@('TimeBrokerSvc',        'Benötigt', 'Zeitbroker – nötig für Aufgabenplanung (MS: nicht deaktivieren).')
    ,@('CoreMessagingRegistrar', 'Benötigt', 'CoreMessaging – Kommunikation der Shell-Komponenten.')
    ,@('StateRepository',      'Benötigt', 'StateRepository – Startmenü und Apps hängen davon ab.')
    ,@('tiledatamodelsvc',     'Benötigt', 'Kachel-Datenmodell – ohne ihn funktioniert das Startmenü nicht (MS: nicht deaktivieren).')
    ,@('AppReadiness',         'Benötigt', 'App-Vorbereitung bei der ersten Anmeldung (MS: nicht deaktivieren).')
    ,@('AppXSvc',              'Benötigt', 'AppX-Bereitstellung – Startmenü, Suche, Teams (neu) und andere MSIX-Apps bei Anmeldung.')
    ,@('ClipSVC',              'Benötigt', 'Clientlizenzdienst – Lizenzprüfung von Store-/MSIX-Apps.')
    ,@('UdkUserSvc',           'Benötigt', 'Shell-Benutzerdienst (Windows 11/Server 2025) – Startmenü/Taskleiste.')
    ,@('TextInputManagementService', 'Benötigt', 'Texteingabe (Startmenü, Suche, moderne Apps).')
    ,@('Themes',               'Benötigt', 'Designs – Darstellung und Barrierefreiheits-Kontrast in Sitzungen (MS: nicht deaktivieren).')
    ,@('FontCache',            'Benötigt', 'Schriftartencache – beschleunigt Anwendungsstarts in vielen Sitzungen.')
    ,@('DispBrokerDesktopSvc', 'Benötigt', 'Anzeigerichtlinien – Auflösung/Skalierung in Sitzungen.')
    ,@('camsvc',               'Benötigt', 'Funktionszugriffs-Manager – App-Berechtigungen für Mikrofon/Kamera (Teams).')
    ,@('Audiosrv',             'Benötigt', 'Windows-Audio – nötig für HDX-Audioumleitung (MS: deaktivierbar nur ohne Desktop-Nutzung).')
    ,@('AudioEndpointBuilder', 'Benötigt', 'Audio-Endpunkte – nötig für HDX-Audioumleitung.')
    ,@('Spooler',              'Benötigt', 'Druckwarteschlange – nötig für Druckerumleitung und Citrix Universal Print.')
    ,@('PrintNotify',          'Benötigt', 'Druckererweiterungen und -benachrichtigungen.')
    ,@('DeviceInstall',        'Benötigt', 'Geräteinstallation – Treiber für umgeleitete Drucker/Geräte.')
    ,@('DsmSvc',               'Benötigt', 'Geräteinstallations-Manager – Treiber für umgeleitete Geräte.')
    ,@('msiserver',            'Benötigt', 'Windows Installer – Softwareinstallation/-reparatur.')
    ,@('TrustedInstaller',     'Benötigt', 'Windows-Modulinstaller – Updates und Windows-Features.')
    ,@('sppsvc',               'Benötigt', 'Softwareschutz – Windows-/Office-Aktivierung (KMS).')
    ,@('ClickToRunSvc',        'Benötigt', 'Office Click-to-Run – ohne ihn starten Office-Programme nicht.')

    # ---------- Benötigt: Netzwerk, Domäne, Sicherheit ----------
    ,@('Netlogon',             'Benötigt', 'Domänenanmeldung und Vertrauensstellung.')
    ,@('LanmanWorkstation',    'Benötigt', 'Zugriff auf Netzwerkfreigaben (Profile, Basisordner).')
    ,@('LanmanServer',         'Benötigt', 'Server/Freigaben – nötig für Verwaltung, IPC$ und Citrix (MS: nicht deaktivieren).')
    ,@('Dnscache',             'Benötigt', 'DNS-Client.')
    ,@('Dhcp',                 'Benötigt', 'DHCP-Client.')
    ,@('nsi',                  'Benötigt', 'Netzwerkspeicherschnittstelle.')
    ,@('NlaSvc',               'Benötigt', 'Netzwerkerkennung – steuert u. a. Firewall-Profile.')
    ,@('netprofm',             'Benötigt', 'Netzwerklistendienst.')
    ,@('Wcmsvc',               'Benötigt', 'Windows-Verbindungs-Manager.')
    ,@('WinHttpAutoProxySvc',  'Benötigt', 'Proxy-Erkennung (WPAD/PAC) – viele Anwendungen hängen davon ab (MS: nicht deaktivieren).')
    ,@('W32Time',              'Benötigt', 'Zeitsynchronisierung – wichtig für Kerberos.')
    ,@('BFE',                  'Benötigt', 'Basisfiltermodul – Grundlage der Windows-Firewall.')
    ,@('mpssvc',               'Benötigt', 'Windows-Firewall.')

    # ---------- Prüfen ----------
    ,@('WSearch',              'Prüfen', 'Windows-Suche – nötig für Outlook- und Startmenüsuche; hoher Ressourcenbedarf, ab Server 2019 Index pro Benutzer.')
    ,@('wuauserv',             'Prüfen', 'Windows Update – bei MCS/PVS nur im Master-Image nötig, auf persistenten Hosts benötigt.')
    ,@('UsoSvc',               'Prüfen', 'Update Orchestrator – wie Windows Update (MS: nicht deaktivieren).')
    ,@('WaaSMedicSvc',         'Prüfen', 'Windows Update Medic – repariert Update-Komponenten; geschützt, meist nicht änderbar.')
    ,@('DoSvc',                'Prüfen', 'Übermittlungsoptimierung – Peer-Verteilung von Updates; auf Images meist deaktiviert.')
    ,@('BITS',                 'Prüfen', 'Hintergrundübertragung – von Updates, SCCM/Intune und Software-Verteilung genutzt.')
    ,@('InstallService',       'Prüfen', 'Microsoft Store-Installation – deaktivierbar, wenn der Store gesperrt ist.')
    ,@('WinDefend',            'Prüfen', 'Microsoft Defender – nur deaktivieren, wenn ein anderer Virenschutz aktiv ist (geschützt).')
    ,@('WdNisSvc',             'Prüfen', 'Defender-Netzwerkinspektion – gehört zu Defender.')
    ,@('MDCoreSvc',            'Prüfen', 'Defender-Kerndienst – gehört zu Defender.')
    ,@('Sense',                'Prüfen', 'Defender for Endpoint (EDR) – nötig, wenn MDE lizenziert/eingesetzt.')
    ,@('SecurityHealthService','Prüfen', 'Windows-Sicherheit – gehört zu Defender.')
    ,@('wscsvc',               'Prüfen', 'Sicherheitscenter – überwacht Virenschutz/Firewall-Status.')
    ,@('webthreatdefsvc',      'Prüfen', 'Web Threat Defense (SmartScreen-Phishingschutz).')
    ,@('webthreatdefusersvc',  'Prüfen', 'Web Threat Defense, Benutzerdienst (SmartScreen-Phishingschutz).')
    ,@('AppIDSvc',             'Prüfen', 'Anwendungsidentität – zwingend nötig, wenn AppLocker eingesetzt wird.')
    ,@('AppVClient',           'Prüfen', 'App-V-Client – nur nötig, wenn App-V-Pakete genutzt werden.')
    ,@('UevAgentService',      'Prüfen', 'User Experience Virtualization – mit Citrix Profile Management meist ungenutzt.')
    ,@('RemoteRegistry',       'Prüfen', 'Remoteregistrierung – von Monitoring-/Verwaltungswerkzeugen genutzt (MS: nicht deaktivieren).')
    ,@('iphlpsvc',             'Prüfen', 'IP-Hilfsdienst (IPv6-Übergangstechniken) – meist nicht benötigt.')
    ,@('IKEEXT',               'Prüfen', 'IPsec-Schlüsselerstellung – nötig bei IPsec/Domänenisolierung oder Always-On-VPN.')
    ,@('PolicyAgent',          'Prüfen', 'IPsec-Richtlinien-Agent – nötig bei IPsec/Domänenisolierung.')
    ,@('RasMan',               'Prüfen', 'RAS-Verbindungsverwaltung – von manchen VPN-Clients benötigt.')
    ,@('defragsvc',            'Prüfen', 'Laufwerksoptimierung – auf nicht-persistenten Images (MCS/PVS) deaktivierbar.')
    ,@('VSS',                  'Prüfen', 'Volumeschattenkopie – auf nicht-persistenten Hosts deaktivierbar, für Backups nötig.')
    ,@('swprv',                'Prüfen', 'Softwareschattenkopie-Anbieter – wie Volumeschattenkopie.')
    ,@('wbengine',             'Prüfen', 'Blockebenen-Sicherung (Windows Server-Sicherung) – nur bei deren Nutzung nötig.')
    ,@('WerSvc',               'Prüfen', 'Windows-Fehlerberichterstattung – oft deaktiviert, hilft aber bei Absturzanalysen (MS: nicht deaktivieren).')
    ,@('DPS',                  'Prüfen', 'Diagnoserichtliniendienst – häufig deaktiviert (Citrix Optimizer), liefert Problemdiagnosen.')
    ,@('WdiServiceHost',       'Prüfen', 'Diagnosediensthost – häufig deaktiviert.')
    ,@('WdiSystemHost',        'Prüfen', 'Diagnosesystemhost – häufig deaktiviert (WDOT).')
    ,@('TabletInputService',   'Prüfen', 'Bildschirmtastatur/Handschrift – für Touch-Clients nötig; auf Server 2019/2022 teils Ursache für Eingabeverzögerung.')
    ,@('PenService',           'Prüfen', 'Stifteingabe – nur für Stift-/Touch-Clients nötig.')
    ,@('WbioSrvc',             'Prüfen', 'Biometrie – nur bei Windows Hello/Fingerabdruck-Umleitung nötig.')
    ,@('SCardSvr',             'Prüfen', 'Smartcard – nötig für Smartcard-Anmeldung und -Umleitung.')
    ,@('ScDeviceEnum',         'Prüfen', 'Smartcard-Geräteaufzählung – für Smartcard-Umleitung.')
    ,@('SCPolicySvc',          'Prüfen', 'Smartcard-Entfernungsrichtlinie – nötig, wenn Sperren bei Kartenentnahme gewünscht.')
    ,@('CertPropSvc',          'Prüfen', 'Zertifikatverteilung – für Smartcards nötig.')
    ,@('FrameServer',          'Prüfen', 'Kameradienst – für HDX-Webcam-Umleitung (Teams/Videokonferenz) nötig.')
    ,@('FrameServerMonitor',   'Prüfen', 'Kamera-Überwachung – gehört zum Kameradienst.')
    ,@('stisvc',               'Prüfen', 'Windows-Bilderfassung – für Scanner-Umleitung (TWAIN/WIA) nötig.')
    ,@('WiaRpc',               'Prüfen', 'Standbild-Ereignisse – gehört zur Scanner-Unterstützung.')
    ,@('WPDBusEnum',           'Prüfen', 'Tragbare Geräte (MTP) – für Umleitung von Smartphones/Kameras.')
    ,@('TapiSrv',              'Prüfen', 'Telefonie – von Softphones/CTI genutzt (MS: nicht deaktivieren).')
    ,@('cbdhsvc',              'Prüfen', 'Zwischenablage-Benutzerdienst (Verlauf) – Deaktivieren kann Kopieren/Einfügen stören.')
    ,@('CaptureService',       'Prüfen', 'Bildschirmaufnahme – nötig für Snipping Tool/Screenshot-Apps.')
    ,@('WebClient',            'Prüfen', 'WebDAV – nötig für SharePoint-Explorer-Ansicht/WebDAV-Laufwerke.')
    ,@('wlidsvc',              'Prüfen', 'Microsoft-Konto-Anmeldung – für Office/Store teilweise nötig.')
    ,@('WpnService',           'Prüfen', 'Pushbenachrichtigungen – für Benachrichtigungen von Teams/Outlook.')
    ,@('WpnUserService',       'Prüfen', 'Pushbenachrichtigungen pro Benutzer – für Benachrichtigungen von Teams/Outlook.')
    ,@('MSDTC',                'Prüfen', 'Verteilte Transaktionen – von manchen Datenbank-/Branchenanwendungen benötigt.')
    ,@('PeerDistSvc',          'Prüfen', 'BranchCache – nur nötig, wenn BranchCache eingesetzt wird.')
    ,@('vmcompute',            'Prüfen', 'Hyper-V-Host-Computedienst – für Container/WSL2/Sandbox.')
    ,@('SNMP',                 'Prüfen', 'SNMP-Agent – nur bei SNMP-Monitoring nötig.')
    ,@('sshd',                 'Prüfen', 'OpenSSH-Server – nur nötig, wenn SSH-Zugriff gewünscht.')
    ,@('edgeupdate*',          'Prüfen', 'Edge-Update – auf Images meist deaktiviert, Aktualisierung im Master.')
    ,@('MicrosoftEdgeElevationService', 'Prüfen', 'Edge-Erhöhungsdienst – gehört zur Edge-Aktualisierung.')
    ,@('gupdate*',             'Prüfen', 'Google-Update – auf Images meist deaktiviert, Aktualisierung im Master.')
    ,@('GoogleChromeElevationService', 'Prüfen', 'Chrome-Erhöhungsdienst – gehört zur Chrome-Aktualisierung.')
    ,@('MozillaMaintenance',   'Prüfen', 'Firefox-Update – auf Images meist deaktiviert, Aktualisierung im Master.')

    # ---------- Deaktivierbar ----------
    ,@('DiagTrack',            'Deaktivierbar', 'Telemetrie (Benutzererfahrung und Telemetrie).')
    ,@('dmwappushservice',     'Deaktivierbar', 'WAP-Push für Telemetrie/MDM – nur bei Intune-Verwaltung behalten.')
    ,@('diagnosticshub.standardcollector.service', 'Deaktivierbar', 'Diagnose-Sammeldienst (Entwicklerwerkzeuge).')
    ,@('diagsvc',              'Deaktivierbar', 'Diagnoseausführung (WDOT).')
    ,@('wuqisvc',              'Deaktivierbar', 'Erkenntnisse zu Nutzung und Qualität (Telemetrie).')
    ,@('InventorySvc',         'Deaktivierbar', 'Inventur und Kompatibilitätsbewertung (Telemetrie/Upgrade-Bewertung).')
    ,@('PcaSvc',               'Deaktivierbar', 'Programmkompatibilitäts-Assistent.')
    ,@('TroubleshootingSvc',   'Deaktivierbar', 'Empfohlene Problembehandlung.')
    ,@('wercplsupport',        'Deaktivierbar', 'Problemberichte in der Systemsteuerung.')
    ,@('SysMain',              'Deaktivierbar', 'SysMain/Superfetch – bei vielen Sitzungen kaum Nutzen, erzeugt I/O (Citrix Optimizer, WDOT).')
    ,@('MapsBroker',           'Deaktivierbar', 'Offline-Karten.')
    ,@('lfsvc',                'Deaktivierbar', 'Geolocation – Standort kommt per Citrix-Standortumleitung, falls benötigt.')
    ,@('tzautoupdate',         'Deaktivierbar', 'Automatische Zeitzone – auf RDS kommt die Zeitzone per Zeitzonenumleitung.')
    ,@('autotimesvc',          'Deaktivierbar', 'Mobilfunkzeit.')
    ,@('Xbl*',                 'Deaktivierbar', 'Xbox-Dienst (MS: sollte deaktiviert werden).')
    ,@('XboxGipSvc',           'Deaktivierbar', 'Xbox-Zubehör.')
    ,@('XboxNetApiSvc',        'Deaktivierbar', 'Xbox-Netzwerk.')
    ,@('BcastDVRUserService',  'Deaktivierbar', 'Spieleaufzeichnung und Übertragung (GameDVR).')
    ,@('GameInputSvc',         'Deaktivierbar', 'Spiele-Eingabegeräte.')
    ,@('RetailDemo',           'Deaktivierbar', 'Einzelhandels-Demo.')
    ,@('WMPNetworkSvc',        'Deaktivierbar', 'Windows Media Player-Netzwerkfreigabe.')
    ,@('Fax',                  'Deaktivierbar', 'Fax – nur behalten, wenn tatsächlich gefaxt wird.')
    ,@('PhoneSvc',             'Deaktivierbar', 'Telefondienst (Smartphone-Verknüpfung).')
    ,@('SmsRouter',            'Deaktivierbar', 'SMS-Router.')
    ,@('MessagingService*',    'Deaktivierbar', 'SMS/Nachrichten-Synchronisierung.')
    ,@('icssvc',               'Deaktivierbar', 'Mobiler Hotspot.')
    ,@('SharedAccess',         'Deaktivierbar', 'Internetverbindungsfreigabe (ICS).')
    ,@('wisvc',                'Deaktivierbar', 'Windows-Insider-Programm.')
    ,@('WalletService',        'Deaktivierbar', 'Wallet/Zahlungen.')
    ,@('SEMgrSvc',             'Deaktivierbar', 'Zahlungen und NFC.')
    ,@('wlpasvc',              'Deaktivierbar', 'Assistent für lokale Profile (eSIM).')
    ,@('RmSvc',                'Deaktivierbar', 'Funkverwaltung/Flugzeugmodus.')
    ,@('WwanSvc',              'Deaktivierbar', 'Mobilfunk (WWAN).')
    ,@('WlanSvc',              'Deaktivierbar', 'WLAN – auf Servern/VMs nicht vorhanden.')
    ,@('WFDSConMgrSvc',        'Deaktivierbar', 'Wi-Fi Direct.')
    ,@('wcncsvc',              'Deaktivierbar', 'Windows-Sofortverbindung (WPS).')
    ,@('DusmSvc',              'Deaktivierbar', 'Datennutzung/getaktete Verbindungen (WDOT).')
    ,@('NcdAutoSetup',         'Deaktivierbar', 'Automatische Einrichtung von Netzwerkgeräten.')
    ,@('lltdsvc',              'Deaktivierbar', 'Netzwerkübersicht (LLTD).')
    ,@('NcbService',           'Deaktivierbar', 'Netzwerkverbindungsbroker (Store-Apps).')
    ,@('FDResPub',             'Deaktivierbar', 'Veröffentlichung im Netzwerk (Funktionssuche).')
    ,@('fdPHost',              'Deaktivierbar', 'Funktionssuchanbieter-Host.')
    ,@('SSDPSRV',              'Deaktivierbar', 'SSDP-Suche (UPnP).')
    ,@('upnphost',             'Deaktivierbar', 'UPnP-Gerätehost.')
    ,@('QWAVE',                'Deaktivierbar', 'Audio-/Video-Qualität im Heimnetz.')
    ,@('IpxlatCfgSvc',         'Deaktivierbar', 'IP-Übersetzung (Mobilfunk-IPv6).')
    ,@('p2psvc',               'Deaktivierbar', 'Peernetzwerk-Gruppierung.')
    ,@('p2pimsvc',             'Deaktivierbar', 'Peernetzwerk-Identitätsmanager.')
    ,@('PNRPsvc',              'Deaktivierbar', 'Peer Name Resolution Protocol.')
    ,@('PNRPAutoReg',          'Deaktivierbar', 'PNRP-Computernamenveröffentlichung.')
    ,@('Browser',              'Deaktivierbar', 'Computerbrowser (SMBv1-Altlast).')
    ,@('RpcLocator',           'Deaktivierbar', 'RPC-Locator (veraltet).')
    ,@('RasAuto',              'Deaktivierbar', 'Automatische RAS-Verbindung.')
    ,@('RemoteAccess',         'Deaktivierbar', 'Routing und RAS – nur auf VPN-/Routing-Servern nötig.')
    ,@('NetTcpPortSharing',    'Deaktivierbar', 'Net.Tcp-Portfreigabe (WCF).')
    ,@('SNMPTRAP',             'Deaktivierbar', 'SNMP-Trap – nur bei SNMP-Monitoring nötig.')
    ,@('AJRouter',             'Deaktivierbar', 'AllJoyn-Router (IoT).')
    ,@('ALG',                  'Deaktivierbar', 'Gatewaydienst auf Anwendungsebene (ICS).')
    ,@('irmon',                'Deaktivierbar', 'Infrarot.')
    ,@('bthserv',              'Deaktivierbar', 'Bluetooth – am Host nicht vorhanden; Geräte kommen per HDX-Umleitung.')
    ,@('BTAGService',          'Deaktivierbar', 'Bluetooth-Audio-Gateway.')
    ,@('BthAvctpSvc',          'Deaktivierbar', 'Bluetooth AVCTP.')
    ,@('BthHFSrv',             'Deaktivierbar', 'Bluetooth-Freisprechen.')
    ,@('BluetoothUserService', 'Deaktivierbar', 'Bluetooth-Benutzerdienst.')
    ,@('SensorService',        'Deaktivierbar', 'Sensoren – auf Servern/VMs nicht vorhanden.')
    ,@('SensrSvc',             'Deaktivierbar', 'Sensorüberwachung.')
    ,@('SensorDataService',    'Deaktivierbar', 'Sensordaten.')
    ,@('DisplayEnhancementService', 'Deaktivierbar', 'Helligkeitsregelung – auf VMs ohne Bildschirm wirkungslos.')
    ,@('GraphicsPerfSvc',      'Deaktivierbar', 'Grafikleistungsüberwachung.')
    ,@('midisrv',              'Deaktivierbar', 'MIDI-Dienst.')
    ,@('NPSMSvc',              'Deaktivierbar', 'Medienwiedergabe-Sitzungen (Overlay) – in Sitzungen ungenutzt.')
    ,@('TrkWks',               'Deaktivierbar', 'Überwachung verteilter Verknüpfungen (Citrix Optimizer).')
    ,@('CDPSvc',               'Deaktivierbar', 'Plattform für verbundene Geräte (Citrix Optimizer).')
    ,@('CDPUserSvc',           'Deaktivierbar', 'Plattform für verbundene Geräte, Benutzerdienst (MS: deaktivierbar).')
    ,@('DevicesFlowUserSvc',   'Deaktivierbar', 'Geräte-Kopplung (Bluetooth/Miracast).')
    ,@('OneSyncSvc',           'Deaktivierbar', 'Synchronisierung für Mail/Kalender/Kontakte-Apps – Outlook nicht betroffen (MS: deaktivierbar).')
    ,@('PimIndexMaintenanceSvc','Deaktivierbar', 'Kontaktdaten-Index für Windows-Apps (MS: deaktivierbar).')
    ,@('UnistoreSvc',          'Deaktivierbar', 'Benutzerdatenspeicher der Windows-Apps Mail/Kontakte (MS: deaktivierbar).')
    ,@('UserDataSvc',          'Deaktivierbar', 'Benutzerdatenzugriff der Windows-Apps (MS: deaktivierbar).')
    ,@('AarSvc',               'Deaktivierbar', 'Agent Activation Runtime (Sprachassistenten).')
    ,@('CloudBackupRestoreSvc','Deaktivierbar', 'Cloud-Sicherung von Windows-Einstellungen – auf RDS übernimmt das Profil-Management.')
    ,@('fhsvc',                'Deaktivierbar', 'Dateiversionsverlauf.')
    ,@('SDRSVC',               'Deaktivierbar', 'Windows-Sicherung (Client-Funktion).')
    ,@('workfolderssvc',       'Deaktivierbar', 'Arbeitsordner.')
    ,@('CscService',           'Deaktivierbar', 'Offlinedateien – auf RDS-Hosts nicht sinnvoll.')
    ,@('MSiSCSI',              'Belassen', 'iSCSI-Initiator – Deaktivieren bringt nichts (MS: nicht deaktivieren).')
    ,@('AxInstSV',             'Deaktivierbar', 'ActiveX-Installer (MS: deaktivierbar).')
    ,@('PushToInstall',        'Deaktivierbar', 'Store-Ferninstallation.')
    ,@('DmEnrollmentSvc',      'Deaktivierbar', 'Geräteverwaltungs-Registrierung – nur bei Intune/MDM nötig.')
    ,@('NaturalAuthentication','Deaktivierbar', 'Natürliche Authentifizierung (dynamische Sperre).')
    ,@('NgcSvc',               'Deaktivierbar', 'Microsoft Passport/Windows Hello – auf Server nicht unterstützt (MS: deaktivierbar).')
    ,@('NgcCtnrSvc',           'Deaktivierbar', 'Microsoft Passport-Container (MS: deaktivierbar).')
    ,@('shpamsvc',             'Deaktivierbar', 'Shared PC Account Manager.')
    ,@('AssignedAccessManagerSvc', 'Deaktivierbar', 'Zugewiesener Zugriff (Kiosk).')
    ,@('embeddedmode',         'Deaktivierbar', 'Eingebetteter Modus (IoT).')
    ,@('WpcMonSvc',            'Deaktivierbar', 'Jugendschutz.')
    ,@('ShellHWDetection',     'Deaktivierbar', 'Shellhardwareerkennung (AutoPlay) – in Sitzungen meist ungenutzt (MS: deaktivierbar).')
    ,@('P9RdrService',         'Deaktivierbar', 'Plan-9-Dateiumleitung (WSL).')
    ,@('LxssManager',          'Deaktivierbar', 'Windows-Subsystem für Linux.')
    ,@('perceptionsimulation', 'Deaktivierbar', 'Mixed-Reality-Simulation.')
    ,@('spectrum',             'Deaktivierbar', 'Windows Perception (Mixed Reality).')
    ,@('SharedRealitySvc',     'Deaktivierbar', 'Räumliche Daten (Mixed Reality).')
    ,@('MixedRealityOpenXRSvc','Deaktivierbar', 'Mixed Reality OpenXR.')

    # ---------- Belassen ----------
    ,@('Netman',               'Belassen', 'Netzwerkverbindungen (Netzwerk-Oberfläche).')
    ,@('NcaSvc',               'Belassen', 'Netzwerkkonnektivitäts-Assistent (DirectAccess).')
    ,@('NetSetupSvc',          'Belassen', 'Netzwerkeinrichtung.')
    ,@('lmhosts',              'Belassen', 'NetBIOS über TCP/IP – für ältere Freigaben/Anwendungen.')
    ,@('dot3svc',              'Belassen', 'Kabelgebundene Authentifizierung (802.1X).')
    ,@('EapHost',              'Belassen', 'EAP-Authentifizierung (802.1X/VPN).')
    ,@('SstpSvc',              'Belassen', 'SSTP-VPN (MS: nicht deaktivieren – RRAS hängt davon ab).')
    ,@('seclogon',             'Belassen', 'Sekundäre Anmeldung („Ausführen als“) – von Administratoren genutzt.')
    ,@('COMSysApp',            'Belassen', 'COM+-Systemanwendung – von Anwendungen genutzt.')
    ,@('KtmRm',                'Belassen', 'Transaktions-Manager für MSDTC.')
    ,@('EFS',                  'Belassen', 'Verschlüsselndes Dateisystem.')
    ,@('BDESVC',               'Belassen', 'BitLocker – auf VMs meist ungenutzt, Deaktivieren bringt kaum etwas.')
    ,@('AppMgmt',              'Belassen', 'Anwendungsverwaltung – Softwareverteilung per Gruppenrichtlinie.')
    ,@('LicenseManager',       'Belassen', 'Lizenz-Manager für Store-Apps.')
    ,@('EntAppSvc',            'Belassen', 'Verwaltung von Unternehmens-Apps.')
    ,@('DeviceAssociationService', 'Belassen', 'Gerätezuordnung.')
    ,@('DeviceAssociationBrokerSvc', 'Belassen', 'Gerätezuordnungsbroker.')
    ,@('DevicePickerUserSvc',  'Belassen', 'Geräteauswahl.')
    ,@('DevQueryBroker',       'Belassen', 'Geräteabfrage im Hintergrund.')
    ,@('hidserv',              'Belassen', 'Eingabegeräte – Sondertasten/Hotkeys.')
    ,@('PrintWorkflowUserSvc', 'Belassen', 'Druck-Workflow – Druckdialoge moderner Apps.')
    ,@('PrintScanBrokerService','Belassen', 'Druck-/Scan-Broker.')
    ,@('PrintDeviceConfigurationService', 'Belassen', 'Druckgerätekonfiguration.')
    ,@('ConsentUxUserSvc',     'Belassen', 'Zustimmungsdialoge (Geräte-Kopplung).')
    ,@('CredentialEnrollmentManagerUserSvc', 'Belassen', 'Anmeldeinformationen-Registrierung.')
    ,@('PerfHost',             'Belassen', 'Leistungsindikatoren-Host – von Monitoring (z. B. Citrix Director) genutzt.')
    ,@('pla',                  'Belassen', 'Leistungsprotokolle – von Monitoring/Diagnose genutzt.')
    ,@('wmiApSrv',             'Belassen', 'WMI-Leistungsadapter – von Monitoring genutzt.')
    ,@('Wecsvc',               'Belassen', 'Windows-Ereignissammlung (MS: nicht deaktivieren).')
    ,@('smphost',              'Belassen', 'Speicherplätze-Verwaltung (MS: nicht deaktivieren).')
    ,@('vds',                  'Belassen', 'Virtueller Datenträger – Datenträgerverwaltung.')
    ,@('svsvc',                'Belassen', 'Echtzeit-Datenträgerprüfung.')
    ,@('StorSvc',              'Belassen', 'Speicherdienst.')
    ,@('TieringEngineService', 'Belassen', 'Speicherebenen-Verwaltung.')
    ,@('refsdedupsvc',         'Belassen', 'ReFS-Deduplizierung.')
    ,@('wudfsvc',              'Belassen', 'Benutzermodus-Treiberframework.')
    ,@('WEPHOSTSVC',           'Belassen', 'Verschlüsselungsanbieter-Host.')
    ,@('SgrmBroker',           'Belassen', 'System Guard – Laufzeitüberwachung.')
    ,@('LxpSvc',               'Belassen', 'Sprachumgebung – wichtig bei mehrsprachigen RDS-Hosts.')
    ,@('DsSvc',                'Belassen', 'Datenfreigabe zwischen Apps.')
    ,@('DialogBlockingService','Belassen', 'Dialogblockierung (standardmäßig deaktiviert).')
    ,@('MsKeyboardFilter',     'Belassen', 'Tastaturfilter (standardmäßig deaktiviert).')
    ,@('ssh-agent',            'Belassen', 'OpenSSH-Agent (standardmäßig deaktiviert).')
    ,@('RSoPProv',             'Belassen', 'Richtlinienergebnissatz (gpresult).')
    ,@('sacsvr',               'Belassen', 'Spezielle Verwaltungskonsole (Notfallzugriff).')
    ,@('UALSVC',               'Belassen', 'Benutzerzugriffsprotokollierung (Server-Lizenzierungsberichte).')
    ,@('KPSSVC',               'Belassen', 'Kerberos-Proxy.')
    ,@('UI0Detect',            'Belassen', 'Erkennung interaktiver Dienste (veraltet).')
    ,@('TScPubRPC',            'Belassen', 'RemoteApp-Veröffentlichung (Connection Broker).')
    ,@('WManSvc',              'Belassen', 'Windows-Verwaltungsdienst (MDM-Richtlinien).')
    ,@('dcsvc',                'Belassen', 'Deklarierte Konfiguration (Verwaltung).')
    ,@('cloudidsvc',           'Belassen', 'Cloud-Identität (Entra ID).')
    ,@('LocalKdc',             'Belassen', 'Lokales Kerberos-KDC.')
    ,@('hpatchmon',            'Belassen', 'Hotpatch-Überwachung.')
    ,@('IsolationSession',     'Belassen', 'Isolierte Sitzungen (Sicherheitsfeature).')
    ,@('IsoSessionCore',       'Belassen', 'Isolierte Sitzungen, Kern (Sicherheitsfeature).')
    ,@('appprotectionsvc',     'Belassen', 'App-Schutz (Sicherheitsfeature).')
    ,@('ADPSvc',               'Belassen', 'Aggregierte Datenplattform (Shell-Komponente).')
    ,@('ApxSvc',               'Belassen', 'Virtuelle Audiogeräte (Proxy).')
    ,@('FileSyncHelper',       'Belassen', 'Dateisynchronisierungs-Hilfsdienst (OneDrive).')
    ,@('whesvc',               'Belassen', 'Windows-Integrität und optimierte Oberflächen.')
    ,@('McmSvc',               'Belassen', 'Windows-Komponente (Medien/Konnektivität).')
    ,@('McpManagementService', 'Belassen', 'Windows-Komponente (Verwaltung).')
    ,@('WSAIFabricSvc',        'Belassen', 'Windows-KI-Komponenten.')
    ,@('WarpJITSvc',           'Belassen', 'WARP-JIT (Software-Grafik).')
    ,@('PlutonQcService',      'Belassen', 'Pluton-Sicherheitsprozessor.')
)

# Vorauswahl auf der Seite „RDS-Optimierung“: nur Dienste, die auf einem RDS-Host sicher ungenutzt sind
# (fehlende VM-Hardware, reine Consumer-/Spiele-Funktionen). Schlüssel = Regelname aus $script:RdsHints.
# Alle anderen „Deaktivierbar“-Dienste erscheinen dort als „Prüfen“ (nicht vorausgewählt) mit Grund.
$script:RdsSafeServices = @(
    'Xbl*', 'XboxGipSvc', 'XboxNetApiSvc', 'BcastDVRUserService', 'GameInputSvc', 'RetailDemo', 'WMPNetworkSvc',
    'SmsRouter', 'MessagingService*', 'icssvc', 'wisvc', 'WalletService', 'SEMgrSvc', 'wlpasvc', 'RmSvc', 'WwanSvc',
    'WlanSvc', 'WFDSConMgrSvc', 'wcncsvc', 'NcdAutoSetup', 'lltdsvc', 'QWAVE', 'IpxlatCfgSvc', 'p2psvc', 'p2pimsvc',
    'PNRPsvc', 'PNRPAutoReg', 'Browser', 'RpcLocator', 'RasAuto', 'AJRouter', 'ALG', 'irmon',
    'bthserv', 'BTAGService', 'BthAvctpSvc', 'BthHFSrv', 'BluetoothUserService',
    'SensorService', 'SensrSvc', 'SensorDataService', 'DisplayEnhancementService', 'GraphicsPerfSvc', 'DevicesFlowUserSvc',
    'AarSvc', 'CloudBackupRestoreSvc', 'fhsvc', 'SDRSVC', 'CscService', 'PushToInstall', 'NaturalAuthentication',
    'shpamsvc', 'AssignedAccessManagerSvc', 'embeddedmode', 'WpcMonSvc',
    'perceptionsimulation', 'spectrum', 'SharedRealitySvc', 'MixedRealityOpenXRSvc',
    'MapsBroker', 'tzautoupdate', 'autotimesvc', 'diagsvc', 'wuqisvc', 'InventorySvc', 'TroubleshootingSvc', 'wercplsupport'
)
$script:RdsServiceCaution = @{
    'DiagTrack'          = 'Microsoft Defender for Endpoint, Endpoint Analytics und Windows Update for Business können ihn voraussetzen.'
    'dmwappushservice'   = 'Wird für die Intune-/MDM-Verwaltung benötigt.'
    'DmEnrollmentSvc'    = 'Wird für die Intune-/MDM-Verwaltung benötigt.'
    'diagnosticshub.standardcollector.service' = 'Profiler von Entwicklerwerkzeugen (Visual Studio).'
    'PcaSvc'             = 'Kompatibilitätshilfe für ältere Anwendungen.'
    'SysMain'            = 'Keine Frage der Nutzung, sondern der Leistung; bei PVS/MCS eigener Punkt.'
    'lfsvc'              = 'Standortdienste (Browser, Teams, Citrix-Standortumleitung).'
    'Fax'                = 'Faxdienst wird in manchen Umgebungen genutzt.'
    'PhoneSvc'           = 'Telefonie-Status für Telefon-Apps.'
    'SharedAccess'       = 'Wird auch für NAT von Hyper-V, WSL und Docker genutzt.'
    'DusmSvc'            = 'Abschalten kann Netzwerkstatus und Store-Verbindung stören.'
    'NcbService'         = 'Hintergrundaufgaben und Benachrichtigungen von Store-Apps.'
    'FDResPub'           = 'Netzwerkerkennung, u. a. für WSD-Drucker und -Scanner.'
    'fdPHost'            = 'Netzwerkerkennung, u. a. für WSD-Drucker und -Scanner.'
    'SSDPSRV'            = 'Netzwerkerkennung, u. a. für WSD-Drucker und -Scanner.'
    'upnphost'           = 'Netzwerkerkennung, u. a. für WSD-Drucker und -Scanner.'
    'RemoteAccess'       = 'VPN/Routing, falls auf dem Host genutzt.'
    'NetTcpPortSharing'  = 'Wird von WCF-Anwendungen genutzt.'
    'SNMPTRAP'           = 'SNMP-Überwachung.'
    'midisrv'            = 'Musik-/MIDI-Anwendungen.'
    'NPSMSvc'            = 'Medientasten und Lautstärke-Overlay.'
    'TrkWks'             = 'Repariert Verknüpfungen zu verschobenen Dateien auf Freigaben.'
    'CDPSvc'             = 'Zwischenablage-Verlauf, Benachrichtigungen, Freigabe in der Nähe.'
    'CDPUserSvc'         = 'Zwischenablage-Verlauf, Benachrichtigungen, Freigabe in der Nähe.'
    'OneSyncSvc'         = 'Windows-Apps Mail/Kalender/Kontakte und Kontaktsuche im Startmenü.'
    'PimIndexMaintenanceSvc' = 'Windows-Apps Mail/Kalender/Kontakte und Kontaktsuche im Startmenü.'
    'UnistoreSvc'        = 'Windows-Apps Mail/Kalender/Kontakte und Kontaktsuche im Startmenü.'
    'UserDataSvc'        = 'Windows-Apps Mail/Kalender/Kontakte und Kontaktsuche im Startmenü.'
    'workfolderssvc'     = 'Arbeitsordner (Unternehmens-Dateisynchronisierung).'
    'AxInstSV'           = 'ActiveX-Installation für Alt-Webanwendungen (IE-Modus), auf RDS-Hosts häufig.'
    'NgcSvc'             = 'Windows Hello for Business / FIDO, z. B. auf Windows 10/11 Multi-Session.'
    'NgcCtnrSvc'         = 'Windows Hello for Business / FIDO, z. B. auf Windows 10/11 Multi-Session.'
    'ShellHWDetection'   = 'AutoPlay und Geräteerkennung (Scanner, umgeleitete Laufwerke).'
    'P9RdrService'       = 'Wird vom Windows-Subsystem für Linux (WSL) genutzt.'
    'LxssManager'        = 'Windows-Subsystem für Linux (WSL).'
}

function Get-RdsHint([string]$Name, [string]$PathName = '', [string]$DisplayName = '') {
    foreach ($h in $script:RdsHints) { if ($h[0] -notmatch '\*' -and $Name -ieq $h[0]) { return $h } }
    foreach ($h in $script:RdsHints) { if ($h[0] -match '\*' -and $Name -like $h[0]) { return $h } }

    # Keine Regel: anhand von Programmdatei und Hersteller einordnen
    $exe = Resolve-ExePath $PathName
    $company = ''
    if ($exe -and [IO.File]::Exists($exe)) {
        try { $company = "$([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).CompanyName)".Trim() } catch { }
    }
    $inWindows = [bool]($exe -and $exe.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase))
    $isMs   = ($company -match 'Microsoft') -or (-not $company -and $inWindows)
    $vendor = if ($company) { $company } else { 'unbekanntem Hersteller' }
    $file   = if ($exe) { [IO.Path]::GetFileName($exe) } else { '–' }
    if ("$Name $DisplayName" -match 'update|updater|elevation|maintenance') {
        return @('', 'Prüfen', ('Update-/Wartungsdienst von {0} – auf RDS-Images meist deaktiviert, Aktualisierung im Master-Image. Auf persistenten Hosts Updates anderweitig sicherstellen.' -f $vendor))
    }
    if ($isMs) {
        return @('', 'Belassen', 'Windows-/Microsoft-Komponente ohne bekannte RDS-Optimierungsempfehlung – nicht ändern.')
    }
    return @('', 'Drittanbieter', ('Dienst von {0} ({1}) – gehört zu installierter Software. Behalten, wenn die Software auf dem RDS-Host genutzt wird; Hardware-Hilfsdienste (Audio, Grafik, Druckerhersteller-Tools, Treiber-Updater) sind auf VMs meist überflüssig.' -f $vendor, $file))
}

function Read-ServiceConfig([string]$Name) {
    # Starttyp direkt aus der Registry (zuverlässig inkl. "verzögert"), Type für Benutzerdienste
    $base = Open-BaseKey 'HKLM'
    try {
        $key = $base.OpenSubKey("$($script:ServicesPath)\$Name")
        if ($null -eq $key) { return $null }
        try {
            $start   = [int]$key.GetValue('Start', 3)
            $type    = [int]$key.GetValue('Type', 0)
            $delayed = [int]$key.GetValue('DelayedAutostart', 0)
        } finally { $key.Close() }
    } finally { $base.Close() }
    $code = switch ($start) { 0 { 'boot' } 1 { 'system' } 2 { if ($delayed -eq 1) { 'delayed-auto' } else { 'auto' } } 4 { 'disabled' } default { 'demand' } }
    [pscustomobject]@{ StartType = $code; Type = $type }
}

function Update-ServiceDisplay($Svc) {
    $Svc.StartTypeText = $script:StartTypeText[$Svc.StartType]
    $Svc.StatusText    = $Svc.StartTypeText   # graut deaktivierte Zeilen aus (gemeinsamer Zeilenstil)
    $Svc.SwitchTip     = if ($Svc.IsInstance) { 'Benutzerdienst-Instanz – Starttyp wird über die Vorlage „{0}“ gesteuert' -f $Svc.Template }
                         elseif ($Svc.StartType -in 'boot', 'system') { 'Systemstart-Dienst – hier nicht änderbar' }
                         elseif (-not $script:IsAdmin) { 'Nur mit Administratorrechten änderbar' }
                         elseif ($Svc.IsTemplate) { 'Vorlage für Benutzerdienste – Änderung wirkt nach Neustart' }
                         else { 'Starttyp wählen' }
}

function Get-ServiceEntries {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($w in @(Get-CimSafe 'Win32_Service')) {
        $cfg = Read-ServiceConfig $w.Name
        if (-not $cfg) { continue }
        # 0x40 = Benutzerdienst (Vorlage), 0x80 = Instanz einer Vorlage (Name_xxxxx)
        $isInstance = (($cfg.Type -band 0x80) -ne 0)
        $isTemplate = (($cfg.Type -band 0x40) -ne 0) -and -not $isInstance
        $template   = if ($isInstance) { $w.Name -replace '_[0-9a-fA-F]+$', '' } else { '' }
        $hint = Get-RdsHint $(if ($isInstance) { $template } else { $w.Name }) "$($w.PathName)" "$($w.DisplayName)"
        $svc = [pscustomobject]@{
            Name          = "$($w.Name)"
            DisplayName   = if ($w.DisplayName) { "$($w.DisplayName)" } else { "$($w.Name)" }
            Description   = "$($w.Description)"
            PathName      = "$($w.PathName)"
            StartName     = "$($w.StartName)"
            StateText     = switch ("$($w.State)") { 'Running' { 'Läuft' } 'Stopped' { 'Beendet' } 'Paused' { 'Angehalten' } default { "$($w.State)" } }
            StartType     = $cfg.StartType
            IsInstance    = $isInstance
            IsTemplate    = $isTemplate
            Template      = $template
            CanModify     = $script:IsAdmin -and -not $isInstance -and ($cfg.StartType -notin 'boot', 'system')
            RdsRating     = $hint[1]
            RdsText       = $hint[2]
            StartTypeText = ''
            StatusText    = ''
            SwitchTip     = ''
        }
        Update-ServiceDisplay $svc
        $list.Add($svc)
    }
    return @($list | Sort-Object DisplayName)
}

function Set-ServiceStartType($Svc, [string]$Code) {
    if ($Code -notin 'auto', 'delayed-auto', 'demand', 'disabled') { throw ('Unbekannter Starttyp: {0}' -f $Code) }
    if ($Svc.IsInstance) { throw ('Der Starttyp von „{0}“ wird über die Vorlage „{1}“ gesteuert.' -f $Svc.Name, $Svc.Template) }
    if (-not $script:IsAdmin) { throw 'Zum Ändern von Diensten sind Administratorrechte nötig.' }
    $old = $Svc.StartType

    if ($Svc.IsTemplate) {
        # Vorlagen für Benutzerdienste lehnt sc.exe ab (Fehler 87) – daher direkt in der Registry
        $base = Open-BaseKey 'HKLM'
        try {
            $key = $base.OpenSubKey("$($script:ServicesPath)\$($Svc.Name)", $true)
            if ($null -eq $key) { throw ('Dienst „{0}“ nicht gefunden.' -f $Svc.Name) }
            try {
                $start = @{ 'auto' = 2; 'delayed-auto' = 2; 'demand' = 3; 'disabled' = 4 }[$Code]
                $key.SetValue('Start', $start, [Microsoft.Win32.RegistryValueKind]::DWord)
                $key.SetValue('DelayedAutostart', [int]($Code -eq 'delayed-auto'), [Microsoft.Win32.RegistryValueKind]::DWord)
            } finally { $key.Close() }
        } finally { $base.Close() }
    } else {
        $ErrorActionPreference = 'Continue'
        $out = & "$env:SystemRoot\System32\sc.exe" config $Svc.Name start= $Code 2>&1
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            $msg = switch ($rc) {
                5       { 'Zugriff verweigert – der Dienst ist geschützt oder es fehlen Administratorrechte.' }
                1060    { 'Der Dienst ist nicht (mehr) vorhanden.' }
                default { (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' ' }
            }
            throw ('Starttyp von „{0}“ konnte nicht geändert werden (Code {1}): {2}' -f $Svc.DisplayName, $rc, $msg)
        }
    }

    $cfg = Read-ServiceConfig $Svc.Name
    if ($cfg) { $Svc.StartType = $cfg.StartType } else { $Svc.StartType = $Code }
    Update-ServiceDisplay $Svc
    Write-Log ('DIENST      {0} ({1}): {2} -> {3}' -f $Svc.DisplayName, $Svc.Name, $script:StartTypeText[$old], $Svc.StartTypeText)
    if ($Svc.StartType -ne $Code) { throw ('Starttyp von „{0}“ ist nach der Änderung „{1}“ statt „{2}“.' -f $Svc.DisplayName, $Svc.StartTypeText, $script:StartTypeText[$Code]) }
}

#endregion

#region RDS-Optimierung ---------------------------------------------------------------------
# Vorschläge für Citrix-RDS-Hosts (angelehnt an Citrix Optimizer, Microsoft WDOT, Citrix-PVS/MCS/WEM-Doku).
# Jeder Punkt einzeln anwendbar und rückgängig: Der ursprüngliche Zustand wird beim ersten Anwenden in
# backups\rdsopt_original.json festgehalten und nie überschrieben.

$script:PowerCfg       = "$env:SystemRoot\System32\powercfg.exe"
$script:HighPerfScheme = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

function Test-RegKey([string]$Path) {
    $base = Open-BaseKey 'HKLM'
    try {
        $k = $base.OpenSubKey($Path)
        if ($k) { $k.Close(); return $true }
        return $false
    } finally { $base.Close() }
}

$script:PvsCacheTypes = @{
    0 = 'Privat (Schreibzugriff)'; 1 = 'Cache auf dem Server'; 3 = 'Cache im Geräte-RAM'; 4 = 'Cache auf der Geräte-Festplatte'
    7 = 'Cache auf dem Server, persistent'; 9 = 'Cache im Geräte-RAM mit Überlauf auf Festplatte'; 10 = 'Privat (asynchron)'
    11 = 'Cache auf dem Server, persistent (asynchron)'; 12 = 'Cache im RAM mit Überlauf (asynchron)'
}

function Get-CitrixEnvironment([string]$IniPath = '') {
    # Mehrere Merkmale je Komponente; eines genügt. "Installiert" gilt auch im Master-Image.
    # Bereitstellung (Merkmale u. a. nach BIS-F, neu umgesetzt):
    #   PVS: Schlüssel bnistack\PVSAgent existiert nur auf von einer vDisk gestarteten Target-Devices
    #   MCS: Personality.ini (mit DiskMode) ohne PVSAgent-Schlüssel
    $vda = @(); $wem = @(); $pvs = @(); $mcs = @(); $wemSvc = ''; $brokerPath = ''; $vmtools = $false
    $base = Open-BaseKey 'HKLM'
    try {
        $root = $base.OpenSubKey($script:ServicesPath)
        try {
            foreach ($n in $root.GetSubKeyNames()) {
                $dn = ''
                try {
                    $k = $root.OpenSubKey($n)
                    if ($null -eq $k) { continue }
                    try {
                        $dn = "$($k.GetValue('DisplayName', ''))"
                        if ($n -eq 'BrokerAgent') { $brokerPath = "$($k.GetValue('ImagePath', ''))" }
                    } finally { $k.Close() }
                } catch { continue }
                if ($dn.StartsWith('@')) { $dn = '' }
                $label = if ($dn) { '{0} ({1})' -f $dn, $n } else { $n }
                if ($n -in 'BrokerAgent', 'picaSvc2') { $vda += $label }
                if ($n -eq 'vmtools') { $vmtools = $true }
                if ($n -in 'WemAgentSvc', 'Norskale Agent Host Service' -or $n -match 'Norskale|WemAgent' -or $dn -match 'WEM Agent|Norskale|Workspace Environment Management') {
                    $wem += $label
                    if (-not $wemSvc -or $n -in 'WemAgentSvc', 'Norskale Agent Host Service') { $wemSvc = $n }
                }
                if ($n -in 'BNDevice', 'bnistack' -or $dn -match 'PVS Device|PVS Target|Provisioning Services Device') { $pvs += $label }
                if ($n -match '^(MachineIdentityService|mcsio|CtxMcs)' -or $dn -match 'Machine Identity|MCS ?I/?O') { $mcs += $label }
            }
        } finally { $root.Close() }
    } finally { $base.Close() }
    if (Test-RegKey 'SOFTWARE\Citrix\VirtualDesktopAgent') { $vda += 'Registry: SOFTWARE\Citrix\VirtualDesktopAgent' }
    if (Test-RegKey 'SYSTEM\CurrentControlSet\Control\Norskale') { $wem += 'Registry: Control\Norskale' }
    if (Test-RegKey 'SOFTWARE\Citrix\MachineIdentityServiceAgent') { $mcs += 'Registry: SOFTWARE\Citrix\MachineIdentityServiceAgent' }

    # VDA-Version (Dateiversion des Desktop Service, intern 7.xx); MCSIO ab 7.21 (VDA 1903)
    $vdaVer = $null
    $exe = Resolve-ExePath $brokerPath
    if ($exe -and [IO.File]::Exists($exe)) {
        try { $fv = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe); $vdaVer = [version]('{0}.{1}' -f $fv.FileMajorPart, $fv.FileMinorPart) } catch { }
    }
    if ($vdaVer) { $vda += ('Version {0}' -f $vdaVer) }

    # WEM: Agent-Ort und aktueller Cache-Ort
    $wemKey = 'SYSTEM\CurrentControlSet\Control\Norskale\Agent Host'
    $wemLoc = "$((Get-RegState (New-RegSpec $wemKey 'AgentLocation' '' 'String')).Value)"
    $wemCache = Get-RegState (New-RegSpec $wemKey 'AgentCacheAlternateLocation' '' 'String')
    if ($wem.Count -gt 0 -and $wemCache.Exists) { $wem += ('Agent-Cache: {0}' -f $wemCache.Value) }

    # PVS: von vDisk gestartet? WriteCacheType 0/10 = Schreibzugriff, sonst Standard-Modus
    $pvsAgent = 'SYSTEM\CurrentControlSet\Services\bnistack\PVSAgent'
    $pvsBooted = Test-RegKey $pvsAgent
    $standard = $false; $mode = ''
    if ($pvsBooted) {
        $wct = Get-RegState (New-RegSpec $pvsAgent 'WriteCacheType' 0)
        $disk = "$((Get-RegState (New-RegSpec $pvsAgent 'DiskName' '' 'String')).Value)"
        if ($wct.Exists) {
            $t = [int]$wct.Value
            $standard = ($t -notin 0, 10)
            $txt = if ($script:PvsCacheTypes.ContainsKey($t)) { $script:PvsCacheTypes[$t] } else { 'Typ {0}' -f $t }
            $mode = if ($standard) { 'Standard-Modus – {0}' -f $txt } else { $txt }
        } else { $mode = 'Modus unbekannt' }
        if ($disk -match '\.avhdx?$') { $mode += ', Wartungsversion' }
        $pvs += ('von vDisk gestartet: {0} – {1}' -f $disk, $mode)
    }

    # MCS: Personality.ini ohne PVSAgent = von MCS bereitgestellt; DiskMode Shared = nicht persistent
    $mcsProv = $false; $diskMode = ''
    $ini = if ($IniPath) { $IniPath } else { Join-Path $env:SystemDrive 'Personality.ini' }
    if (-not $pvsBooted -and [IO.File]::Exists($ini)) {
        $mcsProv = $true
        if ([IO.File]::ReadAllText($ini) -match '(?m)^\s*\$?DiskMode\s*=\s*(\S+)') { $diskMode = $Matches[1] }
        $mcs += ('von MCS bereitgestellt (Personality.ini, DiskMode={0})' -f $(if ($diskMode) { $diskMode } else { '?' }))
    }
    $isMcs = ($mcs.Count -gt 0)
    $mcsio = $isMcs -and $vdaVer -and ($vdaVer -ge [version]'7.21')
    if ($mcsio) { $mcs += 'MCSIO möglich (VDA ab 1903)' }

    # Plattform und Betriebssystem
    $cs = @(Get-CimSafe 'Win32_ComputerSystem') | Select-Object -First 1
    $platform = if ($cs) { ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim() } else { 'unbekannt' }
    $isVmware = $vmtools -or ($platform -match 'VMware')
    $build = "$((Get-RegState (New-RegSpec 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' '' 'String')).Value)"
    $ptype = "$((Get-RegState (New-RegSpec 'SYSTEM\CurrentControlSet\Control\ProductOptions' 'ProductType' '' 'String')).Value)"
    $isServer = ($ptype -ne 'WinNT')
    $platText = @($platform, ('Windows-Build {0} ({1})' -f $build, $(if ($isServer) { 'Server' } else { 'Client' })))
    if ($isVmware) { $platText += 'VMware erkannt' }

    [pscustomobject]@{
        Vda = ($vda.Count -gt 0); Wem = ($wem.Count -gt 0); Pvs = ($pvs.Count -gt 0); Mcs = $isMcs
        WemService = $wemSvc; WemAgentLocation = $wemLoc; VdaVersion = $vdaVer
        PvsBooted = $pvsBooted; PvsStandard = $standard; PvsMode = $mode
        McsProvisioned = $mcsProv; McsDiskMode = $diskMode; Mcsio = [bool]$mcsio
        ImageReadOnly = ($standard -or ($mcsProv -and $diskMode -match 'Shared'))
        Platform = $platform; VMware = $isVmware; Server2019 = ($isServer -and $build -eq '17763'); Server = $isServer
        # RD-Sitzungshost: Rolle installiert (TSAppCompat = 1) oder Citrix-Server-VDA
        Rdsh = ($isServer -and (($vda.Count -gt 0) -or "$((Get-RegState (New-RegSpec 'SYSTEM\CurrentControlSet\Control\Terminal Server' 'TSAppCompat' 0)).Value)" -eq '1'))
        VdaText = ($vda -join "`n"); WemText = ($wem -join "`n"); PvsText = ($pvs -join "`n"); McsText = ($mcs -join "`n")
        PlatformText = ($platText -join "`n")
    }
}

function New-RegSpec([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord') {
    [pscustomobject]@{ Hive = 'HKLM'; Path = $Path; Name = $Name; Value = $Value; Kind = $Kind }
}

function Convert-RegValue($Value, [string]$Kind) {
    switch ($Kind) {
        'DWord'       { return [int][long]$Value }
        'QWord'       { return [long]$Value }
        'MultiString' { return [string[]]@($Value) }
        'Binary'      { return [byte[]]@($Value) }
        default       { return [string]$Value }
    }
}

function Get-RegState($Spec) {
    # Kind 'Key': es zählt nur, ob der Unterschlüssel <Path>\<Name> existiert
    $exists = $false; $value = $null; $kind = $Spec.Kind
    $base = Open-BaseKey $Spec.Hive
    try {
        $key = $base.OpenSubKey($Spec.Path)
        if ($key) {
            try {
                if ($Spec.Kind -eq 'Key') { $exists = ($key.GetSubKeyNames() -contains $Spec.Name) }
                elseif ($key.GetValueNames() -contains $Spec.Name) {
                    $exists = $true
                    $value = $key.GetValue($Spec.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $kind = $key.GetValueKind($Spec.Name).ToString()
                }
            } finally { $key.Close() }
        }
    } finally { $base.Close() }
    [pscustomobject]@{ Hive = $Spec.Hive; Path = $Spec.Path; Name = $Spec.Name; Exists = $exists; Kind = $kind; Value = $value }
}

function Test-RegSpec($Spec) {
    $st = Get-RegState $Spec
    if ($Spec.Kind -eq 'Key') { return $st.Exists }
    return ($st.Exists -and "$($st.Value)" -eq "$($Spec.Value)")
}

function Set-RegSpec($Spec) {
    $base = Open-BaseKey $Spec.Hive
    try {
        if ($Spec.Kind -eq 'Key') { $base.CreateSubKey("$($Spec.Path)\$($Spec.Name)").Close(); return }
        $key = $base.CreateSubKey($Spec.Path)
        try { $key.SetValue($Spec.Name, (Convert-RegValue $Spec.Value $Spec.Kind), [Microsoft.Win32.RegistryValueKind]$Spec.Kind) }
        finally { $key.Close() }
    } finally { $base.Close() }
}

function Restore-RegState($State) {
    $base = Open-BaseKey $State.Hive
    try {
        if ($State.Kind -eq 'Key') {
            $sub = "$($State.Path)\$($State.Name)"
            if ($State.Exists) { $base.CreateSubKey($sub).Close() } else { $base.DeleteSubKey($sub, $false) }
            return
        }
        if ($State.Exists) {
            $key = $base.CreateSubKey($State.Path)
            try { $key.SetValue($State.Name, (Convert-RegValue $State.Value $State.Kind), [Microsoft.Win32.RegistryValueKind]$State.Kind) }
            finally { $key.Close() }
        } else {
            $key = $base.OpenSubKey($State.Path, $true)
            if ($key) { try { $key.DeleteValue($State.Name, $false) } finally { $key.Close() } }
        }
    } finally { $base.Close() }
}

function Update-OptTaskCache {
    # Einzelabfragen per Get-ScheduledTask dauern je ~2 s – daher alle Aufgaben einmal lesen
    $c = @{}
    try { foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) { $c[("$($t.TaskPath)$($t.TaskName)").ToLower()] = $t } }
    catch { Write-Log ('Geplante Aufgaben nicht lesbar: {0}' -f $_.Exception.Message) 'WARN' }
    $script:OptTaskCache = $c
}

function Get-OptTask([string]$Full) {
    if ($null -eq $script:OptTaskCache) { Update-OptTaskCache }
    $script:OptTaskCache[$Full.ToLower()]
}

function Get-TaskEnabled([string]$Full) {
    $t = Get-OptTask $Full
    if (-not $t) { return $null }
    return ("$($t.State)" -ne 'Disabled')
}

function Set-TaskEnabled([string]$Full, [bool]$On) {
    $t = Get-OptTask $Full
    if (-not $t) { return }
    $new = if ($On) { Enable-ScheduledTask -InputObject $t -ErrorAction Stop } else { Disable-ScheduledTask -InputObject $t -ErrorAction Stop }
    if ($new) { $script:OptTaskCache[$Full.ToLower()] = $new }
}

function Invoke-NativeChecked([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
        throw ('{0} {1} fehlgeschlagen (Code {2}): {3}' -f [IO.Path]::GetFileName($Exe), ($Arguments -join ' '), $LASTEXITCODE, $msg)
    }
    @($out | ForEach-Object { "$_" })
}

function Get-HibernateEnabled {
    $st = Get-RegState (New-RegSpec 'SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 0)
    return [int]($st.Exists -and [long]$st.Value -ne 0)
}

function Get-ActivePowerScheme {
    $out = Invoke-NativeChecked $script:PowerCfg @('/getactivescheme')
    $m = [regex]::Match(($out -join ' '), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { $m.Value.ToLower() } else { '' }
}

function Get-BootStatusPolicy {
    # Nur mit Adminrechten lesbar; '' = Wert nicht gesetzt (Windows-Standard)
    $out = Invoke-NativeChecked "$env:SystemRoot\System32\bcdedit.exe" @('/enum', '{current}')
    $m = [regex]::Match(($out -join "`n"), '(?im)^bootstatuspolicy\s+(\S+)')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

function Get-RssState { "$((Get-NetOffloadGlobalSetting -ErrorAction Stop).ReceiveSideScaling)" }

function New-CacheFolder([string]$Path, [string]$AclFrom = '') {
    # Zielordner auf dem Cache-Laufwerk; Rechte von einer Vorlage übernehmen oder für Systemdienste setzen
    if (-not [IO.Directory]::Exists($Path)) { [void][IO.Directory]::CreateDirectory($Path) }
    if ($AclFrom -and [IO.Directory]::Exists($AclFrom)) { Set-Acl -LiteralPath $Path -AclObject (Get-Acl -LiteralPath $AclFrom); return }
    $acl = Get-Acl -LiteralPath $Path
    $ids = @(
        (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'),       # SYSTEM
        (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'),   # Administratoren
        (New-Object Security.Principal.SecurityIdentifier 'S-1-5-19')        # Lokaler Dienst
    )
    try { $ids += (New-Object Security.Principal.NTAccount 'NT SERVICE\EventLog').Translate([Security.Principal.SecurityIdentifier]) } catch { }
    foreach ($id in $ids) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-EventLogTarget { if ($script:OptCacheDrive) { Join-Path $script:OptCacheDrive 'EventLogs' } else { '' } }

function Test-EventLogsRedirected {
    $dir = Get-EventLogTarget
    if (-not $dir) { return $false }
    $s = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    foreach ($n in 'Application', 'System') {
        $c = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($n, $s)
        $p = [Environment]::ExpandEnvironmentVariables($c.LogFilePath)
        if (-not $p.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-EventLogPaths {
    $map = [ordered]@{}
    $s = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    foreach ($n in $s.GetLogNames()) {
        try { $map[$n] = (New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($n, $s)).LogFilePath } catch { }
    }
    $map
}

function Set-EventLogPath([string]$Name, [string]$Path, $Session) {
    $c = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($Name, $Session)
    if ($c.LogFilePath -eq $Path) { return }
    # Debug-/Analyse-Protokolle lassen sich nur im deaktivierten Zustand umstellen
    $toggle = ("$($c.LogType)" -in 'Debug', 'Analytical') -and $c.IsEnabled
    if ($toggle) { $c.IsEnabled = $false; $c.SaveChanges() }
    $c.LogFilePath = $Path
    $c.SaveChanges()
    if ($toggle) { $c.IsEnabled = $true; $c.SaveChanges() }
}

function Move-EventLogs([string]$Dir) {
    New-CacheFolder $Dir
    $s = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    $fail = 0
    foreach ($n in $s.GetLogNames()) {
        try {
            $c = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($n, $s)
            if (-not $c.LogFilePath) { continue }
            Set-EventLogPath $n (Join-Path $Dir ([IO.Path]::GetFileName([Environment]::ExpandEnvironmentVariables($c.LogFilePath)))) $s
        } catch { $fail++ }
    }
    if ($fail) { Write-Log ('Ereignisprotokolle: {0} Protokoll(e) ließen sich nicht umstellen.' -f $fail) 'WARN' }
}

function Restore-EventLogs($Map) {
    $src = if ($Map -is [Collections.IDictionary]) { @($Map.GetEnumerator() | ForEach-Object { [pscustomobject]@{ K = $_.Key; V = $_.Value } }) }
           else { @($Map.PSObject.Properties | ForEach-Object { [pscustomobject]@{ K = $_.Name; V = $_.Value } }) }
    $pairs = @($src | ForEach-Object { , @($_.K, $_.V) })   # auch bei nur einem Protokoll eine Liste von Paaren
    $s = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    $fail = 0
    foreach ($p in $pairs) { try { Set-EventLogPath "$($p[0])" "$($p[1])" $s } catch { $fail++ } }
    if ($fail) { Write-Log ('Ereignisprotokolle: {0} Protokoll(e) ließen sich nicht zurückstellen.' -f $fail) 'WARN' }
}

function Clear-AllEventLogs {
    $s = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    $ok = 0; $fail = 0
    foreach ($n in $s.GetLogNames()) { try { $s.ClearLog($n); $ok++ } catch { $fail++ } }
    Write-Log ('Ereignisprotokolle geleert: {0}, nicht leerbar: {1}' -f $ok, $fail)
}

function Remove-RegValues([string]$Path, [string[]]$Names) {
    $base = Open-BaseKey 'HKLM'
    try {
        $key = $base.OpenSubKey($Path, $true)
        if ($key) { try { foreach ($n in $Names) { $key.DeleteValue($n, $false) } } finally { $key.Close() } }
    } finally { $base.Close() }
}

function Clear-FolderContent([string]$Path) {
    if (-not [IO.Directory]::Exists($Path)) { return }
    foreach ($i in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop } catch { Write-Log ('Nicht löschbar: {0}' -f $i.FullName) 'WARN' }
    }
}

function Invoke-WemCacheRefresh($Ctx) {
    $exe = if ($Ctx.WemAgentLocation) { Join-Path $Ctx.WemAgentLocation 'AgentCacheUtility.exe' } else { '' }
    if (-not $exe -or -not [IO.File]::Exists($exe)) { Write-Log 'WEM AgentCacheUtility.exe nicht gefunden – Cache wird beim nächsten Agent-Start neu aufgebaut.' 'WARN'; return }
    try { [void](Invoke-NativeChecked $exe @('-RefreshCache')) } catch { Write-Log ('WEM-Cache-Aktualisierung: {0}' -f $_.Exception.Message) 'WARN' }
}

function Enable-TokenPrivilege([int]$Id) {
    # Eigene Minimal-Deklaration: ntdll!RtlAdjustPrivilege (9 = SeTakeOwnership, 18 = SeRestore)
    if (-not ('WinOpt.TokenPriv' -as [type])) {
        Add-Type -Namespace WinOpt -Name TokenPriv -MemberDefinition '[DllImport("ntdll.dll")] public static extern int RtlAdjustPrivilege(int Privilege, bool Enable, bool CurrentThread, out bool WasEnabled);'
    }
    $was = $false
    $rc = [WinOpt.TokenPriv]::RtlAdjustPrivilege($Id, $true, $false, [ref]$was)
    if ($rc -ne 0) { throw ('Recht {0} konnte nicht aktiviert werden (NTSTATUS 0x{1:X8}).' -f $Id, $rc) }
}

function Reset-RdsGracePeriod {
    # Kulanzzeitraum des RD-Sitzungshosts für Klone zurücksetzen (Werte *TIMEBOMB* löschen).
    # Der Schlüssel gehört NETWORK SERVICE: Besitz kurz übernehmen, danach Besitzer und Rechte wiederherstellen.
    $path = 'SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod'
    $rw = [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    Enable-TokenPrivilege 9
    Enable-TokenPrivilege 18
    $base = Open-BaseKey 'HKLM'
    try {
        $k = $base.OpenSubKey($path, $rw, [Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $k) { Write-Log 'RDS-Kulanzfrist: Schlüssel GracePeriod nicht vorhanden – nichts zu tun.'; return }
        $k.Close()

        # Ursprünglichen Besitzer lesen (falls erlaubt), sonst NETWORK SERVICE annehmen
        $origOwner = New-Object Security.Principal.SecurityIdentifier 'S-1-5-20'
        try {
            $k = $base.OpenSubKey($path, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [Security.AccessControl.RegistryRights]::ReadPermissions)
            if ($k) { try { $origOwner = $k.GetAccessControl('Owner').GetOwner([Security.Principal.SecurityIdentifier]) } finally { $k.Close() } }
        } catch { }

        # 1. Besitz übernehmen
        $k = $base.OpenSubKey($path, $rw, [Security.AccessControl.RegistryRights]::TakeOwnership)
        try { $sd = $k.GetAccessControl('None'); $sd.SetOwner($admins); $k.SetAccessControl($sd) } finally { $k.Close() }

        # 2. Rechte merken, Administratoren Vollzugriff geben
        $k = $base.OpenSubKey($path, $rw, [Security.AccessControl.RegistryRights]'ReadPermissions, ChangePermissions')
        try {
            $acl = $k.GetAccessControl('Access')
            $origAccess = $acl.GetSecurityDescriptorSddlForm('Access')
            $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($admins, 'FullControl', 'Allow')))
            $k.SetAccessControl($acl)
        } finally { $k.Close() }

        try {
            # 3. Zeitstempel löschen
            $k = $base.OpenSubKey($path, $true)
            try {
                $names = @($k.GetValueNames() | Where-Object { $_ -match 'TIMEBOMB' })
                foreach ($n in $names) { $k.DeleteValue($n) }
            } finally { $k.Close() }
            Write-Log ('RDS-Kulanzfrist zurückgesetzt: {0} Wert(e) gelöscht.' -f $names.Count)
        } finally {
            # 4. Ursprüngliche Rechte und Besitzer wiederherstellen
            $k = $base.OpenSubKey($path, $rw, [Security.AccessControl.RegistryRights]'ChangePermissions, TakeOwnership')
            try {
                $acl = New-Object Security.AccessControl.RegistrySecurity
                $acl.SetSecurityDescriptorSddlForm($origAccess, 'Access')
                $k.SetAccessControl($acl)
                $own = New-Object Security.AccessControl.RegistrySecurity
                $own.SetOwner($origOwner)
                $k.SetAccessControl($own)
            } finally { $k.Close() }
        }
    } finally { $base.Close() }
}

function Find-OfficeOspp {
    # OSPPREARM.EXE/OSPP.VBS suchen: MSI-Office (InstallRoot), Click-to-Run (auch LTSC-Volumenlizenz), OSPP (Office 2010)
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($sw in 'SOFTWARE', 'SOFTWARE\WOW6432Node') {
        foreach ($v in '16.0', '15.0', '14.0') {
            $p = "$((Get-RegState (New-RegSpec "$sw\Microsoft\Office\$v\Common\InstallRoot" 'Path' '' 'String')).Value)"
            if ($p) { $dirs.Add($p) }
        }
        $p = "$((Get-RegState (New-RegSpec "$sw\Microsoft\Office\ClickToRun" 'InstallPath' '' 'String')).Value)"
        if ($p) { $dirs.Add((Join-Path $p 'root\Office16')); $dirs.Add($p) }
        $p = "$((Get-RegState (New-RegSpec "$sw\Microsoft\OfficeSoftwareProtectionPlatform" 'Path' '' 'String')).Value)"
        if ($p) { $dirs.Add($p) }
    }
    foreach ($d in $dirs) {
        $d = [Environment]::ExpandEnvironmentVariables($d)
        if (-not [IO.Directory]::Exists($d)) { continue }
        $exe = Join-Path $d 'OSPPREARM.EXE'
        if (-not [IO.File]::Exists($exe)) {
            $exe = @(Get-ChildItem -LiteralPath $d -Filter 'OSPPREARM.EXE' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)[0]
        }
        if (-not $exe -or -not [IO.File]::Exists($exe)) { continue }
        $vbs = Join-Path (Split-Path -Parent $exe) 'OSPP.VBS'
        if (-not [IO.File]::Exists($vbs)) {
            $vbs = @(Get-ChildItem -LiteralPath $d -Filter 'OSPP.VBS' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)[0]
        }
        return [pscustomobject]@{ Rearm = $exe; Ospp = "$vbs" }
    }
    return $null
}

function Get-OfficeLicenseStatus($Tool) {
    # ospp.vbs /dstatus nur lesen; Volumenlizenz = Kanal VOLUME_KMSCLIENT oder VOLUME_MAK
    if (-not $Tool -or -not $Tool.Ospp -or -not [IO.File]::Exists($Tool.Ospp)) { return [pscustomobject]@{ Text = ''; IsVolume = $false } }
    $ErrorActionPreference = 'Continue'
    $text = (@(& "$env:SystemRoot\System32\cscript.exe" '//NoLogo' $Tool.Ospp '/dstatus' 2>&1) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ Text = $text; IsVolume = ($text -match 'VOLUME_KMSCLIENT|VOLUME_MAK') }
}

function Get-OfficeRearmSkipReason {
    $t = Find-OfficeOspp
    if (-not $t) { return 'Office nicht installiert bzw. ospprearm.exe nicht gefunden' }
    $st = Get-OfficeLicenseStatus $t
    if ($st.IsVolume) { return '' }
    if ($st.Text -match 'LICENSE NAME') { return 'keine Office-Volumenlizenz (z. B. Microsoft 365) – kein Rearm nötig' }
    return 'Office-Lizenzstatus nicht lesbar (ospp.vbs /dstatus)'
}

function Invoke-OfficeRearm {
    $t = Find-OfficeOspp
    if (-not $t) { throw 'ospprearm.exe nicht gefunden.' }
    [void](Invoke-NativeChecked $t.Rearm @())
    $st = Get-OfficeLicenseStatus $t
    foreach ($l in @($st.Text -split "`n" | Where-Object { $_ -match '^\s*(LICENSE NAME|LICENSE STATUS|REMAINING GRACE)' })) {
        Write-Log ('Office-Lizenz nach Rearm: {0}' -f $l.Trim())
    }
}

function New-OptServiceObject([string]$Name) {
    # Minimales Objekt für Set-ServiceStartType / Update-ServiceDisplay
    $cfg = Read-ServiceConfig $Name
    if (-not $cfg) { throw ('Dienst „{0}“ nicht gefunden.' -f $Name) }
    [pscustomobject]@{
        Name = $Name; DisplayName = $Name; StartType = $cfg.StartType; Template = ''
        IsInstance = (($cfg.Type -band 0x80) -ne 0); IsTemplate = (($cfg.Type -band 0x40) -ne 0) -and (($cfg.Type -band 0x80) -eq 0)
        StartTypeText = ''; StatusText = ''; SwitchTip = ''
    }
}

function Get-OptimizationCatalog($Ctx) {
    $pol = 'SOFTWARE\Policies\Microsoft\Windows'
    $fs  = 'SYSTEM\CurrentControlSet\Control\FileSystem'
    $pf  = 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
    $t   = '\Microsoft\Windows\'
    $drv = if ($script:OptCacheDrive) { $script:OptCacheDrive } else { '(Laufwerk wählen)' }
    $defs = @(
        # ---------- Allgemein: Registry ----------
        @{ Id = 'reg.telemetry'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Telemetrie auf Minimum'
           Detail = 'Richtlinie AllowTelemetry = 0 (Sicherheit; Pro-Editionen werten das als „Erforderlich“). Weniger Hintergrundlast und Datenverkehr je Host.'
           Reg = @(New-RegSpec "$pol\DataCollection" 'AllowTelemetry' 0) }
        @{ Id = 'reg.consumer'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Consumer-Features und Tipps aus'
           Detail = 'Keine automatisch installierten Store-Apps, Vorschläge und Tipps in Benutzersitzungen.'
           Reg = @((New-RegSpec "$pol\CloudContent" 'DisableWindowsConsumerFeatures' 1), (New-RegSpec "$pol\CloudContent" 'DisableSoftLanding' 1)) }
        @{ Id = 'reg.firstlogon'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Animation bei der Erstanmeldung aus'
           Detail = 'Verkürzt die erste Anmeldung neuer bzw. nicht-persistenter Profile („Hallo“-Bildschirm entfällt).'
           Reg = @(New-RegSpec 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableFirstLogonAnimation' 0) }
        @{ Id = 'reg.bgapps'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Hintergrund-Apps verbieten'
           Detail = 'Store-Apps laufen nicht in jeder Sitzung im Hintergrund – spart CPU und RAM je Benutzer.'
           Reg = @(New-RegSpec "$pol\AppPrivacy" 'LetAppsRunInBackground' 2) }
        @{ Id = 'reg.cortana'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Cortana aus'
           Detail = 'Nur Cortana wird abgeschaltet; die Windows-Suche (wichtig für Outlook) bleibt erhalten.'
           Reg = @(New-RegSpec "$pol\Windows Search" 'AllowCortana' 0) }
        @{ Id = 'reg.servermanager'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Server-Manager nicht bei Anmeldung öffnen'
           Detail = 'Der Server-Manager startet nicht bei jeder Anmeldung von Administratoren (spart Ressourcen).'
           Reg = @(New-RegSpec "$pol\Server\ServerManager" 'DoNotOpenAtLogon' 1) }
        @{ Id = 'reg.lastaccess'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'NTFS-Zeitstempel „Letzter Zugriff“ aus'
           Detail = 'Weniger Schreibzugriffe auf den Datenträger (wie „fsutil behavior set disablelastaccess 1“). Wirkt nach Neustart.'
           Reg = @(New-RegSpec $fs 'NtfsDisableLastAccessUpdate' 1) }
        @{ Id = 'reg.8dot3'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Prüfen'
           Title = '8.3-Kurznamen nicht mehr erzeugen'
           Detail = 'Beschleunigt Dateioperationen in Ordnern mit vielen Dateien. Sehr alte Programme/Installer können Kurznamen benötigen; vorhandene Kurznamen bleiben.'
           Reg = @(New-RegSpec $fs 'NtfsDisable8dot3NameCreation' 1) }
        @{ Id = 'reg.wer'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Prüfen'
           Title = 'Windows-Fehlerberichterstattung aus'
           Detail = 'Keine Fehlerberichte an Microsoft. Bei Supportfällen mit Microsoft können die Berichte benötigt werden.'
           Reg = @(New-RegSpec "$pol\Windows Error Reporting" 'Disabled' 1) }
        @{ Id = 'reg.crashdump'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Prüfen'
           Title = 'Kleines Speicherabbild statt vollständigem'
           Detail = 'Spart Platz (bei PVS/MCS im Schreibcache). Für tiefe Absturzanalysen kann ein vollständiges Abbild nötig sein.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled' 3) }

        # ---------- Allgemein: geplante Aufgaben ----------
        @{ Id = 'task.defrag'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Geplante Defragmentierung aus'
           Detail = 'Auf VMs mit SAN/SSD-Speicher unnötig; bei PVS/MCS füllt sie nur den Schreibcache.'
           Tasks = @("$($t)Defrag\ScheduledDefrag") }
        @{ Id = 'task.ceip'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Programm zur Verbesserung der Benutzerfreundlichkeit (CEIP)'
           Detail = 'Sammel- und Upload-Aufgaben für Nutzungsdaten.'
           Tasks = @("$($t)Customer Experience Improvement Program\Consolidator", "$($t)Customer Experience Improvement Program\UsbCeip", "$($t)Customer Experience Improvement Program\KernelCeipTask") }
        @{ Id = 'task.appexp'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Kompatibilitäts-Telemetrie (Application Experience)'
           Detail = 'Compatibility Appraiser und Programmdaten-Updater erzeugen regelmäßig hohe CPU-/Datenträgerlast.'
           Tasks = @("$($t)Application Experience\Microsoft Compatibility Appraiser", "$($t)Application Experience\ProgramDataUpdater", "$($t)Application Experience\StartupAppTask") }
        @{ Id = 'task.diskdiag'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Datenträgerdiagnose aus'
           Detail = 'Virtuelle Datenträger liefern keine sinnvollen SMART-Daten.'
           Tasks = @("$($t)DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector", "$($t)DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver") }
        @{ Id = 'task.maps'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Kartenaktualisierung aus'
           Detail = 'Offline-Karten werden auf RDS-Hosts nicht genutzt.'
           Tasks = @("$($t)Maps\MapsUpdateTask", "$($t)Maps\MapsToastTask") }
        @{ Id = 'task.power'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Energieeffizienz-Diagnose aus'
           Detail = 'Analysiert den Energieverbrauch – auf VMs ohne Nutzen.'
           Tasks = @("$($t)Power Efficiency Diagnostics\AnalyzeSystem") }
        @{ Id = 'task.wer'; Group = 'Allgemein'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'All'; Level = 'Prüfen'
           Title = 'Warteschlange der Fehlerberichte aus'
           Detail = 'Sendet gesammelte Fehlerberichte; passend zu „Windows-Fehlerberichterstattung aus“.'
           Tasks = @("$($t)Windows Error Reporting\QueueReporting") }

        # ---------- Allgemein: System ----------
        @{ Id = 'sys.hibernate'; Group = 'Allgemein'; Category = 'System'; Kind = 'System'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Ruhezustand aus (hiberfil.sys)'
           Detail = 'RDS-Hosts gehen nicht in den Ruhezustand; spart Speicherplatz in Größe des Arbeitsspeichers (powercfg /hibernate off).'
           Test = { (Get-HibernateEnabled) -eq 0 }; Read = { Get-HibernateEnabled }
           Apply = { [void](Invoke-NativeChecked $script:PowerCfg @('/hibernate', 'off')) }
           Undo = { param($v) if ([int]$v -eq 1) { [void](Invoke-NativeChecked $script:PowerCfg @('/hibernate', 'on')) } } }
        @{ Id = 'sys.powerplan'; Group = 'Allgemein'; Category = 'System'; Kind = 'System'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Energieplan „Höchstleistung“'
           Detail = 'Verhindert das Heruntertakten der vCPUs – bessere Reaktionszeit in Sitzungen (Citrix-/Microsoft-Empfehlung für VDAs).'
           Test = { (Get-ActivePowerScheme) -eq $script:HighPerfScheme }; Read = { Get-ActivePowerScheme }
           Apply = { [void](Invoke-NativeChecked $script:PowerCfg @('/setactive', $script:HighPerfScheme)) }
           Undo = { param($v) if ($v) { [void](Invoke-NativeChecked $script:PowerCfg @('/setactive', "$v")) } } }

        # ---------- PVS und MCS (nicht-persistente Images) ----------
        @{ Id = 'reg.maintenance'; Group = 'PVS/MCS'; Category = 'Registry'; Kind = 'Registry'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Automatische Wartung aus'
           Detail = 'Wartungsläufe (Defrag, Diagnose, Updates) belasten nicht-persistente Hosts nach jedem Start; gewartet wird im Master-Image.'
           Reg = @(New-RegSpec 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1) }
        @{ Id = 'reg.prefetch'; Group = 'PVS/MCS'; Category = 'Registry'; Kind = 'Registry'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Prefetch/Superfetch aus'
           Detail = 'Prefetch-Daten gehen bei jedem Neustart verloren und erzeugen nur Schreiblast im Cache.'
           Reg = @((New-RegSpec $pf 'EnablePrefetcher' 0), (New-RegSpec $pf 'EnableSuperfetch' 0)) }
        @{ Id = 'reg.bootopt'; Group = 'PVS/MCS'; Category = 'Registry'; Kind = 'Registry'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Boot-Optimierung (Defrag der Startdateien) aus'
           Detail = 'Verschiebt Startdateien auf dem Datenträger – bei vDisk/Basis-Image wirkungslos und belastet den Schreibcache.'
           Reg = @(New-RegSpec 'SOFTWARE\Microsoft\Dfrg\BootOptimizeFunction' 'Enable' 'N' 'String') }
        @{ Id = 'svc.sysmain'; Group = 'PVS/MCS'; Category = 'Dienst'; Kind = 'Service'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Dienst SysMain (Superfetch) deaktivieren'
           Detail = 'Lernt Zugriffsmuster, die nach jedem Neustart verloren sind.'
           Service = 'SysMain'; Target = 'disabled' }
        @{ Id = 'svc.csc'; Group = 'PVS/MCS'; Category = 'Dienst'; Kind = 'Service'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Dienst Offlinedateien (CscService) deaktivieren'
           Detail = 'Offlinedateien werden auf RDS-Hosts nicht genutzt und belasten den Schreibcache.'
           Service = 'CscService'; Target = 'disabled' }
        @{ Id = 'svc.wuauserv'; Group = 'PVS/MCS'; Category = 'Dienst'; Kind = 'Service'; Applies = 'Image'; Level = 'Prüfen'
           Title = 'Windows Update deaktivieren'
           Detail = 'Nicht-persistente Hosts werden über das Master-Image aktualisiert. Im Master-Image vor Updates wieder einschalten; auf persistenten Hosts NICHT deaktivieren. Windows kann den Dienst über WaaSMedicSvc reaktivieren.'
           Service = 'wuauserv'; Target = 'disabled' }
        @{ Id = 'task.wu'; Group = 'PVS/MCS'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'Image'; Level = 'Prüfen'
           Title = 'Geplanter Start von Windows Update aus'
           Detail = 'Passend zu „Windows Update deaktivieren“.'
           Tasks = @("$($t)WindowsUpdate\Scheduled Start") }
        @{ Id = 'task.regidle'; Group = 'PVS/MCS'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Registry-Sicherung im Leerlauf aus'
           Detail = 'Die Sicherung geht bei nicht-persistenten Hosts beim Neustart verloren.'
           Tasks = @("$($t)Registry\RegIdleBackup") }
        @{ Id = 'task.sr'; Group = 'PVS/MCS'; Category = 'Aufgabe'; Kind = 'Task'; Applies = 'Image'; Level = 'Empfohlen'
           Title = 'Wiederherstellungspunkte (Aufgabe SR) aus'
           Detail = 'Wiederherstellungspunkte sind bei vDisk/Basis-Image nutzlos – zurückgesetzt wird über die Image-Version.'
           Tasks = @("$($t)SystemRestore\SR") }

        # ---------- PVS ----------
        @{ Id = 'reg.taskoffload'; Group = 'PVS'; Category = 'Registry'; Kind = 'Registry'; Applies = 'PVS'; Level = 'Empfohlen'
           Title = 'TCP Task Offload aus'
           Detail = 'Citrix-Empfehlung für PVS-Target-Devices: verhindert Streaming-Probleme durch Offload-Funktionen der Netzwerkkarte. Wirkt nach Neustart.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'DisableTaskOffload' 1) }
        @{ Id = 'reg.machinepwd'; Group = 'PVS'; Category = 'Registry'; Kind = 'Registry'; Applies = 'PVS'; Level = 'Empfohlen'
           Title = 'Kennwortänderung des Computerkontos aus'
           Detail = 'Bei PVS verwaltet der Provisioning-Server das Computerkonto-Kennwort; ändert Windows es selbst, schlägt nach dem Neustart die Vertrauensstellung fehl. Nur setzen, wenn die Kennwortverwaltung in PVS aktiv ist.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' 'DisablePasswordChange' 1) }

        # ---------- MCS ----------
        @{ Id = 'hint.mcspwd'; Group = 'MCS'; Category = 'Hinweis'; Kind = 'Hint'; Applies = 'MCS'; Level = 'Hinweis'
           Title = 'Kennwortänderung des Computerkontos NICHT sperren'
           Detail = 'Bei MCS verwaltet der Machine Identity Service das Computerkonto über den Identity-Datenträger. Die Windows-Kennwortänderung bleibt aktiv – anders als bei PVS.' }

        # ---------- WEM ----------
        @{ Id = 'reg.wemnonpersist'; Group = 'WEM'; Category = 'Registry'; Kind = 'Registry'; Applies = 'WEMImage'; Level = 'Empfohlen'
           Title = 'WEM-Agent: Verlauf für nicht-persistente Hosts'
           Detail = 'Citrix-Empfehlung für WEM-Agents auf PVS-/MCS-Images (AgentServiceUseNonPersistentCompliantHistory = 1): Der Agent führt seinen Verlauf so, dass er zu zurückgesetzten Hosts passt.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Control\Norskale\Agent Host' 'AgentServiceUseNonPersistentCompliantHistory' 1) }
        @{ Id = 'hint.wemopt'; Group = 'WEM'; Category = 'Hinweis'; Kind = 'Hint'; Applies = 'WEM'; Level = 'Hinweis'
           Title = 'WEM-Laufzeitoptimierungen nicht doppeln'
           Detail = 'CPU-Spitzenschutz, Arbeitsspeicher- und I/O-Optimierung von WEM wirken bereits zur Laufzeit. Gleichartige Funktionen anderer Tools nicht zusätzlich aktivieren.' }

        # ---------- Ergänzungen nach BIS-F (Werte übernommen, neu umgesetzt) ----------
        @{ Id = 'reg.newnetwork'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Empfohlen'
           Title = 'Dialog „Neues Netzwerk gefunden“ aus'
           Detail = 'Keine Netzwerkstandort-Abfrage bei neuen Netzwerken (Schlüssel NewNetworkWindowOff) – auf geklonten Hosts sonst bei jedem Start möglich.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Control\Network' 'NewNetworkWindowOff' $null 'Key') }
        @{ Id = 'reg.fastsend'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Prüfen'
           Title = 'UDP FastSend bis 1500 Byte'
           Detail = 'AFD FastSendDatagramThreshold = 1500: UDP-Pakete bis zur MTU werden ohne Zwischenpuffer gesendet (VMware-/Citrix-Netzwerkempfehlung). Wirkt nach Neustart.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Services\AFD\Parameters' 'FastSendDatagramThreshold' 1500) }
        @{ Id = 'reg.bfe'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Prüfen'
           Title = 'UDP-Endpunkte: MaxEndpointCountMult = 0x10'
           Detail = 'Erhöht den Schwellwert, ab dem die Basisfiltermodul-Engine UDP-Endpunkte bereinigt (Microsoft KB 2685007) – gegen Verbindungsabbrüche bei vielen Sitzungen. Wirkt nach Neustart.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Services\BFE\Parameters' 'MaxEndpointCountMult' 16) }
        @{ Id = 'reg.ipv6'; Group = 'Allgemein'; Category = 'Registry'; Kind = 'Registry'; Applies = 'All'; Level = 'Prüfen'
           Title = 'IPv6 vollständig deaktivieren'
           Detail = 'DisabledComponents = 0xFF. Microsoft rät davon ab (manche Windows-Komponenten erwarten IPv6) – nur setzen, wenn IPv6 im Netz sicher nicht genutzt wird und Probleme bekannt sind. Wirkt nach Neustart.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 255) }
        @{ Id = 'sys.rss'; Group = 'Allgemein'; Category = 'System'; Kind = 'System'; Applies = 'All'; Level = 'Prüfen'
           Title = 'Receive Side Scaling (RSS) aus'
           Detail = 'Ältere Empfehlung für PVS/VMware-VMs (Microsoft KB 951037). Auf aktuellen Systemen meist nicht nötig – nur bei bekannten Netzwerkproblemen setzen.'
           Test = { (Get-RssState) -eq 'Disabled' }; Read = { Get-RssState }
           Apply = { Set-NetOffloadGlobalSetting -ReceiveSideScaling Disabled -ErrorAction Stop }
           Undo = { param($v) if ("$v" -eq 'Enabled') { Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled -ErrorAction Stop } } }
        @{ Id = 'sys.bootstatus'; Group = 'PVS/MCS'; Category = 'System'; Kind = 'System'; Applies = 'Image'; Level = 'Prüfen'
           Title = 'Starthilfe/Systemreparatur nach Fehlstart aus'
           Detail = 'bcdedit bootstatuspolicy = IgnoreAllFailures: Nicht-persistente Hosts starten nach einem harten Abschalten normal statt in die Systemreparatur.'
           Test = { (Get-BootStatusPolicy) -eq 'IgnoreAllFailures' }; Read = { Get-BootStatusPolicy }
           Apply = { [void](Invoke-NativeChecked "$env:SystemRoot\System32\bcdedit.exe" @('/set', '{current}', 'bootstatuspolicy', 'ignoreallfailures')) }
           Undo = { param($v)
                    if ("$v") { [void](Invoke-NativeChecked "$env:SystemRoot\System32\bcdedit.exe" @('/set', '{current}', 'bootstatuspolicy', "$v")) }
                    else { [void](Invoke-NativeChecked "$env:SystemRoot\System32\bcdedit.exe" @('/deletevalue', '{current}', 'bootstatuspolicy')) } } }
        @{ Id = 'reg.pvsicon'; Group = 'PVS'; Category = 'Registry'; Kind = 'Registry'; Applies = 'PVS'; Level = 'Empfohlen'
           Title = 'PVS-Statussymbol im Infobereich ausblenden'
           Detail = 'Benutzer sehen das Symbol des PVS-Target-Device nicht in ihrer Sitzung.'
           Reg = @(New-RegSpec 'SOFTWARE\Citrix\ProvisioningServices\Status' 'ShowIcon' 0) }
        @{ Id = 'reg.fastreconnect'; Group = 'Citrix'; Category = 'Registry'; Kind = 'Registry'; Applies = 'VDA2019'; Level = 'Empfohlen'
           Title = 'Server 2019: Schnelles Wiederverbinden aus'
           Detail = 'Citrix Reconnect FastReconnect = 0 – behebt unter Windows Server 2019 Probleme beim Wiederverbinden getrennter Sitzungen („Not so fast reconnect“).'
           Reg = @(New-RegSpec 'SOFTWARE\Citrix\Reconnect' 'FastReconnect' 0) }
        @{ Id = 'reg.vmtray'; Group = 'VMware'; Category = 'Registry'; Kind = 'Registry'; Applies = 'VMware'; Level = 'Empfohlen'
           Title = 'VMware-Tools-Symbol ausblenden'
           Detail = 'Das Symbol der VMware Tools erscheint nicht mehr in jeder Benutzersitzung.'
           Reg = @(New-RegSpec 'SOFTWARE\VMware, Inc.\VMware Tools' 'ShowTray' 0) }
        @{ Id = 'svc.vmdebug'; Group = 'VMware'; Category = 'Dienst'; Kind = 'Service'; Applies = 'VMware'; Level = 'Empfohlen'
           Title = 'VMware-Debugtreiber (vmdebug) deaktivieren'
           Detail = 'Nur für die Fehlersuche durch VMware nötig.'
           Service = 'vmdebug'; Target = 'disabled' }

        # ---------- Umleitung auf das persistente Cache-Laufwerk (PVS-Schreibcache / MCSIO) ----------
        @{ Id = 'redir.eventlogs'; Group = 'Cache-Laufwerk'; Category = 'Umleitung'; Kind = 'System'; Applies = 'CacheDisk'; Level = 'Empfohlen'
           Title = ('Ereignisprotokolle nach {0}\EventLogs' -f $drv)
           Detail = 'Alle Ereignisprotokolle liegen auf dem persistenten Laufwerk und überstehen so den Neustart nicht-persistenter Hosts. Ursprüngliche Pfade je Protokoll werden gesichert. Vollständig wirksam nach Neustart.'
           Test = { Test-EventLogsRedirected }; Read = { Get-EventLogPaths }
           Apply = { Move-EventLogs (Get-EventLogTarget) }; Undo = { param($v) Restore-EventLogs $v } }
        @{ Id = 'redir.spool'; Group = 'Cache-Laufwerk'; Category = 'Umleitung'; Kind = 'Registry'; Applies = 'CacheDisk'; Level = 'Empfohlen'
           Title = ('Druckspooler nach {0}\Spool' -f $drv)
           Detail = 'Druckaufträge belasten nicht den Schreibcache des Systemlaufwerks. Ordnerrechte werden vom Windows-Spoolordner übernommen. Wirksam nach Neustart der Druckwarteschlange.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Control\Print\Printers' 'DefaultSpoolDirectory' "$drv\Spool" 'String')
           Prepare = { New-CacheFolder (Join-Path $script:OptCacheDrive 'Spool') "$env:SystemRoot\System32\spool\PRINTERS" } }
        @{ Id = 'redir.pagefile'; Group = 'Cache-Laufwerk'; Category = 'Umleitung'; Kind = 'Registry'; Applies = 'CacheDisk'; Level = 'Empfohlen'
           Title = ('Auslagerungsdatei nach {0} (systemverwaltet)' -f $drv)
           Detail = 'Die Auslagerungsdatei liegt nur noch auf dem Cache-Laufwerk; das Systemlaufwerk (vDisk/Basis-Image) bleibt frei davon. Wirksam nach Neustart.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'PagingFiles' @("$drv\pagefile.sys 0 0") 'MultiString') }
        @{ Id = 'redir.wemcache'; Group = 'Cache-Laufwerk'; Category = 'Umleitung'; Kind = 'Registry'; Applies = 'WEMCache'; Level = 'Empfohlen'
           Title = ('WEM-Agent-Cache nach {0}\WEMAgentCache' -f $drv)
           Detail = 'Der Agent-Cache bleibt über Neustarts erhalten und muss nicht bei jedem Start neu aufgebaut werden. Danach wird der Cache mit AgentCacheUtility neu erstellt.'
           Reg = @(New-RegSpec 'SYSTEM\CurrentControlSet\Control\Norskale\Agent Host' 'AgentCacheAlternateLocation' "$drv\WEMAgentCache" 'String')
           Prepare = { New-CacheFolder (Join-Path $script:OptCacheDrive 'WEMAgentCache') }
           After = { Invoke-WemCacheRefresh $script:CitrixEnv } }
    )
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in $defs) { $list.Add($d) }

    if ($Ctx.WemService) {
        $list.Add(@{ Id = 'svc.wemagent'; Group = 'WEM'; Category = 'Dienst'; Kind = 'Service'; Applies = 'WEM'; Level = 'Empfohlen'
                     Title = 'WEM-Agent-Dienst automatisch starten'
                     Detail = ('Der Agent ({0}) wendet Einstellungen und Optimierungen bei der Anmeldung an und muss ab dem Start laufen.' -f $Ctx.WemService)
                     Service = $Ctx.WemService; Target = 'auto' })
    }

    # Dienste aus der RDS-Einstufung ("Deaktivierbar"), soweit installiert
    $seen = @{}
    foreach ($d in $list) { if ($d.Service) { $seen[$d.Service.ToLower()] = $true } }
    $display = @{}
    foreach ($s in @(Get-Service -ErrorAction SilentlyContinue)) { $display[$s.Name.ToLower()] = $s.DisplayName }
    $base = Open-BaseKey 'HKLM'
    try {
        $root = $base.OpenSubKey($script:ServicesPath)
        try { $names = @($root.GetSubKeyNames()) } finally { $root.Close() }
    } finally { $base.Close() }
    $byName = @{}
    foreach ($n in $names) { $byName[$n.ToLower()] = $n }
    foreach ($h in @($script:RdsHints | Where-Object { $_[1] -eq 'Deaktivierbar' })) {
        $hits = if ($h[0] -match '\*') { @($names | Where-Object { $_ -like $h[0] }) }
                elseif ($byName.ContainsKey($h[0].ToLower())) { @($byName[$h[0].ToLower()]) } else { @() }
        foreach ($n in $hits) {
            if ($seen.ContainsKey($n.ToLower())) { continue }
            $cfg = Read-ServiceConfig $n
            if (-not $cfg -or ($cfg.Type -band 0x80) -ne 0 -or $cfg.StartType -in 'boot', 'system') { continue }
            $seen[$n.ToLower()] = $true
            $dn = if ($display.ContainsKey($n.ToLower())) { $display[$n.ToLower()] } else { $n }
            # Vorausgewählt nur, wenn auf RDS-Hosts sicher ungenutzt; sonst „Prüfen“ mit Grund
            $safe = $h[0] -in $script:RdsSafeServices
            $detail = '{0} ({1})' -f $h[2], $n
            if (-not $safe) {
                $why = if ($script:RdsServiceCaution.ContainsKey($h[0])) { $script:RdsServiceCaution[$h[0]] } else { 'Nutzung auf dem RDS-Host nicht sicher auszuschließen.' }
                $detail += ' – Nicht vorausgewählt: ' + $why
            }
            $list.Add(@{ Id = "svc.$n"; Group = 'Dienste'; Category = 'Dienst'; Kind = 'Service'; Applies = 'All'
                         Level = $(if ($safe) { 'Empfohlen' } else { 'Prüfen' })
                         Title = ('Dienst „{0}“ deaktivieren' -f $dn); Detail = $detail
                         Service = $n; Target = 'disabled' })
        }
    }
    return $list.ToArray()
}

function Get-SealSteps {
    # Einmalige, nicht umkehrbare Schritte vor dem Verteilen des Images. Werden immer gemeinsam über
    # „Versiegeln und herunterfahren“ ausgeführt (Applies wie im Katalog; Service = nötiger Dienst).
    @(
        @{ Id = 'seal.wsus'; Applies = 'All'
           Title = 'WSUS-Kennung entfernen'
           Detail = 'Löscht SusClientId/SusClientIdValidation, damit jeder Klon eine eigene Kennung am WSUS-Server erhält.'
           Apply = { Remove-RegValues 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' @('SusClientId', 'SusClientIdValidation') } }
        @{ Id = 'seal.wudl'; Applies = 'All'
           Title = 'Windows-Update-Downloadcache leeren'
           Detail = 'Leert SoftwareDistribution\Download – spart Platz im Image.'
           Apply = { Clear-FolderContent "$env:SystemRoot\SoftwareDistribution\Download" } }
        @{ Id = 'seal.netcache'; Applies = 'All'
           Title = 'DNS- und ARP-Cache leeren'
           Detail = 'ipconfig /flushdns und arp -d * – keine veralteten Adressen im Image.'
           Apply = { [void](Invoke-NativeChecked "$env:SystemRoot\System32\ipconfig.exe" @('/flushdns'))
                     try { [void](Invoke-NativeChecked "$env:SystemRoot\System32\ARP.EXE" @('-d', '*')) } catch { Write-Log ('ARP-Cache: {0}' -f $_.Exception.Message) 'WARN' } } }
        @{ Id = 'seal.officerearm'; Applies = 'All'
           Title = 'Office-Lizenz zurücksetzen (ospprearm)'
           Detail = 'Nur bei Office-Volumenlizenz (KMS/MAK, auch LTSC Click-to-Run): setzt den Lizenzzustand zurück, damit jeder Klon eine eigene KMS-Kennung erhält. Office danach nicht mehr starten – es wird direkt heruntergefahren.'
           Check = { Get-OfficeRearmSkipReason }
           Apply = { Invoke-OfficeRearm } }
        @{ Id = 'seal.evtclear'; Applies = 'All'
           Title = 'Ereignisprotokolle leeren'
           Detail = 'Leert alle Ereignisprotokolle (auch auf das Cache-Laufwerk umgeleitete), damit Klone ohne Altlasten starten. Das Protokoll dieses Tools (Textdatei) bleibt erhalten.'
           Apply = { Clear-AllEventLogs } }
        @{ Id = 'seal.shutdown'; Applies = 'All'
           Title = 'Markierung „unerwartet heruntergefahren“ entfernen'
           Detail = 'Löscht DirtyShutdown und Reliability\LastAliveStamp – Klone zeigen nach dem Start keine Ereignisprotokollierung zum Herunterfahren.'
           Apply = { Remove-RegValues 'SOFTWARE\Microsoft\Windows\CurrentVersion' @('DirtyShutdown')
                     Remove-RegValues 'SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' @('LastAliveStamp') } }
        @{ Id = 'seal.ctxcache'; Applies = 'VDA'
           Title = 'Citrix-Cache leeren'
           Detail = 'Leert „Citrix\System32\Cache“ unter Programme (x86).'
           Apply = { Clear-FolderContent (Join-Path ${env:ProgramFiles(x86)} 'Citrix\System32\Cache') } }
        @{ Id = 'seal.msdtc'; Applies = 'All'
           Title = 'MSDTC zurücksetzen'
           Detail = 'msdtc -reset: Jeder Klon erhält eine eigene Kennung des Distributed Transaction Coordinators.'
           Service = 'MSDTC'
           Apply = { [void](Invoke-NativeChecked "$env:SystemRoot\System32\msdtc.exe" @('-reset')) } }
        @{ Id = 'seal.rdsgrace'; Applies = 'RDSH'
           Title = 'RDS-Kulanzfrist zurücksetzen'
           Detail = 'Löscht den Zeitstempel (*TIMEBOMB*) unter Terminal Server\RCM\GracePeriod, damit Klone nicht mit der abgelaufenen Kulanzfrist des Master-Images starten. Besitzer und Rechte des Schlüssels werden danach wiederhergestellt. Ersetzt keine RDS-CALs – Lizenzserver und Lizenzierungsmodus müssen konfiguriert sein.'
           Apply = { Reset-RdsGracePeriod } }
        @{ Id = 'seal.perfctr'; Applies = 'All'
           Title = 'Leistungsindikatoren neu aufbauen'
           Detail = 'lodctr /r – baut die Leistungsindikatoren aus den Sicherungsdaten neu auf (beugt fehlenden/beschädigten Indikatoren in Klonen vor).'
           Apply = { [void](Invoke-NativeChecked "$env:SystemRoot\System32\lodctr.exe" @('/r')) } }
    )
}

function Test-OptApplies([string]$Applies, $Ctx) {
    $cache = [bool]($script:OptCacheDrive -and ($Ctx.Pvs -or $Ctx.Mcsio))
    switch ($Applies) {
        'PVS'       { return [bool]$Ctx.Pvs }
        'MCS'       { return [bool]$Ctx.Mcs }
        'Image'     { return [bool]($Ctx.Pvs -or $Ctx.Mcs) }
        'WEM'       { return [bool]$Ctx.Wem }
        'WEMImage'  { return [bool]($Ctx.Wem -and ($Ctx.Pvs -or $Ctx.Mcs)) }
        'VDA'       { return [bool]$Ctx.Vda }
        'VDA2019'   { return [bool]($Ctx.Vda -and $Ctx.Server2019) }
        'VMware'    { return [bool]$Ctx.VMware }
        'RDSH'      { return [bool]$Ctx.Rdsh }
        'CacheDisk' { return $cache }
        'WEMCache'  { return ($cache -and [bool]$Ctx.Wem) }
        default     { return $true }
    }
}

function New-OptItem([hashtable]$D, $Ctx) {
    [pscustomobject]@{
        Id = $D.Id; Group = $D.Group; Category = $D.Category; Title = $D.Title; Detail = $D.Detail
        Level = $D.Level; RdsRating = $D.Level; Kind = $D.Kind
        # @() direkt zuweisen – ein if-Ausdruck würde Ein-Element-Arrays entpacken (.Count fehlt dann in PS 5.1)
        Reg   = @($D.Reg | Where-Object { $null -ne $_ })
        Tasks = @($D.Tasks | Where-Object { $null -ne $_ })
        Service = "$($D.Service)"; Target = "$($D.Target)"
        Test = $D.Test; Read = $D.Read; Apply = $D.Apply; Undo = $D.Undo; Prepare = $D.Prepare; After = $D.After
        Applicable = (Test-OptApplies $D.Applies $Ctx)
        StatusText = ''; UndoText = ''; CanSelect = $false; Selected = $false; HasOriginal = $false; Tip = ''
    }
}

function Get-OptStatus($O) {
    switch ($O.Kind) {
        'Hint'     { return 'Hinweis' }
        'Registry' {
            $hit = @($O.Reg | Where-Object { Test-RegSpec $_ }).Count
            if ($hit -eq @($O.Reg).Count) { return 'Umgesetzt' }
            if ($hit -gt 0) { return 'Teilweise' }
            return 'Offen'
        }
        'Task' {
            $st = @(foreach ($t in $O.Tasks) { Get-TaskEnabled $t }) | Where-Object { $null -ne $_ }
            $st = @($st)
            if ($st.Count -eq 0) { return 'Nicht vorhanden' }
            $on = @($st | Where-Object { $_ }).Count
            if ($on -eq 0) { return 'Umgesetzt' }
            if ($on -lt $st.Count) { return 'Teilweise' }
            return 'Offen'
        }
        'Service' {
            $cfg = Read-ServiceConfig $O.Service
            if (-not $cfg) { return 'Nicht vorhanden' }
            $ok = if ($O.Target -eq 'auto') { $cfg.StartType -in 'auto', 'delayed-auto' } else { $cfg.StartType -eq $O.Target }
            if ($ok) { return 'Umgesetzt' } else { return 'Offen' }
        }
        'System' { if (& $O.Test) { return 'Umgesetzt' } else { return 'Offen' } }
    }
    return 'Offen'
}

function Update-OptItemState($O, [hashtable]$Originals) {
    $O.HasOriginal = $Originals.ContainsKey($O.Id)
    if (-not $O.Applicable) { $O.StatusText = 'Nicht zutreffend' }
    else {
        try { $O.StatusText = Get-OptStatus $O }
        catch {
            # Manche Werte (bcdedit, Netzwerk-Offload) lassen sich nur mit Adminrechten lesen
            $O.StatusText = if ($script:IsAdmin) { 'Fehler' } else { 'Nur als Admin prüfbar' }
            if ($script:IsAdmin) { Write-Log ('Status von "{0}" nicht lesbar: {1}' -f $O.Title, $_.Exception.Message) 'WARN' }
        }
    }
    $O.UndoText  = if ($O.HasOriginal) { 'Original gesichert' } else { '' }
    $O.CanSelect = $script:IsAdmin -and $O.Applicable -and $O.Kind -ne 'Hint' -and ($O.StatusText -notin 'Nicht vorhanden', 'Fehler')
    if (-not $O.CanSelect) { $O.Selected = $false }
    $O.Tip = if ($O.Kind -eq 'Hint') { 'Hinweis – wird nicht automatisch umgesetzt' }
             elseif (-not $O.Applicable) { 'Trifft auf diesen Rechner nicht zu (Komponente nicht erkannt)' }
             elseif ($O.StatusText -eq 'Nicht vorhanden') { 'Auf diesem System nicht vorhanden' }
             elseif (-not $script:IsAdmin) { 'Nur mit Administratorrechten änderbar' }
             elseif ($O.HasOriginal) { 'Ursprünglicher Zustand gesichert – rückgängig möglich' }
             else { 'Auswählen zum Anwenden' }
}

function Get-OptStoreFile { Join-Path $script:BackupDir 'rdsopt_original.json' }

function Read-OptOriginals {
    $h = @{}
    $f = Get-OptStoreFile
    if ([IO.File]::Exists($f)) {
        $o = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    }
    $h
}

function Save-OptOriginals([hashtable]$Originals) {
    [IO.File]::WriteAllText((Get-OptStoreFile), ($Originals | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
}

function Read-OptCurrentState($O) {
    switch ($O.Kind) {
        'Registry' { return @(foreach ($r in $O.Reg) { Get-RegState $r }) }
        'Task'     { return @(foreach ($t in $O.Tasks) { $e = Get-TaskEnabled $t; if ($null -ne $e) { [pscustomobject]@{ Task = $t; Enabled = $e } } }) }
        'Service'  { return [pscustomobject]@{ StartType = (Read-ServiceConfig $O.Service).StartType } }
        'System'   { return [pscustomobject]@{ Value = (& $O.Read) } }
    }
}

function Invoke-Optimization($O, [hashtable]$Originals) {
    if (-not $Originals.ContainsKey($O.Id)) {
        # Nur beim ersten Anwenden – späteres erneutes Anwenden überschreibt den Ursprung nicht
        $Originals[$O.Id] = [ordered]@{ Kind = $O.Kind; Title = $O.Title; Saved = (Get-Date).ToString('s'); State = (Read-OptCurrentState $O) }
        Save-OptOriginals $Originals
    }
    if ($O.Prepare) { & $O.Prepare }
    switch ($O.Kind) {
        'Registry' { foreach ($r in $O.Reg) { Set-RegSpec $r } }
        'Task'     { foreach ($t in $O.Tasks) { Set-TaskEnabled $t $false } }
        'Service'  { Set-ServiceStartType (New-OptServiceObject $O.Service) $O.Target }
        'System'   { & $O.Apply }
    }
    if ($O.After) { & $O.After }
    Write-Log ('OPTIMIERUNG {0} [{1}]' -f $O.Title, $O.Id)
}

function Undo-Optimization($O, [hashtable]$Originals) {
    $rec = $Originals[$O.Id]
    if (-not $rec) { throw ('Für „{0}“ ist kein ursprünglicher Zustand gesichert.' -f $O.Title) }
    $state = $rec.State
    switch ($O.Kind) {
        'Registry' { foreach ($s in @($state)) { Restore-RegState $s } }
        'Task'     { foreach ($s in @($state)) { Set-TaskEnabled "$($s.Task)" ([bool]$s.Enabled) } }
        'Service'  {
            $svc = New-OptServiceObject $O.Service
            if ($svc.StartType -ne "$($state.StartType)") { Set-ServiceStartType $svc "$($state.StartType)" }
        }
        'System'   { & $O.Undo $state.Value }
    }
    $Originals.Remove($O.Id)
    Save-OptOriginals $Originals
    Write-Log ('RÜCKGÄNGIG {0} [{1}]' -f $O.Title, $O.Id)
}

#endregion

#region Startmenü ----------------------------------------------------------------------------
# Sichtbarkeit der Einträge im gemeinsamen Startmenü (alle Benutzer):
#   Alle          – unverändert
#   Ausgeblendet  – Verknüpfung liegt in der Ablage AUSSERHALB von "Start Menu" (das Startmenü zeigt alles darunter)
#   Eingeschränkt – geschützte NTFS-Rechte: nur SYSTEM, Administratoren und die gewählten Gruppen dürfen lesen
# Ursprüngliche Rechte je Datei: backups\startmenu_original.json (nur beim ersten Einschränken gespeichert).

$script:SmRoot  = [Environment]::GetFolderPath('CommonPrograms')
$script:SmStore = Join-Path $env:ProgramData 'WindowsOptimizer\StartMenuHidden'
$script:SmExtensions = '.lnk', '.url', '.appref-ms'
$script:SmOpenSids   = 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4'      # Benutzer, Authentifizierte Benutzer, Jeder, Interaktiv
$script:SmBaseSids   = 'S-1-5-18', 'S-1-5-32-544', 'S-1-15-2-1', 'S-1-15-2-2', 'S-1-3-0',
                       'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'   # SYSTEM, Admins, App-Pakete, Ersteller, TrustedInstaller

function Get-SidName($Sid) {
    try { "$(([Security.Principal.SecurityIdentifier]"$Sid").Translate([Security.Principal.NTAccount]).Value)" } catch { "$Sid" }
}

function Get-SmAclInfo([string]$Path) {
    # Wer darf lesen? "Offen" = Benutzer/Authentifizierte/Jeder; sonst Liste der zusätzlichen Gruppen
    $acl = Get-Acl -LiteralPath $Path
    $open = $false; $groups = New-Object System.Collections.Generic.List[string]
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow' -or ([int]$r.FileSystemRights -band 1) -eq 0) { continue }   # 1 = ReadData
        $sid = $r.IdentityReference.Value
        if ($sid -in $script:SmOpenSids) { $open = $true }
        elseif ($sid -notin $script:SmBaseSids -and -not $groups.Contains($sid)) { $groups.Add($sid) }
    }
    [pscustomobject]@{ Open = $open; Groups = @($groups | ForEach-Object { Get-SidName $_ }) }
}

function Get-SmShortcutTarget([IO.FileInfo]$File) {
    try {
        if ($File.Extension -ieq '.lnk') {
            $sc = (Get-Shell).CreateShortcut($File.FullName)
            return ('{0} {1}' -f $sc.TargetPath, $sc.Arguments).Trim()
        }
        if ($File.Extension -ieq '.url') {
            $m = [regex]::Match([IO.File]::ReadAllText($File.FullName), '(?m)^URL=(.+)$')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        }
    } catch { }
    return ''
}

function New-SmEntry([string]$Kind, [string]$Name, [string]$Rel, [string]$Folder, [string]$Target, [string]$Rating, [string]$Groups) {
    [pscustomobject]@{
        Kind = $Kind; Name = $Name; RelPath = $Rel; Folder = $Folder; Target = $Target
        RdsRating = $Rating; GroupsText = $Groups
        StatusText = if ($Rating -eq 'Ausgeblendet') { 'Deaktiviert' } else { $Rating }   # graut ausgeblendete Zeilen aus
        CanSelect = ($Kind -eq 'Shortcut') -and $script:IsAdmin; Selected = $false
        Tip = if ($Kind -ne 'Shortcut') { 'Store-App – nur Anzeige (Entfernen wäre nicht umkehrbar)' }
              elseif (-not $script:IsAdmin) { 'Nur mit Administratorrechten änderbar' } else { 'Auswählen für eine Aktion oben' }
    }
}

function Get-SmFiles([string]$Dir, [string]$Rel = '') {
    # Relativen Pfad beim Durchlaufen mitführen (unabhängig von Kurz-/Langnamen des Basispfads)
    try { $files = [IO.Directory]::GetFiles($Dir); $dirs = [IO.Directory]::GetDirectories($Dir) } catch { return }
    foreach ($f in $files) {
        $n = [IO.Path]::GetFileName($f)
        [pscustomobject]@{ Info = (New-Object IO.FileInfo $f); Rel = $(if ($Rel) { "$Rel\$n" } else { $n }) }
    }
    foreach ($d in $dirs) {
        $n = [IO.Path]::GetFileName($d)
        Get-SmFiles $d $(if ($Rel) { "$Rel\$n" } else { $n })
    }
}

function Get-StartMenuEntries([string]$Root = $script:SmRoot, [string]$Store = $script:SmStore, [switch]$NoAppx) {
    $list = New-Object System.Collections.Generic.List[object]
    $active = @{}
    foreach ($src in @(@{ Dir = $Root; Hidden = $false }, @{ Dir = $Store; Hidden = $true })) {
        if (-not $src.Dir -or -not [IO.Directory]::Exists($src.Dir)) { continue }
        foreach ($item in @(Get-SmFiles $src.Dir)) {
            $f = $item.Info
            if ($f.Extension -notin $script:SmExtensions) { continue }
            $rel = $item.Rel
            if ($src.Hidden -and $active.ContainsKey($rel.ToLower())) { continue }   # aktive Verknüpfung gewinnt
            $folder = Split-Path -Parent $rel
            if (-not $folder) { $folder = '(Hauptebene)' }
            if ($src.Hidden) {
                $rating = 'Ausgeblendet'; $groups = ''
            } else {
                $active[$rel.ToLower()] = $true
                try {
                    $info = Get-SmAclInfo $f.FullName
                    if ($info.Open) { $rating = 'Alle'; $groups = '' }
                    else { $rating = 'Eingeschränkt'; $groups = if ($info.Groups.Count) { $info.Groups -join ', ' } else { 'nur Administratoren' } }
                } catch { $rating = 'Alle'; $groups = '(Rechte nicht lesbar)' }
            }
            $list.Add((New-SmEntry 'Shortcut' $f.BaseName $rel $folder (Get-SmShortcutTarget $f) $rating $groups))
        }
    }
    if (-not $NoAppx) {
        try {
            $prov = @{}
            if ($script:IsAdmin) { foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) { $prov[$p.DisplayName] = $true } }
            $pk = if ($script:IsAdmin) { @(Get-AppxPackage -AllUsers -ErrorAction Stop) } else { @(Get-AppxPackage -ErrorAction Stop) }
            foreach ($p in @($pk | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage -and "$($_.SignatureKind)" -ne 'System' } | Sort-Object Name -Unique)) {
                $where = if ($prov.ContainsKey($p.Name)) { 'Store-App (bereitgestellt für neue Benutzer)' } else { 'Store-App' }
                $list.Add((New-SmEntry 'AppX' $p.Name '' $where $p.PackageFullName 'Store-App' ''))
            }
        } catch { Write-Log ('Store-Apps nicht lesbar: {0}' -f $_.Exception.Message) 'WARN' }
    }
    return @($list | Sort-Object @{ Expression = { $_.Kind -ne 'Shortcut' } }, Folder, Name)
}

function Get-SmStoreFile { Join-Path $script:BackupDir 'startmenu_original.json' }

function Read-SmOriginals {
    $h = @{}
    $f = Get-SmStoreFile
    if ([IO.File]::Exists($f)) {
        $o = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = "$($p.Value)" } }
    }
    $h
}

function Save-SmOriginals([hashtable]$Map) {
    [IO.File]::WriteAllText((Get-SmStoreFile), ($Map | ConvertTo-Json -Depth 3), $script:Utf8NoBom)
}

function Resolve-SmGroups([string]$Text) {
    # Namen (DOMÄNE\Gruppe, lokale Gruppe) oder SIDs; unbekannte Namen werden gemeldet
    $sids = @(); $bad = @()
    foreach ($n in @($Text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        try {
            if ($n -match '^S-1-') { $sid = New-Object Security.Principal.SecurityIdentifier $n; [void]$sid.Translate([Security.Principal.NTAccount]) }
            else { $sid = (New-Object Security.Principal.NTAccount $n).Translate([Security.Principal.SecurityIdentifier]) }
            $sids += $sid
        } catch { $bad += $n }
    }
    [pscustomobject]@{ Sids = $sids; Bad = $bad }
}

function Move-SmFile([string]$From, [string]$To) {
    if (-not [IO.File]::Exists($From)) { throw ('Datei „{0}“ wurde nicht gefunden.' -f $From) }
    $dir = Split-Path -Parent $To
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    if ([IO.File]::Exists($To)) { [IO.File]::Delete($To) }
    [IO.File]::Move($From, $To)
}

function Set-StartMenuVisibility($Entry, [string]$Mode, $Sids = @(), [string]$Root = $script:SmRoot, [string]$Store = $script:SmStore) {
    $active = Join-Path $Root $Entry.RelPath
    $hidden = Join-Path $Store $Entry.RelPath
    $orig = Read-SmOriginals
    $key = $Entry.RelPath.ToLower()
    switch ($Mode) {
        'hide' {
            if ([IO.File]::Exists($active)) { Move-SmFile $active $hidden }
        }
        'show' {
            if (-not [IO.File]::Exists($active) -and [IO.File]::Exists($hidden)) { Move-SmFile $hidden $active }
            if ($orig.ContainsKey($key)) {
                $acl = [IO.File]::GetAccessControl($active)
                $acl.SetSecurityDescriptorSddlForm($orig[$key], 'Access')
                [IO.File]::SetAccessControl($active, $acl)
                $orig.Remove($key); Save-SmOriginals $orig
            } elseif (-not (Get-SmAclInfo $active).Open) {
                # Kein gespeicherter Ursprung: Vererbung vom Ordner wieder einschalten, eigene Regeln entfernen
                $acl = [IO.File]::GetAccessControl($active)
                $acl.SetAccessRuleProtection($false, $false)
                foreach ($r in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($r) }
                [IO.File]::SetAccessControl($active, $acl)
            }
        }
        'groups' {
            if (-not [IO.File]::Exists($active) -and [IO.File]::Exists($hidden)) { Move-SmFile $hidden $active }
            if (-not $orig.ContainsKey($key)) {
                $orig[$key] = ([IO.File]::GetAccessControl($active)).GetSecurityDescriptorSddlForm('Access')
                Save-SmOriginals $orig
            }
            $acl = [IO.File]::GetAccessControl($active)
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($r in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($r) }
            $add = { param($sid, $rights) $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), $rights, 'Allow'))) }
            & $add 'S-1-5-18' 'FullControl'
            & $add 'S-1-5-32-544' 'FullControl'
            & $add 'S-1-15-2-1' 'ReadAndExecute'      # Alle Anwendungspakete (Startmenü-Host) – wirkt nur zusammen mit Benutzerrechten
            & $add 'S-1-15-2-2' 'ReadAndExecute'
            foreach ($s in @($Sids)) { & $add "$s" 'ReadAndExecute' }
            [IO.File]::SetAccessControl($active, $acl)
        }
        default { throw ('Unbekannte Aktion: {0}' -f $Mode) }
    }
}

#endregion

#region Software (winget) -------------------------------------------------------------------
# Installierte Software über "winget list" (liefert Version und verfügbare Version in einem Aufruf).
# Ohne winget: Liste aus den Uninstall-Schlüsseln der Registry, ohne Update-Prüfung.
# winget läuft immer als eigener Prozess im Hintergrund (Ausgabe in Datei, Abfrage per Timer).

function Find-Winget {
    $c = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if ([IO.File]::Exists($p)) { return $p }
    # Als anderer Admin bzw. ohne App-Alias: direkt aus dem App-Installer-Paket
    $pkg = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1)
    if ($pkg.Count -and [IO.File]::Exists((Join-Path $pkg[0].FullName 'winget.exe'))) { return (Join-Path $pkg[0].FullName 'winget.exe') }
    return ''
}

function ConvertFrom-WingetTable([string]$Text) {
    # Tabelle anhand der Kopfzeile zerlegen (Spaltenstart = Position der Überschrift); sprachunabhängig
    # Zeilenende-CR entfernen; bei Fortschrittsanzeigen (…\r…) zählt nur der Text nach dem letzten CR
    $lines = @($Text -split "`n" | ForEach-Object { (($_.TrimEnd("`r") -split "`r")[-1]) -replace '[\x00-\x08]', '' })
    $sep = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -match '^-{10,}$') { $sep = $i; break } }
    if ($sep -lt 1) { return @() }
    $header = $lines[$sep - 1]
    $starts = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 3) { return @() }
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($l)) { break }
        if ($l.Length -le $starts[1]) { continue }                 # Fuß-/Hinweiszeilen
        $cells = for ($c = 0; $c -lt $starts.Count; $c++) {
            $s = $starts[$c]
            $e = if ($c + 1 -lt $starts.Count) { $starts[$c + 1] } else { $l.Length }
            if ($s -ge $l.Length) { '' } else { $l.Substring($s, [Math]::Min($e, $l.Length) - $s).Trim() }
        }
        $cells = @($cells)
        $row = [ordered]@{ Name = $cells[0]; Id = $cells[1]; Version = $cells[2]; Available = ''; Source = '' }
        if ($cells.Count -ge 5) { $row.Available = $cells[3]; $row.Source = $cells[4] }
        elseif ($cells.Count -eq 4) { $row.Source = $cells[3] }
        $rows.Add([pscustomobject]$row)
    }
    return $rows.ToArray()
}

function Get-RegistrySoftware {
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($src in @(@{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
                       @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
                       @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Uninstall' })) {
        $base = Open-BaseKey $src.Hive
        try {
            $root = $base.OpenSubKey($src.Path)
            if ($null -eq $root) { continue }
            try {
                foreach ($n in $root.GetSubKeyNames()) {
                    $k = $root.OpenSubKey($n)
                    if ($null -eq $k) { continue }
                    try {
                        $name = "$($k.GetValue('DisplayName', ''))"
                        if (-not $name -or [int]$k.GetValue('SystemComponent', 0) -eq 1 -or $k.GetValue('ParentKeyName')) { continue }
                        $ver = "$($k.GetValue('DisplayVersion', ''))"
                        if ($seen.ContainsKey("$name|$ver")) { continue }
                        $seen["$name|$ver"] = $true
                        $list.Add([pscustomobject]@{ Name = $name; Id = ''; Version = $ver; Available = ''; Source = '' })
                    } finally { $k.Close() }
                }
            } finally { $root.Close() }
        } finally { $base.Close() }
    }
    return $list.ToArray()
}

function Test-UnknownVersion([string]$Version) { return (-not $Version -or $Version -match '^(Unknown|Unbekannt)$' -or $Version.StartsWith('<')) }

function New-SwEntry($Row, [hashtable]$Results) {
    $hasUpdate = [bool]($Row.Available -and $Row.Id -and $Row.Source -and $Row.Id -notmatch '…')
    $status = if (-not $Row.Source) { 'Nicht über winget' } elseif ($hasUpdate) { 'Update verfügbar' } else { 'Aktuell' }
    $detail = switch ($status) {
        'Nicht über winget' { 'Kein passendes Paket in einer winget-Quelle – Aktualisierung über den Hersteller.' }
        'Update verfügbar'  { 'Version {0} → {1}' -f $Row.Version, $Row.Available }
        default             { 'Keine neuere Version in der Quelle {0}.' -f $Row.Source }
    }
    if ($hasUpdate -and $Results -and $Results.ContainsKey($Row.Id)) { $status = 'Fehler'; $detail = $Results[$Row.Id] }
    [pscustomobject]@{
        Name = $Row.Name; Id = $Row.Id; Version = $Row.Version; Available = $Row.Available; Source = $Row.Source
        HasUpdate = $hasUpdate
        InAll = $hasUpdate -and $Row.Source -eq 'winget' -and -not (Test-UnknownVersion $Row.Version)   # „Alle Updates“: nur Quelle winget, bekannte Version
        RdsRating = $status; StatusText = $status; Tip = $detail
        CanSelect = $hasUpdate -and $script:IsAdmin; Selected = $false
    }
}

function Read-SharedText([string]$Path) {
    # Die Ausgabedatei kann noch von Kindprozessen gehalten werden (Installer, neu gestartete Programme
    # erben das Handle) – daher mit geteiltem Zugriff lesen statt exklusiv
    if (-not [IO.File]::Exists($Path)) { return '' }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}

function Invoke-WingetAsync([string[]]$Arguments, [scriptblock]$OnExit) {
    # winget als eigener Prozess; Ergebnis über $OnExit (ExitCode, Ausgabe) nach Prozessende
    if ($script:WgJob) { throw 'Es läuft bereits ein winget-Vorgang.' }
    # Reste früherer Läufe (beim Lesen noch gesperrt gewesen) aufräumen
    Get-ChildItem -LiteralPath $env:TEMP -Filter 'winopt_wg_*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $out = Join-Path $env:TEMP ('winopt_wg_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $p = Start-Process -FilePath $script:WingetPath -ArgumentList $Arguments -NoNewWindow -PassThru `
                       -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle   # nötig, damit ExitCode später verfügbar ist
    $script:WgJob = @{ Proc = $p; Out = $out; OnExit = $OnExit }
    $script:WgTimer.Start()
}

function Test-WingetJob {
    $j = $script:WgJob
    if (-not $j) { $script:WgTimer.Stop(); return }
    if (-not $j.Proc.HasExited) {
        # Während eines Updates: Fortschritt aus der laufenden winget-Ausgabe anzeigen
        if ($script:SwQueue) {
            $pct = -1
            try { $pct = Get-WingetProgress (Read-SharedText $j.Out) } catch { }
            Update-SwProgress $pct
        }
        return
    }
    $script:WgTimer.Stop()
    $script:WgJob = $null
    $code = $j.Proc.ExitCode
    $text = ''
    foreach ($f in $j.Out, "$($j.Out).err") {
        try { $text += (Read-SharedText $f) + "`n" }
        catch { Write-Log ('winget-Ausgabe nicht lesbar ({0}): {1}' -f $f, $_.Exception.Message) 'WARN' }
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue   # noch gesperrt: wird beim nächsten Lauf aufgeräumt
    }
    # Rückruf immer ausführen, sonst bleibt eine laufende Warteschlange bzw. die Ladeanzeige hängen
    & $j.OnExit $code $text
}

function Get-WingetProgress([string]$Text) {
    # Prozent der letzten Fortschrittsanzeige („… 40%“ oder „… 2.00 MB / 10.0 MB“); -1 = unbekannt
    if (-not $Text) { return -1 }
    $last = (($Text.TrimEnd() -split "[`r`n]") | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if (-not $last) { return -1 }
    $m = [regex]::Match($last, '(\d{1,3})\s*%')
    if ($m.Success) { return [Math]::Min(100, [int]$m.Groups[1].Value) }
    $m = [regex]::Match($last, '([\d.,]+)\s*(KB|MB|GB)\s*/\s*([\d.,]+)\s*(KB|MB|GB)')
    if ($m.Success) {
        $f = @{ KB = 1KB; MB = 1MB; GB = 1GB }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $a = [double]::Parse($m.Groups[1].Value.Replace(',', '.'), $inv) * $f[$m.Groups[2].Value]
        $b = [double]::Parse($m.Groups[3].Value.Replace(',', '.'), $inv) * $f[$m.Groups[4].Value]
        if ($b -gt 0) { return [int][Math]::Min(100, [Math]::Floor($a * 100 / $b)) }
    }
    return -1
}

function Get-WingetErrorText([int]$Code, [string]$Text) {
    $known = @{
        -1978335189 = 'Kein anwendbares Update (z. B. andere Installationsart oder Architektur)'
        -1978335212 = 'Paket nicht gefunden'
        -1978335226 = 'Installationsprogramm meldet Fehler'
        -1978334967 = 'Neustart erforderlich, um die Installation abzuschließen'
        -1978335135 = 'Paket wird gerade verwendet (Programm schließen)'
    }
    $msg = if ($known.ContainsKey($Code)) { $known[$Code] } else { 'Fehler' }
    $tail = @($Text -split "`n" | ForEach-Object { (($_.TrimEnd("`r") -split "`r")[-1]).Trim() } | Where-Object { $_ -and $_ -notmatch '^[\-\\|/ █▒]+$' } | Select-Object -Last 2) -join ' / '
    '{0} (Code 0x{1:X8}){2}' -f $msg, $Code, $(if ($tail) { ': ' + $tail } else { '' })
}

#endregion

#region Sicherung und Wiederherstellung ----------------------------------------------------

function Export-RegBackup([string]$Target, [string[]]$Keys = @()) {
    # Sicherheitsnetz: .reg-Export aller beteiligten Schlüssel (per Doppelklick wieder einspielbar)
    # Ohne -Keys: Autostart-Schlüssel; die RDS-Optimierung übergibt ihre eigenen Schlüssel.
    $ErrorActionPreference = 'Continue'
    if ($Keys.Count -eq 0) { $Keys = @(
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
        "HKCU\$($script:ApprovedPath)\Run"
        "HKCU\$($script:ApprovedPath)\StartupFolder"
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        "HKLM\$($script:ApprovedPath)\Run"
        "HKLM\$($script:ApprovedPath)\Run32"
        "HKLM\$($script:ApprovedPath)\StartupFolder"
    ) }
    $sb  = New-Object System.Text.StringBuilder
    [void]$sb.Append("Windows Registry Editor Version 5.00`r`n")
    $tmp = [IO.Path]::GetTempFileName()
    try {
        foreach ($k in $Keys) {
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
    $entries  = @(Get-AutostartEntries)
    $services = @(Get-ServiceEntries | Where-Object { -not $_.IsInstance -and $_.StartType -notin 'boot', 'system' })
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base  = Join-Path $script:BackupDir "autostart_$stamp"
    $n = 2
    while (Test-Path -LiteralPath "$base.json") { $base = Join-Path $script:BackupDir ('autostart_{0}_{1}' -f $stamp, $n); $n++ }

    $data = [ordered]@{
        Format   = 'WindowsOptimizer-Backup'
        Version  = 2
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
        # Ab Version 2: Starttyp je Dienst
        Services = @(foreach ($s in $services) {
            [ordered]@{ Name = $s.Name; DisplayName = $s.DisplayName; StartType = $s.StartType }
        })
    }
    [IO.File]::WriteAllText("$base.json", ($data | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
    try { Export-RegBackup "$base.reg" } catch { Write-Log ('.reg-Export fehlgeschlagen: {0}' -f $_.Exception.Message) 'WARN' }
    Write-Log ('SICHERUNG   {0} ({1} Einträge, {2} Dienste, Anlass: {3})' -f (Split-Path -Leaf "$base.json"), $entries.Count, $services.Count, $Reason)
    return "$base.json"
}

function Read-BackupFile([string]$Path) {
    $b = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    # Auch Sicherungen der Vorgängerversion (Autostart-Manager) bleiben lesbar
    if ($b.Format -notin 'WindowsOptimizer-Backup', 'AutostartManager-Backup') { throw 'Die Datei ist keine gültige Sicherung des Windows-Optimizers.' }
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

function Get-RestorePlan($Backup, $Current, $CurrentServices = @()) {
    # Dienste (nur Sicherungen ab Version 2)
    if ($Backup.Services) {
        $svcMap = @{}
        foreach ($c in $CurrentServices) { $svcMap[$c.Name] = $c }
        foreach ($b in @($Backup.Services)) {
            if (-not $script:StartTypeText.Contains("$($b.StartType)")) { continue }
            $cur = $svcMap[$b.Name]
            $label = 'Dienst'
            # Nicht mehr vorhandene Dienste (z. B. deinstalliert) werden still übergangen
            if (-not $cur -or $cur.StartType -eq $b.StartType) { continue }
            $can = $true; $reason = ''
            if (-not $script:IsAdmin) { $can = $false; $reason = 'Administratorrechte nötig' }
            elseif ($cur.IsInstance)  { $can = $false; $reason = 'Benutzerdienst-Instanz' }
            [pscustomobject]@{ Kind = 'Service'; Action = ('Starttyp → {0}' -f $script:StartTypeText["$($b.StartType)"])
                               Name = $cur.DisplayName; Label = $label; Backup = $b; Service = $cur; CanApply = $can; Reason = $reason }
        }
    }

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
                           Current = $cur; CanApply = $can; Reason = $reason }
    }
}

function Invoke-RestoreItem($Item) {
    if ($Item.Kind -eq 'Service') { Set-ServiceStartType $Item.Service ([string]$Item.Backup.StartType); return }
    $b = $Item.Backup
    $src = $Item.Source
    if ($Item.Action -ne 'Neu anlegen') { Set-EntryState $Item.Current ([bool]$b.Enabled); return }

    # Fehlender Eintrag: aktiv -> in Run/Autostart-Ordner, deaktiviert -> direkt in die Ablage
    $enabled = [bool]$b.Enabled
    if ($src.Kind -eq 'Registry') {
        $kind = if ($b.ValueKind -eq 'ExpandString') { [Microsoft.Win32.RegistryValueKind]::ExpandString } else { [Microsoft.Win32.RegistryValueKind]::String }
        $path = if ($enabled) { $src.Path } else { Get-StoreLocation $src }
        $base = Open-BaseKey $src.Hive
        try {
            $key = $base.CreateSubKey($path)
            try { $key.SetValue($b.ValueName, [string]$b.Command, $kind) } finally { $key.Close() }
        } finally { $base.Close() }
    } else {
        $folder = if ($enabled) { $src.Path } else { Get-StoreLocation $src }
        if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }
        $sc = (Get-Shell).CreateShortcut((Join-Path $folder $b.ValueName))
        $sc.TargetPath = $b.LnkTarget
        $sc.Arguments = "$($b.LnkArgs)"
        $sc.WorkingDirectory = "$($b.LnkWorkDir)"
        $sc.Save()
    }
    if ($enabled -and -not (Test-ApprovedEnabled (Get-ApprovedBytes $src.Hive $src.Approved $b.ValueName))) {
        Set-ApprovedState $src.Hive $src.Approved $b.ValueName $true
    }
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
    [void][Windows.MessageBox]::Show($script:Window, $Text, $script:AppName, 'OK', $Icon)
}

function Confirm-Action([string]$Text) {
    ([Windows.MessageBox]::Show($script:Window, $Text, $script:AppName, 'YesNo', 'Question') -eq 'Yes')
}

function New-AppIcon([int]$Size = 256) {
    # App-Symbol zur Laufzeit gezeichnet (keine Zusatzdatei): Teal-Kachel mit Tachometer = "optimieren"
    $c = { param($r, $g, $b) [Windows.Media.Color]::FromRgb($r, $g, $b) }
    $k = $Size / 64.0
    $P = { param($x, $y) New-Object Windows.Point ($x * $k), ($y * $k) }
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $bg = New-Object Windows.Media.LinearGradientBrush((& $c 0x5D 0xB4 0xBE), (& $c 0x1F 0x6F 0x78), 60)
    $dc.DrawRoundedRectangle($bg, $null, (New-Object Windows.Rect (2 * $k), (2 * $k), (60 * $k), (60 * $k)), (14 * $k), (14 * $k))

    $arc = {
        param($fromDeg, $toDeg, $brush, $large)
        $cx = 32; $cy = 38; $r = 19
        $a1 = $fromDeg * [Math]::PI / 180; $a2 = $toDeg * [Math]::PI / 180
        $fig = New-Object Windows.Media.PathFigure
        $fig.StartPoint = & $P ($cx + $r * [Math]::Cos($a1)) ($cy - $r * [Math]::Sin($a1))
        $seg = New-Object Windows.Media.ArcSegment((& $P ($cx + $r * [Math]::Cos($a2)) ($cy - $r * [Math]::Sin($a2))),
                   (New-Object Windows.Size ($r * $k), ($r * $k)), 0, $large, [Windows.Media.SweepDirection]::Clockwise, $true)
        $fig.Segments.Add($seg)
        $geo = New-Object Windows.Media.PathGeometry
        $geo.Figures.Add($fig)
        $pen = New-Object Windows.Media.Pen($brush, (6 * $k))
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'
        $dc.DrawGeometry($null, $pen, $geo)
    }
    $white = [Windows.Media.Brushes]::White
    $faint = New-Object Windows.Media.SolidColorBrush((& $c 0xFF 0xFF 0xFF)); $faint.Opacity = 0.35
    & $arc 210 330 $faint $true    # ganze Skala (330° = -30°)
    & $arc 210 50 $white $false    # Füllstand

    $needle = New-Object Windows.Media.Pen($white, (4.5 * $k))
    $needle.StartLineCap = 'Round'; $needle.EndLineCap = 'Round'
    $a = 50 * [Math]::PI / 180
    $dc.DrawLine($needle, (& $P 32 38), (& $P (32 + 13 * [Math]::Cos($a)) (38 - 13 * [Math]::Sin($a))))
    $dc.DrawEllipse($white, $null, (& $P 32 38), (5 * $k), (5 * $k))
    $dc.Close()

    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $bmp.Freeze()
    $bmp
}

function Set-AppUserModelId([string]$Id) {
    # Eigene Taskleisten-Gruppe, sonst zeigt Windows das Fenster unter dem PowerShell-Symbol
    try {
        Add-Type -Namespace WinOpt -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);'
        [void][WinOpt.Shell]::SetCurrentProcessExplicitAppUserModelID($Id)
    } catch {
        Write-Log ('AppUserModelID nicht gesetzt: {0}' -f $_.Exception.Message) 'WARN'
    }
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
    if ($script:UI.PageServices.Visibility -eq 'Visible') { Update-ServiceCounts }
    elseif ($script:UI.PageOptimize.Visibility -eq 'Visible') { Update-OptCounts }
    elseif ($script:UI.PageStartMenu.Visibility -eq 'Visible') { Update-SmCounts }
    elseif ($script:UI.PageSoftware.Visibility -eq 'Visible') { Update-SwCounts }
    else { $script:UI.TxtCounts.Text = '{0} Einträge  ·  {1} aktiv  ·  {2} deaktiviert' -f $all.Count, $on, ($all.Count - $on) }
    $script:UI.TxtEmpty.Visibility = if ($script:View.IsEmpty) { 'Visible' } else { 'Collapsed' }
    $locked = @($all | Where-Object { -not $_.CanModify }).Count
    $script:UI.AdminHint.Visibility = if ($locked -gt 0) { 'Visible' } else { 'Collapsed' }
    $weak = @($all | Where-Object { $_.ApprovedOff })
    $script:UI.ApprovedHint.Visibility = if ($weak.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $script:UI.TxtApprovedHint.Text = '{0} Eintrag/Einträge sind nur per Task-Manager gesperrt und können trotzdem starten.' -f $weak.Count
    $script:UI.BtnFixApproved.Content = 'Endgültig deaktivieren ({0})' -f @($weak | Where-Object { $_.CanModify }).Count
    $script:UI.BtnFixApproved.IsEnabled = (@($weak | Where-Object { $_.CanModify }).Count -gt 0)
}

function Invoke-FixApproved {
    # Alte Sperren (nur StartupApproved) auf die Ablage-Methode umstellen
    $weak = @($script:Entries | Where-Object { $_.ApprovedOff -and $_.CanModify })
    if ($weak.Count -eq 0) { return }
    $nl = [Environment]::NewLine
    $names = ($weak | Select-Object -First 15 | ForEach-Object { '   {0}  [{1}]' -f $_.Name, $_.SourceLabel }) -join $nl
    if ($weak.Count -gt 15) { $names += '{0}   … und {1} weitere' -f $nl, ($weak.Count - 15) }
    $q = 'Diese Einträge sind nur per Task-Manager gesperrt:{0}{0}{1}{0}{0}Jetzt endgültig deaktivieren (in die Ablage verschieben)? Einschalten ist jederzeit wieder möglich.' -f $nl, $names
    if (-not (Confirm-Action $q)) { return }
    Invoke-SessionBackup
    $ok = 0; $fail = 0
    foreach ($e in $weak) {
        try { Set-EntryState $e $false; $ok++ }
        catch { $fail++; Write-Log ('Endgültiges Deaktivieren von "{0}" fehlgeschlagen: {1}' -f $e.Name, $_.Exception.Message) 'FEHLER' }
    }
    $script:View.Refresh()
    Update-Counts
    Set-Status ('{0} Eintrag/Einträge endgültig deaktiviert{1}.' -f $ok, $(if ($fail) { ", $fail fehlgeschlagen (siehe Protokoll)" } else { '' }))
    if ($fail) { Show-Message ('{0} Eintrag/Einträge konnten nicht umgestellt werden – Details im Protokoll.' -f $fail) 'Warning' }
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
        $note = if ($want) { '' } else { (' – verschoben in die Ablage „{0}“, Windows startet ihn nicht mehr' -f $script:StoreName) }
        Set-Status ('"{0}" {1}{2}.' -f $Entry.Name, $state, $note)
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

function Update-ServiceCounts {
    $all = @($script:Services)
    $auto = @($all | Where-Object { $_.StartType -in 'auto', 'delayed-auto' }).Count
    $man  = @($all | Where-Object { $_.StartType -eq 'demand' }).Count
    $off  = @($all | Where-Object { $_.StartType -eq 'disabled' }).Count
    $script:UI.TxtCounts.Text = '{0} Dienste  ·  {1} automatisch  ·  {2} manuell  ·  {3} deaktiviert' -f $all.Count, $auto, $man, $off
    $script:UI.TxtSvcEmpty.Visibility  = if ($script:ServicesLoaded -and $script:SvcView.IsEmpty) { 'Visible' } else { 'Collapsed' }
    $script:UI.SvcAdminHint.Visibility = if ($script:ServicesLoaded -and -not $script:IsAdmin) { 'Visible' } else { 'Collapsed' }
}

function Update-ServiceList {
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $items = @(Get-ServiceEntries)
        $script:Services.Clear()
        foreach ($s in $items) { $script:Services.Add($s) }
        $script:ServicesLoaded = $true
    } finally { $script:Window.Cursor = $null }
    Update-ServiceCounts
    Set-Status ('Dienste eingelesen um {0}' -f (Get-Date -Format 'HH:mm:ss'))
}

function Request-ServiceList {
    # Verzögert, damit die Seite sofort erscheint (WMI braucht einen Moment)
    $script:UI.TxtSvcLoading.Visibility = 'Visible'
    Set-Status 'Dienste werden gelesen …'
    [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
        Invoke-Guarded {
            try { Update-ServiceList } finally { $script:UI.TxtSvcLoading.Visibility = 'Collapsed' }
        }
    })
}

function Test-ServiceFilter($Item) {
    switch ($script:SvcFilter) {
        'auto'   { if ($Item.StartType -notin 'auto', 'delayed-auto') { return $false } }
        'manual' { if ($Item.StartType -ne 'demand') { return $false } }
        'off'    { if ($Item.StartType -ne 'disabled') { return $false } }
    }
    $q = $script:SvcSearch
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $hay = '{0} {1} {2} {3} {4}' -f $Item.Name, $Item.DisplayName, $Item.Description, $Item.RdsRating, $Item.RdsText
    return ($hay.IndexOf($q.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Invoke-StartTypeChange($Combo, $Svc, [string]$NewText) {
    $code = @($script:StartTypeText.Keys | Where-Object { $script:StartTypeText[$_] -eq $NewText })[0]
    $revert = { $Combo.SetCurrentValue([Windows.Controls.Primitives.Selector]::SelectedItemProperty, $Svc.StartTypeText) }
    if (-not $code) { & $revert; return }
    if ($code -eq 'disabled' -and $Svc.RdsRating -eq 'Benötigt') {
        $q = '„{0}“ ist für Citrix-RDS-Hosts als benötigt eingestuft:{1}{2}{1}{1}Trotzdem deaktivieren?' -f $Svc.DisplayName, [Environment]::NewLine, $Svc.RdsText
        if (-not (Confirm-Action $q)) { & $revert; return }
    }
    try {
        Invoke-SessionBackup
        Set-ServiceStartType $Svc $code
        $note = if ($Svc.IsTemplate) { ' (wirksam nach Neustart)' } else { '' }
        Set-Status ('„{0}“: Starttyp {1}{2}.' -f $Svc.DisplayName, $Svc.StartTypeText, $note)
    } catch {
        & $revert
        Write-Log ('Starttyp von "{0}" nicht geändert: {1}' -f $Svc.Name, $_.Exception.Message) 'FEHLER'
        Show-Message $_.Exception.Message 'Warning'
    }
    # Nach dem Ereignis neu zeichnen (nicht während die ComboBox noch ihr SelectionChanged verarbeitet)
    [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
        $script:SvcView.Refresh()
        Update-ServiceCounts
    })
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
    $curSvc  = if ($backup.Services) { @(Get-ServiceEntries) } else { @() }
    $plan    = @(Get-RestorePlan $backup $current $curSvc)
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
    if ($script:ServicesLoaded) { Update-ServiceList }
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

function New-DetectCard([string]$Title, [bool]$Found, [string]$Detail, [string]$Missing) {
    $dot   = if ($Found) { '#5DB47F' } else { '#C3C6C8' }
    $state = if ($Found) { 'erkannt' } else { 'nicht erkannt' }
    $color = if ($Found) { '#1F6F78' } else { '#878B8E' }
    $text  = if ($Found) { $Detail } else { $Missing }
    $x = '<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="White" BorderBrush="#E3E3DF" BorderThickness="1" CornerRadius="4" Padding="10,7" Margin="0,0,8,8" Width="168" ToolTip="{4}"><StackPanel><StackPanel Orientation="Horizontal"><Ellipse Width="8" Height="8" Fill="{0}" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock Text="{1}" FontWeight="SemiBold"/></StackPanel><TextBlock Text="{2}" Foreground="{3}" FontSize="12" Margin="16,1,0,0"/><TextBlock Text="{4}" Foreground="#80858A" FontSize="11.5" TextTrimming="CharacterEllipsis" Margin="16,3,0,0"/></StackPanel></Border>' -f $dot, (ConvertTo-XamlText $Title), $state, $color, (ConvertTo-XamlText (($text -split "`n")[0]))
    $card = [Windows.Markup.XamlReader]::Parse($x)
    $card.ToolTip = $text
    $card
}

function Show-OptEnvironment($Ctx) {
    $p = $script:UI.OptDetect
    $p.Children.Clear()
    [void]$p.Children.Add((New-DetectCard 'Citrix VDA' $Ctx.Vda $Ctx.VdaText 'Kein Citrix Virtual Delivery Agent gefunden'))
    [void]$p.Children.Add((New-DetectCard 'WEM-Agent'  $Ctx.Wem $Ctx.WemText 'Workspace Environment Management Agent nicht installiert'))
    [void]$p.Children.Add((New-DetectCard 'PVS-Target' $Ctx.Pvs $Ctx.PvsText 'Provisioning-Target-Device-Software nicht installiert'))
    [void]$p.Children.Add((New-DetectCard 'MCS'        $Ctx.Mcs $Ctx.McsText 'Keine Machine-Creation-Services-Komponenten gefunden'))
    [void]$p.Children.Add((New-DetectCard 'Plattform'  $true    $Ctx.PlatformText ''))
    $script:UI.OptPvsHint.Visibility = if ($Ctx.ImageReadOnly) { 'Visible' } else { 'Collapsed' }
}

function Update-OptDriveList {
    # Feste Laufwerke außer dem Systemlaufwerk; Vorauswahl: Name mit "Cache", sonst das erste weitere Laufwerk
    $cmb = $script:UI.CmbOptCacheDrive
    $script:OptDriveLoading = $true
    try {
        $cmb.Items.Clear()
        $none = New-Object Windows.Controls.ComboBoxItem -Property @{ Content = '(keins)'; Tag = '' }
        [void]$cmb.Items.Add($none)
        $drives = @(Get-CimSafe 'Win32_LogicalDisk' 'DriveType=3' | Where-Object { $_.DeviceID -ne $env:SystemDrive } | Sort-Object DeviceID)
        $pick = $null
        foreach ($d in $drives) {
            $label = '{0}  {1}  ({2} frei)' -f $d.DeviceID, $(if ($d.VolumeName) { $d.VolumeName } else { 'ohne Namen' }), (Format-Size ([double]$d.FreeSpace))
            $item = New-Object Windows.Controls.ComboBoxItem -Property @{ Content = $label; Tag = "$($d.DeviceID)" }
            [void]$cmb.Items.Add($item)
            if ($script:OptCacheDrive -eq $d.DeviceID) { $pick = $item }
        }
        if (-not $pick -and $null -eq $script:OptCacheDrive) {
            $pick = @($cmb.Items | Where-Object { $_.Tag -and "$($_.Content)" -match 'cache|wcd|persist' })[0]
            if (-not $pick -and $cmb.Items.Count -gt 1) { $pick = $cmb.Items[1] }
        }
        if (-not $pick) { $pick = $none }
        $cmb.SelectedItem = $pick
        $script:OptCacheDrive = "$($pick.Tag)"
    } finally { $script:OptDriveLoading = $false }
}

function Update-OptCounts {
    $items = @($script:OptItems)
    $rel  = @($items | Where-Object { $_.Applicable -and $_.Kind -ne 'Hint' -and $_.StatusText -ne 'Nicht vorhanden' })
    $done = @($rel | Where-Object { $_.StatusText -eq 'Umgesetzt' }).Count
    $open = @($rel | Where-Object { $_.StatusText -in 'Offen', 'Teilweise' }).Count
    $sel  = @($items | Where-Object { $_.Selected }).Count
    $undo = @($items | Where-Object { $_.Selected -and $_.HasOriginal }).Count
    $script:UI.TxtCounts.Text = '{0} zutreffend  ·  {1} umgesetzt  ·  {2} offen  ·  {3} ausgewählt' -f $rel.Count, $done, $open, $sel
    $script:UI.TxtOptEmpty.Visibility  = if ($script:OptLoaded -and $script:OptView.IsEmpty) { 'Visible' } else { 'Collapsed' }
    $script:UI.OptAdminHint.Visibility = if ($script:OptLoaded -and -not $script:IsAdmin) { 'Visible' } else { 'Collapsed' }
    $script:UI.BtnOptApply.Content   = 'Anwenden ({0})' -f $sel
    $script:UI.BtnOptApply.IsEnabled = ($sel -gt 0)
    $script:UI.BtnOptUndo.Content    = 'Rückgängig ({0})' -f $undo
    $script:UI.BtnOptUndo.IsEnabled  = ($undo -gt 0)
}

function Update-OptimizationList {
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        if ($script:UI.CmbOptCacheDrive.Items.Count -eq 0) { Update-OptDriveList }
        $ctx = Get-CitrixEnvironment
        $script:CitrixEnv = $ctx
        Update-OptTaskCache
        Show-OptEnvironment $ctx
        $orig = Read-OptOriginals
        $keep = @{}
        foreach ($o in $script:OptItems) { $keep[$o.Id] = $o.Selected }
        $items = @(foreach ($d in (Get-OptimizationCatalog $ctx)) { New-OptItem $d $ctx })
        foreach ($o in $items) {
            Update-OptItemState $o $orig
            if ($o.CanSelect) {
                # Vorauswahl: empfohlen und noch offen; beim Neu-Prüfen bleibt die Auswahl erhalten
                $o.Selected = if ($keep.ContainsKey($o.Id)) { [bool]$keep[$o.Id] } else { $o.Level -eq 'Empfohlen' -and $o.StatusText -in 'Offen', 'Teilweise' }
            }
        }
        $script:OptItems.Clear()
        foreach ($o in $items) { $script:OptItems.Add($o) }
        $script:OptLoaded = $true
        Update-SealInfo
    } finally { $script:Window.Cursor = $null }
    Update-OptCounts
    Set-Status ('RDS-Optimierungen geprüft um {0}' -f (Get-Date -Format 'HH:mm:ss'))
}

function Request-OptimizationList {
    $script:UI.TxtOptLoading.Visibility = 'Visible'
    Set-Status 'Citrix-Komponenten und Optimierungen werden geprüft …'
    [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
        Invoke-Guarded {
            try { Update-OptimizationList } finally { $script:UI.TxtOptLoading.Visibility = 'Collapsed' }
        }
    })
}

function Test-OptFilter($Item) {
    switch ($script:OptFilter) {
        'applicable' { return [bool]$Item.Applicable }
        'open'       { return ($Item.Applicable -and $Item.StatusText -in 'Offen', 'Teilweise') }
        'done'       { return ($Item.StatusText -eq 'Umgesetzt') }
    }
    return $true
}

function Set-OptSelection([string]$Mode) {
    foreach ($o in $script:OptItems) {
        if (-not $o.CanSelect) { continue }
        $o.Selected = ($Mode -eq 'recommended') -and $o.Level -eq 'Empfohlen' -and $o.StatusText -in 'Offen', 'Teilweise'
    }
    $script:OptView.Refresh()
    Update-OptCounts
}

function Invoke-OptimizationRun([bool]$Undo) {
    $sel = @($script:OptItems | Where-Object { $_.Selected -and $_.CanSelect -and (-not $Undo -or $_.HasOriginal) })
    if ($sel.Count -eq 0) { Set-Status 'Keine passenden Punkte ausgewählt.'; return }
    $nl = [Environment]::NewLine
    $names = ($sel | Select-Object -First 15 | ForEach-Object { '   {0}  [{1}]' -f $_.Title, $_.Group }) -join $nl
    if ($sel.Count -gt 15) { $names += '{0}   … und {1} weitere' -f $nl, ($sel.Count - 15) }
    $verb = if ($Undo) { 'rückgängig machen (ursprünglicher Zustand wird wiederhergestellt)' } else { 'anwenden' }
    $warn = ''
    if (-not $Undo -and $script:CitrixEnv.ImageReadOnly) { $warn += '{0}{0}Achtung: Dieses System läuft von einem nicht-persistenten Image (PVS-Standard-Modus bzw. MCS) – Änderungen gehen beim nächsten Neustart verloren.' -f $nl }
    $q = '{0} Optimierung(en) {1}?{2}{2}{3}{4}{2}{2}Vorher wird automatisch gesichert. Einige Einstellungen wirken erst nach einem Neustart.' -f $sel.Count, $verb, $nl, $names, $warn
    if (-not (Confirm-Action $q)) { return }

    Invoke-SessionBackup
    if (-not $Undo) {
        $keys = @($sel | Where-Object { $_.Kind -eq 'Registry' } | ForEach-Object { $_.Reg } | ForEach-Object { 'HKLM\' + $_.Path } | Select-Object -Unique)
        if ($keys.Count -gt 0) {
            $target = Join-Path $script:BackupDir ('rdsopt_{0}.reg' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            try { Export-RegBackup $target $keys } catch { Write-Log ('.reg-Export (RDS-Optimierung) fehlgeschlagen: {0}' -f $_.Exception.Message) 'WARN' }
        }
    }
    $orig = Read-OptOriginals
    $ok = 0; $fail = 0
    foreach ($o in $sel) {
        try {
            if ($Undo) { Undo-Optimization $o $orig } else { Invoke-Optimization $o $orig }
            $o.Selected = $false
            $ok++
        } catch {
            $fail++
            Write-Log ('{0} von "{1}" fehlgeschlagen: {2}' -f $(if ($Undo) { 'Rückgängig' } else { 'Optimierung' }), $o.Title, $_.Exception.Message) 'FEHLER'
        }
    }
    if (@($sel | Where-Object { $_.Kind -eq 'Service' }).Count -gt 0) { $script:ServicesLoaded = $false }   # Dienste-Seite neu lesen
    foreach ($o in $script:OptItems) { Update-OptItemState $o $orig }
    $script:OptView.Refresh()
    Update-OptCounts
    $done = if ($Undo) { 'rückgängig gemacht' } else { 'angewendet' }
    Set-Status ('{0} Optimierung(en) {1}{2}. Einige Einstellungen wirken erst nach einem Neustart.' -f $ok, $done, $(if ($fail) { ", $fail fehlgeschlagen (siehe Protokoll)" } else { '' }))
    if ($fail) { Show-Message ('{0} Punkt(e) konnten nicht umgesetzt werden – Details im Protokoll.' -f $fail) 'Warning' }
}

function Update-SwCounts {
    $all = @($script:SwEntries)
    $upd = @($all | Where-Object { $_.HasUpdate }).Count
    $unm = @($all | Where-Object { -not $_.Source }).Count
    $sel = @($all | Where-Object { $_.Selected }).Count
    $inAll = @($all | Where-Object { $_.InAll }).Count
    $script:UI.TxtCounts.Text = '{0} Programme  ·  {1} Updates verfügbar  ·  {2} nicht über winget  ·  {3} ausgewählt' -f $all.Count, $upd, $unm, $sel
    $running = [bool]$script:SwQueue
    $script:UI.TxtSwEmpty.Visibility    = if ($script:SwLoaded -and $script:SwView.IsEmpty) { 'Visible' } else { 'Collapsed' }
    $script:UI.SwAdminHint.Visibility   = if ($script:SwLoaded -and -not $script:IsAdmin -and $script:WingetPath) { 'Visible' } else { 'Collapsed' }
    $script:UI.SwWingetHint.Visibility  = if ($script:SwLoaded -and -not $script:WingetPath) { 'Visible' } else { 'Collapsed' }
    $script:UI.BtnSwUpdateSel.Content   = 'Ausgewählte aktualisieren ({0})' -f $sel
    $script:UI.BtnSwUpdateSel.IsEnabled = ($sel -gt 0) -and -not $running
    $script:UI.BtnSwUpdateAll.Content   = 'Alle Updates installieren ({0})' -f $inAll
    $script:UI.BtnSwUpdateAll.IsEnabled = ($inAll -gt 0) -and $script:IsAdmin -and -not $running
    $script:UI.BtnSwRefresh.IsEnabled   = -not $running -and -not $script:WgJob
    $script:UI.BtnSwCancel.Visibility   = if ($running) { 'Visible' } else { 'Collapsed' }
}

function Request-SoftwareList {
    # Liste laden; mit winget im Hintergrund (Oberfläche bleibt bedienbar)
    if ($script:WgJob) { return }
    $script:UI.TxtSwLoading.Visibility = 'Visible'
    $script:WingetPath = Find-Winget
    if (-not $script:WingetPath) {
        try { Set-SoftwareList @(Get-RegistrySoftware) } finally { $script:UI.TxtSwLoading.Visibility = 'Collapsed' }
        Set-Status 'winget nicht gefunden – Software aus der Registry gelesen (ohne Update-Prüfung).'
        return
    }
    Set-Status 'Installierte Software und Updates werden über winget geprüft …'
    Update-SwCounts
    Invoke-WingetAsync @('list', '--accept-source-agreements', '--disable-interactivity') {
        param($code, $text)
        $script:UI.TxtSwLoading.Visibility = 'Collapsed'
        $rows = @(ConvertFrom-WingetTable $text)
        if ($rows.Count -eq 0) {
            Write-Log ('winget list ohne verwertbare Ausgabe (Code 0x{0:X8}) – Registry wird verwendet.' -f $code) 'WARN'
            $rows = @(Get-RegistrySoftware)
            Set-Status 'winget lieferte keine Liste – Software aus der Registry gelesen (ohne Update-Prüfung).'
        } else {
            Set-Status ('Software geprüft um {0}' -f (Get-Date -Format 'HH:mm:ss'))
        }
        Set-SoftwareList $rows
    }
}

function Set-SoftwareList($Rows) {
    $script:SwEntries.Clear()
    foreach ($r in @($Rows | Sort-Object Name)) { $script:SwEntries.Add((New-SwEntry $r $script:SwResults)) }
    $script:SwLoaded = $true
    Update-SwCounts
}

function Test-SwFilter($Item) {
    switch ($script:SwFilter) {
        'updates'   { if (-not $Item.HasUpdate) { return $false } }
        'unmanaged' { if ($Item.Source) { return $false } }
    }
    $q = $script:SwSearch
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $hay = '{0} {1} {2}' -f $Item.Name, $Item.Id, $Item.Source
    return ($hay.IndexOf($q.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Set-SwSelection([bool]$On) {
    foreach ($e in @($script:SwView)) { if ($e.CanSelect) { $e.Selected = $On } }
    $script:SwView.Refresh()
    Update-SwCounts
}

function Start-SoftwareUpgrade([bool]$All) {
    if (-not $script:IsAdmin) { throw 'Zum Aktualisieren sind Administratorrechte nötig.' }
    # @() außen: ein if-Ausdruck würde ein einzelnes Paket entpacken (.Count fehlt dann in PS 5.1)
    $items = @(if ($All) { $script:SwEntries | Where-Object { $_.InAll } } else { $script:SwEntries | Where-Object { $_.Selected -and $_.CanSelect } })
    if ($items.Count -eq 0) { Set-Status 'Keine Updates ausgewählt.'; return }
    $nl = [Environment]::NewLine
    $names = ($items | Select-Object -First 15 | ForEach-Object { '   {0}  {1} → {2}' -f $_.Name, $_.Version, $_.Available }) -join $nl
    if ($items.Count -gt 15) { $names += '{0}   … und {1} weitere' -f $nl, ($items.Count - 15) }
    $q = '{0} Programm(e) über winget aktualisieren?{1}{1}{2}{1}{1}Laufende Programme werden ggf. beendet. Auf einem RDS-Host vorher Benutzer abmelden bzw. Anmeldungen sperren (change logon /drain). Die Aktualisierung läuft im Hintergrund; „Abbrechen“ stoppt nach dem aktuellen Paket.' -f $items.Count, $nl, $names
    if (-not (Confirm-Action $q)) { return }
    $script:SwQueue = New-Object System.Collections.Queue
    foreach ($i in $items) { $script:SwQueue.Enqueue($i) }
    $script:SwTotal = $items.Count; $script:SwDone = 0; $script:SwFailed = 0; $script:SwCancel = $false
    Write-Log ('SOFTWARE    Start: {0} Update(s)' -f $items.Count)
    Start-NextSoftwareUpgrade
}

function Start-NextSoftwareUpgrade {
    if ($script:SwCancel -or $script:SwQueue.Count -eq 0) { Complete-SoftwareUpgrade; return }
    $item = $script:SwQueue.Dequeue()
    $script:SwCurrent = $item
    $item.RdsRating = 'Läuft …'; $item.StatusText = 'Läuft …'
    $script:SwView.Refresh()
    Update-SwCounts
    $script:UI.SwProgress.Visibility = 'Visible'
    Update-SwProgress -1
    Set-Status ('Aktualisiere {0}/{1}: {2} ({3} → {4}) …' -f ($script:SwDone + $script:SwFailed + 1), $script:SwTotal, $item.Name, $item.Version, $item.Available)
    $wgArgs = @('upgrade', '--id', $item.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($item.Source) { $wgArgs += @('--source', $item.Source) }
    try {
        Invoke-WingetAsync $wgArgs {
            param($code, $text)
            $it = $script:SwCurrent
            if ($code -eq 0) {
                $script:SwDone++
                $it.RdsRating = 'Aktualisiert'; $it.StatusText = 'Aktualisiert'; $it.Tip = 'Aktualisiert auf {0}' -f $it.Available
                $it.CanSelect = $false; $it.Selected = $false
                $script:SwResults.Remove($it.Id)
                Write-Log ('SOFTWARE    {0} ({1}): {2} -> {3} aktualisiert' -f $it.Name, $it.Id, $it.Version, $it.Available)
            } else {
                $script:SwFailed++
                $msg = Get-WingetErrorText $code $text
                $it.RdsRating = 'Fehler'; $it.StatusText = 'Fehler'; $it.Tip = $msg
                $script:SwResults[$it.Id] = 'Letzter Versuch: ' + $msg
                Write-Log ('Software-Update {0} ({1}) fehlgeschlagen: {2}' -f $it.Name, $it.Id, $msg) 'FEHLER'
            }
            Start-NextSoftwareUpgrade
        }
    } catch {
        $script:SwFailed++
        Write-Log ('Software-Update {0} nicht gestartet: {1}' -f $item.Name, $_.Exception.Message) 'FEHLER'
        Complete-SoftwareUpgrade
    }
}

function Update-SwProgress([int]$Percent) {
    # Balken über der Liste: Gesamt (Pakete) und aktuelles Paket (Prozent oder unbestimmt)
    $ui = $script:UI
    $finished = $script:SwDone + $script:SwFailed
    $ui.PbSwPackages.Maximum = [Math]::Max(1, $script:SwTotal)
    $ui.PbSwPackages.Value   = $finished
    $ui.PbSwCurrent.IsIndeterminate = ($Percent -lt 0)
    if ($Percent -ge 0) { $ui.PbSwCurrent.Value = $Percent }
    $name = if ($script:SwCurrent) { $script:SwCurrent.Name } else { '' }
    $ui.TxtSwProgress.Text = 'Paket {0}/{1}: {2}{3}' -f ($finished + 1), $script:SwTotal, $name, $(if ($Percent -ge 0) { ' · {0} %' -f $Percent } else { '' })
}

function Complete-SoftwareUpgrade {
    $done = $script:SwDone; $failed = $script:SwFailed; $cancel = $script:SwCancel
    $rest = if ($script:SwQueue) { $script:SwQueue.Count } else { 0 }
    $script:SwQueue = $null
    $script:UI.SwProgress.Visibility = 'Collapsed'
    Write-Log ('SOFTWARE    Ende: {0} aktualisiert, {1} fehlgeschlagen{2}' -f $done, $failed, $(if ($cancel) { ", abgebrochen ($rest offen)" } else { '' }))
    $script:SwView.Refresh()
    Update-SwCounts
    $msg = '{0} Programm(e) aktualisiert{1}{2}.' -f $done, $(if ($failed) { ", $failed fehlgeschlagen (Details im Tooltip/Protokoll)" } else { '' }), $(if ($cancel) { ", abgebrochen – $rest nicht ausgeführt" } else { '' })
    Set-Status $msg
    if ($failed) { Show-Message $msg 'Warning' }
    Request-SoftwareList   # Versionen neu prüfen; Fehlerhinweise bleiben über SwResults erhalten
}

function Show-InputDialog([string]$Title, [string]$Prompt, [string]$Default = '') {
    $x = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="520" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13" Background="#F4F4F2" ShowInTaskbar="False"><StackPanel Margin="20"><TextBlock x:Name="P" TextWrapping="Wrap"/><TextBox x:Name="T" Margin="0,12,0,0" Padding="6,5"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0"><Button x:Name="O" Content="OK" Width="90" IsDefault="True" Padding="0,5"/><Button Content="Abbrechen" Width="90" IsCancel="True" Margin="8,0,0,0" Padding="0,5"/></StackPanel></StackPanel></Window>'
    $w = [Windows.Markup.XamlReader]::Parse($x)
    $w.Title = $Title
    $w.Owner = $script:Window
    $w.FindName('P').Text = $Prompt
    $tb = $w.FindName('T'); $tb.Text = $Default
    $w.FindName('O').add_Click({ $w.DialogResult = $true })
    $w.add_ContentRendered({ $tb.Focus(); $tb.SelectAll() })
    if ($w.ShowDialog()) { return $tb.Text }
    return $null
}

function Update-SmCounts {
    $all = @($script:SmEntries)
    $sc  = @($all | Where-Object { $_.Kind -eq 'Shortcut' })
    $vis = @($sc | Where-Object { $_.RdsRating -eq 'Alle' }).Count
    $hid = @($sc | Where-Object { $_.RdsRating -eq 'Ausgeblendet' }).Count
    $lim = @($sc | Where-Object { $_.RdsRating -eq 'Eingeschränkt' }).Count
    $sel = @($all | Where-Object { $_.Selected }).Count
    $script:UI.TxtCounts.Text = '{0} Verknüpfungen  ·  {1} für alle  ·  {2} ausgeblendet  ·  {3} eingeschränkt  ·  {4} Store-Apps  ·  {5} ausgewählt' -f $sc.Count, $vis, $hid, $lim, ($all.Count - $sc.Count), $sel
    $script:UI.TxtSmEmpty.Visibility  = if ($script:SmLoaded -and $script:SmView.IsEmpty) { 'Visible' } else { 'Collapsed' }
    $script:UI.SmAdminHint.Visibility = if ($script:SmLoaded -and -not $script:IsAdmin) { 'Visible' } else { 'Collapsed' }
    foreach ($b in 'BtnSmShow', 'BtnSmHide', 'BtnSmGroups') { $script:UI[$b].IsEnabled = ($sel -gt 0) }
}

function Update-StartMenuList {
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $items = @(Get-StartMenuEntries)
        $script:SmEntries.Clear()
        foreach ($e in $items) { $script:SmEntries.Add($e) }
        $script:SmLoaded = $true
    } finally { $script:Window.Cursor = $null }
    Update-SmCounts
    Set-Status ('Startmenü eingelesen um {0}' -f (Get-Date -Format 'HH:mm:ss'))
}

function Request-StartMenuList {
    $script:UI.TxtSmLoading.Visibility = 'Visible'
    Set-Status 'Startmenü und Store-Apps werden gelesen …'
    [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
        Invoke-Guarded {
            try { Update-StartMenuList } finally { $script:UI.TxtSmLoading.Visibility = 'Collapsed' }
        }
    })
}

function Test-SmFilter($Item) {
    switch ($script:SmFilter) {
        'visible' { if ($Item.RdsRating -ne 'Alle') { return $false } }
        'hidden'  { if ($Item.RdsRating -ne 'Ausgeblendet') { return $false } }
        'groups'  { if ($Item.RdsRating -ne 'Eingeschränkt') { return $false } }
        'appx'    { if ($Item.Kind -ne 'AppX') { return $false } }
    }
    $q = $script:SmSearch
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $hay = '{0} {1} {2} {3}' -f $Item.Name, $Item.Folder, $Item.Target, $Item.GroupsText
    return ($hay.IndexOf($q.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Set-SmSelection([bool]$On) {
    # Auswahl nur für die aktuell sichtbaren (gefilterten) Zeilen
    foreach ($e in @($script:SmView)) { if ($e.CanSelect) { $e.Selected = $On } }
    $script:SmView.Refresh()
    Update-SmCounts
}

function Invoke-SmAction([string]$Mode) {
    $sel = @($script:SmEntries | Where-Object { $_.Selected -and $_.CanSelect })
    if ($sel.Count -eq 0) { Set-Status 'Keine Einträge ausgewählt.'; return }
    $sids = @(); $groupText = ''
    if ($Mode -eq 'groups') {
        $txt = Show-InputDialog 'Nur für Gruppen sichtbar' ('Welche Gruppen sollen die {0} ausgewählten Einträge sehen?{1}Mehrere Gruppen mit Komma trennen, z. B. „DOMÄNE\Buchhaltung, Remotedesktopbenutzer“. Administratoren sehen die Einträge immer.' -f $sel.Count, [Environment]::NewLine) $script:SmLastGroups
        if ($null -eq $txt) { return }
        $res = Resolve-SmGroups $txt
        if ($res.Bad.Count -gt 0) { Show-Message ('Diese Gruppen wurden nicht gefunden:{0}{0}{1}{0}{0}Es wurde nichts geändert.' -f [Environment]::NewLine, ($res.Bad -join ', ')) 'Warning'; return }
        if ($res.Sids.Count -eq 0) { Show-Message 'Bitte mindestens eine Gruppe angeben.' 'Warning'; return }
        $sids = $res.Sids
        $groupText = ($sids | ForEach-Object { Get-SidName $_ }) -join ', '
        $script:SmLastGroups = $txt
    }
    $nl = [Environment]::NewLine
    $verb = switch ($Mode) { 'show' { 'für alle Benutzer sichtbar machen' } 'hide' { 'für alle Benutzer ausblenden' } 'groups' { 'nur für {0} sichtbar machen' -f $groupText } }
    $names = ($sel | Select-Object -First 15 | ForEach-Object { '   {0}  [{1}]' -f $_.Name, $_.Folder }) -join $nl
    if ($sel.Count -gt 15) { $names += '{0}   … und {1} weitere' -f $nl, ($sel.Count - 15) }
    $q = '{0} Startmenü-Eintrag/Einträge {1}?{2}{2}{3}{2}{2}Wirksam ab der nächsten Anmeldung. Administratoren sehen weiterhin alle Einträge.' -f $sel.Count, $verb, $nl, $names
    if (-not (Confirm-Action $q)) { return }
    $ok = 0; $fail = 0
    foreach ($e in $sel) {
        try {
            Set-StartMenuVisibility $e $Mode $sids
            Write-Log ('STARTMENÜ   {0}: {1}{2}' -f $Mode, $e.RelPath, $(if ($groupText) { " → $groupText" } else { '' }))
            $ok++
        } catch {
            $fail++
            Write-Log ('Startmenü „{0}“ ({1}) fehlgeschlagen: {2}' -f $e.RelPath, $Mode, $_.Exception.Message) 'FEHLER'
        }
    }
    Update-StartMenuList
    Set-Status ('{0} Eintrag/Einträge geändert{1}. Wirksam ab der nächsten Anmeldung.' -f $ok, $(if ($fail) { ", $fail fehlgeschlagen (siehe Protokoll)" } else { '' }))
    if ($fail) { Show-Message ('{0} Eintrag/Einträge konnten nicht geändert werden – Details im Protokoll.' -f $fail) 'Warning' }
}

function Get-SealPlan($Ctx) {
    # Welche Versiegeln-Schritte laufen auf diesem System, welche werden (mit Grund) übersprungen
    $run = @(); $skip = @()
    foreach ($s in Get-SealSteps) {
        $why = ''
        if (-not (Test-OptApplies $s.Applies $Ctx)) {
            $why = switch ($s.Applies) { 'VDA' { 'kein Citrix VDA erkannt' } 'RDSH' { 'kein RD-Sitzungshost' } default { 'trifft nicht zu' } }
        } elseif ($s.Service -and -not (Read-ServiceConfig $s.Service)) {
            $why = 'Dienst {0} nicht vorhanden' -f $s.Service
        } elseif ($s.Check) {
            try { $why = "$(& $s.Check)" } catch { $why = 'Prüfung fehlgeschlagen: {0}' -f $_.Exception.Message }
        }
        if ($why) { $skip += [pscustomobject]@{ Title = $s.Title; Reason = $why } } else { $run += $s }
    }
    [pscustomobject]@{ Run = $run; Skip = $skip }
}

function Update-SealInfo {
    $o = Read-OptOriginals
    $script:UI.TxtSealLast.Text = if ($o.ContainsKey('seal:last')) { 'Zuletzt versiegelt: {0}' -f ([datetime]"$($o['seal:last'])").ToString('dd.MM.yyyy HH:mm') } else { 'Noch nie versiegelt' }
    $script:UI.BtnSeal.IsEnabled = $script:IsAdmin
}

function Invoke-SealAndShutdown([switch]$PlanOnly) {
    # Bei jeder Image-Aktualisierung: alle zutreffenden einmaligen Schritte ausführen, dann herunterfahren
    $ctx = if ($script:CitrixEnv) { $script:CitrixEnv } else { Get-CitrixEnvironment }
    $plan = Get-SealPlan $ctx
    $nl = [Environment]::NewLine
    $i = 0
    $q = 'Image versiegeln und herunterfahren?{0}{0}Folgende Schritte werden ausgeführt:{0}{1}' -f $nl, ((@($plan.Run) | ForEach-Object { $i++; '   {0}. {1}' -f $i, $_.Title }) -join $nl)
    if (@($plan.Skip).Count -gt 0) {
        $q += '{0}{0}Übersprungen:{0}{1}' -f $nl, ((@($plan.Skip) | ForEach-Object { '   – {0} ({1})' -f $_.Title, $_.Reason }) -join $nl)
    }
    if ($ctx.ImageReadOnly) { $q += '{0}{0}Achtung: Dieses System läuft von einem nicht-persistenten Image – Versiegeln wirkt nur in einer Wartungsversion bzw. im Master-Image.' -f $nl }
    $q += '{0}{0}Die Schritte sind nicht umkehrbar. Vorher wird automatisch gesichert, anschließend fährt der Rechner herunter.' -f $nl
    if ($PlanOnly) { return $q }

    if (-not $script:IsAdmin) { throw 'Zum Versiegeln sind Administratorrechte nötig.' }
    if (-not (Confirm-Action $q)) { return }
    Invoke-SessionBackup
    $steps = @($plan.Run)
    Write-Log ('VERSIEGELN  Start ({0} Schritte)' -f $steps.Count)
    $fail = 0; $n = 0
    foreach ($s in $steps) {
        $n++
        Set-Status ('Versiegeln {0}/{1}: {2} …' -f $n, $steps.Count, $s.Title)
        $script:Window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background)   # Statuszeile neu zeichnen
        try {
            & $s.Apply
            Write-Log ('VERSIEGELN  {0} [{1}]' -f $s.Title, $s.Id)
        } catch {
            $fail++
            Write-Log ('Versiegeln „{0}“ fehlgeschlagen: {1}' -f $s.Title, $_.Exception.Message) 'FEHLER'
        }
    }
    $orig = Read-OptOriginals
    $orig['seal:last'] = (Get-Date).ToString('s')
    Save-OptOriginals $orig
    Update-SealInfo
    if ($fail -and -not (Confirm-Action ('{0} Schritt(e) sind fehlgeschlagen (Details im Protokoll).{1}{1}Trotzdem herunterfahren?' -f $fail, $nl))) {
        Set-Status ('Versiegelt mit {0} Fehler(n) – nicht heruntergefahren.' -f $fail)
        return
    }
    Write-Log 'HERUNTERFAHREN nach Versiegeln'
    [void](Invoke-NativeChecked "$env:SystemRoot\System32\shutdown.exe" @('/s', '/t', '5', '/c', 'Windows-Optimizer: Image versiegelt'))
    $script:Window.Close()
}

function Show-Page([string]$Nav) {
    $pages = [ordered]@{ NavAutostart = 'PageAutostart'; NavServices = 'PageServices'; NavOptimize = 'PageOptimize'; NavStartMenu = 'PageStartMenu'; NavSoftware = 'PageSoftware'; NavSystem = 'PageSystem'; NavBackup = 'PageBackup'; NavLog = 'PageLog' }
    foreach ($k in $pages.Keys) {
        $script:UI[$pages[$k]].Visibility = if ($k -eq $Nav) { 'Visible' } else { 'Collapsed' }
    }
    Update-Counts
    switch ($Nav) {
        'NavServices' { if (-not $script:ServicesLoaded) { Request-ServiceList } }
        'NavOptimize' { if (-not $script:OptLoaded) { Request-OptimizationList } }
        'NavStartMenu' { if (-not $script:SmLoaded) { Request-StartMenuList } }
        'NavSoftware'  { if (-not $script:SwLoaded) { Request-SoftwareList } }
        'NavSystem' { if (-not $script:SysInfo) { Request-SystemInfo } }
        'NavBackup' { Update-BackupList }
        'NavLog'    { Update-LogFiles }
    }
}

#endregion

#region Start --------------------------------------------------------------------------------

try {
    Initialize-DataDir
    Set-AppUserModelId 'WindowsOptimizer'

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

    # Symbol (Fenster, Taskleiste, Seitenleiste)
    try {
        $icon = New-AppIcon 256
        $window.Icon = $icon
        $ui.ImgLogo.Source = $icon
    } catch { Write-Log ('Symbol konnte nicht erzeugt werden: {0}' -f $_.Exception.Message) 'WARN' }

    # Kopfbereich und Rechte
    $ui.TxtMachine.Text = $env:COMPUTERNAME
    $ui.TxtVersion.Text = 'Version {0}' -f $script:AppVersion
    if ($script:IsAdmin) {
        $ui.TxtRights.Text = 'Administrator'
        $ui.DotRights.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#5DB47F')
        $ui.BtnElevate.Visibility = 'Collapsed'
        $window.Title = '{0} (Administrator)' -f $script:AppName
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

    # Datenquelle der Dienste-Tabelle; Starttyp-Auswahl (gemeinsamer Handler für alle Zeilen)
    $script:Services = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:SvcView  = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Services)
    $script:SvcView.Filter = [Predicate[object]]{ param($item) Test-ServiceFilter $item }
    $ui.GridServices.ItemsSource = $script:Services
    $ui.GridServices.AddHandler([Windows.Controls.Primitives.Selector]::SelectionChangedEvent, [Windows.Controls.SelectionChangedEventHandler]{
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -isnot [Windows.Controls.ComboBox] -or "$($src.Tag)" -ne 'starttype') { return }
        $e.Handled = $true
        $svc = $src.DataContext
        # Beim Recyceln von Zeilen ist DataContext kurz ein Platzhalter bzw. Auswahl = aktueller Wert
        if ($null -eq $svc -or $null -eq $svc.PSObject.Properties['StartTypeText']) { return }
        $new = [string]$src.SelectedItem
        if (-not $new -or $new -eq $svc.StartTypeText) { return }
        Invoke-StartTypeChange $src $svc $new
    })

    # Datenquelle der RDS-Optimierung; Auswahl-Häkchen (gemeinsamer Handler für alle Zeilen)
    $script:OptItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:OptView  = [Windows.Data.CollectionViewSource]::GetDefaultView($script:OptItems)
    $script:OptView.Filter = [Predicate[object]]{ param($item) Test-OptFilter $item }
    $ui.GridOptimize.ItemsSource = $script:OptItems
    $ui.GridOptimize.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -isnot [Windows.Controls.CheckBox] -or "$($src.Tag)" -ne 'optsel' -or $null -eq $src.DataContext) { return }
        if ($null -eq $src.DataContext.PSObject.Properties['Selected']) { return }
        $src.DataContext.Selected = [bool]$src.IsChecked
        Update-OptCounts
    })
    $ui.CmbOptCacheDrive.add_SelectionChanged({
        if ($script:OptDriveLoading) { return }
        $item = $script:UI.CmbOptCacheDrive.SelectedItem
        $script:OptCacheDrive = if ($item) { "$($item.Tag)" } else { '' }
        Invoke-Guarded { Update-OptimizationList }
    })
    foreach ($f in 'OptFltApplicable', 'OptFltOpen', 'OptFltDone', 'OptFltAll') {
        $ui[$f].add_Checked({
            param($s, $e)
            $script:OptFilter = @{ OptFltApplicable = 'applicable'; OptFltOpen = 'open'; OptFltDone = 'done'; OptFltAll = 'all' }[$s.Name]
            if ($script:OptView) { $script:OptView.Refresh(); Update-OptCounts }
        })
    }

    # Datenquelle der Startmenü-Seite; Auswahl-Häkchen, Suche und Filter
    $script:SmEntries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:SmView    = [Windows.Data.CollectionViewSource]::GetDefaultView($script:SmEntries)
    $script:SmView.Filter = [Predicate[object]]{ param($item) Test-SmFilter $item }
    $ui.GridStartMenu.ItemsSource = $script:SmEntries
    $ui.GridStartMenu.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -isnot [Windows.Controls.CheckBox] -or "$($src.Tag)" -ne 'smsel' -or $null -eq $src.DataContext) { return }
        if ($null -eq $src.DataContext.PSObject.Properties['Selected']) { return }
        $src.DataContext.Selected = [bool]$src.IsChecked
        Update-SmCounts
    })
    $ui.TxtSmSearch.add_TextChanged({
        $script:SmSearch = $script:UI.TxtSmSearch.Text
        $script:UI.TxtSmSearchHint.Visibility = if ($script:SmSearch) { 'Collapsed' } else { 'Visible' }
        $script:SmView.Refresh()
        Update-SmCounts
    })
    foreach ($f in 'SmFltAll', 'SmFltVisible', 'SmFltHidden', 'SmFltGroups', 'SmFltAppx') {
        $ui[$f].add_Checked({
            param($s, $e)
            $script:SmFilter = @{ SmFltAll = 'all'; SmFltVisible = 'visible'; SmFltHidden = 'hidden'; SmFltGroups = 'groups'; SmFltAppx = 'appx' }[$s.Name]
            if ($script:SmView) { $script:SmView.Refresh(); Update-SmCounts }
        })
    }

    # Software-Seite: Datenquelle, Häkchen, Suche, Filter; Timer fragt den winget-Prozess ab
    $script:SwEntries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:SwView    = [Windows.Data.CollectionViewSource]::GetDefaultView($script:SwEntries)
    $script:SwView.Filter = [Predicate[object]]{ param($item) Test-SwFilter $item }
    $ui.GridSoftware.ItemsSource = $script:SwEntries
    $ui.GridSoftware.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -isnot [Windows.Controls.CheckBox] -or "$($src.Tag)" -ne 'swsel' -or $null -eq $src.DataContext) { return }
        if ($null -eq $src.DataContext.PSObject.Properties['Selected']) { return }
        $src.DataContext.Selected = [bool]$src.IsChecked
        Update-SwCounts
    })
    $ui.TxtSwSearch.add_TextChanged({
        $script:SwSearch = $script:UI.TxtSwSearch.Text
        $script:UI.TxtSwSearchHint.Visibility = if ($script:SwSearch) { 'Collapsed' } else { 'Visible' }
        $script:SwView.Refresh()
        Update-SwCounts
    })
    foreach ($f in 'SwFltAll', 'SwFltUpdates', 'SwFltUnmanaged') {
        $ui[$f].add_Checked({
            param($s, $e)
            $script:SwFilter = @{ SwFltAll = 'all'; SwFltUpdates = 'updates'; SwFltUnmanaged = 'unmanaged' }[$s.Name]
            if ($script:SwView) { $script:SwView.Refresh(); Update-SwCounts }
        })
    }
    $script:WgTimer = New-Object Windows.Threading.DispatcherTimer
    $script:WgTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $script:WgTimer.add_Tick({ Invoke-Guarded { Test-WingetJob } })

    # Navigation
    foreach ($nav in 'NavAutostart', 'NavServices', 'NavOptimize', 'NavStartMenu', 'NavSoftware', 'NavSystem', 'NavBackup', 'NavLog') {
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

    $ui.TxtSvcSearch.add_TextChanged({
        $script:SvcSearch = $script:UI.TxtSvcSearch.Text
        $script:UI.TxtSvcSearchHint.Visibility = if ($script:SvcSearch) { 'Collapsed' } else { 'Visible' }
        $script:SvcView.Refresh()
        Update-ServiceCounts
    })
    foreach ($f in 'SvcFltAll', 'SvcFltAuto', 'SvcFltManual', 'SvcFltOff') {
        $ui[$f].add_Checked({
            param($s, $e)
            $script:SvcFilter = @{ SvcFltAll = 'all'; SvcFltAuto = 'auto'; SvcFltManual = 'manual'; SvcFltOff = 'off' }[$s.Name]
            $script:SvcView.Refresh()
            Update-ServiceCounts
        })
    }

    # Buttons: ein Handler, Aktion je Button-Name
    $script:ClickActions = @{
        BtnRefresh    = { Update-EntryList }
        BtnFixApproved = { Invoke-FixApproved }
        BtnSvcRefresh = { Update-ServiceList }
        BtnOptRefresh     = { Update-OptimizationList }
        BtnOptRecommended = { Set-OptSelection 'recommended' }
        BtnOptNone        = { Set-OptSelection 'none' }
        BtnOptApply       = { Invoke-OptimizationRun $false }
        BtnOptUndo        = { Invoke-OptimizationRun $true }
        BtnSeal           = { Invoke-SealAndShutdown }
        BtnSmShow         = { Invoke-SmAction 'show' }
        BtnSmHide         = { Invoke-SmAction 'hide' }
        BtnSmGroups       = { Invoke-SmAction 'groups' }
        BtnSmRefresh      = { Update-StartMenuList }
        BtnSmSelectAll    = { Set-SmSelection $true }
        BtnSmSelectNone   = { Set-SmSelection $false }
        BtnSwRefresh      = { Request-SoftwareList }
        BtnSwUpdateSel    = { Start-SoftwareUpgrade $false }
        BtnSwUpdateAll    = { Start-SoftwareUpgrade $true }
        BtnSwSelectAll    = { Set-SwSelection $true }
        BtnSwSelectNone   = { Set-SwSelection $false }
        BtnSwCancel       = {
            $script:SwCancel = $true
            $script:UI.BtnSwCancel.IsEnabled = $false
            Set-Status 'Wird nach dem aktuellen Paket abgebrochen …'
        }
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
    $window.add_Closing({
        param($s, $e)
        if ($script:SwQueue -and -not (Confirm-Action ('Es läuft noch eine Software-Aktualisierung. Das aktuelle Paket wird von winget zu Ende installiert, weitere werden nicht mehr gestartet.{0}{0}Trotzdem schließen?' -f [Environment]::NewLine))) { $e.Cancel = $true }
    })
    $window.add_Closed({ Write-Log 'Programm beendet.' })

    $rights = if ($script:IsAdmin) { 'Administrator' } else { 'Standardbenutzer' }
    Write-Log ('Programm gestartet (Version {0}, {1}\{2}, {3}, Daten: {4})' -f $script:AppVersion, $env:USERDOMAIN, $env:USERNAME, $rights, $script:DataDir)

    [void]$window.ShowDialog()
}
catch {
    $msg = $_.Exception.Message
    try { Write-Log ('Abbruch: {0}' -f $msg) 'FEHLER' } catch { }
    [void][Windows.MessageBox]::Show("Der Windows-Optimizer konnte nicht gestartet werden:`n`n$msg", 'Windows-Optimizer', 'OK', 'Error')
}

#endregion
