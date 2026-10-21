param([string]$HelperPath=(Join-Path $PSScriptRoot '..\src\ClientAccessWorker.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -eq 'Core') {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -HelperPath $HelperPath
    exit $LASTEXITCODE
}
# All transport, account, policy, service and journal operations are doubles.
# This test never queries or modifies a real Windows service or SMB session.
$taskTokens=$null;$taskErrors=$null
$taskHelper=[IO.File]::ReadAllText([IO.Path]::GetFullPath($HelperPath),[Text.Encoding]::UTF8)
$taskAst=[Management.Automation.Language.Parser]::ParseInput($taskHelper,[ref]$taskTokens,[ref]$taskErrors)
if(@($taskErrors).Count -ne 0){throw ('Client service preflight syntax: '+(($taskErrors | ForEach-Object {$_.Message}) -join '; '))}
. ([scriptblock]::Create($taskHelper))
$taskWorker=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'),[Text.Encoding]::UTF8)
$taskWorkerAst=[Management.Automation.Language.Parser]::ParseInput($taskWorker,[ref]$taskTokens,[ref]$taskErrors)
foreach($taskName in @('Get-Value','Add-Check')){
    $taskFunction=$taskWorkerAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskName},$true)
    . ([scriptblock]::Create($taskFunction.Extent.Text))
}
$script:passed=0
function Check([bool]$value,[string]$message){if(-not $value){throw $message};$script:passed++;Write-Output ('PASS: '+$message)}
function Reset-Case([string]$action='InspectRemote',[string]$mode='Guest'){
    $script:Checks=New-Object 'System.Collections.Generic.List[object]'
    $script:Result=[ordered]@{Success=$false;Message='';ErrorCode='';ErrorType='';ErrorStackTrace='';ConnectionVerified=$true;NativeConnectionVerified=$true;NamedConnectionVerified=$true;NamedSharePath='\\stale\Desktop';RemoteName='STALE';ClientRepairAvailable=$true;ClientBackupPath='preserved-owned-journal'}
    $script:Request=[pscustomobject]@{Action=$action;Mode=$mode;AllowNameConnection=$true;DryRun=$false;ProtectedPassword='secret-not-decrypted';AllowGuestSettings=$true}
    $script:Snapshot=[pscustomobject]@{Name='LanmanWorkstation';Exists=$true;State='Stopped';StartMode='Auto';Win32ExitCode=[uint32]0;ServiceSpecificExitCode=[uint32]0}
    $script:QueryException=$null;$script:NullSnapshot=$false
    $script:HealthReads=0;$script:TargetReads=0;$script:PortReads=0;$script:PolicyReads=0;$script:SessionReads=0;$script:AuthCalls=0;$script:NameAuthCalls=0;$script:RestoreCalls=0;$script:Writes=0;$script:Phases=New-Object 'System.Collections.Generic.List[string]'
    $script:Steps=New-Object 'System.Collections.Generic.HashSet[string]'
}
function Get-ServiceNativeSnapshot([string]$Name){$script:HealthReads++;if($Name -ne 'LanmanWorkstation'){throw 'Preflight must read only local Workstation'};if($null -ne $script:QueryException){throw $script:QueryException};if($script:NullSnapshot){return $null};return $script:Snapshot}
function Publish-ClientRestoreState {}
function Write-Phase([string]$Text){$script:Phases.Add($Text)}
function Complete-WorkStep([string]$Name){[void]$script:Steps.Add($Name)}
function Resolve-ClientTarget($Request){$script:TargetReads++;return [pscustomobject]@{Address='192.168.178.21';Mode=$Request.Mode;Share='Desktop';Login='TEST-NOTEBOOK\Gast'}}
function Test-ClientPort([string]$Address){$script:PortReads++;return $true}
function Get-ClientPolicyState{$script:PolicyReads++;return [pscustomobject]@{Managed=$false;Unknown=$false;Blocks=@();Configuration=[pscustomobject]@{EnableInsecureGuestLogons=$false;RequireSecuritySignature=$true}}}
function Show-ClientPolicyChecks($State,[string]$Mode){Complete-WorkStep remote-policy}
function Add-ClientExistingSessions($Target){$script:SessionReads++}
function Test-ClientNativeAccess($Request,$Target,[bool]$Connect=$false){$script:AuthCalls++;return [pscustomobject]@{Success=$true;DirectoryListed=$true;ErrorCode=0;ErrorMessage='';Stage='DirectoryListed';TimedOut=$false}}
function Publish-ClientProbeResult($Probe,$Target){$script:Result.Success=$Probe.Success;$script:Result.ConnectionVerified=$Probe.Success;$script:Result.NativeConnectionVerified=$Probe.Success;$script:Result.SharePath='\\192.168.178.21\Desktop'}
function Invoke-ClientNamedAccess($Request,$Target){$script:NameAuthCalls++}
function Set-ClientOwnedValue{$script:Writes++;throw 'Unexpected security mutation'}
function Write-JsonAtomic{$script:Writes++;throw 'Unexpected journal mutation'}
function Unprotect-Password{$script:Writes++;throw 'Unexpected secret decryption'}
function Is-Administrator{return $true}
function Read-ClientJournal{return [pscustomobject]@{Status='Committed';Changes=@([pscustomobject]@{Name='RequireSecuritySignature';Before=$true;Expected=$false;Status='Applied'})}}
function Restore-ClientJournal($Journal){$script:RestoreCalls++;return $true}
function Run-Case([string]$action){switch($action){'InspectRemote'{Invoke-InspectRemote $script:Request};'ConnectRemote'{Invoke-ConnectRemote $script:Request};'RepairClient'{Invoke-RepairClient $script:Request};'RestoreClient'{Invoke-RestoreClient $script:Request}}}

