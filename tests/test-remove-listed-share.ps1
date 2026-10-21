param(
    [string]$WorkerPath = (Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'),
    [string]$RemoveFunction = 'Remove-ListedShare'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Only function definitions are extracted. The worker entry point is never
# evaluated. SMB reads and removal are in-memory doubles, so these tests cannot
# remove an existing Windows share or change files or security settings.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$functions = @{}
foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $functions[$definition.Name] = $definition }
if (-not $functions.ContainsKey($RemoveFunction)) { throw ('Production listed-share removal function is missing: ' + $RemoveFunction) }
$wanted = @('Get-Value', 'Get-Managed', 'Add-Check', 'Read-ShareInventory', $RemoveFunction)
$queue = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($name in $wanted) { $queue.Enqueue($name) }
$loaded = @{}
while ($queue.Count -gt 0) {
    $name = $queue.Dequeue()
    if ($loaded.ContainsKey($name)) { continue }
    if (-not $functions.ContainsKey($name)) { throw ('Required production helper is missing: ' + $name) }
    $definition = $functions[$name]
    $loaded[$name] = $true
    foreach ($command in @($definition.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = $command.GetCommandName()
        if ($commandName -in @('Is-Administrator', 'Write-Phase')) { continue }
        if ($functions.ContainsKey($commandName) -and -not $loaded.ContainsKey($commandName)) { $queue.Enqueue($commandName) }
    }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fresh-Test {
    $script:NativeShares = @([pscustomobject]@{ Name = 'Photos'; Path = 'D:\Photos'; Special = $false; ScopeName = '*' })
    $script:Ledger = [pscustomobject]@{ Shares = @(); CreatedUsers = @(); Version = 1 }
    $script:OriginalLedger = $script:Ledger | ConvertTo-Json -Depth 8 -Compress
    $script:Result = [ordered]@{ Success = $false; Message = ''; Shares = @(); ConnectionVerified = $true }
    $script:Checks = New-Object 'System.Collections.Generic.List[object]'
    $script:DeletedShares = New-Object 'System.Collections.Generic.List[object]'
    $script:ForbiddenCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:QueryFailure = ''; $script:QueryFailureAt = 0; $script:QueryCount = 0; $script:RemovalFailure = $false; $script:RemovalNoOp = $false
    $script:Administrator = $true
    $script:Request = [pscustomobject]@{ Action = 'RemoveListedShare'; ShareName = 'Photos'; FolderPath = 'D:\Photos'; DryRun = $false }
}
function Check([string]$Name, [scriptblock]$Body) { Fresh-Test; try { & $Body; $passed.Add($Name) } catch { $failed.Add($Name + ': ' + $_.Exception.Message) } }
function Is-Administrator { return $script:Administrator }
function Write-Phase { param($Text) }
function Get-SmbShare {
    [CmdletBinding()]
    param([string[]]$Name, [string[]]$ScopeName)
    $script:QueryCount++
    if ($script:QueryFailureAt -gt 0 -and $script:QueryCount -eq $script:QueryFailureAt) { throw 'Fixture later SMB query failed.' }
    if ($script:QueryFailure -eq 'Throw') { throw 'Fixture SMB query failed.' }
    if ($script:QueryFailure -eq 'NonTerminating') { Write-Error 'Fixture SMB query access denied.'; return }
    foreach ($share in $script:NativeShares) {
        if ($null -ne $Name -and $Name.Count -gt 0 -and $share.Name -notin $Name) { continue }
        if ($null -ne $ScopeName -and $ScopeName.Count -gt 0 -and $share.ScopeName -notin $ScopeName) { continue }
        $share
    }
}
function Remove-SmbShare {
    [CmdletBinding()]
    param([string[]]$Name, [string]$ScopeName, [Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force, [switch]$Confirm)
    process {
        if ($script:RemovalFailure) { throw 'Fixture SMB removal failed.' }
        $targets = @()
        if ($null -ne $InputObject) { $targets = @($InputObject) }
        else { $targets = @($script:NativeShares | Where-Object { $_.Name -in $Name -and ([string]::IsNullOrEmpty($ScopeName) -or $_.ScopeName -eq $ScopeName) }) }
        foreach ($target in $targets) {
            $script:DeletedShares.Add([pscustomobject]@{ Name = $target.Name; Path = $target.Path; ScopeName = $target.ScopeName; Force = [bool]$Force; UsedInputObject = ($null -ne $InputObject) })
            if (-not $script:RemovalNoOp) { $script:NativeShares = @($script:NativeShares | Where-Object { -not ($_.Name -ieq $target.Name -and $_.ScopeName -ieq $target.ScopeName) }) }
        }
    }
}
function Block-Mutation([string]$Name) { $script:ForbiddenCalls.Add($Name); throw ('Unexpected mutation during listed-share removal: ' + $Name) }
# Guard against accidental scope expansion through the common mutation APIs.
foreach ($mutation in @('Remove-Item', 'Set-Acl', 'Set-ItemProperty', 'Remove-ItemProperty', 'Remove-LocalUser', 'Set-LocalUser', 'Remove-LocalGroupMember', 'Remove-NetFirewallRule', 'Set-SmbServerConfiguration', 'Set-SmbShare', 'New-SmbShare', 'Restore-Folder', 'Restore-Firewall', 'Restore-System', 'Remove-UnusedCreatedUsers', 'Write-JsonAtomic', 'Save-Ledger')) {
    Set-Item -LiteralPath ('Function:' + $mutation) -Value ([scriptblock]::Create('param($Name,$Path,$LiteralPath,$SID,$Value,$Force,$ErrorAction) Block-Mutation ' + "'$mutation'"))
}
function Invoke-Removal { & $RemoveFunction $script:Request }
function Assert-NoRemoval { Assert-Test ($script:DeletedShares.Count -eq 0 -and $script:ForbiddenCalls.Count -eq 0) 'The guarded removal attempted an unexpected mutation.' }
function Assert-LedgerPreserved {
    Assert-Test (($script:Ledger | ConvertTo-Json -Depth 8 -Compress) -ceq $script:OriginalLedger) 'Listed-share removal changed the saved journal or account ownership.'
    Assert-Test ($script:ForbiddenCalls.Count -eq 0) 'Listed-share removal changed files, accounts, ACLs, firewall or global configuration.'
}
function Assert-Rejected {
    $rejected = $false
    try { Invoke-Removal } catch { $rejected = $true }
    Assert-Test $rejected 'An unsafe removal request was not rejected.'
    Assert-NoRemoval
}

Check 'An active foreign folder share is removed without changing unrelated shares or saved state' {
    $script:NativeShares += [pscustomobject]@{ Name = 'Keep'; Path = 'E:\Keep'; Special = $false; ScopeName = '*' }
    Invoke-Removal
    Assert-Test ($script:DeletedShares.Count -eq 1 -and $script:DeletedShares[0].Name -ceq 'Photos' -and $script:DeletedShares[0].Path -ceq 'D:\Photos' -and $script:DeletedShares[0].UsedInputObject -and $script:DeletedShares[0].Force) 'Removal did not target exactly the selected fresh native share object.'
    Assert-Test ($script:NativeShares.Count -eq 1 -and $script:NativeShares[0].Name -ceq 'Keep' -and $script:Result.Success) 'Removal changed another share or did not report success.'
    Assert-LedgerPreserved
}
Check 'A managed share removal preserves its saved setup and inventory reports it as missing' {
    $record = [pscustomobject]@{ Name = 'Photos'; Path = 'D:\Photos'; Mode = 'Guest'; UserName = 'Gast'; AllowWrite = $true; AdapterId = 17 }
    $script:Ledger.Shares = @($record)
    $script:OriginalLedger = $script:Ledger | ConvertTo-Json -Depth 8 -Compress
    Invoke-Removal
    Assert-Test ($script:DeletedShares.Count -eq 1 -and $script:Result.Success) 'A managed share could not be removed.'
    Assert-LedgerPreserved
    Read-ShareInventory
    Assert-Test (@($script:Result.Shares).Count -eq 1 -and -not $script:Result.Shares[0].Available -and $script:Result.Shares[0].Managed -and $script:Result.Shares[0].Mode -ceq 'Guest') 'The retained setup was falsely shown as an active Windows share.'
}
Check 'A complete data drive is removed through its SMB definition only' {
    $script:Request.ShareName = 'DataDrive'; $script:Request.FolderPath = 'E:\'
    $script:NativeShares = @([pscustomobject]@{ Name = 'DataDrive'; Path = 'E:\'; Special = $false; ScopeName = '*' })
    Invoke-Removal
    Assert-Test ($script:DeletedShares.Count -eq 1 -and $script:DeletedShares[0].Path -ceq 'E:\' -and $script:Result.Success) 'Data-drive share removal failed.'
    Assert-LedgerPreserved
}
Check 'A custom hidden data share can be removed despite its dollar suffix' {
    $script:Request.ShareName = 'PrivatePhotos$'
    $script:NativeShares = @([pscustomobject]@{ Name = 'PrivatePhotos$'; Path = 'D:\Photos'; Special = $false; ScopeName = '*' })
    Invoke-Removal
    Assert-Test ($script:DeletedShares.Count -eq 1 -and $script:DeletedShares[0].Name -ceq 'PrivatePhotos$' -and $script:Result.Success) 'A custom hidden share was rejected or removed by the wrong name.'
    Assert-LedgerPreserved
}
Check 'A native Special share is never removed' { $script:NativeShares[0].Special = $true; Assert-Rejected }
Check 'Missing native Special metadata fails closed without removal' {
    $script:NativeShares = @([pscustomobject]@{ Name = 'Photos'; Path = 'D:\Photos'; ScopeName = '*' })
    Assert-Rejected
}
Check 'Administrative share names are blocked even when native Special is false' {
    foreach ($name in @('C$', 'ADMIN$', 'IPC$')) {
        $script:Request.ShareName = $name
        $script:NativeShares = @([pscustomobject]@{ Name = $name; Path = 'D:\Photos'; Special = $false; ScopeName = '*' })
        Assert-Rejected
    }
}
Check 'The operation rejects a name whose native target changed after selection' {
    $script:NativeShares[0].Path = 'E:\Different Target'
    Assert-Rejected
}
Check 'Equivalent path case and trailing separators keep the exact selected share removable' {
    $script:Request.ShareName = 'photos'; $script:Request.FolderPath = 'd:\photos\'
    Invoke-Removal
    Assert-Test ($script:DeletedShares.Count -eq 1 -and $script:DeletedShares[0].Name -ceq 'Photos' -and $script:Result.Success) 'Equivalent Windows spelling was treated as a changed target.'
    Assert-LedgerPreserved
}
Check 'Ambiguous native share names across multiple scopes are rejected' {
    $script:NativeShares += [pscustomobject]@{ Name = 'Photos'; Path = 'D:\Photos'; Special = $false; ScopeName = 'ClusterScope' }
    Assert-Rejected
}
Check 'DryRun does not remove a share or change saved state' {
    $script:Request.DryRun = $true
    Invoke-Removal
    Assert-NoRemoval
    Assert-Test ($script:NativeShares.Count -eq 1 -and $script:Result.Success) 'DryRun changed the native fixture or did not report its completed preview.'
    Assert-LedgerPreserved
}
Check 'Removing a live share requires an administrator before native mutation' {
    $script:Administrator = $false
    Assert-Rejected
    Assert-Test ($script:NativeShares.Count -eq 1 -and -not $script:Result.Success) 'The nonadministrator request changed a native share or reported success.'
}
Check 'An already absent share succeeds without a deletion or journal mutation' {
    $script:NativeShares = @()
    Invoke-Removal
    Assert-NoRemoval
    Assert-Test $script:Result.Success 'An already absent share was not reported as successfully absent.'
    Assert-LedgerPreserved
}
Check 'A terminating SMB query failure is not treated as an already removed share' {
    $script:QueryFailure = 'Throw'
    Assert-Rejected
    Assert-Test (-not $script:Result.Success) 'Query failure was reported as successful removal.'
}
Check 'A nonterminating SMB query error is escalated instead of implying absence' {
    $script:QueryFailure = 'NonTerminating'
    Assert-Rejected
    Assert-Test (-not $script:Result.Success) 'SMB access-denied was reported as successful absence.'
}
Check 'A native SMB removal failure leaves state intact and does not report success' {
    $script:RemovalFailure = $true
    Assert-Rejected
    Assert-Test ($script:NativeShares.Count -eq 1 -and -not $script:Result.Success) 'A failed native removal changed state or reported success.'
    Assert-LedgerPreserved
}
Check 'A native no-op cannot be mistaken for verified removal' {
    $script:RemovalNoOp = $true
    $rejected = $false
    try { Invoke-Removal } catch { $rejected = $true }
    Assert-Test ($rejected -and -not $script:Result.Success -and $script:NativeShares.Count -eq 1) 'An unchanged native share was falsely reported as removed.'
    Assert-LedgerPreserved
}
Check 'Failure to verify native disappearance is not reported as verified removal' {
    $script:QueryFailureAt = 2
    $rejected = $false
    try { Invoke-Removal } catch { $rejected = $true }
    Assert-Test ($rejected -and $script:DeletedShares.Count -eq 1 -and -not $script:Result.Success) 'An unreadable post-removal query was treated as confirmed disappearance.'
    Assert-LedgerPreserved
}
Check 'Inventory refresh failure after confirmed disappearance is a warning with successful removal' {
    $script:QueryFailureAt = 3
    Invoke-Removal
    Assert-Test ($script:DeletedShares.Count -eq 1 -and $script:NativeShares.Count -eq 0 -and $script:Result.Success) 'An inventory refresh failure lost a previously verified removal result.'
    Assert-Test (@($script:Checks | Where-Object { $_.Name -eq 'Inventar aktualisieren' -and $_.State -eq 'warning' }).Count -eq 1) 'An inventory refresh failure did not produce a warning.'
    Assert-LedgerPreserved
}
Check 'Wildcard and path-like share names cannot expand the deletion target' {
    foreach ($name in @('*', 'Photo?', 'Photos\Other', 'Photos/Other', '[Photos]', ' Photos', 'Photos ')) {
        $script:Request.ShareName = $name
        Assert-Rejected
    }
}
Check 'Expected target path is required and cannot be remote or relative' {
    foreach ($path in @('', 'Photos', '\\Remote\Photos', '\\?\D:\Photos', 'D:Photos')) {
        $script:Request.FolderPath = $path
        Assert-Rejected
    }
}

$report = [pscustomobject]@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Isolation = 'AST-extracted production functions; SMB operations replaced by in-memory doubles; worker entry point never executes; other mutation APIs blocked'
    Limits = 'Verifies guards and result/state behavior; no actual Windows share removal or UI interaction; cannot prove cross-process atomicity against concurrent external SMB configuration changes'
    Passed = @($passed.ToArray()); Failed = @($failed.ToArray()); PassedCount = $passed.Count; FailedCount = $failed.Count
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'remove-listed-share-test-results.json') -Encoding UTF8
$report | Format-List
if ($failed.Count -gt 0) { throw 'Listed-share removal regression tests failed.' }
