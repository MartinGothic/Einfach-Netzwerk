param([string]$AssemblyPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($PSVersionTable.PSEdition -eq 'Core') {
    $taskParameters = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($AssemblyPath) { $taskParameters += @('-AssemblyPath',$AssemblyPath) }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @taskParameters
    exit $LASTEXITCODE
}
if (-not $AssemblyPath) {
    $taskDestination = Join-Path $PSScriptRoot 'host-qa'
    [IO.Directory]::CreateDirectory($taskDestination) | Out-Null
    $AssemblyPath = Join-Path $taskDestination 'service-server-check.dll'
    $taskCompiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $taskCompiler '/nologo' '/target:library' '/langversion:5' '/reference:System.dll' '/reference:System.Core.dll' '/reference:System.Security.dll' '/reference:System.Web.Extensions.dll' '/reference:System.Xml.dll' ('/out:'+$AssemblyPath) (Join-Path $PSScriptRoot '..\src\ServiceConfigurationRecovery.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Service configuration helper compilation failed.' }
}
[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path) | Out-Null
Add-Type -AssemblyName System.Web.Extensions
$script:Passed = 0
function Assert-ServiceFixture($Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
    Write-Output ('PASS: '+$Message)
}
$taskType = [EinfachNetzwerk.ServiceConfigurationRecovery]
$taskFlags = [Reflection.BindingFlags]'Static,NonPublic'
$taskRead = $taskType.GetMethod('ReadServerMetadata',$taskFlags)
$taskRestore = $taskType.GetMethod('RestoreServerMetadata',$taskFlags)
$taskWrite = $taskType.GetMethod('WriteServerMetadataPlan',$taskFlags)
$taskBuild = $taskType.GetMethod('BuildPlan',$taskFlags)
$taskSerializer = New-Object Web.Script.Serialization.JavaScriptSerializer
$taskServerBefore = $taskType::ReadServerMetadataJson()
$taskPlan = $taskType::GetPlanJson('LanmanServer') | ConvertFrom-Json
Assert-ServiceFixture ($taskPlan.Name -ceq 'LanmanServer') 'Server has its own canonical identity'
Assert-ServiceFixture ($taskPlan.DllPath -ieq (Join-Path $env:SystemRoot 'System32\srvsvc.dll')) 'Server uses srvsvc.dll rather than service-name DLL'
Assert-ServiceFixture ($taskPlan.DllHash -ceq (Get-FileHash -LiteralPath $taskPlan.DllPath -Algorithm SHA256).Hash) 'Protected original manifest hash matches installed server DLL'
$taskSignature = Get-AuthenticodeSignature -LiteralPath $taskPlan.DllPath
Assert-ServiceFixture ($taskSignature.Status -eq 'Valid' -and $taskSignature.SignerCertificate.Subject -match 'O=Microsoft Corporation') 'Server DLL has a valid Microsoft signature'
Assert-ServiceFixture ($taskPlan.Configuration.ObjectName -ceq 'LocalSystem' -and $taskPlan.Configuration.Start -eq 2 -and $taskPlan.Configuration.Type -eq 32) 'Server original LocalSystem automatic shared-process profile preserved'
Assert-ServiceFixture (($taskPlan.Configuration.DependOnService -join ',') -ceq 'SamSS,Srv2') 'Server dependencies match the typed original SMB2 profile'
Assert-ServiceFixture ($taskPlan.RegistryValues.Count -eq 2 -and @($taskPlan.RegistryValues | Where-Object { $_.Name -notin @('ServiceDll','ServiceDllUnloadOnStop') }).Count -eq 0) 'Repair plan owns exactly the two service DLL metadata values'
Assert-ServiceFixture (@($taskPlan.RegistryValues | Where-Object { $_.Path -cne 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' }).Count -eq 0) 'Repair metadata stays in the exact fixed service Parameters key'
Assert-ServiceFixture ($taskPlan.RegistrySecurity.Count -eq 0 -and $taskPlan.ServiceTriggers.Count -eq 0) 'Service recovery does not rewrite security descriptors or triggers'
$taskFixtureName = 'Software\EinfachNetzwerk-ServiceFixture-' + [Guid]::NewGuid().ToString('N')
$taskFixtureKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($taskFixtureName)
$taskNativePlan = (New-Object Web.Script.Serialization.JavaScriptSerializer).Deserialize($taskType::GetPlanJson('LanmanServer'),[EinfachNetzwerk.ServiceConfigurationRecovery+RecoveryPlan])
try {
    # This fixture is the only registry tree mutated by this test.
    $taskMissing = $taskRead.Invoke($null,@($taskFixtureKey))
    Assert-ServiceFixture (-not $taskMissing.ParametersKeyExists -and @($taskMissing.Values | Where-Object Exists).Count -eq 0) 'Snapshot distinguishes a missing Parameters key and missing values'
    $taskWrite.Invoke($null,@($taskFixtureKey,$taskNativePlan)) | Out-Null
    $taskOwned = $taskRead.Invoke($null,@($taskFixtureKey))
    Assert-ServiceFixture ($taskOwned.ParametersKeyExists -and $taskOwned.Values[0].Kind -ceq 'ExpandString' -and $taskOwned.Values[0].Text.Contains('%SystemRoot%')) 'Repair preserves unexpanded environment text and REG_EXPAND_SZ kind'
    Assert-ServiceFixture ($taskOwned.Values[1].Kind -ceq 'DWord' -and $taskOwned.Values[1].Number -eq 1) 'Unload option uses the exact original DWORD type and value'
    $taskOutcome = $taskRestore.Invoke($null,@($taskFixtureKey,$taskMissing,$taskOwned))
    Assert-ServiceFixture ($taskOutcome.Restored.Count -eq 2 -and $taskOutcome.ParametersKeyRemoved) 'Owned restoration removes exactly its two values and its newly created empty key'
    Assert-ServiceFixture (-not $taskRead.Invoke($null,@($taskFixtureKey)).ParametersKeyExists) 'Originally missing key remains missing after restore'
    $taskParameters = $taskFixtureKey.CreateSubKey('Parameters')
    $taskParameters.SetValue('ServiceDll','fixture-original-string',[Microsoft.Win32.RegistryValueKind]::String)
    $taskParameters.SetValue('ServiceDllUnloadOnStop',[long]37,[Microsoft.Win32.RegistryValueKind]::QWord)
    $taskParameters.SetValue('RequireSecuritySignature',1,[Microsoft.Win32.RegistryValueKind]::DWord)
    $taskParameters.SetValue('NullSessionPipes',[string[]]@('existing-custom-pipe'),[Microsoft.Win32.RegistryValueKind]::MultiString)
    $taskParameters.Dispose()
    $taskOriginal = $taskRead.Invoke($null,@($taskFixtureKey))
    $taskWrite.Invoke($null,@($taskFixtureKey,$taskNativePlan)) | Out-Null
    $taskExpected = $taskRead.Invoke($null,@($taskFixtureKey))
    $taskOutcome = $taskRestore.Invoke($null,@($taskFixtureKey,$taskOriginal,$taskExpected))
    $taskRestored = $taskRead.Invoke($null,@($taskFixtureKey))
    Assert-ServiceFixture ($taskRestored.Values[0].Kind -ceq 'String' -and $taskRestored.Values[0].Text -ceq 'fixture-original-string') 'Restore retains original String kind and exact raw text'
    Assert-ServiceFixture ($taskRestored.Values[1].Kind -ceq 'QWord' -and $taskRestored.Values[1].Number -eq 37) 'Restore retains original QWORD kind and value'
    $taskParameters = $taskFixtureKey.OpenSubKey('Parameters',$true)
    Assert-ServiceFixture ($taskParameters.GetValue('RequireSecuritySignature') -eq 1 -and $taskParameters.GetValue('NullSessionPipes')[0] -ceq 'existing-custom-pipe') 'Sharing security settings remain unchanged throughout repair and restore'
    $taskParameters.Dispose()
    $taskWrite.Invoke($null,@($taskFixtureKey,$taskNativePlan)) | Out-Null
    $taskExpected = $taskRead.Invoke($null,@($taskFixtureKey))
    $taskParameters = $taskFixtureKey.OpenSubKey('Parameters',$true)
    $taskParameters.SetValue('ServiceDll','external-service-choice',[Microsoft.Win32.RegistryValueKind]::String)
    $taskParameters.Dispose()
    $taskOutcome = $taskRestore.Invoke($null,@($taskFixtureKey,$taskOriginal,$taskExpected))
    Assert-ServiceFixture ($taskOutcome.Preserved.Count -eq 1 -and $taskOutcome.Preserved[0] -ceq 'ServiceDll') 'Restore identifies and preserves an external change to an owned value'
    Assert-ServiceFixture ($taskRead.Invoke($null,@($taskFixtureKey)).Values[0].Text -ceq 'external-service-choice') 'External changed DLL text is not overwritten by restore'
    foreach ($taskKind in @([Microsoft.Win32.RegistryValueKind]::Binary,[Microsoft.Win32.RegistryValueKind]::None,[Microsoft.Win32.RegistryValueKind]::MultiString,[Microsoft.Win32.RegistryValueKind]::DWord)) {
        $taskParameters = $taskFixtureKey.OpenSubKey('Parameters',$true)
        switch ([string]$taskKind) { 'Binary' {$taskValue=[byte[]]@(1,2,255)} 'None' {$taskValue=[byte[]]@(7,8)} 'MultiString' {$taskValue=[string[]]@('raw-one','raw-two')} 'DWord' {$taskValue=-1} }
        $taskParameters.SetValue('ServiceDll',$taskValue,$taskKind)
        $taskParameters.Dispose()
        $taskOriginal = $taskRead.Invoke($null,@($taskFixtureKey))
        $taskWrite.Invoke($null,@($taskFixtureKey,$taskNativePlan)) | Out-Null
        $taskExpected = $taskRead.Invoke($null,@($taskFixtureKey))
        $taskRestore.Invoke($null,@($taskFixtureKey,$taskOriginal,$taskExpected)) | Out-Null
        Assert-ServiceFixture ($taskSerializer.Serialize($taskRead.Invoke($null,@($taskFixtureKey))) -ceq $taskSerializer.Serialize($taskOriginal)) ('Corrupt metadata restores its exact original '+$taskKind+' value and kind')
    }
    # Parse a fixture definition through the same typed builder. No Windows
    # service or trusted-source check is replaced during the live readonly plan.
    $taskXml = '<assembly xmlns="urn:schemas-microsoft-com:asm.v3"><serviceData name="lanmanserver" type="win32ShareProcess" errorControl="normal" start="auto" objectName="LocalSystem" sidType="unrestricted" imagePath="%SystemRoot%\system32\svchost.exe -k netsvcs -p" dependOnService="SamSS,Srv2" requiredPrivileges="SeChangeNotifyPrivilege,SeImpersonatePrivilege,SeAuditPrivilege"/><registryKeys><registryKey keyName="HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"><registryValue name="ServiceDll" valueType="REG_EXPAND_SZ" value="%SystemRoot%\system32\srvsvc.dll"/><registryValue name="ServiceDllUnloadOnStop" valueType="REG_DWORD" value="0x00000001"/><registryValue name="NullSessionPipes" valueType="REG_MULTI_SZ" value=""/></registryKey></registryKeys></assembly>'
    function Invoke-FixtureDefinition([string]$Xml) {
        $taskDocument=New-Object Xml.XmlDocument
        $taskDocument.XmlResolver=$null
        $taskDocument.LoadXml($Xml)
        $taskNamespaces=New-Object Xml.XmlNamespaceManager($taskDocument.NameTable)
        $taskNamespaces.AddNamespace('a','urn:schemas-microsoft-com:asm.v3')
        [string]$taskDllPath=Join-Path $env:SystemRoot 'System32\srvsvc.dll'
        [string]$taskDllHash=[Convert]::ToBase64String((New-Object byte[] 32))
        $taskBuild.Invoke($null,@('LanmanServer','fixture.manifest','fixture.dictionary',$taskDllPath,$taskDllHash,$taskDocument.PSObject.BaseObject,$taskNamespaces.PSObject.BaseObject))
    }
    $taskFixturePlan=Invoke-FixtureDefinition $taskXml
    Assert-ServiceFixture ($taskFixturePlan.RegistryValues.Count -eq 2) 'Typed fixture builder excludes unrelated SMB policy values'
    $taskRejected=@{
        'foreign service identity'=$taskXml.Replace('name="lanmanserver"','name="ForeignService"')
        'foreign service host'=$taskXml.Replace('svchost.exe -k netsvcs -p','foreign.exe')
        'incorrect account'=$taskXml.Replace('LocalSystem','NT AUTHORITY\LocalService')
        'incorrect start profile'=$taskXml.Replace('start="auto"','start="demand"')
        'foreign dependency'=$taskXml.Replace('SamSS,Srv2','SamSS,ForeignDriver')
        'extra service privilege'=$taskXml.Replace('SeAuditPrivilege','SeBackupPrivilege')
        'foreign DLL'=$taskXml.Replace('system32\srvsvc.dll','system32\foreign.dll')
        'wrong DLL registry kind'=$taskXml.Replace('REG_EXPAND_SZ','REG_SZ')
        'wrong unload value'=$taskXml.Replace('0x00000001','0x00000000')
        'missing metadata'=$taskXml.Replace('name="ServiceDllUnloadOnStop"','name="UnownedValue"')
    }
    foreach($taskCase in $taskRejected.GetEnumerator()) {
        $taskFailed=$false
        try { Invoke-FixtureDefinition $taskCase.Value | Out-Null } catch {$taskFailed=$true}
        Assert-ServiceFixture $taskFailed ('Typed original profile rejects '+$taskCase.Key)
    }
    $taskHostSnapshot=$taskType::ReadServerMetadataJson()
    Assert-ServiceFixture ($taskServerBefore -ceq $taskHostSnapshot) 'No live LanmanServer metadata changed during fixture tests'
} finally {
    $taskFixtureKey.Dispose()
    if ($taskFixtureName -notmatch '^Software\\EinfachNetzwerk-ServiceFixture-[a-f0-9]{32}$') { throw 'Fixture cleanup path verification failed.' }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($taskFixtureName,$false)
}
Write-Output ('Server service configuration tests: '+$script:Passed+' passed; only isolated own HKCU fixture modified.')
