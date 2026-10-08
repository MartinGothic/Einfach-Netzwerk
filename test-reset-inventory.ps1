param([string]$WorkerPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if([string]::IsNullOrWhiteSpace($WorkerPath)){$WorkerPath=Join-Path $PSScriptRoot 'ShareWorker.ps1'}
$taskInventorySource=[IO.File]::ReadAllText([IO.Path]::GetFullPath($WorkerPath))
$taskInventoryTokens=$null;$taskInventoryErrors=$null
$taskInventoryAst=[Management.Automation.Language.Parser]::ParseInput($taskInventorySource,[ref]$taskInventoryTokens,[ref]$taskInventoryErrors)
$script:taskInventoryPassed=0
function Require-Inventory([bool]$value,[string]$message){if(-not $value){throw $message};$script:taskInventoryPassed++}
Require-Inventory (@($taskInventoryErrors).Count -eq 0) 'The actual worker must parse under Windows PowerShell5.'
$taskInventoryEntry=@($taskInventoryAst.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.TryStatementAst]})
Require-Inventory ($taskInventoryEntry.Count -eq 1) 'The actual main worker dispatch must be unambiguous.'
foreach($taskInventoryHelper in @('Open-ResetServiceRegistryRoot','Read-PersistedResetShares','Inspect-ResetShares')){
    $taskInventoryFunction=$taskInventoryAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $taskInventoryHelper},$true)
    Require-Inventory ($null -ne $taskInventoryFunction) ('Missing actual inventory helper: '+$taskInventoryHelper)
    Require-Inventory ($taskInventoryFunction.Extent.Text -notmatch '(?i)\b(?:Set-ItemProperty|Remove-ItemProperty|Remove-SmbShare|Set-Service|Start-Service|Stop-Service|CreateSubKey|SetValue\()') ('Inventory helper mutates Windows: '+$taskInventoryHelper)
}
$taskInventoryOpen=$taskInventoryAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Open-ResetServiceRegistryRoot'},$true)
Require-Inventory ($taskInventoryOpen.Extent.Text -match "OpenSubKey\('SYSTEM\\CurrentControlSet\\Services', \`$false\)") 'Registry entrypoint must explicitly open the local Services root read-only.'
$taskInventoryRules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Models.cs'))
Require-Inventory ($taskInventoryRules -match '"inspectresetshares"' -and $taskInventoryRules -match 'action == "inspect" \|\| action == "inspectresetshares"\) return null;') 'RequestRules must accept the new read-only action without share or credential fields.'

