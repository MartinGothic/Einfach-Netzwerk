param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$RequestJson = ''
)

# Windows PowerShell 5.1. This worker is embedded in the application and runs in
# a separate process. Inspect and DryRun never change Windows configuration.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$script:AppMark = 'EinfachNetzwerk-v1'
$script:RuleGroup = 'EinfachNetzwerk (Heimnetz)'
$script:LedgerRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'EinfachNetzwerk'
$script:LedgerFile = Join-Path $script:LedgerRoot 'state.json'
$script:Checks = New-Object 'System.Collections.Generic.List[object]'
$script:Secret = $null
$script:Request = $null
$script:Ledger = $null
$script:Transaction = $null
$script:AccountCreated = $null
$script:MutationMutex = $null
$script:MutexHeld = $false
$script:PhaseStream = $null
$script:WorkPlan = $null
$script:WorkCompleted = $null
$script:WorkText = ''
$script:FolderGuard = $null
$script:Result = [ordered]@{
    Success = $false; Message = ''; Checks = @(); Networks = @(); Shares = @()
    ConnectionText = ''; ComputerName = $env:COMPUTERNAME; Address = ''
    SharePath = ''; BackupPath = ''; PendingComputerName = ''; RestartRequired = $false; RetryCount = 0
    LoginUserName = ''; ConnectionVerified = $false
    ErrorCode = ''; ErrorType = ''; ErrorStackTrace = ''
    RemoteComputerName = ''; RemoteAddress = ''; RemoteShareName = ''; NativeConnectionVerified = $false
    NamedConnectionVerified = $false; RemoteName = ''; NamedSharePath = ''; NamedAccessCode = ''; NamedAccessMessage = ''
    ClientRepairAvailable = $false; ClientBackupPath = ''
    RemoteComputerEnumerationVerified = $false; AnonymousShareListDenied = $false; RemoteShares = @()
    ServiceHealthVerified = $false; ServiceRepairAvailable = $false; ServiceBackupPath = ''
}

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Add-Check([string]$Name, [string]$State, [string]$Detail, [string]$Code = '', [bool]$Fixable = $false, [string]$NextStep = '', [string]$TargetShare = '') {
    $script:Checks.Add([pscustomobject]@{ Name = $Name; State = $State; Detail = $Detail; Code = $Code; Fixable = $Fixable; NextStep = $NextStep; TargetShare = $TargetShare })
}
function Hide-FailureSecrets([string]$Text) {
    if (-not [string]::IsNullOrEmpty($script:Secret)) { $Text = $Text.Replace($script:Secret, '[Passwort ausgeblendet]') }
    $protectedValue = [string](Get-Value $script:Request 'ProtectedPassword' '')
    if (-not [string]::IsNullOrEmpty($protectedValue)) { $Text = $Text.Replace($protectedValue, '[verschlüsselte Daten ausgeblendet]') }
    return $Text
}
function Set-FailureDetails([Management.Automation.ErrorRecord]$Failure) {
    $codes = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrEmpty($Failure.FullyQualifiedErrorId)) { $codes.Add('PowerShell: ' + $Failure.FullyQualifiedErrorId) }
    $errorException = $Failure.Exception
    $depth = 0
    while ($null -ne $errorException -and $depth -lt 16) {
        $codes.Add('HRESULT[' + $depth + ']: 0x' + $errorException.HResult.ToString('X8', [Globalization.CultureInfo]::InvariantCulture))
        if ($errorException -is [ComponentModel.Win32Exception]) { $codes.Add('Win32[' + $depth + ']: ' + $errorException.NativeErrorCode) }
        $errorException = $errorException.InnerException
        $depth++
    }
    $script:Result.ErrorCode = Hide-FailureSecrets ($codes -join '; ')
    $script:Result.ErrorType = $Failure.Exception.GetType().FullName
    $script:Result.ErrorStackTrace = Hide-FailureSecrets ($Failure.Exception.ToString() + [Environment]::NewLine + [string]$Failure.ScriptStackTrace)
}
function Advanced-Repair($Request) { return [bool](Get-Value $Request 'AllowAdvancedRepair' $false) }
function Assert-PersonalPolicyChanges {
    try {
        $system = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop
        $domain = [bool]$system.PartOfDomain
    } catch {
        $failure = $_
        Add-Check 'Windows-Verwaltungsstatus lesen' warning $_.Exception.Message (Get-ClientDiagnosticCode $_) $false 'Die lokale WMI-Abfrage ist fehlgeschlagen oder hat ihr Zeitlimit erreicht. Der Status wird zusätzlich über die native Windows-Domänenfunktion geprüft.'
        $join = Get-ClientNativeJoinState
        if (-not $join.Success -or $join.JoinStatus -notin @(1,2,3)) { throw $failure }
        $domain = $join.JoinStatus -eq 3
        $detail = 'Windows bestätigt: kein Domänen-PC.'
        if ($domain) { $detail = 'Windows bestätigt: dieser PC ist einer Domäne beigetreten.' }
        Add-Check 'Nativer Windows-Verwaltungsstatus' ok $detail 'CLIENT_NATIVE_JOIN_CONFIRMED'
    }
    if ($domain) { throw 'Dieser PC ist Mitglied einer Domäne. Verwaltete Sicherheitsrichtlinien müssen dort durch die zuständigen Administratoren geändert werden.' }
    foreach ($managedPath in @('HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts','HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo')) {
        if ((Test-Path -LiteralPath $managedPath) -and @(Get-ChildItem -LiteralPath $managedPath -ErrorAction Stop).Count -gt 0) {
            throw 'Dieser PC wird durch eine Domäne oder Geräteverwaltung verwaltet. Die gespeicherten Einstellungen müssen durch die Administration geprüft werden.'
        }
    }
}
function Get-ComputerNames {
    $active = [string]$env:COMPUTERNAME
    $pending = Get-RegistrySnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName'
    $script:Result.ComputerName = $active
    if ($pending.Exists -and [string]$pending.Value -ine $active) {
        $script:Result.PendingComputerName = [string]$pending.Value
        $script:Result.RestartRequired = $true
        Add-Check 'Computername' info ('Aktuell: ' + $active + '; nach Neustart: ' + [string]$pending.Value) 'RESTART_REQUIRED' $false 'Speichere deine Arbeit und starte Windows neu, damit der neue Computername aktiv wird.'
    }
}
function Rename-LocalComputer($Request) {
    $name = [string](Get-Value $Request 'ComputerName' '')
    if ($name -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$' -or $name -match '^\d+$') { throw 'Der Computername muss 1 bis 15 Buchstaben, Ziffern oder Bindestriche enthalten, mit einem Buchstaben oder einer Ziffer beginnen und enden und darf nicht nur aus Ziffern bestehen.' }
    if ($name -ieq $env:COMPUTERNAME) { $script:Result.Success = $true; $script:Result.Message = 'Der gewünschte Computername ist bereits aktiv.'; Get-ComputerNames; Complete-WorkStep 'rename-validation'; Complete-WorkStep 'rename-change'; return }
    Assert-PersonalPolicyChanges
    Complete-WorkStep 'rename-validation'
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        $script:Result.Success = $true; $script:Result.Message = 'Probelauf: Computername ändern; kein Neustart und keine Windows-Änderung ausgeführt.'
        Add-Check 'Neuer Computername' info ($env:COMPUTERNAME + ' → ' + $name)
        Complete-WorkStep 'rename-change'
        return
    }
    if (-not (Is-Administrator)) { throw 'Diese Aktion benötigt Administratorrechte.' }
    Initialize-LedgerDirectory
    $journal = Join-Path $script:LedgerRoot ('rename-' + [Guid]::NewGuid().ToString('N') + '.json')
    $record = [pscustomobject]@{ App=$script:AppMark; Action='Rename'; PreviousName=[string]$env:COMPUTERNAME; DesiredName=$name; Created=[DateTime]::UtcNow.ToString('o'); Status='Prepared' }
    Write-JsonAtomic $journal $record
    Write-Phase 'Computername für den nächsten Neustart ändern …'
    try {
        $change = Rename-Computer -NewName $name -PassThru -Force -ErrorAction Stop
        if ($null -eq $change -or -not $change.HasSucceeded) { throw 'Windows hat die Namensänderung nicht übernommen.' }
        $record.Status='Committed'; Write-JsonAtomic $journal $record
        $script:Result.Success=$true; $script:Result.PendingComputerName=$name; $script:Result.RestartRequired=$true
        $script:Result.Message='Der Computername wird nach dem nächsten Windows-Neustart geändert. Speichere deine Arbeit und starte Windows selbst neu.'
        Add-Check 'Computername' ok ($env:COMPUTERNAME + ' → ' + $name) 'RESTART_REQUIRED' $false 'Speichere deine Arbeit und starte Windows neu, damit der neue Computername aktiv wird.'
        Complete-WorkStep 'rename-change'
    } catch { $record.Status='Failed'; try { Write-JsonAtomic $journal $record } catch { }; throw }
}
function Add-FailureGuidance([string]$Message) {
    $code='ACTION_FAILED'; $fixable=$false
    $next='Lies die genaue Meldung und prüfe die Verbindung erneut. Am anderen Gerät Host, Port und Anmeldung getrennt eintragen.'
    if($Message -match '(?i)Domäne|Richtlinie|Verschlüsselung') {$code='POLICY_BLOCK';$next='Verwende bei Gastproblemen den Passwortmodus. Verwaltete Richtlinien müssen auf dem betroffenen Gerät durch dessen Administrator geändert werden.'}
    elseif($Message -match '(?i)1326|Passwort|Anmeldung') {$code='CREDENTIALS';$next='Ohne Passwort den angezeigten Gast-Benutzernamen eintragen, Passwort leer lassen und Anonym deaktivieren. Mit Passwort das Netzwerk-Konto und dessen Passwort verwenden, keine Windows-PIN.'}
    elseif($Message -match '(?i)Zugriff|Ordnerrechte|Verbotsregel|Access.+denied') {$code='FOLDER_ACCESS';$fixable=$true;$next='Aktiviere die automatische Blockaden-Reparatur für den gewählten Datenordner. Geschützte Windows-Ordner bleiben ausgeschlossen.'}
    elseif($Message -match '(?i)Adapter|LAN|WLAN|Heimnetz|Netzwerkdaten') {$code='NETWORK';$next='Verbinde PC und Gerät mit demselben Heimnetz. Verwende kein Gast-WLAN und prüfe Geräteisolierung am Router.'}
    elseif($Message -match '(?i)existiert|anderen Ordner|anderer.*Name|Benutzername') {$code='NAME_CONFLICT';$next='Wähle einen neuen Freigabenamen oder Netzwerk-Benutzernamen. Vorhandene fremde Konten behalten ihre Zugangsdaten.'}
    elseif($Message -match '(?i)nicht vollständig übernommen|Firewall|Dienst|SMB 2') {$code='LOCAL_BLOCK';$fixable=$true;$next='Aktiviere die automatische Blockaden-Reparatur und prüfe erneut. Zusätzliche Sicherheitssoftware kann Verbindungen weiterhin blockieren.'}
    Add-Check 'So geht es weiter' info $next $code $fixable $next
}
# A work unit is a named, completed operation, not an estimate of elapsed time.
# Optional checks count only after their applicability has actually been decided.
# The last unit belongs to the client, which confirms the successful result file;
# this worker consequently never publishes 100%, including on a failed action.
function Initialize-WorkProgress([string]$Action, [bool]$DryRun) {
    $steps = @('request', 'access', 'ledger', 'computer', 'network', 'selection')
    if ($Action.ToLowerInvariant() -in @('inspectremote','connectremote','repairclient','restoreclient','inspectclient','prepareclient','enumeratecomputer','inspectservices','repairservices','restoreservices','repairsystem')) { $steps = @('request','access') }
    $inspection = @('inspect-shares', 'inspect-network', 'inspect-LanmanServer', 'inspect-LanmanWorkstation', 'inspect-FDResPub', 'inspect-fdPHost', 'inspect-smb', 'inspect-port', 'inspect-firewall', 'inspect-guest', 'inspect-folder')
    if ($Action -ieq 'BackupReset') { $steps = @('request','access','backup-read','backup-write') }
    if ($Action -ieq 'InspectResetShares') { $steps = @('request','access','reset-ledger','reset-service','reset-inventory') }
    switch ($Action.ToLowerInvariant()) {
        'inspect' { $steps += $inspection; $steps += 'inspect-connection' }
        { $_ -in @('apply', 'repair') } {
            $steps += 'apply-validation'
            if ($DryRun) { $steps += 'dryrun-evaluation' }
            else { $steps += @('apply-service-config', 'apply-snapshot', 'apply-services', 'apply-firewall', 'apply-account', 'apply-folder-share', 'apply-local-verification', 'apply-smb-probe', 'apply-commit'); $steps += $inspection }
        }
        { $_ -in @('remove', 'restore') } {
            $steps += 'remove-validation'
            if ($DryRun) { $steps += 'dryrun-evaluation' }
            else { $steps += @('remove-snapshot', 'remove-configuration', 'remove-commit', 'remove-cleanup', 'remove-inventory') }
        }
        'removelistedshare' {
            $steps += 'listed-validation'
            if ($DryRun) { $steps += 'dryrun-evaluation' }
            else { $steps += @('listed-removal', 'listed-verification', 'listed-inventory') }
        }
        { $_ -in @('inspectservices','repairservices','restoreservices','repairsystem') } { $steps += @('service-validation','service-snapshot','service-start','service-verification') }
        'rename' { $steps += @('rename-validation', 'rename-change', 'rename-inventory') }
        'inspectremote' { $steps += @('remote-validation','remote-network','remote-policy','remote-port','remote-probe') }
        'connectremote' { $steps += @('remote-validation','remote-network','remote-policy','remote-port','remote-probe','client-name-validation','client-name-connect','client-name-enumeration') }
        'repairclient' { $steps += @('remote-validation','remote-network','remote-policy','remote-port','remote-probe','client-snapshot','client-change','client-verification') }
        'restoreclient' { $steps += @('client-snapshot','client-change','client-verification') }
        'inspectclient' { $steps += @('client-local-network','remote-policy') }
        'prepareclient' { $steps += @('client-local-network','remote-policy','client-snapshot','client-change','client-verification') }
        'enumeratecomputer' { $steps += @('remote-validation','remote-network','remote-policy','remote-port','remote-enumeration') }
    }
    $steps += @('action-summary', 'response-written', 'client-confirmation')
    $script:WorkPlan = @($steps)
    $script:WorkCompleted = New-Object 'System.Collections.Generic.HashSet[string]'
    Write-Phase $script:WorkText
}
function Backup-ResetState {
    Write-Phase 'Freigaben und ursprüngliche Netzwerkdaten vor dem Zurücksetzen sichern …'
    if ([bool](Get-Value $script:Request 'DryRun' $false)) {
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Die Rücksetz-Sicherung würde vor dem Entfernen der Freigaben erstellt. Es wurden keine Daten geschrieben.'
        Complete-WorkStep 'backup-read'; Complete-WorkStep 'backup-write'
        return
    }
    if (-not (Is-Administrator)) { throw 'Die Rücksetz-Sicherung benötigt Administratorrechte.' }
    Initialize-LedgerDirectory
    $ledger = Read-Ledger
    $definitions = @()
    foreach ($share in @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special })) {
        $access = @(Get-SmbShareAccess -InputObject $share -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ AccountName=[string]$_.AccountName; AccessControlType=[string]$_.AccessControlType; AccessRight=[string]$_.AccessRight } })
        $sddl = (Get-Acl -LiteralPath ([string]$share.Path) -ErrorAction Stop).Sddl
        $definitions += [pscustomobject]@{ Name=[string]$share.Name; Path=[string]$share.Path; Description=[string]$share.Description; CachingMode=[string]$share.CachingMode; EncryptData=[bool]$share.EncryptData; FolderEnumerationMode=[string]$share.FolderEnumerationMode; ConcurrentUserLimit=[uint32]$share.ConcurrentUserLimit; ContinuouslyAvailable=[bool]$share.ContinuouslyAvailable; CATimeout=[uint32]$share.CATimeout; SecurityDescriptor=[string]$share.SecurityDescriptor; Access=$access; FolderSddl=$sddl }
    }
    $server = Get-SmbServerConfiguration -ErrorAction Stop
    $archives = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $script:LedgerRoot -File -Force | Where-Object { $_.Name -match '^(journal-|client-|services-|service-)' -and $_.Extension -eq '.json' })) {
        Assert-NoReparse $file.FullName
        $archives += [pscustomobject]@{ Name=$file.Name; Json=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8) }
    }
    $snapshot = [pscustomobject]@{ App=$script:AppMark; Kind='NetworkResetBackup'; Version=1; Created=[DateTime]::UtcNow.ToString('o'); ComputerName=$env:COMPUTERNAME; Shares=$definitions; Ledger=$ledger; Journals=$archives; Services=@(Get-ServiceSnapshot 'LanmanServer';Get-ServiceSnapshot 'LanmanWorkstation';Get-ServiceSnapshot 'FDResPub';Get-ServiceSnapshot 'fdPHost'); Networks=@(Get-HomeNetworks); Server=[pscustomobject]@{ EnableSMB2Protocol=[bool]$server.EnableSMB2Protocol; RequireSecuritySignature=[bool]$server.RequireSecuritySignature; EnableSecuritySignature=[bool]$server.EnableSecuritySignature; EncryptData=[bool]$server.EncryptData } }
    Complete-WorkStep 'backup-read'
    $destination = Join-Path $script:LedgerRoot ('reset-backup-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')+'.json')
    Write-JsonAtomic $destination $snapshot
    $confirmed = [IO.File]::ReadAllText($destination,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($confirmed.Kind -ne 'NetworkResetBackup' -or @($confirmed.Shares).Count -ne $definitions.Count) { throw 'Die Rücksetz-Sicherung wurde nicht vollständig bestätigt. Es werden keine Freigaben entfernt.' }
    Complete-WorkStep 'backup-write'
    $script:Result.BackupPath=$destination; $script:Result.ComputerName=$env:COMPUTERNAME
    $script:Result.Success=$true; $script:Result.Message='Die Freigaben- und Netzwerkdaten wurden vor dem Zurücksetzen gesichert.'
    Add-Check 'Rücksetz-Sicherung' ok $destination 'RESET_BACKUP_CONFIRMED'
}
function Complete-WorkStep([string]$Name) {
    # Extracted-function test harnesses do not initialize a progress plan.
    $plan = Get-Variable -Name WorkPlan -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $plan -or $null -eq $plan.Value -or $Name -notin $plan.Value) { return }
    if ($script:WorkCompleted.Add($Name)) { Write-Phase $script:WorkText }
}
function Write-Phase([string]$Text) {
    $script:WorkText = $Text
    try {
        if ($null -eq $script:PhaseStream) { $script:PhaseStream = New-Object IO.FileStream(($ResultPath + '.phase'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
        $payload = $Text
        $plan = Get-Variable -Name WorkPlan -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $plan -and $null -ne $plan.Value) {
            $total = @($plan.Value).Count
            $completed = $script:WorkCompleted.Count
            $percent = [Math]::Min(99, [int][Math]::Floor(100.0 * $completed / $total))
            $payload = ConvertTo-Json -InputObject ([ordered]@{ Text = $Text; Completed = $completed; Total = $total; Percent = $percent }) -Compress
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $script:PhaseStream.Position = 0
        $script:PhaseStream.SetLength(0)
        $script:PhaseStream.Write($bytes, 0, $bytes.Length)
        $script:PhaseStream.Flush()
    } catch { }
}
function Is-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Is-PrivateIPv4([string]$Address) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $ip.GetAddressBytes()
    return ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168))
}
function Get-Subnet([string]$Address, [int]$Prefix) {
    if ($Prefix -lt 1 -or $Prefix -gt 32) { throw 'Ungültige IPv4-Netzmaske.' }
    $b = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    $n = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $Prefix - 8 * $i))
        $mask = 0
        if ($bits -gt 0) { $mask = 256 - [Math]::Pow(2, 8 - $bits) }
        $n[$i] = $b[$i] -band [int]$mask
    }
    return ((New-Object Net.IPAddress(,$n)).ToString() + '/' + $Prefix)
}
function Get-HomeNetworks {
    # Prefer the native, confirmed private LAN inventory. This also keeps the
    # Windows client connection helper usable when the CIM providers are slow.
    if ('EinfachNetzwerk.NativeHomeNetworks' -as [type]) {
        try {
            $nativeNetworks = [EinfachNetzwerk.NativeHomeNetworks]::ReadJson() | ConvertFrom-Json
            if (@($nativeNetworks).Count -gt 0) { foreach ($nativeNetwork in $nativeNetworks) { $nativeNetwork }; return }
        } catch { Add-Check 'Native Heimnetzerkennung' warning $_.Exception.Message 'SERVICE_NATIVE_NETWORK_UNAVAILABLE' }
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction Stop)) {
        # NDIS physical media: unspecified physical NIC, ethernet, wireless LAN.
        if ([string]$adapter.Status -ne 'Up' -or -not $adapter.HardwareInterface -or $adapter.Virtual) { continue }
        if ([string]$adapter.InterfaceDescription -match '(?i)VPN|TAP-|TUN|WireGuard|Virtual|Hyper-V|VMware|VirtualBox|Bluetooth') { continue }
        $media = [int](Get-Value $adapter 'NdisPhysicalMedium' 0)
        if ($media -notin @(0, 1, 9, 14)) { continue }
        $config = Get-NetIPConfiguration -InterfaceIndex ([int]$adapter.ifIndex) -ErrorAction Stop
        $gateway = @($config.IPv4DefaultGateway | Where-Object { Is-PrivateIPv4 ([string]$_.NextHop) } | Select-Object -First 1)
        if ($gateway.Count -eq 0) { continue }
        $addresses = @($config.IPv4Address | Where-Object { Is-PrivateIPv4 ([string]$_.IPAddress) } | Sort-Object SkipAsSource)
        if ($addresses.Count -eq 0) { continue }
        $address = $addresses[0]
        $prefix = [int]$address.PrefixLength
        $first = ([Net.IPAddress]::Parse([string]$address.IPAddress)).GetAddressBytes()[0]
        $minimumPrefix = 16
        if ($first -eq 10) { $minimumPrefix = 8 }
        elseif ($first -eq 172) { $minimumPrefix = 12 }
        if ($prefix -lt $minimumPrefix -or $prefix -gt 32) {
            Add-Check 'Heimnetz-Maske' warning ($adapter.Name + ' hat ein IPv4-Subnetz, das öffentliche Adressen umfasst. Diese Verbindung wird nicht für automatische Firewall-Freigaben angeboten.')
            continue
        }
        $subnet = Get-Subnet ([string]$address.IPAddress) $prefix
        if ((Get-Subnet ([string]$gateway[0].NextHop) $prefix) -ne $subnet) { continue }
        $profile = @(Get-NetConnectionProfile -InterfaceIndex ([int]$adapter.ifIndex) -ErrorAction Stop | Select-Object -First 1)
        if ($profile.Count -eq 0) { continue }
        $category = [string]$profile[0].NetworkCategory
        if ($category -eq 'DomainAuthenticated') { continue }
        $items.Add([pscustomobject]@{
            Id = [int]$adapter.ifIndex; Name = [string]$adapter.Name
            Address = [string]$address.IPAddress
            Subnet = $subnet
            Category = $category; Gateway = [string]$gateway[0].NextHop
        })
    }
    return @($items.ToArray())
}
function Assert-NoReparse([string]$Path) {
    $current = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Dieser Pfad enthält eine Verknüpfung/Junction. Bitte den tatsächlichen lokalen Ordner wählen.'
        }
        $parent = Get-Value $current 'Parent' $null
        if ($null -eq $parent -and $current -is [IO.FileInfo]) { $parent = $current.Directory }
        $current = $parent
    }
}
function Resolve-ShareFolder($Request) {
    $inputPath = [string](Get-Value $Request 'FolderPath' '')
    if ([string]::IsNullOrWhiteSpace($inputPath)) { throw 'Bitte einen vorhandenen Ordner auswählen.' }
    if ($inputPath -notmatch '^[A-Za-z]:[\\/]') { throw 'Nur lokale Ordner und Datenlaufwerke sind möglich; kein UNC- oder relativer Pfad.' }
    $full = [IO.Path]::GetFullPath($inputPath).TrimEnd([char[]]'\/')
    if ($full -match '^[A-Za-z]:$') { $full += '\' }
    if ($full.Substring(2).Contains(':')) { throw 'Alternative NTFS-Datenströme sind als Ordner nicht zulässig.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo]) { throw 'Bitte einen Ordner auswählen, keine einzelne Datei.' }
    Assert-NoReparse $full
    $root = [IO.Path]::GetPathRoot($full)
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) { throw 'Nur lokale Festplatten und Wechseldatenträger können freigegeben werden.' }
    $systemRoot = [IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows'))
    $isRoot = $full.TrimEnd('\') -ieq $root.TrimEnd('\')
    if ($isRoot -and $root -ieq $systemRoot) {
        throw 'Die ganze Windows-Systemfestplatte wird zum Schutz von Windows nicht freigegeben. Bitte einen Datenordner wählen, z. B. C:\Freigabe.'
    }
    if ($isRoot -and -not [bool](Get-Value $Request 'AllowDriveRoot' $false)) { throw 'Eine ganze Datenfestplatte benötigt die ausdrückliche Bestätigung „Ganzes Datenlaufwerk freigeben“.' }
    $protected = @([Environment]::GetFolderPath('Windows'), [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'), [Environment]::GetFolderPath('CommonApplicationData'), $script:LedgerRoot)
    foreach ($p in $protected) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $p = $p.TrimEnd('\')
        if ($full -ieq $p -or $full.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Windows-, Programm- und systemweite Konfigurationsordner können nicht freigegeben werden. Bitte einen Datenordner wählen.'
        }
    }
    # Never expose this application's management store via an ancestor folder.
    if ($script:LedgerRoot.StartsWith($full.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Dieser Ordner enthält geschützte Windows-Konfiguration. Bitte einen reinen Datenordner wählen.' }
    return [pscustomobject]@{ Path = $full; Format = [string]$drive.DriveFormat; IsRoot = $isRoot }
}
function Assert-ShareName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80 -or $Name -match '[\\/\[\]:;|=,+*?<>"\x00-\x1f]' -or $Name.Contains('$') -or $Name -match '^\s|\s$|\.$') {
        throw 'Ungültiger Freigabename: 1–80 Zeichen, ohne $, Schrägstriche oder Sonderzeichen wie : * ?.'
    }
    if ($Name -match '^(?i:IPC|ADMIN|PRINT)\$?$') { throw 'Dieser Name ist für Windows reserviert.' }
}
function Assert-IndependentFolder([string]$Name, [string]$Path) {
    $target = $Path.TrimEnd('\')
    $managedOthers = @()
    if ($null -ne $script:Ledger) { $managedOthers = @($script:Ledger.Shares | Where-Object { $_.Name -ine $Name }) }
    foreach ($other in $managedOthers) {
        $p = [string](Get-Value $other 'Path' '')
        if ([string]::IsNullOrEmpty($p)) { continue }
        $p = $p.TrimEnd('\')
        if ($p -ieq $target -or $p.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw ('Der Ordner überschneidet sich mit der Freigabe „' + $other.Name + '“. Bitte diese vorhandene Freigabe bearbeiten oder einen unabhängigen Ordner wählen; ihre Rechte bleiben erhalten.')
        }
    }
    foreach ($other in @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special -and $_.Name -notlike '*$' -and $_.Name -ine $Name })) {
        $p = ([string]$other.Path).TrimEnd('\')
        if ($p -ieq $target -or $p.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Add-Check 'Bestehende Freigabe im Datenbereich' warning ('Der gewählte Bereich überschneidet sich mit „' + $other.Name + '“. Deren Freigaberechte und ursprüngliche Ordnerberechtigungen bleiben erhalten. Ein Passwort schützt nur die hier gewählte Freigabe; vorhandene Freigaben können dieselben Dateien weiterhin mit ihren bisherigen Rechten öffnen. Neue vererbte NTFS-Rechte innerhalb Ihres gewählten Bereichs können auch dort wirksam werden.')
        }
    }
}
function Get-ShareSnapshot([string]$Name) {
    $found = @(Get-SmbShare -Name $Name -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    $share = $found[0]
    if ($share.Special -or [string]$share.Name -like '*$') { throw 'Administrative Windows-Freigaben werden nicht verändert.' }
    return [pscustomobject]@{
        Name = [string]$share.Name; Path = [string]$share.Path
        Description = [string]$share.Description; SecurityDescriptor = [string]$share.SecurityDescriptor
        EncryptData = [bool]$share.EncryptData
        CachingMode = [string]$share.CachingMode
        FolderEnumerationMode = [string]$share.FolderEnumerationMode
        ConcurrentUserLimit = [int]$share.ConcurrentUserLimit
    }
}
function Get-Managed([string]$Name) {
    if ($null -eq $script:Ledger) { return $null }
    return (@($script:Ledger.Shares | Where-Object { $_.Name -ieq $Name }) | Select-Object -First 1)
}
function Read-Ledger {
    if (-not (Test-Path -LiteralPath $script:LedgerFile -PathType Leaf)) { return $null }
    Assert-NoReparse $script:LedgerRoot
    Assert-NoReparse $script:LedgerFile
    $state = [IO.File]::ReadAllText($script:LedgerFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int](Get-Value $state 'Version' 0) -ne 1 -or [string](Get-Value $state 'App' '') -ne $script:AppMark) { throw 'Das Freigabejournal ist unbekannt oder beschädigt. Es werden keine Änderungen vorgenommen.' }
    return $state
}
function Assert-LedgerProtection {
    if (-not (Test-Path -LiteralPath $script:LedgerRoot)) { return }
    Assert-NoReparse $script:LedgerRoot
    $acl = Get-Acl -LiteralPath $script:LedgerRoot
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-32-544', 'S-1-5-18')) { throw 'Der Konfigurationsordner hat keinen vertrauenswürdigen Besitzer. Er muss von einem Administrator geprüft werden.' }
    $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if (($rule.FileSystemRights -band $writeMask) -ne 0 -and $rule.IdentityReference.Value -notin @('S-1-5-32-544', 'S-1-5-18')) { throw 'Der Konfigurationsordner ist durch andere Benutzer beschreibbar. Automatische Änderungen werden gestoppt.' }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $script:LedgerRoot -File -Force)) {
        Assert-NoReparse $file.FullName
        $fAcl = Get-Acl -LiteralPath $file.FullName
        if ($fAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-32-544','S-1-5-18')) { throw 'Ein Freigabejournal hat keinen vertrauenswürdigen Besitzer. Ein Administrator muss es prüfen.' }
        foreach ($rule in $fAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeMask) -ne 0 -and $rule.IdentityReference.Value -notin @('S-1-5-32-544', 'S-1-5-18')) { throw 'Ein Freigabejournal wurde unsicher geändert. Ein Administrator muss es prüfen.' }
        }
    }
}
function Initialize-LedgerDirectory {
    if (Test-Path -LiteralPath $script:LedgerRoot) { Assert-LedgerProtection; return }
    New-Item -ItemType Directory -Path $script:LedgerRoot -ErrorAction Stop | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Snapshots contain configuration, never passwords; users may inspect them.
    $readRule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($readRule)
    Set-Acl -LiteralPath $script:LedgerRoot -AclObject $acl
    Assert-LedgerProtection
}
function Write-JsonAtomic([string]$Path, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 18
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    try {
        $fileAcl = Get-Acl -LiteralPath $temp
        $fileAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $temp -AclObject $fileAcl
        # PowerShell coerces $null to an empty string for a typed string
        # parameter. File.Replace needs an actual CLR null backup filename.
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Get-RegistrySnapshot([string]$Path, [string]$Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key -or $Name -notin @($key.GetValueNames())) { return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Kind = ''; Value = $null } }
    return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $true; Kind = [string]$key.GetValueKind($Name); Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
}
function Restore-Registry($Snapshot) {
    if ($Snapshot.Exists) {
        # The registry provider's New-Item -Force can replace an existing key
        # and delete unrelated values/subkeys (including service definitions).
        # Create only a missing key, without Force, then restore one value.
        if (-not (Test-Path -LiteralPath $Snapshot.Path -ErrorAction Stop)) {
            New-Item -Path $Snapshot.Path -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -Value $Snapshot.Value -PropertyType $Snapshot.Kind -Force | Out-Null
    } else {
        if (-not (Test-Path -LiteralPath $Snapshot.Path -ErrorAction Stop)) { return }
        $key = Get-Item -LiteralPath $Snapshot.Path -ErrorAction Stop
        if ($Snapshot.Name -in @($key.GetValueNames())) {
            Remove-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -ErrorAction Stop
        }
    }
}
function Get-NullShares {
    $reg = Get-RegistrySnapshot 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'NullSessionShares'
    if ($reg.Exists -and $reg.Kind -ne 'MultiString') { throw 'Windows NullSessionShares ist kein REG_MULTI_SZ. Die vorhandene Konfiguration muss zunächst geprüft werden.' }
    return @($reg.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
function Set-NullShare([string]$Name, [bool]$Enabled) {
    $values = @(Get-NullShares | Where-Object { $_ -ine $Name })
    if ($Enabled) { $values += $Name }
    New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name NullSessionShares -Value ([string[]]$values) -PropertyType MultiString -Force | Out-Null
}
function Load-Native {
    if ('EinfachNetzwerk.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace EinfachNetzwerk {
  public static class Native {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public uint Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountRights(IntPtr handle, byte[] sid, out IntPtr rights, out uint count);
    [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr handle, byte[] sid, [MarshalAs(UnmanagedType.U1)]bool allRights, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr memory);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    static IntPtr Open(bool write) {
      var attrs = new LSA_OBJECT_ATTRIBUTES(); attrs.Length = (uint)Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
      IntPtr handle; Check(LsaOpenPolicy(IntPtr.Zero, ref attrs, write ? 0x00000810u : 0x00000800u, out handle)); return handle;
    }
    static byte[] Bytes(string sid) { var s = new SecurityIdentifier(sid); var b = new byte[s.BinaryLength]; s.GetBinaryForm(b, 0); return b; }
    static void Check(uint status) { if(status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status)); }
    public static string[] Rights(string sid) {
      IntPtr handle = Open(false), memory = IntPtr.Zero;
      try {
        uint count; uint status = LsaEnumerateAccountRights(handle, Bytes(sid), out memory, out count);
        if(status == 0xC0000034u) return new string[0]; Check(status);
        var rights = new List<string>(); int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));
        for(int i=0; i<count; i++) { var r = (LSA_UNICODE_STRING)Marshal.PtrToStructure(IntPtr.Add(memory, i*size), typeof(LSA_UNICODE_STRING)); rights.Add(Marshal.PtrToStringUni(r.Buffer, r.Length/2)); }
        return rights.ToArray();
      } finally { if(memory!=IntPtr.Zero) LsaFreeMemory(memory); LsaClose(handle); }
    }
    public static void Right(string sid, string right, bool enabled) {
      var existing = Rights(sid); bool found = Array.IndexOf(existing, right) >= 0; if(found == enabled) return;
      IntPtr handle = Open(true), text = Marshal.StringToHGlobalUni(right);
      try { var r = new LSA_UNICODE_STRING { Buffer = text, Length = (ushort)(right.Length*2), MaximumLength = (ushort)(right.Length*2+2) }; var rights = new[] {r};
        Check(enabled ? LsaAddAccountRights(handle, Bytes(sid), rights, 1) : LsaRemoveAccountRights(handle, Bytes(sid), false, rights, 1));
      } finally { Marshal.FreeHGlobal(text); LsaClose(handle); }
    }
    public static int NetworkLogon(string user, string password) {
      IntPtr token; if(!LogonUser(user, Environment.MachineName, password, 3, 0, out token)) return Marshal.GetLastWin32Error();
      CloseHandle(token); return 0;
    }
  }
}
'@
}
function Get-Guest {
    return (@(Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -match '-501$' }) | Select-Object -First 1)
}
function Snapshot-User($User) {
    if ($null -eq $User) { return $null }
    Load-Native
    return [pscustomobject]@{ Name = [string]$User.Name; Sid = [string]$User.SID.Value; Enabled = [bool]$User.Enabled; Description = [string]$User.Description; Rights = @([EinfachNetzwerk.Native]::Rights($User.SID.Value)) }
}
function Restore-User($Snapshot) {
    if ($null -eq $Snapshot) { return }
    $user = Get-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($Snapshot.Sid)) -ErrorAction Stop
    if ($Snapshot.Enabled) { Enable-LocalUser -SID $user.SID } else { Disable-LocalUser -SID $user.SID }
    foreach ($right in @('SeDenyNetworkLogonRight', 'SeNetworkLogonRight', 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight')) {
        [EinfachNetzwerk.Native]::Right($Snapshot.Sid, $right, ($right -in @($Snapshot.Rights)))
    }
}
function Assert-OwnedUser([string]$Name) {
    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,19}$' -or $Name -match '^(?i:Administrator|Admin|Guest|Gast|DefaultAccount|WDAGUtilityAccount)$') { throw 'Benutzername: mit einem Buchstaben beginnen, höchstens 20 Buchstaben/Ziffern oder . _ -; keine Windows-Systemkonten.' }
    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $user) { return $null }
    $owned = @()
    if ($null -ne $script:Ledger) { $owned = @($script:Ledger.CreatedUsers | Where-Object { $_.Name -ieq $Name -and $_.Sid -eq $user.SID.Value }) }
    if ($owned.Count -eq 0 -or $user.Description -ne $script:AppMark) { throw 'Dieser Benutzer existiert bereits und gehört nicht zu diesem Programm. Bitte einen neuen Namen wählen; vorhandene Konten bleiben unverändert.' }
    $admins = @(Get-LocalGroupMember -SID (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')) -ErrorAction Stop | Where-Object { $_.SID.Value -eq $user.SID.Value })
    if ($admins.Count -gt 0) { throw 'Das Freigabekonto ist Mitglied der Administratoren. Bitte einen neuen, normalen Freigabebenutzer wählen.' }
    return $user
}
function Unprotect-Password($Request) {
    $protected = [string](Get-Value $Request 'ProtectedPassword' '')
    if ([string]::IsNullOrEmpty($protected)) { return $null }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($sid -ne [string](Get-Value $Request 'OriginalUserSid' '')) { throw 'Die Administratoranmeldung verwendet ein anderes Windows-Konto. Das verschlüsselte Passwort kann nur im ursprünglichen Benutzerkonto geöffnet werden.' }
    Add-Type -AssemblyName System.Security
    $bytes = $null; $plain = $null
    try {
        $bytes = [Convert]::FromBase64String($protected)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, [Text.Encoding]::UTF8.GetBytes('EinfachNetzwerk-v1'), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch { throw 'Das verschlüsselte Passwort konnte nicht geöffnet werden. Bitte das Programm erneut öffnen und das Passwort eingeben.' }
    finally { if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }; if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}
function Get-ServiceSnapshot([string]$Name) {
    if (Get-Command Get-ServiceNativeSnapshot -ErrorAction SilentlyContinue) {
        $native = Get-ServiceNativeSnapshot $Name
        if (-not $native.Exists) { throw (New-Object ComponentModel.Win32Exception(1060)) }
        return [pscustomobject]@{ Name=$Name; State=[string]$native.State; StartMode=[string]$native.StartMode; Delayed=Get-RegistrySnapshot ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name) 'DelayedAutoStart' }
    }
    $s = Get-CimInstance Win32_Service -Filter ("Name='" + $Name + "'") -OperationTimeoutSec 5 -ErrorAction Stop
    if ($null -eq $s) { throw "Der Windows-Dienst $Name fehlt." }
    return [pscustomobject]@{ Name = $Name; State = [string]$s.State; StartMode = [string]$s.StartMode; Delayed = Get-RegistrySnapshot ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name) 'DelayedAutoStart' }
}
function Get-FirewallSnapshots([string]$Prefix) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name.StartsWith($Prefix, [StringComparison]::Ordinal) -and $_.Group -eq $script:RuleGroup })) {
        $p = $r | Get-NetFirewallPortFilter
        $a = $r | Get-NetFirewallAddressFilter
        $app = $r | Get-NetFirewallApplicationFilter
        $svc = $r | Get-NetFirewallServiceFilter
        $iface = $r | Get-NetFirewallInterfaceFilter
        $list.Add([pscustomobject]@{ Name = [string]$r.Name; DisplayName = [string]$r.DisplayName; Group = [string]$r.Group; Description = [string]$r.Description; Enabled = [string]$r.Enabled; Profile = [string]$r.Profile; Direction = [string]$r.Direction; Action = [string]$r.Action; Protocol = [string]$p.Protocol; LocalPort = @($p.LocalPort); RemotePort = @($p.RemotePort); LocalAddress = @($a.LocalAddress); RemoteAddress = @($a.RemoteAddress); Program = [string]$app.Program; Service = [string]$svc.Service; InterfaceAlias = @($iface.InterfaceAlias) })
    }
    return @($list.ToArray())
}
function Rule-Prefix([string]$Name) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name.ToLowerInvariant()))).Replace('-', '').Substring(0,16) }
    finally { $sha.Dispose() }
    return 'EinfachNetzwerk-' + $hash + '-'
}
function Clear-ManagedRules([string]$Prefix) {
    foreach ($r in @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name.StartsWith($Prefix, [StringComparison]::Ordinal) })) {
        if ($r.Group -ne $script:RuleGroup) { throw 'Eine vorhandene Firewall-Regel hat denselben Namen und gehört nicht zum Programm. Die Regel bleibt unverändert.' }
        $r | Remove-NetFirewallRule -ErrorAction Stop
    }
}
function Restore-Firewall($Rules, [string]$Prefix) {
    Clear-ManagedRules $Prefix
    foreach ($r in @($Rules)) {
        $parameters = @{}
        foreach ($p in @('Name','DisplayName','Group','Description','Enabled','Profile','Direction','Action','Protocol','LocalPort','RemotePort','LocalAddress','RemoteAddress','Program','Service','InterfaceAlias')) { $parameters[$p] = $r.$p }
        New-NetFirewallRule @parameters -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
    }
}
function Get-DiscoveryShareDescription([string]$Mode, [string]$Account) {
    if ($Mode -notin @('Guest','Password')) { throw 'Ungültiger Freigabemodus für die Heimnetz-Datenmeldung.' }
    $Mode = if ($Mode -ieq 'Guest') { 'Guest' } else { 'Password' }
    if ([string]::IsNullOrWhiteSpace($Account) -or $Account.Length -gt 20 -or $Account -in @('.','..') -or $Account -match '["/\\\[\]:;|=,+*?<>\x00-\x1f\x7f]') { throw 'Ungültiger Netzwerk-Benutzer für die Heimnetz-Datenmeldung.' }
    return '[EinfachNetzwerk:1;mode=' + $Mode + ';computer=' + [Uri]::EscapeDataString($env:COMPUTERNAME) + ';user=' + [Uri]::EscapeDataString($Account) + ']'
}
function Get-RequestDiscoveryDescription($Request) {
    $account = [string](Get-Value $Request 'UserName' '')
    if ([string]$Request.Mode -ieq 'Guest') { $account = [string](Get-Guest).Name }
    return Get-DiscoveryShareDescription ([string]$Request.Mode) $account
}
function Get-DiscoveryExecutable {
    $appType = 'EinfachNetzwerk.AppInfo' -as [type]
    if ($null -eq $appType) { return $null }
    $location = [string]$appType.Assembly.Location
    if ([IO.Path]::GetExtension($location) -ine '.exe' -or -not [IO.File]::Exists($location) -or $location.StartsWith('\\')) { return $null }
    return [IO.Path]::GetFullPath($location)
}
function Get-DiscoveryLocalAddresses($Network) {
    $scope = Normalize-IPv4FirewallScope ([string]$Network.Subnet)
    if ([string]::IsNullOrWhiteSpace($scope) -or -not (Is-PrivateIPv4 ([string]$Network.Address))) { throw 'Ungültiges Heimnetz für die Freigabedaten.' }
    $parts = $scope.Split('/'); $prefix = [int]$parts[1]
    if ($prefix -lt 8 -or $prefix -gt 30 -or (Normalize-IPv4FirewallScope ($Network.Address + '/' + $prefix)) -ne $scope) { throw 'Ungeeignetes Heimnetz für die Freigabedaten.' }
    $bytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    for ($index=0; $index -lt 4; $index++) {
        $used = [Math]::Min(8, [Math]::Max(0, $prefix - 8*$index))
        $bytes[$index] = $bytes[$index] -bor ((1 -shl (8-$used))-1)
    }
    return @([string]$Network.Address, (New-Object Net.IPAddress -ArgumentList (,$bytes)).ToString())
}
function Configure-Firewall($Network, [string]$Prefix) {
    Clear-ManagedRules $Prefix
    # System owns the kernel SMB listener. A LanmanServer service-only rule does
    # not match its traffic. Never open SMB on Public profiles or the internet.
    New-NetFirewallRule -PolicyStore PersistentStore -Name ($Prefix + 'SMB') -DisplayName ('EinfachNetzwerk: SMB · ' + $Network.Name) -Group $script:RuleGroup -Description $script:AppMark -Direction Inbound -Action Allow -Enabled True -Profile Private -Protocol TCP -LocalPort 445 -RemotePort Any -Program System -Service Any -InterfaceAlias $Network.Name -LocalAddress $Network.Address -RemoteAddress $Network.Subnet -EdgeTraversalPolicy Block | Out-Null
    # Public connection presets from this running application only. The same
    # managed prefix/snapshot restores or removes this rule with the share.
    $discoveryExe = Get-DiscoveryExecutable
    if (-not [string]::IsNullOrWhiteSpace($discoveryExe)) {
        New-NetFirewallRule -PolicyStore PersistentStore -Name ($Prefix + 'Discovery') -DisplayName ('EinfachNetzwerk: Freigabedaten · ' + $Network.Name) -Group $script:RuleGroup -Description $script:AppMark -Direction Inbound -Action Allow -Enabled True -Profile Private -Protocol UDP -LocalPort 41671 -RemotePort Any -Program $discoveryExe -Service Any -InterfaceAlias $Network.Name -LocalAddress (Get-DiscoveryLocalAddresses $Network) -RemoteAddress $Network.Subnet -EdgeTraversalPolicy Block | Out-Null
    }
    # Clone only actual built-in WSD discovery templates; OS releases have
    # different service/program filters. Original Windows rules stay untouched.
    $templates = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name -match '^NETDIS-(WSD|WSDEVNTS|FDResPub|FDPHOST)' -and $_.Action -eq 'Allow' })
    $index = 0
    foreach ($rule in $templates) {
        $port = $rule | Get-NetFirewallPortFilter
        $proto = [string]$port.Protocol
        if ($proto -notin @('TCP','UDP','6','17')) { continue }
        $ports = @($port.LocalPort) + @($port.RemotePort)
        if (@($ports | Where-Object { $_ -in @('3702','5357','5358') }).Count -eq 0) { continue }
        $app = $rule | Get-NetFirewallApplicationFilter
        $svc = $rule | Get-NetFirewallServiceFilter
        $localAddress = @($Network.Address)
        $remoteAddress = @($Network.Subnet)
        if ($proto -in @('UDP','17')) {
            # WSD probes arrive at the multicast destination 239.255.255.250,
            # not at this NIC's unicast address. Restrict ingress by source and
            # interface; allow multicast only in outbound discovery templates.
            if ([string]$rule.Direction -eq 'Inbound') { $localAddress = @('Any') }
            else { $remoteAddress += '239.255.255.250' }
        }
        $index++
        New-NetFirewallRule -PolicyStore PersistentStore -Name ($Prefix + 'WSD-' + $index) -DisplayName ('EinfachNetzwerk: Erkennung · ' + $Network.Name + ' · ' + $index) -Group $script:RuleGroup -Description $script:AppMark -Direction $rule.Direction -Action Allow -Enabled True -Profile Private -Protocol $proto -LocalPort $port.LocalPort -RemotePort $port.RemotePort -Program $app.Program -Service $svc.Service -InterfaceAlias $Network.Name -LocalAddress $localAddress -RemoteAddress $remoteAddress -EdgeTraversalPolicy Block | Out-Null
    }
    if ($index -eq 0) { Add-Check 'Netzwerkerkennung' warning 'Windows stellt hier keine passenden WSD-Regelvorlagen bereit. Direkter Zugriff über IP/SMB bleibt möglich; Explorer-Erkennung kann fehlen.' }
}
function Includes-SmbPort($Port) {
    foreach ($p in @($Port)) {
        if ([string]$p -in @('Any','445')) { return $true }
        if ([string]$p -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le 445 -and [int]$Matches[2] -ge 445) { return $true }
    }
    return $false
}
function Normalize-IPv4FirewallScope([string]$Scope) {
    if ([string]::IsNullOrWhiteSpace($Scope)) { return $null }
    $parts = $Scope.Trim().Split('/')
    if ($parts.Count -gt 2) { return $null }
    $ipv4Pattern = '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$'
    if ($parts[0] -notmatch $ipv4Pattern) { return $null }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $prefix = 32
    if ($parts.Count -eq 2) {
        if ($parts[1] -match '^(?:0|[1-9]|[12][0-9]|3[0-2])$') { $prefix = [int]$parts[1] }
        elseif ($parts[1] -match $ipv4Pattern) {
            $mask = $null
            if (-not [Net.IPAddress]::TryParse($parts[1], [ref]$mask) -or $mask.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $null }
            $prefix = 0; $sawZero = $false
            foreach ($byte in $mask.GetAddressBytes()) {
                for ($bit = 7; $bit -ge 0; $bit--) {
                    if (($byte -band (1 -shl $bit)) -ne 0) {
                        if ($sawZero) { return $null }
                        $prefix++
                    } else { $sawZero = $true }
                }
            }
        } else { return $null }
    }
    if ($prefix -eq 0) { return '0.0.0.0/0' }
    return (Get-Subnet $address.ToString() $prefix)
}
function Test-IPv4FirewallScope($Actual, [string]$Expected) {
    $values = @($Actual)
    if ($values.Count -ne 1) { return $false }
    $wanted = Normalize-IPv4FirewallScope $Expected
    if ([string]::IsNullOrEmpty($wanted)) { return $false }
    return ((Normalize-IPv4FirewallScope ([string]$values[0])) -ceq $wanted)
}
function Test-ManagedSmbFirewallRule($Rule, $Network) {
    if ($null -eq $Rule -or $null -eq $Network) { return $false }
    if ($Rule.Enabled -ne 'True' -or $Rule.Profile -ne 'Private' -or $Rule.Program -ne 'System' -or $Rule.Service -ne 'Any') { return $false }
    if (-not (Test-IPv4FirewallScope $Rule.LocalAddress $Network.Address) -or -not (Test-IPv4FirewallScope $Rule.RemoteAddress $Network.Subnet)) { return $false }
    if (@($Rule.InterfaceAlias).Count -ne 1 -or [string]$Rule.InterfaceAlias[0] -ine $Network.Name) { return $false }
    # Real firewall snapshots have all of these fields. Keep older diagnostic
    # records readable, while validating every available traffic filter.
    $direction = Get-Value $Rule 'Direction' $null
    $action = Get-Value $Rule 'Action' $null
    $protocol = Get-Value $Rule 'Protocol' $null
    $ports = Get-Value $Rule 'LocalPort' $null
    if ($null -ne $direction -and [string]$direction -ne 'Inbound') { return $false }
    if ($null -ne $action -and [string]$action -ne 'Allow') { return $false }
    if ($null -ne $protocol -and [string]$protocol -notin @('TCP','6')) { return $false }
    if ($null -ne $ports -and (@($ports).Count -ne 1 -or [string]@($ports)[0] -ne '445')) { return $false }
    return $true
}
function Test-ManagedDiscoveryFirewallRule($Rule, $Network, [string]$Executable) {
    if ($null -eq $Rule -or $null -eq $Network -or [string]::IsNullOrWhiteSpace($Executable)) { return $false }
    if ([string]$Rule.Enabled -ne 'True' -or [string]$Rule.Profile -ne 'Private' -or [string]$Rule.Program -ine $Executable -or [string]$Rule.Service -ne 'Any') { return $false }
    if ([string]$Rule.Direction -ne 'Inbound' -or [string]$Rule.Action -ne 'Allow' -or [string]$Rule.Protocol -notin @('UDP','17')) { return $false }
    if (@($Rule.LocalPort).Count -ne 1 -or [string]@($Rule.LocalPort)[0] -ne '41671') { return $false }
    if (@($Rule.InterfaceAlias).Count -ne 1 -or [string]@($Rule.InterfaceAlias)[0] -ine $Network.Name) { return $false }
    $expected = @(Get-DiscoveryLocalAddresses $Network | ForEach-Object { Normalize-IPv4FirewallScope $_ } | Sort-Object)
    $actual = @($Rule.LocalAddress | ForEach-Object { Normalize-IPv4FirewallScope ([string]$_) } | Sort-Object -Unique)
    if (@($Rule.LocalAddress).Count -ne 2 -or $actual.Count -ne 2 -or [string]::Join(';',$expected) -cne [string]::Join(';',$actual)) { return $false }
    return Test-IPv4FirewallScope $Rule.RemoteAddress $Network.Subnet
}
function Inspect-OtherSmbRules($Network) {
    $broad = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop | Where-Object { $_.Group -ne $script:RuleGroup })) {
        $port = $rule | Get-NetFirewallPortFilter
        if ([string]$port.Protocol -notin @('TCP','6','Any','256') -or -not (Includes-SmbPort $port.LocalPort)) { continue }
        $program = $rule | Get-NetFirewallApplicationFilter
        $service = $rule | Get-NetFirewallServiceFilter
        if ([string]$program.Program -notin @('Any','System') -or [string]$service.Service -notin @('Any','LanmanServer')) { continue }
        $address = $rule | Get-NetFirewallAddressFilter
        $iface = $rule | Get-NetFirewallInterfaceFilter
        if ([string]$rule.Profile -ne 'Private' -or -not (Test-IPv4FirewallScope $address.RemoteAddress $Network.Subnet) -or -not (Test-IPv4FirewallScope $address.LocalAddress $Network.Address) -or @($iface.InterfaceAlias).Count -ne 1 -or [string]$iface.InterfaceAlias[0] -ne $Network.Name) { $broad.Add([string]$rule.DisplayName) }
    }
    if ($broad.Count -gt 0) {
        Add-Check 'Weitere SMB-Firewallregeln' warning ('Vorhandene Windows-/Fremdregeln können SMB über weitere Adapter, Netze oder Profile erlauben: ' + ((@($broad.ToArray()) | Select-Object -First 4) -join '; ') + '. Diese Regeln bleiben erhalten. Nur die Regeln dieses Programms sind auf die gewählte Verbindung begrenzt.')
    }
}
function Get-SystemSnapshot($Network, [string]$Prefix, $Guest, $User) {
    $config = Get-SmbServerConfiguration
    $groups = @()
    if ($null -ne $Guest) { Load-Native; $groups = @([pscustomobject]@{ Sid='S-1-5-32-546'; Rights=@([EinfachNetzwerk.Native]::Rights('S-1-5-32-546')) }) }
    $binding = $null
    if ((Advanced-Repair $script:Request) -and $Network.Id -ge 0 -and -not [string]::IsNullOrWhiteSpace([string](Get-Value $Network 'Name' ''))) { $binding = @(Get-NetAdapterBinding -Name $Network.Name -ComponentID ms_server -ErrorAction Stop | Select-Object -First 1); if ($binding.Count -gt 0) { $binding=[pscustomobject]@{Name=$Network.Name; Enabled=[bool]$binding[0].Enabled} } else { $binding=$null } }
    $bindings=@()
    $globalState=Get-Value $script:Ledger 'Global' $null
    foreach($savedBinding in @(Get-Value $globalState 'Bindings' @())) {
        $actualBinding=@(Get-NetAdapterBinding -Name $savedBinding.Name -ComponentID ms_server -ErrorAction SilentlyContinue | Select-Object -First 1)
        if($actualBinding.Count -gt 0) {$bindings+=@([pscustomobject]@{Name=$savedBinding.Name;Enabled=[bool]$actualBinding[0].Enabled})}
    }
    return [pscustomobject]@{
        Network = [pscustomobject]@{ Id = $Network.Id; Category = $Network.Category }
        Services = @(Get-ServiceSnapshot 'LanmanServer'; Get-ServiceSnapshot 'LanmanWorkstation'; Get-ServiceSnapshot 'FDResPub'; Get-ServiceSnapshot 'fdPHost')
        Server = [pscustomobject]@{ EnableSMB2Protocol = [bool]$config.EnableSMB2Protocol; RequireSecuritySignature = [bool]$config.RequireSecuritySignature }
        Registry = @(Get-RegistrySnapshot 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'NullSessionShares'; Get-RegistrySnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'ForceGuest')
        Guest = Snapshot-User $Guest; User = Snapshot-User $User
        Groups = $groups; Binding = $binding; Bindings=$bindings
        Firewall = @(Get-FirewallSnapshots $Prefix)
    }
}
function New-Transaction($Request, $Folder, $Network, $Guest, $User) {
    $name = [string]$Request.ShareName
    $sddl = $null
    if ($Folder.Format -in @('NTFS','ReFS')) { $sddl = (Get-Acl -LiteralPath $Folder.Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) }
    return [pscustomobject]@{ App = $script:AppMark; Version = 1; Created = [DateTime]::UtcNow.ToString('o'); ShareName = $name; FolderPath = $Folder.Path; FolderSddl = $sddl; Share = Get-ShareSnapshot $name; System = Get-SystemSnapshot $Network (Rule-Prefix $name) $Guest $User; CreatedUser = $null; Status = 'Prepared' }
}
function Restore-ShareSnapshot([string]$Name, $Snapshot) {
    $current = @(Get-SmbShare -Name $Name -ErrorAction SilentlyContinue)
    if ($null -eq $Snapshot) {
        if ($current.Count -gt 0) { Remove-SmbShare -Name $Name -Force -Confirm:$false }
        return
    }
    $parameters = @{ Name = $Name; SecurityDescriptor = $Snapshot.SecurityDescriptor; Description = $Snapshot.Description; EncryptData = [bool]$Snapshot.EncryptData; CachingMode = $Snapshot.CachingMode; FolderEnumerationMode = $Snapshot.FolderEnumerationMode; ConcurrentUserLimit = [int]$Snapshot.ConcurrentUserLimit }
    if ($current.Count -eq 0) { $parameters.Path = $Snapshot.Path; New-SmbShare @parameters | Out-Null }
    elseif ($current[0].Path -ieq $Snapshot.Path) { Set-SmbShare @parameters -Force | Out-Null }
    else { throw 'Die Freigabe zeigt inzwischen auf einen anderen Ordner. Sie wird nicht automatisch ersetzt.' }
}
function Restore-Folder([string]$Path, [string]$Sddl) {
    if ([string]::IsNullOrEmpty($Sddl)) { return }
    Assert-NoReparse $Path
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -LiteralPath $Path -AclObject $acl
    $actual = (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    if ($actual -ne $Sddl) { throw 'Die ursprünglichen Ordnerrechte konnten nicht vollständig wiederhergestellt werden.' }
}
function Restore-Service($Service) {
    $mode = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$Service.StartMode]
    if ($null -eq $mode) { throw 'Unbekannter gespeicherter Dienststarttyp.' }
    Set-Service -Name $Service.Name -StartupType $mode
    Restore-Registry $Service.Delayed
    if ($Service.State -eq 'Running') { Start-Service -Name $Service.Name }
    elseif ($Service.State -eq 'Stopped') { Stop-Service -Name $Service.Name -ErrorAction Stop }
}
function Remove-CreatedUser($User) {
    if ($null -eq $User) { return }
    $existing = Get-LocalUser -Name $User.Name -ErrorAction SilentlyContinue
    if ($null -eq $existing) { return }
    if ($existing.SID.Value -ne $User.Sid -or $existing.Description -ne $script:AppMark) { throw 'Das ursprünglich erstellte Konto wurde verändert; es wird nicht gelöscht.' }
    Remove-LocalUser -SID $existing.SID
}
function Test-CreatedUserReferenced($User, $ManagedShares, $LiveShares) {
    $sid = [string](Get-Value $User 'Sid' '')
    $name = [string](Get-Value $User 'Name' '')
    if ([string]::IsNullOrWhiteSpace($sid) -or [string]::IsNullOrWhiteSpace($name)) { throw 'Die gespeicherten Kontodaten sind unvollständig.' }
    # Reject malformed ownership data before deciding that an account is unused.
    $sid = (New-Object Security.Principal.SecurityIdentifier($sid)).Value
    foreach ($share in @($ManagedShares)) {
        $usedSid = [string](Get-Value $share 'UserSid' '')
        $usedName = [string](Get-Value $share 'UserName' '')
        if ($usedSid -eq $sid -or $usedName -ieq $name -or $usedName.EndsWith('\' + $name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($share in @($LiveShares)) {
        $sddl = [string](Get-Value $share 'SecurityDescriptor' '')
        if ([string]::IsNullOrWhiteSpace($sddl)) { throw 'Die Rechte einer bestehenden SMB-Freigabe konnten nicht vollständig gelesen werden.' }
        $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($sddl)
        if (($null -ne $descriptor.Owner -and $descriptor.Owner.Value -eq $sid) -or ($null -ne $descriptor.Group -and $descriptor.Group.Value -eq $sid)) { return $true }
        foreach ($acl in @($descriptor.DiscretionaryAcl, $descriptor.SystemAcl)) {
            if ($null -eq $acl) { continue }
            foreach ($ace in $acl) {
                # Preserve explicit references of any kind, including deny and
                # audit entries. A broad Users/Everyone grant alone is not an
                # explicit reuse of a particular dedicated network account.
                if ($ace -is [Security.AccessControl.KnownAce] -and $ace.SecurityIdentifier.Value -eq $sid) { return $true }
            }
        }
    }
    return $false
}
function Remove-UnusedCreatedUsers {
    if ($null -eq $script:Ledger) { return }
    foreach ($created in @($script:Ledger.CreatedUsers)) {
        try {
            # Include foreign and special shares. Read fresh before each account
            # deletion; an unreadable inventory or descriptor retains the account.
            $liveShares = @(Get-SmbShare -ErrorAction Stop)
            if (Test-CreatedUserReferenced $created @($script:Ledger.Shares) $liveShares) { continue }
            Remove-CreatedUser $created
            $script:Ledger.CreatedUsers = @($script:Ledger.CreatedUsers | Where-Object { $_.Sid -ne $created.Sid })
        } catch { Add-Check 'Kontobereinigung' warning ('Das eigene Freigabekonto ' + $created.Name + ' bleibt erhalten, weil seine sichere Entfernung nicht bestätigt werden konnte. Die verwalteten Kontodaten bleiben für eine spätere Prüfung erhalten.') }
    }
}
function Verify-TransactionRestored($Transaction) {
    $share = Get-ShareSnapshot $Transaction.ShareName
    if ($null -eq $Transaction.Share) { if ($null -ne $share) { throw 'Die neu erstellte Freigabe ist nach der Rücknahme noch vorhanden.' } }
    else {
        if ($null -eq $share -or $share.Path -ine $Transaction.Share.Path -or $share.EncryptData -ne $Transaction.Share.EncryptData) { throw 'Die ursprüngliche Freigabe wurde nicht vollständig wiederhergestellt.' }
        $actualSd = New-Object Security.AccessControl.RawSecurityDescriptor($share.SecurityDescriptor)
        $oldSd = New-Object Security.AccessControl.RawSecurityDescriptor($Transaction.Share.SecurityDescriptor)
        if ($actualSd.GetSddlForm([Security.AccessControl.AccessControlSections]::Access) -ne $oldSd.GetSddlForm([Security.AccessControl.AccessControlSections]::Access)) { throw 'Die ursprünglichen Freigaberechte wurden nicht vollständig wiederhergestellt.' }
    }
    $server = Get-SmbServerConfiguration
    if ([bool]$server.EnableSMB2Protocol -ne [bool]$Transaction.System.Server.EnableSMB2Protocol -or [bool]$server.RequireSecuritySignature -ne [bool]$Transaction.System.Server.RequireSecuritySignature) { throw 'Die früheren SMB-Servereinstellungen wurden nicht vollständig wiederhergestellt.' }
    foreach ($reg in @($Transaction.System.Registry)) {
        $actual = Get-RegistrySnapshot $reg.Path $reg.Name
        if ($actual.Exists -ne $reg.Exists -or ($reg.Exists -and ($actual.Kind -ne $reg.Kind -or (@($actual.Value) -join "`0") -cne (@($reg.Value) -join "`0")))) { throw ('Die frühere Registry-Einstellung ' + $reg.Name + ' wurde nicht vollständig wiederhergestellt.') }
    }
    foreach ($old in @($Transaction.System.Guest, $Transaction.System.User)) {
        if ($null -eq $old) { continue }
        $user = Get-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($old.Sid)) -ErrorAction Stop
        $actual = Snapshot-User $user
        if ($actual.Enabled -ne $old.Enabled) { throw 'Die frühere Aktivierung des Freigabekontos wurde nicht wiederhergestellt.' }
        foreach ($right in @('SeDenyNetworkLogonRight','SeNetworkLogonRight','SeDenyInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
            if (($right -in @($actual.Rights)) -ne ($right -in @($old.Rights))) { throw ('Das frühere Kontorecht ' + $right + ' wurde nicht wiederhergestellt.') }
        }
    }
    foreach($group in @(Get-Value $Transaction.System 'Groups' @())) {
        if (('SeDenyNetworkLogonRight' -in @([EinfachNetzwerk.Native]::Rights($group.Sid))) -ne ('SeDenyNetworkLogonRight' -in @($group.Rights))) {throw 'Die ursprüngliche Gast-Gruppensperre wurde nicht wiederhergestellt.'}
    }
    $bindings=@(Get-Value $Transaction.System 'Bindings' @())
    $binding=Get-Value $Transaction.System 'Binding' $null
    if ($null -ne $binding) {$bindings+=@($binding)}
    foreach($oldBinding in $bindings) {
        $actual=@(Get-NetAdapterBinding -Name $oldBinding.Name -ComponentID ms_server -ErrorAction Stop | Select-Object -First 1)
        if($actual.Count -ne 1 -or [bool]$actual[0].Enabled -ne [bool]$oldBinding.Enabled) {throw 'Die ursprüngliche SMB-Adapterbindung wurde nicht wiederhergestellt.'}
    }
    foreach ($service in @($Transaction.System.Services)) {
        $actual = Get-ServiceSnapshot $service.Name
        if ($actual.State -ne $service.State -or $actual.StartMode -ne $service.StartMode -or $actual.Delayed.Exists -ne $service.Delayed.Exists -or ($service.Delayed.Exists -and $actual.Delayed.Value -ne $service.Delayed.Value)) { throw ('Der frühere Zustand des Dienstes ' + $service.Name + ' wurde nicht vollständig wiederhergestellt.') }
    }
    $actualRules = @(Get-FirewallSnapshots (Rule-Prefix $Transaction.ShareName) | Sort-Object Name)
    $oldRules = @($Transaction.System.Firewall | Sort-Object Name)
    if ((ConvertTo-Json -InputObject $actualRules -Depth 6 -Compress) -cne (ConvertTo-Json -InputObject $oldRules -Depth 6 -Compress)) { throw 'Die ursprünglichen eigenen Firewall-Regeln wurden nicht vollständig wiederhergestellt.' }
    $profiles = @(Get-Value $Transaction.System 'Networks' @())
    if ($Transaction.System.Network.Id -ge 0) { $profiles += $Transaction.System.Network }
    foreach ($profile in $profiles) {
        $actual = Get-NetConnectionProfile -InterfaceIndex $profile.Id
        if ([string]$actual.NetworkCategory -ne $profile.Category) { throw 'Das ursprüngliche Netzwerkprofil wurde nicht vollständig wiederhergestellt.' }
    }
    if ($null -ne $Transaction.CreatedUser) {
        $remaining = Get-LocalUser -Name $Transaction.CreatedUser.Name -ErrorAction SilentlyContinue
        if ($null -ne $remaining -and $remaining.SID.Value -eq $Transaction.CreatedUser.Sid) { throw 'Das neu erstellte Freigabekonto ist nach der Rücknahme noch vorhanden.' }
    }
}
function Undo-Transaction($Transaction) {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $steps = @(
        { Restore-ShareSnapshot $Transaction.ShareName $Transaction.Share },
        { Restore-Folder $Transaction.FolderPath $Transaction.FolderSddl },
        { Restore-Firewall $Transaction.System.Firewall (Rule-Prefix $Transaction.ShareName) },
        { foreach ($reg in $Transaction.System.Registry) { Restore-Registry $reg } },
        { Set-SmbServerConfiguration -EnableSMB2Protocol $Transaction.System.Server.EnableSMB2Protocol -RequireSecuritySignature $Transaction.System.Server.RequireSecuritySignature -Force | Out-Null },
        { Restore-User $Transaction.System.Guest; Restore-User $Transaction.System.User; foreach ($group in @(Get-Value $Transaction.System 'Groups' @())) { [EinfachNetzwerk.Native]::Right($group.Sid, 'SeDenyNetworkLogonRight', ('SeDenyNetworkLogonRight' -in @($group.Rights))) } },
        { $bindings=@(Get-Value $Transaction.System 'Bindings' @()); $binding=Get-Value $Transaction.System 'Binding' $null; if($null -ne $binding) {$bindings+=@($binding)}; foreach($item in $bindings) { if ($item.Enabled) { Enable-NetAdapterBinding -Name $item.Name -ComponentID ms_server -ErrorAction Stop | Out-Null } else { Disable-NetAdapterBinding -Name $item.Name -ComponentID ms_server -ErrorAction Stop | Out-Null } } },
        { Remove-CreatedUser $Transaction.CreatedUser },
        { foreach ($service in $Transaction.System.Services) { Restore-Service $service } },
        { if ($Transaction.System.Network.Id -ge 0) { $profile = Get-NetConnectionProfile -InterfaceIndex $Transaction.System.Network.Id; if ([string]$profile.NetworkCategory -ne $Transaction.System.Network.Category) { Set-NetConnectionProfile -InterfaceIndex $Transaction.System.Network.Id -NetworkCategory $Transaction.System.Network.Category } }; foreach ($n in @(Get-Value $Transaction.System 'Networks' @())) { $profile = Get-NetConnectionProfile -InterfaceIndex $n.Id; if ([string]$profile.NetworkCategory -ne $n.Category) { Set-NetConnectionProfile -InterfaceIndex $n.Id -NetworkCategory $n.Category } } }
    )
    foreach ($step in $steps) { try { & $step } catch { $failures.Add($_.Exception.Message) } }
    if ($failures.Count -eq 0) { try { Verify-TransactionRestored $Transaction } catch { $failures.Add($_.Exception.Message) } }
    if ($failures.Count -gt 0) { Add-Check 'Rücknahme' error ('Rücknahme unvollständig: ' + ($failures -join ' | ')); return $false }
    Add-Check 'Rücknahme' ok 'Die zuvor gespeicherten Ordner-, Freigabe- und Windows-Einstellungen wurden zurückgesetzt.'
    return $true
}
function Configure-Folder($Folder, [string[]]$Sids, [bool]$Write, $Managed) {
    if ($Folder.Format -notin @('NTFS','ReFS')) {
        if ($Folder.Format -notin @('FAT','FAT32','exFAT')) { throw ('Das Dateisystem ' + $Folder.Format + ' wird nicht unterstützt.') }
        Add-Check 'Ordnerrechte' warning ($Folder.Format + ' unterstützt keine NTFS-Benutzerrechte. Die Zugriffsbeschränkung gilt über die SMB-Freigabe.')
        return
    }
    $acl = Get-Acl -LiteralPath $Folder.Path
    # On first apply, all original ACLs stay intact. On later updates, rebuild
    # only our principal's explicit allows from the original snapshot before
    # adding the new app grants. The share ACL controls read-only/password mode
    # even when an existing NTFS grant is broader. Never reduce a foreign grant.
    $removeSids = @('S-1-5-7') + @($Sids)
    $guest = Get-Guest
    if ($null -ne $guest) { $removeSids += $guest.SID.Value }
    if ($null -ne $Managed -and -not [string]::IsNullOrEmpty([string]$Managed.UserSid)) { $removeSids += $Managed.UserSid }
    if ($null -ne $Managed -and -not [string]::IsNullOrEmpty([string]$Managed.OriginalFolderSddl)) {
        $original = New-Object Security.AccessControl.DirectorySecurity
        $original.SetSecurityDescriptorSddlForm($Managed.OriginalFolderSddl, [Security.AccessControl.AccessControlSections]::Access)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
            if ($rule.IdentityReference.Value -in $removeSids -and $rule.AccessControlType -eq 'Allow') { [void]$acl.RemoveAccessRuleSpecific($rule) }
        }
        foreach ($rule in @($original.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
            if ($rule.IdentityReference.Value -in $removeSids -and $rule.AccessControlType -eq 'Allow') { $acl.AddAccessRule($rule) }
        }
    }
    $rights = 'ReadAndExecute'
    if ($Write) { $rights = 'Modify' }
    foreach ($sid in $Sids) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Folder.Path -AclObject $acl
}
function Get-ShareSddl([string[]]$Sids, [bool]$Write) {
    $mask = '0x1200a9'
    if ($Write) { $mask = '0x1301bf' }
    $sddl = 'O:BAG:BAD:(A;;FA;;;BA)(A;;FA;;;SY)'
    foreach ($sid in $Sids) { $sddl += '(A;;' + $mask + ';;;' + $sid + ')' }
    return $sddl
}
function Build-Connection($Request, $Network, [string]$UserName) {
    if ($null -eq $Network) { return }
    $name = [string](Get-Value $Request 'ShareName' '')
    $script:Result.Address = $Network.Address
    $script:Result.SharePath = '\\' + $env:COMPUTERNAME + '\' + $name
    $guestName = $UserName
    $record = Get-Managed $name
    if ($null -ne $record -and $record.Mode -ieq 'Guest') { $guestName = [string]$record.UserName }
    elseif ([string](Get-Value $Request 'Mode' 'Guest') -ieq 'Guest') {
        try { $guest = Get-Guest; if ($null -ne $guest) { $guestName = $guest.Name } } catch { }
    }
    if ([string]::IsNullOrEmpty($guestName)) { $guestName = 'Gast' }
    $effectiveMode = [string](Get-Value $Request 'Mode' 'Guest')
    if ($null -ne $record) { $effectiveMode = [string]$record.Mode }
    $script:Result.LoginUserName = $env:COMPUTERNAME + '\' + $guestName
    $login = $script:Result.LoginUserName + '; Passwort leer lassen; Anonym deaktivieren.'
    if ($effectiveMode -ieq 'Password') {
        $account = $UserName
        if ($null -ne $record) { $account = [string]$record.UserName }
        $script:Result.LoginUserName = $env:COMPUTERNAME + '\' + $account
        $login = $script:Result.LoginUserName + '; Passwort: dein gewähltes Passwort'
    }
    $smbUri = 'smb://' + $Network.Address + '/' + [Uri]::EscapeDataString($name)
    $script:Result.ConnectionText = "Protokoll: SMB 2/3`r`nServer / IPv4: $($Network.Address)`r`nPort: 445 (TCP)`r`nComputer: $env:COMPUTERNAME`r`nFreigabe: $name`r`nWindows: \\$env:COMPUTERNAME\$name`r`nDirekter Pfad: \\$($Network.Address)\$name`r`nSMB-Adresse: $smbUri`r`nAnmeldung: $login`r`nHeimnetz: $($Network.Subnet)`r`nOrdner: $([string](Get-Value $Request 'FolderPath' ''))`r`nAndere Geräte: mit demselben Heimnetz verbinden und SMB verwenden."
}
function Test-RealSmbConnection($Request, $Network, [string]$UserName, [string]$Password, [bool]$Required) {
    $script:Result.ConnectionVerified = $false
    if ([bool](Get-Value $Request 'DryRun' $false) -or $null -eq $Network) { return }
    Write-Phase 'SMB-Anmeldung und Ordnerzugriff wirklich prüfen …'
    $login = $env:COMPUTERNAME + '\' + $UserName
    $script:Result.LoginUserName = $login
    try {
        $probe = [EinfachNetzwerk.SmbConnectionProbe]::ProbeJson($Network.Address, [string]$Request.ShareName, $login, $Password) | ConvertFrom-Json
        if ([string](Get-Value $Request 'Mode' 'Password') -ieq 'Password' -and [bool]$probe.GuestSession) {
            $probe.Success = $false
            $probe.Error = 'Windows hat die Anmeldung auf einen Gastzugang umgeleitet. Das gewählte Passwortkonto wurde deshalb nicht bestätigt.'
        }
        if (-not $probe.Success -or -not $probe.LoginSucceeded -or -not $probe.TreeConnected -or -not $probe.DirectoryListed) {
            $detail = 'Die echte SMB-Verbindung scheitert bei ' + $probe.Stage + ': ' + $probe.Error
            if (-not [string]::IsNullOrEmpty([string]$probe.StatusCode)) { $detail += ' [' + [string]$probe.StatusCode + ']' }
            Add-Check 'SMB-Verbindung' error $detail 'SMB_CONNECTION_FAILED' $true 'Den angezeigten Benutzernamen verwenden. Ohne Passwort Anonym deaktivieren und das Passwort leer lassen.'
            if ($Required) { throw $detail }
            return
        }
        $script:Result.ConnectionVerified = $true
        Add-Check 'SMB-Verbindung' ok ('Die SMB-Anmeldung mit ' + $login + ', der Zugriff auf die Freigabe und das Auflisten des Ordners funktionieren. Geprüft wurde eine echte SMB-Verbindung von diesem PC.') 'SMB_SESSION_VERIFIED'
    } catch {
        if ($Required) { throw }
        if (@($script:Checks | Where-Object {$_.Code -eq 'SMB_CONNECTION_FAILED'}).Count -eq 0) { Add-Check 'SMB-Verbindung' error $_.Exception.Message 'SMB_CONNECTION_FAILED' $true 'Den angezeigten Benutzernamen verwenden. Ohne Passwort Anonym deaktivieren und das Passwort leer lassen.' }
    }
}
function Read-ShareInventory {
    $allShares = @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special })
    $script:Result.Shares = @($allShares | ForEach-Object {
            $record = Get-Managed ([string]$_.Name)
            # A reused name does not prove that an externally retargeted share
            # still has this program's saved access configuration.
            if ($null -ne $record -and ([string]$_.Path).TrimEnd([char[]]'\/') -ine ([string]$record.Path).TrimEnd([char[]]'\/')) { $record = $null }
            [pscustomobject]@{ Name = [string]$_.Name; Path = [string]$_.Path; Available = $true; Managed = ($null -ne $record); Mode = [string](Get-Value $record 'Mode' ''); UserName = [string](Get-Value $record 'UserName' ''); AllowWrite = [bool](Get-Value $record 'AllowWrite' $false); AdapterId = [int](Get-Value $record 'AdapterId' -1) }
    })
    if ($null -ne $script:Ledger) {
        $liveNames = @($allShares | ForEach-Object { $_.Name })
        foreach ($record in @($script:Ledger.Shares | Where-Object { $_.Name -notin $liveNames })) {
            $script:Result.Shares += [pscustomobject]@{ Name = [string]$record.Name; Path = [string]$record.Path; Available = $false; Managed = $true; Mode = [string]$record.Mode; UserName = [string]$record.UserName; AllowWrite = [bool]$record.AllowWrite; AdapterId = [int]$record.AdapterId }
        }
    }
}
function Open-ResetServiceRegistryRoot {
    # OpenSubKey is read-only and distinguishes confirmed absence from denied
    # registry access. Never use Test-Path to turn a read error into zero shares.
    return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services', $false)
}
function Read-PersistedResetShares {
    $services = $null; $server = $null; $shares = $null
    try {
        $services = Open-ResetServiceRegistryRoot
        if ($null -eq $services) { throw 'Der Windows-Diensteregistrierungszweig konnte nicht bestätigt werden.' }
        $serviceNames = $services.GetSubKeyNames()
        if ($null -eq $serviceNames) { throw 'Der Windows-Diensteregistrierungszweig konnte nicht bestätigt werden.' }
        $server = $services.OpenSubKey('LanmanServer', $false)
        if ($null -eq $server) {
            if ('LanmanServer' -in $serviceNames) { throw 'Die Serverdienst-Konfiguration konnte nicht vollständig gelesen werden.' }
            return @()
        }
        $serverNames = $server.GetSubKeyNames()
        if ($null -eq $serverNames) { throw 'Die Serverdienst-Konfiguration konnte nicht vollständig gelesen werden.' }
        $shares = $server.OpenSubKey('Shares', $false)
        if ($null -eq $shares) {
            if ('Shares' -in $serverNames) { throw 'Die gespeicherten Freigaben konnten nicht vollständig gelesen werden.' }
            return @()
        }
        $definitions = New-Object 'System.Collections.Generic.List[object]'
        $valueNames = $shares.GetValueNames()
        if ($null -eq $valueNames) { throw 'Die gespeicherten Freigaben konnten nicht vollständig gelesen werden.' }
        foreach ($name in $valueNames) {
            # The unnamed registry default is not a share definition.
            if ([string]::IsNullOrEmpty($name)) { continue }
            if ($name -match '^(?:ADMIN\$|IPC\$|[A-Z]\$)$') { continue }
            if ($name.Length -gt 80 -or $name.Trim() -cne $name -or $name.EndsWith('.') -or $name -match '[\\/\[\]:;|=,+*?<>"\x00-\x1f]') { throw 'Ein gespeicherter Freigabename ist ungültig.' }
            if ($shares.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::MultiString) { throw 'Eine gespeicherte Freigabe hat keinen gültigen Windows-Definitionstyp.' }
            $definition = $shares.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $definition -or -not ($definition -is [string[]]) -or $definition.Count -eq 0) { throw 'Eine gespeicherte Freigabedefinition fehlt oder ist beschädigt.' }
            $paths = New-Object 'System.Collections.Generic.List[string]'
            foreach ($entry in $definition) {
                if ([string]::IsNullOrEmpty($entry) -or $entry -notmatch '^([^=]+)=(.*)$') { throw 'Eine gespeicherte Freigabedefinition ist unvollständig.' }
                if ($Matches[1] -ieq 'Path') { $paths.Add($Matches[2]) }
            }
            if ($paths.Count -ne 1 -or [string]::IsNullOrWhiteSpace($paths[0]) -or $paths[0] -notmatch '^[A-Za-z]:[\\/]' -or $paths[0] -match '[\x00-\x1f]') { throw 'Eine gespeicherte Freigabe hat keinen eindeutigen lokalen Ordnerpfad.' }
            $path = [IO.Path]::GetFullPath($paths[0])
            $definitions.Add([pscustomobject]@{ Name=[string]$name; Path=$path; Available=$true; Managed=$false; Mode=''; UserName=''; AllowWrite=$false; AdapterId=-1 })
        }
        return @($definitions.ToArray())
    } finally {
        if ($null -ne $shares) { $shares.Dispose() }
        if ($null -ne $server) { $server.Dispose() }
        if ($null -ne $services) { $services.Dispose() }
    }
}
function Inspect-ResetShares {
    Write-Phase 'Lokale Datenfreigaben für die Rücksetzung prüfen …'
    try {
        $script:Ledger = Read-Ledger
        Complete-WorkStep 'reset-ledger'
        $service = Get-ServiceNativeSnapshot 'LanmanServer'
        if ($null -eq $service -or -not ((Get-Value $service 'Exists' $null) -is [bool])) { throw 'Der Zustand des lokalen Serverdiensts wurde nicht bestätigt.' }
        $running = [bool]$service.Exists -and [string]$service.State -eq 'Running'
        if (-not $running -and ([bool]$service.Exists -and [string]$service.State -ne 'Stopped')) { throw 'Der lokale Serverdienst wechselt gerade seinen Zustand. Bitte die Freigabenübersicht erneut prüfen.' }
        if (-not [bool]$service.Exists -and [string]$service.State -ne 'Missing') { throw 'Der Zustand des lokalen Serverdiensts wurde nicht bestätigt.' }
        Complete-WorkStep 'reset-service'
        if ($running) {
            Read-ShareInventory
            $detail = 'Die aktuelle lokale Datenfreigabenliste wurde direkt von Windows bestätigt.'
        } else {
            $persisted = @(Read-PersistedResetShares)
            $script:Result.Shares = $persisted
            if ($null -ne $script:Ledger) {
                $names = @($persisted | ForEach-Object { $_.Name })
                foreach ($record in @($script:Ledger.Shares | Where-Object { $_.Name -notin $names })) {
                    $script:Result.Shares += [pscustomobject]@{ Name=[string]$record.Name; Path=[string]$record.Path; Available=$false; Managed=$true; Mode=[string](Get-Value $record 'Mode' ''); UserName=[string](Get-Value $record 'UserName' ''); AllowWrite=[bool](Get-Value $record 'AllowWrite' $false); AdapterId=[int](Get-Value $record 'AdapterId' -1) }
                }
            }
            $detail = 'Der Serverdienst läuft nicht. Die gespeicherten lokalen Datenfreigaben wurden aus der Windows-Konfiguration bestätigt. Dies bestätigt keinen Netzwerkzugriff.'
        }
        Complete-WorkStep 'reset-inventory'
        $script:Result.ConnectionVerified = $false; $script:Result.NativeConnectionVerified = $false; $script:Result.NamedConnectionVerified = $false; $script:Result.RemoteComputerEnumerationVerified = $false
        $script:Result.Success = $true; $script:Result.Message = $detail
        Add-Check 'Freigaben' ok $detail 'RESET_SHARE_INVENTORY_CONFIRMED'
    } catch {
        $script:Result.Success = $false; $script:Result.Shares = $null
        Add-Check 'Freigaben' error 'Die lokale Datenfreigabenliste konnte nicht vollständig bestätigt werden. Es wird keine leere Liste angenommen.' 'RESET_SHARE_INVENTORY_UNCONFIRMED'
        throw
    }
}
function Get-RelevantDeny($Acl, [string[]]$Sids, [bool]$Write) {
    $mask = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    if ($Write) { $mask = $mask -bor [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete }
    return @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference.Value -in $Sids -and ($_.FileSystemRights -band $mask) -ne 0 })
}
function Relevant-Sids([string]$Mode, [string]$UserSid) {
    $sids = @('S-1-1-0','S-1-5-2','S-1-5-113')
    if ($Mode -ieq 'Guest') { $guest = Get-Guest; if ($null -ne $guest) { $sids += $guest.SID.Value }; $sids += @('S-1-5-7','S-1-5-32-546') }
    else { $sids += @($UserSid,'S-1-5-11','S-1-5-32-545') }
    return @($sids | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
}
function Repair-FolderDenials($Folder, [string[]]$Sids, [bool]$Write) {
    if ($Folder.Format -notin @('NTFS','ReFS')) { return }
    $acl = Get-Acl -LiteralPath $Folder.Path
    $rules = @(Get-RelevantDeny $acl $Sids $Write)
    if ($rules.Count -eq 0) { return }
    # Break inheritance only on the explicitly selected data folder, keeping
    # inherited grants. Parent folders and unrelated users remain untouched.
    if (@($rules | Where-Object {$_.IsInherited}).Count -gt 0) { $acl.SetAccessRuleProtection($true, $true) }
    $required = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    if ($Write) { $required = $required -bor [Security.AccessControl.FileSystemRights]::Modify }
    foreach ($rule in @(Get-RelevantDeny $acl $Sids $Write)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
        $remaining = [int]$rule.FileSystemRights -band (-bnot [int]$required)
        if ($remaining -ne 0) {
            $replacement = New-Object Security.AccessControl.FileSystemAccessRule($rule.IdentityReference, [Security.AccessControl.FileSystemRights]$remaining, $rule.InheritanceFlags, $rule.PropagationFlags, 'Deny')
            $acl.AddAccessRule($replacement)
        }
    }
    Set-Acl -LiteralPath $Folder.Path -AclObject $acl
    if (@(Get-RelevantDeny (Get-Acl -LiteralPath $Folder.Path) $Sids $Write).Count -gt 0) { throw 'Windows hat die Reparatur der gewählten Ordnerrechte nicht übernommen.' }
    Add-Check 'Ordnerblockade behoben' ok 'Die benötigten Lese-/Schreibrechte wurden im ausgewählten Datenordner entsperrt. Andere Verbote und der übergeordnete Ordner bleiben erhalten.' 'FOLDER_DENY_FIXED' $true
}
function Get-LocalShareProblems($Request, $Folder, $Network, [string[]]$Sids) {
    $problems=New-Object 'System.Collections.Generic.List[string]'
    $profile=Get-NetConnectionProfile -InterfaceIndex $Network.Id -ErrorAction Stop
    if ([string]$profile.NetworkCategory -ne 'Private') { $problems.Add('Profile') }
    if (-not (Get-SmbServerConfiguration).EnableSMB2Protocol) { $problems.Add('SMB2') }
    foreach ($name in @('LanmanServer','FDResPub','fdPHost')) { if ((Get-Service -Name $name).Status -ne 'Running') { $problems.Add('Service:'+ $name) } }
    $share=Get-ShareSnapshot ([string]$Request.ShareName)
    if ($null -eq $share -or $share.Path.TrimEnd('\') -ine $Folder.Path.TrimEnd('\')) { $problems.Add('Share') }
    elseif ($null -ne $share) {
        $sd=New-Object Security.AccessControl.RawSecurityDescriptor($share.SecurityDescriptor)
        foreach($sid in $Sids) { if (@($sd.DiscretionaryAcl | Where-Object {$_.AceQualifier -eq 'AccessAllowed' -and $_.SecurityIdentifier.Value -eq $sid}).Count -eq 0) { $problems.Add('ShareRights'); break } }
    }
    $rules=@(Get-FirewallSnapshots (Rule-Prefix ([string]$Request.ShareName)) | Where-Object {$_.Name -like '*-SMB'})
    if ($rules.Count -ne 1 -or -not (Test-ManagedSmbFirewallRule $rules[0] $Network)) { $problems.Add('Firewall') }
    $discoveryExe = Get-DiscoveryExecutable
    if (-not [string]::IsNullOrWhiteSpace($discoveryExe)) {
        $discoveryRules=@(Get-FirewallSnapshots (Rule-Prefix ([string]$Request.ShareName)) | Where-Object {$_.Name -like '*-Discovery'})
        if ($discoveryRules.Count -ne 1 -or -not (Test-ManagedDiscoveryFirewallRule $discoveryRules[0] $Network $discoveryExe)) { $problems.Add('Firewall') }
        if ($null -ne $share -and [string]$share.Description -cne (Get-RequestDiscoveryDescription $Request)) { $problems.Add('DiscoveryMetadata') }
    }
    if (Advanced-Repair $Request) { $binding=@(Get-NetAdapterBinding -Name $Network.Name -ComponentID ms_server -ErrorAction Stop); if ($binding.Count -gt 0 -and -not $binding[0].Enabled) {$problems.Add('Binding')} }
    if ($Folder.Format -in @('NTFS','ReFS')) { if (@(Get-RelevantDeny (Get-Acl -LiteralPath $Folder.Path) (Relevant-Sids ([string]$Request.Mode) $Sids[0]) ([bool]$Request.AllowWrite)).Count -gt 0) {$problems.Add('FolderDeny')} }
    return @($problems.ToArray() | Select-Object -Unique)
}
function Confirm-AndRepairLocalShare($Request, $Folder, $Network, [string[]]$Sids, [string]$OriginalSid) {
    for ($attempt=1; $attempt -le 3; $attempt++) {
        Write-Phase ('Wirksamkeit prüfen · Durchlauf ' + $attempt + ' von 3 …')
        $problems=@(Get-LocalShareProblems $Request $Folder $Network $Sids)
        $script:Result.RetryCount=$attempt
        if ($problems.Count -eq 0) { Add-Check 'Wirksamkeit' ok 'Freigabe, Rechte, Dienste, privates Profil und eigene Firewallregel sind lokal wirksam.' 'LOCAL_VERIFIED'; return }
        if (-not (Advanced-Repair $Request) -or $attempt -eq 3) { throw ('Windows hat die Einrichtung noch nicht vollständig übernommen: ' + ($problems -join ', ') + '. Die Diagnose zeigt den nächsten Schritt.') }
        Add-Check 'Automatische Nachbesserung' info ('Gefundene Blockaden werden gezielt erneut korrigiert: ' + ($problems -join ', ')) 'RETRY' $true
        foreach ($problem in $problems) {
            switch -Wildcard ($problem) {
                'Profile' { Set-NetConnectionProfile -InterfaceIndex $Network.Id -NetworkCategory Private }
                'SMB2' { Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force | Out-Null }
                'Service:*' { $serviceName=$problem.Substring(8); Set-Service -Name $serviceName -StartupType Automatic; Start-Service -Name $serviceName }
                'Firewall' { Configure-Firewall $Network (Rule-Prefix ([string]$Request.ShareName)) }
                'DiscoveryMetadata' { Set-SmbShare -Name $Request.ShareName -Description (Get-RequestDiscoveryDescription $Request) -Force | Out-Null }
                'Binding' { Enable-NetAdapterBinding -Name $Network.Name -ComponentID ms_server -ErrorAction Stop | Out-Null }
                'FolderDeny' { Repair-FolderDenials $Folder (Relevant-Sids ([string]$Request.Mode) $Sids[0]) ([bool]$Request.AllowWrite) }
                {$_ -in @('Share','ShareRights')} {
                    $security=(Get-ShareSddl $Sids ([bool]$Request.AllowWrite)) + '(A;;FA;;;' + $OriginalSid + ')'
                    $existing=Get-ShareSnapshot ([string]$Request.ShareName)
                    if ($null -eq $existing) { New-SmbShare -Name $Request.ShareName -Path $Folder.Path -SecurityDescriptor $security -Description (Get-RequestDiscoveryDescription $Request) -EncryptData $false | Out-Null }
                    elseif ($existing.Path.TrimEnd('\') -ieq $Folder.Path.TrimEnd('\')) { Set-SmbShare -Name $Request.ShareName -SecurityDescriptor $security -Description (Get-RequestDiscoveryDescription $Request) -Force | Out-Null }
                    else { throw 'Der Freigabename zeigt inzwischen auf einen anderen Ordner. Bitte einen neuen Freigabenamen wählen.' }
                }
            }
        }
    }
}
function Inspect-DiscoveryReadiness([string]$RequiredShare = '') {
    $executable = Get-DiscoveryExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) { return }
    foreach ($share in @($script:Result.Shares | Where-Object {$_.Managed -and $_.Available})) {
        try {
            $networks = @($script:Result.Networks | Where-Object {$_.Id -eq $share.AdapterId})
            if ($networks.Count -ne 1 -and @($script:Result.Networks).Count -eq 1) { $networks=@($script:Result.Networks) }
            $ready = $false
            if ($networks.Count -eq 1) {
                $rules=@(Get-FirewallSnapshots (Rule-Prefix $share.Name) | Where-Object {$_.Name -like '*-Discovery'})
                $live = Get-ShareSnapshot $share.Name
                $account=[string]$share.UserName
                if ($share.Mode -ieq 'Guest') { $account=[string](Get-Guest).Name }
                $description=Get-DiscoveryShareDescription $share.Mode $account
                $ready=$networks[0].Category -eq 'Private' -and $rules.Count -eq 1 -and (Test-ManagedDiscoveryFirewallRule $rules[0] $networks[0] $executable) -and $null -ne $live -and $live.Description -ceq $description
            }
            if ($ready) { Add-Check ('Heimnetz-Erkennung: ' + $share.Name) ok 'Freigabedaten und die begrenzte Erkennungsregel für diese Programmdatei sind eingerichtet.' 'DISCOVERY_SETUP_READY' }
            else {
                $state = if ($share.Name -ieq $RequiredShare) { 'error' } else { 'warning' }
                Add-Check ('Heimnetz-Erkennung: ' + $share.Name) $state 'Die automatische Datenübernahme benötigt aktuelle Freigabedaten und eine Erkennungsregel für diese Programmdatei. Die vorhandene SMB-Freigabe bleibt erhalten.' 'DISCOVERY_SETUP_REQUIRED' $true 'Möchtest du das beheben? „Automatisch reparieren“ aktualisiert die eigene Einrichtung dieser Freigabe.' $share.Name
            }
        } catch { Add-Check ('Heimnetz-Erkennung: ' + $share.Name) warning ('Die Erkennungseinrichtung konnte nicht vollständig gelesen werden: ' + $_.Exception.Message) 'DISCOVERY_QUERY_FAILED' $false 'Fehlerbericht exportieren oder die eigene Freigabe erneut prüfen.' }
    }
}
function Test-SelectedShareInspectionFailure([string]$ShareName) {
    return @($script:Checks | Where-Object { $_.State -eq 'error' -and -not ($_.Code -eq 'DISCOVERY_SETUP_REQUIRED' -and $_.TargetShare -ine $ShareName) }).Count -gt 0
}
function Inspect-State($Request, $Network, $Folder) {
    try {
        Read-ShareInventory
        $allShares = @($script:Result.Shares)
        Add-Check 'Freigaben' ok ($allShares.Count.ToString() + ' normale SMB-Freigabe(n) gefunden.')
    } catch { Add-Check 'Freigaben' error ('Freigaben können nicht gelesen werden: ' + $_.Exception.Message) }
    Complete-WorkStep 'inspect-shares'
    if ($null -eq $Network) { Add-Check 'Heimnetz' warning 'Kein ausgewähltes aktives LAN/WLAN mit privater IPv4 und Heimnetz-Gateway. WLAN/LAN verbinden und erneut prüfen.' }
    else {
        $state = 'ok'; if ($Network.Category -ne 'Private') { $state = 'warning' }
        Add-Check 'Heimnetz' $state ($Network.Name + ' · ' + $Network.Address + ' · ' + $Network.Subnet + ' · ' + $Network.Category)
    }
    Complete-WorkStep 'inspect-network'
    foreach ($name in @('LanmanServer','LanmanWorkstation','FDResPub','fdPHost')) {
        try {
            $svc = Get-ServiceSnapshot $name; $state = 'ok'
            if ($svc.StartMode -notin @('Auto','Manual','Disabled')) {
                Add-Check $name error ($svc.State + ', Start: ' + $svc.StartMode + '. Die Windows-Dienstkonfiguration ist beschädigt und wird bei der Einrichtung automatisch aus den Originaldateien von Windows repariert.') 'SERVICE_CONFIG_MISSING' $true 'Freigabe mit aktivierter automatischer Blockaden-Reparatur einrichten.'
            } else {
                if ($svc.State -ne 'Running' -or ($name -ne 'LanmanServer' -and $svc.StartMode -ne 'Auto')) { $state = 'warning' }
                Add-Check $name $state ($svc.State + ', Start: ' + $svc.StartMode)
            }
        }
        catch { Add-Check $name error $_.Exception.Message }
        Complete-WorkStep ('inspect-' + $name)
    }
    try {
        $config = Get-SmbServerConfiguration
        $state = 'ok'; if (-not $config.EnableSMB2Protocol) { $state = 'error' }
        Add-Check 'SMB 2/3' $state ('Aktiv: ' + $config.EnableSMB2Protocol)
        if ($config.EnableSMB1Protocol) { Add-Check 'SMB 1' warning 'SMB 1 ist bereits aktiviert. Das Programm benötigt SMB 2/3 und aktiviert SMB 1 niemals.' }
        $state = 'ok'; if ([string](Get-Value $Request 'Mode' '') -ieq 'Guest' -and $config.RequireSecuritySignature) { $state = 'warning' }
        Add-Check 'SMB-Signatur' $state ('Pflicht auf diesem Server: ' + $config.RequireSecuritySignature + '. Gastzugriff unterstützt keine Signatur; diese Einstellung betrifft alle Freigaben des PCs.')
        if ($config.EncryptData -and [string](Get-Value $Request 'Mode' '') -ieq 'Guest') { Add-Check 'SMB-Verschlüsselung' error 'Serverweite Verschlüsselung verhindert Gastzugriff. Diese Sicherheitsrichtlinie wird nicht automatisch abgeschaltet; bitte Passwortmodus verwenden.' }
    } catch { Add-Check 'SMB-Konfiguration' error $_.Exception.Message }
    Complete-WorkStep 'inspect-smb'
    try {
        $listen = @(Get-NetTCPConnection -State Listen -LocalPort 445 -ErrorAction SilentlyContinue)
        $state = 'ok'; if ($listen.Count -eq 0) { $state = 'warning' }
        Add-Check 'Port 445' $state ('SMB-Listener: ' + ($listen.Count -gt 0) + '. Dies ist eine lokale Prüfung; Router, Gast-WLAN oder andere Geräte können Verbindungen zusätzlich blockieren.')
    } catch { Add-Check 'Port 445' warning 'Der lokale SMB-Listener konnte nicht gelesen werden.' }
    Complete-WorkStep 'inspect-port'
    if ($null -ne $Network) {
        try {
            $fw = Get-NetFirewallProfile -Name Private -PolicyStore ActiveStore
            if (-not $fw.Enabled) { Add-Check 'Firewall' warning 'Die private Windows-Firewall ist bereits abgeschaltet. Das Programm schaltet sie nicht ab.' }
            elseif ($fw.AllowInboundRules -eq 'False') { Add-Check 'Firewall' error 'Eine Windows-Richtlinie blockiert eingehende Freigaben trotz Erlaubnisregel. Diese Richtlinie wird nicht übergangen.' }
            else { Add-Check 'Firewall' info 'Windows-Firewall bleibt aktiv; das Programm erstellt begrenzte Regeln für den ausgewählten Adapter und dessen Heimnetz.' }
            Inspect-OtherSmbRules $Network
            $name = [string](Get-Value $Request 'ShareName' '')
            if (-not [string]::IsNullOrEmpty($name)) {
                $rules = @(Get-FirewallSnapshots (Rule-Prefix $name) | Where-Object { $_.Name -like '*-SMB' })
                $state = 'warning'; if ($rules.Count -eq 1 -and (Test-ManagedSmbFirewallRule $rules[0] $Network)) { $state = 'ok' }
                Add-Check 'SMB-Firewallregel' $state 'Eigene SMB-Regel für Private, System, ausgewählte IPv4, Adapter und Heimnetz geprüft.'
            }
        } catch { Add-Check 'Firewall' warning ('Firewall-Konfiguration konnte nicht vollständig gelesen werden: ' + $_.Exception.Message) }
    }
    $requiredDiscoveryShare = if ([string](Get-Value $Request 'Action' 'Inspect') -in @('Apply','Repair')) { [string](Get-Value $Request 'ShareName' '') } else { '' }
    Inspect-DiscoveryReadiness $requiredDiscoveryShare
    Complete-WorkStep 'inspect-firewall'
    if ([string](Get-Value $Request 'Mode' '') -ieq 'Guest') {
        try {
            $guest = Get-Guest
            if ($null -eq $guest) { Add-Check 'Gastkonto' error 'Das eingebaute Windows-Gastkonto wurde nicht gefunden.' }
            else {
                $state = 'ok'; if (-not $guest.Enabled) { $state = 'warning' }
                Add-Check 'Gastkonto' $state ($guest.Name + ' · Aktiv: ' + $guest.Enabled)
                if (Is-Administrator) {
                    Load-Native
                    $rights = @([EinfachNetzwerk.Native]::Rights($guest.SID.Value))
                    $state = 'ok'; if ('SeDenyNetworkLogonRight' -in $rights) { $state = 'warning' }
                    Add-Check 'Gast-Netzwerkanmeldung' $state ('Direkte Netzwerksperre: ' + ('SeDenyNetworkLogonRight' -in $rights))
                    $groups = @([EinfachNetzwerk.Native]::Rights('S-1-5-32-546'))
                    if ('SeDenyNetworkLogonRight' -in $groups) { Add-Check 'Gast-Gruppenrichtlinie' error 'Die Gruppe Gäste ist für Netzwerkanmeldung gesperrt. Das Programm entfernt keine pauschale Gruppensperre; Passwortmodus verwenden oder die zuständige Richtlinie prüfen.' }
                } else { Add-Check 'Gast-Netzwerkanmeldung' info 'Die Sicherheitsrichtlinie wird beim Ausführen als Administrator zusätzlich geprüft.' }
            }
            $nullShares = @(Get-NullShares)
            if (-not [string]::IsNullOrEmpty([string](Get-Value $Request 'ShareName' ''))) { $state = 'warning'; if ([string]$Request.ShareName -in $nullShares) { $state = 'ok' }; Add-Check 'Anonymer Freigabename' $state 'Nur ausdrücklich ausgewählte Namen werden zu Windows NullSessionShares hinzugefügt.' }
        } catch { Add-Check 'Gastzugriff' warning $_.Exception.Message }
    }
    Complete-WorkStep 'inspect-guest'
    if ($null -ne $Folder) {
        Add-Check 'Ordner' ok ($Folder.Path + ' · ' + $Folder.Format)
        $name = [string](Get-Value $Request 'ShareName' '')
        if (-not [string]::IsNullOrEmpty($name)) {
            $share = Get-ShareSnapshot $name
            if ($null -eq $share) { Add-Check 'Gewählte Freigabe' warning 'Diese Freigabe existiert noch nicht.' }
            elseif ($share.Path.TrimEnd('\') -ine $Folder.Path.TrimEnd('\')) { Add-Check 'Gewählte Freigabe' error 'Der Freigabename wird bereits für einen anderen Ordner verwendet.' }
            else {
                Add-Check 'Gewählte Freigabe' ok ($share.Name + ' → ' + $share.Path)
                try {
                    $aces = @(Get-SmbShareAccess -Name $name)
                    Add-Check 'Freigaberechte' info (($aces | ForEach-Object { $_.AccountName + ': ' + $_.AccessControlType + '/' + $_.AccessRight }) -join '; ')
                    if ([string](Get-Value $Request 'Mode' '') -ieq 'Password') {
                        $sd = New-Object Security.AccessControl.RawSecurityDescriptor($share.SecurityDescriptor)
                        $open = @($sd.DiscretionaryAcl | Where-Object { $_.AceQualifier -eq 'AccessAllowed' -and $_.SecurityIdentifier.Value -in @('S-1-5-7','S-1-1-0','S-1-5-32-546') })
                        if ($open.Count -gt 0) { Add-Check 'Passwortschutz' error 'Die vorhandene Freigabe erlaubt noch allgemeinen/Gast-Zugriff. „Freigeben“ setzt ausschließlich Administratoren und das gewählte Freigabekonto.' }
                    }
                } catch { Add-Check 'Freigaberechte' warning 'Die Freigaberechte konnten nicht vollständig geprüft werden.' }
            }
        }
        if ($Folder.Format -in @('NTFS','ReFS')) {
            try {
                $acl = Get-Acl -LiteralPath $Folder.Path
                Add-Check 'Dateisystemrechte' info ('Ordnerrechte lesbar, ' + $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]).Count + ' Einträge. Geschützte Unterordner und explizite Sperren werden nicht überschrieben.')
                $record = Get-Managed ([string](Get-Value $Request 'ShareName' ''))
                $userSid = [string](Get-Value $record 'UserSid' '')
                $denies = @(Get-RelevantDeny $acl (Relevant-Sids ([string](Get-Value $Request 'Mode' 'Guest')) $userSid) ([bool](Get-Value $Request 'AllowWrite' $false)))
                if ($denies.Count -gt 0) { Add-Check 'Ordner-Zugriffssperre' error 'Dieser Ordner enthält relevante explizite oder geerbte Zugriffsverbote. Sie bleiben erhalten; bitte einen anderen Datenordner wählen oder die bestehenden Rechte gezielt prüfen.' }
            }
            catch { Add-Check 'Dateisystemrechte' error ('Ordnerrechte können nicht gelesen werden: ' + $_.Exception.Message) }
        } else { Add-Check 'Dateisystemrechte' warning ($Folder.Format + ' hat keine NTFS-Benutzerrechte; Schutz erfolgt durch die SMB-Freigabe.') }
    }
    Add-Check 'Verbindung anderer Geräte' info 'Die tatsächliche Verbindung vom Handy/anderen PC muss dort geprüft werden. WLAN-Gastnetz, Router-Isolation, fremde Firewalls und Richtlinien kann dieses Programm nicht garantiert beheben.'
    Complete-WorkStep 'inspect-folder'
}

function Test-JournalStorage {
    Initialize-LedgerDirectory
    $probe = Join-Path $script:LedgerRoot ('write-check-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-JsonAtomic $probe ([pscustomobject]@{ App=$script:AppMark; Status='Prepared' })
        Write-JsonAtomic $probe ([pscustomobject]@{ App=$script:AppMark; Status='Verified' })
        $verified = [IO.File]::ReadAllText($probe, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($verified.Status -ne 'Verified') { throw 'Das Journal wurde nicht vollständig aktualisiert.' }
    } catch { throw ('Das Änderungsjournal kann nicht zuverlässig geschrieben werden. Es wurden noch keine Freigabeeinstellungen geändert. Ursache: ' + $_.Exception.Message) }
    finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }
}
function Get-ServiceConfigurationProblems([string]$Name) {
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $key) { $problems.Add('Dienstschlüssel fehlt') }
    else {
        foreach ($value in @('ImagePath','ObjectName','Start','Type','ErrorControl')) {
            if ($value -notin @($key.GetValueNames())) { $problems.Add($value + ' fehlt') }
        }
    }
    $parameters = Get-Item -LiteralPath ($path + '\Parameters') -ErrorAction SilentlyContinue
    if ($null -eq $parameters -or 'ServiceDll' -notin @($parameters.GetValueNames())) { $problems.Add('ServiceDll fehlt') }
    return @($problems.ToArray())
}
function Get-ServiceRegistryTree([string]$Path) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return [pscustomobject]@{Path=$Path; Exists=$false; Values=@(); Children=@()} }
    $values = @()
    foreach ($name in @($key.GetValueNames())) { $values += @(Get-RegistrySnapshot $Path $name) }
    $children = @()
    foreach ($name in @($key.GetSubKeyNames())) { $children += @(Get-ServiceRegistryTree ($Path + '\' + $name)) }
    return [pscustomobject]@{Path=$Path; Exists=$true; Values=$values; Children=$children}
}
function Repair-RequiredServiceConfigurations($Request) {
    foreach ($name in @('fdPHost','FDResPub')) {
        $problems = @(Get-ServiceConfigurationProblems $name)
        if ($problems.Count -eq 0) { continue }
        if (-not (Advanced-Repair $Request)) { throw ($name + ': Die Windows-Dienstkonfiguration ist unvollständig. Bitte die automatische Blockaden-Reparatur aktivieren. Ursache: ' + ($problems -join ', ')) }
        if ([bool](Get-Value $Request 'DryRun' $false)) {
            Add-Check $name warning ('Die Original-Dienstkonfiguration wird bei der Einrichtung automatisch aus Windows wiederhergestellt: ' + ($problems -join ', ')) 'SERVICE_CONFIG_MISSING' $true 'Freigabe mit aktivierter automatischer Blockaden-Reparatur einrichten.'
            continue
        }
        Assert-PersonalPolicyChanges
        Write-Phase ('Originalkonfiguration von ' + $name + ' aus Windows prüfen …')
        $plan = [EinfachNetzwerk.ServiceConfigurationRecovery]::GetPlanJson($name) | ConvertFrom-Json
        foreach ($file in @($plan.DllPath, (Join-Path ([Environment]::GetFolderPath('System')) 'svchost.exe'))) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw ($name + ': Die originale Microsoft-Dienstdatei konnte nicht verifiziert werden. Bitte Windows-Systemdateien reparieren. Es wird keine fremde Dienstdatei geladen.') }
        }
        $backup = Join-Path $script:LedgerRoot ('service-recovery-' + $name + '-' + [Guid]::NewGuid().ToString('N') + '.json')
        $record = [pscustomobject]@{App=$script:AppMark; Version=1; Action='ServiceRecovery'; Name=$name; Status='Prepared'; Original=(Get-ServiceRegistryTree ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $name)); Source=$plan; Created=[DateTime]::UtcNow.ToString('o')}
        Write-JsonAtomic $backup $record
        $script:Result.BackupPath=$backup
        try {
            Write-Phase ('Beschädigte Windows-Dienstkonfiguration von ' + $name + ' wiederherstellen …')
            $null = [EinfachNetzwerk.ServiceConfigurationRecovery]::Repair($name)
            $remaining = @(Get-ServiceConfigurationProblems $name)
            $service = Get-ServiceSnapshot $name
            if ($remaining.Count -gt 0 -or $service.StartMode -notin @('Auto','Manual','Disabled')) { throw ($name + ': Die wiederhergestellte Dienstkonfiguration ist noch unvollständig.') }
            $record.Status='Verified'; Write-JsonAtomic $backup $record
            Add-Check $name ok 'Die beschädigte Dienstkonfiguration wurde gesichert und aus den geprüften Originaldateien dieses Windows wiederhergestellt.' 'SERVICE_CONFIG_REPAIRED' $true
        } catch {
            $record.Status='RepairIncomplete'
            $record | Add-Member -NotePropertyName Error -NotePropertyValue $_.Exception.Message -Force
            try { Write-JsonAtomic $backup $record } catch { Add-Check 'Journal' error ('Der Dienst-Reparaturstatus konnte nicht gespeichert werden: ' + $_.Exception.Message) }
            throw
        }
    }
}
function Apply-Share($Request, $Folder, $Network, [bool]$Repair) {
    if (-not [bool](Get-Value $Request 'DryRun' $false)) {
        # Lock the actual saved/selected path after resolution, including every
        # parent. An unelevated process cannot redirect ACL changes via a junction.
        $script:FolderGuard=[EinfachNetzwerk.BackendClient]::LockDataFolder($Folder.Path)
    }
    $name = [string]$Request.ShareName
    $mode = [string]$Request.Mode
    $managed = Get-Managed $name
    # The SMB provider cannot read a share snapshot while LanmanServer is stopped.
    # Repair its independently journaled service state before accessing that provider.
    if (-not [bool](Get-Value $Request 'DryRun' $false) -and (Get-Command Get-ServiceNativeSnapshot -ErrorAction SilentlyContinue)) {
        $serverService = Get-ServiceNativeSnapshot 'LanmanServer'
        if (-not $serverService.Exists -or $serverService.State -ne 'Running') {
            Invoke-RepairLocalServices $Request
            if (-not $script:Result.ServiceHealthVerified) { throw 'Der lokale Serverdienst ist noch nicht bereit. Bitte Windows-Dienste reparieren öffnen und den Fehlerbericht lesen.' }
            $script:Result.Success = $false
        }
    }
    $existing = Get-ShareSnapshot $name
    if ($null -ne $existing -and $existing.Path.TrimEnd('\') -ine $Folder.Path.TrimEnd('\')) { throw 'Dieser Freigabename gehört bereits zu einem anderen Ordner. Bitte einen anderen Namen wählen.' }
    if ($null -ne $managed -and $managed.Path.TrimEnd('\') -ine $Folder.Path.TrimEnd('\')) { throw 'Die gespeicherte Freigabe gehört zu einem anderen Ordner. Bitte die ursprüngliche Freigabe zuerst zurücknehmen.' }
    if ($null -ne $managed -and -not [string]::IsNullOrEmpty([string]$managed.AppliedFolderSddl)) {
        $currentAcl = (Get-Acl -LiteralPath $Folder.Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        if ($currentAcl -ne $managed.AppliedFolderSddl -and -not (Advanced-Repair $Request)) { throw 'Die Ordnerrechte wurden außerhalb des Programms geändert. Diese Änderungen werden erhalten; bitte die Rechte gezielt prüfen oder einen unabhängigen Datenordner wählen. Freigabe, Dienste und Firewall können danach wieder geprüft werden.' }
        if ($currentAcl -ne $managed.AppliedFolderSddl) { Add-Check 'Geänderte Ordnerrechte' info 'Die automatische Reparatur ergänzt benötigte Freigaberechte in den aktuellen Ordnerrechten. Andere Benutzerrechte werden erhalten.' 'ACL_REPAIR' $true }
    }
    Assert-IndependentFolder $name $Folder.Path
    if ($Repair -and $null -eq $managed) { throw 'Reparieren gilt nur für Freigaben, die dieses Programm bereits verwaltet. Bitte zuerst „Freigeben“ wählen.' }
    if ($Repair -and ($managed.Mode -ine $mode -or [bool]$managed.AllowWrite -ne [bool](Get-Value $Request 'AllowWrite' $false))) { throw 'Zum Ändern von Passwortmodus oder Schreibrechten bitte „Freigeben“ verwenden. Reparieren erhält die gespeicherten Einstellungen.' }
    $originalSid = [string](Get-Value $Request 'OriginalUserSid' '')
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($originalSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $originalSid -ne $currentSid) { throw 'Die Freigabe muss im ursprünglichen Windows-Benutzerkonto ausgeführt werden. Bitte dieselbe Anmeldung bei der Administratorabfrage verwenden.' }
    $guest = $null; $user = $null
    $server = Get-SmbServerConfiguration
    $firewall = Get-NetFirewallProfile -Name Private -PolicyStore ActiveStore
    if ($firewall.Enabled -and $firewall.AllowInboundRules -eq 'False') { throw 'Eine Windows-Firewallrichtlinie blockiert eingehende Verbindungen trotz Erlaubnisregeln. Sie wird nicht übergangen; bitte die zuständige Richtlinie prüfen.' }
    if ($mode -ieq 'Guest') {
        if (-not [bool](Get-Value $Request 'AllowGuestSettings' $false)) { throw 'Gastzugriff benötigt die ausdrückliche Zustimmung zu Gastkonto und gegebenenfalls der serverweiten SMB-Signaturänderung.' }
        if ($server.EncryptData) { throw 'Die serverweite SMB-Verschlüsselungsrichtlinie verhindert Gastzugriff. Sie bleibt erhalten. Bitte Passwortmodus wählen.' }
        $guest = Get-Guest
        if ($null -eq $guest) { throw 'Das eingebaute Windows-Gastkonto wurde nicht gefunden.' }
        Load-Native
        if ('SeDenyNetworkLogonRight' -in @([EinfachNetzwerk.Native]::Rights('S-1-5-32-546'))) {
            if (-not (Advanced-Repair $Request)) { throw 'Die Gruppe Gäste ist durch eine Sicherheitsrichtlinie im Netzwerk gesperrt. Diese Gruppensperre wird nicht pauschal entfernt. Bitte Passwortmodus verwenden.' }
            Assert-PersonalPolicyChanges
            Add-Check 'Gast-Gruppenblockade' info 'Die lokale Netzwerksperre der Gruppe Gäste wird gesichert und für Gastfreigaben dieses PCs aufgehoben.' 'GUEST_GROUP_REPAIR' $true
        }
    } elseif ($mode -ieq 'Password') {
        $userName = [string](Get-Value $Request 'UserName' 'NetzwerkUser')
        $user = Assert-OwnedUser $userName
        $force = Get-RegistrySnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'ForceGuest'
        if ($force.Exists -and [int]$force.Value -ne 0) {
            if (-not (Advanced-Repair $Request)) { throw 'Windows erzwingt derzeit „Nur Gast“ für lokale Netzwerkbenutzer. Passwortschutz ist damit nicht möglich. Die globale ForceGuest-Richtlinie wird nicht automatisch geändert; bitte die Windows-Sicherheitsrichtlinie auf „Klassisch“ prüfen.' }
            Assert-PersonalPolicyChanges
            Add-Check 'Windows-Anmeldemodus' info 'Der lokale Anmeldemodus wird gesichert und auf Benutzeranmeldung mit Passwort umgestellt.' 'FORCE_GUEST_REPAIR' $true
        }
        if (-not [bool](Get-Value $Request 'DryRun' $false)) {
            $script:Secret = Unprotect-Password $Request
            if ($null -eq $user -and ([string]::IsNullOrEmpty($script:Secret) -or $script:Secret.Length -lt 8)) { throw 'Für das neue Freigabekonto bitte ein Passwort mit mindestens 8 Zeichen eingeben.' }
        }
    } else { throw 'Bitte „Mit Passwort“ oder „Ohne Passwort“ auswählen.' }
    if ($Folder.Format -in @('NTFS','ReFS')) {
        $userSid = ''; if ($null -ne $user) { $userSid = $user.SID.Value }
        $denies = @(Get-RelevantDeny (Get-Acl -LiteralPath $Folder.Path) (Relevant-Sids $mode $userSid) ([bool](Get-Value $Request 'AllowWrite' $false)))
        if ($denies.Count -gt 0 -and -not (Advanced-Repair $Request)) { throw 'Der Ordner enthält eine Zugriffsverbotsregel für das Freigabekonto oder seine Gruppen. Diese Regel wird nicht entfernt. Bitte einen anderen Datenordner wählen oder die bestehenden Rechte gezielt prüfen.' }
        if ($denies.Count -gt 0) { Add-Check 'Ordnerblockade' info 'Benötigte Freigaberechte werden nur im gewählten Datenordner entsperrt. Die ursprünglichen Rechte werden vorher gesichert.' 'FOLDER_REPAIR' $true }
    }
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        Add-Check 'Geplante Änderung' info ('Nur Adapter ' + $Network.Name + ' auf Privat, Windows-Freigabedienst und Erkennung starten, SMB 2/3, Firewall auf ' + $Network.Subnet + ' begrenzen.')
        Add-Check 'Geplante Freigabe' info ($Folder.Path + ' → ' + $name + '; Modus ' + $mode + '; Schreiben ' + [bool](Get-Value $Request 'AllowWrite' $false) + '. Keine Änderungen ausgeführt.')
        if ($mode -ieq 'Guest') { Add-Check 'Geplante Gast-Einstellung' warning 'Eingebautes Gastkonto aktivieren, nur dessen Netzwerksperre entfernen, lokale Anmeldung sperren, diesen NullSessionShare ergänzen. SMB-Signaturpflicht auf dem Server bei Bedarf deaktivieren; das betrifft alle Serverfreigaben.' }
        else { Add-Check 'Geplantes Freigabekonto' info ('Dediziertes normales Konto ' + [string](Get-Value $Request 'UserName' 'NetzwerkUser') + '; kein fremdes Passwort wird geändert. DPAPI-Passwort wird im Probelauf nicht entschlüsselt.') }
        if (Advanced-Repair $Request) { Add-Check 'Geplante automatische Reparatur' info 'SMB-Adapterbindung, lokale Anmeldeblockaden und gewählte Ordnerrechte werden bei Bedarf gesichert und repariert. Danach folgen bis zu drei lokale Wirksamkeitsprüfungen.' 'REPAIR_PLAN' $true }
        $script:Result.Success = $true
        $script:Result.Message = 'Probelauf abgeschlossen. Windows, Konten, Rechte und Freigaben wurden nicht verändert.'
        Complete-WorkStep 'apply-validation'
        Complete-WorkStep 'dryrun-evaluation'
        return
    }
    if (-not (Is-Administrator)) { throw 'Diese Aktion benötigt Administratorrechte. Bitte den entsprechenden Button im Programm verwenden und die Windows-Abfrage bestätigen.' }
    Assert-LedgerProtection
    Complete-WorkStep 'apply-validation'
    Test-JournalStorage
    Repair-RequiredServiceConfigurations $Request
    Complete-WorkStep 'apply-service-config'
    Write-Phase 'Vorherige Freigabe- und Windows-Einstellungen sichern …'
    $script:Transaction = New-Transaction $Request $Folder $Network $guest $user
    $backup = Join-Path $script:LedgerRoot ('journal-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
    $script:Result.BackupPath = $backup
    Write-JsonAtomic $backup $script:Transaction
    if ($null -eq $script:Ledger -or @($script:Ledger.Shares).Count -eq 0) {
        $priorUsers = @(); if ($null -ne $script:Ledger) { $priorUsers = @($script:Ledger.CreatedUsers) }
        $script:Ledger = [pscustomobject]@{ App = $script:AppMark; Version = 1; Shares = @(); CreatedUsers = $priorUsers; Global = [pscustomobject]@{ Networks = @($script:Transaction.System.Network); Services = $script:Transaction.System.Services; Server = $script:Transaction.System.Server; Registry = $script:Transaction.System.Registry; Guest = $script:Transaction.System.Guest; ExpectedGuest = $null; ExpectedServer = $null; Groups=@($script:Transaction.System.Groups); ExpectedGroups=@(); Bindings=@(); ExpectedForceGuest=$null } }
    }
    if (@($script:Ledger.Global.Networks | Where-Object { $_.Id -eq $Network.Id }).Count -eq 0) { $script:Ledger.Global.Networks = @($script:Ledger.Global.Networks) + @($script:Transaction.System.Network) }
    # Older ledgers predate configuring the outbound SMB client. Save any newly
    # managed service's actual original state once, preserving earlier snapshots.
    foreach ($service in @($script:Transaction.System.Services)) {
        if (@($script:Ledger.Global.Services | Where-Object { $_.Name -eq $service.Name }).Count -eq 0) { $script:Ledger.Global.Services = @($script:Ledger.Global.Services) + @($service) }
    }
    if ($null -eq $script:Ledger.Global.Guest -and $null -ne $script:Transaction.System.Guest) { $script:Ledger.Global.Guest = $script:Transaction.System.Guest }
    foreach($field in @('Groups','ExpectedGroups','Bindings')) { if ($null -eq $script:Ledger.Global.PSObject.Properties[$field]) {$script:Ledger.Global | Add-Member -NotePropertyName $field -NotePropertyValue @()} }
    if ($null -eq $script:Ledger.Global.PSObject.Properties['ExpectedForceGuest']) {$script:Ledger.Global | Add-Member -NotePropertyName ExpectedForceGuest -NotePropertyValue $null}
    if(@($script:Ledger.Global.Registry | Where-Object {$_.Name -eq 'ForceGuest'}).Count -eq 0) {$script:Ledger.Global.Registry=@($script:Ledger.Global.Registry)+@($script:Transaction.System.Registry | Where-Object {$_.Name -eq 'ForceGuest'})}
    foreach($group in @($script:Transaction.System.Groups)) { if(@($script:Ledger.Global.Groups | Where-Object {$_.Sid -eq $group.Sid}).Count -eq 0) {$script:Ledger.Global.Groups=@($script:Ledger.Global.Groups)+@($group)} }
    if ($null -ne $script:Transaction.System.Binding -and @($script:Ledger.Global.Bindings | Where-Object {$_.Name -eq $script:Transaction.System.Binding.Name}).Count -eq 0) {$script:Ledger.Global.Bindings=@($script:Ledger.Global.Bindings)+@($script:Transaction.System.Binding)}
    Complete-WorkStep 'apply-snapshot'
    try {
        Write-Phase 'Ausgewähltes Heimnetz und Windows-Dienste einrichten …'
        if (Advanced-Repair $Request) {
            $binding=$script:Transaction.System.Binding
            if ($null -ne $binding -and -not $binding.Enabled) { Enable-NetAdapterBinding -Name $binding.Name -ComponentID ms_server -ErrorAction Stop | Out-Null; Add-Check 'SMB-Adapterbindung' ok 'Datei- und Druckerfreigabe wurde auf dem gewählten Netzwerkadapter aktiviert.' 'BINDING_REPAIRED' $true }
        }
        Set-NetConnectionProfile -InterfaceIndex $Network.Id -NetworkCategory Private
        Set-Service -Name LanmanServer -StartupType Automatic
        Start-Service -Name LanmanServer
        Set-Service -Name LanmanWorkstation -StartupType Automatic
        Start-Service -Name LanmanWorkstation
        foreach ($service in @('FDResPub','fdPHost')) {
            Set-Service -Name $service -StartupType Automatic
            New-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $service) -Name DelayedAutoStart -Value 1 -PropertyType DWord -Force | Out-Null
            Start-Service -Name $service
        }
        Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force | Out-Null
        Complete-WorkStep 'apply-services'
        Write-Phase 'Firewall für Adapter, Heimnetz und SMB begrenzen …'
        Configure-Firewall $Network (Rule-Prefix $name)
        Complete-WorkStep 'apply-firewall'
        Write-Phase 'Freigabekonto und Anmeldung einrichten …'
        $sids = @()
        $userSid = ''; $actualUser = ''
        if ($mode -ieq 'Guest') {
            if ((Advanced-Repair $Request) -and 'SeDenyNetworkLogonRight' -in @([EinfachNetzwerk.Native]::Rights('S-1-5-32-546'))) { [EinfachNetzwerk.Native]::Right('S-1-5-32-546', 'SeDenyNetworkLogonRight', $false) }
            Enable-LocalUser -SID $guest.SID
            [EinfachNetzwerk.Native]::Right($guest.SID.Value, 'SeDenyNetworkLogonRight', $false)
            [EinfachNetzwerk.Native]::Right($guest.SID.Value, 'SeNetworkLogonRight', $true)
            [EinfachNetzwerk.Native]::Right($guest.SID.Value, 'SeDenyInteractiveLogonRight', $true)
            [EinfachNetzwerk.Native]::Right($guest.SID.Value, 'SeDenyRemoteInteractiveLogonRight', $true)
            if ($server.RequireSecuritySignature) { Set-SmbServerConfiguration -RequireSecuritySignature $false -Force | Out-Null }
            Set-NullShare $name $true
            $sids = @($guest.SID.Value, 'S-1-5-7')
            $actualUser = $guest.Name
        } else {
            if ((Advanced-Repair $Request) -and $force.Exists -and [int]$force.Value -ne 0) { New-ItemProperty -LiteralPath $force.Path -Name ForceGuest -PropertyType DWord -Value 0 -Force | Out-Null }
            if ($null -eq $user) {
                $secure = ConvertTo-SecureString $script:Secret -AsPlainText -Force
                try { $user = New-LocalUser -Name $userName -Password $secure -Description $script:AppMark -AccountNeverExpires -PasswordNeverExpires }
                finally { if ($null -ne $secure) { $secure.Dispose() } }
                $created = [pscustomobject]@{ Name = $user.Name; Sid = $user.SID.Value }
                $script:AccountCreated = $created
                $script:Transaction.CreatedUser = $created
                # Journal the SID before any following operation can fail.
                Write-JsonAtomic $backup $script:Transaction
                $script:Ledger.CreatedUsers = @($script:Ledger.CreatedUsers) + @($created)
                Add-LocalGroupMember -SID (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')) -Member $user
            } else { Enable-LocalUser -SID $user.SID }
            Load-Native
            [EinfachNetzwerk.Native]::Right($user.SID.Value, 'SeDenyNetworkLogonRight', $false)
            [EinfachNetzwerk.Native]::Right($user.SID.Value, 'SeNetworkLogonRight', $true)
            [EinfachNetzwerk.Native]::Right($user.SID.Value, 'SeDenyInteractiveLogonRight', $true)
            [EinfachNetzwerk.Native]::Right($user.SID.Value, 'SeDenyRemoteInteractiveLogonRight', $true)
            Set-NullShare $name $false
            $sids = @($user.SID.Value); $userSid = $user.SID.Value; $actualUser = $user.Name
        }
        Complete-WorkStep 'apply-account'
        Write-Phase 'Gewählten Ordner und seine Freigaberechte einrichten …'
        if (Advanced-Repair $Request) { Repair-FolderDenials $Folder (Relevant-Sids $mode $sids[0]) ([bool](Get-Value $Request 'AllowWrite' $false)); Configure-Folder $Folder $sids ([bool](Get-Value $Request 'AllowWrite' $false)) $null }
        else { Configure-Folder $Folder $sids ([bool](Get-Value $Request 'AllowWrite' $false)) $managed }
        $sddl = Get-ShareSddl $sids ([bool](Get-Value $Request 'AllowWrite' $false))
        # The initiating local Windows user retains access to their own share.
        $sddl += '(A;;FA;;;' + $originalSid + ')'
        $parameters = @{ Name = $name; SecurityDescriptor = $sddl; Description = (Get-DiscoveryShareDescription $mode $actualUser); EncryptData = $false }
        if ($mode -ieq 'Password' -and $null -ne $existing) { $parameters.EncryptData = [bool]$existing.EncryptData }
        if ($null -eq $existing) { $parameters.Path = $Folder.Path; New-SmbShare @parameters | Out-Null }
        else { Set-SmbShare @parameters -Force | Out-Null }
        Complete-WorkStep 'apply-folder-share'
        # Validation remains local: no claim that every remote client is tested.
        Write-Phase 'Freigabe, Profil, Rechte und Anmeldung lokal prüfen …'
        Confirm-AndRepairLocalShare $Request $Folder $Network $sids $originalSid
        $share = Get-ShareSnapshot $name
        $profile = Get-NetConnectionProfile -InterfaceIndex $Network.Id
        if ($null -eq $share -or $share.Path.TrimEnd('\') -ine $Folder.Path.TrimEnd('\') -or [string]$profile.NetworkCategory -ne 'Private') { throw 'Die Freigabe oder das private Netzwerkprofil wurde von Windows nicht übernommen.' }
        if (-not (Get-SmbServerConfiguration).EnableSMB2Protocol) { throw 'SMB 2/3 konnte nicht aktiviert werden.' }
        $sd = New-Object Security.AccessControl.RawSecurityDescriptor($share.SecurityDescriptor)
        foreach ($sid in $sids) { if (@($sd.DiscretionaryAcl | Where-Object { $_.AceQualifier -eq 'AccessAllowed' -and $_.SecurityIdentifier.Value -eq $sid }).Count -eq 0) { throw 'Windows hat die gewünschten Freigaberechte nicht übernommen.' } }
        if ($mode -ieq 'Password' -and -not [string]::IsNullOrEmpty($script:Secret)) {
            $code = [EinfachNetzwerk.Native]::NetworkLogon($actualUser, $script:Secret)
            if ($code -ne 0) { throw ('Die lokale Netzwerkanmeldung für das Freigabekonto scheitert (Windows-Code ' + $code + '). Vorhandene Passwörter werden nicht geändert; bitte das bisherige Passwort oder einen neuen Benutzernamen verwenden.') }
            Add-Check 'Kontoprüfung' ok 'Die lokale Netzwerkanmeldung mit dem Freigabekonto funktioniert. Das Passwort wird nicht gespeichert oder angezeigt.'
        } elseif ($mode -ieq 'Guest') {
            $code = [EinfachNetzwerk.Native]::NetworkLogon($actualUser, '')
            if ($code -ne 0) { throw ('Windows lehnt die lokale Gast-Netzwerkanmeldung ohne Passwort ab (Windows-Code ' + $code + '). Ein bestehendes Gastpasswort oder eine weitere Sicherheitsrichtlinie kann den Zugriff verhindern. Vorhandene Passwörter werden nicht geändert; bitte Passwortmodus verwenden oder die genannte Richtlinie gezielt prüfen.') }
            Add-Check 'Gast-Kontoprüfung' ok 'Die lokale Gast-Netzwerkanmeldung mit leerem Passwort funktioniert. Der Zugriff vom anderen Gerät muss dort zusätzlich geprüft werden.'
        } else {
            Add-Check 'Anmeldung am anderen Gerät' info 'Die gespeicherten Freigaberechte wurden repariert. Zur Prüfung des bestehenden Passworts das Passwort eingeben oder die Verbindung am anderen Gerät testen.' 'CLIENT_LOGIN_CHECK' $false 'Mit dem angezeigten Netzwerk-Konto anmelden. Ein leeres Passwortfeld bei der Reparatur ändert das vorhandene Kontopasswort nicht.'
        }
        Complete-WorkStep 'apply-local-verification'
        if ($mode -ieq 'Guest') { Test-RealSmbConnection $Request $Network $actualUser '' $true }
        elseif (-not [string]::IsNullOrEmpty($script:Secret)) { Test-RealSmbConnection $Request $Network $actualUser $script:Secret $true }
        else { Add-Check 'SMB-Verbindung noch offen' warning 'Für den echten Verbindungstest fehlt das bestehende Passwort. Die Windows-Einstellungen wurden geprüft; der Zugriff muss mit dem Passwort getestet werden.' 'SMB_PASSWORD_NEEDED' $false }
        Complete-WorkStep 'apply-smb-probe'
        $originalShare = $script:Transaction.Share; $originalFolder = $script:Transaction.FolderSddl
        if ($null -ne $managed) { $originalShare = $managed.OriginalShare; $originalFolder = $managed.OriginalFolderSddl }
        $record = [pscustomobject]@{ Name = $name; Path = $Folder.Path; Mode = $mode; AllowWrite = [bool](Get-Value $Request 'AllowWrite' $false); AllowDriveRoot = $Folder.IsRoot; UserName = $actualUser; UserSid = $userSid; AdapterId = $Network.Id; AdapterName=$Network.Name; NetworkSubnet=$Network.Subnet; OriginalShare = $originalShare; OriginalFolderSddl = $originalFolder; AppliedFolderSddl = $null; BackupPath = $backup }
        if ($Folder.Format -in @('NTFS','ReFS')) { $record.AppliedFolderSddl = (Get-Acl -LiteralPath $Folder.Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) }
        $script:Ledger.Shares = @($script:Ledger.Shares | Where-Object { $_.Name -ine $name }) + @($record)
        $currentServer = Get-SmbServerConfiguration
        $script:Ledger.Global.ExpectedServer = [pscustomobject]@{ EnableSMB2Protocol = [bool]$currentServer.EnableSMB2Protocol; RequireSecuritySignature = [bool]$currentServer.RequireSecuritySignature }
        if ($mode -ieq 'Guest') { $script:Ledger.Global.ExpectedGuest = Snapshot-User (Get-Guest) }
        $script:Ledger.Global.ExpectedGroups=@($script:Ledger.Global.Groups | ForEach-Object {[pscustomobject]@{Sid=$_.Sid; Rights=@([EinfachNetzwerk.Native]::Rights($_.Sid))}})
        $script:Ledger.Global.ExpectedForceGuest=Get-RegistrySnapshot 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'ForceGuest'
        $script:Transaction.Status = 'Committed'
        Write-JsonAtomic $backup $script:Transaction
        Write-JsonAtomic $script:LedgerFile $script:Ledger
        $Network.Category = 'Private'
        Build-Connection $Request $Network $actualUser
        $script:Result.Success = $true
        $script:Result.Message = 'Freigabe eingerichtet. SMB-Anmeldung und Ordnerzugriff wurden über eine echte Verbindung von diesem PC geprüft. Verwende auf dem Handy den angezeigten Benutzernamen.'
        if (-not $script:Result.ConnectionVerified) { $script:Result.Message = 'Die Windows-Einstellungen wurden eingerichtet. Der echte SMB-Zugriff ist noch nicht bestätigt; bitte mit dem bestehenden Passwort testen.' }
        if ($Repair -and $script:Result.ConnectionVerified) { $script:Result.Message = 'Die Freigabe wurde repariert. Die SMB-Anmeldung und das Auflisten des Ordners funktionieren in einer echten Verbindung von diesem PC.' }
        Add-Check 'Freigabe eingerichtet' ok ($name + ' → ' + $Folder.Path)
        Complete-WorkStep 'apply-commit'
    } catch {
        $failureRecord = $_
        $script:Transaction.Status = 'Failed'
        Write-Phase 'Fehlgeschlagene Änderungen aus dem Journal zurücknehmen …'
        $rollback = Undo-Transaction $script:Transaction
        $script:Transaction.Status = 'RollbackIncomplete'; if ($rollback) { $script:Transaction.Status = 'RolledBack' }
        try { Write-JsonAtomic $backup $script:Transaction } catch { Add-Check 'Journal' error ('Der Rücknahmestatus konnte nicht im geschützten Journal gespeichert werden: ' + $_.Exception.Message) }
        throw $failureRecord
    }
    # The outer operation finally removes this password after all diagnostic
    # fields have been sanitized, including errors rethrown after rollback.
}

function Restore-GlobalIfLast {
    if (@($script:Ledger.Shares).Count -gt 0) { return }
    $g = $script:Ledger.Global
    $expectedForce=Get-Value $g 'ExpectedForceGuest' $null
    $originalForce=@($g.Registry | Where-Object {$_.Name -eq 'ForceGuest'} | Select-Object -First 1)
    if($null -ne $expectedForce -and $originalForce.Count -eq 1) {
        $currentForce=Get-RegistrySnapshot $expectedForce.Path $expectedForce.Name
        if($currentForce.Exists -eq $expectedForce.Exists -and $currentForce.Kind -eq $expectedForce.Kind -and [string]$currentForce.Value -ceq [string]$expectedForce.Value) { Restore-Registry $originalForce[0] }
        else {Add-Check 'Windows-Anmeldemodus erhalten' warning 'Der zwischenzeitlich geänderte Windows-Anmeldemodus bleibt erhalten.'}
    }
    foreach($group in @(Get-Value $g 'Groups' @())) {
        $expected=@((Get-Value $g 'ExpectedGroups' @()) | Where-Object {$_.Sid -eq $group.Sid} | Select-Object -First 1)
        if($expected.Count -eq 1) {
            $currentRights=@([EinfachNetzwerk.Native]::Rights($group.Sid))
            if(('SeDenyNetworkLogonRight' -in $currentRights) -eq ('SeDenyNetworkLogonRight' -in @($expected[0].Rights))) { [EinfachNetzwerk.Native]::Right($group.Sid,'SeDenyNetworkLogonRight',('SeDenyNetworkLogonRight' -in @($group.Rights))) }
            else {Add-Check 'Gast-Gruppenrecht erhalten' warning 'Die zwischenzeitlich geänderte Gast-Gruppenrichtlinie bleibt erhalten.'}
        }
    }
    foreach($binding in @(Get-Value $g 'Bindings' @())) {
        $actual=@(Get-NetAdapterBinding -Name $binding.Name -ComponentID ms_server -ErrorAction SilentlyContinue | Select-Object -First 1)
        if($actual.Count -eq 1 -and $actual[0].Enabled -and -not $binding.Enabled) {Disable-NetAdapterBinding -Name $binding.Name -ComponentID ms_server -ErrorAction Stop | Out-Null}
    }
    $server = Get-SmbServerConfiguration
    if ($null -ne $g.ExpectedServer) {
        foreach ($property in @('EnableSMB2Protocol','RequireSecuritySignature')) {
            if ([bool]$server.$property -eq [bool]$g.ExpectedServer.$property) {
                $parameters = @{ Force = $true }; $parameters[$property] = [bool]$g.Server.$property
                Set-SmbServerConfiguration @parameters | Out-Null
            } else { Add-Check 'Windows-Einstellung erhalten' warning ('SMB ' + $property + ' wurde inzwischen anders geändert und bleibt erhalten.') }
        }
    }
    foreach ($network in @($g.Networks)) {
        try { $profile = Get-NetConnectionProfile -InterfaceIndex $network.Id; if ([string]$profile.NetworkCategory -eq 'Private' -and $network.Category -ne 'Private') { Set-NetConnectionProfile -InterfaceIndex $network.Id -NetworkCategory $network.Category } }
        catch { Add-Check 'Netzwerkprofil' warning ('Das ursprüngliche Profil von Adapter ' + $network.Id + ' konnte nicht zurückgesetzt werden.') }
    }
    if ($null -ne $g.Guest) {
        $expected = Get-Value $g 'ExpectedGuest' $null
        if ($null -ne $expected) {
            $current = Snapshot-User (Get-Guest)
            if ($current.Sid -ne $g.Guest.Sid) { throw 'Das Windows-Gastkonto hat sich seit der Freigabe geändert.' }
            if ($current.Enabled -eq $expected.Enabled) {
                if ($g.Guest.Enabled) { Enable-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($current.Sid)) }
                else { Disable-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($current.Sid)) }
            } else { Add-Check 'Gastkonto erhalten' warning 'Die zwischenzeitlich geänderte Aktivierung des Gastkontos bleibt erhalten.' }
            foreach ($right in @('SeDenyNetworkLogonRight','SeNetworkLogonRight','SeDenyInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
                if (($right -in @($current.Rights)) -eq ($right -in @($expected.Rights))) { [EinfachNetzwerk.Native]::Right($current.Sid, $right, ($right -in @($g.Guest.Rights))) }
                else { Add-Check 'Gastrecht erhalten' warning ('Die zwischenzeitlich geänderte Richtlinie ' + $right + ' bleibt erhalten.') }
            }
        }
    }
    foreach ($service in @($g.Services)) {
        $current = Get-ServiceSnapshot $service.Name
        if ($current.StartMode -eq 'Auto' -and $current.State -eq 'Running') { Restore-Service $service }
        else { Add-Check 'Dienste' warning ('Die zwischenzeitlich geänderte Einstellung für ' + $service.Name + ' bleibt erhalten.') }
    }
}
function Normalize-ListedSharePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Der ausgewählte lokale Freigabeordner fehlt oder ist ungültig.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
}
function Remove-ListedShare($Request) {
    $name = [string](Get-Value $Request 'ShareName' '')
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 80 -or $name.Trim() -cne $name -or $name.EndsWith('.') -or
        $name -match '[\\/\[\]:;|=,+*?<>"\x00-\x1f]' -or $name -match '^(?:ADMIN\$?|IPC\$?|[A-Z]\$)$') {
        throw 'Bitte eine vorhandene Datenfreigabe auswählen. Windows-Systemfreigaben werden nicht entfernt.'
    }
    $expectedPath = Normalize-ListedSharePath ([string](Get-Value $Request 'FolderPath' ''))
    $current = @(Get-SmbShare -ErrorAction Stop | Where-Object { [string]$_.Name -ieq $name })
    if ($current.Count -gt 1) { throw 'Der Freigabename ist nicht eindeutig. Es wurde keine Freigabe entfernt.' }
    if ($current.Count -eq 1) {
        $share = $current[0]
        if ([bool](Get-Value $share 'Special' $true)) { throw 'Windows-Systemfreigaben werden nicht entfernt.' }
        if ((Normalize-ListedSharePath ([string]$share.Path)) -ine $expectedPath) { throw 'Die Freigabe wurde inzwischen einem anderen Ordner zugeordnet und bleibt unverändert. Bitte die Übersicht erneut öffnen.' }
        Complete-WorkStep 'listed-validation'
        if ([bool](Get-Value $Request 'DryRun' $false)) {
            $script:Result.Success = $true
            $script:Result.Message = 'Probelauf: Nur die ausgewählte Netzwerkfreigabe entfernen. Dateien und Windows-Einstellungen bleiben erhalten.'
            Add-Check 'Freigabe entfernen' info $script:Result.Message
            Complete-WorkStep 'dryrun-evaluation'
            return
        }
        if (-not (Is-Administrator)) { throw 'Freigabe entfernen benötigt Administratorrechte.' }
        Write-Phase 'Ausgewählte Netzwerkfreigabe entfernen …'
        # Use the freshly read CIM object, never a wildcard or a different scope.
        # No folder, permissions, account, journal or firewall is modified here.
        Remove-SmbShare -InputObject $share -Force -Confirm:$false -ErrorAction Stop | Out-Null
        Complete-WorkStep 'listed-removal'
        $remaining = @(Get-SmbShare -ErrorAction Stop | Where-Object { [string]$_.Name -ieq $name })
        if ($remaining.Count -gt 0) { throw 'Windows zeigt diese Freigabe weiterhin an. Bitte die Übersicht erneut prüfen.' }
        Complete-WorkStep 'listed-verification'
        $script:Result.Message = 'Die Netzwerkfreigabe wurde entfernt. Ihre Dateien und die gespeicherten Windows-Einstellungen bleiben erhalten.'
    } else {
        $script:Result.Message = 'Diese Netzwerkfreigabe ist bereits entfernt. Ihre Dateien bleiben erhalten.'
        Complete-WorkStep 'listed-validation'
        Complete-WorkStep 'listed-removal'
        Complete-WorkStep 'listed-verification'
        Complete-WorkStep 'dryrun-evaluation'
    }
    $script:Result.Success = $true
    Add-Check 'Freigabe entfernen' ok $script:Result.Message
    try { Read-ShareInventory } catch { Add-Check 'Inventar aktualisieren' warning 'Die Freigabe ist entfernt; die Übersicht konnte noch nicht vollständig neu gelesen werden.' }
    Complete-WorkStep 'listed-inventory'
    $script:Result.ConnectionText = ''; $script:Result.SharePath = ''
}
function Remove-ManagedShare($Request, [bool]$RestoreOriginal) {
    $name = [string]$Request.ShareName
    $managed = Get-Managed $name
    if ($null -eq $managed) { throw 'Diese Freigabe wird nicht vom Programm verwaltet. Fremde Freigaben werden nicht gelöscht oder zurückgesetzt.' }
    $approvedPath = [string](Get-Value $Request 'FolderPath' '')
    if (-not [string]::IsNullOrWhiteSpace($approvedPath) -and (Normalize-ListedSharePath $approvedPath) -ine (Normalize-ListedSharePath ([string]$managed.Path))) {
        throw 'Die gespeicherte Freigabe wurde inzwischen einem anderen Ordner zugeordnet. Bitte die Übersicht neu erstellen; es wurde nichts entfernt.'
    }
    if (-not [bool](Get-Value $Request 'DryRun' $false)) {$script:FolderGuard=[EinfachNetzwerk.BackendClient]::LockDataFolder($managed.Path)}
    $current = Get-ShareSnapshot $name
    if ($null -ne $current -and $current.Path.TrimEnd('\') -ine $managed.Path.TrimEnd('\')) { throw 'Die Freigabe wurde inzwischen einem anderen Ordner zugeordnet und bleibt unverändert.' }
    Assert-NoReparse $managed.Path
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        Add-Check 'Geplante Rücknahme' info ('Nur verwaltete Freigabe ' + $name + ', eigene Firewall-Regeln und unveränderte App-Ordnerrechte zurücknehmen. Dateien bleiben erhalten. Noch keine Änderung.')
        Complete-WorkStep 'remove-validation'
        Complete-WorkStep 'dryrun-evaluation'
        $script:Result.Success = $true; $script:Result.Message = 'Probelauf abgeschlossen; nichts wurde verändert.'; return
    }
    if (-not (Is-Administrator)) { throw 'Entfernen oder Zurücknehmen benötigt Administratorrechte.' }
    Assert-LedgerProtection
    # Refuse destructive restoration if an ACL changed after our last write.
    if (-not [string]::IsNullOrEmpty([string]$managed.AppliedFolderSddl)) {
        $actual = (Get-Acl -LiteralPath $managed.Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        if ($actual -ne $managed.AppliedFolderSddl) { throw 'Die Ordnerrechte wurden seit der Freigabe anderweitig geändert. Die automatische Rücknahme stoppt, damit diese Änderungen erhalten bleiben. Bitte die Rechte manuell prüfen.' }
    }
    Complete-WorkStep 'remove-validation'
    # Keep a current-state transaction before reversible removal steps. Account
    # cleanup runs only after that transaction commits, because old passwords
    # cannot be recovered from configuration snapshots.
    $profile = @(Get-NetConnectionProfile -InterfaceIndex $managed.AdapterId -ErrorAction SilentlyContinue | Select-Object -First 1)
    $network = [pscustomobject]@{ Id = -1; Category = 'Private' }
    if ($profile.Count -gt 0) { $network.Id = $managed.AdapterId; $network.Category = [string]$profile[0].NetworkCategory }
    $guest = $null
    if ($null -ne $script:Ledger.Global.Guest) { $guest = Get-Guest }
    $user = $null
    if (-not [string]::IsNullOrEmpty([string]$managed.UserSid)) { $user = Get-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($managed.UserSid)) -ErrorAction SilentlyContinue }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($managed.Path))
    $folder = [pscustomobject]@{ Path = $managed.Path; Format = $drive.DriveFormat }
    $transactionRequest = [pscustomobject]@{ ShareName = $name }
    $transaction = New-Transaction $transactionRequest $folder $network $guest $user
    $currentNetworks = @()
    foreach ($n in @($script:Ledger.Global.Networks)) {
        $p = @(Get-NetConnectionProfile -InterfaceIndex $n.Id -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($p.Count -gt 0) { $currentNetworks += [pscustomobject]@{ Id = $n.Id; Category = [string]$p[0].NetworkCategory } }
    }
    $transaction.System | Add-Member -MemberType NoteProperty -Name Networks -Value $currentNetworks
    $ledgerBefore = ConvertTo-Json -InputObject $script:Ledger -Depth 18
    Write-Phase 'Verwaltete Freigabe und Rücknahmedaten prüfen …'
    $archive = Join-Path $script:LedgerRoot ('remove-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
    Write-JsonAtomic $archive ([pscustomobject]@{ App = $script:AppMark; Version = 1; Action = 'Remove'; Record = $managed; Transaction = $transaction; Ledger = $script:Ledger })
    $script:Result.BackupPath = $archive
    Complete-WorkStep 'remove-snapshot'
    try {
        Write-Phase 'Freigabe, eigene Regeln und Ordnerrechte zurücknehmen …'
        if ($RestoreOriginal) { Restore-ShareSnapshot $name $managed.OriginalShare }
        elseif ($null -ne $current) { Remove-SmbShare -Name $name -Force -Confirm:$false }
        Restore-Folder $managed.Path $managed.OriginalFolderSddl
        Clear-ManagedRules (Rule-Prefix $name)
        # Preserve all unrelated existing NullSessionShares, including names
        # added by other tools since the original snapshot.
        $initial = @($script:Ledger.Global.Registry | Where-Object { $_.Name -eq 'NullSessionShares' } | Select-Object -First 1)
        $previouslyAllowed = $false
        if ($initial.Count -gt 0) { $previouslyAllowed = $name -in @($initial[0].Value) }
        Set-NullShare $name $previouslyAllowed
        $script:Ledger.Shares = @($script:Ledger.Shares | Where-Object { $_.Name -ine $name })
        Restore-GlobalIfLast
        if (@($script:Ledger.Shares).Count -eq 0 -and $initial.Count -gt 0) {
            $currentNull = @(Get-NullShares)
            $oldNull = @($initial[0].Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if (($currentNull -join "`0") -ceq ($oldNull -join "`0")) { Restore-Registry $initial[0] }
        }
        Complete-WorkStep 'remove-configuration'
        Write-JsonAtomic $script:LedgerFile $script:Ledger
        $transaction.Status = 'Committed'
        Write-JsonAtomic $archive ([pscustomobject]@{ App = $script:AppMark; Version = 1; Action = 'Remove'; Transaction = $transaction; Record = $managed })
        Complete-WorkStep 'remove-commit'
    } catch {
        $failure = $_.Exception.Message
        $script:Ledger = $ledgerBefore | ConvertFrom-Json
        Write-Phase 'Unvollständige Rücknahme aus dem Journal wiederherstellen …'
        $rollback = Undo-Transaction $transaction
        try { Write-JsonAtomic $script:LedgerFile $script:Ledger } catch { Add-Check 'Journal' error 'Der frühere Verwaltungsstand konnte nicht zurückgeschrieben werden.' }
        throw $failure
    }
    # Once committed, failures here are warnings with retained ownership data.
    # Deleting a dedicated account is never included in rollback snapshots.
    if (@($script:Ledger.CreatedUsers).Count -gt 0) {
        Remove-UnusedCreatedUsers
        try { Write-JsonAtomic $script:LedgerFile $script:Ledger } catch { Add-Check 'Kontobereinigung' warning 'Der Bereinigungsstatus konnte nicht gespeichert werden. Ein späterer Start kann anhand der gespeicherten Konten erneut prüfen.' }
    }
    Complete-WorkStep 'remove-cleanup'
    $script:Result.Success = $true
    $script:Result.Message = 'Die verwaltete Freigabe wurde entfernt. Ihre Dateien bleiben erhalten.'
    if ($RestoreOriginal) { $script:Result.Message = 'Die Freigabe und die gespeicherten ursprünglichen Einstellungen wurden zurückgenommen. Ihre Dateien bleiben erhalten.' }
    Add-Check 'Rücknahme' ok $script:Result.Message
    try { Read-ShareInventory; $script:Result.Networks = @(Get-HomeNetworks) } catch { Add-Check 'Inventar aktualisieren' warning 'Die Rücknahme ist abgeschlossen; das aktuelle Freigabeinventar konnte nicht vollständig neu gelesen werden.' }
    Complete-WorkStep 'remove-inventory'
    $script:Result.ConnectionText = ''
    $script:Result.SharePath = ''
}

try {
    Write-Phase 'Windows-Netzwerk und Freigaben lesen …'
    if ([string]::IsNullOrEmpty($RequestJson)) { $RequestJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RequestPath), [Text.Encoding]::UTF8) }
    $script:Request = $RequestJson | ConvertFrom-Json
    $action = [string](Get-Value $script:Request 'Action' 'Inspect')
    if ($action -notin @('Inspect','Apply','Repair','Remove','Restore','Rename','RepairSystem','RemoveListedShare','InspectRemote','ConnectRemote','RepairClient','RestoreClient','InspectClient','PrepareClient','EnumerateComputer','InspectServices','RepairServices','RestoreServices','BackupReset','InspectResetShares')) { throw 'Unbekannte Aktion.' }
    Initialize-WorkProgress $action ([bool](Get-Value $script:Request 'DryRun' $false))
    Complete-WorkStep 'request'
    if ($action -notin @('Inspect','InspectRemote','ConnectRemote','InspectClient','EnumerateComputer','InspectServices','InspectResetShares') -and -not [bool](Get-Value $script:Request 'DryRun' $false)) {
        if (-not (Is-Administrator)) { throw 'Diese Aktion benötigt Administratorrechte. Bitte die Windows-Abfrage des Programms bestätigen.' }
        $mutexSecurity = New-Object Security.AccessControl.MutexSecurity
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) { $mutexSecurity.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'Allow'))) }
        $createdNew = $false
        $script:MutationMutex = New-Object Threading.Mutex($false, 'Global\EinfachNetzwerk-v1-Configuration', [ref]$createdNew, $mutexSecurity)
        try { $script:MutexHeld = $script:MutationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:MutexHeld = $true }
        if (-not $script:MutexHeld) { throw 'Eine andere Instanz bearbeitet gerade die Freigaben. Bitte deren Abschluss abwarten und erneut versuchen.' }
        if ($action -ine 'RemoveListedShare') { Assert-LedgerProtection }
    }
    Complete-WorkStep 'access'
    if ($action -ieq 'BackupReset') {
        Backup-ResetState
    } elseif ($action -ieq 'InspectResetShares') {
        Inspect-ResetShares
    } elseif ($action -in @('InspectRemote','ConnectRemote','RepairClient','RestoreClient','InspectClient','PrepareClient','EnumerateComputer','InspectServices','RepairServices','RestoreServices','RepairSystem')) {
        switch ($action) {
            'InspectRemote' { Invoke-InspectRemote $script:Request }
            'ConnectRemote' { Invoke-ConnectRemote $script:Request }
            'RepairClient' { Invoke-RepairClient $script:Request }
            'RestoreClient' { Invoke-RestoreClient $script:Request }
            'InspectClient' { Invoke-InspectClient $script:Request }
            'PrepareClient' { Invoke-PrepareClient $script:Request }
            'EnumerateComputer' { Invoke-EnumerateComputer $script:Request }
            'InspectServices' { Invoke-InspectLocalServices $script:Request }
            'RepairServices' { Invoke-RepairLocalServices $script:Request }
            'RestoreServices' { Invoke-RestoreLocalServices $script:Request }
            'RepairSystem' {
                if (-not (Advanced-Repair $script:Request)) { throw 'Bitte die automatische Blockaden-Reparatur aktivieren.' }
                Invoke-RepairLocalServices $script:Request
            }
        }
    } elseif ($action -ieq 'Inspect' -and (Get-Command Get-ServiceNativeSnapshot -ErrorAction SilentlyContinue) -and (Get-ServiceNativeSnapshot 'LanmanServer').State -ne 'Running') {
        # A stopped server makes the SMB providers unusable. Diagnose directly
        # before any network/share provider call can delay the repair controls.
        Invoke-InspectLocalServices $script:Request
        Add-Check 'Freigaben' warning 'Die Freigabeliste und SMB-Einstellungen werden erst nach dem Start des lokalen Serverdiensts gelesen.' 'SERVICE_INVENTORY_UNAVAILABLE' $true 'Automatisch reparieren öffnet die lokale Windows-Dienstereparatur.'
        foreach ($step in @('ledger','computer','network','selection','inspect-shares','inspect-network','inspect-LanmanServer','inspect-LanmanWorkstation','inspect-FDResPub','inspect-fdPHost','inspect-smb','inspect-port','inspect-firewall','inspect-guest','inspect-folder','inspect-connection')) { Complete-WorkStep $step }
    } else {
    # The ledger is only read during inspection/dry runs, never created.
    try { $script:Ledger = Read-Ledger } catch { if ($action -notin @('Inspect','RemoveListedShare')) { throw }; Add-Check 'Journal' warning $_.Exception.Message }
    if ($action -ieq 'Repair') {
        $saved = Get-Managed ([string](Get-Value $script:Request 'ShareName' ''))
        if ($null -eq $saved) { throw 'Reparieren gilt nur für Freigaben, die dieses Programm verwaltet.' }
        foreach ($property in @('Mode','AllowWrite','UserName','AdapterId')) { $script:Request | Add-Member -MemberType NoteProperty -Name $property -Value $saved.$property -Force }
        $script:Request | Add-Member -MemberType NoteProperty -Name FolderPath -Value $saved.Path -Force
        $script:Request | Add-Member -MemberType NoteProperty -Name AllowDriveRoot -Value ([bool](Get-Value $saved 'AllowDriveRoot' $false)) -Force
    }
    Complete-WorkStep 'ledger'
    if ($action -ieq 'Inspect') {
        # Restore remains available on the receiving PC after a restart,
        # even when the remote computer is asleep or disconnected.
        try { Publish-ClientRestoreState }
        catch { Add-Check 'Client-Rücknahme' warning $_.Exception.Message 'CLIENT_RESTORE_INVENTORY_FAILED' }
    }
    Get-ComputerNames
    Complete-WorkStep 'computer'
    $networks = @()
    try { $networks = @(Get-HomeNetworks); $script:Result.Networks = $networks } catch { Add-Check 'Netzwerkadressen' error ('Netzwerkdaten können nicht gelesen werden: ' + $_.Exception.Message) }
    $network = @($networks | Where-Object { $_.Id -eq [int](Get-Value $script:Request 'AdapterId' -1) } | Select-Object -First 1)
    if ($network.Count -eq 0 -and $action -ieq 'Inspect' -and $networks.Count -gt 0) { $network = @($networks[0]) }
    if ($network.Count -eq 0 -and $action -ieq 'Repair' -and (Advanced-Repair $script:Request)) {
        $savedName=[string](Get-Value $saved 'AdapterName' '')
        $savedSubnet=[string](Get-Value $saved 'NetworkSubnet' '')
        $candidate=@($networks | Where-Object {(-not [string]::IsNullOrEmpty($savedName) -and $_.Name -eq $savedName) -or (-not [string]::IsNullOrEmpty($savedSubnet) -and $_.Subnet -eq $savedSubnet)})
        if($candidate.Count -eq 1) {$network=@($candidate[0])}
        elseif($networks.Count -eq 1) {$network=@($networks[0])}
        if($network.Count -eq 1) {$script:Request.AdapterId=$network[0].Id; Add-Check 'Heimnetz wiedergefunden' info 'Der frühere Adapter ist nicht mehr aktiv. Die eindeutige aktuelle Heimnetzverbindung wird verwendet und erneut gesichert.' 'ADAPTER_RECOVERED' $true}
    }
    $selected = $null; if ($network.Count -gt 0) { $selected = $network[0] }
    Complete-WorkStep 'network'
    $folder = $null
    $path = [string](Get-Value $script:Request 'FolderPath' '')
    if ($action -notin @('Remove','Restore','Rename','RepairSystem','RemoveListedShare') -and -not [string]::IsNullOrWhiteSpace($path)) {
        try { $folder = Resolve-ShareFolder $script:Request } catch { if ($action -ine 'Inspect') { throw }; Add-Check 'Ordner' error $_.Exception.Message }
    }
    $name = [string](Get-Value $script:Request 'ShareName' '')
    if ($action -notin @('Rename','RepairSystem','RemoveListedShare')) { if ($action -ine 'Inspect' -or -not [string]::IsNullOrEmpty($name)) { Assert-ShareName $name }; Build-Connection $script:Request $selected ([string](Get-Value $script:Request 'UserName' 'NetzwerkUser')) }
    Complete-WorkStep 'selection'
    switch ($action.ToLowerInvariant()) {
        'inspect' {
            if ((Get-Command Get-ServiceNativeSnapshot -ErrorAction SilentlyContinue) -and (Get-ServiceNativeSnapshot 'LanmanServer').State -ne 'Running') {
                $health = Add-LocalServiceHealthChecks $script:Request $selected
                Add-Check 'Freigaben' warning 'Die Freigabeliste und SMB-Einstellungen werden erst nach dem Start des lokalen Serverdiensts gelesen.' 'SERVICE_INVENTORY_UNAVAILABLE' $true 'Automatisch reparieren öffnet die lokale Windows-Dienstereparatur.'
                foreach ($step in @('inspect-shares','inspect-network','inspect-LanmanServer','inspect-LanmanWorkstation','inspect-FDResPub','inspect-fdPHost','inspect-smb','inspect-port','inspect-firewall','inspect-guest','inspect-folder','inspect-connection')) { Complete-WorkStep $step }
                $script:Result.Success = $false
                $script:Result.Message = 'Der lokale Serverdienst ist nicht gestartet. Bitte Automatisch reparieren verwenden; die genaue Ursache steht in der Prüfung.'
                break
            }
            Inspect-State $script:Request $selected $folder
            $record = Get-Managed ([string](Get-Value $script:Request 'ShareName' ''))
            if ($null -ne $record -and $null -ne $selected -and $record.Mode -ieq 'Guest') { Test-RealSmbConnection $script:Request $selected ([string]$record.UserName) '' $false }
            Complete-WorkStep 'inspect-connection'
            $script:Result.Success = $true
            $script:Result.Message = 'Diagnose abgeschlossen. Es wurden keine Windows-Einstellungen geändert.'
            if (@($script:Checks | Where-Object { $_.Code -eq 'DISCOVERY_SETUP_REQUIRED' }).Count -gt 0) { $script:Result.Message = 'Die Diagnose ist abgeschlossen. Für die automatische Heimnetzsuche fehlen noch Erkennungseinstellungen. „Automatisch reparieren“ aktualisiert die betroffene Freigabe.' }
            if (@($script:Checks | Where-Object { $_.State -eq 'error' }).Count -gt 0) { $script:Result.Success = $false; $script:Result.Message = 'Die Diagnose hat ein Problem erkannt. Die Prüfliste zeigt die Ursache und den nächsten Schritt.' }
        }
        { $_ -in @('apply','repair') } {
            if ($null -eq $folder) { throw 'Bitte einen vorhandenen lokalen Ordner auswählen.' }
            if ($null -eq $selected) { throw 'Bitte eine aktive physische LAN-/WLAN-Verbindung mit privater IPv4 und Heimnetz-Gateway auswählen. VPN, öffentliche Adressen und Domänennetze werden nicht verändert.' }
            Apply-Share $script:Request $folder $selected ($action -ieq 'Repair')
            if (-not [bool](Get-Value $script:Request 'DryRun' $false)) {
                Inspect-State $script:Request $selected $folder
                if (Test-SelectedShareInspectionFailure ([string]$script:Request.ShareName)) { $script:Result.Success = $false; $script:Result.Message = 'Die Freigabe ist eingerichtet, aber die Diagnose erkennt noch ein Problem. Bitte die Prüfliste lesen.' }
            }
        }
        'remove' { Remove-ManagedShare $script:Request $false }
        'removelistedshare' { Remove-ListedShare $script:Request }
        'restore' { Remove-ManagedShare $script:Request $true }
        'repairsystem' {
            if (-not (Advanced-Repair $script:Request)) { throw 'Bitte die automatische Blockaden-Reparatur aktivieren.' }
            if (-not [bool](Get-Value $script:Request 'DryRun' $false)) {
                if ([string](Get-Value $script:Request 'OriginalUserSid' '') -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Die Reparatur muss im ursprünglichen Windows-Benutzerkonto ausgeführt werden.' }
                Assert-PersonalPolicyChanges
                Test-JournalStorage
            }
            Complete-WorkStep 'system-validation'
            Repair-RequiredServiceConfigurations $script:Request
            Complete-WorkStep 'system-service-config'
            if (-not [bool](Get-Value $script:Request 'DryRun' $false)) {
                foreach ($service in @('fdPHost','FDResPub')) {
                    Set-Service -Name $service -StartupType Automatic
                    New-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $service) -Name DelayedAutoStart -Value 1 -PropertyType DWord -Force | Out-Null
                    Start-Service -Name $service
                    if ((Get-ServiceSnapshot $service).State -ne 'Running') { throw ($service + ': Der reparierte Dienst läuft noch nicht.') }
                }
            }
            Complete-WorkStep 'system-services'
            Read-ShareInventory
            Complete-WorkStep 'system-inventory'
            $script:Result.Success=$true
            $script:Result.Message='Die Windows-Erkennungsdienste und das Änderungsjournal wurden repariert und geprüft. Bestehende Freigaben und Dateien bleiben erhalten.'
            if ([bool](Get-Value $script:Request 'DryRun' $false)) { $script:Result.Message='Probelauf: Beschädigte Erkennungsdienste werden aus Windows wiederhergestellt. Keine Windows-Einstellungen geändert.' }
        }
        'rename' { Rename-LocalComputer $script:Request; try { Read-ShareInventory } catch { Add-Check 'Freigaben aktualisieren' warning 'Die Namensänderung wurde bearbeitet; die Freigabeliste konnte nicht aktualisiert werden.' }; Complete-WorkStep 'rename-inventory' }
    }
    }
    Complete-WorkStep 'action-summary'
} catch {
    $failure = $_
    $message = Hide-FailureSecrets $failure.Exception.Message
    Set-FailureDetails $failure
    $script:Result.Success = $false
    $script:Result.Message = $message
    Add-Check 'Aktion' error $message $script:Result.ErrorCode
    Add-FailureGuidance $message
} finally {
    $script:Result.Checks = @($script:Checks.ToArray())
    foreach ($field in @($script:Result.Keys)) {
        if ($script:Result[$field] -is [string]) { $script:Result[$field] = Hide-FailureSecrets $script:Result[$field] }
    }
    foreach ($collection in @('Checks', 'Networks', 'Shares', 'RemoteShares')) {
        foreach ($item in @($script:Result[$collection])) {
            if ($null -eq $item) { continue }
            foreach ($property in @($item.PSObject.Properties)) {
                if ($property.Value -is [string]) { $property.Value = Hide-FailureSecrets $property.Value }
            }
        }
    }
    $script:Secret = $null
    try {
        $output = ConvertTo-Json -InputObject $script:Result -Depth 10
        $resultStream = $null
        try {
            $resultStream = New-Object IO.FileStream([IO.Path]::GetFullPath($ResultPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $outputBytes = [Text.Encoding]::UTF8.GetBytes($output)
            $resultStream.Write($outputBytes, 0, $outputBytes.Length)
            $resultStream.Flush()
        } finally { if ($null -ne $resultStream) { $resultStream.Dispose() } }
        Complete-WorkStep 'response-written'
    } catch {
        # No account/password values are written to stdout or the event log.
        Write-Error 'Die Ergebnisdatei konnte nicht geschrieben werden.' -ErrorAction Continue
    }
    if ($script:MutexHeld -and $null -ne $script:MutationMutex) { $script:MutationMutex.ReleaseMutex() }
    if ($null -ne $script:MutationMutex) { $script:MutationMutex.Dispose() }
    if ($null -ne $script:PhaseStream) { $script:PhaseStream.Dispose() }
    if ($null -ne $script:FolderGuard) { $script:FolderGuard.Dispose() }
}
