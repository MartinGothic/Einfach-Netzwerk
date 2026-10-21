param([string]$WorkerPath = (Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Real file replacement and real registry-provider tests under Windows
# PowerShell 5.1. Only a GUID temp directory and a GUID HKCU key are changed;
# service/share/firewall configuration is never touched. The administrator
# ownership assignment is checked in memory, so this test needs no elevation.
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $WorkerPath).Path, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'The worker has syntax errors.' }
$wanted = @('Write-JsonAtomic', 'Restore-Registry')
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $true))
if ($definitions.Count -ne $wanted.Count) { throw 'Journal/registry function definitions are missing.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$id = [Guid]::NewGuid().ToString('N')
$script:AtomicFolder = Join-Path ([IO.Path]::GetTempPath()) ('EinfachNetzwerk-journaltest-' + $id)
$registryRoot = 'HKCU:\Software\EinfachNetzwerk-JournalTest-' + $id
$script:AclCalls = 0
$script:FailAcl = $false
$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'

function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $passed.Add($Name) } catch { $failed.Add($Name + ': ' + $_.Exception.Message) }
}
function Set-Acl {
    param([string]$LiteralPath, $AclObject)
    Assert-Test ($LiteralPath.StartsWith($script:AtomicFolder + '\', [StringComparison]::OrdinalIgnoreCase)) 'ACL test escaped its isolated directory.'
    Assert-Test ($AclObject.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Atomic writer did not prepare administrator ownership.'
    $script:AclCalls++
    if ($script:FailAcl) { throw 'SIMULATED ACL WRITE FAILURE' }
}

New-Item -ItemType Directory -Path $script:AtomicFolder | Out-Null
New-Item -Path $registryRoot | Out-Null
try {
    $journal = Join-Path $script:AtomicFolder 'journal.json'
    Check 'A new JSON journal is written and repeatedly replaced atomically' {
        foreach ($status in @('Prepared', 'Committed', 'RolledBack')) {
            Write-JsonAtomic $journal ([pscustomobject]@{Status=$status;Nested=[pscustomobject]@{Text='Grüße aus dem Heimnetz';Numbers=@(1,2,3)}})
            $saved = [IO.File]::ReadAllText($journal, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Assert-Test ($saved.Status -eq $status) 'Repeated journal update did not save its actual status.'
            Assert-Test ($saved.Nested.Text -eq 'Grüße aus dem Heimnetz' -and $saved.Nested.Numbers.Count -eq 3) 'JSON data was damaged.'
        }
        Assert-Test ($script:AclCalls -eq 3) 'Not every atomic replacement prepared ownership.'
        Assert-Test (@(Get-ChildItem -LiteralPath $script:AtomicFolder -Filter '*.tmp').Count -eq 0) 'Successful update left temporary files.'
    }
    Check 'An atomic update failure retains the previous journal and removes its temporary file' {
        $before = [IO.File]::ReadAllText($journal)
        $script:FailAcl = $true
        $caught = $false
        try { Write-JsonAtomic $journal ([pscustomobject]@{Status='MustNotCommit'}) } catch { $caught = $_.Exception.Message -eq 'SIMULATED ACL WRITE FAILURE' } finally { $script:FailAcl=$false }
        Assert-Test $caught 'Expected atomic preparation failure was not reported.'
        Assert-Test ([IO.File]::ReadAllText($journal) -ceq $before) 'Failed atomic update changed the previous journal.'
        Assert-Test (@(Get-ChildItem -LiteralPath $script:AtomicFolder -Filter '*.tmp').Count -eq 0) 'Failed update left temporary files.'
    }
    $existing = Join-Path $registryRoot 'ExistingServiceFixture'
    New-Item -Path $existing | Out-Null
    New-ItemProperty -LiteralPath $existing -Name ImagePath -Value 'C:\Windows\System32\svchost.exe -k Fixture' -PropertyType ExpandString | Out-Null
    New-ItemProperty -LiteralPath $existing -Name Start -Value 3 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $existing -Name DelayedAutoStart -Value 0 -PropertyType DWord | Out-Null
    $child = Join-Path $existing 'Parameters'
    New-Item -Path $child | Out-Null
    New-ItemProperty -LiteralPath $child -Name ServiceDll -Value '%SystemRoot%\System32\fixture.dll' -PropertyType ExpandString | Out-Null

    Check 'Restoring a registry value preserves existing service values and child keys' {
        $snapshot = [pscustomobject]@{Path=$existing;Name='DelayedAutoStart';Exists=$true;Kind='DWord';Value=1}
        Restore-Registry $snapshot
        Restore-Registry $snapshot
        $key = Get-Item -LiteralPath $existing
        Assert-Test ($key.GetValue('DelayedAutoStart') -eq 1 -and $key.GetValueKind('DelayedAutoStart').ToString() -eq 'DWord') 'Targeted registry value was not restored.'
        Assert-Test ($key.GetValue('Start') -eq 3) 'Unrelated service start mode was deleted.'
        Assert-Test ($key.GetValue('ImagePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq 'C:\Windows\System32\svchost.exe -k Fixture') 'Unrelated ImagePath was deleted.'
        Assert-Test ((Get-Item -LiteralPath $child).GetValue('ServiceDll', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq '%SystemRoot%\System32\fixture.dll') 'Service Parameters subkey was deleted.'
    }
    Check 'Removing an originally absent registry value is idempotent and preserves unrelated values' {
        $snapshot = [pscustomobject]@{Path=$existing;Name='DelayedAutoStart';Exists=$false;Kind='';Value=$null}
        Restore-Registry $snapshot
        Restore-Registry $snapshot
        $key = Get-Item -LiteralPath $existing
        Assert-Test ('DelayedAutoStart' -notin @($key.GetValueNames())) 'Absent original value was not removed.'
        Assert-Test ($key.GetValue('Start') -eq 3 -and (Test-Path -LiteralPath $child)) 'Value removal damaged unrelated registry data.'
    }
    Check 'Restoring a missing registry key creates only the requested key and correct value type' {
        $missing = Join-Path $registryRoot 'MissingFixture'
        Restore-Registry ([pscustomobject]@{Path=$missing;Name='NullSessionShares';Exists=$true;Kind='MultiString';Value=@('One','Two')})
        $key = Get-Item -LiteralPath $missing
        Assert-Test ($key.GetValueKind('NullSessionShares').ToString() -eq 'MultiString') 'Original registry type was lost.'
        Assert-Test ((@($key.GetValue('NullSessionShares')) -join ',') -eq 'One,Two') 'Original MultiString data was lost.'
    }
    Check 'Removing an absent value from an absent key remains a no-op' {
        $missing = Join-Path $registryRoot 'MustRemainMissing'
        Restore-Registry ([pscustomobject]@{Path=$missing;Name='Nothing';Exists=$false;Kind='';Value=$null})
        Assert-Test (-not (Test-Path -LiteralPath $missing)) 'No-op restoration created a registry key.'
    }
} finally {
    # Both names are fixed prefixes plus this invocation's GUID, never a
    # computed Windows service path or user-selected data directory.
    if ($registryRoot -notmatch '^HKCU:\\Software\\EinfachNetzwerk-JournalTest-[0-9a-f]{32}$') { throw 'Unsafe registry cleanup path.' }
    Remove-Item -LiteralPath $registryRoot -Recurse -Force -ErrorAction Stop
    $resolvedTemp = [IO.Path]::GetFullPath($script:AtomicFolder)
    $expectedTemp = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('EinfachNetzwerk-journaltest-' + $id)))
    if ($resolvedTemp -cne $expectedTemp) { throw 'Unsafe file cleanup path.' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction Stop
}
$report = [pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString();Passed=@($passed.ToArray());Failed=@($failed.ToArray());PassedCount=$passed.Count;FailedCount=$failed.Count}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'journal-test-results.json') -Encoding UTF8
$report | Format-List
if ($failed.Count -gt 0) { throw 'Isolated journal/registry regression tests failed.' }
