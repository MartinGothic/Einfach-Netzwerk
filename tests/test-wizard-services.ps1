param([string]$WorkerPath=(Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Execute the actual setup service block and journal helpers with in-memory
# Windows doubles. This test never creates a share or changes real services.
$taskServiceSource=[IO.File]::ReadAllText([IO.Path]::GetFullPath($WorkerPath))
$taskServiceTokens=$null; $taskServiceErrors=$null
$taskServiceAst=[Management.Automation.Language.Parser]::ParseInput($taskServiceSource,[ref]$taskServiceTokens,[ref]$taskServiceErrors)
$script:taskServicePassed=0
function Require-Service([bool]$condition,[string]$message) { if(-not $condition){throw $message}; $script:taskServicePassed++ }
Require-Service (@($taskServiceErrors).Count -eq 0) 'The setup worker must parse under Windows PowerShell 5.'
foreach($taskServiceName in @('Get-Value','Get-SystemSnapshot','Undo-Transaction','Restore-Service','Verify-TransactionRestored','Restore-GlobalIfLast')) {
    $taskServiceFunction=$taskServiceAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskServiceName},$true)
    if($null -eq $taskServiceFunction){throw ('Missing production helper: '+$taskServiceName)}
    . ([scriptblock]::Create($taskServiceFunction.Extent.Text))
}
$taskServiceApply=$taskServiceAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Apply-Share'},$true)
$taskServiceBegin=$taskServiceApply.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Phase' -and $node.CommandElements.Count -eq 2 -and $node.CommandElements[1].Value -eq 'Ausgewähltes Heimnetz und Windows-Dienste einrichten …'},$true)
$taskServiceEnd=$taskServiceApply.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Complete-WorkStep' -and $node.CommandElements.Count -eq 2 -and $node.CommandElements[1].Value -eq 'apply-services'},$true)
Require-Service ($null -ne $taskServiceBegin -and $null -ne $taskServiceEnd -and $taskServiceEnd.Extent.EndOffset -gt $taskServiceBegin.Extent.StartOffset) 'The real setup service phase must be identifiable.'
$taskServiceBlock=[scriptblock]::Create($taskServiceSource.Substring($taskServiceBegin.Extent.StartOffset,$taskServiceEnd.Extent.EndOffset-$taskServiceBegin.Extent.StartOffset))
$taskServiceMergeAst=$taskServiceApply.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Body.Extent.Text.Contains('$script:Ledger.Global.Services')},$true)
Require-Service ($null -ne $taskServiceMergeAst) 'Older journals must preserve new Workstation ownership snapshots.'
$taskServiceMerge=[scriptblock]::Create($taskServiceMergeAst.Extent.Text)

