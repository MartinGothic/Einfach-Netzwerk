param(
    [switch]$Live,
    [string]$Address = '192.168.178.24',
    [string]$ShareName = 'Desktop',
    [string]$GuestName = 'Gast',
    [string]$AssemblyPath,
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Diese .NET-Framework-Prüfung mit Windows PowerShell 5.1 ausführen.' }
$taskQa = Join-Path $PSScriptRoot 'ui-qa'
New-Item -ItemType Directory -Path $taskQa -Force | Out-Null
if (-not $AssemblyPath) {
    $taskCompiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $taskCompiler)) { $taskCompiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    $AssemblyPath = Join-Path $taskQa ('smb-probe-test-' + [Guid]::NewGuid().ToString('N') + '.dll')
    & $taskCompiler /nologo /target:library /langversion:5 /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:' + $AssemblyPath) (Join-Path $PSScriptRoot 'SmbConnectionProbe.cs')
    if ($LASTEXITCODE -ne 0) { throw 'SMB-Prüfung konnte nicht kompiliert werden.' }
}
[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path) | Out-Null
if (-not $ReportPath) { $ReportPath = Join-Path $taskQa 'smb-probe-test-results.json' }
$taskResults = New-Object 'Collections.Generic.List[object]'
function Check([string]$name, [scriptblock]$body) {
    try { & $body; $taskResults.Add([pscustomobject]@{ Name = $name; Passed = $true; Error = '' }) }
    catch { $taskResults.Add([pscustomobject]@{ Name = $name; Passed = $false; Error = $_.Exception.Message }) }
}
function Assert([bool]$condition, [string]$reason) { if (-not $condition) { throw $reason } }
function Probe([string]$ip, [string]$share, [string]$user, [string]$password) {
    [EinfachNetzwerk.SmbConnectionProbe]::ProbeJson($ip, $share, $user, $password) | ConvertFrom-Json
}
Check 'Public IP is refused before credential exchange' {
    $r = Probe '8.8.8.8' 'Folder' 'Test' ''
    Assert (-not $r.Success -and -not $r.TcpReachable -and $r.Stage -eq 'Input') 'A non-local address reached a network operation.'
}
Check 'Loopback and hostnames cannot select another target' {
    foreach ($ip in @('127.0.0.1', 'localhost')) {
        $r = Probe $ip 'Folder' 'Test' ''
        Assert (-not $r.Success -and -not $r.TcpReachable -and $r.Stage -eq 'Input') 'Target validation did not reject input.'
    }
}
Check 'UNC share input is refused without network access' {
    $r = Probe $Address '\\other-server\folder' $GuestName ''
    Assert (-not $r.Success -and -not $r.TcpReachable -and $r.Stage -eq 'Input') 'A UNC share argument was accepted.'
}
if ($Live) {
    $taskBefore = Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol,EnableSMB2Protocol,EnableSecuritySignature,RequireSecuritySignature,EncryptData | ConvertTo-Json -Compress
    $taskConnectionsBefore = @(Get-SmbConnection -ErrorAction SilentlyContinue | ForEach-Object { '{0}|{1}|{2}' -f $_.ServerName,$_.ShareName,$_.UserName })
    Check 'Named guest performs real NTLM login and directory read' {
        $r = Probe $Address $ShareName $GuestName ''
        Assert ($r.Success -and $r.TcpReachable -and $r.LoginSucceeded -and $r.TreeConnected -and $r.DirectoryListed) ('Guest SMB check failed at ' + $r.Stage + ' (' + $r.StatusCode + ').')
        Assert ($r.Dialect -eq 'SMB 2.1' -and $r.AuthenticationProtocol -eq 'NTLM') 'SMB 2.1 with NTLM was not confirmed.'
    }
    Check 'Qualified named guest also performs a real directory read' {
        $r = Probe $Address $ShareName ($env:COMPUTERNAME + '\' + $GuestName) ''
        Assert ($r.Success -and $r.DirectoryListed) ('Qualified guest failed at ' + $r.Stage + ' (' + $r.StatusCode + ').')
    }
    Check 'Missing share is not reported as reachable despite valid login' {
        $r = Probe $Address ('probe-missing-' + [Guid]::NewGuid().ToString('N')) $GuestName ''
        Assert (-not $r.Success -and $r.LoginSucceeded -and -not $r.TreeConnected -and $r.Stage -eq 'TreeConnect' -and $r.StatusCode -eq '0xC00000CC') 'A missing share was not distinguished from login.'
    }
    Check 'Unknown explicit identity never falls back to current Windows user' {
        $r = Probe $Address $ShareName ('probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)) 'probe-non-secret-password'
        Assert (-not $r.Success -and (-not $r.LoginSucceeded -or $r.GuestSession) -and $r.Stage -eq 'Login') 'Invalid credentials unexpectedly fell back to the current account.'
        Assert ($r.Error -notmatch 'probe-non-secret-password') 'A password was included in output.'
    }
    Check 'Anonymous failure remains a failure at the actual protocol stage' {
        $r = Probe $Address $ShareName '' ''
        Assert (-not $r.Success -and $r.Stage -eq 'Login' -and $r.StatusCode -eq '0xC0000022') 'This test PC no longer reproduces the anonymous access denial.'
    }
    Check 'SMB configuration and Windows client mappings remain unchanged' {
        $after = Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol,EnableSMB2Protocol,EnableSecuritySignature,RequireSecuritySignature,EncryptData | ConvertTo-Json -Compress
        $connectionsAfter = @(Get-SmbConnection -ErrorAction SilentlyContinue | ForEach-Object { '{0}|{1}|{2}' -f $_.ServerName,$_.ShareName,$_.UserName })
        Assert ($taskBefore -eq $after) 'The SMB server configuration changed.'
        Assert (-not (Compare-Object @($taskConnectionsBefore | Sort-Object) @($connectionsAfter | Sort-Object))) 'Windows SMB client mappings changed.'
    }
}
$taskFailed = @($taskResults | Where-Object { -not $_.Passed }).Count
$taskReport = [ordered]@{ Passed = $taskResults.Count - $taskFailed; Failed = $taskFailed; Live = [bool]$Live; WindowsSettingsModified = $false; Results = $taskResults.ToArray() }
$taskReport | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$taskResults | Format-Table Name,Passed -AutoSize
if ($taskFailed) { throw ('SMB-Prüfung: ' + $taskFailed + ' Fehler. Details: ' + $ReportPath) }
