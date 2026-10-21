param([string]$HelperPath=(Join-Path $PSScriptRoot '..\src\ServiceHealthWorker.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Isolated service doubles: never start, stop, configure or rebuild real services.
$helper=[IO.File]::ReadAllText((Resolve-Path $HelperPath),[Text.Encoding]::UTF8)
$worker=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'),[Text.Encoding]::UTF8)
$tokens=$null; $errors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseInput($helper,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw ('Service helper syntax: '+(($errors | ForEach-Object {$_.Message}) -join '; ')) }
$workerAst=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tokens,[ref]$errors)
foreach ($name in @('Get-Value','Add-Check','Complete-WorkStep','Set-FailureDetails','Hide-FailureSecrets','Advanced-Repair')) {
    $function=$workerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $function.Extent.Text
}
Invoke-Expression $helper
$networkFunction=$helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ServiceHealthNetworks'},$true)
Invoke-Expression $networkFunction.Extent.Text.Replace('Get-ServiceHealthNetworks','Get-NativeNetworkShapeFixture').Replace('[EinfachNetzwerk.NativeHomeNetworks]::ReadJson()','(Get-FixtureNetworkJson)')
$native=[regex]::Match($helper,"Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@",[Text.RegularExpressions.RegexOptions]::Singleline)
$nativeFixture=@'
namespace EinfachNetzwerkServiceIsolatedTest {
 public sealed class StartTransactionOutcome {
  public uint Start;public bool Delayed;public int StartCalls,DelayedCalls,ErrorCode;public string Error="";
 }
 public static class StartTransactionFixture {
  public static StartTransactionOutcome Run(string scenario) {
   bool clear=scenario=="ClearThenStartFail" || scenario=="ClearAppliedThenFail";
   var before=new ServiceHealthSnapshot {Exists=true,StartValue=clear?2u:3u,Delayed=clear};
   var actual=new ServiceHealthSnapshot {Exists=true,StartValue=before.StartValue,Delayed=before.Delayed};
   var result=new StartTransactionOutcome();bool fault=false;int readAfterFault=0;
   System.Func<ServiceHealthSnapshot> read=delegate {
    if(scenario=="ForeignBeforeStart") {actual.StartValue=4;actual.Delayed=false;}
    if(scenario=="ForeignDuringRollback" && fault && ++readAfterFault==2) {actual.StartValue=4;actual.Delayed=false;}
    return new ServiceHealthSnapshot {Exists=true,StartValue=actual.StartValue,Delayed=actual.Delayed};
   };
   System.Action<uint> start=delegate(uint value) {
    result.StartCalls++;
    if(scenario=="ClearThenStartFail" && result.StartCalls==1) {fault=true;throw new System.ComponentModel.Win32Exception(5,"Original Win32 5");}
    if(scenario=="RollbackFails" && result.StartCalls==2) throw new System.ComponentModel.Win32Exception(32,"Rollback Win32 32");
    actual.StartValue=value;
   };
   System.Action<bool> delay=delegate(bool value) {
    result.DelayedCalls++;
    if(result.DelayedCalls==1 && scenario!="Success") {
     fault=true;
     if(scenario=="ForeignAfterStart") {actual.StartValue=4;actual.Delayed=false;}
     if(scenario=="DelayedAppliedThenFail" || scenario=="ClearAppliedThenFail") actual.Delayed=value;
     if(scenario!="ClearThenStartFail") throw new System.ComponentModel.Win32Exception(5,"Original Win32 5");
    }
    actual.Delayed=value;
   };
   try {NativeServiceHealth.ApplyStartOwned(before,clear?3u:2u,clear?false:true,read,start,delay);}
   catch(System.Exception ex) {
    result.Error=ex.ToString();System.Exception next=ex;
    while(next!=null) {var native=next as System.ComponentModel.Win32Exception;if(native!=null) {result.ErrorCode=native.NativeErrorCode;break;}next=next.InnerException;}
   }
   result.Start=actual.StartValue;result.Delayed=actual.Delayed;return result;
  }
 }
}
'@
Add-Type -TypeDefinition ($native.Groups[1].Value.Replace('namespace EinfachNetzwerk {','namespace EinfachNetzwerkServiceIsolatedTest {')+[Environment]::NewLine+$nativeFixture)
$testRoot=Join-Path $env:TEMP ('EinfachNetzwerk-servicetest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot '.isolated-test'),'Isolated service backend test')
$script:LedgerRoot=$testRoot; $script:AppMark='EinfachNetzwerk-v1'; $script:Count=0
function Assert([bool]$Test,[string]$Message) { if (-not $Test) { throw $Message }; $script:Count++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert $failed $Message }
function Reset-Test {
    $script:Checks=New-Object 'System.Collections.Generic.List[object]'
    $script:Result=[ordered]@{Success=$false;Message='';ServiceHealthVerified=$false;ServiceRepairAvailable=$false;ServiceBackupPath='';ConnectionVerified=$false;NativeConnectionVerified=$false;ErrorCode='';ErrorType='';ErrorStackTrace='';RestartRequired=$false;Networks=@();Address=''}
    $script:Services=@{}
    foreach ($name in @(Get-ServiceHealthNames)) { $script:Services[$name]=[pscustomobject]@{Name=$name;Exists=$true;State='Running';StateValue=4;StartMode='Auto';StartValue=2;Delayed=$false;Win32ExitCode=0;ServiceSpecificExitCode=0;Dependencies=@()} }
    $script:Services.fdPHost.StartValue=3; $script:Services.fdPHost.StartMode='Manual'
    $script:Services.RpcSs=[pscustomobject]@{Name='RpcSs';Exists=$true;State='Running';StateValue=4;StartMode='Auto';StartValue=2;Delayed=$false;Win32ExitCode=0;ServiceSpecificExitCode=0;Dependencies=@()}
    $script:Starts=@();$script:Sets=@();$script:Writes=0;$script:PortReady=$true;$script:Managed=$false;$script:Admin=$true;$script:StartError=0;$script:ConfigError=$false;$script:AdvancedCalls=0;$script:LateStartFailure=$false;$script:MetadataRepairs=0;$script:MetadataRestoreCalls=0;$script:SignatureValid=$true;$script:MetadataPartialFailure=$false
    $script:Metadata=[pscustomobject]@{ParametersKeyExists=$true;Values=@([pscustomobject]@{Name='ServiceDll';Exists=$true;Kind='ExpandString';Text=(Join-Path ([Environment]::GetFolderPath('System')) 'srvsvc.dll');Strings=$null;Number=0;Binary=$null},[pscustomobject]@{Name='ServiceDllUnloadOnStop';Exists=$true;Kind='DWord';Text=$null;Strings=$null;Number=1;Binary=$null})}
    $script:Nets=@([pscustomobject]@{Id=17;Name='Ethernet';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private';Gateway='192.168.178.1'})
    $script:Request=[pscustomobject]@{Action='RepairServices';AdapterId=0;DryRun=$false;AllowAdvancedRepair=$false;OriginalUserSid='test';ProtectedPassword='';BackupPath='ignored-untrusted.json'}
    $script:Secret=$null
    $path=Get-ServiceHealthJournalPath; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
function Get-ServiceHealthNetworks { return $script:Nets }
function Get-FixtureNetworkJson { return (ConvertTo-Json -InputObject @($script:Nets) -Depth 5 -Compress) }
function Get-HomeNetworks { throw 'The isolated service helper must never require WMI-backed home network providers' }
function Get-ServiceNativeSnapshot([string]$Name) {
    if ($Name -notin @($script:Services.Keys)) { return [pscustomobject]@{Name=$Name;Exists=$false;State='Missing';StateValue=0;StartMode='Unknown';StartValue=0;Delayed=$false;Win32ExitCode=1060;ServiceSpecificExitCode=0;Dependencies=@()} }
    return $script:Services[$Name]
}
function Set-ServiceNativeStart([string]$Name,[int]$StartValue,[bool]$Delayed) {
    if ($Name -notin @(Get-ServiceHealthNames)) { throw 'Foreign service mutation' }
    $script:Sets+=@($Name + ':' + $StartValue + ':' + $Delayed)
    if ($script:ConfigError) { throw (New-Object ComponentModel.Win32Exception(5,'Isolated config failure')) }
    $script:Services[$Name].StartValue=$StartValue; $script:Services[$Name].Delayed=$Delayed
    $script:Services[$Name].StartMode=@{2='Auto';3='Manual';4='Disabled'}[$StartValue]
}
function Start-ServiceNative([string]$Name) {
    if ($Name -notin @(Get-ServiceHealthNames)) { throw 'Foreign service start' }
    $script:Starts+=@($Name)
    if ($script:StartError -ne 0) { throw (New-Object ComponentModel.Win32Exception($script:StartError,('Isolated start failure: '+$script:StartError))) }
    if (-not $script:LateStartFailure) { $script:Services[$Name].State='Running';$script:Services[$Name].StateValue=4;$script:Services[$Name].Win32ExitCode=0 }
}
function Test-ServiceHealthPort { return $script:PortReady }
function Write-Phase { param($Text) }
function Is-Administrator { return $script:Admin }
function Get-ServiceRepairUserSid { return 'test' }
function Assert-PersonalPolicyChanges { if ($script:Managed) { throw 'Managed machine' } }
function Assert-LedgerProtection {}
function Assert-NoReparse {}
function Initialize-LedgerDirectory {}
function Write-JsonAtomic([string]$Path,$Object) { $script:Writes++; [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Object -Depth 12),[Text.Encoding]::UTF8) }
function Repair-RequiredServiceConfigurations { $script:AdvancedCalls++ }
function Get-ServerServiceMetadataJson { return (ConvertTo-Json -InputObject $script:Metadata -Depth 10 -Compress) }
function Get-ServerServiceOriginalPlan { return [pscustomobject]@{Name='LanmanServer';DllPath=(Join-Path ([Environment]::GetFolderPath('System')) 'srvsvc.dll');RegistryValues=@([pscustomobject]@{Path='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters';Name='ServiceDll';Kind='ExpandString';Value=(Join-Path ([Environment]::GetFolderPath('System')) 'srvsvc.dll')},[pscustomobject]@{Path='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters';Name='ServiceDllUnloadOnStop';Kind='DWord';Value=1})} }
function Assert-ServiceOriginalFiles { if (-not $script:SignatureValid) { throw 'Isolated untrusted Windows original file' } }
function Repair-ServerServiceMetadata {
    $script:MetadataRepairs++
    $expected=Get-ServiceMetadataExpected (Get-ServerServiceMetadataJson) (Get-ServerServiceOriginalPlan)
    if ($script:MetadataPartialFailure) { $partial=$expected | ConvertFrom-Json; $script:Metadata.Values[0]=$partial.Values[0]; throw 'Isolated partial metadata write failure' }
    $script:Metadata=$expected | ConvertFrom-Json
}
function Restore-ServerServiceMetadata([string]$Before,[string]$Expected) {
    $script:MetadataRestoreCalls++; $beforeData=$Before | ConvertFrom-Json; $expectedData=$Expected | ConvertFrom-Json; $restored=@();$preserved=@()
    foreach ($name in @('ServiceDll','ServiceDllUnloadOnStop')) {
        $actual=@($script:Metadata.Values | Where-Object {$_.Name -eq $name})[0]
        $desired=@($beforeData.Values | Where-Object {$_.Name -eq $name})[0]
        $owned=@($expectedData.Values | Where-Object {$_.Name -eq $name})[0]
        if (-not (Test-ServiceMetadataValueSame $actual $owned)) { $preserved+=@($name); continue }
        if (Test-ServiceMetadataValueSame $actual $desired) { continue }
        $index=0; if ($name -eq 'ServiceDllUnloadOnStop') { $index=1 }
        $script:Metadata.Values[$index]=$desired; $restored+=@($name)
    }
    return [pscustomobject]@{Restored=$restored;Preserved=$preserved;ParametersKeyRemoved=$false}
}
function Get-CimInstance { throw 'The isolated service helper must never require WMI' }
function Stop-Service { throw 'Never stop a running service' }
try {
    Reset-Test
    $shape=@(Get-NativeNetworkShapeFixture)
    Assert ($shape.Count -eq 1 -and $shape[0] -isnot [Array] -and $shape[0].Id -eq 17) 'Native PS5 JSON network wrapper produces nested Networks arrays.'
    $script:Nets=@($script:Nets[0],$script:Nets[0].PSObject.Copy()); $script:Nets[1].Id=18
    $shape=@(Get-NativeNetworkShapeFixture)
    Assert ($shape.Count -eq 2 -and $shape[0] -isnot [Array] -and $shape[1].Id -eq 18) 'Native PS5 JSON network wrapper hides multiple adapters.'
    $script:Nets=@(); $shape=@(Get-NativeNetworkShapeFixture)
    Assert ($shape.Count -eq 0) 'Native PS5 empty network wrapper produces a fake candidate.'
    Reset-Test
    Invoke-InspectLocalServices $script:Request
    Assert ($script:Result.Success -and $script:Result.ServiceHealthVerified) 'Healthy SCM services/port not confirmed.'
    Assert (-not $script:Result.ConnectionVerified -and -not $script:Result.NativeConnectionVerified) 'Local health pretended to verify a remote connection.'
    Assert ($script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0 -and $script:Writes -eq 0) 'Inspection changed services.'
    Reset-Test;$script:Services.LanmanServer.State='Stopped';$script:PortReady=$false
    Invoke-InspectLocalServices $script:Request
    Assert (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'Win32: 2114') 'Stopped Server service did not report original 2114 condition.'
    Assert (@($script:Checks | Where-Object {$_.Name -eq 'LanmanServer' -and $_.Fixable}).Count -eq 1) 'Stopped server service has no repair guidance.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; Invoke-RepairLocalServices $script:Request
    Assert ($script:Result.Success -and $script:Result.ServiceHealthVerified) 'Stopped automatic Server service was not really verified after start.'
    Assert ($script:Starts.Count -eq 1 -and $script:Starts[0] -eq 'LanmanServer') 'Repair restarted an already running service.'
    Assert ($script:Sets.Count -eq 0 -and $script:Writes -eq 0) 'Start-only repair changed unrelated start types.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Services.LanmanServer.StartValue=4; $script:Services.LanmanServer.StartMode='Disabled'
    Invoke-RepairLocalServices $script:Request
    Assert ($script:Result.Success -and $script:Services.LanmanServer.StartValue -eq 2) 'Disabled Server service was not enabled after snapshot.'
    Assert ($script:Result.ServiceRepairAvailable -and $script:Result.ServiceBackupPath -eq (Get-ServiceHealthJournalPath)) 'Own fixed start-type backup was not published.'
    $saved=Read-ServiceHealthJournal
    Assert ($saved.Changes[0].Before.StartValue -eq 4 -and $saved.Changes[0].Expected.StartValue -eq 2 -and $saved.Status -eq 'Committed') 'Journal lost original disabled start type.'
    Invoke-RestoreLocalServices $script:Request
    Assert ($script:Services.LanmanServer.StartValue -eq 4 -and $script:Services.LanmanServer.State -eq 'Running') 'Restore stopped a running service instead of restoring its start type only.'
    Assert (-not $script:Result.ServiceRepairAvailable) 'Restored journal still advertises active changes.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Services.LanmanServer.StartValue=4; $script:Services.LanmanServer.StartMode='Disabled'; $script:StartError=1068
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Failed service start was accepted.'
    Assert ($script:Services.LanmanServer.StartValue -eq 4) 'Failed start did not roll back its own start-type change.'
    Assert ($script:Services.LanmanWorkstation.State -eq 'Running' -and $script:Services.RpcSs.State -eq 'Running') 'Failed repair affected existing running services.'
    Assert (@($script:Checks | Where-Object {$_.Code -eq 'Win32: 1068'}).Count -eq 1) 'Original dependency failure code was hidden.'
    foreach ($code in @(1058,1068,1069,1053,1072,1066,2)) {
        Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:StartError=$code
        Assert-Throws { Invoke-RepairLocalServices $script:Request } ('Error '+$code+' ignored.')
        Assert (@($script:Checks | Where-Object {$_.Code -eq ('Win32: '+$code)}).Count -gt 0) ('Original error code '+$code+' not exported.')
        if ($code -eq 1072) { Assert $script:Result.RestartRequired 'Marked-for-delete code did not request a manual restart.' }
    }
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Services.LanmanServer.Dependencies=@('MissingDependency','RpcSs','+NetworkGroup'); $script:StartError=1068
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Missing dependency ignored.'
    Assert (@($script:Checks | Where-Object {$_.Code -eq 'Win32: 1060' -and $_.Name -eq 'Abhängigkeit von LanmanServer'}).Count -gt 0) 'Missing dependency not identified.'
    Assert ($script:Sets.Count -eq 0 -and $script:Starts.Count -eq 1) 'Dependency diagnostic changed a foreign service.'
    Reset-Test; $script:Services.LanmanServer.Exists=$false
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Missing core service rebuilt without authorization.'
    Assert ($script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0 -and $script:AdvancedCalls -eq 0) 'Missing service caused an unauthorized mutation.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:PortReady=$false
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Closed SMB port accepted as success.'
    Assert (-not $script:Result.ServiceHealthVerified -and $script:Services.LanmanServer.State -eq 'Running') 'Port failure stopped a now running service or claimed healthy.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:LateStartFailure=$true
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Unconfirmed Start-Service call accepted.'
    Assert (-not $script:Result.ServiceHealthVerified) 'A start request was treated as proof of running.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Request.DryRun=$true
    Invoke-RepairLocalServices $script:Request
    Assert ($script:Result.Success -and $script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0 -and $script:Writes -eq 0 -and -not $script:Result.ServiceHealthVerified) 'Dry run mutated or pretended to verify services.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Admin=$false
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Unelevated repair allowed.'
    Assert ($script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0) 'Unelevated repair changed services.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Managed=$true
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Managed-PC policy bypass allowed.'
    Assert ($script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0) 'Policy refusal changed services.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Request.OriginalUserSid='different-account'
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Repair elevated under a different Windows account.'
    Assert ($script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0 -and $script:Writes -eq 0) 'Cross-account refusal still changed services.'
    Reset-Test; $script:Nets[0].Category='Public'; $script:Services.LanmanServer.State='Stopped'
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Public network allowed.'
    Reset-Test; $script:Nets=@($script:Nets[0],$script:Nets[0].PSObject.Copy()); $script:Nets[1].Id=18
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Ambiguous physical private network accepted.'
    $script:Request.AdapterId=17; $network=Resolve-ServiceHealthNetwork $script:Request
    Assert ($network.Id -eq 17) 'Explicit valid private adapter rejected.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Services.LanmanServer.StartValue=4; $script:Services.LanmanServer.StartMode='Disabled'
    Invoke-RepairLocalServices $script:Request; $script:Services.LanmanServer.StartValue=3; $script:Services.LanmanServer.StartMode='Manual'
    Invoke-RestoreLocalServices $script:Request
    Assert ($script:Services.LanmanServer.StartValue -eq 3 -and $script:Services.LanmanServer.State -eq 'Running') 'Restore overwrote external start-type change or stopped service.'
    Assert (@($script:Checks | Where-Object {$_.Code -eq 'SERVICE_EXTERNAL_CHANGE'}).Count -eq 1) 'External config preservation not reported.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Services.LanmanServer.StartValue=4; $script:Services.LanmanServer.StartMode='Disabled'; Invoke-RepairLocalServices $script:Request
    $journal=Read-ServiceHealthJournal; $journal.Changes[0].Name='RpcSs'; Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal
    Assert-Throws { Invoke-RestoreLocalServices $script:Request } 'Foreign service injected into protected journal accepted.'
    Reset-Test; Invoke-RepairLocalServices $script:Request
    Assert ($script:Starts.Count -eq 0 -and $script:Sets.Count -eq 0 -and $script:Writes -eq 0) 'Already healthy preflight changed settings.'
    Assert (-not $helper.Contains('Stop-Service ') -and -not $helper.Contains('ControlService(') -and -not $helper.Contains('Set-Smb') -and -not $helper.Contains('Set-NetFirewall')) 'Service-only helper contains blanket security or stop mutations.'
    # Native library compilation and its hard-coded write allowlist.
    Assert-Throws { [EinfachNetzwerkServiceIsolatedTest.NativeServiceHealth]::SetStart('RpcSs',2,$false) } 'Native starttype allowlist does not reject RPC.'
    Assert-Throws { [EinfachNetzwerkServiceIsolatedTest.NativeServiceHealth]::EnsureRunning('RpcSs',20000) } 'Native start allowlist does not reject RPC.'
    Assert-Throws { [EinfachNetzwerkServiceIsolatedTest.NativeServiceHealth]::SetStart('LanmanServer',0,$false) } 'Native layer accepts boot-driver starttype.'
    Assert-Throws { [EinfachNetzwerkServiceIsolatedTest.NativeServiceHealth]::SetStart('LanmanServer',3,$true) } 'Invalid delayed manual config accepted.'
    foreach ($scenario in @('DelayedFails','DelayedAppliedThenFail','ClearThenStartFail','ClearAppliedThenFail')) {
        $transaction=[EinfachNetzwerkServiceIsolatedTest.StartTransactionFixture]::Run($scenario)
        $start=3; $delayed=$false; if ($scenario.StartsWith('Clear')) {$start=2;$delayed=$true}
        Assert ($transaction.Start -eq $start -and $transaction.Delayed -eq $delayed) ($scenario+': partial own native SCM config was left behind.')
        Assert ($transaction.ErrorCode -eq 5) ($scenario+': original Win32 error was replaced by rollback result.')
    }
    $transaction=[EinfachNetzwerkServiceIsolatedTest.StartTransactionFixture]::Run('ForeignAfterStart')
    Assert ($transaction.Start -eq 4 -and -not $transaction.Delayed -and $transaction.StartCalls -eq 1) 'Native partial rollback overwrote a foreign pair.'
    $transaction=[EinfachNetzwerkServiceIsolatedTest.StartTransactionFixture]::Run('ForeignBeforeStart')
    Assert ($transaction.Start -eq 4 -and $transaction.StartCalls -eq 0 -and $transaction.DelayedCalls -eq 0) 'Native transaction mutated after its original snapshot changed.'
    $transaction=[EinfachNetzwerkServiceIsolatedTest.StartTransactionFixture]::Run('ForeignDuringRollback')
    Assert ($transaction.Start -eq 4 -and $transaction.StartCalls -eq 1) 'Native rollback failed to recheck an intervening foreign edit.'
    $transaction=[EinfachNetzwerkServiceIsolatedTest.StartTransactionFixture]::Run('RollbackFails')
    Assert ($transaction.ErrorCode -eq 5 -and $transaction.Error.Contains('Rollback Win32 32') -and $transaction.Error.Contains('Original Win32 5')) 'Native partial rollback failure lost the original error or rollback error.'
    $transaction=[EinfachNetzwerkServiceIsolatedTest.StartTransactionFixture]::Run('Success')
    Assert ($transaction.Start -eq 2 -and $transaction.Delayed -and $transaction.ErrorCode -eq 0 -and $transaction.StartCalls -eq 1 -and $transaction.DelayedCalls -eq 1) 'Native start transaction did not verify its complete successful pair.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Services.LanmanServer.Win32ExitCode=2; $script:Metadata.Values[0].Exists=$false; $script:Metadata.Values[1].Exists=$false
    Invoke-InspectLocalServices $script:Request
    Assert ($script:Result.ErrorCode -eq 'Win32: 2' -and @($script:Checks | Where-Object {$_.Code -eq 'SERVICE_SERVER_METADATA_INVALID'}).Count -eq 1) 'Missing ServiceDll rootcause or original SCM code2 lost.'
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Metadata replaced without explicit advanced consent.'
    Assert ($script:MetadataRepairs -eq 0 -and $script:Starts.Count -eq 0) 'No-consent metadata repair wrote settings.'
    $script:Request.AllowAdvancedRepair=$true
    # A fresh worker result, as used for each application action.
    $script:Checks.Clear(); $script:Result.ErrorCode=''; $script:Result.ErrorType=''
    Invoke-RepairLocalServices $script:Request
    Assert ($script:Result.Success -and $script:MetadataRepairs -eq 1 -and $script:Services.LanmanServer.State -eq 'Running') 'Confirmed missing ServiceDll was not repaired before Server start.'
    Assert ($script:Result.ServiceRepairAvailable -and @($script:Checks | Where-Object {$_.State -eq 'error'}).Count -eq 0 -and [string]::IsNullOrEmpty($script:Result.ErrorCode)) ('Successful repair retained poisoned baseline errors. Restore='+$script:Result.ServiceRepairAvailable+';Errors='+(@($script:Checks | Where-Object {$_.State -eq 'error'}).Count)+';Code='+$script:Result.ErrorCode)
    $journal=Read-ServiceHealthJournal
    Assert ($journal.Changes.Count -eq 0 -and $journal.Configurations.Count -eq 1 -and $journal.Configurations[0].Status -eq 'Applied') 'Metadata-only repair did not use fixed protected journal.'
    Invoke-RestoreLocalServices $script:Request
    Assert (-not $script:Metadata.Values[0].Exists -and -not $script:Metadata.Values[1].Exists -and $script:Services.LanmanServer.State -eq 'Running') 'Metadata restore overwrote original missing values or stopped running Server.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Metadata.Values[0].Exists=$false; $script:Request.AllowAdvancedRepair=$true; $script:StartError=1068
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Post-metadata service failure accepted.'
    Assert (-not $script:Metadata.Values[0].Exists -and $script:MetadataRestoreCalls -eq 1) 'Post-start failure did not roll back its own metadata write.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Metadata.Values[0].Exists=$false; $script:Metadata.Values[1].Exists=$false; $script:Request.AllowAdvancedRepair=$true; $script:MetadataPartialFailure=$true
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Partial metadata write failure accepted.'
    Assert (-not $script:Metadata.Values[0].Exists -and -not $script:Metadata.Values[1].Exists) 'Partial metadata write did not restore only already written owned value.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Metadata.Values[0].Exists=$false; $script:Request.AllowAdvancedRepair=$true; $script:SignatureValid=$false
    Assert-Throws { Invoke-RepairLocalServices $script:Request } 'Untrusted Windows original file accepted.'
    Assert ($script:MetadataRepairs -eq 0 -and $script:Starts.Count -eq 0) 'Signature failure still mutated Server metadata.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Metadata.Values[0].Exists=$false; $script:Request.AllowAdvancedRepair=$true; Invoke-RepairLocalServices $script:Request
    $script:Metadata.Values[0].Text='C:\Windows\changed-by-another-admin.dll'
    Invoke-RestoreLocalServices $script:Request
    Assert ($script:Metadata.Values[0].Text -eq 'C:\Windows\changed-by-another-admin.dll') 'Metadata restore overwrote external service path change.'
    Assert (@($script:Checks | Where-Object {$_.Code -eq 'SERVICE_METADATA_EXTERNAL_CHANGE'}).Count -eq 1) 'External metadata preservation not reported.'
    Reset-Test; $script:Services.LanmanServer.State='Stopped'; $script:Metadata.Values[0].Exists=$false; $script:Request.AllowAdvancedRepair=$true; Invoke-RepairLocalServices $script:Request
    $journal=Read-ServiceHealthJournal; $payload=$journal.Configurations[0].Before | ConvertFrom-Json; $payload.Values[0].Name='NullSessionShares'; $journal.Configurations[0].Before=ConvertTo-Json -InputObject $payload -Depth 10 -Compress; Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal
    Assert-Throws { Invoke-RestoreLocalServices $script:Request } 'SMB security/sharing value injected into metadata backup accepted.'
    Write-Output ('PASS: '+$script:Count+' isolated service-health checks. No real services or Windows settings changed.')
} finally {
    $fullRoot=[IO.Path]::GetFullPath($testRoot)
    if ($fullRoot.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $fullRoot '.isolated-test'))) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
}
