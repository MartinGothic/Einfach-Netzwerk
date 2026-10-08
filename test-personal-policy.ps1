param([string]$WorkerPath=(Join-Path $PSScriptRoot 'ShareWorker.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Read-only isolated guard tests. No real registry, WMI, network or mutation.
$tokens=$null;$errors=$null
$worker=[IO.File]::ReadAllText((Resolve-Path $WorkerPath),[Text.Encoding]::UTF8)
$helper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ClientAccessWorker.ps1'),[Text.Encoding]::UTF8)
$workerAst=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){throw 'Worker syntax invalid.'}
$helperAst=[Management.Automation.Language.Parser]::ParseInput($helper,[ref]$tokens,[ref]$errors)
foreach($name in @('Assert-PersonalPolicyChanges','Add-Check')) {
    $function=$workerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if($null -eq $function){throw ('Missing worker function: '+$name)}
    Invoke-Expression $function.Extent.Text
}
$diagnostic=$helperAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ClientDiagnosticCode'},$true)
Invoke-Expression $diagnostic.Extent.Text
$script:Count=0
function Assert([bool]$Pass,[string]$Message){if(-not $Pass){throw $Message};$script:Count++}
function Reset-Test {
    $script:Checks=New-Object 'System.Collections.Generic.List[object]'
    $script:Domain=$false;$script:CimFailed=$false;$script:CimMissing=$false;$script:CimCalls=0;$script:CimDeadline=0;$script:JoinCalls=0
    $script:JoinSuccess=$true;$script:JoinStatus=2;$script:JoinTimeout=$false;$script:JoinThrows=$false
    $script:Mdm=$false;$script:Cloud=$false;$script:RegistryFails=$false;$script:RegistryEnumerationFails=$false;$script:Mutations=0
}
function Get-CimInstance {
    param($ClassName,$OperationTimeoutSec)
    $script:CimCalls++;$script:CimDeadline=$OperationTimeoutSec
    if($script:CimFailed){throw (New-Object TimeoutException('Isolated original CIM timeout'))}
    if($script:CimMissing){return [pscustomobject]@{}}
    return [pscustomobject]@{PartOfDomain=$script:Domain}
}
function Get-ClientNativeJoinState {
    $script:JoinCalls++
    if($script:JoinThrows){throw (New-Object InvalidOperationException('Isolated native join failure'))}
    return [pscustomobject]@{Success=$script:JoinSuccess;JoinStatus=$script:JoinStatus;TimedOut=$script:JoinTimeout;ErrorCode=0}
}
function Test-Path {
    param($LiteralPath)
    if($script:RegistryFails){throw (New-Object UnauthorizedAccessException('Isolated registry access denied'))}
    if($LiteralPath -like '*OMADM*'){return $script:Mdm}
    if($LiteralPath -like '*CloudDomainJoin*'){return $script:Cloud}
    throw 'Unexpected registry path in guard.'
}
function Get-ChildItem {
    param($LiteralPath)
    if($script:RegistryEnumerationFails){throw (New-Object UnauthorizedAccessException('Isolated registry enumeration denied'))}
    return @([pscustomobject]@{Name='Managed enrollment'})
}
function Unexpected-Mutation {$script:Mutations++;throw 'Forbidden Windows mutation from guard.'}
function Set-SmbClientConfiguration {Unexpected-Mutation}
function Set-SmbServerConfiguration {Unexpected-Mutation}
function Set-Service {Unexpected-Mutation}
function Set-Acl {Unexpected-Mutation}
function New-ItemProperty {Unexpected-Mutation}
function Remove-ItemProperty {Unexpected-Mutation}
function Rename-Computer {Unexpected-Mutation}
function New-SmbShare {Unexpected-Mutation}
function Remove-SmbShare {Unexpected-Mutation}
function Invoke-Guard {
    try {Assert-PersonalPolicyChanges;return $null}
    catch{return $_}
}
Reset-Test;$failure=Invoke-Guard
Assert ($null -eq $failure) 'Known personal non-domain PC rejected.'
Assert ($script:CimCalls -eq 1 -and $script:CimDeadline -eq 5 -and $script:JoinCalls -eq 0) 'Known CIM state queried repeatedly, unbounded, or needlessly used native fallback.'
Assert ($script:Mutations -eq 0) 'Guard mutated Windows.'
Reset-Test;$script:Domain=$true;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -match 'Domäne') 'CIM-confirmed domain PC accepted.'
Assert ($script:JoinCalls -eq 0 -and $script:Mutations -eq 0) 'Native fallback overrode a known domain restriction.'
foreach($status in @(1,2)) {
    Reset-Test;$script:CimFailed=$true;$script:JoinStatus=$status;$failure=Invoke-Guard
    Assert ($null -eq $failure -and $script:JoinCalls -eq 1) ('Confirmed native personal join state rejected: '+$status)
    Assert (@($script:Checks | Where-Object {$_.Name -eq 'Windows-Verwaltungsstatus lesen' -and $_.Code -match 'HRESULT'}).Count -eq 1) 'Original failed CIM code lost from warning.'
    Assert (@($script:Checks | Where-Object {$_.Code -eq 'CLIENT_NATIVE_JOIN_CONFIRMED'}).Count -eq 1) 'Native fallback confirmation not recorded.'
    Assert ($script:Mutations -eq 0) 'Fallback guard mutated Windows.'
}
Reset-Test;$script:CimFailed=$true;$script:JoinStatus=3;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -match 'Domäne') 'Native-confirmed domain PC accepted.'
Assert ($script:Mutations -eq 0) 'Domain rejection mutated Windows.'
foreach($status in @(0,4,-1)) {
    Reset-Test;$script:CimFailed=$true;$script:JoinStatus=$status;$failure=Invoke-Guard
    Assert ($null -ne $failure -and $failure.Exception.Message -eq 'Isolated original CIM timeout') ('Unknown native state lost original CIM failure or allowed changes: '+$status)
    Assert ($script:Mutations -eq 0) 'Unknown domain state mutated Windows.'
}
Reset-Test;$script:CimFailed=$true;$script:JoinSuccess=$false;$script:JoinTimeout=$true;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -eq 'Isolated original CIM timeout') 'Failed/timed-out native fallback replaced original CIM failure or accepted unknown state.'
Assert ($script:Mutations -eq 0) 'Native timeout mutated Windows.'
Reset-Test;$script:CimFailed=$true;$script:JoinThrows=$true;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -eq 'Isolated native join failure') 'Native fallback exception was hidden.'
Assert (@($script:Checks | Where-Object {$_.Name -eq 'Windows-Verwaltungsstatus lesen'}).Count -eq 1) 'Original CIM failure disappeared after a native fallback exception.'
foreach($fallback in @($false,$true)) {
    foreach($managed in @('Mdm','Cloud')) {
        Reset-Test;$script:CimFailed=$fallback
        if($managed -eq 'Mdm'){$script:Mdm=$true}else{$script:Cloud=$true}
        $failure=Invoke-Guard
        Assert ($null -ne $failure -and $failure.Exception.Message -match 'Geräteverwaltung') ('Managed state accepted: '+$managed+' fallback '+$fallback)
        Assert ($script:Mutations -eq 0) 'Managed device rejection mutated Windows.'
    }
}
Reset-Test;$script:RegistryFails=$true;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -eq 'Isolated registry access denied') 'Registry management check failure silently treated as personal PC.'
Assert ($script:Mutations -eq 0) 'Registry check failure mutated Windows.'
Reset-Test;$script:Mdm=$true;$script:RegistryEnumerationFails=$true;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -eq 'Isolated registry enumeration denied') 'Registry management enumeration failure silently ignored.'
Reset-Test;$script:CimMissing=$true;$script:JoinStatus=3;$failure=Invoke-Guard
Assert ($null -ne $failure -and $failure.Exception.Message -match 'Domäne') 'Missing CIM PartOfDomain bypassed the native domain guard.'
Write-Host ('Personal policy guard: '+$script:Count+' isolated checks passed; no Windows or network changes.')