function New-InventoryRegistryKey([string]$name){
    $key=[pscustomobject]@{Name=$name;Children=@{};Values=@{};Kinds=@{};NullSubkeys=$false;NullValues=$false;FailSubkeys=$false;FailValues=$false;FailOpen=$false;FailKind=$false;FailValue=$false;Disposed=$false;GhostChildren=@()}
    $key|Add-Member ScriptMethod GetSubKeyNames {
        $global:ResetInventoryFixture.Calls.Add('subkeys:'+ $this.Name)
        if($this.FailSubkeys){throw (New-Object Security.SecurityException('Isolated registry enumeration denied.'))}
        if($this.NullSubkeys){return $null}
        return ,([string[]](@($this.Children.Keys)+@($this.GhostChildren)))
    }
    $key|Add-Member ScriptMethod OpenSubKey {
        param($name,$writable)
        if($writable){throw 'Inventory requested writable registry access.'}
        $global:ResetInventoryFixture.Calls.Add('open:'+ $this.Name+'/'+$name)
        if($this.FailOpen){throw (New-Object Security.SecurityException('Isolated registry key denied.'))}
        if($this.Children.ContainsKey($name)){return $this.Children[$name]}
        return $null
    }
    $key|Add-Member ScriptMethod GetValueNames {
        $global:ResetInventoryFixture.Calls.Add('values:'+ $this.Name)
        if($this.FailValues){throw (New-Object Security.SecurityException('Isolated share names denied.'))}
        if($this.NullValues){return $null}
        return ,([string[]]@($this.Values.Keys))
    }
    $key|Add-Member ScriptMethod GetValueKind {
        param($name)
        if($this.FailKind){throw (New-Object Security.SecurityException('Isolated definition kind denied.'))}
        return $this.Kinds[$name]
    }
    $key|Add-Member ScriptMethod GetValue {
        param($name,$fallback,$options)
        if($options -ne [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames){throw 'Inventory expanded persisted environment variables.'}
        if($this.FailValue){throw (New-Object Security.SecurityException('Isolated definition denied.'))}
        $value=$this.Values[$name]
        if($value -is [string[]]){return ,$value}
        return $value
    }
    $key|Add-Member ScriptMethod Dispose {$this.Disposed=$true;$global:ResetInventoryFixture.Calls.Add('dispose:'+ $this.Name)}
    return $key
}
function New-InventoryFixture([string]$state='Running'){
    $shares=New-InventoryRegistryKey 'Shares';$server=New-InventoryRegistryKey 'LanmanServer';$services=New-InventoryRegistryKey 'Services'
    $server.Children['Shares']=$shares;$services.Children['LanmanServer']=$server
    $global:ResetInventoryFixture=[pscustomobject]@{
        Calls=(New-Object 'Collections.Generic.List[string]');Mutations=0;AdminReads=0;NetworkReads=0;SmbReads=0;RegistryReads=0
        Root=$services;Server=$server;Persisted=$shares;RootFailure=$false;ServiceFailure=$false;LedgerFailure=$false;LiveFailure=$false
        Service=[pscustomobject]@{Exists=($state -ne 'Missing');State=$state;Name='LanmanServer';Win32ExitCode=0}
        Ledger=$null;Live=@();
    }
}
function Add-InventoryDefinition([string]$name,[object]$definition,[Microsoft.Win32.RegistryValueKind]$kind=[Microsoft.Win32.RegistryValueKind]::MultiString){
    $global:ResetInventoryFixture.Persisted.Values[$name]=$definition
    $global:ResetInventoryFixture.Persisted.Kinds[$name]=$kind
}
$taskInventoryDoubles=@'
function Get-ServiceNativeSnapshot($Name){
    $global:ResetInventoryFixture.Calls.Add('native:'+ $Name)
    if($Name -ne 'LanmanServer'){throw 'Inventory inspected an unrelated service.'}
    if($global:ResetInventoryFixture.ServiceFailure){throw (New-Object ComponentModel.Win32Exception(5,'Isolated native query denied.'))}
    return $global:ResetInventoryFixture.Service
}
function Read-Ledger {
    $global:ResetInventoryFixture.Calls.Add('ledger')
    if($global:ResetInventoryFixture.LedgerFailure){throw 'Isolated journal is damaged.'}
    return $global:ResetInventoryFixture.Ledger
}
function Open-ResetServiceRegistryRoot {
    $global:ResetInventoryFixture.RegistryReads++
    if($global:ResetInventoryFixture.RootFailure){throw (New-Object Security.SecurityException('Isolated Services registry denied.'))}
    return $global:ResetInventoryFixture.Root
}
function Get-SmbShare($ErrorAction){
    $global:ResetInventoryFixture.SmbReads++
    if($global:ResetInventoryFixture.Service.State -ne 'Running'){throw 'SMB provider called while Server was unavailable.'}
    if($global:ResetInventoryFixture.LiveFailure){throw (New-Object ComponentModel.Win32Exception(5,'Isolated SMB inventory denied.'))}
    return $global:ResetInventoryFixture.Live
}
function Is-Administrator{$global:ResetInventoryFixture.AdminReads++;return $false}
function Get-HomeNetworks{$global:ResetInventoryFixture.NetworkReads++;throw 'Inventory performed a network probe.'}
function Set-Service {$global:ResetInventoryFixture.Mutations++;throw 'Real service mutation forbidden.'}
function Start-Service {$global:ResetInventoryFixture.Mutations++;throw 'Real service mutation forbidden.'}
function Stop-Service {$global:ResetInventoryFixture.Mutations++;throw 'Real service mutation forbidden.'}
function Remove-SmbShare {$global:ResetInventoryFixture.Mutations++;throw 'Real share removal forbidden.'}
function Set-ItemProperty {$global:ResetInventoryFixture.Mutations++;throw 'Real registry mutation forbidden.'}
function New-ItemProperty {$global:ResetInventoryFixture.Mutations++;throw 'Real registry mutation forbidden.'}
function Remove-ItemProperty {$global:ResetInventoryFixture.Mutations++;throw 'Real registry mutation forbidden.'}
function Set-Acl {$global:ResetInventoryFixture.Mutations++;throw 'Real ACL mutation forbidden.'}
'@
$taskInventoryWorker=$taskInventorySource.Insert($taskInventoryEntry[0].Extent.StartOffset,$taskInventoryDoubles+[Environment]::NewLine)
$taskInventoryRoot=Join-Path ([IO.Path]::GetTempPath()) ('EinfachNetzwerk-reset-inventory-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($taskInventoryRoot)
[IO.File]::WriteAllText((Join-Path $taskInventoryRoot '.isolated-test'),'Exact worker dispatch with Windows doubles only. No configuration changes.')
$script:taskInventoryCase=0
function Invoke-InventoryFixture([bool]$expected,[bool]$dryRun=$false){
    $script:taskInventoryCase++
    $requestPath=Join-Path $taskInventoryRoot ('request-'+$script:taskInventoryCase+'.json')
    $resultPath=Join-Path $taskInventoryRoot ('result-'+$script:taskInventoryCase+'.json')
    $json=ConvertTo-Json -InputObject ([ordered]@{Action='InspectResetShares';DryRun=$dryRun;AdapterId=-1;AllowAdvancedRepair=$false}) -Compress
    [IO.File]::WriteAllText($requestPath,$json)
    & ([scriptblock]::Create($taskInventoryWorker)) -RequestPath $requestPath -ResultPath $resultPath -RequestJson $json|Out-Null
    Require-Inventory ([IO.File]::Exists($resultPath)) 'Actual readonly worker dispatch did not save an isolated result.'
    $result=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json
    $progress=[IO.File]::ReadAllText(($resultPath+'.phase'))|ConvertFrom-Json
    Require-Inventory ($result.Success -eq $expected) ('Unexpected inventory success: '+$result.Message)
    Require-Inventory ($progress.Total -eq 8 -and $progress.Percent -eq [int][Math]::Floor(100.0*$progress.Completed/$progress.Total) -and $progress.Percent -lt 100) 'Inventory progress is not based on five real worker units plus existing result/UI units.'
    Require-Inventory ($global:ResetInventoryFixture.AdminReads -eq 0 -and $global:ResetInventoryFixture.Mutations -eq 0 -and $global:ResetInventoryFixture.NetworkReads -eq 0) 'Readonly inventory elevated, mutated Windows or inspected network readiness.'
    Require-Inventory (-not $result.ConnectionVerified -and -not $result.NativeConnectionVerified -and -not $result.NamedConnectionVerified -and -not $result.RemoteComputerEnumerationVerified) 'Local inventory claimed an external access proof.'
    if($expected){
        Require-Inventory ($progress.Completed -eq 7) 'Confirmed inventory left a real worker/result unit uncounted.'
        Require-Inventory (@($result.Checks|Where-Object{$_.Name -eq 'Freigaben' -and $_.State -eq 'ok' -and $_.Code -eq 'RESET_SHARE_INVENTORY_CONFIRMED'}).Count -eq 1) 'Confirmed inventory is missing the exact trusted proof code.'
    }else{
        Require-Inventory ($null -eq $result.Shares) 'Failed inventory guessed an empty share list.'
        Require-Inventory (@($result.Checks|Where-Object{$_.Code -eq 'RESET_SHARE_INVENTORY_UNCONFIRMED' -and $_.State -eq 'error'}).Count -eq 1) 'Unconfirmed inventory lacks an explicit error.'
        Require-Inventory (@($result.Checks|Where-Object{$_.Code -eq 'RESET_SHARE_INVENTORY_CONFIRMED'}).Count -eq 0) 'Failed inventory emitted a success proof.'
        Require-Inventory ($progress.Completed -lt 7) 'Failed inventory falsely counted completed inspection.'
    }
    return $result
}
try{
    New-InventoryFixture
    $global:ResetInventoryFixture.Live=@([pscustomobject]@{Name='Photos';Path='C:\IsolatedPhotos';Special=$false},[pscustomobject]@{Name='Hidden$';Path='D:\IsolatedHidden';Special=$false},[pscustomobject]@{Name='ADMIN$';Path='C:\Windows';Special=$true},[pscustomobject]@{Name='C$';Path='C:\';Special=$true})
    $global:ResetInventoryFixture.Ledger=[pscustomobject]@{Shares=@([pscustomobject]@{Name='Photos';Path='C:\IsolatedPhotos';Mode='Guest';UserName='Guest';AllowWrite=$true;AdapterId=7},[pscustomobject]@{Name='MissingManaged';Path='D:\IsolatedMissing';Mode='Password';UserName='NetworkUser';AllowWrite=$false;AdapterId=8})}
    $result=Invoke-InventoryFixture $true
    Require-Inventory ($result.Shares.Count -eq 3 -and $global:ResetInventoryFixture.SmbReads -eq 1 -and $global:ResetInventoryFixture.RegistryReads -eq 0) 'Live exact provider inventory dropped hidden data or added administrative shares.'
    Require-Inventory ($result.Shares[0].Managed -and $result.Shares[0].Available -and $result.Shares[0].AllowWrite) 'Live managed configuration was lost.'
    Require-Inventory (@($result.Shares|Where-Object{$_.Name -eq 'MissingManaged' -and $_.Managed -and -not $_.Available}).Count -eq 1) 'Live inventory dropped a missing managed ledger entry.'
    New-InventoryFixture;$result=Invoke-InventoryFixture $true $true
    Require-Inventory (@($result.Shares).Count -eq 0 -and $global:ResetInventoryFixture.SmbReads -eq 1) 'Successful empty live inventory was not confirmed during DryRun.'
    New-InventoryFixture;$global:ResetInventoryFixture.LiveFailure=$true;$result=Invoke-InventoryFixture $false
    Require-Inventory ($result.ErrorCode -match 'Win32\[[0-9]+\]: 5' -and $global:ResetInventoryFixture.RegistryReads -eq 0) 'Live provider failure was disguised by a registry fallback or lost its native code.'

    New-InventoryFixture 'Stopped'
    Add-InventoryDefinition 'Photos' ([string[]]@('Path=C:\IsolatedPhotos','Remark=Photo library','Type=0'))
    Add-InventoryDefinition 'Hidden$' ([string[]]@('pAtH=D:\IsolatedHidden','Remark=x=y'))
    Add-InventoryDefinition 'ADMIN$' ([string[]]@('Path=C:\Windows'))
    Add-InventoryDefinition 'IPC$' ([string[]]@('Path='))
    Add-InventoryDefinition 'C$' ([string[]]@('Path=C:\'))
    Add-InventoryDefinition '' '' ([Microsoft.Win32.RegistryValueKind]::String)
    $global:ResetInventoryFixture.Ledger=[pscustomobject]@{Shares=@([pscustomobject]@{Name='MissingManaged';Path='D:\IsolatedMissing';Mode='Guest';UserName='Guest';AllowWrite=$true;AdapterId=7})}
    $result=Invoke-InventoryFixture $true
    Require-Inventory ($result.Shares.Count -eq 3 -and $global:ResetInventoryFixture.SmbReads -eq 0 -and $global:ResetInventoryFixture.RegistryReads -eq 1) 'Stopped-server persistent inventory lost normal/hidden/missing-owned shares or queried unavailable SMB.'
    Require-Inventory (@($result.Shares|Where-Object{$_.Name -eq 'Hidden$' -and $_.Available -and -not $_.Managed}).Count -eq 1) 'A hidden ordinary persisted share was mistaken for a Windows system share.'
    Require-Inventory ($result.Message -match 'keinen Netzwerkzugriff') 'Persistent definitions were presented as actual network access proof.'
    Require-Inventory ($global:ResetInventoryFixture.Root.Disposed -and $global:ResetInventoryFixture.Server.Disposed -and $global:ResetInventoryFixture.Persisted.Disposed) 'Read-only registry handles were not released.'
    New-InventoryFixture 'Stopped';$result=Invoke-InventoryFixture $true
    Require-Inventory (@($result.Shares).Count -eq 0) 'Confirmed empty persisted definitions were not accepted.'
    New-InventoryFixture 'Stopped';$global:ResetInventoryFixture.Server.Children.Clear();$result=Invoke-InventoryFixture $true
    Require-Inventory (@($result.Shares).Count -eq 0 -and $global:ResetInventoryFixture.Server.Disposed) 'Confirmed absent Shares subkey was not handled as empty configuration.'
    New-InventoryFixture 'Missing';$global:ResetInventoryFixture.Root.Children.Clear();$result=Invoke-InventoryFixture $true
    Require-Inventory (@($result.Shares).Count -eq 0 -and $global:ResetInventoryFixture.Root.Disposed) 'Confirmed absent server/configuration was not handled honestly.'
    New-InventoryFixture 'Missing';Add-InventoryDefinition 'PersistedAfterServiceMissing' ([string[]]@('PATH=D:\StillSaved'));$result=Invoke-InventoryFixture $true
    Require-Inventory ($result.Shares.Count -eq 1) 'A missing service concealed a still-present persisted data share.'

    foreach($state in @('StartPending','StopPending','Paused','Unknown')){New-InventoryFixture $state;$result=Invoke-InventoryFixture $false;Require-Inventory ($global:ResetInventoryFixture.SmbReads -eq 0 -and $global:ResetInventoryFixture.RegistryReads -eq 0) ('Transient/unconfirmed service state was treated as stable: '+$state)}
    New-InventoryFixture;$global:ResetInventoryFixture.Service=$null;$null=Invoke-InventoryFixture $false
    New-InventoryFixture;$global:ResetInventoryFixture.Service=[pscustomobject]@{Exists='false';State='Missing'};$null=Invoke-InventoryFixture $false
    New-InventoryFixture;$global:ResetInventoryFixture.ServiceFailure=$true;$result=Invoke-InventoryFixture $false;Require-Inventory ($result.ErrorCode -match 'Win32\[[0-9]+\]: 5') 'Native status failure lost the original access code.'
    New-InventoryFixture;$global:ResetInventoryFixture.LedgerFailure=$true;$null=Invoke-InventoryFixture $false
    foreach($failure in @('RootNull','RootDenied','ServiceNamesDenied','ServiceNamesNull','ServiceGhost','ServerNamesDenied','ServerNamesNull','SharesGhost','ShareNamesDenied','ShareNamesNull','ValueKindDenied','ValueDenied')){
        New-InventoryFixture 'Stopped';Add-InventoryDefinition 'Photos' ([string[]]@('Path=C:\IsolatedPhotos'))
        switch($failure){
            'RootNull'{$global:ResetInventoryFixture.Root=$null}
            'RootDenied'{$global:ResetInventoryFixture.RootFailure=$true}
            'ServiceNamesDenied'{$global:ResetInventoryFixture.Root.FailSubkeys=$true}
            'ServiceNamesNull'{$global:ResetInventoryFixture.Root.NullSubkeys=$true}
            'ServiceGhost'{$global:ResetInventoryFixture.Root.Children.Clear();$global:ResetInventoryFixture.Root.GhostChildren=@('LanmanServer')}
            'ServerNamesDenied'{$global:ResetInventoryFixture.Server.FailSubkeys=$true}
            'ServerNamesNull'{$global:ResetInventoryFixture.Server.NullSubkeys=$true}
            'SharesGhost'{$global:ResetInventoryFixture.Server.Children.Clear();$global:ResetInventoryFixture.Server.GhostChildren=@('Shares')}
            'ShareNamesDenied'{$global:ResetInventoryFixture.Persisted.FailValues=$true}
            'ShareNamesNull'{$global:ResetInventoryFixture.Persisted.NullValues=$true}
            'ValueKindDenied'{$global:ResetInventoryFixture.Persisted.FailKind=$true}
            'ValueDenied'{$global:ResetInventoryFixture.Persisted.FailValue=$true}
        }
        $null=Invoke-InventoryFixture $false
    }
    foreach($malformed in @('WrongKind','Null','Scalar','Empty','MissingPath','DuplicatePath','RemotePath','RelativePath','BrokenEntry','ControlPath','InvalidName')){
        New-InventoryFixture 'Stopped';$name='Malformed';$definition=[string[]]@('Path=C:\IsolatedPhotos');$kind=[Microsoft.Win32.RegistryValueKind]::MultiString
        switch($malformed){
            'WrongKind'{$kind=[Microsoft.Win32.RegistryValueKind]::String}
            'Null'{$definition=$null}
            'Scalar'{$definition='Path=C:\IsolatedPhotos'}
            'Empty'{$definition=[string[]]@()}
            'MissingPath'{$definition=[string[]]@('Remark=missing path')}
            'DuplicatePath'{$definition=[string[]]@('Path=C:\One','PATH=D:\Two')}
            'RemotePath'{$definition=[string[]]@('Path=\\OtherComputer\Photos')}
            'RelativePath'{$definition=[string[]]@('Path=C:Photos')}
            'BrokenEntry'{$definition=[string[]]@('Path=C:\IsolatedPhotos','damaged-entry')}
            'ControlPath'{$definition=[string[]]@("Path=C:\Isolated`nPhotos")}
            'InvalidName'{$name='Bad*Name'}
        }
        Add-InventoryDefinition $name $definition $kind;$null=Invoke-InventoryFixture $false
    }
    Write-Output ('PASS: '+$script:taskInventoryPassed+' reset-inventory assertions; '+$script:taskInventoryCase+' exact worker-dispatch cases; Windows calls doubled and only isolated result files written.')
}finally{
    if(Test-Path variable:global:ResetInventoryFixture){Remove-Variable ResetInventoryFixture -Scope Global}
    $taskInventoryResolved=[IO.Path]::GetFullPath($taskInventoryRoot);$taskInventoryTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($taskInventoryResolved.StartsWith($taskInventoryTemp,[StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists((Join-Path $taskInventoryResolved '.isolated-test'))){Microsoft.PowerShell.Management\Remove-Item -LiteralPath $taskInventoryResolved -Recurse -Force}
}
