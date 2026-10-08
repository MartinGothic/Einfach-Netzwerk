param([string]$ExecutablePath = (Join-Path $PSScriptRoot 'dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot 'host-qa'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot '.isolated-network-share-tests'), 'Read-only Windows inspection and DryRun only.')
$dataFolder = Join-Path $testRoot 'SampleData'
New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null
$executable = [IO.Path]::GetFullPath($ExecutablePath)
$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
$skipped = New-Object 'System.Collections.Generic.List[string]'
$reports = New-Object 'System.Collections.Generic.List[object]'
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-WindowsState {
    $server = Get-SmbServerConfiguration
    $state = [ordered]@{
        Shares = @(Get-SmbShare | Sort-Object Name | Select-Object Name,Path,EncryptData,SecurityDescriptor)
        Users = @(Get-LocalUser | Sort-Object Name | Select-Object Name,Enabled,@{n='Sid';e={$_.SID.Value}})
        Profiles = @(Get-NetConnectionProfile | Sort-Object InterfaceIndex | Select-Object InterfaceIndex,NetworkCategory)
        Services = @(Get-Service LanmanServer,FDResPub,fdPHost | Sort-Object Name | Select-Object Name,Status,StartType)
        Smb = @($server.EnableSMB1Protocol,$server.EnableSMB2Protocol,$server.RequireSecuritySignature,$server.EncryptData)
        AppRules = @(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object {$_.Group -eq 'EinfachNetzwerk (Heimnetz)'} | Sort-Object Name | Select-Object Name,Enabled,Profile,Direction,Action)
        Registry = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' | Select-Object NullSessionShares,RestrictNullSessAccess)
        DataAcl = (Get-Acl -LiteralPath $dataFolder).Sddl
        LedgerExists = Test-Path -LiteralPath (Join-Path $env:ProgramData 'EinfachNetzwerk')
        ComputerName = $env:COMPUTERNAME
        PendingComputerName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    }
    return ($state | ConvertTo-Json -Depth 8 -Compress)
}
function Run-Request([string]$Case, $Request, [bool]$ExpectSuccess) {
    $session = Join-Path $testRoot ($Case + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $session | Out-Null
    $requestPath = Join-Path $session 'Request.json'
    $resultPath = Join-Path $session 'Result.json'
    [IO.File]::WriteAllText($requestPath, ($Request | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $process = Start-Process -FilePath $executable -ArgumentList @('--worker',('"'+$requestPath+'"'),('"'+$resultPath+'"')) -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'Read-only / DryRun worker exceeded two minutes.' }
    Assert-Test (Test-Path -LiteralPath $resultPath) ('No result for '+$Case)
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $reports.Add([pscustomobject]@{ Case=$Case; ExitCode=$process.ExitCode; Result=$result })
    Assert-Test ($result.Success -eq $ExpectSuccess) ($Case+': '+$result.Message)
    Assert-Test ($process.ExitCode -eq $(if ($ExpectSuccess) {0} else {1})) ('Unexpected exit code for '+$Case)
    return $result
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $passed.Add($Name) } catch {
        if ($_.Exception.Message.StartsWith('SKIP:')) { $skipped.Add($Name+': '+$_.Exception.Message.Substring(5)) }
        else { $failed.Add($Name+': '+$_.Exception.Message) }
    }
}
$before = Get-WindowsState
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$inspect = $null
Check 'Embedded in-memory worker performs real read-only inspection' {
    $script:inspect = Run-Request 'inspect' @{Action='Inspect';Mode='Password';FolderPath=$dataFolder;ShareName='NetworkAppTest';OriginalUserSid=$sid} $true
    Assert-Test (@($script:inspect.Networks).Count -gt 0) 'No active physical home network returned'
    Assert-Test ($script:inspect.ConnectionText.Contains('445')) 'SMB port missing'
}
if ($null -ne $inspect -and @($inspect.Networks).Count -gt 0) {
    $adapter = [int]$inspect.Networks[0].Id
    Check 'Password share plan does not create accounts or shares' {
        $null = Run-Request 'password-dry-run' @{Action='Apply';DryRun=$true;Mode='Password';FolderPath=$dataFolder;ShareName='NetworkAppTest';UserName=('NWTest'+[Guid]::NewGuid().ToString('N').Substring(0,8));OriginalUserSid=$sid;AdapterId=$adapter;AllowWrite=$true;AllowAdvancedRepair=$true} $true
    }
    Check 'Guest share plan does not modify guest settings' {
        $null = Run-Request 'guest-dry-run' @{Action='Apply';DryRun=$true;Mode='Guest';FolderPath=$dataFolder;ShareName='NetworkAppTest';OriginalUserSid=$sid;AdapterId=$adapter;AllowWrite=$false;AllowGuestSettings=$true;AllowAdvancedRepair=$true} $true
    }
    $systemRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    $drive = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' -and $_.Root -ine $systemRoot } | Select-Object -First 1)
    if ($drive.Count -gt 0) {
        Check 'Entire data drive is supported in DryRun' {
            $null = Run-Request 'drive-dry-run' @{Action='Apply';DryRun=$true;Mode='Password';FolderPath=$drive[0].Root;AllowDriveRoot=$true;ShareName='NetworkDriveTest';UserName=('NWDrive'+[Guid]::NewGuid().ToString('N').Substring(0,8));OriginalUserSid=$sid;AdapterId=$adapter;AllowWrite=$false} $true
        }
    }
}
Check 'System drive root is rejected before changes' {
    $null = Run-Request 'system-root' @{Action='Apply';DryRun=$true;Mode='Guest';FolderPath=[IO.Path]::GetPathRoot($env:SystemRoot);AllowDriveRoot=$true;ShareName='SystemMustStayProtected';AdapterId=17;AllowGuestSettings=$true} $false
}
Check 'Computer rename is planned without changing Windows or restarting' {
    $null = Run-Request 'rename-dry-run' @{Action='Rename';DryRun=$true;ComputerName='Mein-NetzwerkPC';OriginalUserSid=$sid} $true
}
Check 'Existing IPC result cannot be overwritten' {
    $session = Join-Path $testRoot ('existing-result-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $session | Out-Null
    $requestPath = Join-Path $session 'Request.json'; $resultPath = Join-Path $session 'Result.json'
    [IO.File]::WriteAllText($requestPath, '{"Action":"invalid"}')
    [IO.File]::WriteAllText($resultPath, 'Existing file must survive')
    $process = Start-Process -FilePath $executable -ArgumentList @('--worker',('"'+$requestPath+'"'),('"'+$resultPath+'"')) -Wait -PassThru -WindowStyle Hidden
    Assert-Test ($process.ExitCode -eq 1) 'Invalid request unexpectedly succeeded'
    Assert-Test ([IO.File]::ReadAllText($resultPath) -eq 'Existing file must survive') 'Existing result was overwritten'
}
Check 'Session directory junction is rejected' {
    $target = Join-Path $testRoot ('junction-target-'+[Guid]::NewGuid().ToString('N'))
    $alias = Join-Path $testRoot ('junction-alias-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $target | Out-Null
    New-Item -ItemType Junction -Path $alias -Target $target | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'Request.json'), '{"Action":"Inspect"}')
    $process = Start-Process -FilePath $executable -ArgumentList @('--worker',('"'+(Join-Path $alias 'Request.json')+'"'),('"'+(Join-Path $alias 'Result.json')+'"')) -Wait -PassThru -WindowStyle Hidden
    Assert-Test ($process.ExitCode -eq 1) 'Junction session unexpectedly succeeded'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $target 'Result.json'))) 'Junction target received output'
}
Check 'Request file symbolic link is rejected without reading its target' {
    $session = Join-Path $testRoot ('file-link-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $session | Out-Null
    $target = Join-Path $session 'Target.json'
    $requestPath = Join-Path $session 'Request.json'; $resultPath = Join-Path $session 'Result.json'
    [IO.File]::WriteAllText($target, '{"Action":"Inspect","Marker":"isolated link target"}')
    try { New-Item -ItemType SymbolicLink -Path $requestPath -Target $target | Out-Null }
    catch {
        if ($_.Exception -is [UnauthorizedAccessException] -or $_.CategoryInfo.Category -eq 'PermissionDenied' -or $_.Exception.Message -match 'Administratorrechte|privilege') {
            throw 'SKIP: Windows does not permit creating test file symlinks in this session. No system policy was changed; the no-follow handle was reviewed in source.'
        }
        throw
    }
    $process = Start-Process -FilePath $executable -ArgumentList @('--worker',('"'+$requestPath+'"'),('"'+$resultPath+'"')) -Wait -PassThru -WindowStyle Hidden
    Assert-Test ($process.ExitCode -eq 1) 'Linked request unexpectedly succeeded'
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test ($result.Message.Contains('Auftragsdateien')) 'Linked request was not explicitly rejected'
    Assert-Test (-not ($result.Message.Contains('isolated link target'))) 'Linked target content leaked'
}
Check 'Windows configuration remains identical after tests' { Assert-Test ((Get-WindowsState) -ceq $before) 'Windows configuration changed' }
$report = [ordered]@{ Success=$failed.Count -eq 0; Passed=@($passed.ToArray()); Failed=@($failed.ToArray()); Skipped=@($skipped.ToArray()); Reports=@($reports.ToArray()); Scope='Real inspection, Apply with DryRun=true only, isolated IPC validation; no live sharing changes.' }
[IO.File]::WriteAllText((Join-Path $testRoot 'host-test-results.json'), ($report | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]$report | Select-Object Success,Passed,Failed,Skipped | ConvertTo-Json -Depth 4
if ($failed.Count -gt 0) { exit 1 }
