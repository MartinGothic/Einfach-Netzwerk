param([string]$Executable=(Join-Path $PSScriptRoot 'dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Exact trusted embedded modules, isolated request/results and Windows doubles.
# This test executes dispatch and progress; it never changes real services.
$assembly=[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $Executable).Path)
function Read-Embedded([string]$Name) {
    $stream=$assembly.GetManifestResourceStream('EinfachNetzwerk.'+$Name)
    if ($null -eq $stream) { throw ('Missing trusted resource '+$Name) }
    $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
$worker=Read-Embedded 'ShareWorker.ps1'
foreach ($resource in @('ClientAccessWorker.ps1','ServiceHealthWorker.ps1')) {
    $helper=Read-Embedded $resource
    $insertion=$worker.IndexOf('# Windows PowerShell',[StringComparison]::Ordinal)
    if ($insertion -lt 0) { throw 'Unrecognized trusted worker entry point' }
    $worker=$worker.Insert($insertion,$helper+[Environment]::NewLine)
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw ('Embedded worker syntax: '+(($errors | ForEach-Object {$_.Message}) -join '; ')) }
$entry=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($entry.Count -ne 1) { throw 'Trusted worker main dispatch is ambiguous' }
$doubles=@'
function Get-ServiceHealthNetworks { return @([pscustomobject]@{Id=17;Name='Isolated Ethernet';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private';Gateway='192.168.178.1'}) }
function Get-ServiceNativeSnapshot([string]$Name) {
    $state='Running'; $code=0
    if ($Name -eq 'LanmanServer' -and $global:ServiceIntegrationFixture.Stopped) { $state='Stopped'; $code=$global:ServiceIntegrationFixture.Code }
    return [pscustomobject]@{Name=$Name;Exists=$true;State=$state;StateValue=4;StartMode='Auto';StartValue=2;Delayed=$false;Win32ExitCode=$code;ServiceSpecificExitCode=0;Dependencies=@()}
}
function Get-ServerServiceMetadataJson {
    return (ConvertTo-Json -InputObject ([pscustomobject]@{ParametersKeyExists=$true;Values=@([pscustomobject]@{Name='ServiceDll';Exists=(-not $global:ServiceIntegrationFixture.MetadataMissing);Kind='ExpandString';Text=(Join-Path ([Environment]::GetFolderPath('System')) 'srvsvc.dll');Strings=$null;Number=0;Binary=$null},[pscustomobject]@{Name='ServiceDllUnloadOnStop';Exists=$true;Kind='DWord';Text=$null;Strings=$null;Number=1;Binary=$null})}) -Depth 10 -Compress)
}
function Test-ServiceHealthPort { return (-not $global:ServiceIntegrationFixture.Stopped) }
function Publish-ServiceHealthRestoreState { $script:Result.ServiceRepairAvailable=$false; $script:Result.ServiceBackupPath='' }
function Read-ServiceHealthJournal {
    return [pscustomobject]@{App='EinfachNetzwerk-v1';Version=1;Action='RepairServices';Status='Committed';Changes=@([pscustomobject]@{Name='LanmanServer';Before=[pscustomobject]@{StartValue=4;Delayed=$false};Expected=[pscustomobject]@{StartValue=2;Delayed=$false};Status='Applied'});Configurations=@()}
}
function Assert-PersonalPolicyChanges {}
function Get-HomeNetworks { throw 'Forbidden WMI-backed network provider before local service repair' }
function Get-CimInstance { throw 'Forbidden WMI provider for native service diagnosis' }
function Get-SmbShare { throw 'Forbidden SMB provider before Server service start' }
function Get-SmbServerConfiguration { throw 'Forbidden SMB provider before Server service start' }
function Read-Ledger { throw 'Forbidden share journal before local service diagnosis' }
function Start-ServiceNative { throw 'Forbidden actual start in isolated dispatch test' }
function Set-ServiceNativeStart { throw 'Forbidden actual starttype in isolated dispatch test' }
function Repair-ServerServiceMetadata { throw 'Forbidden actual metadata write in isolated dispatch test' }
function Restore-ServerServiceMetadata { throw 'Forbidden actual metadata restore in isolated dispatch test' }
function Write-JsonAtomic { throw 'Forbidden machine journal write in isolated dispatch test' }
'@
$worker=$worker.Insert($entry[0].Extent.StartOffset,$doubles+[Environment]::NewLine)
$run=[scriptblock]::Create($worker)
$root=Join-Path $env:TEMP ('EinfachNetzwerk-service-integration-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
[IO.File]::WriteAllText((Join-Path $root '.isolated-test'),'Embedded service integration doubles only')
$script:ChecksPassed=0
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:ChecksPassed++ }
function Invoke-Fixture([string]$Action,[bool]$Stopped,[int]$Code=0,[bool]$Missing=$false,[bool]$DryRun=$false) {
    $global:ServiceIntegrationFixture=[pscustomobject]@{Stopped=$Stopped;Code=$Code;MetadataMissing=$Missing}
    $directory=Join-Path $root ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($directory)
    $requestPath=Join-Path $directory 'Request.json';$resultPath=Join-Path $directory 'Result.json'
    $request=ConvertTo-Json -InputObject ([ordered]@{Action=$Action;AdapterId=0;DryRun=$DryRun;AllowAdvancedRepair=$true;OriginalUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ProtectedPassword='';BackupPath='untrusted-ignored.json'}) -Compress
    [IO.File]::WriteAllText($requestPath,$request,[Text.Encoding]::UTF8)
    & $run -RequestPath $requestPath -ResultPath $resultPath -RequestJson $request | Out-Null
    Assert ([IO.File]::Exists($resultPath)) ($Action+': worker failed to write a real result')
    $result=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $progress=[IO.File]::ReadAllText(($resultPath+'.phase'),[Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($progress.Completed -eq ($progress.Total-1) -and $progress.Percent -lt 100) ($Action+': worker claimed client confirmation or left service work uncounted')
    Assert (-not $result.ConnectionVerified -and -not $result.NativeConnectionVerified) ($Action+': local check claimed an external Windows connection')
    return $result
}
try {
    $result=Invoke-Fixture 'InspectServices' $false
    Assert ($result.Success -and $result.ServiceHealthVerified) ('Healthy native service dispatch failed: '+$result.Message+' / '+$result.ErrorCode)
    $result=Invoke-Fixture 'InspectServices' $true
    Assert (-not $result.Success -and $result.ErrorCode -eq 'Win32: 2114') 'Stopped native Server condition2114 lost.'
    $result=Invoke-Fixture 'InspectServices' $true 2 $true
    Assert (-not $result.Success -and $result.ErrorCode -eq 'Win32: 2' -and @($result.Checks | Where-Object {$_.Code -eq 'SERVICE_SERVER_METADATA_INVALID'}).Count -eq 1) 'Original SCM code2 + missing ServiceDll rootcause lost in complete worker.'
    $result=Invoke-Fixture 'Inspect' $true 2 $true
    Assert (-not $result.Success -and @($result.Checks | Where-Object {$_.Code -eq 'SERVICE_INVENTORY_UNAVAILABLE'}).Count -eq 1) 'Startup Inspect called SMB/WMI while Server service stopped.'
    $result=Invoke-Fixture 'RepairServices' $true 2 $true $true
    Assert ($result.Success -and -not $result.ServiceHealthVerified -and $result.Message.StartsWith('Probelauf:')) 'Service dryrun repaired or verified actual Windows.'
    $result=Invoke-Fixture 'RestoreServices' $false 0 $false $true
    Assert ($result.Success -and $result.Message.StartsWith('Probelauf:')) 'Service restore dryrun failed.'
    $result=Invoke-Fixture 'RepairSystem' $true 2 $true $true
    Assert ($result.Success -and -not $result.ServiceHealthVerified) 'Legacy no-folder system repair did not use new isolated service path.'
    Write-Output ('PASS: '+$script:ChecksPassed+' embedded service-dispatch checks; no real services or Windows configuration changed.')
} finally {
    Remove-Variable -Name ServiceIntegrationFixture -Scope Global -ErrorAction SilentlyContinue
    $fullRoot=[IO.Path]::GetFullPath($root)
    if ($fullRoot.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $fullRoot '.isolated-test'))) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
}
