param([string]$ExecutablePath = (Join-Path $PSScriptRoot '..\dist\Einfach-Netzwerk.exe'), [ValidateSet('Guest','Password')][string]$Mode = 'Guest', [string]$ExpectedCleanupAccountSid = '')
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'This explicit live test requires an elevated administrator.' }
$testRoot = Join-Path $PSScriptRoot ('live-qa\share-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot '.isolated-network-share-tests'), 'Explicit live sharing test; only this fresh test folder and app-owned test share.')
$dataFolder=Join-Path $testRoot 'SampleData'
New-Item -ItemType Directory -Path $dataFolder | Out-Null
[IO.File]::WriteAllText((Join-Path $dataFolder 'test.txt'),'Isolated network sharing test; no user data.')
$name='NWTest'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$reports=New-Object 'System.Collections.Generic.List[object]'
$passed=New-Object 'System.Collections.Generic.List[string]'
$failed=New-Object 'System.Collections.Generic.List[string]'
function State {
 $server=Get-SmbServerConfiguration
 [pscustomobject]@{
  Shares=@(Get-SmbShare | Sort-Object Name | Select-Object Name,Path,SecurityDescriptor,EncryptData)
  Profiles=@(Get-NetConnectionProfile | Sort-Object InterfaceIndex | Select-Object InterfaceIndex,NetworkCategory)
  Services=@(Get-CimInstance Win32_Service -Filter "Name='LanmanServer' OR Name='FDResPub' OR Name='fdPHost'" | Sort-Object Name | Select-Object Name,State,StartMode,PathName)
  Smb=@($server.EnableSMB1Protocol,$server.EnableSMB2Protocol,$server.RequireSecuritySignature,$server.EncryptData)
  Users=@(Get-LocalUser | Sort-Object Name | Select-Object Name,Enabled,@{n='Sid';e={$_.SID.Value}})
  NullShares=@((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters').NullSessionShares)
  Lsa=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' | Select-Object ForceGuest,LimitBlankPasswordUse)
  FolderAcl=(Get-Acl -LiteralPath $dataFolder).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
 } | ConvertTo-Json -Depth 7 -Compress
}
function Invoke-Worker([string]$Case,$Request) {
 $session=Join-Path $testRoot ($Case+'-'+[Guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $session | Out-Null
 $requestPath=Join-Path $session 'Request.json'; $resultPath=Join-Path $session 'Result.json'
 [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
 $worker=Start-Process -FilePath $ExecutablePath -ArgumentList @('--worker',('"'+$requestPath+'"'),('"'+$resultPath+'"')) -PassThru -WindowStyle Hidden
 $worker.WaitForExit()
 if(-not(Test-Path -LiteralPath $resultPath)){throw ('No result for '+$Case)}
 $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
 $reports.Add([pscustomobject]@{Case=$Case;Result=$result;ExitCode=$worker.ExitCode})
 if(-not $result.Success){throw ($Case+': '+$result.Message)}
 return $result
}
$before=State
if (-not [string]::IsNullOrEmpty($ExpectedCleanupAccountSid)) {
 $testCleanupAccount=Get-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($ExpectedCleanupAccountSid)) -ErrorAction Stop
 $testCleanupLedger=Get-Content -LiteralPath (Join-Path $env:ProgramData 'EinfachNetzwerk\state.json') -Raw | ConvertFrom-Json
 if($testCleanupAccount.Description -ne 'EinfachNetzwerk-v1' -or @($testCleanupLedger.CreatedUsers | Where-Object {$_.Sid -eq $ExpectedCleanupAccountSid -and $_.Name -eq $testCleanupAccount.Name}).Count -ne 1){throw 'Cleanup expectation must identify a journaled app-created isolated test account.'}
 if(@($testCleanupLedger.Shares | Where-Object {$_.UserSid -eq $ExpectedCleanupAccountSid -or $_.UserName -eq $testCleanupAccount.Name}).Count -ne 0){throw 'Cleanup expectation cannot include a used account.'}
 $testBaseline=$before | ConvertFrom-Json
 $testBaseline.Users=@($testBaseline.Users | Where-Object {$_.Sid -ne $ExpectedCleanupAccountSid})
 $before=$testBaseline | ConvertTo-Json -Depth 7 -Compress
}
$configured=$false
try {
 $network=@(Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up'} | ForEach-Object {Get-NetIPConfiguration -InterfaceIndex $_.ifIndex} | Where-Object {@($_.IPv4DefaultGateway).Count -gt 0 -and @($_.IPv4Address | Where-Object {$_.IPAddress -match '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)'}).Count -gt 0} | Select-Object -First 1)
 if($network.Count -ne 1){throw 'No physical home network for explicit test'}
 $request=@{Action='Apply';Mode=$Mode;FolderPath=$dataFolder;ShareName=$name;OriginalUserSid=$sid;AdapterId=[int]$network[0].InterfaceIndex;AllowWrite=$false;AllowGuestSettings=$true;AllowAdvancedRepair=$true;DryRun=$false}
 if ($Mode -eq 'Password') {
  Add-Type -AssemblyName System.Security
  $testPassword='NW-'+[Guid]::NewGuid().ToString('N')+'!7'
  $request.UserName='NWT'+[Guid]::NewGuid().ToString('N').Substring(0,12)
  $request.ProtectedPassword=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($testPassword),[Text.Encoding]::UTF8.GetBytes('EinfachNetzwerk-v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))
  $testPassword=$null
 }
 $result=Invoke-Worker 'apply' $request
 $configured=$true
 if(-not $result.ConnectionVerified){throw 'Real SMB authentication and directory listing were not verified'}
 if(@($result.Checks | Where-Object {$_.Code -eq 'LOCAL_VERIFIED'}).Count -ne 1){throw 'No successful local effectiveness verification'}
 if(@(Get-SmbShare -Name $name).Count -ne 1){throw 'Test share not created'}
 $state=Get-Content -LiteralPath (Join-Path $env:ProgramData 'EinfachNetzwerk\state.json') -Raw | ConvertFrom-Json
 if(@($state.Shares | Where-Object {$_.Name -eq $name}).Count -ne 1){throw 'Committed share missing from state journal'}
 $journal=Get-Content -LiteralPath $result.BackupPath -Raw | ConvertFrom-Json
 if($journal.Status -ne 'Committed'){throw 'Transaction journal was not updated to Committed'}
 $passed.Add('Live '+$Mode+' share is created, verified over a real SMB connection and committed to both journals')
 $request.Action='Repair'
 $null=Invoke-Worker 'repair' $request
 $passed.Add('A second live repair updates existing journals without replacing Windows registry keys')
 $request.Action='Remove'
 $null=Invoke-Worker 'remove' $request
 $configured=$false
 if(@(Get-SmbShare -Name $name -ErrorAction SilentlyContinue).Count -ne 0){throw 'Test share remains after removal'}
 if($before -cne (State)){throw 'Windows sharing/service/user state or test folder permissions differ after removal'}
 $passed.Add('Live removal restores the original shares, services, users, SMB settings and folder permissions')
 if(-not [string]::IsNullOrEmpty($ExpectedCleanupAccountSid)){
  if($null -ne (Get-LocalUser -SID (New-Object Security.Principal.SecurityIdentifier($ExpectedCleanupAccountSid)) -ErrorAction SilentlyContinue)){throw 'The previous unused test account was not cleaned up.'}
  $passed.Add('A previously unused app-created test account is cleaned up while the managed Desktop share remains intact')
 }
} catch { $failed.Add($_.Exception.Message) }
finally {
 if($configured){
  try {$null=Invoke-Worker 'cleanup' @{Action='Remove';ShareName=$name;OriginalUserSid=$sid}} catch {$failed.Add('Cleanup: '+$_.Exception.Message)}
 }
 $report=[pscustomobject]@{Success=($failed.Count -eq 0);Mode=$Mode;Passed=@($passed.ToArray());Failed=@($failed.ToArray());ShareName=$name;TestRoot=$testRoot;Reports=@($reports.ToArray());Scope='Explicit live test in a fresh marked test folder; no remote-device connection claimed.'}
 $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $PSScriptRoot ('live-qa\live-share-test-results-'+$Mode+'.json')) -Encoding UTF8
 $report|Select-Object Success,Passed,Failed,ShareName,TestRoot|ConvertTo-Json -Depth 4
}
if($failed.Count -gt 0){exit 1}
