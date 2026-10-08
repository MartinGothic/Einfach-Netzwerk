param([string]$HelperPath=(Join-Path $PSScriptRoot 'ClientAccessWorker.ps1'),[string]$AssemblyPath=(Join-Path $PSScriptRoot 'dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -eq 'Core') {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -HelperPath $HelperPath -AssemblyPath $AssemblyPath
    exit $LASTEXITCODE
}
# Production functions, fake Windows boundaries. No real service, firewall,
# registry, SMB authentication, security policy or journal mutation occurs.
$taskHelper=[IO.File]::ReadAllText([IO.Path]::GetFullPath($HelperPath),[Text.Encoding]::UTF8)
$taskWorker=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ShareWorker.ps1'),[Text.Encoding]::UTF8)
$taskTokens=$null;$taskErrors=$null
$taskAst=[Management.Automation.Language.Parser]::ParseInput($taskHelper,[ref]$taskTokens,[ref]$taskErrors)
if(@($taskErrors).Count){throw ('Client helper syntax: '+(($taskErrors | ForEach-Object {$_.Message}) -join '; '))}
$taskWorkerAst=[Management.Automation.Language.Parser]::ParseInput($taskWorker,[ref]$taskTokens,[ref]$taskErrors)
foreach($taskName in @('Get-Value','Add-Check','Get-Subnet','Is-PrivateIPv4','Assert-ShareName','Initialize-WorkProgress','Complete-WorkStep','Hide-FailureSecrets')) {
    $taskFunction=$taskWorkerAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskName},$true)
    . ([scriptblock]::Create($taskFunction.Extent.Text))
}
. ([scriptblock]::Create($taskHelper))
$taskRealResolve=${function:Resolve-ClientTarget};$taskRealComputerNative=${function:Test-ClientComputerNative}
$taskRealPinned=${function:Test-ClientPinnedNetwork}
$script:Passed=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:Passed++;Write-Output ('PASS: '+$Message)}
function Throws([scriptblock]$Code,[string]$Message){$thrown=$false;try{& $Code | Out-Null}catch{$thrown=$true};Check $thrown $Message}
function Reset-Case([string]$Action='InspectClient') {
    $script:Checks=New-Object 'System.Collections.Generic.List[object]'
    $script:Result=[ordered]@{Success=$false;Message='';ErrorCode='';ErrorType='';ErrorStackTrace='';ConnectionVerified=$true;NativeConnectionVerified=$true;NamedConnectionVerified=$true;NamedSharePath='stale';RemoteName='stale';RemoteShares=@('stale');RemoteComputerEnumerationVerified=$true;AnonymousShareListDenied=$true;ClientRepairAvailable=$false;ClientBackupPath='';Networks=@();RemoteComputerName='';RemoteAddress='';RemoteShareName='';LoginUserName='';SharePath='';ConnectionText=''}
    $script:Request=[pscustomobject]@{Action=$Action;Mode='Guest';RemoteHost='';RemoteShareName='';RemoteUserName='';ProtectedPassword='';AllowGuestSettings=$true;AdapterId=-1;DryRun=$false}
    $script:Config=[pscustomobject]@{EnableInsecureGuestLogons=$false;RequireSecuritySignature=$true;RequireEncryption=$true}
    $script:PolicyBlocks=@();$script:Managed=$false;$script:Unknown=$false
    $script:Networks=@([pscustomobject]@{Id=16;Name='Ethernet';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private'})
    $script:Service=[pscustomobject]@{Exists=$true;State='Running';StartMode='Auto';Win32ExitCode=0;ServiceSpecificExitCode=0}
    $script:Journal=$null;$script:AppMark='EinfachNetzwerk-v1';$script:LedgerRoot='C:\isolated-no-write'
    $script:Auth=0;$script:Dns=0;$script:Port=0;$script:Decrypt=0;$script:Writes=0;$script:Changes=0;$script:SettingsRead=0;$script:Init=0
    $script:PortAvailable=$true;$script:ChangeFailure='';$script:VerificationFailure=$false;$script:SavedJournals=New-Object 'System.Collections.Generic.List[object]'
    $script:NetworkReads=0;$script:ProfileSwitchRead=0
    $script:SwitchDuringVerify=$false
    $script:NativeProbe=[pscustomobject]@{Success=$true;DirectoryListed=$false;ErrorCode=0;ErrorMessage='';Stage='NetShareEnum';TimedOut=$false;ManagedErrorCode='';ManagedErrorType='';ServerName='TEST-NOTEBOOK';Shares=@([pscustomobject]@{Name='Desktop';Remark='EinfachNetzwerk-v1'})}
    $script:Completed=New-Object 'System.Collections.Generic.HashSet[string]';$script:WorkText='';$script:WorkPlan=$null;$script:WorkCompleted=$null
}
function Write-Phase([string]$Text){}
function Complete-WorkStep([string]$Name){[void]$script:Completed.Add($Name)}
function Get-ServiceNativeSnapshot([string]$Name){if($Name -ne 'LanmanWorkstation'){throw 'Only client service is permitted'};return $script:Service}
function Get-HomeNetworks {
    $script:NetworkReads++
    if($script:ProfileSwitchRead -gt 0 -and $script:NetworkReads -ge $script:ProfileSwitchRead){return @($script:Networks | ForEach-Object {[pscustomobject]@{Id=$_.Id;Name=$_.Name;Address=$_.Address;Subnet=$_.Subnet;Category='Public'}})}
    return $script:Networks
}
function Get-ClientPolicyState{return [pscustomobject]@{Configuration=$script:Config;Blocks=$script:PolicyBlocks;Managed=$script:Managed;Unknown=$script:Unknown}}
function Is-Administrator{return $true}
function Initialize-LedgerDirectory{$script:Init++}
function Read-ClientJournal{return $script:Journal}
function Write-JsonAtomic([string]$Path,$Object){$script:Writes++;$script:Journal=$Object;$script:SavedJournals.Add(($Object | ConvertTo-Json -Depth 10 | ConvertFrom-Json))}
function Get-SmbClientConfiguration {
    $script:SettingsRead++
    if($script:SwitchDuringVerify -and $script:SettingsRead -eq 1){$script:ProfileSwitchRead=1}
    if($script:VerificationFailure -and $script:SettingsRead -eq 1){return [pscustomobject]@{EnableInsecureGuestLogons=$false;RequireSecuritySignature=$false;RequireEncryption=$false}}
    return $script:Config
}
function Set-ClientOwnedValue([string]$Name,[bool]$Value){$script:Changes++;$script:Config.$Name=$Value;if($script:ChangeFailure -eq $Name){$script:ChangeFailure='';throw 'isolated supported cmdlet verification failure'}}
function Resolve-ClientHostAddresses([string]$HostName){$script:Dns++;if($HostName -eq 'TEST-NOTEBOOK'){return @('192.168.178.21')};$numeric=$null;if([Net.IPAddress]::TryParse($HostName,[ref]$numeric)){return @($numeric.ToString())};return @()}
function Test-ClientPort([string]$Address){$script:Port++;return $script:PortAvailable}
function Unprotect-Password($Request){$script:Decrypt++;return 'isolated-network-secret'}
function Test-ClientComputerNative($Request,$Target){$script:Auth++;return $script:NativeProbe}

Reset-Case;Invoke-InspectClient $script:Request
Check (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'CLIENT_GUEST_COMPATIBILITY_REQUIRED') 'Empty-target client inspection detects actual guest, signing and encryption blocks'
Check (@($script:Checks | Where-Object {$_.Code -eq 'SERVICE_WORKSTATION_READY' -and $_.State -eq 'ok' -and $_.Detail -match 'Running; Start: Auto; Windows-Code: 0; Dienst-Code: 0'}).Count -eq 1) 'Receiver diagnosis exposes the observed running local workstation service and actual SCM exit values'
Check (@($script:Checks | Where-Object {$_.Code -eq 'CLIENT_GUEST_COMPATIBILITY_REQUIRED' -and $_.Fixable}).Count -eq 3) 'Known personal blocking values are individually repairable'
Check ($script:Dns -eq 0 -and $script:Auth -eq 0 -and $script:Decrypt -eq 0 -and $script:Changes -eq 0 -and $script:Writes -eq 0) 'Client inspection has no DNS, remote authentication, password or mutation side effects'
Check (-not $script:Result.NativeConnectionVerified -and -not $script:Result.NamedConnectionVerified -and -not $script:Result.RemoteComputerEnumerationVerified -and $script:Result.RemoteShares.Count -eq 0) 'Inspection clears all stale data-share and computer-enumeration proofs'
Check (-not $script:Result.AnonymousShareListDenied) 'Receiver inspection clears a previous optional anonymous list denial'
foreach($taskState in @('Public','DomainAuthenticated')) {
    Reset-Case PrepareClient;$script:Networks[0].Category=$taskState;Invoke-PrepareClient $script:Request
    Check ($script:Result.ErrorCode -eq 'CLIENT_PRIVATE_LAN_REQUIRED' -and $script:Changes -eq 0 -and $script:Init -eq 0) ($taskState+': no preparation or journal creation outside a physical private LAN')
}
foreach($taskStatus in @('Managed','Unknown','Policy')) {
    Reset-Case PrepareClient
    switch($taskStatus){'Managed'{$script:Managed=$true};'Unknown'{$script:Unknown=$true};'Policy'{$script:PolicyBlocks=@('RequireSecuritySignature')}}
    Invoke-PrepareClient $script:Request
    Check (-not $script:Result.Success -and $script:Changes -eq 0 -and $script:Writes -eq 0 -and $script:Init -eq 0) ($taskStatus+': no administrative policy bypass')
    Check (@($script:Checks | Where-Object {$_.Fixable}).Count -eq 0) ($taskStatus+': no unsafe automatic-fix suggestion')
}
Reset-Case PrepareClient;$script:Request.AllowGuestSettings=$false
Throws {Invoke-PrepareClient $script:Request} 'Client preparation requires explicit global guest-setting consent'
Check ($script:Changes -eq 0 -and $script:Auth -eq 0 -and $script:Decrypt -eq 0) 'Declining preparation keeps configuration and credentials untouched'
Reset-Case PrepareClient;$script:Request.ProtectedPassword='dpapi-unrelated-value'
Throws {Invoke-PrepareClient $script:Request} 'Targetless guest preparation refuses an unrelated protected password in the backend'
Check ($script:Decrypt -eq 0 -and $script:Changes -eq 0 -and $script:Auth -eq 0) 'Preparation password rejection happens before decryption, settings and authentication'
Reset-Case PrepareClient;$script:Request.Mode='Password'
Throws {Invoke-PrepareClient $script:Request} 'Password mode cannot silently enter guest compatibility preparation'
Reset-Case PrepareClient;Invoke-PrepareClient $script:Request
Check ($script:Result.Success -and $script:Changes -eq 3 -and $script:Config.EnableInsecureGuestLogons -and -not $script:Config.RequireSecuritySignature -and -not $script:Config.RequireEncryption) 'Explicit preparation applies only the three observed blocked SMB client values'
Check ($script:Journal.Action -eq 'RepairClient' -and $script:Journal.Status -eq 'Committed' -and $script:Journal.Changes.Count -eq 3) 'Preparation uses the existing owned protected-journal contract for offline undo'
Check ($script:SavedJournals[0].Status -eq 'Prepared' -and @($script:SavedJournals[0].Changes | Where-Object {$_.Status -eq 'Prepared'}).Count -eq 3) 'Original values are saved before the first effective setting changes'
Check ($script:Result.ClientRepairAvailable -and $script:Result.Message -match 'noch ungeprüft' -and -not $script:Result.ConnectionVerified -and -not $script:Result.NativeConnectionVerified) 'Configuration success never claims the other computer or a selected folder is accessible'
Check ($script:Auth -eq 0 -and $script:Dns -eq 0 -and $script:Port -eq 0 -and $script:Decrypt -eq 0) 'Preparation does not send or decrypt any target credentials'
Check (-not $script:Result.AnonymousShareListDenied) 'Client preparation never retains a previous anonymous list diagnosis'
Reset-Case PrepareClient;$script:Config.EnableInsecureGuestLogons=$true;$script:Config.RequireSecuritySignature=$false;$script:Config.RequireEncryption=$false
Invoke-PrepareClient $script:Request
Check ($script:Result.Success -and $script:Changes -eq 0 -and $script:Writes -eq 0 -and $script:Init -eq 0) 'Already-ready client needs no security, journal or administrator mutation'
Reset-Case PrepareClient;$script:Request.DryRun=$true;Invoke-PrepareClient $script:Request
Check ($script:Result.Success -and $script:Changes -eq 0 -and $script:Writes -eq 0 -and $script:Auth -eq 0) 'Dry run reports concrete setting changes without applying them'
Reset-Case PrepareClient;$script:ChangeFailure='RequireSecuritySignature'
Throws {Invoke-PrepareClient $script:Request} 'Supported-setting failure propagates its original preparation error'
Check (-not $script:Config.EnableInsecureGuestLogons -and $script:Config.RequireSecuritySignature -and $script:Config.RequireEncryption -and $script:Journal.Status -eq 'Restored') 'Partial setting failure restores all changes of this attempt'
Reset-Case PrepareClient;$script:VerificationFailure=$true
Throws {Invoke-PrepareClient $script:Request} 'Final effective configuration must be verified before committing preparation'
Check (-not $script:Config.EnableInsecureGuestLogons -and $script:Config.RequireSecuritySignature -and $script:Config.RequireEncryption) 'Failed final configuration verification rolls the own preparation back'
Reset-Case PrepareClient;$script:Config.EnableInsecureGuestLogons=$true
$script:Journal=[pscustomobject]@{App=$script:AppMark;Version=1;Action='RepairClient';Status='Committed';Changes=@([pscustomobject]@{Name='EnableInsecureGuestLogons';Before=$false;Expected=$true;Status='Applied'})}
Invoke-PrepareClient $script:Request
Check ($script:Journal.Changes.Count -eq 3 -and $script:Journal.Changes[0].Before -eq $false -and $script:Journal.Changes[0].Status -eq 'Applied') 'New preparation preserves earlier own undo entries rather than replacing their before values'
Reset-Case PrepareClient
$script:Journal=[pscustomobject]@{App=$script:AppMark;Version=1;Action='RepairClient';Status='Committed';Changes=@([pscustomobject]@{Name='EnableInsecureGuestLogons';Before=$false;Expected=$true;Status='Applied'})}
Throws {Invoke-PrepareClient $script:Request} 'A changed earlier owned setting blocks merging a new preparation'
Check ($script:Changes -eq 0 -and $script:Writes -eq 0) 'Foreign modifications of earlier settings are preserved'
Reset-Case PrepareClient;$script:Config.PSObject.Properties.Remove('RequireEncryption')
Invoke-PrepareClient $script:Request
Check ($script:Result.Success -and $script:Changes -eq 2) 'Older Windows without RequireEncryption changes only the available known values'
Reset-Case PrepareClient;$script:Config.RequireSecuritySignature='False';Invoke-PrepareClient $script:Request
Check (-not $script:Result.Success -and $script:Changes -eq 0 -and $script:Result.ErrorCode -eq 'CLIENT_POLICY_STATE_UNKNOWN') 'Non-boolean configuration cannot be guessed or changed'
Check (@($script:Checks | Where-Object {$_.Fixable}).Count -eq 0) 'A later unknown configuration property prevents every earlier repair suggestion'
foreach($taskSwitch in @(2,3,4)) {
    Reset-Case PrepareClient;$script:ProfileSwitchRead=$taskSwitch
    Throws {Invoke-PrepareClient $script:Request} ('Private profile changes at stage '+$taskSwitch+' abort local preparation')
    Check (-not $script:Config.EnableInsecureGuestLogons -and $script:Config.RequireSecuritySignature -and $script:Config.RequireEncryption -and $script:Auth -eq 0) 'Profile-change failure rolls back own changes and never performs remote authentication'
}
Reset-Case PrepareClient;$script:SwitchDuringVerify=$true
Throws {Invoke-PrepareClient $script:Request} 'A profile change during final effective-settings read prevents committing preparation'
Check (-not $script:Config.EnableInsecureGuestLogons -and $script:Config.RequireSecuritySignature -and $script:Config.RequireEncryption -and $script:Journal.Status -eq 'Restored') 'Last-stage profile switch rolls back the own client configuration'
foreach($taskAction in @('InspectClient','PrepareClient','EnumerateComputer')) {
    Reset-Case $taskAction;$script:Service.State='Stopped'
    switch($taskAction){'InspectClient'{Invoke-InspectClient $script:Request};'PrepareClient'{Invoke-PrepareClient $script:Request};'EnumerateComputer'{Invoke-EnumerateComputer $script:Request}}
    Check ($script:Result.ErrorCode -eq 'SERVICE_WORKSTATION_NOT_RUNNING' -and $script:Auth -eq 0 -and $script:Dns -eq 0 -and $script:Changes -eq 0) ($taskAction+': stopped local workstation service is handled before any remote or setting action')
    Check (-not $script:Result.AnonymousShareListDenied) ($taskAction+': a stopped receiver service cannot retain an informational anonymous-list result')
}
Reset-Case EnumerateComputer;$script:Request.RemoteHost='TEST-NOTEBOOK';Invoke-EnumerateComputer $script:Request
Check ($script:Result.Success -and $script:Result.RemoteComputerEnumerationVerified -and $script:Result.RemoteShares.Count -eq 1) 'Computer-only request returns a complete normal-share list without requiring a share or guest account'
Check (-not $script:Result.NativeConnectionVerified -and -not $script:Result.ConnectionVerified -and $script:Result.RemoteShareName -eq '' -and $script:Result.SharePath -eq '') 'A complete computer list remains separate from real selected data-share access'
Check ($script:Result.RemoteName -ceq 'TEST-NOTEBOOK' -and $script:Result.RemoteComputerName -ceq 'TEST-NOTEBOOK' -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedSharePath -ceq '') 'A validated native computer identity qualifies public accounts without confirming named folder access'
Check ($script:Auth -eq 1 -and $script:Decrypt -eq 0 -and $script:Changes -eq 0 -and $script:Writes -eq 0) 'Guest computer enumeration authenticates once and never changes policies'
Check ($script:Result.RemoteShares[0].SuggestedUserName -eq '' -and -not $script:Result.RemoteShares[0].MetadataVerified) 'Legacy share remark never guesses a guest account'
Check (-not $script:Result.AnonymousShareListDenied) 'A newly confirmed list clears the prior optional denial flag'
foreach($taskCode in @(1272,-1067646973,-1067646972,5,53,67,1219,1326)) {
    Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:NativeProbe.Success=$false;$script:NativeProbe.ErrorCode=$taskCode;$script:NativeProbe.ErrorMessage='isolated Windows error';Invoke-EnumerateComputer $script:Request
    Check ($script:Result.ErrorCode -eq (Format-ClientNativeCode $taskCode) -and -not $script:Result.RemoteComputerEnumerationVerified -and $script:Result.RemoteShares.Count -eq 0) ('Native computer enumeration preserves exact Windows code '+$taskCode)
    Check ($script:Changes -eq 0 -and $script:Writes -eq 0) ('Native failure '+$taskCode+' does not silently relax security settings')
    Check ($script:Result.AnonymousShareListDenied -eq ($taskCode -eq 5)) ('Only exact anonymous NetShareEnum access-denied code is informational; code '+$taskCode)
}

# An anonymous server list is optional. Its exact access-denied result must
# never be promoted to a successful list, selected folder or named root.
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21'
$script:NativeProbe.Success=$false;$script:NativeProbe.ErrorCode=5;$script:NativeProbe.ErrorMessage='isolated access denied'
Invoke-EnumerateComputer $script:Request
$taskListCheck=@($script:Checks | Where-Object {$_.Name -ceq 'Windows-Freigabenliste des Computers'})
Check ($script:Result.AnonymousShareListDenied -and -not $script:Result.Success -and $script:Result.ErrorCode -ceq 'Win32: 5' -and $script:Result.ErrorType -ceq 'System.ComponentModel.Win32Exception') 'Optional anonymous list denial keeps the exact original failure code and exception type'
Check ($taskListCheck.Count -eq 1 -and $taskListCheck[0].State -ceq 'info' -and $taskListCheck[0].Code -ceq 'Win32: 5' -and -not $taskListCheck[0].Fixable) 'The narrow anonymous-list result is informational and does not offer a Windows-security relaxation'
Check ($taskListCheck[0].Detail.Contains('isolated access denied') -and $taskListCheck[0].Detail.Contains('NetShareEnum') -and $taskListCheck[0].NextStep -match 'Netzwerk-Konto' -and $taskListCheck[0].NextStep -match 'Freigabenamen direkt') 'Friendly guidance preserves the native failure and offers explicit account retry or direct known-share test'
Check (-not $script:Result.ConnectionVerified -and -not $script:Result.NativeConnectionVerified -and -not $script:Result.NamedConnectionVerified -and -not $script:Result.RemoteComputerEnumerationVerified -and $script:Result.RemoteShares.Count -eq 0 -and $script:Result.NamedSharePath -ceq '' -and $script:Result.RemoteName -ceq '') 'An informational anonymous list denial never confirms any remote list, folder or computer-name proof'
Check ($script:Auth -eq 1 -and $script:Changes -eq 0 -and $script:Writes -eq 0 -and $script:Decrypt -eq 0) 'The informational result does not retry guessed accounts or mutate Windows'
foreach($taskNegative in @('IPCAuth','NamedGuest','Password','WrongStageCase','Timeout','Managed')) {
    Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21'
    $script:NativeProbe.Success=$false;$script:NativeProbe.ErrorCode=5;$script:NativeProbe.ErrorMessage='isolated failure'
    switch($taskNegative) {
        'IPCAuth' {$script:NativeProbe.Stage='WNetAddConnection2-IPC'}
        'NamedGuest' {$script:Request.RemoteUserName='TEST-NOTEBOOK\Gast'}
        'Password' {$script:Request.Mode='Password';$script:Request.RemoteUserName='TEST-NOTEBOOK\User';$script:Request.ProtectedPassword='dpapi-value'}
        'WrongStageCase' {$script:NativeProbe.Stage='netshareenum'}
        'Timeout' {$script:NativeProbe.TimedOut=$true}
        'Managed' {$script:NativeProbe.ManagedErrorCode='APP: ISOLATED_LIST_FAILURE';$script:NativeProbe.ManagedErrorType='System.InvalidOperationException'}
    }
    Invoke-EnumerateComputer $script:Request
    $taskListCheck=@($script:Checks | Where-Object {$_.Name -ceq 'Windows-Freigabenliste des Computers'})
    Check (-not $script:Result.AnonymousShareListDenied -and -not $script:Result.Success -and $taskListCheck.Count -eq 1 -and $taskListCheck[0].State -ceq 'error') ($taskNegative+': access-denied remains an ordinary error outside the exact anonymous native-list scope')
    $taskExpectedCode='Win32: 5';$taskExpectedType='System.ComponentModel.Win32Exception'
    if($taskNegative -eq 'Timeout'){$taskExpectedCode='APP: CLIENT_COMPUTER_ENUMERATION_TIMEOUT';$taskExpectedType='System.TimeoutException'}
    if($taskNegative -eq 'Managed'){$taskExpectedCode='APP: ISOLATED_LIST_FAILURE';$taskExpectedType='System.InvalidOperationException'}
    Check ($script:Result.ErrorCode -ceq $taskExpectedCode -and $script:Result.ErrorType -ceq $taskExpectedType -and -not $script:Result.RemoteComputerEnumerationVerified -and -not $script:Result.NativeConnectionVerified -and $script:Changes -eq 0 -and $script:Writes -eq 0) ($taskNegative+': original error, unconfirmed proof and unchanged Windows settings are preserved')
}
# Old request actions can follow an optional list attempt in an in-process
# harness. A new operation must not inherit the special result flag.
$taskSavedExistingSessions=${function:Add-ClientExistingSessions}
function Add-ClientExistingSessions($Target){}
foreach($taskLegacy in @('InspectRemote','ConnectRemote','RepairClient','RestoreClient')) {
    Reset-Case $taskLegacy;$script:Request.RemoteHost='192.168.178.21';$script:Request.RemoteShareName='Desktop';$script:Request.RemoteUserName='TEST-NOTEBOOK\User';$script:Request.Mode='Password';$script:Request.DryRun=$true
    switch($taskLegacy) {
        'InspectRemote' {Invoke-InspectRemote $script:Request}
        'ConnectRemote' {Invoke-ConnectRemote $script:Request}
        'RepairClient' {Invoke-RepairClient $script:Request}
        'RestoreClient' {Invoke-RestoreClient $script:Request}
    }
    Check (-not $script:Result.AnonymousShareListDenied -and $script:Auth -eq 0 -and $script:Changes -eq 0) ($taskLegacy+': a separate request clears the optional denial flag without extra authentication or changes')
}
Set-Item -LiteralPath Function:\Add-ClientExistingSessions -Value $taskSavedExistingSessions
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:NativeProbe.Success=$false;$script:NativeProbe.TimedOut=$true;Invoke-EnumerateComputer $script:Request
Check ($script:Result.ErrorCode -eq 'APP: CLIENT_COMPUTER_ENUMERATION_TIMEOUT' -and -not $script:Result.RemoteComputerEnumerationVerified) 'Our native enumeration deadline is not reported as a fabricated Windows code'
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:PortAvailable=$false;Invoke-EnumerateComputer $script:Request
Check ($script:Result.ErrorCode -eq 'REMOTE_PORT_UNREACHABLE' -and $script:Auth -eq 0) 'Unreachable SMB port has its own failure and no credential attempt'
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:Request.DryRun=$true;Invoke-EnumerateComputer $script:Request
Check ($script:Result.Success -and -not $script:Result.RemoteComputerEnumerationVerified -and $script:Auth -eq 0) 'Enumeration dry run cannot claim a full list or issue a logon'
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:ProfileSwitchRead=2;Invoke-EnumerateComputer $script:Request
Check ($script:Result.ErrorCode -eq 'CLIENT_ENUMERATION_NETWORK_CHANGED' -and $script:Auth -eq 0 -and -not $script:Result.RemoteComputerEnumerationVerified) 'A changed private network stops computer enumeration before the isolated login'
foreach($taskBadHost in @('8.8.8.8','192.168.178.24','192.168.178.0','192.168.178.255','192.168.178.021','192.168.178.21\Desktop','192.168.178.21:445')) {
    Reset-Case EnumerateComputer;$script:Request.RemoteHost=$taskBadHost
    Throws {Invoke-EnumerateComputer $script:Request} ('Unsafe computer target is rejected: '+$taskBadHost)
    Check ($script:Auth -eq 0 -and $script:Changes -eq 0) 'Target rejection occurs before authentication or configuration changes'
}
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:Request.Mode='Password'
Throws {Invoke-EnumerateComputer $script:Request} 'Password computer enumeration still requires an explicit account'
Reset-Case EnumerateComputer;$script:Request.RemoteHost='192.168.178.21';$script:NativeProbe.ServerName='';Invoke-EnumerateComputer $script:Request
Check ($script:Result.RemoteComputerEnumerationVerified -and -not $script:Result.RemoteShares[0].MetadataVerified) 'Identity failure does not invent a canonical name or prevent a completed IP enumeration'
Check ($script:Result.RemoteName -ceq '' -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedSharePath -ceq '' -and -not $script:Result.NativeConnectionVerified) 'Missing native identity leaves the account-qualification name and every folder proof empty'
foreach($taskInvalidIdentity in @('192.168.178.21','BAD/NAME','NAME WITH SPACE','NAME-WITH-MORE-THAN-FIFTEEN','-NOTEBOOK','NOTEBOOK-')) {
    Reset-Case EnumerateComputer;$script:Request.RemoteHost='TEST-NOTEBOOK';$script:NativeProbe.ServerName=$taskInvalidIdentity
    Invoke-EnumerateComputer $script:Request
    Check ($script:Result.RemoteComputerEnumerationVerified -and $script:Result.RemoteName -ceq '' -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedSharePath -ceq '' -and -not $script:Result.NativeConnectionVerified -and -not $script:Result.ConnectionVerified) ('Malformed/IP native identity cannot qualify public accounts or prove a folder: '+$taskInvalidIdentity)
}

# Compile the production native routine with instrumented fake Win32 entry
# points. Its page handling, isolated IPC lifecycle and explicit credential
# arguments are exercised; every DllImport and token API is replaced.
$taskNative=[regex]::Match($taskHelper,"Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@",[Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value
$taskImports=[regex]::Matches($taskNative,'\[DllImport\([^\]]+\)\]\s*static extern [^;]+;')
foreach($taskImport in $taskImports){
    $taskSignature=($taskImport.Value -replace '\[DllImport\([^\]]+\)\]\s*','')
    $taskMethod=[regex]::Match($taskSignature,'static extern \S+ (\w+)\(').Groups[1].Value
    $taskImplementation=switch($taskMethod){
        'LogonUser' {'static bool LogonUser(string user,string domain,string password,int type,int provider,out IntPtr token) {FixtureTokenCalls++;FixtureTokenUser=user;FixtureTokenType=type;FixtureTokenProvider=provider;token=new IntPtr(9);return true;}'}
        'CloseHandle' {'static bool CloseHandle(IntPtr token) {FixtureClosed++;return true;}'}
        'WNetAddConnection2' {'static int WNetAddConnection2(ref NETRESOURCE resource,string password,string user,uint flags) {FixtureWNetCalls++;FixturePath=resource.lpRemoteName;FixtureUser=user;FixturePassword=password;FixtureFlags=flags;if(!FixtureIsolated)throw new Exception("not isolated");return FixtureAuthCode;}'}
        'WNetCancelConnection2' {'static int WNetCancelConnection2(string path,uint flags,bool force) {FixtureCleanup++;FixtureCleanupPath=path;FixtureCleanupForce=force;if(!FixtureIsolated)throw new Exception("cleanup outside isolated token");return 0;}'}
        'NetGetJoinInformation' {'static int NetGetJoinInformation(string server,out IntPtr name,out int status) {name=IntPtr.Zero;status=2;return 0;}'}
        'NetWkstaGetInfo' {'static int NetWkstaGetInfo(string server,uint level,out IntPtr buffer) {FixtureIdentityServer=server;buffer=IntPtr.Zero;if(FixtureIdentityCode!=0)return FixtureIdentityCode;buffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WKSTA_INFO_100)));Marshal.StructureToPtr(new WKSTA_INFO_100 {name="TEST-NOTEBOOK"},buffer,false);FixtureBuffers[buffer]=1;return 0;}'}
        'NetShareEnum' {'static int NetShareEnum(string server,uint level,out IntPtr buffer,uint length,out uint read,out uint total,ref uint resume) {FixtureEnumCalls++;FixtureEnumServer=server;read=0;total=2;buffer=IntPtr.Zero;if(FixtureEnumCode!=0)return FixtureEnumCode;if(FixtureStalled)return 234;read=1;buffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SHARE_INFO_1)));Marshal.StructureToPtr(new SHARE_INFO_1 {name=resume==0?"Desktop":"Data",type=0,remark="public-preset"},buffer,false);FixtureBuffers[buffer]=2;if(resume==0){resume=1;return 234;}resume=0;return 0;}'}
        'NetApiBufferFree' {'static int NetApiBufferFree(IntPtr buffer) {int kind=FixtureBuffers[buffer];Marshal.DestroyStructure(buffer,kind==1?typeof(WKSTA_INFO_100):typeof(SHARE_INFO_1));Marshal.FreeHGlobal(buffer);FixtureBuffers.Remove(buffer);FixtureFreed++;return 0;}'}
        'FindFirstFile' {'static IntPtr FindFirstFile(string path,out FIND_DATA data) {data=new FIND_DATA();throw new Exception("data shares must not be opened by enumeration");}'}
        'GetFileAttributes' {'static uint GetFileAttributes(string path) {throw new Exception("data share attributes must not be read by enumeration");}'}
        'FindClose' {'static bool FindClose(IntPtr handle) {throw new Exception("data shares must not be opened");}'}
        default {throw ('Uninstrumented native API: '+$taskMethod)}
    }
    $taskNative=$taskNative.Replace($taskImport.Value,$taskImplementation)
}
$taskFixture=@'
    public static int FixtureTokenCalls,FixtureTokenType,FixtureTokenProvider,FixtureClosed,FixtureWNetCalls,FixtureAuthCode,FixtureEnumCode,FixtureEnumCalls,FixtureIdentityCode,FixtureCleanup,FixtureFreed;
    public static uint FixtureFlags;
    public static string FixtureTokenUser,FixturePath,FixtureUser,FixturePassword,FixtureCleanupPath,FixtureEnumServer,FixtureIdentityServer;
    public static bool FixtureIsolated,FixtureCleanupForce,FixtureStalled;
    static Dictionary<IntPtr,int> FixtureBuffers=new Dictionary<IntPtr,int>();
    sealed class FixtureImpersonation:IDisposable {public FixtureImpersonation(){FixtureIsolated=true;}public void Dispose(){FixtureIsolated=false;}}
    public static void FixtureReset(){FixtureTokenCalls=FixtureTokenType=FixtureTokenProvider=FixtureClosed=FixtureWNetCalls=FixtureAuthCode=FixtureEnumCode=FixtureEnumCalls=FixtureIdentityCode=FixtureCleanup=FixtureFreed=0;FixtureIsolated=FixtureCleanupForce=FixtureStalled=false;FixturePath=FixtureUser=FixturePassword=FixtureCleanupPath=FixtureEnumServer=FixtureIdentityServer="";FixtureBuffers.Clear();}
'@
$taskNative=$taskNative.Replace('public static class NativeClientAccess {','public static class NativeClientAccess {'+[Environment]::NewLine+$taskFixture)
$taskNative=$taskNative.Replace('using(WindowsIdentity.Impersonate(token))','using(new FixtureImpersonation())')
Check (-not $taskNative.Contains('[DllImport(') -and -not $taskNative.Contains('WindowsIdentity.Impersonate(token)')) 'Every native and token boundary of the enumeration fixture is isolated'
Add-Type -TypeDefinition $taskNative
Reset-Case EnumerateComputer
[EinfachNetzwerk.NativeClientAccess]::FixtureReset()
$taskNativeResult=[EinfachNetzwerk.NativeClientAccess]::EnumerateComputer('192.168.178.21','','')
Check ($taskNativeResult.Success -and -not $taskNativeResult.DirectoryListed -and $taskNativeResult.Shares.Length -eq 2 -and $taskNativeResult.ShareNames.Length -eq 2) 'Production native computer list consumes all ERROR_MORE_DATA pages and retains remarks'
Check ([EinfachNetzwerk.NativeClientAccess]::FixtureTokenType -eq 9 -and [EinfachNetzwerk.NativeClientAccess]::FixtureTokenProvider -eq 3 -and [EinfachNetzwerk.NativeClientAccess]::FixtureClosed -eq 1) 'Native computer list uses a fresh network-only logon token and closes it'
Check ([EinfachNetzwerk.NativeClientAccess]::FixtureUser -ceq '' -and [EinfachNetzwerk.NativeClientAccess]::FixturePassword -ceq '' -and [EinfachNetzwerk.NativeClientAccess]::FixtureFlags -eq 4) 'Anonymous attempt sends explicit empty strings with a temporary nonpersistent IPC connection'
Check ([EinfachNetzwerk.NativeClientAccess]::FixturePath -ceq '\\192.168.178.21\IPC$' -and [EinfachNetzwerk.NativeClientAccess]::FixtureEnumServer -ceq '\\192.168.178.21' -and [EinfachNetzwerk.NativeClientAccess]::FixtureIdentityServer -ceq '\\192.168.178.21') 'Native IPC authentication, enumeration and identity stay on the exact pinned IP'
Check ([EinfachNetzwerk.NativeClientAccess]::FixtureCleanup -eq 1 -and [EinfachNetzwerk.NativeClientAccess]::FixtureCleanupPath -ceq [EinfachNetzwerk.NativeClientAccess]::FixturePath -and -not [EinfachNetzwerk.NativeClientAccess]::FixtureCleanupForce -and [EinfachNetzwerk.NativeClientAccess]::FixtureFreed -eq 3) 'Only own isolated IPC is released without force and every native page/identity buffer is freed'
foreach($taskError in @(1272,1219,5)) {
    [EinfachNetzwerk.NativeClientAccess]::FixtureReset();[EinfachNetzwerk.NativeClientAccess]::FixtureAuthCode=$taskError
    $taskNativeResult=[EinfachNetzwerk.NativeClientAccess]::EnumerateComputer('192.168.178.21','TEST-NOTEBOOK\Gast','')
    Check (-not $taskNativeResult.Success -and $taskNativeResult.ErrorCode -eq $taskError -and [EinfachNetzwerk.NativeClientAccess]::FixtureEnumCalls -eq 0) ('Native IPC failure '+$taskError+' stops before implicit default-credential enumeration')
    Check ($taskNativeResult.Stage -ceq 'WNetAddConnection2-IPC') ('Native IPC failure '+$taskError+' is distinguished from an optional list-stage denial')
    Check ([EinfachNetzwerk.NativeClientAccess]::FixtureCleanup -eq 0 -and [EinfachNetzwerk.NativeClientAccess]::FixtureClosed -eq 1) 'Failed IPC auth never disconnects a connection it did not open'
}
[EinfachNetzwerk.NativeClientAccess]::FixtureReset();[EinfachNetzwerk.NativeClientAccess]::FixtureEnumCode=5
$taskNativeResult=[EinfachNetzwerk.NativeClientAccess]::EnumerateComputer('192.168.178.21','','')
Check (-not $taskNativeResult.Success -and $taskNativeResult.Stage -ceq 'NetShareEnum' -and $taskNativeResult.ErrorCode -eq 5 -and $taskNativeResult.Shares.Length -eq 0) 'Actual native anonymous enumeration denial supplies the exact scoped list-stage evidence without a partial list'
Check ([EinfachNetzwerk.NativeClientAccess]::FixtureUser -ceq '' -and [EinfachNetzwerk.NativeClientAccess]::FixturePassword -ceq '' -and [EinfachNetzwerk.NativeClientAccess]::FixtureCleanup -eq 1 -and [EinfachNetzwerk.NativeClientAccess]::FixtureClosed -eq 1) 'Anonymous list denial retains explicit empty credentials and releases only its isolated IPC and token'
[EinfachNetzwerk.NativeClientAccess]::FixtureReset();[EinfachNetzwerk.NativeClientAccess]::FixtureEnumCode=5
$taskNativeResult=[EinfachNetzwerk.NativeClientAccess]::EnumerateComputer('192.168.178.21','TEST-NOTEBOOK\User','isolated-network-secret')
Check (-not $taskNativeResult.Success -and $taskNativeResult.ErrorCode -eq 5 -and [EinfachNetzwerk.NativeClientAccess]::FixtureUser -ceq 'TEST-NOTEBOOK\User' -and [EinfachNetzwerk.NativeClientAccess]::FixturePassword -ceq 'isolated-network-secret' -and [EinfachNetzwerk.NativeClientAccess]::FixtureCleanup -eq 1) 'Explicit password list uses only supplied credentials and cleans up after enum denial'
[EinfachNetzwerk.NativeClientAccess]::FixtureReset();[EinfachNetzwerk.NativeClientAccess]::FixtureStalled=$true
$taskNativeResult=[EinfachNetzwerk.NativeClientAccess]::EnumerateComputer('192.168.178.21','','')
Check (-not $taskNativeResult.Success -and $taskNativeResult.ErrorCode -eq 234 -and $taskNativeResult.Shares.Length -eq 0 -and [EinfachNetzwerk.NativeClientAccess]::FixtureCleanup -eq 1) 'Nonadvancing ERROR_MORE_DATA pages cannot be called a successful complete list'
[EinfachNetzwerk.NativeClientAccess]::FixtureReset();[EinfachNetzwerk.NativeClientAccess]::FixtureIdentityCode=5
$taskNativeResult=[EinfachNetzwerk.NativeClientAccess]::EnumerateComputer('192.168.178.21','','')
Check ($taskNativeResult.Success -and $taskNativeResult.ServerName -eq '' -and $taskNativeResult.Shares.Length -eq 2) 'Failed native identity preserves full IP share enumeration without inventing a name'
Check ($taskNativeResult.IdentityErrorCode -eq 5) 'Successful IP enumeration retains the original separate identity error for TXT diagnostics'
Set-Item -LiteralPath Function:\Test-ClientComputerNative -Value $taskRealComputerNative
Reset-Case EnumerateComputer;$script:Request.Mode='Password';$script:Request.ProtectedPassword='dpapi-value'
$taskTarget=[pscustomobject]@{Address='192.168.178.21';Mode='Password';Login='TEST-NOTEBOOK\User'}
[EinfachNetzwerk.NativeClientAccess]::FixtureReset();$null=Test-ClientComputerNative $script:Request $taskTarget
Check ($script:Decrypt -eq 1 -and $null -eq $script:Secret -and [EinfachNetzwerk.NativeClientAccess]::FixturePassword -ceq 'isolated-network-secret') 'Password mode decrypts only within the native request and releases its redaction secret afterward'
Reset-Case EnumerateComputer;$script:Request.ProtectedPassword='dpapi-value';$script:Secret='isolated-network-secret'
Check ((Hide-FailureSecrets 'raw isolated-network-secret dpapi-value') -eq 'raw [Passwort ausgeblendet] [verschlüsselte Daten ausgeblendet]') 'Existing TXT and response redaction hides both decrypted and protected password strings'
if(Test-Path -LiteralPath $AssemblyPath -PathType Leaf) {
    [void][Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))
    $taskMeta=Get-ClientShareSuggestion 'Desktop' '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast]' 'TEST-NOTEBOOK'
    Check ($taskMeta.MetadataVerified -and $taskMeta.SuggestedUserName -ceq 'TEST-NOTEBOOK\Gast' -and $taskMeta.AccessMode -ceq 'Guest') 'Public account suggestion is accepted only against the real native canonical name'
    $taskWrong=Get-ClientShareSuggestion 'Desktop' '[EinfachNetzwerk:1;mode=Guest;computer=OTHER-PC;user=Gast]' 'TEST-NOTEBOOK'
    Check (-not $taskWrong.MetadataVerified -and $taskWrong.SuggestedUserName -eq '') 'A different advertised computer cannot supply an account suggestion'
    $taskUnknown=Get-ClientShareSuggestion 'Desktop' '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast]' ''
    Check (-not $taskUnknown.MetadataVerified -and $taskUnknown.SuggestedUserName -eq '') 'Missing native identity never trusts reported account metadata'
}
foreach($taskAction in @('InspectClient','PrepareClient','EnumerateComputer')) {
    Check ($taskWorker -match ("'"+$taskAction+"' \{ Invoke-"+$taskAction)) ($taskAction+': dispatches before server providers')
    Reset-Case $taskAction;Initialize-WorkProgress $taskAction $false
    Check ('ledger' -notin $script:WorkPlan -and 'inspect-shares' -notin $script:WorkPlan -and 'selection' -notin $script:WorkPlan) ($taskAction+': counted progress excludes unused server and share-selection stages')
    Check ($script:WorkPlan[0] -eq 'request' -and $script:WorkPlan[-1] -eq 'client-confirmation' -and @($script:WorkPlan | Select-Object -Unique).Count -eq $script:WorkPlan.Count) ($taskAction+': finite work stages remain counted once with client completion reserved')
}
Check ($taskWorker -match "foreach \(\`$collection in @\('Checks', 'Networks', 'Shares', 'RemoteShares'\)\)") 'Remote metadata strings participate in the existing response password redaction'
Write-Output ('Client computer and preparation tests: '+$script:Passed+' passed; all Windows and network effects isolated.')
