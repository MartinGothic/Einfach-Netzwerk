param([string]$WorkerPath = (Join-Path $PSScriptRoot 'ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# Call the original production verification with isolated cmdlet doubles.
# No firewall, service, profile, account, folder ACL or share is changed.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$wanted=@('Get-Value','Get-Subnet','Normalize-IPv4FirewallScope','Test-IPv4FirewallScope','Test-ManagedSmbFirewallRule','Advanced-Repair','Get-LocalShareProblems','Confirm-AndRepairLocalShare')
$definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted},$true))
if ($definitions.Count -ne $wanted.Count) { throw 'Production firewall verification functions are missing.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$script:Request=[pscustomobject]@{ShareName='Fixture';Mode='Guest';AllowAdvancedRepair=$false;AllowWrite=$false}
$script:Folder=[pscustomobject]@{Path='D:\IsolatedFixture';Format='exFAT'}
$script:Network=[pscustomobject]@{Id=51;Name='Ethernet';Address='192.168.178.24';Subnet='192.168.178.0/24'}
$script:Rule=$null
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
$script:Result=[ordered]@{RetryCount=0}
$passed=New-Object 'System.Collections.Generic.List[string]'
$failed=New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition,[string]$Message) {if(-not $Condition){throw $Message}}
function Check([string]$Name,[scriptblock]$Body) {try{& $Body;$passed.Add($Name)}catch{$failed.Add($Name+': '+$_.Exception.Message)}}
function Rule-Prefix {param($Name) 'Fixture-'}
function Get-NetConnectionProfile {param($InterfaceIndex) [pscustomobject]@{NetworkCategory='Private'}}
function Get-SmbServerConfiguration {[pscustomobject]@{EnableSMB2Protocol=$true}}
function Get-Service {param($Name) [pscustomobject]@{Status='Running'}}
function Get-ShareSnapshot {param($Name) [pscustomobject]@{Path='D:\IsolatedFixture';SecurityDescriptor='D:(A;;FR;;;S-1-5-7)'}}
function Get-FirewallSnapshots {param($Prefix) $script:Rule}
function Write-Phase {param($Text)}
function Add-Check {param($Name,$State,$Detail,$Code,$Fixable,$NextStep) $script:Checks.Add([pscustomobject]@{Name=$Name;State=$State;Code=$Code})}
function Fresh-Rule {
    return [pscustomobject]@{Name='Fixture-SMB';Enabled='True';Profile='Private';Direction='Inbound';Action='Allow';Protocol='TCP';LocalPort=@('445');RemotePort=@('Any');LocalAddress=@('192.168.178.24');RemoteAddress=@('192.168.178.0/255.255.255.0');Program='System';Service='Any';InterfaceAlias=@('Ethernet')}
}
function Verify-OriginalLocalPredicate([bool]$ExpectedFirewall) {
    $problems=@(Get-LocalShareProblems $script:Request $script:Folder $script:Network @('S-1-5-7'))
    Assert-Test (('Firewall' -in $problems) -eq $ExpectedFirewall) ('Original local verifier returned unexpected problems: '+($problems -join ','))
    Assert-Test (@($problems | Where-Object {$_ -ne 'Firewall'}).Count -eq 0) 'Fixture unexpectedly failed an unrelated production verification.'
}
Check 'Actual Windows dotted netmask representation passes the original local verifier' {
    $script:Rule=Fresh-Rule
    Verify-OriginalLocalPredicate $false
    Confirm-AndRepairLocalShare $script:Request $script:Folder $script:Network @('S-1-5-7') 'S-1-5-21-1-2-3-1000'
    Assert-Test ($script:Result.RetryCount -eq 1 -and @($script:Checks | Where-Object {$_.Code -eq 'LOCAL_VERIFIED'}).Count -eq 1) 'A valid normalized firewall rule triggered a repair retry or failed actual confirmation.'
}
Check 'CIDR subnet and explicit /32 local address are equivalent to native firewall values' {
    $script:Rule=Fresh-Rule
    $script:Rule.LocalAddress=@('192.168.178.24/255.255.255.255')
    $script:Rule.RemoteAddress=@('192.168.178.0/24')
    Verify-OriginalLocalPredicate $false
}
Check 'A wider subnet remains a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.RemoteAddress=@('192.168.178.0/255.255.254.0');Verify-OriginalLocalPredicate $true}
Check 'Any never counts as an exact home subnet' {$script:Rule=Fresh-Rule;$script:Rule.RemoteAddress=@('Any');Verify-OriginalLocalPredicate $true}
Check 'Additional remote subnets remain a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.RemoteAddress=@('192.168.178.0/24','192.168.179.0/24');Verify-OriginalLocalPredicate $true}
Check 'A noncontiguous dotted mask is rejected' {$script:Rule=Fresh-Rule;$script:Rule.RemoteAddress=@('192.168.178.0/255.0.255.0');Verify-OriginalLocalPredicate $true}
Check 'A broad local subnet is rejected even when the selected IPv4 belongs to it' {$script:Rule=Fresh-Rule;$script:Rule.LocalAddress=@('192.168.178.0/24');Verify-OriginalLocalPredicate $true}
Check 'Additional interfaces remain a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.InterfaceAlias=@('Ethernet','WLAN');Verify-OriginalLocalPredicate $true}
Check 'Disabled rules remain a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.Enabled='False';Verify-OriginalLocalPredicate $true}
Check 'Public profile rules remain a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.Profile='Public';Verify-OriginalLocalPredicate $true}
Check 'Wrong SMB protocol remains a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.Protocol='UDP';Verify-OriginalLocalPredicate $true}
Check 'Wrong SMB port remains a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.LocalPort=@('446');Verify-OriginalLocalPredicate $true}
Check 'Broad SMB ports remain a firewall problem' {$script:Rule=Fresh-Rule;$script:Rule.LocalPort=@('445','446');Verify-OriginalLocalPredicate $true}
Check 'Wrong direction and action remain a firewall problem' {
    $script:Rule=Fresh-Rule;$script:Rule.Direction='Outbound';Verify-OriginalLocalPredicate $true
    $script:Rule=Fresh-Rule;$script:Rule.Action='Block';Verify-OriginalLocalPredicate $true
}
Check 'Invalid legacy IPv4 notation and prefix bounds are rejected' {
    foreach($scope in @('Any','LocalSubnet','192.168.178','3232281112','192.168.178.0/33','192.168.178.0/-1','192.168.178.0/24/32','192.168.178.0/255.255.256.0')) {
        Assert-Test ([string]::IsNullOrEmpty((Normalize-IPv4FirewallScope $scope))) ('Invalid scope was normalized: '+$scope)
    }
}
$report=[pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString();Passed=@($passed.ToArray());Failed=@($failed.ToArray());PassedCount=$passed.Count;FailedCount=$failed.Count}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'firewall-scope-test-results.json') -Encoding UTF8
$report | Format-List
if($failed.Count -gt 0){throw 'Firewall scope regression tests failed.'}
