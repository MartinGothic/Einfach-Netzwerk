param([string]$WorkerPath = (Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Exercise the original production SMB integration function with a static
# protocol-probe double. Nothing in this test reaches the network or changes
# shares, accounts, permissions, services, policies, registry or firewall.
# Run in a fresh Windows PowerShell 5.1 process; do not load the real app DLL.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$wanted = @('Get-Value', 'Add-Check', 'Test-RealSmbConnection')
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $true))
if ($definitions.Count -ne $wanted.Count) { throw 'Production SMB integration functions are missing.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

Add-Type -TypeDefinition @'
namespace EinfachNetzwerk {
  public static class SmbConnectionProbe {
    public static string Reply;
    public static bool Throw;
    public static int Calls;
    public static string Address;
    public static string Share;
    public static string Login;
    public static string Password;
    public static string ProbeJson(string address, string share, string login, string password) {
      Calls++;
      Address = address;
      Share = share;
      Login = login;
      Password = password;
      if (Throw) throw new System.InvalidOperationException("Synthetic probe transport failure");
      return Reply;
    }
  }
}
'@

$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
$script:PhaseCount = 0
$script:Network = [pscustomobject]@{ Address = '192.168.178.24' }
$script:Request = [pscustomobject]@{ Mode = 'Guest'; ShareName = 'Desktop'; DryRun = $false }
$script:SentinelPassword = 'Isolated-Test-Secret-Do-Not-Report'
function Write-Phase { param($Text) $script:PhaseCount++ }
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fresh-Test {
    $script:Checks = New-Object 'System.Collections.Generic.List[object]'
    $script:Result = [ordered]@{ ConnectionVerified = $true; LoginUserName = ''; Message = '' }
    $script:PhaseCount = 0
    $script:Request = [pscustomobject]@{ Mode = 'Guest'; ShareName = 'Desktop'; DryRun = $false }
    [EinfachNetzwerk.SmbConnectionProbe]::Calls = 0
    [EinfachNetzwerk.SmbConnectionProbe]::Throw = $false
    [EinfachNetzwerk.SmbConnectionProbe]::Address = ''
    [EinfachNetzwerk.SmbConnectionProbe]::Share = ''
    [EinfachNetzwerk.SmbConnectionProbe]::Login = ''
    [EinfachNetzwerk.SmbConnectionProbe]::Password = ''
    Set-Probe @{ Success = $true; LoginSucceeded = $true; TreeConnected = $true; DirectoryListed = $true; GuestSession = $false; Stage = 'Complete'; Error = '' }
}
function Set-Probe($Fields) { [EinfachNetzwerk.SmbConnectionProbe]::Reply = ConvertTo-Json -InputObject $Fields -Compress }
function Assert-NotVerified {
    Assert-Test (-not $script:Result.ConnectionVerified) 'An incomplete SMB exchange was marked verified.'
    Assert-Test (@($script:Checks | Where-Object { $_.Code -eq 'SMB_SESSION_VERIFIED' }).Count -eq 0) 'An incomplete SMB exchange emitted a success check.'
    Assert-Test (@($script:Checks | Where-Object { $_.Code -eq 'SMB_CONNECTION_FAILED' -and $_.State -eq 'error' }).Count -eq 1) 'A failed probe should report one clear error check.'
}
function Check([string]$Name, [scriptblock]$Body) {
    Fresh-Test
    try { & $Body; $passed.Add($Name) }
    catch { $failed.Add($Name + ': ' + $_.Exception.Message) }
}

Check 'Successful login, tree connect and directory listing verify the real connection' {
    Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $true
    Assert-Test $script:Result.ConnectionVerified 'A fully successful probe was rejected.'
    Assert-Test ([EinfachNetzwerk.SmbConnectionProbe]::Calls -eq 1) 'The probe did not run exactly once.'
    Assert-Test (@($script:Checks | Where-Object { $_.Code -eq 'SMB_SESSION_VERIFIED' -and $_.State -eq 'ok' }).Count -eq 1) 'A successful probe did not produce a verified connection check.'
}

foreach ($missing in @('Success', 'LoginSucceeded', 'TreeConnected', 'DirectoryListed')) {
    $stageField = $missing
    Check ('Incomplete ' + $stageField + ' prevents verification') {
        $reply = @{ Success = $true; LoginSucceeded = $true; TreeConnected = $true; DirectoryListed = $true; GuestSession = $false; Stage = $stageField; Error = 'Synthetic incomplete protocol stage' }
        $reply[$stageField] = $false
        Set-Probe $reply
        Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $false
        Assert-NotVerified
    }
}

Check 'Password mode rejects silent fallback to a guest SMB session' {
    $script:Request.Mode = 'Password'
    Set-Probe @{ Success = $true; LoginSucceeded = $true; TreeConnected = $true; DirectoryListed = $true; GuestSession = $true; Stage = 'Complete'; Error = '' }
    Test-RealSmbConnection $script:Request $script:Network 'ShareUser' $script:SentinelPassword $false
    Assert-NotVerified
    Assert-Test ($script:Checks[0].Detail -match 'Gast') 'Guest fallback should explain why password authentication was not verified.'
}

Check 'Explicit guest mode accepts a successful guest session' {
    Set-Probe @{ Success = $true; LoginSucceeded = $true; TreeConnected = $true; DirectoryListed = $true; GuestSession = $true; Stage = 'Complete'; Error = '' }
    Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $true
    Assert-Test $script:Result.ConnectionVerified 'An explicitly requested successful guest session was rejected.'
}

Check 'Required failures throw and cannot be reported as verified' {
    Set-Probe @{ Success = $false; LoginSucceeded = $false; TreeConnected = $false; DirectoryListed = $false; GuestSession = $false; Stage = 'SessionSetup'; Error = 'Synthetic authentication failure' }
    $caught = $false
    try { Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $true }
    catch { $caught = $true; Assert-Test ($_.Exception.Message -match 'SessionSetup') 'The required failure lost its protocol stage.' }
    Assert-Test $caught 'A required failed probe did not stop the action.'
    Assert-NotVerified
}

Check 'Optional failures produce a diagnostic check without throwing' {
    Set-Probe @{ Success = $false; LoginSucceeded = $true; TreeConnected = $false; DirectoryListed = $false; GuestSession = $false; Stage = 'TreeConnect'; Error = 'Synthetic access denied' }
    Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $false
    Assert-NotVerified
    Assert-Test ($script:Checks[0].Fixable -and -not [string]::IsNullOrEmpty($script:Checks[0].NextStep)) 'Optional failure omitted actionable diagnostic guidance.'
}

Check 'Optional transport exceptions produce one check and remain unverified' {
    [EinfachNetzwerk.SmbConnectionProbe]::Throw = $true
    Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $false
    Assert-NotVerified
}

Check 'Required transport exceptions throw without a false success result' {
    [EinfachNetzwerk.SmbConnectionProbe]::Throw = $true
    $caught = $false
    try { Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $true } catch { $caught = $true }
    Assert-Test $caught 'A required transport exception was swallowed.'
    Assert-Test (-not $script:Result.ConnectionVerified) 'A failed transport kept an earlier verified state.'
}

Check 'Dry run never executes a protocol probe or a progress phase' {
    $script:Request.DryRun = $true
    Test-RealSmbConnection $script:Request $script:Network 'Gast' '' $true
    Assert-Test ([EinfachNetzwerk.SmbConnectionProbe]::Calls -eq 0 -and $script:PhaseCount -eq 0) 'Dry run executed the real-protocol integration.'
    Assert-Test (-not $script:Result.ConnectionVerified -and $script:Checks.Count -eq 0) 'Dry run claimed verification it never performed.'
}

Check 'Missing network never executes a protocol probe' {
    Test-RealSmbConnection $script:Request $null 'Gast' '' $true
    Assert-Test ([EinfachNetzwerk.SmbConnectionProbe]::Calls -eq 0 -and -not $script:Result.ConnectionVerified) 'Missing network executed a probe or claimed verification.'
}

Check 'Displayed account equals the actual computer-qualified probe account' {
    Test-RealSmbConnection $script:Request $script:Network 'RenamedGuest' '' $true
    $expectedLogin = $env:COMPUTERNAME + '\RenamedGuest'
    Assert-Test ([EinfachNetzwerk.SmbConnectionProbe]::Login -ceq $expectedLogin -and $script:Result.LoginUserName -ceq $expectedLogin) 'Displayed login differs from the probe login.'
    Assert-Test ([EinfachNetzwerk.SmbConnectionProbe]::Address -eq $script:Network.Address -and [EinfachNetzwerk.SmbConnectionProbe]::Share -eq 'Desktop') 'The actual SMB endpoint differs from the selected endpoint.'
    Assert-Test ($script:Checks[0].Detail.Contains($expectedLogin)) 'Verified detail omits the real account used.'
}

Check 'Password reaches only the probe and never result or diagnostic reports' {
    $script:Request.Mode = 'Password'
    Test-RealSmbConnection $script:Request $script:Network 'ShareUser' $script:SentinelPassword $true
    Assert-Test ([EinfachNetzwerk.SmbConnectionProbe]::Password -ceq $script:SentinelPassword) 'Password did not reach the private probe argument.'
    $serialized = ConvertTo-Json -InputObject @{ Result = $script:Result; Checks = @($script:Checks.ToArray()) } -Depth 8
    Assert-Test (-not $serialized.Contains($script:SentinelPassword)) 'Password leaked into a worker result or diagnostic check.'
    Fresh-Test
    $script:Request.Mode = 'Password'
    Set-Probe @{ Success = $false; LoginSucceeded = $false; TreeConnected = $false; DirectoryListed = $false; GuestSession = $false; Stage = 'SessionSetup'; Error = 'Synthetic invalid credentials' }
    Test-RealSmbConnection $script:Request $script:Network 'ShareUser' $script:SentinelPassword $false
    $serialized = ConvertTo-Json -InputObject @{ Result = $script:Result; Checks = @($script:Checks.ToArray()) } -Depth 8
    Assert-Test (-not $serialized.Contains($script:SentinelPassword)) 'Password leaked into a failure diagnostic.'
}

[EinfachNetzwerk.SmbConnectionProbe]::Password = ''
$report = [pscustomobject]@{ PowerShell = $PSVersionTable.PSVersion.ToString(); Isolation = 'Production integration function with a static protocol-probe double; no real network or Windows mutations'; Passed = @($passed.ToArray()); Failed = @($failed.ToArray()); PassedCount = $passed.Count; FailedCount = $failed.Count }
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'smb-integration-test-results.json') -Encoding UTF8
$report | Format-List
if ($failed.Count -gt 0) { throw 'SMB integration regression tests failed.' }