$script:taskServiceNames=@('LanmanServer','LanmanWorkstation','FDResPub','fdPHost')
$script:taskServiceStates=@{}
$script:taskServiceCalls=New-Object 'Collections.Generic.List[string]'
$script:taskServiceChecks=New-Object 'Collections.Generic.List[object]'
$script:taskServiceStartFailure=0
$script:taskServiceServer=[pscustomobject]@{EnableSMB2Protocol=$false;RequireSecuritySignature=$true}
function Reset-ServiceFixture {
    $script:taskServiceCalls.Clear(); $script:taskServiceChecks.Clear(); $script:taskServiceStartFailure=0
    foreach($serviceName in $script:taskServiceNames){$script:taskServiceStates[$serviceName]=[pscustomobject]@{Name=$serviceName;StartMode='Manual';State='Stopped';Delayed=[pscustomobject]@{Path=('fixture:'+ $serviceName);Name='DelayedAutoStart';Exists=$true;Kind='DWord';Value=0}}}
}
function Advanced-Repair($Request){return $false}
function Get-SmbServerConfiguration {return $script:taskServiceServer}
function Snapshot-User($User){return $null}
function Get-RegistrySnapshot($Path,$Name){return [pscustomobject]@{Path=$Path;Name=$Name;Exists=$false;Kind='';Value=$null}}
function Get-FirewallSnapshots($Prefix){return @()}
function Get-ServiceSnapshot([string]$Name){$state=$script:taskServiceStates[$Name]; return [pscustomobject]@{Name=$state.Name;StartMode=$state.StartMode;State=$state.State;Delayed=[pscustomobject]@{Path=$state.Delayed.Path;Name=$state.Delayed.Name;Exists=$state.Delayed.Exists;Kind=$state.Delayed.Kind;Value=$state.Delayed.Value}}}
function Write-Phase($Text){$script:taskServiceCalls.Add('phase')}
function Complete-WorkStep($Name){$script:taskServiceCalls.Add('complete:'+ $Name)}
function Set-NetConnectionProfile($InterfaceIndex,$NetworkCategory){$script:taskServiceCalls.Add('network:'+ $InterfaceIndex+':'+$NetworkCategory)}
function Set-Service($Name,$StartupType){$script:taskServiceCalls.Add('set:'+ $Name+':'+$StartupType); $script:taskServiceStates[$Name].StartMode=@{Automatic='Auto';Manual='Manual';Disabled='Disabled'}[[string]$StartupType]}
function Start-Service($Name){$script:taskServiceCalls.Add('start:'+ $Name); if($Name -eq 'LanmanWorkstation' -and $script:taskServiceStartFailure -ne 0){throw (New-Object ComponentModel.Win32Exception($script:taskServiceStartFailure,'Isolated Workstation start failed'))}; $script:taskServiceStates[$Name].State='Running'}
function Stop-Service($Name,$ErrorAction){$script:taskServiceCalls.Add('stop:'+ $Name);$script:taskServiceStates[$Name].State='Stopped'}
function New-ItemProperty($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force){$script:taskServiceCalls.Add('delayed:'+ $LiteralPath)}
function Set-SmbServerConfiguration($EnableSMB2Protocol,$RequireSecuritySignature,[switch]$Force){$script:taskServiceCalls.Add('server'); if($null -ne $EnableSMB2Protocol){$script:taskServiceServer.EnableSMB2Protocol=[bool]$EnableSMB2Protocol}; if($null -ne $RequireSecuritySignature){$script:taskServiceServer.RequireSecuritySignature=[bool]$RequireSecuritySignature}}
function Rule-Prefix($Name){return 'fixture-only-'}
function Add-Check($Name,$State,$Detail,$Code,$Fixable,$NextStep){$script:taskServiceChecks.Add([pscustomobject]@{Name=$Name;State=$State;Detail=$Detail;Code=$Code})}
function Restore-ShareSnapshot($Name,$Share){}
function Restore-Folder($Path,$Sddl){}
function Restore-Firewall($Firewall,$Prefix){}
function Restore-Registry($Registry){if($Registry.Path -like 'fixture:*'){$serviceName=$Registry.Path.Substring(8);$script:taskServiceStates[$serviceName].Delayed.Value=$Registry.Value;$script:taskServiceStates[$serviceName].Delayed.Exists=$Registry.Exists}}
function Restore-User($User){}
function Remove-CreatedUser($User){}
function Get-ShareSnapshot($Name){return $null}
function Get-NetConnectionProfile($InterfaceIndex){throw 'Forbidden unmocked network-profile read in the service fixture.'}

Reset-ServiceFixture
$script:Request=[pscustomobject]@{AllowAdvancedRepair=$false}
$script:Ledger=[pscustomobject]@{Global=[pscustomobject]@{Bindings=@()}}
$taskServiceNetwork=[pscustomobject]@{Id=16;Name='Isolated Ethernet';Category='Private'}
$taskServiceSnapshot=Get-SystemSnapshot $taskServiceNetwork 'fixture-only-' $null $null
Require-Service ($taskServiceSnapshot.Services.Count -eq 4) 'A setup transaction must journal all four services.'
Require-Service (($taskServiceSnapshot.Services.Name -join ',') -eq ($script:taskServiceNames -join ',')) 'The transaction omitted or duplicated the Workstation original state.'
Require-Service ($taskServiceSnapshot.Services[1].StartMode -eq 'Manual' -and $taskServiceSnapshot.Services[1].State -eq 'Stopped') 'The Workstation snapshot must be captured before setup changes.'
$script:Transaction=[pscustomobject]@{System=$taskServiceSnapshot}
$Network=$taskServiceNetwork
& $taskServiceBlock
foreach($taskServiceName in $script:taskServiceNames){Require-Service ($script:taskServiceStates[$taskServiceName].StartMode -eq 'Auto' -and $script:taskServiceStates[$taskServiceName].State -eq 'Running') ('Setup did not configure and start '+$taskServiceName)}
Require-Service ($script:taskServiceCalls.IndexOf('start:LanmanServer') -lt $script:taskServiceCalls.IndexOf('start:LanmanWorkstation')) 'Setup must start the local server before the outbound client.'
Require-Service ($script:taskServiceCalls.Contains('complete:apply-services')) 'A successful service phase did not report its completed work unit.'
Require-Service ($taskServiceSnapshot.Services[1].StartMode -eq 'Manual' -and $taskServiceSnapshot.Services[1].State -eq 'Stopped') 'Setup mutated the original Workstation journal snapshot.'

