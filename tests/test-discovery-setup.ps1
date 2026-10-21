param([string]$AssemblyPath=(Join-Path $PSScriptRoot '..\dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference='Stop'
$script:passed=0
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:passed++}
[Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath)) | Out-Null
$taskTokens=$null; $taskErrors=$null
$taskSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$taskAst=[Management.Automation.Language.Parser]::ParseInput($taskSource,[ref]$taskTokens,[ref]$taskErrors)
Require (@($taskErrors).Count -eq 0) 'PowerShell source must parse under Windows PS5.'
foreach($taskName in @('Get-Value','Get-Subnet','Is-PrivateIPv4','Normalize-IPv4FirewallScope','Test-IPv4FirewallScope','Get-DiscoveryShareDescription','Get-DiscoveryExecutable','Get-DiscoveryLocalAddresses','Configure-Firewall','Test-ManagedDiscoveryFirewallRule','Inspect-DiscoveryReadiness','Test-SelectedShareInspectionFailure')) {
    $taskFunction=$taskAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskName},$true)
    if(!$taskFunction){throw ('Production function missing: '+$taskName)}
    . ([scriptblock]::Create($taskFunction.Extent.Text))
}
$taskGuest=Get-DiscoveryShareDescription Guest 'Gast'
$taskMode='';$taskLogin=''
Require ([EinfachNetzwerk.NetworkDiscovery]::TryParseMetadata($taskGuest,$env:COMPUTERNAME,[ref]$taskMode,[ref]$taskLogin)) 'First setup must emit a recipient-readable preset.'
Require ($taskMode -eq 'Guest' -and $taskLogin -ceq ($env:COMPUTERNAME+'\Gast')) 'Guest preset must carry actual qualified account.'
$taskPassword=Get-DiscoveryShareDescription Password 'NetworkUser'
Require ([EinfachNetzwerk.NetworkDiscovery]::TryParseMetadata($taskPassword,$env:COMPUTERNAME,[ref]$taskMode,[ref]$taskLogin)) 'Password mode also advertises public account.'
Require ($taskMode -eq 'Password' -and $taskLogin -ceq ($env:COMPUTERNAME+'\NetworkUser')) 'Password preset must not claim a blank password.'
foreach($taskBadAccount in @('',' ','Other\Gast','../Guest',"Bad`nUser",'.','..','Bad:User',('a'*21))) {
    $taskRejected=$false;try{$null=Get-DiscoveryShareDescription Guest $taskBadAccount}catch{$taskRejected=$true}
    Require $taskRejected 'Unsafe preset account accepted.'
}
$taskRejected=$false;try{$null=Get-DiscoveryShareDescription Anonymous Gast}catch{$taskRejected=$true}
Require $taskRejected 'Unknown mode must fail before publication.'
foreach($taskLowerMode in @('guest','password')) {
    $taskLowerDescription=Get-DiscoveryShareDescription $taskLowerMode 'Gast'
    Require ([EinfachNetzwerk.NetworkDiscovery]::TryParseMetadata($taskLowerDescription,$env:COMPUTERNAME,[ref]$taskMode,[ref]$taskLogin)) 'Case-insensitive accepted request modes must emit canonical recipient presets.'
}
$taskExe=Get-DiscoveryExecutable
Require ($taskExe -ceq [IO.Path]::GetFullPath($AssemblyPath)) 'Rule program must be the loaded trusted EXE, not PowerShell or user input.'
$script:AppMark='EinfachNetzwerk-v1';$script:RuleGroup='EinfachNetzwerk (Heimnetz)'
$script:rules=New-Object 'Collections.Generic.List[object]'
$script:cleared=''
function Clear-ManagedRules($Prefix){$script:cleared=$Prefix}
function Get-NetFirewallRule {param($PolicyStore,$ErrorAction)}
function Add-Check {param($Name,$State,$Detail,$Code,$Fixable,$NextStep)}
function New-NetFirewallRule {
    param($PolicyStore,$Name,$DisplayName,$Group,$Description,$Direction,$Action,$Enabled,$Profile,$Protocol,$LocalPort,$RemotePort,$Program,$Service,$InterfaceAlias,$LocalAddress,$RemoteAddress,$EdgeTraversalPolicy,$ErrorAction)
    $script:rules.Add([pscustomobject]@{Name=$Name;Program=$Program;Service=$Service;Enabled=[string]$Enabled;Profile=[string]$Profile;Direction=$Direction;Action=$Action;Protocol=[string]$Protocol;LocalPort=@([string]$LocalPort);RemotePort=@([string]$RemotePort);InterfaceAlias=@($InterfaceAlias);LocalAddress=@($LocalAddress);RemoteAddress=@($RemoteAddress);EdgeTraversalPolicy=$EdgeTraversalPolicy;Description=$Description;Group=$Group})
}
$taskNetwork=[pscustomobject]@{Id=16;Name='Private LAN';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private'}
Configure-Firewall $taskNetwork 'OwnShare-'
Require ($script:cleared -eq 'OwnShare-') 'Only own managed prefix may be replaced.'
Require ($script:rules.Count -eq 2) 'SMB and public preset require distinct scoped rules.'
$taskRule=@($script:rules | Where-Object {$_.Name -eq 'OwnShare-Discovery'})[0]
Require ($taskRule.Protocol -eq 'UDP' -and $taskRule.LocalPort[0] -eq '41671') 'Discovery must use only the reserved UDP port.'
Require ($taskRule.Program -eq $taskExe -and $taskRule.Program -ne 'Any') 'UDP rule must be limited to this exact app.'
Require ($taskRule.Profile -eq 'Private' -and $taskRule.InterfaceAlias[0] -eq $taskNetwork.Name) 'UDP rule must be limited to the selected private adapter.'
Require ($taskRule.LocalAddress.Count -eq 2 -and $taskRule.LocalAddress[0] -eq $taskNetwork.Address -and $taskRule.LocalAddress[1] -eq '192.168.178.255' -and $taskRule.RemoteAddress[0] -eq $taskNetwork.Subnet -and $taskRule.EdgeTraversalPolicy -eq 'Block') 'UDP rule must permit exact unicast and directed broadcast in this local subnet.'
Require (Test-ManagedDiscoveryFirewallRule $taskRule $taskNetwork $taskExe) 'First setup proof must accept its exact rule.'
foreach($taskMutation in @(@('Enabled','False'),@('Profile','Public'),@('Program','Any'),@('Program','C:\Other.exe'),@('Service','LanmanServer'),@('Direction','Outbound'),@('Action','Block'),@('Protocol','TCP'),@('LocalPort',@('445')),@('InterfaceAlias',@('Other LAN')),@('LocalAddress',@('Any')),@('RemoteAddress',@('Any')),@('RemoteAddress',@('192.168.178.0/16')),@('InterfaceAlias',@('Private LAN','Other LAN')))) {
    $taskOriginal=$taskRule.($taskMutation[0]);$taskRule.($taskMutation[0])=$taskMutation[1]
    Require (-not (Test-ManagedDiscoveryFirewallRule $taskRule $taskNetwork $taskExe)) ('Unsafe/stale rule accepted: '+$taskMutation[0])
    $taskRule.($taskMutation[0])=$taskOriginal
}
$taskRule.RemoteAddress=@('192.168.178.0/255.255.255.0')
Require (Test-ManagedDiscoveryFirewallRule $taskRule $taskNetwork $taskExe) 'Windows dotted subnet masks must remain supported.'
Require (-not (Test-ManagedDiscoveryFirewallRule $null $taskNetwork $taskExe)) 'Missing discovery rule must trigger targeted repair.'
Require (-not (Test-ManagedDiscoveryFirewallRule $taskRule $taskNetwork '')) 'Unknown executable must not pass first setup proof.'
$taskConfigure=$taskAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Configure-Firewall'},$true).Extent.Text
Require ($taskConfigure -notmatch 'Disable-NetFirewall|Set-NetFirewallProfile') 'Discovery setup cannot disable Windows firewall.'
$taskRepair=$taskAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-AndRepairLocalShare'},$true).Extent.Text
Require ($taskRepair -match "'DiscoveryMetadata'" -and $taskRepair -match 'Get-RequestDiscoveryDescription') 'First setup retries must preserve and repair public preset metadata.'
$script:Checks=New-Object 'Collections.Generic.List[object]'
function Add-Check {param($Name,$State,$Detail,$Code,$Fixable,$NextStep,$TargetShare) $script:Checks.Add([pscustomobject]@{Name=$Name;State=$State;Code=$Code;Fixable=$Fixable;TargetShare=$TargetShare})}
function Get-Guest {[pscustomobject]@{Name='Gast'}}
function Rule-Prefix($Name){return 'OwnShare-'}
$script:taskDescription='EinfachNetzwerk-v1'
$script:taskInspectRules=@($taskRule)
function Get-ShareSnapshot($Name){[pscustomobject]@{Name=$Name;Description=$script:taskDescription}}
function Get-FirewallSnapshots($Prefix){$script:taskInspectRules}
$script:Result=[pscustomobject]@{Shares=@([pscustomobject]@{Name='Desktop';Managed=$true;Available=$true;Mode='Guest';UserName='Gast';AdapterId=16},[pscustomobject]@{Name='Foreign';Managed=$false;Available=$true},[pscustomobject]@{Name='Removed';Managed=$true;Available=$false});Networks=@($taskNetwork)}
Inspect-DiscoveryReadiness
Require ($script:Checks.Count -eq 1 -and $script:Checks[0].Code -eq 'DISCOVERY_SETUP_REQUIRED' -and $script:Checks[0].TargetShare -eq 'Desktop' -and $script:Checks[0].Fixable) 'Startup must report an old managed share and exact repair target, excluding foreign/removed shares.'
Require ($script:Checks[0].State -eq 'warning') 'A pending discovery upgrade alone must not claim normal SMB diagnosis failed.'
$script:Checks.Clear()
Inspect-DiscoveryReadiness 'Desktop'
Require ($script:Checks[0].State -eq 'error') 'The selected setup must still fail when its required discovery proof is missing.'
$script:Checks.Clear()
Inspect-DiscoveryReadiness 'Other'
Require ($script:Checks[0].State -eq 'warning') 'Another selected setup must retain a warning for this older share.'
$script:Checks.Clear();$script:taskDescription=$taskGuest
Inspect-DiscoveryReadiness
Require ($script:Checks[0].Code -eq 'DISCOVERY_SETUP_READY' -and $script:Checks[0].State -eq 'ok') 'Current metadata/rule must prove readiness.'
$script:Checks.Clear();$taskRule.Program='C:\OlderVersion.exe'
Inspect-DiscoveryReadiness
Require ($script:Checks[0].Code -eq 'DISCOVERY_SETUP_REQUIRED') 'Moving/updating portable EXE must request exact discovery rule repair.'
$script:Checks.Clear();$taskRule.Program=$taskExe;$script:taskInspectRules=@()
Inspect-DiscoveryReadiness
Require ($script:Checks[0].Code -eq 'DISCOVERY_SETUP_REQUIRED') 'Missing discovery rule must be detected at startup before user manual setup.'
$script:Checks.Clear();$script:taskInspectRules=@($taskRule);$taskNetwork.Category='Public'
Inspect-DiscoveryReadiness
Require ($script:Checks[0].Code -eq 'DISCOVERY_SETUP_REQUIRED') 'A public network cannot be declared ready by a private firewall rule.'
Require ((Get-DiscoveryLocalAddresses ([pscustomobject]@{Address='192.168.5.5';Subnet='192.168.5.4/30'}))[1] -eq '192.168.5.7') 'Directed broadcast must match the exact small subnet.'
Require ((Get-DiscoveryLocalAddresses ([pscustomobject]@{Address='10.2.3.4';Subnet='10.2.0.0/16'}))[1] -eq '10.2.255.255') 'Directed broadcast must match the exact larger subnet.'
$script:Checks.Clear()
Add-Check 'Other old share' error '' 'DISCOVERY_SETUP_REQUIRED' $true '' 'Other'
Require (-not (Test-SelectedShareInspectionFailure 'Desktop')) 'Another old share must not make a freshly verified Desktop setup fail.'
Require (Test-SelectedShareInspectionFailure 'Other') 'The selected old share must retain its own repair failure.'
Add-Check 'Server' error '' 'SERVICE_CONFIG_MISSING' $true '' ''
Require (Test-SelectedShareInspectionFailure 'Desktop') 'A global server error must still make selected setup fail.'
$script:Checks.Clear()
Add-Check 'Healthy' ok '' 'DISCOVERY_SETUP_READY' $false '' 'Desktop'
Add-Check 'Unknown' warning '' 'DISCOVERY_QUERY_FAILED' $false '' 'Desktop'
Require (-not (Test-SelectedShareInspectionFailure 'Desktop')) 'Warnings must not fabricate a selected-share failure.'
Write-Output ('Discovery first setup: '+$script:passed+' isolated checks passed; no real share, account, firewall or network mutation.')
