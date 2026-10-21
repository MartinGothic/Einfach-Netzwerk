param([string]$AssemblyPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($PSVersionTable.PSEdition -eq 'Core') {
    $parameters = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($AssemblyPath) { $parameters += @('-AssemblyPath',$AssemblyPath) }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @parameters
    exit $LASTEXITCODE
}
if (-not $AssemblyPath) {
    $destination = Join-Path $PSScriptRoot 'host-qa'
    if (-not (Test-Path -LiteralPath $destination)) { [IO.Directory]::CreateDirectory($destination) | Out-Null }
    $AssemblyPath = Join-Path $destination 'service-recovery-check.dll'
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler '/nologo' '/target:library' '/langversion:5' '/reference:System.dll' '/reference:System.Core.dll' '/reference:System.Security.dll' '/reference:System.Web.Extensions.dll' '/reference:System.Xml.dll' ('/out:'+$AssemblyPath) (Join-Path $PSScriptRoot '..\src\ServiceConfigurationRecovery.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Read-only recovery helper compilation failed.' }
}
[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path) | Out-Null
$script:Passed = 0
function Assert-Recovery($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++; Write-Output ('PASS: '+$Message) }
function Get-ServiceRegistrySnapshot {
    $items = @()
    foreach($name in @('FDResPub','fdPHost')) {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\'+$name
        $all = @(Get-Item -LiteralPath $path -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $path -Recurse -ErrorAction SilentlyContinue)
        foreach($key in $all) {
            $values = @()
            foreach($valueName in $key.GetValueNames()) {
                $values += [pscustomobject]@{ Name=$valueName; Kind=[string]$key.GetValueKind($valueName); Value=$key.GetValue($valueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            }
            $items += [pscustomobject]@{ Key=$key.Name; Values=$values; Sddl=$key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All) }
        }
    }
    ConvertTo-Json -InputObject $items -Depth 8 -Compress
}
$before = Get-ServiceRegistrySnapshot
foreach($name in @('FDResPub','fdPHost')) {
    $plan = [EinfachNetzwerk.ServiceConfigurationRecovery]::GetPlanJson($name) | ConvertFrom-Json
    Assert-Recovery ($plan.Name -ceq $name) ($name+': exact service identity retained')
    Assert-Recovery ($plan.ManifestPath.StartsWith((Join-Path $env:SystemRoot 'WinSxS\Manifests\'),[StringComparison]::OrdinalIgnoreCase)) ($name+': manifest is from local Windows component store')
    Assert-Recovery ($plan.DllHash -ceq (Get-FileHash -LiteralPath $plan.DllPath -Algorithm SHA256).Hash) ($name+': manifest hash matches actual installed service DLL')
    $signature = Get-AuthenticodeSignature -LiteralPath $plan.DllPath
    Assert-Recovery ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation') ($name+': installed service DLL is Microsoft signed')
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\'+$name
    $foreign = @($plan.RegistryValues | Where-Object { $_.Path -ine $root -and -not $_.Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) })
    Assert-Recovery ($foreign.Count -eq 0) ($name+': every recovery registry value is scoped to this service')
    $dll = @($plan.RegistryValues | Where-Object { $_.Name -eq 'ServiceDll' })
    Assert-Recovery ($dll.Count -eq 1 -and $dll[0].Kind -eq 'ExpandString' -and [Environment]::ExpandEnvironmentVariables($dll[0].Value) -ieq $plan.DllPath) ($name+': DLL registry definition resolves to the verified DLL')
    Assert-Recovery ($plan.Configuration.ObjectName -eq 'NT AUTHORITY\LocalService' -and $plan.Configuration.Type -eq 32) ($name+': service keeps original low-privilege shared-process identity')
    Assert-Recovery (@($plan.FailureActions.Actions).Count -gt 0 -and @($plan.FailureActions.Actions | Where-Object {$_.Type -notin @(0,1)}).Count -eq 0) ($name+': original failure actions contain no reboot or arbitrary command')
}
foreach($name in @('LanmanWorkstation','..\FDResPub','FDResPub\Parameters','')) {
    $rejected = $false
    try { [EinfachNetzwerk.ServiceConfigurationRecovery]::GetPlanJson($name) | Out-Null }
    catch { $rejected = $true }
    Assert-Recovery $rejected ('Unsupported recovery service rejected: '+$name)
}
$fd = [EinfachNetzwerk.ServiceConfigurationRecovery]::GetPlanJson('FDResPub') | ConvertFrom-Json
Assert-Recovery ($fd.ServiceTriggers.Count -eq 1 -and $fd.ServiceTriggers[0].Type -eq 20 -and $fd.ServiceTriggers[0].Data[0].Value -eq 'PROFILE_CHANGED_TO_PRIVATE') 'FDResPub original private-network trigger recovered'
Assert-Recovery ($fd.RegistrySecurity.Count -eq 1 -and $fd.RegistrySecurity[0].Path.EndsWith('\FDResPub\ServiceData')) 'FDResPub registry ACL plan is scoped to its original ServiceData key'
Assert-Recovery ($before -ceq (Get-ServiceRegistrySnapshot)) 'Read-only plans and validation leave both service registry trees unchanged'
Write-Output ('Service recovery read-only tests: '+$script:Passed+' passed; no live Repair call performed.')