# An older committed ledger has three service records. Add only the missing
# original Workstation snapshot, never replace an earlier saved state.
$taskServiceLegacyServer=[pscustomobject]@{Name='LanmanServer';StartMode='Disabled';State='Stopped';Delayed=$taskServiceSnapshot.Services[0].Delayed}
$script:Ledger=[pscustomobject]@{Shares=@();Global=[pscustomobject]@{Services=@($taskServiceLegacyServer,$taskServiceSnapshot.Services[2],$taskServiceSnapshot.Services[3]);Registry=@();Bindings=@();Groups=@();ExpectedGroups=@();Networks=@();ExpectedServer=$null;Guest=$null}}
& $taskServiceMerge
Require-Service ($script:Ledger.Global.Services.Count -eq 4) 'An old ledger failed to acquire the original Workstation record.'
Require-Service ([object]::ReferenceEquals($script:Ledger.Global.Services[0],$taskServiceLegacyServer) -and $script:Ledger.Global.Services[0].StartMode -eq 'Disabled') 'Upgrading the ledger overwrote a previously saved service state.'
Require-Service (@($script:Ledger.Global.Services | Where-Object {$_.Name -eq 'LanmanWorkstation'}).Count -eq 1) 'Workstation ownership was duplicated.'
& $taskServiceMerge
Require-Service ($script:Ledger.Global.Services.Count -eq 4) 'A repeated setup duplicated saved original service records.'

# A real start failure must interrupt setup and retain its native code. It must
# not mark this phase complete or proceed to enabling SMB after the failure.
foreach($taskServiceCode in @(1060,1058,5)){
    Reset-ServiceFixture; $script:taskServiceStartFailure=$taskServiceCode; $taskServiceFailure=$null
    try{& $taskServiceBlock}catch{$taskServiceFailure=$_}
    Require-Service ($null -ne $taskServiceFailure) ('Setup ignored Workstation error '+$taskServiceCode)
    $taskServiceException=$taskServiceFailure.Exception
    while($null -ne $taskServiceException -and $taskServiceException -isnot [ComponentModel.Win32Exception]){$taskServiceException=$taskServiceException.InnerException}
    Require-Service ($null -ne $taskServiceException -and $taskServiceException.NativeErrorCode -eq $taskServiceCode) 'Setup replaced an original Windows service error with a success or generic code.'
    Require-Service (-not $script:taskServiceCalls.Contains('complete:apply-services') -and -not $script:taskServiceCalls.Contains('server')) 'Failed Workstation start claimed a completed service phase.'
}

# Exercise the actual rollback and its actual final verification, including
# Workstation state/start type and delayed-start original record.
Reset-ServiceFixture
& $taskServiceBlock
$script:taskServiceCalls.Clear()
$taskServiceSnapshot.Network.Id=-1
$taskServiceRollback=[pscustomobject]@{ShareName='IsolatedShare';Share=$null;FolderPath='C:\IsolatedFixture';FolderSddl=$null;CreatedUser=$null;System=$taskServiceSnapshot}
$taskServiceUndone=Undo-Transaction $taskServiceRollback
Require-Service ([bool]$taskServiceUndone) 'The actual rollback could not verify its saved service state.'
Require-Service ($script:taskServiceStates.LanmanWorkstation.StartMode -eq 'Manual' -and $script:taskServiceStates.LanmanWorkstation.State -eq 'Stopped') 'Failed setup rollback failed to restore the outbound SMB client.'
Require-Service ($script:taskServiceCalls.Contains('set:LanmanWorkstation:Manual') -and $script:taskServiceCalls.Contains('stop:LanmanWorkstation')) 'Rollback skipped the actual Workstation restore action.'

Reset-ServiceFixture
foreach($taskServiceName in $script:taskServiceNames){$script:taskServiceStates[$taskServiceName].StartMode='Auto';$script:taskServiceStates[$taskServiceName].State='Running'}
Restore-GlobalIfLast
Require-Service ($script:taskServiceStates.LanmanWorkstation.StartMode -eq 'Manual' -and $script:taskServiceStates.LanmanWorkstation.State -eq 'Stopped') 'Removing the last owned share failed to restore the original Workstation state from an upgraded ledger.'
Reset-ServiceFixture
foreach($taskServiceName in $script:taskServiceNames){$script:taskServiceStates[$taskServiceName].StartMode='Auto';$script:taskServiceStates[$taskServiceName].State='Running'}
$script:taskServiceStates.LanmanWorkstation.StartMode='Manual'
Restore-GlobalIfLast
Require-Service ($script:taskServiceStates.LanmanWorkstation.StartMode -eq 'Manual' -and $script:taskServiceStates.LanmanWorkstation.State -eq 'Running') 'Global undo replaced a Workstation state changed outside the program.'
Require-Service (-not $script:taskServiceCalls.Contains('stop:LanmanWorkstation') -and @($script:taskServiceChecks | Where-Object {$_.State -eq 'warning' -and $_.Detail.Contains('LanmanWorkstation')}).Count -eq 1) 'Global undo must explain preserved external Workstation changes.'
$script:taskServiceCalls.Clear();$script:Ledger.Shares=@([pscustomobject]@{Name='StillOwned'})
Restore-GlobalIfLast
Require-Service ($script:taskServiceCalls.Count -eq 0) 'Removing one of several owned shares prematurely restored shared service settings.'
Write-Output ('PASS: '+$script:taskServicePassed+' isolated setup/service-journal checks; no real services, shares, accounts, registry or firewall changed.')
