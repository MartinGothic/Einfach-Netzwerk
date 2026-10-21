param([string]$WorkerPath = (Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Production progress/check functions only. The worker entry point is never run.
# All Windows reads are doubles and all state/files belong to a private temp dir.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$functions = @{}
foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $functions[$definition.Name] = $definition }
foreach ($name in @('Get-Value', 'Add-Check', 'Initialize-WorkProgress', 'Complete-WorkStep', 'Write-Phase', 'Inspect-State')) {
    if (-not $functions.ContainsKey($name)) { throw ('Missing production function: ' + $name) }
    . ([scriptblock]::Create($functions[$name].Extent.Text))
}

$testRoot = Join-Path $env:TEMP ('EinfachNetzwerk-progress-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:PhaseStream = $null
$script:WorkPlan = $null
$script:WorkCompleted = $null
$script:WorkText = ''
$script:ReadCalls = New-Object 'System.Collections.Generic.List[string]'
$passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function New-TestPlan([string]$Action, [bool]$DryRun = $false) {
    if ($null -ne $script:PhaseStream) { $script:PhaseStream.Dispose() }
    $script:PhaseStream = $null
    $script:ResultPath = Join-Path $testRoot ([Guid]::NewGuid().ToString('N') + '.json')
    $script:WorkPlan = $null; $script:WorkCompleted = $null; $script:WorkText = 'Prüfung läuft …'
    Initialize-WorkProgress $Action $DryRun
}
function Read-Progress {
    $stream = New-Object IO.FileStream(($script:ResultPath + '.phase'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
}
function Complete-Preparation { foreach ($name in @('request', 'access', 'ledger', 'computer', 'network', 'selection')) { Complete-WorkStep $name } }
function Read-ShareInventory { $script:ReadCalls.Add('shares'); $script:Result.Shares = @() }
function Get-ServiceSnapshot { param($Name) $script:ReadCalls.Add($Name); [pscustomobject]@{ State = 'Running'; StartMode = 'Auto' } }
function Get-SmbServerConfiguration { $script:ReadCalls.Add('smb'); $script:CompletedDuringSmb = $script:WorkCompleted.Count; if ($script:FailSmbRead) { throw 'Fixture read failure.' }; [pscustomobject]@{ EnableSMB2Protocol = $true; EnableSMB1Protocol = $false; RequireSecuritySignature = $true; EncryptData = $false } }
function Get-NetTCPConnection { param($State, $LocalPort) $script:ReadCalls.Add('port'); [pscustomobject]@{ State = 'Listen'; LocalPort = 445 } }
function Get-NetFirewallProfile { param($Name, $PolicyStore) $script:ReadCalls.Add('firewall'); [pscustomobject]@{ Enabled = $true; AllowInboundRules = 'NotConfigured' } }
function Inspect-OtherSmbRules { param($Network) $script:ReadCalls.Add('firewall-rules') }
function Inspect-DiscoveryReadiness { $script:ReadCalls.Add('discovery-readiness') }

try {
    New-TestPlan 'Inspect'
    $p = Read-Progress
    Assert-Test ($p.Percent -eq 0 -and $p.Completed -eq 0 -and $p.Total -eq $script:WorkPlan.Count) 'Progress must start at zero completed work.'
    Assert-Test ($script:WorkPlan[-1] -eq 'client-confirmation') 'Client result confirmation must be reserved.'
    Complete-WorkStep 'request'
    $p = Read-Progress
    Assert-Test ($p.Completed -eq 1 -and $p.Percent -eq [Math]::Floor(100.0 / $p.Total)) 'Reported percentage is not the counted fraction.'
    Write-Phase 'Andere Phase ohne erledigte Arbeit …'
    $q = Read-Progress
    Assert-Test ($q.Completed -eq $p.Completed -and $q.Percent -eq $p.Percent -and $q.Text -eq 'Andere Phase ohne erledigte Arbeit …') 'Changing the phase fabricated progress or lost UTF-8 text.'
    Complete-WorkStep 'request'; Complete-WorkStep 'unplanned-step'
    $q = Read-Progress
    Assert-Test ($q.Completed -eq 1) 'Duplicate/retry or unplanned work was counted.'
    foreach ($name in $script:WorkPlan | Where-Object { $_ -ne 'client-confirmation' }) { Complete-WorkStep $name }
    $p = Read-Progress
    Assert-Test ($p.Completed -eq $p.Total - 1 -and $p.Percent -lt 100) 'Worker claimed successful client result confirmation.'
    Write-Phase 'Fehler und Rücknahme …'
    $q = Read-Progress
    Assert-Test ($q.Percent -eq $p.Percent -and $q.Percent -lt 100) 'Failure/rollback fabricated completion.'

    foreach ($action in @('Inspect', 'Apply', 'Repair', 'Remove', 'Restore', 'RemoveListedShare', 'RepairSystem', 'Rename', 'InspectRemote', 'ConnectRemote', 'RepairClient', 'RestoreClient')) {
        foreach ($dryRun in @($false, $true)) {
            New-TestPlan $action $dryRun
            Assert-Test (@($script:WorkPlan | Select-Object -Unique).Count -eq $script:WorkPlan.Count) ($action + ': duplicate planned work units.')
            foreach ($name in $script:WorkPlan | Where-Object { $_ -ne 'client-confirmation' }) { Complete-WorkStep $name }
            $p = Read-Progress
            Assert-Test ($p.Completed -eq $p.Total - 1 -and $p.Percent -eq [Math]::Floor(100.0 * $p.Completed / $p.Total) -and $p.Percent -lt 100) ($action + ': incorrect completion fraction.')
            if ($dryRun -and $action -in @('Apply', 'Repair', 'Remove', 'Restore', 'RemoveListedShare')) {
                Assert-Test ('dryrun-evaluation' -in $script:WorkPlan -and 'apply-commit' -notin $script:WorkPlan -and 'remove-commit' -notin $script:WorkPlan -and 'listed-removal' -notin $script:WorkPlan) ($action + ': dry run counted unapplied configuration.')
            }
        }
    }

    foreach ($fail in @($false, $true)) {
        New-TestPlan 'Inspect'
        Complete-Preparation
        $script:Checks = New-Object 'System.Collections.Generic.List[object]'
        $script:Result = [ordered]@{ Shares = @() }
        $script:ReadCalls.Clear(); $script:FailSmbRead = $fail
        $request = [pscustomobject]@{ Mode = 'Password'; ShareName = '' }
        $network = [pscustomobject]@{ Name = 'Test LAN'; Address = '192.168.178.24'; Subnet = '192.168.178.0/24'; Category = 'Private' }
        Inspect-State $request $network $null
        $p = Read-Progress
        Assert-Test ($p.Completed -eq 17) 'Inspection did not count its eleven actually completed check/decision groups.'
        Assert-Test ($script:CompletedDuringSmb -eq 12) 'The SMB work unit advanced before its Windows read completed.'
        Assert-Test (($script:ReadCalls -join ',') -eq 'shares,LanmanServer,LanmanWorkstation,FDResPub,fdPHost,smb,port,firewall,firewall-rules,discovery-readiness') 'Fixture inspection did not execute its actual Windows read groups.'
        Assert-Test ($p.Percent -eq [Math]::Floor(1700.0 / $p.Total) -and $p.Percent -lt 100) 'Inspection reported progress beyond actual completed groups.'
        Assert-Test ((@($script:Checks | Where-Object { $_.State -eq 'error' }).Count -gt 0) -eq $fail) 'Inspection did not preserve success/error behavior.'
    }

    # Helpers remain harmless when only extracted functions are used by other QA.
    $script:WorkPlan = $null; $script:WorkCompleted = $null
    Complete-WorkStep 'request'
    Assert-Test ($null -eq $script:WorkCompleted) 'An uninitialized test plan was accidentally created.'
    Write-Host ('PASS: ' + $passed + ' isolated work-progress checks; no Windows configuration changes.')
} finally {
    if ($null -ne $script:PhaseStream) { $script:PhaseStream.Dispose() }
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedRoot) -notlike 'EinfachNetzwerk-progress-test-*') { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
