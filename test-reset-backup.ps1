param([string]$WorkerPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if([string]::IsNullOrWhiteSpace($WorkerPath)){$WorkerPath=Join-Path $PSScriptRoot 'ShareWorker.ps1'}
$taskResetSource=[IO.File]::ReadAllText([IO.Path]::GetFullPath($WorkerPath))
$taskResetTokens=$null;$taskResetErrors=$null
$taskResetAst=[Management.Automation.Language.Parser]::ParseInput($taskResetSource,[ref]$taskResetTokens,[ref]$taskResetErrors)
$script:taskResetPassed=0
function Require-Reset([bool]$value,[string]$message){if(-not $value){throw $message};$script:taskResetPassed++}
Require-Reset (@($taskResetErrors).Count -eq 0) 'The actual reset-backup worker must parse under Windows PowerShell5.'
foreach($taskResetHelper in @('Get-Value','Initialize-WorkProgress','Complete-WorkStep','Initialize-LedgerDirectory','Assert-LedgerProtection','Read-Ledger','Backup-ResetState')){
    $taskResetFunction=$taskResetAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskResetHelper},$true)
    if($null -eq $taskResetFunction){throw ('Missing production backup helper: '+$taskResetHelper)}
    . ([scriptblock]::Create($taskResetFunction.Extent.Text))
}
$taskResetRoot=Join-Path ([IO.Path]::GetTempPath()) ('EinfachNetzwerk-reset-backup-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($taskResetRoot)
[IO.File]::WriteAllText((Join-Path $taskResetRoot '.isolated-test'),'Actual backup function with Windows doubles only; no network reset.')
$script:taskResetAdmin=$true;$script:taskResetOwner='S-1-5-32-544';$script:taskResetJournalOwner='S-1-5-32-544'
$script:taskResetWriteMode='Normal';$script:taskResetAclFailure=$false;$script:taskResetReparse=$false
$script:taskResetMutations=0
$script:taskResetCalls=New-Object 'Collections.Generic.List[string]'
$script:taskResetAccessInputs=New-Object 'Collections.Generic.List[object]'
$script:AppMark='EinfachNetzwerk-v1';$script:WorkText='';$script:WorkPlan=$null
$script:taskResetShares=@(
    [pscustomobject]@{Name='FixturePhotos';Path='C:\IsolatedSharePhotos';Special=$false;Description='public photos';CachingMode='Manual';EncryptData=$true;FolderEnumerationMode='AccessBased';ConcurrentUserLimit=23;ContinuouslyAvailable=$true;CATimeout=71;SecurityDescriptor='D:P(A;;FA;;;BA)'},
    [pscustomobject]@{Name='FixtureHidden$';Path='D:\IsolatedHiddenShare';Special=$false;Description='hidden normal data';CachingMode='None';EncryptData=$false;FolderEnumerationMode='Unrestricted';ConcurrentUserLimit=42;ContinuouslyAvailable=$false;CATimeout=99;SecurityDescriptor='D:P(A;;FR;;;BU)'},
    [pscustomobject]@{Name='ADMIN$';Path='C:\Windows';Special=$true},[pscustomobject]@{Name='IPC$';Path='';Special=$true},[pscustomobject]@{Name='C$';Path='C:\';Special=$true}
)
function Is-Administrator{return $script:taskResetAdmin}
function Write-Phase($Text){$script:WorkText=$Text;$script:taskResetCalls.Add('phase')}
function Assert-NoReparse($Path){$script:taskResetCalls.Add('no-reparse:'+ $Path);if($script:taskResetReparse -and $Path -eq $script:LedgerRoot){throw 'Isolated untrusted reparse ledger.'}}
function Get-SmbShare($ErrorAction){$script:taskResetCalls.Add('shares');return $script:taskResetShares}
function Get-SmbShareAccess($InputObject,$ErrorAction){
    $script:taskResetCalls.Add('access:'+ $InputObject.Name);$script:taskResetAccessInputs.Add($InputObject)
    return @([pscustomobject]@{AccountName='FIXTURE-PC\NetworkUser';AccessControlType='Allow';AccessRight='Full'},[pscustomobject]@{AccountName='BUILTIN\Users';AccessControlType='Allow';AccessRight='Read'},[pscustomobject]@{AccountName='FIXTURE-PC\Blocked';AccessControlType='Deny';AccessRight='Change'})
}
function Get-Acl($LiteralPath,$ErrorAction){
    if($LiteralPath -eq $script:LedgerRoot -or $LiteralPath.StartsWith($script:LedgerRoot+'\',[StringComparison]::OrdinalIgnoreCase)){
        $owner=$script:taskResetOwner;if($LiteralPath -ne $script:LedgerRoot){$owner=$script:taskResetJournalOwner}
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($owner)))
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
        return $acl
    }
    $script:taskResetCalls.Add('folder-acl:'+ $LiteralPath)
    if($script:taskResetAclFailure){throw 'Isolated folder ACL cannot be read.'}
    return [pscustomobject]@{Sddl=('D:P(A;;FA;;;BA)(A;;FR;;;BU);'+$LiteralPath)}
}
function Get-SmbServerConfiguration($ErrorAction){$script:taskResetCalls.Add('server');return [pscustomobject]@{EnableSMB2Protocol=$true;RequireSecuritySignature=$false;EnableSecuritySignature=$true;EncryptData=$true}}
function Get-ServiceSnapshot($Name){$script:taskResetCalls.Add('service:'+ $Name);return [pscustomobject]@{Name=$Name;StartMode='Manual';State='Stopped';Delayed=[pscustomobject]@{Exists=$true;Value=0}}}
function Get-HomeNetworks{$script:taskResetCalls.Add('networks');return @([pscustomobject]@{Id=16;Name='Isolated LAN';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private'})}
function Write-JsonAtomic($Path,$Object){
    Require-Reset ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)) -eq $script:LedgerRoot) 'Backup escaped the trusted isolated ledger directory.'
    Require-Reset ($Path -match 'reset-backup-[0-9]{8}-[0-9]{6}-[a-f0-9]{32}\.json$') 'Backup filename is not unique and program-owned.'
    Require-Reset ($script:WorkCompleted.Contains('backup-read')) 'A backup was written before its snapshot reads were counted.'
    Require-Reset ($script:taskResetMutations -eq 0) 'Windows reset mutation preceded the backup.'
    $script:taskResetCalls.Add('write')
    if($script:taskResetWriteMode -eq 'WriteFail'){throw (New-Object IO.IOException('Isolated backup write denied.'))}
    if($script:taskResetWriteMode -eq 'NoFile'){return}
    $copy=ConvertTo-Json -InputObject $Object -Depth 18 | ConvertFrom-Json
    if($script:taskResetWriteMode -eq 'MissingShare'){$copy.Shares=@($copy.Shares[0])}
    if($script:taskResetWriteMode -eq 'WrongKind'){$copy.Kind='UnconfirmedBackup'}
    [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $copy -Depth 18),(New-Object Text.UTF8Encoding($false)))
}
function Add-Check($Name,$State,$Detail,$Code){$script:taskResetCalls.Add('check:'+ $Code)}
function Forbidden-ResetMutation($Name){$script:taskResetMutations++;throw ('Forbidden Windows reset mutation: '+$Name)}
function Remove-SmbShare{Forbidden-ResetMutation 'Remove-SmbShare'}
function Set-Service{Forbidden-ResetMutation 'Set-Service'}
function Start-Service{Forbidden-ResetMutation 'Start-Service'}
function Stop-Service{Forbidden-ResetMutation 'Stop-Service'}
function Set-SmbServerConfiguration{Forbidden-ResetMutation 'Set-SmbServerConfiguration'}
function Set-NetConnectionProfile{Forbidden-ResetMutation 'Set-NetConnectionProfile'}
function Set-Acl{Forbidden-ResetMutation 'Set-Acl'}
function Remove-NetFirewallRule{Forbidden-ResetMutation 'Remove-NetFirewallRule'}
function Reset-BackupFixture {
    $script:taskResetAdmin=$true;$script:taskResetOwner='S-1-5-32-544';$script:taskResetJournalOwner='S-1-5-32-544';$script:taskResetWriteMode='Normal';$script:taskResetAclFailure=$false;$script:taskResetReparse=$false
    $script:taskResetCalls.Clear();$script:taskResetAccessInputs.Clear()
    $script:LedgerRoot=Join-Path $taskResetRoot ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($script:LedgerRoot)
    $script:LedgerFile=Join-Path $script:LedgerRoot 'state.json'
    [IO.File]::WriteAllText($script:LedgerFile,'{"App":"EinfachNetzwerk-v1","Version":1,"Shares":[{"Name":"OwnedBeforeReset"}],"Global":{"OriginalMarker":"preserve-originals"}}')
    foreach($file in @('journal-setup.json','client-settings.json','services-local.json','service-recovery-old.json')){[IO.File]::WriteAllText((Join-Path $script:LedgerRoot $file),('{"Marker":"'+$file+'"}'))}
    foreach($file in @('reset-backup-old.json','unrelated.json','journal-not-json.txt')){[IO.File]::WriteAllText((Join-Path $script:LedgerRoot $file),'Excluded private fixture noise')}
    $script:Result=[ordered]@{Success=$false;BackupPath='';ComputerName='';Message=''}
    $script:Request=[pscustomobject]@{DryRun=$false}
    Initialize-WorkProgress 'BackupReset' $false;Complete-WorkStep 'request';Complete-WorkStep 'access'
}
function Fails-Backup([string]$case){
    $failure=$null;try{Backup-ResetState}catch{$failure=$_}
    Require-Reset ($null -ne $failure) ($case+': unsafe/incomplete backup was accepted.')
    Require-Reset (-not $script:Result.Success -and [string]::IsNullOrEmpty($script:Result.BackupPath)) ($case+': failure claimed a confirmed backup.')
    Require-Reset (-not $script:WorkCompleted.Contains('backup-write')) ($case+': failed read-back earned confirmed-write progress.')
    Require-Reset ($script:taskResetMutations -eq 0) ($case+': failure performed Windows reset changes.')
}
try{
    Reset-BackupFixture
    Require-Reset (($script:WorkPlan -join ',') -eq 'request,access,backup-read,backup-write,action-summary,response-written,client-confirmation') 'Backup reset progress includes unrelated setup tasks or omits final confirmation.'
    Backup-ResetState
    Require-Reset ($script:Result.Success -and [IO.File]::Exists($script:Result.BackupPath)) 'The actual backup did not confirm a persisted result.'
    $backup=[IO.File]::ReadAllText($script:Result.BackupPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    Require-Reset ($backup.App -eq $script:AppMark -and $backup.Kind -eq 'NetworkResetBackup' -and $backup.Version -eq 1) 'Backup identity/version marker was lost.'
    Require-Reset ($backup.ComputerName -eq $env:COMPUTERNAME -and -not [string]::IsNullOrWhiteSpace($backup.Created)) 'Backup omitted computer/time metadata.'
    Require-Reset ($backup.Shares.Count -eq 2 -and $backup.Shares[0].Name -eq 'FixturePhotos' -and $backup.Shares[1].Name -eq 'FixtureHidden$') 'Ordinary and hidden non-special shares were not backed up exactly; system shares leaked in.'
    Require-Reset ($script:taskResetAccessInputs.Count -eq 2 -and [object]::ReferenceEquals($script:taskResetAccessInputs[0],$script:taskResetShares[0]) -and [object]::ReferenceEquals($script:taskResetAccessInputs[1],$script:taskResetShares[1])) 'Access snapshots must use the exact enumerated share objects.'
    foreach($index in @(0,1)){
        $original=$script:taskResetShares[$index];$saved=$backup.Shares[$index]
        foreach($field in @('Name','Path','Description','CachingMode','EncryptData','FolderEnumerationMode','ConcurrentUserLimit','ContinuouslyAvailable','CATimeout','SecurityDescriptor')){Require-Reset ([string]$saved.$field -ceq [string]$original.$field) ('Share definition field lost: '+$field)}
        Require-Reset ($saved.FolderSddl -ceq ('D:P(A;;FA;;;BA)(A;;FR;;;BU);'+$original.Path)) 'Original folder ACL descriptor was not backed up.'
        Require-Reset ($saved.Access.Count -eq 3 -and $saved.Access[0].AccessRight -eq 'Full' -and $saved.Access[1].AccessRight -eq 'Read' -and $saved.Access[2].AccessControlType -eq 'Deny' -and $saved.Access[2].AccessRight -eq 'Change') 'Full/read/deny share access entries were lost.'
        Require-Reset ($saved.Access[0].AccountName -ceq 'FIXTURE-PC\NetworkUser') 'Share account identity changed in its access snapshot.'
    }
    Require-Reset ($backup.Ledger.Global.OriginalMarker -eq 'preserve-originals' -and $backup.Ledger.Shares[0].Name -eq 'OwnedBeforeReset') 'Managed original states were omitted from the backup.'
    Require-Reset ($backup.Journals.Count -eq 4) 'Backup omitted a client/service/share journal or copied unrelated files.'
    foreach($journal in $backup.Journals){Require-Reset ($journal.Json -ceq [IO.File]::ReadAllText((Join-Path $script:LedgerRoot $journal.Name))) 'A journal was rewritten rather than copied exactly.'}
    Require-Reset (($backup.Services.Name -join ',') -eq 'LanmanServer,LanmanWorkstation,FDResPub,fdPHost') 'Backup omitted a relevant service original state.'
    Require-Reset ($backup.Networks.Count -eq 1 -and $backup.Networks[0].Address -eq '192.168.178.24') 'The current network snapshot was omitted.'
    Require-Reset ($backup.Server.EnableSMB2Protocol -and $backup.Server.EnableSecuritySignature -and -not $backup.Server.RequireSecuritySignature -and $backup.Server.EncryptData) 'Relevant SMB server metadata was lost.'
    Require-Reset ($script:taskResetCalls.IndexOf('write') -gt $script:taskResetCalls.IndexOf('networks') -and $script:taskResetCalls.IndexOf('write') -lt $script:taskResetCalls.IndexOf('check:RESET_BACKUP_CONFIRMED')) 'The success confirmation preceded persisted backup data.'
    Require-Reset ($script:WorkCompleted.Contains('backup-write') -and $script:WorkCompleted.Count -eq 4 -and -not $script:WorkCompleted.Contains('client-confirmation')) 'Backup worker claimed result-file/UI confirmation before dispatch writes it.'
    Require-Reset ($script:taskResetMutations -eq 0) 'Backup changed actual sharing or service settings.'
    Reset-BackupFixture;$script:taskResetAdmin=$false;Fails-Backup 'No administrator'
    Require-Reset (-not $script:taskResetCalls.Contains('shares') -and -not $script:taskResetCalls.Contains('write')) 'Non-admin backup inspected or wrote trusted backup data.'
    Reset-BackupFixture;$script:taskResetOwner='S-1-5-32-545';Fails-Backup 'Untrusted ledger owner'
    Require-Reset (-not $script:taskResetCalls.Contains('shares') -and -not $script:taskResetCalls.Contains('write')) 'An untrusted ledger root was used.'
    Reset-BackupFixture;$script:taskResetJournalOwner='S-1-5-32-545';Fails-Backup 'Untrusted existing journal owner'
    Reset-BackupFixture;$script:taskResetReparse=$true;Fails-Backup 'Reparse ledger root'
    Reset-BackupFixture;[IO.File]::WriteAllText($script:LedgerFile,'{"App":"ForeignState","Version":1}');Fails-Backup 'Foreign state identity'
    Reset-BackupFixture;$script:taskResetAclFailure=$true;Fails-Backup 'Folder ACL read failure'
    Require-Reset (-not $script:taskResetCalls.Contains('write')) 'An incomplete definition snapshot was written as complete.'
    foreach($mode in @('MissingShare','WrongKind','NoFile','WriteFail')){Reset-BackupFixture;$script:taskResetWriteMode=$mode;Fails-Backup $mode}
    Reset-BackupFixture;$script:Request.DryRun=$true;$script:taskResetAdmin=$false
    Backup-ResetState
    Require-Reset ($script:Result.Success -and [string]::IsNullOrEmpty($script:Result.BackupPath) -and $script:Result.Message.StartsWith('Probelauf:')) 'Dry-run backup claimed a real confirmed backup.'
    Require-Reset (-not $script:taskResetCalls.Contains('shares') -and -not $script:taskResetCalls.Contains('write') -and $script:taskResetMutations -eq 0) 'Dry-run backup required Windows access or wrote real backup data.'
    Write-Output ('PASS: '+$script:taskResetPassed+' isolated reset-backup checks; real snapshot/trust/read-back functions exercised, no Windows reset or service/share mutation.')
}finally{
    $taskResetFullRoot=[IO.Path]::GetFullPath($taskResetRoot)
    $taskResetTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($taskResetFullRoot.StartsWith($taskResetTemp,[StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists((Join-Path $taskResetFullRoot '.isolated-test'))){Microsoft.PowerShell.Management\Remove-Item -LiteralPath $taskResetFullRoot -Recurse -Force}
}