foreach($taskAction in @('InspectRemote','ConnectRemote','RepairClient')){
    foreach($taskMode in @('Guest','Password')){
        Reset-Case $taskAction $taskMode;Run-Case $taskAction
        Check ($script:HealthReads -eq 1 -and $script:TargetReads -eq 0 -and $script:PortReads -eq 0 -and $script:PolicyReads -eq 0 -and $script:SessionReads -eq 0) ($taskAction+' '+$taskMode+': stopped local service blocks target, transport and policy queries')
        Check ($script:AuthCalls -eq 0 -and $script:NameAuthCalls -eq 0 -and $script:Writes -eq 0) ($taskAction+' '+$taskMode+': no logon, secret decryption or security mutations')
        Check (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'SERVICE_WORKSTATION_NOT_RUNNING') ($taskAction+' '+$taskMode+': precise receiver-service error is returned')
        Check (-not $script:Result.ConnectionVerified -and -not $script:Result.NativeConnectionVerified -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedSharePath -eq '' -and $script:Result.RemoteName -eq '') ($taskAction+' '+$taskMode+': stale IP and named proofs are invalidated')
        Check (@($script:Checks | Where-Object {$_.Code -eq 'SERVICE_WORKSTATION_NOT_RUNNING' -and $_.Fixable}).Count -eq 1) ($taskAction+' '+$taskMode+': local service repair is proposed')
        Check (@($script:Checks | Where-Object {$_.Code -eq 'Win32: 0; Service: 0'}).Count -eq 1 -and $script:Result.Message -match [regex]::Escape($env:COMPUTERNAME)) ($taskAction+' '+$taskMode+': actual zero SCM exit codes and receiving PC are preserved')
        Check ($script:Result.ClientRepairAvailable -and $script:Result.ClientBackupPath -eq 'preserved-owned-journal') ($taskAction+' '+$taskMode+': existing offline policy undo remains available')
        Check ($script:Steps.Contains('remote-validation') -and $script:Steps.Contains('remote-network') -and $script:Steps.Contains('remote-policy') -and $script:Steps.Contains('remote-port') -and $script:Steps.Contains('remote-probe') -and $script:Steps.Contains('client-name-enumeration') -and $script:Steps.Contains('client-verification')) ($taskAction+' '+$taskMode+': remaining work stages are completed as inapplicable')
    }
}
foreach($taskCase in @(@($false,'Missing','Unknown',1060,0),@($true,'Stopped','Disabled',1058,17),@($true,'StartPending','Auto',1068,8),@($true,'Running','Disabled',0,0),@($true,'Running','Unknown',13,0))){
    Reset-Case ConnectRemote
    $script:Snapshot.Exists=[bool]$taskCase[0];$script:Snapshot.State=[string]$taskCase[1];$script:Snapshot.StartMode=[string]$taskCase[2];$script:Snapshot.Win32ExitCode=[uint32]$taskCase[3];$script:Snapshot.ServiceSpecificExitCode=[uint32]$taskCase[4]
    Invoke-ConnectRemote $script:Request
    Check (-not $script:Result.Success -and $script:AuthCalls -eq 0 -and $script:Result.ErrorCode -eq 'SERVICE_WORKSTATION_NOT_RUNNING') 'Missing, disabled, pending and invalid service configurations cannot certify remote access'
    Check (@($script:Checks | Where-Object {$_.Code -eq ('Win32: '+$taskCase[3]+'; Service: '+$taskCase[4])}).Count -eq 1) 'Original SCM Win32 and service-specific numbers are retained without guessing'
}
foreach($taskAction in @('InspectRemote','ConnectRemote','RepairClient')){
    foreach($taskStartMode in @('Auto','Manual')){
        Reset-Case $taskAction;$script:Snapshot.State='Running';$script:Snapshot.StartMode=$taskStartMode;Run-Case $taskAction
        Check ($script:HealthReads -eq 1 -and $script:TargetReads -eq 1 -and $script:AuthCalls -eq 1 -and $script:Writes -eq 0) ($taskAction+' '+$taskStartMode+': ready local service retains the normal authenticated workflow')
        Check ($script:Result.Success -and $script:Result.NativeConnectionVerified -and $script:Result.ErrorCode -eq '') ($taskAction+' '+$taskStartMode+': healthy preflight does not invent a failure')
        Check (@($script:Checks | Where-Object {$_.Code -eq 'SERVICE_WORKSTATION_READY' -and $_.State -eq 'ok' -and $_.Detail -match ('Running; Start: '+$taskStartMode+'; Windows-Code: 0; Dienst-Code: 0')}).Count -eq 1) ($taskAction+' '+$taskStartMode+': real ready service evidence and original SCM exit values are visible')
    }
}
Reset-Case RepairClient;$script:QueryException=New-Object ComponentModel.Win32Exception(5,'isolated SCM access denied');Invoke-RepairClient $script:Request
Check ($script:Result.ErrorCode -eq 'SERVICE_WORKSTATION_QUERY_FAILED' -and $script:AuthCalls -eq 0 -and $script:Writes -eq 0) 'An unreadable local service fails closed before auth or policy changes'
Check (@($script:Checks | Where-Object {$_.Code -match 'Win32\[0\]: 5' -and -not $_.Fixable}).Count -eq 1) 'Native SCM query denial preserves the original Win32 code instead of claiming the service is stopped'
Check ($script:Result.ErrorType -match 'Win32Exception' -and $script:Result.ErrorStackTrace.Length -gt 0) 'Actual query exception type and script stack remain exportable'
Reset-Case ConnectRemote;$script:NullSnapshot=$true;Invoke-ConnectRemote $script:Request
Check ($script:Result.ErrorCode -eq 'SERVICE_WORKSTATION_QUERY_FAILED' -and $script:AuthCalls -eq 0) 'An absent SCM snapshot is an inspection failure, not a successful or stopped-service claim'
Reset-Case ConnectRemote;$script:Request.DryRun=$true;Invoke-ConnectRemote $script:Request
Check ($script:Result.ErrorCode -eq 'SERVICE_WORKSTATION_NOT_RUNNING' -and $script:Writes -eq 0 -and $script:AuthCalls -eq 0) 'Read-only preflight identifies a stopped service during dry run without attempting repair'
Reset-Case RestoreClient;Invoke-RestoreClient $script:Request
Check ($script:Result.Success -and $script:RestoreCalls -eq 1 -and $script:HealthReads -eq 0 -and $script:AuthCalls -eq 0 -and $script:PortReads -eq 0) 'Offline undo remains available when the local Workstation service is stopped'
Remove-Item -LiteralPath Function:\Get-ServiceNativeSnapshot
Reset-Case InspectRemote;Invoke-InspectRemote $script:Request
Check ($script:AuthCalls -eq 1 -and $script:HealthReads -eq 0 -and $script:Writes -eq 0) 'Older isolated fixtures without the optional native SCM helper remain isolated and functional'
Check (@($script:Checks | Where-Object {$_.Code -eq 'SERVICE_WORKSTATION_READY'}).Count -eq 0) 'An absent native SCM helper cannot publish simulated ready-service evidence'
Write-Output ('Client service preflight tests: '+$script:passed+' passed; no real service, SMB, security or journal changes.')
