param([string]$AssemblyPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($PSVersionTable.PSEdition -eq 'Core') {
    $taskArguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if($AssemblyPath){$taskArguments+=@('-AssemblyPath',$AssemblyPath)}
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @taskArguments
    exit $LASTEXITCODE
}
if(-not $AssemblyPath){
    $taskOutput=Join-Path $PSScriptRoot 'host-qa\native-home-check.dll'
    [IO.Directory]::CreateDirectory((Split-Path $taskOutput)) | Out-Null
    & (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:library /langversion:5 /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:'+$taskOutput) (Join-Path $PSScriptRoot '..\src\NativeHomeNetworks.cs')
    if($LASTEXITCODE -ne 0){throw 'Native network helper compile failed.'}
    $AssemblyPath=$taskOutput
}
[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path) | Out-Null
$script:Passed=0
function Assert-NativeNetwork([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++;Write-Output ('PASS: '+$Message)}
$taskFlags=[Reflection.BindingFlags]'Static,NonPublic'
$taskType=[EinfachNetzwerk.NativeHomeNetworks]
$taskPrivate=$taskType.GetMethod('PrivateIPv4',$taskFlags)
$taskPrefix=$taskType.GetMethod('PrefixLength',$taskFlags)
$taskSubnet=$taskType.GetMethod('Subnet',$taskFlags)
foreach($taskAddress in @('10.0.0.1','10.255.255.254','172.16.0.1','172.31.255.254','192.168.0.1','192.168.255.254')){
    Assert-NativeNetwork ([bool]$taskPrivate.Invoke($null,@([Net.IPAddress]::Parse($taskAddress)))) ('RFC1918 LAN address accepted: '+$taskAddress)
}
foreach($taskAddress in @('9.255.255.255','11.0.0.1','172.15.255.254','172.32.0.1','192.167.255.255','192.169.0.1','127.0.0.1','169.254.0.1','224.0.0.1','0.0.0.0','::1','fd00::1')){
    Assert-NativeNetwork (-not [bool]$taskPrivate.Invoke($null,@([Net.IPAddress]::Parse($taskAddress)))) ('Non-home-network address excluded: '+$taskAddress)
}
foreach($taskCase in @(@('255.255.255.0',24),@('255.255.0.0',16),@('255.240.0.0',12),@('255.0.0.0',8),@('255.255.255.252',30),@('255.255.255.255',32),@('255.0.255.0',-1),@('255.255.127.0',-1))){
    Assert-NativeNetwork ([int]$taskPrefix.Invoke($null,@([Net.IPAddress]::Parse([string]$taskCase[0]))) -eq [int]$taskCase[1]) ('Prefix parser checks contiguous mask: '+$taskCase[0])
}
Assert-NativeNetwork ([string]$taskSubnet.Invoke($null,@([Net.IPAddress]::Parse('192.168.178.24'),24)) -ceq '192.168.178.0/24') 'Local subnet derived from source IPv4 and mask'
Assert-NativeNetwork ([string]$taskSubnet.Invoke($null,@([Net.IPAddress]::Parse('172.27.5.4'),12)) -ceq '172.16.0.0/12') 'Subnet parser handles byte boundary masks'
$taskProfile=$taskType.GetMethod('EligibleProfile',$taskFlags)
Assert-NativeNetwork ([bool]$taskProfile.Invoke($null,@($true,0,1))) 'Only connected non-domain private NLM profile is eligible'
foreach($taskProfileCase in @(@($false,0,1),@($true,0,0),@($true,0,2),@($true,0,-1),@($true,1,1),@($true,2,1))){
    Assert-NativeNetwork (-not [bool]$taskProfile.Invoke($null,$taskProfileCase)) 'Public, unknown, domain or disconnected NLM profile fails closed'
}
$taskAddressRule=$taskType.GetMethod('EligibleAddress',$taskFlags)
Assert-NativeNetwork ([bool]$taskAddressRule.Invoke($null,@([Net.IPAddress]::Parse('192.168.178.24'),24,[Net.IPAddress]::Parse('192.168.178.1')))) 'Private source and gateway on exact subnet are eligible'
foreach($taskSourceCase in @(@('192.168.178.24',15,'192.168.178.1'),@('172.27.5.4',11,'172.27.5.1'),@('10.0.5.4',7,'10.0.5.1'),@('192.168.178.24',31,'192.168.178.25'),@('192.168.178.24',32,'192.168.178.24'),@('192.168.178.24',24,'192.168.179.1'),@('192.168.178.24',24,'8.8.8.8'))){
    Assert-NativeNetwork (-not [bool]$taskAddressRule.Invoke($null,@([Net.IPAddress]::Parse([string]$taskSourceCase[0]),[int]$taskSourceCase[1],[Net.IPAddress]::Parse([string]$taskSourceCase[2])))) 'Overbroad or point-to-point mask, foreign subnet or public gateway fails closed'
}
$taskHardwareRule=$taskType.GetMethod('EligiblePhysical',$taskFlags)
$taskExpectedGuid=[Guid]::NewGuid()
$taskBaseline=[object[]]@($taskExpectedGuid,$taskExpectedGuid,16,16,[uint32]6,[uint32]0,[uint32]14,[byte]1,[uint32]1)
Assert-NativeNetwork ([bool]$taskHardwareRule.Invoke($null,$taskBaseline)) 'Matching active native hardware Ethernet interface is eligible'
foreach($taskHardwareCase in @(@(0,[Guid]::NewGuid()),@(2,17),@(4,[uint32]131),@(5,[uint32]1),@(6,[uint32]10),@(7,[byte]0),@(7,[byte]3),@(7,[byte]17),@(7,[byte]33),@(7,[byte]129),@(8,[uint32]2))){
    $taskModified=$taskBaseline.Clone();$taskModified[[int]$taskHardwareCase[0]]=$taskHardwareCase[1]
    Assert-NativeNetwork (-not [bool]$taskHardwareRule.Invoke($null,$taskModified)) 'GUID/index mismatch, virtual/tunnel media, filter/endpoint or inactive adapter fails closed'
}
$taskTimer=[Diagnostics.Stopwatch]::StartNew()
$taskNetworks=$taskType::ReadJson() | ConvertFrom-Json
$taskTimer.Stop()
Assert-NativeNetwork ($taskTimer.ElapsedMilliseconds -lt 10000) 'Native readonly inventory does not wait on the broken WMI/CIM provider'
foreach($taskNetwork in $taskNetworks){
    Assert-NativeNetwork ($taskNetwork.Category -ceq 'Private' -and $taskNetwork.Id -gt 0 -and [bool]$taskPrivate.Invoke($null,@([Net.IPAddress]::Parse($taskNetwork.Address)))) 'Returned candidate has a confirmed private NLM category and LAN IPv4'
    $taskParts=$taskNetwork.Subnet.Split('/')
    [int]$taskPrefixLength=$taskParts[1]
    Assert-NativeNetwork ($taskPrefixLength -ge 8 -and $taskPrefixLength -le 30 -and [bool]$taskPrivate.Invoke($null,@([Net.IPAddress]::Parse($taskNetwork.Gateway))) -and [string]$taskSubnet.Invoke($null,@([Net.IPAddress]::Parse($taskNetwork.Gateway),$taskPrefixLength)) -ceq $taskNetwork.Subnet) 'Returned private gateway lies in the exact source subnet with a usable LAN mask'
    $taskAdapter=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {$_.GetIPProperties().GetIPv4Properties().Index -eq $taskNetwork.Id})[0]
    $taskPhysical=$taskType.GetMethod('IsPhysicalAdapter',$taskFlags)
    Assert-NativeNetwork ([bool]$taskPhysical.Invoke($null,@([int]$taskNetwork.Id,[Guid]$taskAdapter.Id))) 'Returned candidate matches the native physical adapter GUID, hardware flag and active Ethernet/WLAN medium'
}
Write-Output ('Native home network tests: '+$script:Passed+' passed; readonly Windows inventory '+$taskTimer.ElapsedMilliseconds+' ms; no network settings changed.')
