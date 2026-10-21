param([string]$WorkerPath = (Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Execute only the production inventory and its two data helpers. All SMB
# cmdlets are replaced with local fixtures; no share, account, ACL, registry,
# service, firewall or existing journal is changed.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Worker syntax is invalid.' }
$wanted = @('Get-Value', 'Get-Managed', 'Read-ShareInventory')
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $true))
if ($definitions.Count -ne $wanted.Count) { throw 'Production share inventory functions are missing.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
$script:NativeShares = @()
$script:NativeFailure = ''
$script:NativeCalls = 0
$script:Ledger = $null
$script:Result = [ordered]@{ Shares = @(); Success = $false }
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Check([string]$Name, [scriptblock]$Body) {
    $script:NativeShares = @(); $script:NativeFailure = ''; $script:NativeCalls = 0
    $script:Ledger = $null; $script:Result = [ordered]@{ Shares = @(); Success = $false }
    try { & $Body; $passed.Add($Name) } catch { $failed.Add($Name + ': ' + $_.Exception.Message) }
}
function Get-SmbShare {
    [CmdletBinding()]
    param()
    $script:NativeCalls++
    if ($script:NativeFailure -eq 'Throw') { throw 'Fixture SMB inventory unavailable.' }
    if ($script:NativeFailure -eq 'NonTerminating') { Write-Error 'Fixture access denied reading SMB inventory.'; return }
    foreach ($share in $script:NativeShares) { $share }
}
function Live-Share([string]$Name, [string]$Path, [bool]$Special = $false) {
    [pscustomobject]@{ Name = $Name; Path = $Path; Special = $Special }
}
function Journal-Share([string]$Name, [string]$Path, [string]$Mode = 'Guest', [string]$UserName = 'Gast', [bool]$AllowWrite = $false, [int]$AdapterId = 17) {
    [pscustomobject]@{ Name = $Name; Path = $Path; Mode = $Mode; UserName = $UserName; AllowWrite = $AllowWrite; AdapterId = $AdapterId }
}
function Inventory-Entry([string]$Name) {
    $entries = @($script:Result.Shares | Where-Object { $_.Name -ieq $Name })
    Assert-Test ($entries.Count -eq 1) ('Expected one inventory entry for ' + $Name + '; found ' + $entries.Count)
    return $entries[0]
}

Check 'Live managed share retains guest access metadata and is available' {
    $script:NativeShares = @(Live-Share 'Desktop' 'C:\Users\Fixture\Desktop')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'Desktop' 'C:\Users\Fixture\Desktop' 'Guest' 'Gast' $true 17) }
    Read-ShareInventory
    $entry = Inventory-Entry 'Desktop'
    Assert-Test ($entry.Available -and $entry.Managed) 'A real managed share was shown as missing or unmanaged.'
    Assert-Test ($entry.Mode -ceq 'Guest' -and $entry.UserName -ceq 'Gast' -and $entry.AllowWrite -and $entry.AdapterId -eq 17) 'Guest mode metadata changed during inventory.'
    Assert-Test ($script:NativeCalls -eq 1) 'Inventory did not read the native shares once.'
}
Check 'Live managed drive retains root path and password access metadata' {
    $script:NativeShares = @(Live-Share 'DataDrive' 'E:\')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'DataDrive' 'E:\' 'Password' 'NetzwerkBenutzer' $false 42) }
    Read-ShareInventory
    $entry = Inventory-Entry 'DataDrive'
    Assert-Test ($entry.Path -ceq 'E:\' -and $entry.Available -and $entry.Managed) 'Drive-root path or availability changed.'
    Assert-Test ($entry.Mode -ceq 'Password' -and $entry.UserName -ceq 'NetzwerkBenutzer' -and -not $entry.AllowWrite -and $entry.AdapterId -eq 42) 'Password mode metadata changed during inventory.'
}
Check 'Foreign live share remains available without invented management or login data' {
    $script:NativeShares = @(Live-Share 'Family Photos' 'D:\Family Photos')
    Read-ShareInventory
    $entry = Inventory-Entry 'Family Photos'
    Assert-Test ($entry.Available -and -not $entry.Managed) 'A foreign live share was hidden or adopted.'
    Assert-Test ($entry.Path -ceq 'D:\Family Photos' -and $entry.Mode -ceq '' -and $entry.UserName -ceq '' -and -not $entry.AllowWrite -and $entry.AdapterId -eq -1) 'Foreign-share inventory fabricated access metadata.'
}
Check 'Journal-only share remains visible and explicitly unavailable' {
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'RemovedExternally' 'F:\Old Folder' 'Password' 'SavedUser' $true 23) }
    Read-ShareInventory
    $entry = Inventory-Entry 'RemovedExternally'
    Assert-Test (-not $entry.Available -and $entry.Managed) 'A journal record was falsely shown as an active SMB share.'
    Assert-Test ($entry.Path -ceq 'F:\Old Folder' -and $entry.Mode -ceq 'Password' -and $entry.UserName -ceq 'SavedUser' -and $entry.AllowWrite -and $entry.AdapterId -eq 23) 'Recovery metadata was lost for a missing share.'
}
Check 'Mixed live and missing records produce one truthful entry per share' {
    $script:NativeShares = @(Live-Share 'Managed' 'D:\Managed'; Live-Share 'Foreign' 'D:\Foreign')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'Managed' 'D:\Managed'; Journal-Share 'Missing' 'F:\Missing') }
    Read-ShareInventory
    Assert-Test (@($script:Result.Shares).Count -eq 3) 'Live and journal entries were dropped or duplicated.'
    Assert-Test (@($script:Result.Shares | Where-Object { $_.Available }).Count -eq 2) 'Availability does not match the native share inventory.'
    Assert-Test (@($script:Result.Shares | Where-Object { $_.Managed }).Count -eq 2) 'Management provenance does not match the journal.'
}
Check 'Case-insensitive Windows share names do not duplicate journal records' {
    $script:NativeShares = @(Live-Share 'PHOTO' 'D:\Photo')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'photo' 'D:\Photo' 'Password' 'PhotoUser') }
    Read-ShareInventory
    $entry = Inventory-Entry 'photo'
    Assert-Test ($entry.Name -ceq 'PHOTO' -and $entry.Available -and $entry.Managed -and $entry.UserName -ceq 'PhotoUser') 'Case-insensitive reconciliation lost native spelling or management data.'
}
Check 'Hidden user data shares remain visible while Windows special shares are excluded' {
    $script:NativeShares = @(Live-Share 'PrivatePhotos$' 'D:\Private Photos'; Live-Share 'C$' 'C:\' $true; Live-Share 'ADMIN$' 'C:\Windows' $true; Live-Share 'IPC$' '' $true)
    Read-ShareInventory
    Assert-Test (@($script:Result.Shares).Count -eq 1) 'System shares leaked into the inventory or a hidden data share was excluded.'
    $entry = Inventory-Entry 'PrivatePhotos$'
    Assert-Test ($entry.Available -and -not $entry.Managed -and $entry.Path -ceq 'D:\Private Photos') 'Hidden user data share was changed.'
}
Check 'Managed hidden data shares reconcile without becoming journal-only' {
    $script:NativeShares = @(Live-Share 'Backup$' 'G:\Backup')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'Backup$' 'G:\Backup') }
    Read-ShareInventory
    $entry = Inventory-Entry 'Backup$'
    Assert-Test ($entry.Available -and $entry.Managed) 'A live managed hidden data share was reported as missing.'
}
Check 'An externally retargeted share uses its real path without stale saved access data' {
    $script:NativeShares = @(Live-Share 'Moved' 'H:\Actual Target')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'Moved' 'D:\Old Target' 'Guest' 'Gast' $true 17) }
    Read-ShareInventory
    $entry = Inventory-Entry 'Moved'
    Assert-Test ($entry.Path -ceq 'H:\Actual Target' -and $entry.Available) 'A stale journal path replaced the real Windows share path.'
    Assert-Test (-not $entry.Managed -and $entry.Mode -ceq '' -and $entry.UserName -ceq '' -and -not $entry.AllowWrite -and $entry.AdapterId -eq -1) 'An externally retargeted share retained the old target''s managed status or access data.'
}
Check 'Folder path case and trailing separators retain matching saved access data' {
    $script:NativeShares = @(Live-Share 'Family' 'D:\Family Photos\')
    $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'Family' 'd:\family photos/' 'Password' 'FamilyUser' $true 23) }
    Read-ShareInventory
    $entry = Inventory-Entry 'Family'
    Assert-Test ($entry.Available -and $entry.Managed -and $entry.Path -ceq 'D:\Family Photos\') 'Equivalent folder paths were treated as an external retargeting.'
    Assert-Test ($entry.Mode -ceq 'Password' -and $entry.UserName -ceq 'FamilyUser' -and $entry.AllowWrite -and $entry.AdapterId -eq 23) 'Equivalent folder paths lost saved access data.'
}
Check 'Drive root trailing separators and letter case retain matching management data' {
    foreach ($pathPair in @(
            [pscustomobject]@{ Native = 'D:\'; Journal = 'd:' },
            [pscustomobject]@{ Native = 'D:'; Journal = 'd:\' },
            [pscustomobject]@{ Native = 'D:\'; Journal = 'd:/' }
        )) {
        $script:NativeShares = @(Live-Share 'DataDrive' $pathPair.Native)
        $script:Ledger = [pscustomobject]@{ Shares = @(Journal-Share 'DataDrive' $pathPair.Journal 'Guest' 'Gast' $false 42) }
        Read-ShareInventory
        $entry = Inventory-Entry 'DataDrive'
        Assert-Test ($entry.Available -and $entry.Managed -and $entry.Path -ceq $pathPair.Native) ('Equivalent drive-root paths were treated as an external retargeting: ' + $pathPair.Native + ' versus ' + $pathPair.Journal)
        Assert-Test ($entry.Mode -ceq 'Guest' -and $entry.UserName -ceq 'Gast' -and -not $entry.AllowWrite -and $entry.AdapterId -eq 42) 'Equivalent drive-root paths lost saved access data.'
    }
}
Check 'Empty Windows inventory with no journal is an empty collection' {
    Read-ShareInventory
    Assert-Test (@($script:Result.Shares).Count -eq 0 -and $null -ne $script:Result.Shares) 'Empty inventory did not retain an empty collection.'
}
Check 'Availability and management flags remain Boolean with an integer adapter index' {
    $script:NativeShares = @(Live-Share 'Data' 'D:\Data')
    Read-ShareInventory
    $entry = Inventory-Entry 'Data'
    Assert-Test ($entry.Available -is [bool] -and $entry.Managed -is [bool] -and $entry.AllowWrite -is [bool] -and $entry.AdapterId -is [int]) 'The UI inventory contract lost its Boolean or integer types.'
    $serialized = $script:Result | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    Assert-Test ($serialized.Shares[0].Available -is [bool] -and $serialized.Shares[0].Managed -is [bool]) 'Serialized availability flags are not Boolean values.'
}
Check 'A terminating SMB query failure propagates instead of becoming an empty successful inventory' {
    $sentinel = [pscustomobject]@{ Name = 'PreviousInventory'; Available = $true }
    $script:Result.Shares = @($sentinel)
    $script:NativeFailure = 'Throw'
    $caught = $false
    try { Read-ShareInventory } catch { $caught = $_.Exception.Message -like '*Fixture SMB inventory unavailable*' }
    Assert-Test $caught 'SMB query failure was swallowed.'
    Assert-Test (@($script:Result.Shares).Count -eq 1 -and $script:Result.Shares[0].Name -ceq 'PreviousInventory' -and -not $script:Result.Success) 'Query failure was converted into an empty successful result.'
}
Check 'A nonterminating cmdlet error is escalated by production ErrorAction Stop' {
    $script:Result.Shares = @([pscustomobject]@{ Name = 'PreviousInventory'; Available = $true })
    $script:NativeFailure = 'NonTerminating'
    $caught = $false
    try { Read-ShareInventory } catch { $caught = $_.Exception.Message -like '*Fixture access denied*' }
    Assert-Test $caught 'The production inventory did not escalate a nonterminating SMB error.'
    Assert-Test (@($script:Result.Shares).Count -eq 1 -and $script:Result.Shares[0].Name -ceq 'PreviousInventory' -and -not $script:Result.Success) 'An access-denied query was shown as an empty successful inventory.'
}

$report = [pscustomobject]@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Isolation = 'Production functions extracted by AST; Get-SmbShare replaced by local fixtures; no Windows configuration or existing journal mutations'
    Limits = 'Tests validate inventory reconciliation and serialized fields; they do not test external SMB reachability, permissions, or the rendered overview window'
    Passed = @($passed.ToArray()); Failed = @($failed.ToArray()); PassedCount = $passed.Count; FailedCount = $failed.Count
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'share-inventory-test-results.json') -Encoding UTF8
$report | Format-List
if ($failed.Count -gt 0) { throw 'Share inventory regression tests failed.' }
