param([string]$AssemblyPath,[switch]$Live)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -eq 'Core') {
    $taskArguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if($AssemblyPath){$taskArguments+=@('-AssemblyPath',$AssemblyPath)}
    if($Live){$taskArguments+='-Live'}
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @taskArguments
    exit $LASTEXITCODE
}
if(-not $AssemblyPath){
    $taskOutput=Join-Path $PSScriptRoot 'host-qa\discovery-check.dll'
    [IO.Directory]::CreateDirectory((Split-Path $taskOutput))|Out-Null
    $taskSources=@('NetworkDiscovery.cs','NativeHomeNetworks.cs','DiscoveryPeerService.cs','Models.cs')|ForEach-Object {Join-Path (Join-Path $PSScriptRoot '..\src') $_}
    & (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:library /langversion:5 /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:'+$taskOutput) @taskSources
    if($LASTEXITCODE -ne 0){throw 'Discovery compile failed.'}
    $AssemblyPath=$taskOutput
}
[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path)|Out-Null
$script:Passed=0
function Assert-Discovery([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++}
$taskFlags=[Reflection.BindingFlags]'Static,NonPublic'
$taskType=[EinfachNetzwerk.NetworkDiscovery]
$taskPlan=$taskType.GetMethod('PlanCandidates',$taskFlags)
$taskEligible=$taskType.GetMethod('EligibleAddress',$taskFlags)
$taskValidNetwork=$taskType.GetMethod('ValidNetwork',$taskFlags)
$taskComputerName=$taskType.GetMethod('ValidComputerName',$taskFlags)
$taskShareName=$taskType.GetMethod('ValidShareName',$taskFlags)
function New-DiscoveryNetwork([string]$Address='192.168.178.24',[string]$Subnet='192.168.178.0/24',[string]$Gateway='192.168.178.1',[string]$Category='Private',[int]$Id=16){
    $taskNetwork=New-Object EinfachNetzwerk.NativeHomeNetworks+HomeNetwork
    $taskNetwork.Address=$Address;$taskNetwork.Subnet=$Subnet;$taskNetwork.Gateway=$Gateway;$taskNetwork.Category=$Category;$taskNetwork.Id=$Id;$taskNetwork.Name='isolated-test'
    return $taskNetwork
}
function Get-DiscoveryPlan($Network,[int]$Limit=1024,$Neighbors=$null,[string[]]$OtherLocal=@()){
    $taskNetworks=New-Object 'System.Collections.Generic.List[EinfachNetzwerk.NativeHomeNetworks+HomeNetwork]'
    foreach($item in @($Network)){$taskNetworks.Add($item)}
    $taskNeighborValue=$null; if($null -ne $Neighbors){$taskNeighborValue=$Neighbors.psobject.BaseObject}; $taskPlan.Invoke($null,[object[]]@($taskNetworks.psobject.BaseObject,$taskNeighborValue,$Limit,$OtherLocal))
}
function Get-PlanAddresses($Plan){return ,@($Plan.Candidates | ForEach-Object {$_.Address})}
$taskNetwork=New-DiscoveryNetwork
$taskFull=Get-DiscoveryPlan $taskNetwork
$taskAddresses=Get-PlanAddresses $taskFull
Assert-Discovery ($taskAddresses.Count -eq 253 -and -not $taskFull.Truncated) 'Exact /24 plan excludes local source, network and broadcast'
foreach($taskBad in @('192.168.178.24','192.168.178.0','192.168.178.255','192.168.179.1','8.8.8.8','127.0.0.1','169.254.0.1','::1','192.168.178.024')){
    Assert-Discovery ($taskBad -notin $taskAddresses) ('Excluded source or out-of-scope host '+$taskBad)
}
Assert-Discovery ($taskAddresses -contains '192.168.178.21' -and $taskAddresses -contains '192.168.178.1') 'Actual SMB host and router address remain eligible targets'
$taskOther=Get-DiscoveryPlan $taskNetwork 1024 $null @('192.168.178.21')
Assert-Discovery ((Get-PlanAddresses $taskOther).Count -eq 252 -and '192.168.178.21' -notin (Get-PlanAddresses $taskOther)) 'All local IPv4 addresses excluded even from other profile adapters'
$taskHints=New-Object 'System.Collections.Generic.Dictionary[int,System.Collections.Generic.List[string]]'
$taskHints.Add(16,(New-Object 'System.Collections.Generic.List[string]'))
foreach($taskHint in @('192.168.178.21','8.8.8.8','192.168.178.0','192.168.178.255','192.168.178.24','192.168.178.21')){$taskHints[16].Add($taskHint)}
$taskPriority=Get-DiscoveryPlan $taskNetwork 8 $taskHints
Assert-Discovery ($taskPriority.Truncated -and (Get-PlanAddresses $taskPriority).Count -eq 8 -and (Get-PlanAddresses $taskPriority)[0] -ceq '192.168.178.21') 'Valid neighbor host prioritized, cap and truncation are honest'
Assert-Discovery (@((Get-PlanAddresses $taskPriority)|Select-Object -Unique).Count -eq 8) 'Duplicate neighbor IPs do not consume scan budget'
$taskLarge=Get-DiscoveryPlan (New-DiscoveryNetwork '10.23.55.24' '10.23.0.0/16' '10.23.55.1')
Assert-Discovery ($taskLarge.Candidates.Count -eq 1024 -and $taskLarge.Truncated) 'A large private subnet caps at 1024 and reports incomplete coverage'
Assert-Discovery ((Get-PlanAddresses $taskLarge)[0] -ceq '10.23.55.1' -and '10.23.55.21' -in (Get-PlanAddresses $taskLarge)) 'Source /24 prioritized inside a larger exact subnet'
foreach($taskCase in @(
    @('192.168.178.24','192.168.178.0/24','192.168.178.1','Public',16),
    @('192.168.178.24','192.168.178.0/24','192.168.178.1','DomainAuthenticated',16),
    @('192.168.178.24','192.168.178.0/24','192.168.179.1','Private',16),
    @('192.168.178.24','192.168.178.0/24','8.8.8.8','Private',16),
    @('192.168.178.24','192.168.0.0/15','192.168.178.1','Private',16),
    @('192.168.178.24','192.168.178.0/31','192.168.178.1','Private',16),
    @('192.168.178.24','192.168.178.0/24','192.168.178.1','Private',0),
    @('8.8.8.8','8.8.8.0/24','8.8.8.1','Private',16))){
    $taskInvalid=New-DiscoveryNetwork @taskCase
    Assert-Discovery ((Get-DiscoveryPlan $taskInvalid).Candidates.Count -eq 0) 'Invalid/public/domain profile, gateway, mask or index produces no probes'
}
$taskSmall=Get-DiscoveryPlan (New-DiscoveryNetwork '192.168.1.1' '192.168.1.0/30' '192.168.1.2')
Assert-Discovery ((Get-PlanAddresses $taskSmall).Count -eq 1 -and (Get-PlanAddresses $taskSmall)[0] -ceq '192.168.1.2') 'Usable /30 exactly one remote host'
foreach($taskName in @('TEST-NOTEBOOK','PC','TEST-PC','A-1')){
    Assert-Discovery ([bool]$taskComputerName.Invoke($null,[object[]]@($taskName))) 'Simple actual Windows computer name accepted'
}
foreach($taskName in @('192.168.178.21','TEST-NOTEBOOK.fritz.box','../PC','PC\Gast','PC;mode=Guest','1234',('A'*16),'PC-','-PC')){
    Assert-Discovery (-not [bool]$taskComputerName.Invoke($null,[object[]]@($taskName))) 'Alias/IP/path/overlong computer cannot become canonical identity'
}
foreach($taskName in @('Desktop','Meine Dateien','Bilder-2026')){
    Assert-Discovery ([bool]$taskShareName.Invoke($null,[object[]]@($taskName))) 'Ordinary compatible disk-share name accepted'
}
foreach($taskName in @('C$','ADMIN$','IPC$','IPC','ADMIN','PRINT','..',' Desktop','Desktop.','PC\Desktop','public$tail')){
    Assert-Discovery (-not [bool]$taskShareName.Invoke($null,[object[]]@($taskName))) 'Administrative/hidden/path/reserved unsupported share cannot be suggested'
}
function Test-Metadata([string]$Remark,[string]$Computer='TEST-NOTEBOOK'){
    $taskMode='';$taskLogin=''
    $taskValid=[EinfachNetzwerk.NetworkDiscovery]::TryParseMetadata($Remark,$Computer,[ref]$taskMode,[ref]$taskLogin)
    return [pscustomobject]@{Valid=$taskValid;Mode=$taskMode;Login=$taskLogin}
}
$taskMetadata=Test-Metadata '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast]'
Assert-Discovery ($taskMetadata.Valid -and $taskMetadata.Mode -ceq 'Guest' -and $taskMetadata.Login -ceq 'TEST-NOTEBOOK\Gast') 'Exact guest preset suggests actual public account without claiming access'
$taskPasswordMetadata=Test-Metadata '[EinfachNetzwerk:1;mode=Password;computer=TEST-NOTEBOOK;user=NetworkUser]'
Assert-Discovery ($taskPasswordMetadata.Valid -and $taskPasswordMetadata.Mode -ceq 'Password' -and $taskPasswordMetadata.Login -ceq 'TEST-NOTEBOOK\NetworkUser') 'Password mode can suggest only the public network username'
$taskUnicode=Test-Metadata ('[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user='+[Uri]::EscapeDataString('Gäste Konto')+']')
Assert-Discovery ($taskUnicode.Valid -and $taskUnicode.Login -ceq 'TEST-NOTEBOOK\Gäste Konto') 'Percent-escaped Unicode account remains exact public value'
foreach($taskBadRemark in @(
    'EinfachNetzwerk','[EinfachNetzwerk:0;mode=Guest;computer=TEST-NOTEBOOK;user=Gast]',
    '[EinfachNetzwerk:1;mode=Unknown;computer=TEST-NOTEBOOK;user=Gast]',
    '[EinfachNetzwerk:1;mode=Guest;computer=OTHER-PC;user=Gast]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast;password=secret]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=OTHER%5CGast]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Guest%2Fadmin]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Guest%3Bextra]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Guest%00]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Guest%GG]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=%20Guest]',
    '[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=]',
    ('[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user='+('x'*21)+']'),
    ('[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user='+('x'*1601)+']'))){
    $taskParsed=Test-Metadata $taskBadRemark
    Assert-Discovery (-not $taskParsed.Valid -and $taskParsed.Mode -ceq '' -and $taskParsed.Login -ceq '') 'Malformed/foreign/secret/control/path/oversize preset remains unknown'
}
$taskNativeResult=$taskType.GetNestedType('NativeResult',[Reflection.BindingFlags]'NonPublic')
function New-NativeDiscoveryResult([int]$Code=0,[string]$Name='',[bool]$Complete=$false){
    $taskValue=[Activator]::CreateInstance($taskNativeResult,$true)
    $taskNativeResult.GetField('Code').SetValue($taskValue,[int]$Code)
    $taskNativeResult.GetField('Name').SetValue($taskValue,[string]$Name)
    $taskNativeResult.GetField('Complete').SetValue($taskValue,[bool]$Complete)
    return $taskValue
}
function New-ReportedComputer {
    $taskReported=New-Object EinfachNetzwerk.DiscoveredComputer
    $taskReported.Address='192.168.178.21';$taskReported.ComputerName='TEST-NOTEBOOK';$taskReported.ReportedIdentity=$true
    $taskShare=New-Object EinfachNetzwerk.DiscoveredShare
    $taskShare.Name='Desktop';$taskShare.Remark='[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast]'
    $taskReported.Shares.Add($taskShare)
    return $taskReported
}
$taskApply=$taskType.GetMethod('ApplyDetails',$taskFlags)
$taskReported=New-ReportedComputer
$taskIdentityFail=New-NativeDiscoveryResult 53
$taskShareFail=New-NativeDiscoveryResult 1272
$taskApply.Invoke($null,[object[]]@($taskReported.psobject.BaseObject,$taskIdentityFail.psobject.BaseObject,$taskShareFail.psobject.BaseObject))|Out-Null
Assert-Discovery (-not $taskReported.IdentityVerified -and -not $taskReported.SharesComplete -and $taskReported.ErrorCode -ceq 'Win32: 1272') 'Blocked readonly enumeration retains original error separately from reported identity'
Assert-Discovery ($taskReported.Shares.Count -eq 1 -and $taskReported.Shares[0].MetadataVerified -and $taskReported.Shares[0].SuggestedUserName -ceq 'TEST-NOTEBOOK\Gast') 'Validated public preset survives SMB authentication block without guessing or access proof'
$taskContradiction=New-ReportedComputer
$taskOtherIdentity=New-NativeDiscoveryResult 0 'OTHER-PC'
$taskApply.Invoke($null,[object[]]@($taskContradiction.psobject.BaseObject,$taskOtherIdentity.psobject.BaseObject,$taskShareFail.psobject.BaseObject))|Out-Null
Assert-Discovery ($taskContradiction.IdentityVerified -and $taskContradiction.ComputerName -ceq 'OTHER-PC' -and $taskContradiction.Shares.Count -eq 0) 'Actual Windows identity contradicting public hint removes foreign account/share presets'
$taskMissing=New-ReportedComputer
$taskIdentity=New-NativeDiscoveryResult 0 'TEST-NOTEBOOK'
$taskEmptyNative=New-NativeDiscoveryResult 0 '' $true
$taskApply.Invoke($null,[object[]]@($taskMissing.psobject.BaseObject,$taskIdentity.psobject.BaseObject,$taskEmptyNative.psobject.BaseObject))|Out-Null
Assert-Discovery ($taskMissing.SharesComplete -and $taskMissing.Shares.Count -eq 0) 'Complete native share inventory excludes stale advertised phantom shares'
$taskSnapshot=$taskType.GetMethod('Snapshot',$taskFlags).Invoke($null,[object[]]@($taskReported.psobject.BaseObject))
$taskReported.ComputerName='CHANGED';$taskReported.Shares[0].Name='Changed';$taskReported.Shares[0].SuggestedUserName='CHANGED\Other'
Assert-Discovery ($taskSnapshot.ComputerName -ceq 'TEST-NOTEBOOK' -and $taskSnapshot.Shares[0].Name -ceq 'Desktop' -and $taskSnapshot.Shares[0].SuggestedUserName -ceq 'TEST-NOTEBOOK\Gast') 'Published UI discovery snapshot never observes later worker mutations'
$taskAccountSetter=$taskType.GetMethod('SetExistingAccountSuggestion',$taskFlags)
function New-ExistingAccountComputer {
    $taskComputer=New-Object EinfachNetzwerk.DiscoveredComputer
    $taskComputer.Address='192.168.178.21';$taskComputer.ComputerName='TEST-NOTEBOOK'
    $taskComputer.MetadataContext='ExistingWindowsConnection';$taskComputer.Port445Open=$true;$taskComputer.IdentityVerified=$true
    return $taskComputer
}
foreach($taskActualAccount in @('TEST-NOTEBOOK\Gast','KnownNetworkUser','actual-user@example.test')) {
    $taskKnownAccountComputer=New-ExistingAccountComputer
    $taskAccountSetter.Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject,$taskActualAccount,$true))|Out-Null
    Assert-Discovery ($taskKnownAccountComputer.ConnectionUserNameVerified -and $taskKnownAccountComputer.ConnectionUserName -ceq $taskActualAccount -and $taskKnownAccountComputer.Shares.Count -eq 0) 'Actual connected account suggestion preserves supplied identity without guessing a share, password or access mode'
}
$taskKnownAccountComputer=New-ExistingAccountComputer
$taskAccountSetter.Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject,'TEST-NOTEBOOK\Gast',$true))|Out-Null
$taskKnownAccountSnapshot=$taskType.GetMethod('Snapshot',$taskFlags).Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject))
$taskKnownAccountComputer.ConnectionUserName='changed-account';$taskKnownAccountComputer.ConnectionUserNameVerified=$false
Assert-Discovery ($taskKnownAccountSnapshot.ConnectionUserNameVerified -and $taskKnownAccountSnapshot.ConnectionUserName -ceq 'TEST-NOTEBOOK\Gast') 'Published account suggestion is an immutable snapshot of the verified existing connection'
foreach($taskInvalidAccount in @('', ' ', ' User','User ', 'A/B', 'A\B\C', '\User', 'Domain\', ('User'+[char]10), ('User'+[char]127), ('a'*257))) {
    $taskKnownAccountComputer=New-ExistingAccountComputer
    $taskAccountSetter.Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject,$taskInvalidAccount,$true))|Out-Null
    Assert-Discovery (-not $taskKnownAccountComputer.ConnectionUserNameVerified -and $taskKnownAccountComputer.ConnectionUserName -ceq '') 'Malformed, empty, truncated and control-containing Windows usernames cannot become retry account suggestions'
}
foreach($taskAccountGuard in @('NotCurrent','NoExistingWindowsConnection','PublicPeerPreset','PortClosed','IdentityUnconfirmed','BadIdentity')) {
    $taskKnownAccountComputer=New-ExistingAccountComputer
    $taskIsCurrent=$true
    switch($taskAccountGuard) {
        'NotCurrent' {$taskIsCurrent=$false}
        'NoExistingWindowsConnection' {$taskKnownAccountComputer.MetadataContext=$taskAccountGuard}
        'PublicPeerPreset' {$taskKnownAccountComputer.MetadataContext=$taskAccountGuard}
        'PortClosed' {$taskKnownAccountComputer.Port445Open=$false}
        'IdentityUnconfirmed' {$taskKnownAccountComputer.IdentityVerified=$false}
        'BadIdentity' {$taskKnownAccountComputer.ComputerName='8.8.8.8'}
    }
    $taskAccountSetter.Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject,'TEST-NOTEBOOK\Gast',$taskIsCurrent))|Out-Null
    Assert-Discovery (-not $taskKnownAccountComputer.ConnectionUserNameVerified -and $taskKnownAccountComputer.ConnectionUserName -ceq '') 'Expired, unconfirmed, peer-only and changed Windows contexts cannot provide a current account suggestion'
}
$taskKnownAccountComputer=New-ExistingAccountComputer
$taskAccountSetter.Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject,'TEST-NOTEBOOK\Gast',$true))|Out-Null
$taskType.GetMethod('SetChangedNetwork',$taskFlags).Invoke($null,[object[]]@($taskKnownAccountComputer.psobject.BaseObject))|Out-Null
Assert-Discovery (-not $taskKnownAccountComputer.ConnectionUserNameVerified -and $taskKnownAccountComputer.ConnectionUserName -ceq '') 'Changed physical private network clears the existing account suggestion'
$taskConnectionType=$taskType.GetNestedType('ExistingConnection',[Reflection.BindingFlags]'NonPublic')
$taskSameConnection=$taskType.GetMethod('SameExistingConnection',$taskFlags)
function New-AccountConnection([string]$HostName='TEST-NOTEBOOK',[string]$RemotePath='\\TEST-NOTEBOOK\Desktop',[string]$UserName='TEST-NOTEBOOK\Gast') {
    $taskConnection=[Activator]::CreateInstance($taskConnectionType,$true)
    $taskConnectionType.GetField('Host').SetValue($taskConnection,$HostName)
    $taskConnectionType.GetField('RemotePath').SetValue($taskConnection,$RemotePath)
    $taskConnectionType.GetField('UserName').SetValue($taskConnection,$UserName)
    return $taskConnection
}
$taskExpectedConnection=New-AccountConnection
$taskCurrentConnection=New-AccountConnection 'test-notebook' '\\test-notebook\desktop'
Assert-Discovery ([bool]$taskSameConnection.Invoke($null,[object[]]@($taskExpectedConnection,$taskCurrentConnection))) 'Same SMB resource/account remains valid when only the server/path casing differs'
foreach($taskChangedContext in @((New-AccountConnection -UserName 'TEST-NOTEBOOK\OtherUser'),(New-AccountConnection -HostName 'OTHER-PC'),(New-AccountConnection -RemotePath '\\TEST-NOTEBOOK\Documents'),(New-AccountConnection -UserName ''),(New-AccountConnection -UserName 'bad/user'))) {
    Assert-Discovery (-not [bool]$taskSameConnection.Invoke($null,[object[]]@($taskExpectedConnection,$taskChangedContext))) 'Account replacement or different resource/server cannot authorize a stale Windows-account retry suggestion'
}
$taskScopeType=$taskType.GetNestedType('ScanScope',[Reflection.BindingFlags]'NonPublic')
$taskCandidateType=$taskType.GetNestedType('Candidate',[Reflection.BindingFlags]'NonPublic')
$taskCandidate=[Activator]::CreateInstance($taskCandidateType,$true)
foreach($taskPair in @(@('Address','192.168.178.21'),@('Source','192.168.178.24'),@('Subnet','192.168.178.0/24'),@('AdapterId',[int]16))){$taskCandidateType.GetField($taskPair[0]).SetValue($taskCandidate,$taskPair[1])}
$script:FreshInventory=New-Object 'System.Collections.Generic.List[EinfachNetzwerk.NativeHomeNetworks+HomeNetwork]'
$script:FreshInventory.Add((New-DiscoveryNetwork))
$taskFreshReader=[Func[Collections.Generic.List[EinfachNetzwerk.NativeHomeNetworks+HomeNetwork]]]{return $script:FreshInventory}
$taskScope=[Activator]::CreateInstance($taskScopeType,[object[]]@($taskFreshReader))
$taskScopeCheck=$taskScopeType.GetMethod('Eligible')
Assert-Discovery ([bool]$taskScopeCheck.Invoke($taskScope,[object[]]@($taskCandidate.psobject.BaseObject,$true))) 'Fresh confirmed physical private scope allows planned target'
$script:FreshInventory.Clear();$script:FreshInventory.Add((New-DiscoveryNetwork '192.168.178.24' '192.168.178.0/24' '192.168.178.1' 'Public'))
Assert-Discovery (-not [bool]$taskScopeCheck.Invoke($taskScope,[object[]]@($taskCandidate.psobject.BaseObject,$true))) 'Private-to-public profile change blocks next TCP/metadata query'
$script:FreshInventory.Clear();$script:FreshInventory.Add((New-DiscoveryNetwork))
Assert-Discovery (-not [bool]$taskScopeCheck.Invoke($taskScope,[object[]]@($taskCandidate.psobject.BaseObject,$true))) 'Changed scope terminates this scan even if profile subsequently returns'
Add-Type -TypeDefinition @'
using System;
public static class DiscoveryCallProbe {
    public static int Calls, Checks;
    public static bool Connected=true, LoseAfterIdentity, LoseAfterShares;
    public static string LastHost="";
    public static void Mark(string host) {Calls++;LastHost=host;}
    public static bool Confirmed() {Checks++;return Connected && !(LoseAfterIdentity && Calls>0) && !(LoseAfterShares && Calls>1);}
    public static void Reset() {Calls=Checks=0;Connected=true;LoseAfterIdentity=LoseAfterShares=false;LastHost="";}
}
'@
$taskKnownRead=$taskType.GetMethod('ReadKnownDetails',$taskFlags)
$taskReadFunctionType=[Func[string,object]].GetGenericTypeDefinition().MakeGenericType([string],$taskNativeResult)
$taskHostParameter=[Linq.Expressions.Expression]::Parameter([string],'host')
function New-DiscoveryReadDelegate($Result){
    $taskMark=[DiscoveryCallProbe].GetMethod('Mark')
    $taskReadBody=[Linq.Expressions.Expression]::Block([Linq.Expressions.Expression]::Call($taskMark,$taskHostParameter),[Linq.Expressions.Expression]::Constant($Result.psobject.BaseObject,$taskNativeResult))
    return [Linq.Expressions.Expression]::Lambda($taskReadFunctionType,$taskReadBody,[Linq.Expressions.ParameterExpression[]]@($taskHostParameter)).Compile()
}
$taskIdentityReader=New-DiscoveryReadDelegate (New-NativeDiscoveryResult 0 'TEST-NOTEBOOK')
$taskSharesReader=New-DiscoveryReadDelegate (New-NativeDiscoveryResult 1272)
$taskConfirmed=[Delegate]::CreateDelegate([Func[bool]],[DiscoveryCallProbe].GetMethod('Confirmed'))
$taskReadPeer=New-ReportedComputer
$taskReadPeer.Shares[0].SuggestedUserName='TEST-NOTEBOOK\Gast';$taskReadPeer.Shares[0].AccessMode='Guest';$taskReadPeer.Shares[0].MetadataVerified=$true
[DiscoveryCallProbe]::Reset()
$taskKnownRead.Invoke($null,[object[]]@($taskReadPeer.psobject.BaseObject,'192.168.178.21',$taskConfirmed,$taskIdentityReader,$taskSharesReader))|Out-Null
Assert-Discovery ([DiscoveryCallProbe]::Calls -eq 0 -and [DiscoveryCallProbe]::Checks -eq 0 -and $taskReadPeer.MetadataContext -ceq 'PublicPeerPreset' -and -not $taskReadPeer.IdentityVerified) 'Public peer preset skips all default-login IPC/native metadata before selected explicit login'
$taskReadUnknown=New-Object EinfachNetzwerk.DiscoveredComputer
[DiscoveryCallProbe]::Reset()
$taskKnownRead.Invoke($null,[object[]]@($taskReadUnknown.psobject.BaseObject,'',$taskConfirmed,$taskIdentityReader,$taskSharesReader))|Out-Null
Assert-Discovery ([DiscoveryCallProbe]::Calls -eq 0 -and $taskReadUnknown.MetadataContext -ceq 'NoExistingWindowsConnection' -and $taskReadUnknown.Shares.Count -eq 0) 'No existing same-context SMB resource means no implicit native authentication'
$taskReadAlias=New-Object EinfachNetzwerk.DiscoveredComputer
$taskReadAlias.Address='192.168.178.21'
[DiscoveryCallProbe]::Reset()
$taskKnownRead.Invoke($null,[object[]]@($taskReadAlias.psobject.BaseObject,'TEST-NOTEBOOK',$taskConfirmed,$taskIdentityReader,$taskSharesReader))|Out-Null
Assert-Discovery ([DiscoveryCallProbe]::Calls -eq 2 -and [DiscoveryCallProbe]::LastHost -ceq 'TEST-NOTEBOOK' -and $taskReadAlias.MetadataContext -ceq 'ExistingWindowsConnection' -and $taskReadAlias.ShareCode -eq 1272) 'Native metadata preserves exact already-connected host alias and original auth failure'
$taskDisconnected=New-Object EinfachNetzwerk.DiscoveredComputer
[DiscoveryCallProbe]::Reset();[DiscoveryCallProbe]::Connected=$false
$taskKnownRead.Invoke($null,[object[]]@($taskDisconnected.psobject.BaseObject,'TEST-NOTEBOOK',$taskConfirmed,$taskIdentityReader,$taskSharesReader))|Out-Null
Assert-Discovery ([DiscoveryCallProbe]::Calls -eq 0 -and $taskDisconnected.ErrorCode -ceq 'DISCOVERY_EXISTING_CONNECTION_CHANGED') 'Disconnected same-context resource blocks metadata before any remote native call'
[DiscoveryCallProbe]::Reset();[DiscoveryCallProbe]::LoseAfterIdentity=$true
$taskKnownRead.Invoke($null,[object[]]@($taskDisconnected.psobject.BaseObject,'TEST-NOTEBOOK',$taskConfirmed,$taskIdentityReader,$taskSharesReader))|Out-Null
Assert-Discovery ([DiscoveryCallProbe]::Calls -eq 1 -and $taskDisconnected.ErrorCode -ceq 'DISCOVERY_EXISTING_CONNECTION_CHANGED') 'Resource disappearance after identity stops the share API instead of starting another default login'
[DiscoveryCallProbe]::Reset();[DiscoveryCallProbe]::LoseAfterShares=$true
$taskAfterShares=New-Object EinfachNetzwerk.DiscoveredComputer
$taskKnownRead.Invoke($null,[object[]]@($taskAfterShares.psobject.BaseObject,'TEST-NOTEBOOK',$taskConfirmed,$taskIdentityReader,$taskSharesReader))|Out-Null
Assert-Discovery ([DiscoveryCallProbe]::Calls -eq 2 -and $taskAfterShares.ErrorCode -ceq 'DISCOVERY_EXISTING_CONNECTION_CHANGED' -and -not $taskAfterShares.IdentityVerified -and $taskAfterShares.Shares.Count -eq 0) 'Connection disappearance during share metadata does not publish its identity, list or account as current'
$taskAliasParser=$taskType.GetMethod('ExistingAlias',$taskFlags)
foreach($taskPathCase in @(@('\\192.168.178.21\Desktop','192.168.178.21'),@('\\TEST-NOTEBOOK\Desktop','TEST-NOTEBOOK'),@('\\TEST-NOTEBOOK.fritz.box\Desktop','TEST-NOTEBOOK.fritz.box'))){
    Assert-Discovery ([string]$taskAliasParser.Invoke($null,[object[]]@($taskPathCase[0])) -ceq $taskPathCase[1]) 'Only exact connected UNC server alias is retained for metadata context'
}
foreach($taskInvalidPath in @('192.168.178.21','\\192.168.178.021\Desktop','\\TEST-NOTEBOOK\Desktop\File','\\TEST-NOTEBOOK\','\\OTHER..PC\Desktop','\\::1\Desktop')){
    Assert-Discovery ([string]$taskAliasParser.Invoke($null,[object[]]@($taskInvalidPath)) -ceq '') 'Malformed, alias-ambiguous and extra-path connected resources cannot authorize discovery queries'
}
$taskProvider=$taskType.GetMethod('ConfirmedSmbProvider',$taskFlags)
Assert-Discovery ([bool]$taskProvider.Invoke($null,[object[]]@([uint32]1,'Microsoft Windows Network','Microsoft Windows Network'))) 'Already connected resource must belong to the locally identified Microsoft SMB provider'
foreach($taskProviderCase in @(@([uint32]1,'Web Client Network','Microsoft Windows Network'),@([uint32]1,'OtherProvider','Microsoft Windows Network'),@([uint32]2,'Microsoft Windows Network','Microsoft Windows Network'),@([uint32]1,'','Microsoft Windows Network'),@([uint32]1,'Microsoft Windows Network',''))){
    Assert-Discovery (-not [bool]$taskProvider.Invoke($null,[object[]]$taskProviderCase)) 'Non-SMB provider, print and unknown-provider connection cannot authorize native SMB metadata'
}
$taskFunctionType=[Func[object]].GetGenericTypeDefinition().MakeGenericType($taskNativeResult)
$taskSleep=[Threading.Thread].GetMethod('Sleep',[type[]]@([int]))
$taskNewMethod=[Linq.Expressions.Expression].GetMethod('New',[type[]]@([Type])); $taskNew=$taskNewMethod.Invoke($null,[object[]]@($taskNativeResult)); $taskBody=[Linq.Expressions.Expression]::Block([Linq.Expressions.Expression]::Call($taskSleep,[Linq.Expressions.Expression]::Constant([int]100)),$taskNew)
$taskLambda=[Linq.Expressions.Expression]::Lambda($taskFunctionType,$taskBody,[Linq.Expressions.ParameterExpression[]]@()).Compile()
$taskBounded=$taskType.GetMethod('Bounded',$taskFlags)
$taskTimer=[Diagnostics.Stopwatch]::StartNew()
$taskLate=$taskBounded.Invoke($null,[object[]]@($taskLambda,[int]20,[Threading.CancellationToken]::None))
$taskTimer.Stop()
Assert-Discovery ($taskLate.ErrorCode -ceq 'DISCOVERY_TIMEOUT' -and $taskTimer.ElapsedMilliseconds -lt 500) 'Native metadata caller deadline is bounded'
[Threading.Thread]::Sleep(150)
Assert-Discovery ($taskLate.ErrorCode -ceq 'DISCOVERY_TIMEOUT') 'Late native success never replaces published timeout'
$taskCancel=New-Object Threading.CancellationTokenSource
$taskCancel.Cancel()
$taskCancelled=$taskBounded.Invoke($null,[object[]]@($taskLambda,[int]20,$taskCancel.Token))
Assert-Discovery ($taskCancelled.ErrorCode -ceq 'DISCOVERY_CANCELLED') 'Cancelled metadata invokes no Windows operation'
$taskNoScan=[EinfachNetzwerk.NetworkDiscovery]::Scan($null,$taskCancel.Token)
Assert-Discovery ($taskNoScan.Cancelled -and $taskNoScan.CandidateCount -eq 0 -and $taskNoScan.Computers.Count -eq 0) 'Cancelled discovery returns before network inventory and probes'
$taskCancel.Dispose()
$taskSlots=$taskType.GetField('NativeSlots',$taskFlags).GetValue($null)
try{
    for($taskSlot=0;$taskSlot -lt 8;$taskSlot++){Assert-Discovery ($taskSlots.Wait(0)) 'Native slot released after timed-out operation actually finishes'}
    $taskBusy=$taskBounded.Invoke($null,[object[]]@($taskLambda,[int]20,[Threading.CancellationToken]::None))
    Assert-Discovery ($taskBusy.ErrorCode -ceq 'DISCOVERY_NATIVE_BUSY') 'Outstanding native metadata calls cannot grow beyond finite slot budget'
}finally{$taskSlots.Release(8)|Out-Null}
if($Live){
    $taskLiveTimer=[Diagnostics.Stopwatch]::StartNew()
    $taskLiveResult=[EinfachNetzwerk.NetworkDiscovery]::Scan($null,[Threading.CancellationToken]::None)
    $taskLiveTimer.Stop()
    Assert-Discovery ($taskLiveTimer.ElapsedMilliseconds -lt 68000) 'Live private LAN scan obeys total caller deadline'
    Assert-Discovery ($taskLiveResult.CandidateCount -le 1024 -and $taskLiveResult.CompletedCount -le $taskLiveResult.CandidateCount) 'Live port progress counts actual planned/completed private hosts'
    $taskNetworks=[EinfachNetzwerk.NativeHomeNetworks]::ReadJson()|ConvertFrom-Json
    foreach($taskComputer in $taskLiveResult.Computers){
        $taskMatch=@($taskNetworks|Where-Object {$_.Id -eq $taskComputer.AdapterId -and [bool]$taskEligible.Invoke($null,[object[]]@($taskComputer.Address,$_.Subnet))})
        Assert-Discovery ($taskMatch.Count -eq 1 -and $taskComputer.Address -notin @($taskNetworks|ForEach-Object{$_.Address})) 'Live discovered endpoint belongs to confirmed exact private physical LAN'
        foreach($taskShare in $taskComputer.Shares){
            Assert-Discovery ([bool]$taskShareName.Invoke($null,[object[]]@($taskShare.Name))) 'Live result offers only ordinary compatible disk shares'
            if($taskShare.MetadataVerified){
                Assert-Discovery ((Test-Metadata $taskShare.Remark $taskComputer.ComputerName).Valid) 'Live suggested account derives from exact public preset'
            }
        }
    }
    $taskEvidence=Join-Path $PSScriptRoot 'host-qa\network-discovery-live.json'
    [IO.File]::WriteAllText($taskEvidence,($taskLiveResult|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($true)))
    Write-Output ('Readonly LAN scan: '+$taskLiveResult.CompletedCount+'/'+$taskLiveResult.CandidateCount+' candidates; '+$taskLiveResult.Computers.Count+' SMB hosts; '+$taskLiveTimer.ElapsedMilliseconds+' ms; evidence '+$taskEvidence)
}
Write-Output ('Network discovery tests: '+$script:Passed+' passed; no Windows settings or credentials changed.')
