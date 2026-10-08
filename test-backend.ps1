param([string]$WorkerPath = (Join-Path $PSScriptRoot 'ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# The tests use an isolated PowerShell runspace with Windows cmdlet doubles.
# They never apply a real share, account, firewall, registry or service change.
$source = [IO.File]::ReadAllText((Resolve-Path $WorkerPath), [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ('Worker syntax: ' + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }

$nativeMatch = [regex]::Match($source, "Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@", [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $nativeMatch.Success) { throw 'Native LSA definitions missing.' }
Add-Type -TypeDefinition ($nativeMatch.Groups[1].Value.Replace('namespace EinfachNetzwerk {', 'namespace EinfachNetzwerkSyntaxTest {'))
Add-Type -TypeDefinition @'
namespace EinfachNetzwerk {
  public static class Native {
    public static bool DenyGuests;
    public static string[] Rights(string sid) { return DenyGuests && sid == "S-1-5-32-546" ? new string[] {"SeDenyNetworkLogonRight"} : new string[0]; }
    public static void Right(string sid, string right, bool enabled) { throw new System.Exception("UNEXPECTED LSA MUTATION"); }
    public static int NetworkLogon(string user, string password) { throw new System.Exception("UNEXPECTED LOGON DURING DRY RUN"); }
  }
}
'@

$mockCode = @'
$global:MockShares = @()
$global:MockPrefix = 24
$global:MockAddress = '192.168.178.24'
$global:MockGateway = '192.168.178.1'
$global:MockForeignUser = $false
$global:MockInboundBlocked = $false
$global:MockMutationCount = 0
[EinfachNetzwerk.Native]::DenyGuests=$false
function UnexpectedMutation { $global:MockMutationCount++; throw 'UNEXPECTED WINDOWS MUTATION' }
function Get-NetAdapter { param([switch]$Physical) [pscustomobject]@{ Status='Up'; HardwareInterface=$true; Virtual=$false; InterfaceDescription='Intel Ethernet'; NdisPhysicalMedium=14; ifIndex=51; Name='LAN-Test' } }
function Get-NetIPConfiguration { param($InterfaceIndex) [pscustomobject]@{ IPv4DefaultGateway=@([pscustomobject]@{ NextHop=$global:MockGateway }); IPv4Address=@([pscustomobject]@{ IPAddress=$global:MockAddress; PrefixLength=$global:MockPrefix; SkipAsSource=$false }) } }
function Get-NetConnectionProfile { param($InterfaceIndex) [pscustomobject]@{ NetworkCategory='Private' } }
function Get-SmbShare { param($Name) if ([string]::IsNullOrEmpty([string]$Name)) { $global:MockShares } else { $global:MockShares | Where-Object { $_.Name -eq $Name } } }
function Get-SmbServerConfiguration { [pscustomobject]@{ EnableSMB2Protocol=$true; EnableSMB1Protocol=$false; RequireSecuritySignature=$true; EncryptData=$false } }
function Get-NetFirewallProfile { param($Name,$PolicyStore) $v='NotConfigured'; if ($global:MockInboundBlocked) { $v='False' }; [pscustomobject]@{ Enabled=$true; AllowInboundRules=$v } }
function Get-NetFirewallRule { param($PolicyStore,$Enabled,$Direction,$Action) }
function Get-NetTCPConnection { param($State,$LocalPort) [pscustomobject]@{ LocalPort=445; State='Listen' } }
function Get-CimInstance { param($ClassName,$Filter) if($ClassName -eq 'Win32_ComputerSystem') {[pscustomobject]@{PartOfDomain=$false;Name='Test-PC'}} else {[pscustomobject]@{ State='Running'; StartMode='Auto' }} }
function Get-LocalUser {
  param($Name,$SID)
  if ([string]::IsNullOrEmpty([string]$Name)) { [pscustomobject]@{ Name='Besucher'; SID=(New-Object Security.Principal.SecurityIdentifier('S-1-5-21-1-2-3-501')); Enabled=$false; Description='' } }
  elseif ($global:MockForeignUser) { [pscustomobject]@{ Name=$Name; SID=(New-Object Security.Principal.SecurityIdentifier('S-1-5-21-1-2-3-1234')); Enabled=$true; Description='' } }
}
function Get-Item {
  param($LiteralPath,[switch]$Force)
  if ($LiteralPath -like 'HKLM:*') {
    $key = New-Object PSObject
    $key | Add-Member ScriptMethod GetValueNames { @() }
    $key
  } else { Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force }
}
function Test-Path {
  param($LiteralPath,$PathType)
  if ($LiteralPath -like '*\EinfachNetzwerk\state.json') { return $false }
  Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Set-NetConnectionProfile { UnexpectedMutation }
function Set-Service { UnexpectedMutation }
function Start-Service { UnexpectedMutation }
function Stop-Service { UnexpectedMutation }
function Set-SmbServerConfiguration { UnexpectedMutation }
function New-NetFirewallRule { UnexpectedMutation }
function Remove-NetFirewallRule { UnexpectedMutation }
function New-LocalUser { UnexpectedMutation }
function Remove-LocalUser { UnexpectedMutation }
function Enable-LocalUser { UnexpectedMutation }
function Disable-LocalUser { UnexpectedMutation }
function Add-LocalGroupMember { UnexpectedMutation }
function Set-SmbShare { UnexpectedMutation }
function New-SmbShare { UnexpectedMutation }
function Remove-SmbShare { UnexpectedMutation }
function New-ItemProperty { UnexpectedMutation }
function New-Item { UnexpectedMutation }
function Remove-ItemProperty { UnexpectedMutation }
function Set-Acl { UnexpectedMutation }
function Enable-NetAdapterBinding { UnexpectedMutation }
function Disable-NetAdapterBinding { UnexpectedMutation }
function Rename-Computer { UnexpectedMutation }
'@

$testRoot = Join-Path $env:TEMP ('EinfachNetzwerk-backendtest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$dataFolder = Join-Path $testRoot 'Daten'
New-Item -ItemType Directory -Path $dataFolder | Out-Null
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$count = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

function Invoke-Isolated($Request, [string]$Setup = '') {
    $session = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $session | Out-Null
    $resultFile = Join-Path $session 'result.json'
    $ps = [Management.Automation.PowerShell]::Create()
    try {
        $null = $ps.AddScript($mockCode + "`r`n" + $Setup).Invoke()
        if ($ps.HadErrors) { throw ('Mock setup failed: ' + ($ps.Streams.Error | Out-String)) }
        $ps.Commands.Clear()
        $null = $ps.AddScript($source).AddParameter('RequestPath', (Join-Path $session 'unused.json')).AddParameter('ResultPath', $resultFile).AddParameter('RequestJson', (ConvertTo-Json -InputObject $Request -Depth 6)).Invoke()
        if (-not (Test-Path -LiteralPath $resultFile)) { throw ('Missing result: ' + ($ps.Streams.Error | Out-String)) }
        $ps.Commands.Clear()
        $mutations = $ps.AddScript('$global:MockMutationCount').Invoke()[0]
        Assert ($mutations -eq 0) 'A Windows mutation was attempted during a read-only test.'
        return ([IO.File]::ReadAllText($resultFile, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    } finally { $ps.Dispose() }
}

try {
    $baseRequest = @{ Action='Apply'; DryRun=$true; FolderPath=$dataFolder; ShareName='Test Netzwerk#%'; Mode='Guest'; UserName='NetzwerkUser'; AdapterId=51; AllowWrite=$true; AllowDriveRoot=$false; AllowGuestSettings=$true; OriginalUserSid=$currentSid }
    $r = Invoke-Isolated $baseRequest
    Assert $r.Success ('Guest dry run failed: ' + $r.Message)
    Assert ($r.Networks[0].Subnet -eq '192.168.178.0/24') 'Subnet arithmetic is wrong.'
    Assert ($r.ConnectionText.Contains('smb://192.168.178.24/Test%20Netzwerk%23%25')) 'SMB URI escaping is wrong.'
    Assert ($r.LoginUserName -eq ($env:COMPUTERNAME+'\Besucher') -and $r.ConnectionText.Contains($r.LoginUserName)) 'Renamed built-in guest account is not shown.'
    Assert ($r.ConnectionText.Contains('Passwort leer lassen; Anonym deaktivieren.')) 'Guest connection instructions do not match the named account.'
    Assert ([string]::IsNullOrEmpty($r.BackupPath)) 'Dry run created a backup.'
    $count++

    $p = $baseRequest.Clone(); $p.Mode='Password'; $p.AllowGuestSettings=$false; $p.ProtectedPassword='intentionally-not-dpapi'
    $r = Invoke-Isolated $p
    Assert $r.Success ('Password dry run unexpectedly decrypted a password: ' + $r.Message)
    Assert (-not ((ConvertTo-Json $r -Depth 8).Contains('intentionally-not-dpapi'))) 'Protected password leaked into result.'
    $count++

    $p = $baseRequest.Clone(); $p.AllowGuestSettings=$false
    $r = Invoke-Isolated $p
    Assert (-not $r.Success -and $r.Message -match 'Zustimmung') 'Guest mode bypasses the explicit guest-setting consent.'
    $count++

    $p = $baseRequest.Clone(); $p.ShareName='ADMIN$'
    $r = Invoke-Isolated $p
    Assert (-not $r.Success) 'An administrative share name was accepted.'
    $count++

    $p = $baseRequest.Clone(); $p.FolderPath=[IO.Path]::GetPathRoot($env:WINDIR); $p.AllowDriveRoot=$true
    $r = Invoke-Isolated $p
    Assert (-not $r.Success -and $r.Message -match 'Systemfestplatte') 'The Windows system drive was accepted.'
    $count++

    $p = $baseRequest.Clone(); $p.FolderPath=$env:WINDIR
    $r = Invoke-Isolated $p
    Assert (-not $r.Success -and $r.Message -match 'Windows-') 'The Windows folder was accepted.'
    $count++

    $p = $baseRequest.Clone(); $p.FolderPath='\\computer\share'
    $r = Invoke-Isolated $p
    Assert (-not $r.Success -and $r.Message -match 'lokale') 'A remote UNC folder was accepted.'
    $count++

    $p = $baseRequest.Clone(); $p.AdapterId=999
    $r = Invoke-Isolated $p
    Assert (-not $r.Success) 'An unknown adapter was accepted.'
    $count++

    $r = Invoke-Isolated $baseRequest '$global:MockAddress="10.0.0.2"; $global:MockGateway="10.0.0.1"; $global:MockPrefix=1'
    Assert (-not $r.Success -and @($r.Networks).Count -eq 0) 'A subnet covering public networks was accepted.'
    $count++

    $setup = '$global:MockShares=@([pscustomobject]@{ Name="Other"; Path=' + "'" + $dataFolder.Replace("'", "''") + "'" + '; Special=$false })'
    $r = Invoke-Isolated $baseRequest $setup
    Assert ($r.Success -and @($r.Checks | Where-Object { $_.Name -eq 'Bestehende Freigabe im Datenbereich' -and $_.State -eq 'warning' }).Count -eq 1) 'An unmanaged overlapping share was silently accepted or unnecessarily blocked.'
    $count++

    $p = $baseRequest.Clone(); $p.Mode='Password'; $p.AllowGuestSettings=$false
    $r = Invoke-Isolated $p '$global:MockForeignUser=$true'
    Assert (-not $r.Success -and $r.Message -match 'gehört nicht') 'A foreign local user could be changed.'
    $count++

    $r = Invoke-Isolated $baseRequest '$global:MockInboundBlocked=$true'
    Assert (-not $r.Success -and $r.Message -match 'Firewallrichtlinie') 'A firewall block policy was incorrectly reported as successful.'
    $count++

    $p = $baseRequest.Clone(); $p.Action='Inspect'
    $r = Invoke-Isolated $p
    Assert $r.Success ('Read-only inspection failed: ' + $r.Message)
    $count++

    $p = $baseRequest.Clone(); $p.Action='Remove'
    $r = Invoke-Isolated $p
    Assert (-not $r.Success -and $r.Message -match 'nicht vom Programm') 'Removal of an unmanaged share was accepted.'
    $count++

    # Exercise the real firewall-plan function against capture-only cmdlets.
    $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Extent.Text }) -join "`r`n"
    $ps = [Management.Automation.PowerShell]::Create()
    try {
        $setup = $mockCode + "`r`n" + $functions + @'

$script:RuleGroup='EinfachNetzwerk (Heimnetz)'; $script:AppMark='EinfachNetzwerk-v1'; $script:Checks=New-Object 'System.Collections.Generic.List[object]'
$global:CapturedRules=New-Object 'System.Collections.Generic.List[object]'
function Get-NetFirewallRule {
  [pscustomobject]@{ Name='NETDIS-FDPHOST-In-UDP'; Direction='Inbound'; Action='Allow' }
  [pscustomobject]@{ Name='NETDIS-FDPHOST-Out-UDP'; Direction='Outbound'; Action='Allow' }
}
function Get-NetFirewallPortFilter { param([Parameter(ValueFromPipeline=$true)]$InputObject) process { [pscustomobject]@{ Protocol='UDP'; LocalPort='3702'; RemotePort='3702' } } }
function Get-NetFirewallApplicationFilter { param([Parameter(ValueFromPipeline=$true)]$InputObject) process { [pscustomobject]@{ Program='%SystemRoot%\system32\svchost.exe' } } }
function Get-NetFirewallServiceFilter { param([Parameter(ValueFromPipeline=$true)]$InputObject) process { [pscustomobject]@{ Service='fdPHost' } } }
function Clear-ManagedRules { param($Prefix) }
function New-NetFirewallRule {
  param($PolicyStore,$Name,$DisplayName,$Group,$Description,$Direction,$Action,$Enabled,$Profile,$Protocol,$LocalPort,$RemotePort,$Program,$Service,$InterfaceAlias,$LocalAddress,$RemoteAddress,$EdgeTraversalPolicy)
  $global:CapturedRules.Add([pscustomobject]@{ Name=$Name; Direction=$Direction; LocalAddress=$LocalAddress; RemoteAddress=$RemoteAddress; Program=$Program; Service=$Service; Profile=$Profile; InterfaceAlias=$InterfaceAlias; LocalPort=$LocalPort })
}
Configure-Firewall ([pscustomobject]@{ Name='LAN-Test'; Address='192.168.178.24'; Subnet='192.168.178.0/24' }) 'test-prefix-'
$global:CapturedRules.ToArray()
'@
        $rules = @($ps.AddScript($setup).Invoke())
        if ($ps.HadErrors) { throw ('Firewall capture failed: ' + ($ps.Streams.Error | Out-String)) }
        Assert ($rules.Count -eq 3) 'WSD templates (including FDPHOST) were not cloned.'
        Assert ($rules[0].Program -eq 'System' -and $rules[0].Service -eq 'Any' -and $rules[0].LocalPort -eq 445) 'SMB kernel firewall filter is wrong.'
        Assert ('Any' -in @($rules[1].LocalAddress)) 'Incoming WSD multicast is blocked by a unicast-only local address.'
        Assert ('239.255.255.250' -in @($rules[2].RemoteAddress)) 'Outbound WSD multicast is blocked.'
        Assert (@($rules | Where-Object { $_.Profile -ne 'Private' -or $_.InterfaceAlias -ne 'LAN-Test' }).Count -eq 0) 'A rule exceeds the chosen private interface.'
        $count++
    } finally { $ps.Dispose() }
    # Prove rollback runs every remaining step after a partial restore failure.
    $ps = [Management.Automation.PowerShell]::Create()
    try {
        $undoSetup = $functions + @'

$script:Checks=New-Object 'System.Collections.Generic.List[object]'
$global:UndoCalls=New-Object 'System.Collections.Generic.List[string]'
function Restore-ShareSnapshot { param($Name,$Snapshot) $global:UndoCalls.Add('share') }
function Restore-Folder { param($Path,$Sddl) $global:UndoCalls.Add('folder'); throw 'SIMULATED ACL RESTORE FAILURE' }
function Restore-Firewall { param($Rules,$Prefix) $global:UndoCalls.Add('firewall') }
function Restore-Registry { param($Snapshot) $global:UndoCalls.Add('registry') }
function Set-SmbServerConfiguration { param($EnableSMB2Protocol,$RequireSecuritySignature,[switch]$Force) $global:UndoCalls.Add('server') }
function Restore-User { param($Snapshot) $global:UndoCalls.Add('user') }
function Remove-CreatedUser { param($User) $global:UndoCalls.Add('created-user') }
function Restore-Service { param($Service) $global:UndoCalls.Add('service') }
function Get-NetConnectionProfile { param($InterfaceIndex) [pscustomobject]@{ NetworkCategory='Private' } }
function Set-NetConnectionProfile { param($InterfaceIndex,$NetworkCategory) $global:UndoCalls.Add('network') }
$tx=[pscustomobject]@{ ShareName='RollbackTest'; Share=$null; FolderPath='C:\Dummy'; FolderSddl='D:AI'; CreatedUser=$null; System=[pscustomobject]@{ Firewall=@(); Registry=@([pscustomobject]@{ Name='NullSessionShares' }); Server=[pscustomobject]@{ EnableSMB2Protocol=$true; RequireSecuritySignature=$true }; Guest=$null; User=$null; Services=@([pscustomobject]@{ Name='Test' }); Network=[pscustomobject]@{ Id=51; Category='Public' } } }
$ok=Undo-Transaction $tx
[pscustomobject]@{ Success=$ok; Calls=@($global:UndoCalls.ToArray()); Checks=@($script:Checks.ToArray()) }
'@
        $undo = @($ps.AddScript($undoSetup).Invoke())
        if ($ps.HadErrors) { throw ('Rollback simulation failed: ' + ($ps.Streams.Error | Out-String)) }
        Assert ($undo.Count -eq 1 -and -not $undo[0].Success) 'A partial rollback failure was incorrectly reported as successful.'
        Assert (($undo[0].Calls -join ',') -eq 'share,folder,firewall,registry,server,user,user,created-user,service,network') 'Rollback stopped after the first failed operation.'
        Assert ($undo[0].Checks[0].State -eq 'error' -and $undo[0].Checks[0].Detail.Contains('SIMULATED ACL RESTORE FAILURE')) 'Rollback omitted its concrete failure.'
        $count++
        $ps.Commands.Clear()
        $successfulUndo = @'
function Restore-Folder { param($Path,$Sddl) $global:UndoCalls.Add('folder') }
function Get-ShareSnapshot { param($Name) $null }
function Get-SmbServerConfiguration { [pscustomobject]@{ EnableSMB2Protocol=$true; RequireSecuritySignature=$true } }
function Get-FirewallSnapshots { param($Prefix) @() }
function Get-NetConnectionProfile { param($InterfaceIndex) [pscustomobject]@{ NetworkCategory='Public' } }
$tx.System.Registry=@(); $tx.System.Services=@()
Undo-Transaction $tx
'@
        $goodUndo = @($ps.AddScript($successfulUndo).Invoke())
        if ($ps.HadErrors) { throw ('Successful rollback simulation failed: ' + ($ps.Streams.Error | Out-String)) }
        Assert ($goodUndo.Count -eq 1 -and [bool]$goodUndo[0]) 'A verified complete rollback was incorrectly reported as failed.'
        $count++
    } finally { $ps.Dispose() }
    # The deny detector checks inherited/explicit bans without editing them.
    $ps = [Management.Automation.PowerShell]::Create()
    try {
        $denyTest = $functions + @'

$acl=New-Object Security.AccessControl.DirectorySecurity
$rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')), 'ReadAndExecute', 'Deny')
$acl.AddAccessRule($rule)
@(Get-RelevantDeny $acl @('S-1-1-0') $false).Count
'@
        $deny = @($ps.AddScript($denyTest).Invoke())
        if ($ps.HadErrors) { throw ('Deny simulation failed: ' + ($ps.Streams.Error | Out-String)) }
        Assert ($deny.Count -eq 1 -and $deny[0] -eq 1) 'A relevant root folder deny was missed.'
        $count++
    } finally { $ps.Dispose() }
    $ps = [Management.Automation.PowerShell]::Create()
    try {
        $aclPreservationTest = $functions + @'

$script:Checks=New-Object 'System.Collections.Generic.List[object]'
$script:Ledger=$null
$global:FolderAcl=New-Object Security.AccessControl.DirectorySecurity
$guestSid='S-1-5-21-1-2-3-501'
$originalRule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($guestSid)), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$global:FolderAcl.AddAccessRule($originalRule)
function Get-Guest { [pscustomobject]@{ SID=(New-Object Security.Principal.SecurityIdentifier('S-1-5-21-1-2-3-501')) } }
function Get-Acl { param($LiteralPath) $global:FolderAcl }
function Set-Acl { param($LiteralPath,$AclObject) $global:FolderAcl=$AclObject }
Configure-Folder ([pscustomobject]@{ Path='C:\Dummy'; Format='NTFS' }) @($guestSid, 'S-1-5-7') $false $null
$grants=@($global:FolderAcl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])|Where-Object{$_.IdentityReference.Value -eq $guestSid -and $_.AccessControlType -eq 'Allow'})
[bool](@($grants|Where-Object{($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify}).Count -gt 0)
function Get-SmbShare { @() }
$script:Ledger=[pscustomobject]@{ Shares=@([pscustomobject]@{ Name='ManagedOther'; Path='D:\Data\Child' }) }
try { Assert-IndependentFolder 'New' 'D:\Data'; 'UNEXPECTED ACCEPTED MANAGED OVERLAP' } catch { $_.Exception.Message }
'@
        $preserved = @($ps.AddScript($aclPreservationTest).Invoke())
        if ($ps.Streams.Error.Count -gt 0) { throw ('Original ACL preservation simulation failed: ' + ($ps.Streams.Error | Out-String)) }
        Assert ($preserved.Count -eq 2 -and [bool]$preserved[0]) 'An original guest write permission was reduced by a new read-only share.'
        Assert ([string]$preserved[1] -match 'überschneidet') 'Managed overlapping folders were accepted.'
        $count += 2
    } finally { $ps.Dispose() }
    $p=$baseRequest.Clone(); $p.AllowAdvancedRepair=$true
    $r=Invoke-Isolated $p
    Assert ($r.Success -and @($r.Checks | Where-Object {$_.Code -eq 'REPAIR_PLAN'}).Count -eq 1) 'Advanced repair DryRun omitted its real plan.'
    $count++
    $r=Invoke-Isolated $p '[EinfachNetzwerk.Native]::DenyGuests=$true'
    Assert ($r.Success -and @($r.Checks | Where-Object {$_.Code -eq 'GUEST_GROUP_REPAIR'}).Count -eq 1) 'A local guest-group block was not planned for repair.'
    $count++
    $r=Invoke-Isolated @{Action='Rename';ComputerName='Mein-NetzwerkPC';DryRun=$true}
    Assert ($r.Success -and $r.Message -match 'Probelauf') 'Computer rename DryRun failed.'
    $count++
    $r=Invoke-Isolated @{Action='Rename';ComputerName='PC\445';DryRun=$true}
    Assert (-not $r.Success) 'Invalid computer name reached Windows rename.'
    $count++
    $r=Invoke-Isolated @{Action='Rename';ComputerName='Mein-NetzwerkPC';DryRun=$true} 'function Get-CimInstance {param($ClassName,$Filter) [pscustomobject]@{PartOfDomain=$true}}'
    Assert (-not $r.Success -and $r.Message -match 'Domäne') 'Domain rename lacked an explicit boundary.'
    $count++
    $ps=[Management.Automation.PowerShell]::Create()
    try {
        $retryTest=$functions+@'

$script:Checks=New-Object 'System.Collections.Generic.List[object]'
$script:Result=[ordered]@{RetryCount=0}
$global:Attempts=0; $global:Fixes=0
function Write-Phase {param($Text)}
function Get-LocalShareProblems {param($Request,$Folder,$Network,$Sids) $global:Attempts++; if($global:Attempts -eq 1) {'Profile'} }
function Set-NetConnectionProfile {param($InterfaceIndex,$NetworkCategory) $global:Fixes++}
Confirm-AndRepairLocalShare ([pscustomobject]@{AllowAdvancedRepair=$true}) $null ([pscustomobject]@{Id=51}) @('S-1-5-7') 'S-1-5-21-1-2-3-1000'
[pscustomobject]@{Attempts=$global:Attempts;Fixes=$global:Fixes;RetryCount=$script:Result.RetryCount;Verified=@($script:Checks | Where-Object {$_.Code -eq 'LOCAL_VERIFIED'}).Count}
'@
        $result=@($ps.AddScript($retryTest).Invoke())
        Assert (-not $ps.HadErrors -and $result.Count -eq 1 -and $result[0].Attempts -eq 2 -and $result[0].Fixes -eq 1 -and $result[0].Verified -eq 1) 'Repair failed to correct a transient block and verify it again.'
        $count++
    } finally {$ps.Dispose()}
    $ps=[Management.Automation.PowerShell]::Create()
    try {
        $boundedTest=$functions+@'

$script:Checks=New-Object 'System.Collections.Generic.List[object]'
$script:Result=[ordered]@{RetryCount=0}
$global:Attempts=0; $global:Fixes=0
function Write-Phase {param($Text)}
function Get-LocalShareProblems {param($Request,$Folder,$Network,$Sids) $global:Attempts++; 'Firewall'}
function Configure-Firewall {param($Network,$Prefix) $global:Fixes++}
$message=''
try {Confirm-AndRepairLocalShare ([pscustomobject]@{AllowAdvancedRepair=$true;ShareName='Test'}) $null ([pscustomobject]@{Id=51}) @('S-1-5-7') 'S-1-5-21-1-2-3-1000'} catch {$message=$_.Exception.Message}
[pscustomobject]@{Attempts=$global:Attempts;Fixes=$global:Fixes;Message=$message;Verified=@($script:Checks | Where-Object {$_.Code -eq 'LOCAL_VERIFIED'}).Count}
'@
        $result=@($ps.AddScript($boundedTest).Invoke())
        Assert ($result.Count -eq 1 -and $result[0].Attempts -eq 3 -and $result[0].Fixes -eq 2 -and $result[0].Message -match 'nicht vollständig' -and $result[0].Verified -eq 0) ('Persistent block was either ignored or retried without a bound: '+($result | ConvertTo-Json -Depth 4 -Compress))
        $count++
    } finally {$ps.Dispose()}
    $ps=[Management.Automation.PowerShell]::Create()
    try {
        $folderTest=$functions+@'

$script:Checks=New-Object 'System.Collections.Generic.List[object]'
$script:MockAcl=New-Object Security.AccessControl.DirectorySecurity
$sid=New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
$script:MockAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Deny')))
function Get-Acl {param($LiteralPath) $script:MockAcl}
function Set-Acl {param($LiteralPath,$AclObject) $script:MockAcl=$AclObject}
Repair-FolderDenials ([pscustomobject]@{Format='NTFS';Path='C:\ISOLATED-MOCK-ONLY'}) @('S-1-1-0') $true
$remaining=@($script:MockAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.AccessControlType -eq 'Deny'})
[pscustomobject]@{Relevant=@(Get-RelevantDeny $script:MockAcl @('S-1-1-0') $true).Count;ProtectedRights=(@($remaining | Where-Object {($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ChangePermissions) -ne 0}).Count -gt 0);Fixed=@($script:Checks | Where-Object {$_.Code -eq 'FOLDER_DENY_FIXED'}).Count}
'@
        $result=@($ps.AddScript($folderTest).Invoke())
        Assert (-not $ps.HadErrors -and $result.Count -eq 1 -and $result[0].Relevant -eq 0 -and $result[0].ProtectedRights -and $result[0].Fixed -eq 1) 'Folder repair removed too much or failed to clear needed access.'
        $count++
    } finally {$ps.Dispose()}
    Write-Output ("Backend: $count isolated checks passed; native C# and PowerShell syntax valid; no real Windows mutations.")
} finally {
    # Delete only this known test folder. Verify resolution before recursion.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'EinfachNetzwerk-backendtest-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
