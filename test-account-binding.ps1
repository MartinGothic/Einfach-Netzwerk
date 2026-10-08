param([string]$WorkerPath = (Join-Path $PSScriptRoot 'ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Read-only regression for Add-LocalGroupMember's real Windows Member type.
# An actual LocalUser object is read, but the production command is executed
# against a typed function double. No account or group membership is changed.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-LocalGroupMember' }, $true))
if ($commands.Count -ne 1) { throw 'Expected one unqualified production group membership command.' }
$memberType = (Get-Command -Name 'Microsoft.PowerShell.LocalAccounts\Add-LocalGroupMember' -CommandType Cmdlet).Parameters['Member'].ParameterType
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$user = Microsoft.PowerShell.LocalAccounts\Get-LocalUser -SID $currentSid
if ($null -eq $user) { throw 'A real current local Windows account is required for this read-only binding regression.' }

$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Check([string]$Name, [scriptblock]$Body) { try { & $Body; $passed.Add($Name) } catch { $failed.Add($Name + ': ' + $_.Exception.Message) } }
$script:Captured = $null
function Add-LocalGroupMember {
    param([Security.Principal.SecurityIdentifier]$SID, [Microsoft.PowerShell.Commands.LocalPrincipal[]]$Member)
    $script:Captured = [pscustomobject]@{ GroupSid = $SID.Value; Members = $Member }
}

Check 'Typed test double matches the real Windows LocalPrincipal array parameter' {
    Assert-Test ($memberType -eq [Microsoft.PowerShell.Commands.LocalPrincipal[]]) 'Windows Add-LocalGroupMember Member has an unexpected type.'
    $doubleType = (Get-Command -Name Add-LocalGroupMember -CommandType Function).Parameters['Member'].ParameterType
    Assert-Test ($doubleType -eq $memberType) 'The isolated double does not reproduce the real cmdlet Member type.'
}

Check 'The real LocalUser object converts to the Windows group-member parameter type' {
    $converted = [Management.Automation.LanguagePrimitives]::ConvertTo($user, $memberType)
    Assert-Test ($converted.Count -eq 1 -and $converted[0].SID.Value -eq $user.SID.Value) 'Converting LocalUser to LocalPrincipal[] loses the actual account.'
}

Check 'Production group-membership invocation binds the real LocalUser without mutation' {
    . ([scriptblock]::Create($commands[0].Extent.Text))
    Assert-Test ($null -ne $script:Captured) 'The production command did not reach the isolated typed double.'
    Assert-Test ($script:Captured.GroupSid -eq 'S-1-5-32-545') 'The production command did not target the built-in Users group.'
    Assert-Test ($script:Captured.Members.Count -eq 1 -and $script:Captured.Members[0].SID.Value -eq $user.SID.Value) 'The production command did not bind the actual created-account shape.'
}

Check 'A SecurityIdentifier cannot substitute for a Windows LocalPrincipal member' {
    $rejected = $false
    try { $null = [Management.Automation.LanguagePrimitives]::ConvertTo($user.SID, $memberType) } catch { $rejected = $true }
    Assert-Test $rejected 'The old invalid SID argument unexpectedly converted to LocalPrincipal[].'
}

$report = [pscustomobject]@{ PowerShell = $PSVersionTable.PSVersion.ToString(); Isolation = 'Read actual Windows parameter metadata and current LocalUser; production command runs against a typed function double; no account or group mutation'; Passed = @($passed.ToArray()); Failed = @($failed.ToArray()); PassedCount = $passed.Count; FailedCount = $failed.Count }
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'account-binding-test-results.json') -Encoding UTF8
$report | Format-List
if ($failed.Count -gt 0) { throw 'Account-binding regression tests failed.' }
