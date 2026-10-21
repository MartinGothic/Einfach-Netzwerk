param([string]$WorkerPath = (Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# The original post-commit cleanup helpers run against in-memory share/user
# inventories. Every account deletion is a function double, never a cmdlet.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$wanted = @('Get-Value', 'Add-Check', 'Remove-CreatedUser', 'Test-CreatedUserReferenced', 'Remove-UnusedCreatedUsers')
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $true))
if ($definitions.Count -ne $wanted.Count) { throw 'Account cleanup function definitions are missing.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$script:AppMark = 'EinfachNetzwerk-v1'
$script:UserSid = 'S-1-5-21-1-2-3-1200'
$script:OtherSid = 'S-1-5-21-1-2-3-1201'
$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fresh-Test {
    $script:Created = [pscustomobject]@{ Name = 'ShareOnly'; Sid = $script:UserSid }
    $script:Ledger = [pscustomobject]@{ Shares = @([pscustomobject]@{ Name = 'Desktop'; Mode = 'Guest'; UserName = 'Gast'; UserSid = '' }); CreatedUsers = @($script:Created) }
    $script:LiveShares = @([pscustomobject]@{ Name = 'Desktop'; SecurityDescriptor = 'O:BAG:BAD:(A;;FA;;;BA)(A;;FR;;;LG)' })
    $script:Users = @{ ShareOnly = [pscustomobject]@{ Name = 'ShareOnly'; SID = (New-Object Security.Principal.SecurityIdentifier($script:UserSid)); Description = $script:AppMark } }
    $script:DeletedSids = New-Object 'System.Collections.Generic.List[string]'
    $script:Checks = New-Object 'System.Collections.Generic.List[object]'
    $script:InventoryFailed = $false
}
function Check([string]$Name, [scriptblock]$Body) { Fresh-Test; try { & $Body; $passed.Add($Name) } catch { $failed.Add($Name + ': ' + $_.Exception.Message) } }
function Get-SmbShare { param($ErrorAction) if ($script:InventoryFailed) { throw 'Synthetic unreadable SMB inventory' }; $script:LiveShares }
function Get-LocalUser { param($Name, $ErrorAction) if ($script:Users.ContainsKey($Name)) { $script:Users[$Name] } }
function Remove-LocalUser {
    param([Security.Principal.SecurityIdentifier]$SID)
    $script:DeletedSids.Add($SID.Value)
    foreach ($key in @($script:Users.Keys)) { if ($script:Users[$key].SID.Value -eq $SID.Value) { $script:Users.Remove($key) } }
}
function Assert-Preserved {
    Assert-Test ($script:DeletedSids.Count -eq 0 -and $script:Ledger.CreatedUsers.Count -eq 1) 'An account in use or unsafe to inspect was deleted or lost its ownership record.'
}
function Assert-Warned {
    Assert-Preserved
    Assert-Test (@($script:Checks | Where-Object { $_.Name -eq 'Kontobereinigung' -and $_.State -eq 'warning' }).Count -eq 1) 'Unsafe cleanup did not produce one retained-account warning.'
}

Check 'Unused owned account is removed while another managed guest share remains' {
    Remove-UnusedCreatedUsers
    Assert-Test ($script:DeletedSids.Count -eq 1 -and $script:DeletedSids[0] -eq $script:UserSid) 'Unused account was not pruned.'
    Assert-Test ($script:Ledger.CreatedUsers.Count -eq 0 -and $script:Ledger.Shares.Count -eq 1 -and $script:Ledger.Shares[0].Name -eq 'Desktop') 'Cleanup changed another managed share or kept a deleted ownership entry.'
}
Check 'Another managed share using the same account SID preserves it' {
    $script:Ledger.Shares += [pscustomobject]@{ Name = 'Documents'; UserSid = $script:UserSid; UserName = 'DifferentSpelling' }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'Another managed share using the same account name preserves it without a SID' {
    $script:Ledger.Shares += [pscustomobject]@{ Name = 'Documents'; UserSid = ''; UserName = 'shareonly' }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'A computer-qualified managed account name also preserves the account' {
    $script:Ledger.Shares += [pscustomobject]@{ Name = 'Documents'; UserSid = ''; UserName = 'ANOTHER-PC\ShareOnly' }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'A foreign SMB share with an explicit account allow ACE preserves it' {
    $script:LiveShares += [pscustomobject]@{ Name = 'Foreign'; SecurityDescriptor = ('D:(A;;FR;;;' + $script:UserSid + ')') }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'A special SMB share with an explicit account deny ACE preserves it' {
    $script:LiveShares += [pscustomobject]@{ Name = 'Foreign$'; Special = $true; SecurityDescriptor = ('D:(D;;FR;;;' + $script:UserSid + ')') }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'An explicit share descriptor owner reference preserves the account' {
    $script:LiveShares += [pscustomobject]@{ Name = 'OwnedElsewhere'; SecurityDescriptor = ('O:' + $script:UserSid + 'G:BAD:(A;;FR;;;BA)') }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'An explicit share audit reference preserves the account' {
    $script:LiveShares += [pscustomobject]@{ Name = 'AuditedElsewhere'; SecurityDescriptor = ('D:(A;;FR;;;BA)S:(AU;SA;FR;;;' + $script:UserSid + ')') }
    Remove-UnusedCreatedUsers
    Assert-Preserved
}
Check 'Broad Users and Everyone grants are not explicit reuse of a dedicated account' {
    $script:LiveShares += [pscustomobject]@{ Name = 'Public'; SecurityDescriptor = 'D:(A;;FR;;;BU)(A;;FR;;;WD)' }
    Remove-UnusedCreatedUsers
    Assert-Test ($script:DeletedSids.Count -eq 1 -and $script:Ledger.CreatedUsers.Count -eq 0) 'Broad group grants prevented deletion of every unused dedicated account.'
}
Check 'Malformed SMB share permissions retain the account with a warning' {
    $script:LiveShares += [pscustomobject]@{ Name = 'Unreadable'; SecurityDescriptor = 'not-sddl' }
    Remove-UnusedCreatedUsers
    Assert-Warned
}
Check 'Missing SMB share permissions retain the account with a warning' {
    $script:LiveShares += [pscustomobject]@{ Name = 'Unreadable'; SecurityDescriptor = '' }
    Remove-UnusedCreatedUsers
    Assert-Warned
}
Check 'An unreadable SMB share inventory retains the account with a warning' {
    $script:InventoryFailed = $true
    Remove-UnusedCreatedUsers
    Assert-Warned
}
Check 'Changed account description is protected by the original ownership guard' {
    $script:Users['ShareOnly'].Description = 'Owned by someone else now'
    Remove-UnusedCreatedUsers
    Assert-Warned
}
Check 'A replacement account with the same name and different SID is preserved' {
    $script:Users['ShareOnly'].SID = New-Object Security.Principal.SecurityIdentifier($script:OtherSid)
    Remove-UnusedCreatedUsers
    Assert-Warned
}
Check 'An already absent dedicated account drops only its stale ownership entry' {
    $script:Users.Remove('ShareOnly')
    Remove-UnusedCreatedUsers
    Assert-Test ($script:DeletedSids.Count -eq 0 -and $script:Ledger.CreatedUsers.Count -eq 0) 'Absent account cleanup changed an unrelated account or retained stale ownership.'
}
Check 'Invalid stored account SID fails closed without deleting a local account' {
    $script:Created.Sid = 'invalid-sid'
    Remove-UnusedCreatedUsers
    Assert-Warned
}

$report = [pscustomobject]@{ PowerShell = $PSVersionTable.PSVersion.ToString(); Isolation = 'Production account cleanup helpers with in-memory SMB and account inventories; no real Windows mutations'; Passed = @($passed.ToArray()); Failed = @($failed.ToArray()); PassedCount = $passed.Count; FailedCount = $failed.Count }
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'account-cleanup-test-results.json') -Encoding UTF8
$report | Format-List
if ($failed.Count -gt 0) { throw 'Account cleanup regression tests failed.' }
