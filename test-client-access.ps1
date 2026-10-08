param([string]$HelperPath=(Join-Path $PSScriptRoot 'ClientAccessWorker.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Isolated helper tests: no real SMB logon, policy, account or share changes.
$helper=[IO.File]::ReadAllText((Resolve-Path $HelperPath),[Text.Encoding]::UTF8)
$worker=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ShareWorker.ps1'),[Text.Encoding]::UTF8)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($helper,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw ('Client worker syntax: '+(($errors | ForEach-Object {$_.Message}) -join '; ')) }
$workerAst=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tokens,[ref]$errors)
foreach($name in @('Get-Value','Add-Check','Is-PrivateIPv4','Get-Subnet','Assert-ShareName','Complete-WorkStep')) {
    $function=$workerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $function.Extent.Text
}
Invoke-Expression $helper
$actualPolicy=${function:Get-ClientPolicyState}
$native=[regex]::Match($helper,"Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@",[Text.RegularExpressions.RegexOptions]::Singleline)
$nativeFixture=@'
namespace EinfachNetzwerkClientIsolatedTest {
  public static class DeadlineFixture {
    static ClientProbeResult Call(System.Func<ClientProbeResult> action,int wait) {
      var method=typeof(NativeClientAccess).GetMethod("Bounded",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic);
      return (ClientProbeResult)method.Invoke(null,new object[] {action,wait});
    }
    public static ClientProbeResult Delay(int delay,int wait) {
      return Call(delegate {System.Threading.Thread.Sleep(delay);return new ClientProbeResult {Success=true,DirectoryListed=true};},wait);
    }
    public static ClientProbeResult Throw() {
      return Call(delegate {throw new System.InvalidOperationException("Isolated native deadline fixture");},1000);
    }
  }
}
'@
Add-Type -TypeDefinition ($native.Groups[1].Value.Replace('namespace EinfachNetzwerk {','namespace EinfachNetzwerkClientIsolatedTest {')+[Environment]::NewLine+$nativeFixture)
$testRoot=Join-Path $env:TEMP ('EinfachNetzwerk-clienttest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot '.isolated-test'),'Isolated client backend test')
$script:LedgerRoot=$testRoot; $script:AppMark='EinfachNetzwerk-v1'
$script:Count=0
function Assert([bool]$Test,[string]$Message) { if(-not $Test){throw $Message};$script:Count++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert $failed $Message }
function Reset-Test {
    $script:Checks=New-Object 'System.Collections.Generic.List[object]'
    $script:Result=[ordered]@{ Success=$false; Message=''; Networks=@(); RemoteComputerName=''; RemoteAddress=''; RemoteShareName=''; LoginUserName=''; SharePath=''; ConnectionText=''; ClientRepairAvailable=$false; ClientBackupPath=''; ConnectionVerified=$false; NativeConnectionVerified=$false; ErrorCode=''; ErrorType=''; ErrorStackTrace=''; RetryCount=0 }
    $script:MockCfg=[pscustomobject]@{EnableInsecureGuestLogons=$false;RequireSecuritySignature=$true;RequireEncryption=$true}
    $script:MockNets=@([pscustomobject]@{Id=17;Name='Ethernet';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private';Gateway='192.168.178.1'})
    $script:ProbeCodes=@(0);$script:ProbeCount=0;$script:Mutations=0;$script:ConnectCount=0;$script:Writes=0;$script:PortAvailable=$true;$script:PolicyBlocks=@();$script:Managed=$false;$script:MockMdm=$false;$script:MockCloudJoin=$false;$script:MockGuestPolicy=$null;$script:MockTimeoutAt=-1
    $script:UseActualPolicy=$false;$script:MockCimFailure=$false;$script:MockCimCalls=0;$script:MockCimDeadline=0;$script:MockJoinSuccess=$true;$script:MockJoinStatus=2;$script:MockJoinTimeout=$false
    $script:Request=[pscustomobject]@{Action='InspectRemote';RemoteHost='192.168.178.21';RemoteShareName='Desktop';RemoteUserName='TEST-OLD-PC\Gast';Mode='Guest';AdapterId=17;AllowGuestSettings=$true;DryRun=$false;ProtectedPassword='';OriginalUserSid='test';BackupPath=''}
    $path=Get-ClientJournalPath
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
}
function Get-HomeNetworks {return $script:MockNets}
function Resolve-ClientHostAddresses([string]$HostName) { if($HostName -eq 'multi'){return @('192.168.178.21','192.168.178.22')};if($HostName -eq 'external'){return @('8.8.8.8')};if($HostName -eq 'notebook'){return @('192.168.178.21')};return @($HostName) }
function Get-ClientPolicyState {if($script:UseActualPolicy){return (& $actualPolicy)};return [pscustomobject]@{Configuration=$script:MockCfg;Blocks=$script:PolicyBlocks;Managed=$script:Managed}}
function Get-SmbClientConfiguration {return $script:MockCfg}
function Get-SmbConnection {return @()}
function Get-CimInstance {param($ClassName,$OperationTimeoutSec);$script:MockCimCalls++;$script:MockCimDeadline=$OperationTimeoutSec;if($script:MockCimFailure){throw (New-Object TimeoutException('Isolated CIM timeout'))};return [pscustomobject]@{PartOfDomain=$script:Managed}}
function Get-ClientNativeJoinState {return [pscustomobject]@{Success=$script:MockJoinSuccess;JoinStatus=$script:MockJoinStatus;ErrorCode=0;ErrorMessage='Isolated native join';TimedOut=$script:MockJoinTimeout}}
function Get-RegistrySnapshot([string]$Path,[string]$Name) {return [pscustomobject]@{Exists=($Name -eq 'AllowInsecureGuestAuth' -and $null -ne $script:MockGuestPolicy);Value=$script:MockGuestPolicy}}
function Test-Path {param($LiteralPath,$PathType);if($LiteralPath -like 'HKLM:*OMADM*'){return $script:MockMdm};if($LiteralPath -like 'HKLM:*CloudDomainJoin*'){return $script:MockCloudJoin};return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
function Get-ChildItem {param($LiteralPath);if($LiteralPath -like 'HKLM:*'){return @([pscustomobject]@{Name='Managed-enrollment'})};return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath}
function Test-ClientPort {return $script:PortAvailable}
function Write-Phase {param($Text)}
function Is-Administrator {return $true}
function Assert-PersonalPolicyChanges {if($script:Managed){throw 'Managed machine'}}
function Assert-LedgerProtection {}
function Initialize-LedgerDirectory {}
function Write-JsonAtomic([string]$Path,$Object) {$script:Writes++;[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Object -Depth 10),[Text.Encoding]::UTF8)}
function Set-ClientOwnedValue([string]$Name,[bool]$Value) {$script:Mutations++;$script:MockCfg.$Name=$Value}
function Test-ClientNativeAccess($Request,$Target,[bool]$Connect=$false) {
    if($Connect){$script:ConnectCount++};$index=[Math]::Min($script:ProbeCount,$script:ProbeCodes.Length-1)
    $code=[int]$script:ProbeCodes[$index];$script:ProbeCount++
    $timeout=$script:ProbeCount -eq $script:MockTimeoutAt
    return [pscustomobject]@{Success=($code -eq 0 -and -not $timeout);DirectoryListed=($code -eq 0 -and -not $timeout);ErrorCode=$code;ErrorMessage=('Native error '+$code);Stage='WNetAddConnection2';TimedOut=$timeout}
}
try {
    Reset-Test
    $target=Resolve-ClientTarget $script:Request
    Assert ($target.Address -eq '192.168.178.21') 'Valid LAN target rejected.'
    Assert ($script:Result.SharePath -eq '\\192.168.178.21\Desktop') 'Explorer path does not pin the validated IP.'
    foreach($bad in @('8.8.8.8','127.0.0.1','169.254.1.2','192.168.179.21','192.168.178.0','192.168.178.255','192.168.178.24','192.168.178.021','192.168.178','0xC0A8B215','\\notebook','notebook\Desktop','notebook:445','http://notebook','notebook name','multi','external')) {
        $script:Request.RemoteHost=$bad
        Assert-Throws {Resolve-ClientTarget $script:Request} ('Unsafe/ambiguous target accepted: '+$bad)
    }
    $script:Request.RemoteHost='notebook';$target=Resolve-ClientTarget $script:Request
    Assert ($target.Host -eq 'notebook' -and $target.Address -eq '192.168.178.21') 'Valid name was not resolved once to a pinned LAN address.'
    foreach($bad in @('C$','ADMIN$','IPC$','..','Desktop\child','Desktop/child','Desktop.')) {$script:Request.RemoteShareName=$bad;Assert-Throws {Resolve-ClientTarget $script:Request} ('Reserved/path share accepted: '+$bad)}
    Reset-Test;$script:MockNets[0].Category='Public';Assert-Throws {Resolve-ClientTarget $script:Request} 'Public network accepted.'
    Reset-Test;$script:Request.AdapterId=33;Assert-Throws {Resolve-ClientTarget $script:Request} 'Wrong selected adapter accepted.'
    Reset-Test;Invoke-InspectRemote $script:Request
    Assert ($script:Result.Success -and $script:Result.NativeConnectionVerified -and $script:Result.ConnectionVerified) 'Native success not required.'
    Assert ($script:Mutations -eq 0 -and $script:Writes -eq 0 -and $script:ConnectCount -eq 0) 'Inspect changed client settings or current session.'
    Reset-Test;$script:ProbeCodes=@(1272);Invoke-InspectRemote $script:Request
    Assert (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'Win32: 1272') 'Original native guest code lost.'
    Reset-Test;Invoke-ConnectRemote $script:Request
    Assert ($script:Result.Success -and $script:ConnectCount -eq 1 -and $script:Mutations -eq 0) 'Connect did not use current-user connection or changed security.'
    Reset-Test;Invoke-RepairClient $script:Request
    Assert ($script:Result.Success -and $script:Mutations -eq 0 -and $script:Writes -eq 0) 'Already working named guest needlessly weakened client security.'
    Assert (@($script:Checks | Where-Object {$_.Code -eq 'CLIENT_REPAIR_NOT_NEEDED'}).Count -eq 1) 'Unnecessary repair not explained.'
    foreach($code in @(5,53,67,86,384,1219,1326)) {
        Reset-Test;$script:ProbeCodes=@($code);Invoke-RepairClient $script:Request
        Assert ($script:Mutations -eq 0 -and $script:Writes -eq 0 -and -not $script:Result.Success -and $script:Result.ErrorCode -eq ('Win32: '+$code)) ('Non-policy error weakened security or lost original code: '+$code)
    }
    Reset-Test;$script:ProbeCodes=@(1272);$script:Request.AllowGuestSettings=$false
    Assert-Throws {Invoke-RepairClient $script:Request} 'Guest repair skipped explicit consent.'
    Assert ($script:Mutations -eq 0) 'Consent rejection changed Windows.'
    Reset-Test;$script:ProbeCodes=@(1272);$script:PolicyBlocks=@('Domain-policy')
    Assert-Throws {Invoke-RepairClient $script:Request} 'Managed policy was bypassed.'
    Assert ($script:Mutations -eq 0) 'Managed policy rejection changed Windows.'
    Reset-Test;$script:ProbeCodes=@(1272,0);Invoke-RepairClient $script:Request
    Assert ($script:Result.Success -and $script:Result.ClientRepairAvailable -and $script:Mutations -eq 3) 'Confirmed guest repair did not journal and verify all actual properties.'
    $journal=Read-ClientJournal
    Assert ($journal.Status -eq 'Committed' -and @($journal.Changes).Count -eq 3) 'Client journal not committed.'
    Assert (-not ([IO.File]::ReadAllText((Get-ClientJournalPath)).Contains('ProtectedPassword'))) 'Credentials stored in client journal.'
    Invoke-RestoreClient $script:Request
    Assert ($script:MockCfg.RequireSecuritySignature -and $script:MockCfg.RequireEncryption -and -not $script:MockCfg.EnableInsecureGuestLogons) 'Restore did not restore original settings.'
    Assert (-not $script:Result.ClientRepairAvailable) 'Restore button state remains active after restoration.'
    Reset-Test;$script:MockCfg.PSObject.Properties.Remove('RequireEncryption');$script:ProbeCodes=@(1272,0);Invoke-RepairClient $script:Request
    Assert ($script:Result.Success -and $script:Mutations -eq 2) 'Older Windows unavailable encryption property was changed.'
    Reset-Test;$script:ProbeCodes=@(1272,1326,1326,1326);Invoke-RepairClient $script:Request
    Assert (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'Win32: 1326' -and $script:ProbeCount -eq 4) 'Failed verification did not preserve final native code or bounded retry count.'
    Assert ($script:MockCfg.RequireSecuritySignature -and $script:MockCfg.RequireEncryption -and -not $script:MockCfg.EnableInsecureGuestLogons -and -not $script:Result.ClientRepairAvailable) 'Unverified repair left Windows weakened.'
    Reset-Test;$script:Request.Mode='Password';$script:ProbeCodes=@(1326);Invoke-RepairClient $script:Request
    Assert ($script:Mutations -eq 0 -and -not $script:Result.Success) 'Password mode weakened security.'
    Reset-Test;$script:Request.DryRun=$true;Invoke-RepairClient $script:Request
    Assert ($script:Result.Success -and $script:Mutations -eq 0 -and $script:ProbeCount -eq 0 -and $script:Writes -eq 0 -and -not $script:Result.NativeConnectionVerified) 'Dry run performed a logon or Windows mutation.'
    Reset-Test;$script:PortAvailable=$false;Invoke-InspectRemote $script:Request
    Assert (-not $script:Result.Success -and $script:ProbeCount -eq 0 -and $script:Mutations -eq 0) 'Unreachable target attempted logon or policy change.'
    Reset-Test;$script:Request.BackupPath='C:\Windows\foreign.json';Invoke-RestoreClient $script:Request
    Assert ($script:Result.Success -and $script:Writes -eq 0 -and $script:Mutations -eq 0) 'Caller-selected restore journal was used.'
    foreach($code in @(-1067646973,-1067646972)) {
        Reset-Test;$script:ProbeCodes=@($code);Invoke-InspectRemote $script:Request
        $hex=([int64]$code -band [int64]4294967295).ToString('X8')
        Assert ($script:Result.ErrorCode.Contains(('DWORD: 0x'+$hex))) ('Original signed SMB code not preserved as hex: '+$code)
        Reset-Test;$script:ProbeCodes=@($code,0);Invoke-RepairClient $script:Request
        Assert ($script:Result.Success -and $script:Mutations -eq 3) ('Confirmed signing/encryption guest policy was not repaired: '+$code)
    }
    foreach($bad in @(
        @{Name='EnableInsecureGuestLogons';Before=$true;Expected=$false;Status='Applied'},
        @{Name='RequireSecuritySignature';Before=$false;Expected=$true;Status='Applied'},
        @{Name='RequireEncryption';Before=$false;Expected=$true;Status='Applied'},
        @{Name='RequireSecuritySignature';Before=$true;Expected=$true;Status='Applied'},
        @{Name='Unknown';Before=$true;Expected=$false;Status='Applied'}
    )) {
        Reset-Test;Write-JsonAtomic (Get-ClientJournalPath) @{App=$script:AppMark;Version=1;Action='RepairClient';Status='Committed';Changes=@($bad)}
        Assert-Throws {Read-ClientJournal} 'Invalid/reversed compatibility journal accepted.'
        Assert ($script:Mutations -eq 0) 'Invalid journal changed Windows.'
    }
    Reset-Test;Write-JsonAtomic (Get-ClientJournalPath) @{App=$script:AppMark;Version=1;Action='RepairClient';Status='Committed'}
    Assert-Throws {Read-ClientJournal} 'Missing change list accepted.'
    Reset-Test;Write-JsonAtomic (Get-ClientJournalPath) @{App=$script:AppMark;Version=1;Action='RepairClient';Status='Foreign';Changes=@()}
    Assert-Throws {Read-ClientJournal} 'Unknown journal status accepted.'
    Reset-Test;$state=& $actualPolicy
    Assert (-not $state.Managed -and $state.Blocks.Count -eq 0) 'Ordinary personal client marked managed.'
    $script:Managed=$true;$state=& $actualPolicy
    Assert ($state.Managed -and $state.Blocks.Count -gt 0) 'Domain restrictions not detected.'
    Reset-Test;$script:MockMdm=$true;$state=& $actualPolicy
    Assert ($state.Managed) 'MDM enrollment not detected.'
    Reset-Test;$script:MockCloudJoin=$true;$state=& $actualPolicy
    Assert ($state.Managed) 'Cloud domain join not detected.'
    Reset-Test;$script:MockGuestPolicy=0;$state=& $actualPolicy
    Assert ($state.Blocks -contains 'AllowInsecureGuestAuth') 'Explicit managed guest policy not detected.'
    $deadline=[EinfachNetzwerkClientIsolatedTest.DeadlineFixture]::Delay(100,10)
    Assert ($deadline.TimedOut -and $deadline.ErrorCode -eq 0 -and -not $deadline.Success) 'Native deadline fabricated a Windows error or returned success.'
    [Threading.Thread]::Sleep(130)
    Assert ($deadline.TimedOut -and -not $deadline.Success) 'Late native completion overwrote the returned timeout result.'
    $completed=[EinfachNetzwerkClientIsolatedTest.DeadlineFixture]::Delay(1,1000)
    Assert ($completed.Success -and -not $completed.TimedOut) 'Fast native completion incorrectly timed out.'
    $exception=[EinfachNetzwerkClientIsolatedTest.DeadlineFixture]::Throw()
    Assert ($exception.ManagedErrorType -eq 'System.InvalidOperationException' -and $exception.ManagedErrorCode -match '^HRESULT: 0x' -and $exception.ErrorCode -eq 0) 'Managed exception lost its original code/type or fabricated a Win32 error.'
    Reset-Test;$script:MockTimeoutAt=1;Invoke-InspectRemote $script:Request
    Assert (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'APP: CLIENT_NATIVE_TIMEOUT' -and $script:Result.ErrorType -eq 'System.TimeoutException') 'Program deadline misreported as a Windows native code.'
    Reset-Test;$script:ProbeCodes=@(1272,0);$script:MockTimeoutAt=2;Invoke-RepairClient $script:Request
    Assert (-not $script:Result.Success -and $script:ProbeCount -eq 2 -and $script:Result.ErrorCode -eq 'APP: CLIENT_NATIVE_TIMEOUT') 'Timed-out repair retried indefinitely or lost its own deadline.'
    Assert ($script:MockCfg.RequireSecuritySignature -and $script:MockCfg.RequireEncryption -and -not $script:MockCfg.EnableInsecureGuestLogons -and -not $script:Result.ClientRepairAvailable) 'Native timeout prevented safe client rollback.'
    Reset-Test;$script:MockCfg.RequireEncryption=$false;$script:ProbeCodes=@(1272,0);Invoke-RepairClient $script:Request
    Assert ($script:Result.Success -and @(Read-ClientJournal).Count -eq 1) 'Initial successful client repair was not stored.'
    $script:MockCfg.RequireEncryption=$true;$script:ProbeCount=0;$script:ProbeCodes=@(-1067646972,1326,1326,1326)
    Invoke-RepairClient $script:Request
    $continued=Read-ClientJournal
    Assert (-not $script:Result.Success -and $script:Result.ClientRepairAvailable -and $continued.Status -eq 'Committed') 'Failed later repair lost older successful repair ownership.'
    Assert ($script:MockCfg.EnableInsecureGuestLogons -and -not $script:MockCfg.RequireSecuritySignature -and $script:MockCfg.RequireEncryption) 'Later failed repair rolled back settings from an older successful repair.'
    Assert (@($continued.Changes | Where-Object {$_.Status -eq 'Applied'}).Count -eq 2 -and @($continued.Changes | Where-Object {$_.Name -eq 'RequireEncryption' -and $_.Status -eq 'Restored'}).Count -eq 1) 'Journal did not preserve older owned settings throughout targeted rollback.'
    Invoke-RestoreClient $script:Request
    Assert (-not $script:MockCfg.EnableInsecureGuestLogons -and $script:MockCfg.RequireSecuritySignature -and $script:MockCfg.RequireEncryption -and -not $script:Result.ClientRepairAvailable) 'Full restore after a later failed repair did not recover original owned settings.'
    Reset-Test;$script:MockCimFailure=$true;$state=& $actualPolicy
    Assert ($script:MockCimDeadline -eq 5 -and -not $state.Unknown -and -not $state.Managed -and $state.Blocks.Count -eq 0) 'Confirmed native workgroup fallback did not preserve bounded/known management state.'
    Assert (@($script:Checks | Where-Object {$_.Name -eq 'Windows-Verwaltungsstatus lesen' -and $_.Code -match 'HRESULT'}).Count -eq 1) 'Original failed CIM code was not retained in diagnostic checks.'
    Reset-Test;$script:MockCimFailure=$true;$script:MockJoinStatus=3;$state=& $actualPolicy
    Assert ($state.Managed -and -not $state.Unknown -and $state.Blocks.Count -gt 0) 'Native domain fallback was treated as personal Windows.'
    Reset-Test;$script:MockCimFailure=$true;$script:MockMdm=$true;$state=& $actualPolicy
    Assert ($state.Managed -and $state.Blocks.Count -gt 0) 'Native workgroup fallback bypassed MDM checks.'
    Reset-Test;$script:MockCimFailure=$true;$script:MockJoinSuccess=$false;$script:MockJoinTimeout=$true;$state=& $actualPolicy
    Assert ($state.Unknown -and $state.Blocks.Count -gt 0) 'Failed/timed-out management fallback permitted security changes.'
    Reset-Test;$script:UseActualPolicy=$true;$script:MockCimFailure=$true;$script:MockJoinSuccess=$false;Invoke-InspectRemote $script:Request
    Assert ($script:Result.Success -and $script:ProbeCount -eq 1 -and $script:Mutations -eq 0) 'Unknown management metadata stopped a working native read-only connection.'
    Reset-Test;$script:UseActualPolicy=$true;$script:MockCimFailure=$true;$script:MockJoinSuccess=$false;Invoke-ConnectRemote $script:Request
    Assert ($script:Result.Success -and $script:ConnectCount -eq 1 -and $script:Mutations -eq 0) 'Unknown management metadata stopped an authorized current-user connection.'
    Reset-Test;$script:UseActualPolicy=$true;$script:MockCimFailure=$true;$script:MockJoinSuccess=$false;Invoke-RepairClient $script:Request
    Assert ($script:Result.Success -and $script:Mutations -eq 0) 'Unknown metadata blocked already working access or changed security.'
    Reset-Test;$script:UseActualPolicy=$true;$script:MockCimFailure=$true;$script:MockJoinSuccess=$false;$script:ProbeCodes=@(1272)
    Assert-Throws {Invoke-RepairClient $script:Request} 'Unknown management state allowed guest compatibility mutations.'
    Assert ($script:Mutations -eq 0 -and $script:Writes -eq 0) 'Blocked unknown management state still changed Windows or wrote a journal.'
    Reset-Test;$script:UseActualPolicy=$true;$script:MockCimFailure=$true;$script:MockJoinSuccess=$false;$script:PortAvailable=$false
    Invoke-InspectRemote $script:Request
    Assert (-not $script:Result.Success -and $script:MockCimCalls -eq 0 -and $script:ProbeCount -eq 0) 'Offline target waited for unrelated local WMI or attempted SMB.'
    Write-Host ('Client access backend: '+$script:Count+' isolated checks passed; no real SMB, security, shares, services or firewall changes.')
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temporary=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if ($resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $resolved '.isolated-test'))) {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
