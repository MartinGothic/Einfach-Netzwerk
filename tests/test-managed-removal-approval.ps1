param([string]$WorkerPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if([string]::IsNullOrWhiteSpace($WorkerPath)){$WorkerPath=Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'}
$taskApprovalSource=[IO.File]::ReadAllText([IO.Path]::GetFullPath($WorkerPath))
$taskApprovalTokens=$null;$taskApprovalErrors=$null
$taskApprovalAst=[Management.Automation.Language.Parser]::ParseInput($taskApprovalSource,[ref]$taskApprovalTokens,[ref]$taskApprovalErrors)
$script:taskApprovalPassed=0
function Require-Approval([bool]$value,[string]$message){if(-not $value){throw $message};$script:taskApprovalPassed++}
Require-Approval (@($taskApprovalErrors).Count -eq 0) 'Actual worker syntax must be valid.'
foreach($taskApprovalHelper in @('Get-Value','Normalize-ListedSharePath','Remove-ManagedShare')){
    $taskApprovalFunction=$taskApprovalAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskApprovalHelper},$true)
    Require-Approval ($null -ne $taskApprovalFunction) ('Missing actual removal helper: '+$taskApprovalHelper)
    . ([scriptblock]::Create($taskApprovalFunction.Extent.Text))
}
# The production folder lock must never be reached for an unapproved path.
# A test-only class records any attempted call; it opens no folder or handle.
Add-Type -TypeDefinition @'
namespace EinfachNetzwerk {
 public static class BackendClient {
  public static int LockCalls;
  public static System.IDisposable LockDataFolder(string path) {
   LockCalls++; throw new System.InvalidOperationException("ISOLATED_FOLDER_LOCK_SENTINEL");
  }
 }
}
'@
$script:taskApprovalCalls=New-Object 'Collections.Generic.List[string]'
$script:taskApprovalManaged=$null
$script:taskApprovalNativeReads=0;$script:taskApprovalMutations=0
function Get-Managed($Name){$script:taskApprovalCalls.Add('managed:'+ $Name);return $script:taskApprovalManaged}
function Get-ShareSnapshot($Name){$script:taskApprovalNativeReads++;$script:taskApprovalCalls.Add('snapshot:'+ $Name);throw 'ISOLATED_SHARE_SNAPSHOT_SENTINEL'}
function Assert-NoReparse($Path){throw 'Unexpected filesystem read past the test sentinel.'}
function Is-Administrator{throw 'Unexpected administrator query past the approval guard.'}
function Get-Acl{$script:taskApprovalNativeReads++;throw 'Unexpected ACL query.'}
function Get-ServiceSnapshot{$script:taskApprovalNativeReads++;throw 'Unexpected service query.'}
function Set-Service{$script:taskApprovalMutations++;throw 'Service mutation forbidden.'}
function Remove-SmbShare{$script:taskApprovalMutations++;throw 'Share removal forbidden.'}
function Restore-Folder{$script:taskApprovalMutations++;throw 'Folder ACL mutation forbidden.'}
function Restore-GlobalIfLast{$script:taskApprovalMutations++;throw 'Network configuration mutation forbidden.'}
function Set-ItemProperty{$script:taskApprovalMutations++;throw 'Registry mutation forbidden.'}
function Write-JsonAtomic{$script:taskApprovalMutations++;throw 'Journal write forbidden.'}
function Invoke-ApprovalCase([string]$approved,[string]$current,[bool]$dryRun,[bool]$same,[bool]$restoreOriginal=$false){
    $script:taskApprovalCalls.Clear();$script:taskApprovalNativeReads=0;$script:taskApprovalMutations=0
    [EinfachNetzwerk.BackendClient]::LockCalls=0
    $script:taskApprovalManaged=[pscustomobject]@{Name='Photos';Path=$current}
    $request=[pscustomobject]@{ShareName='Photos';FolderPath=$approved;DryRun=$dryRun}
    $caught=$null
    try{Remove-ManagedShare $request $restoreOriginal}catch{$caught=$_}
    Require-Approval ($null -ne $caught) 'The isolated sentinel or approval guard was not reached.'
    Require-Approval ([EinfachNetzwerk.BackendClient]::LockCalls -eq 0) 'An unapproved path reached the production folder lock.'
    Require-Approval ($script:taskApprovalMutations -eq 0) 'A share/service/ACL/registry mutation was attempted.'
    Require-Approval ($script:taskApprovalCalls.Count -ge 1 -and $script:taskApprovalCalls[0] -eq 'managed:Photos') 'The guard did not read the exact managed share first.'
    if($same){
        Require-Approval ($caught.Exception.Message -eq 'ISOLATED_SHARE_SNAPSHOT_SENTINEL') 'An approved/legacy path was rejected before the fresh share snapshot.'
        Require-Approval ($script:taskApprovalNativeReads -eq 1 -and $script:taskApprovalCalls.Count -eq 2) 'An approved DryRun did not reach exactly one mocked snapshot read.'
    }else{
        Require-Approval ($caught.Exception.Message -ne 'ISOLATED_SHARE_SNAPSHOT_SENTINEL' -and $caught.Exception.Message -ne 'ISOLATED_FOLDER_LOCK_SENTINEL') 'An unapproved path reached a snapshot or lock.'
        Require-Approval ($script:taskApprovalNativeReads -eq 0 -and $script:taskApprovalCalls.Count -eq 1) 'An unapproved path performed a Windows/filesystem read before rejecting approval.'
    }
}
Invoke-ApprovalCase 'C:\ApprovedPhotos' 'D:\RetargetedPhotos' $false $false
Invoke-ApprovalCase 'C:\ApprovedPhotos' 'C:\RetargetedPhotos' $true $false
Invoke-ApprovalCase 'C:\ApprovedPhotos' 'D:\RetargetedPhotos' $false $false $true
Invoke-ApprovalCase '\\OtherComputer\Photos' 'C:\ApprovedPhotos' $false $false
Invoke-ApprovalCase 'C:ApprovedPhotos' 'C:\ApprovedPhotos' $false $false
Invoke-ApprovalCase 'C:\ApprovedPhotos' 'C:\ApprovedPhotos' $true $true
Invoke-ApprovalCase 'c:\approvedphotos\' 'C:\ApprovedPhotos' $true $true
Invoke-ApprovalCase 'C:\ApprovedPhotos\Subfolder\..\' 'C:\ApprovedPhotos' $true $true
Invoke-ApprovalCase '' 'C:\ApprovedPhotos' $true $true
Invoke-ApprovalCase ' ' 'C:\ApprovedPhotos' $true $true
Invoke-ApprovalCase 'D:\' 'D:\' $true $true
Require-Approval ((Normalize-ListedSharePath 'C:\ApprovedPhotos\Child\..\') -eq 'C:\ApprovedPhotos') 'The actual normalizer did not preserve absolute path identity.'
Write-Output ('PASS: '+$script:taskApprovalPassed+' exact managed-removal approval checks; no folder lock, Windows changes or real share/service/ACL reads.')
