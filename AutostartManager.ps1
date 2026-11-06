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

$script:AppVersion   = '1.1.0'
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
    $entries  = @(Get-AutostartEntries)
    $services = @(Get-ServiceEntries | Where-Object { -not $_.IsInstance -and $_.StartType -notin 'boot', 'system' })
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base  = Join-Path $script:BackupDir "autostart_$stamp"
    $n = 2
    while (Test-Path -LiteralPath "$base.json") { $base = Join-Path $script:BackupDir ('autostart_{0}_{1}' -f $stamp, $n); $n++ }

    $data = [ordered]@{
        Format   = 'AutostartManager-Backup'
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
                           CanApply = $can; Reason = $reason }
    }
}

function Invoke-RestoreItem($Item) {
    if ($Item.Kind -eq 'Service') { Set-ServiceStartType $Item.Service ([string]$Item.Backup.StartType); return }
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
    if ($script:UI.PageServices.Visibility -eq 'Visible') { Update-ServiceCounts }
    else { $script:UI.TxtCounts.Text = '{0} Einträge  ·  {1} aktiv  ·  {2} deaktiviert' -f $all.Count, $on, ($all.Count - $on) }
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

function Show-Page([string]$Nav) {
    $pages = [ordered]@{ NavAutostart = 'PageAutostart'; NavServices = 'PageServices'; NavSystem = 'PageSystem'; NavBackup = 'PageBackup'; NavLog = 'PageLog' }
    foreach ($k in $pages.Keys) {
        $script:UI[$pages[$k]].Visibility = if ($k -eq $Nav) { 'Visible' } else { 'Collapsed' }
    }
    Update-Counts
    switch ($Nav) {
        'NavServices' { if (-not $script:ServicesLoaded) { Request-ServiceList } }
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

    # Navigation
    foreach ($nav in 'NavAutostart', 'NavServices', 'NavSystem', 'NavBackup', 'NavLog') {
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
        BtnSvcRefresh = { Update-ServiceList }
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
