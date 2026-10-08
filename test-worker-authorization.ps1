param([Parameter(Mandatory=$true)][string]$ExecutablePath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$taskAuthExecutable=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ExecutablePath).Path)
$script:taskAuthPassed=0
function Require-WorkerAuthorization([bool]$value,[string]$message){if(-not $value){throw $message};$script:taskAuthPassed++}
# The negative cases are safe only with a real non-administrator token. Never
# run a mutation request under an elevated token, even in an isolated folder.
$taskAuthIdentity=[Security.Principal.WindowsIdentity]::GetCurrent()
$taskAuthAdmin=(New-Object Security.Principal.WindowsPrincipal($taskAuthIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Require-WorkerAuthorization (-not $taskAuthAdmin) 'This regression requires a real non-administrator token; no worker requests were executed.'
$taskAuthAssembly=[Reflection.Assembly]::LoadFrom($taskAuthExecutable)
Require-WorkerAuthorization ($taskAuthAssembly.GetName().Version -ge [Version]'2.0.18.0') 'The actual executable must include the corrected worker authorization.'
$taskAuthPolicy=$taskAuthAssembly.GetType('EinfachNetzwerk.WorkerAuthorization',$true)
$taskAuthFlags=[Reflection.BindingFlags]'Static,Public,NonPublic'
$taskAuthUnelevated=$taskAuthPolicy.GetMethod('IsNonElevatedAction',$taskAuthFlags)
$taskAuthRequired=$taskAuthPolicy.GetMethod('RequiresAdministrator',$taskAuthFlags)
Require-WorkerAuthorization ($null -ne $taskAuthUnelevated -and $null -ne $taskAuthRequired) 'The executable is missing the shared action classifier.'
$taskAuthAllowed=@('Inspect','InspectRemote','ConnectRemote','InspectServices','InspectClient','EnumerateComputer','InspectResetShares')
$taskAuthChanges=@('Apply','Repair','Remove','Restore','Rename','RepairSystem','RemoveListedShare','RepairClient','RestoreClient','PrepareClient','RepairServices','RestoreServices','BackupReset')
foreach($taskAuthAction in $taskAuthAllowed){
    Require-WorkerAuthorization ([bool]$taskAuthUnelevated.Invoke($null,[object[]]@($taskAuthAction))) ('Allowed action unexpectedly requests elevation: '+$taskAuthAction)
    $taskAuthRequest=New-Object EinfachNetzwerk.ShareRequest;$taskAuthRequest.Action=$taskAuthAction.ToUpperInvariant()
    Require-WorkerAuthorization (-not [bool]$taskAuthRequired.Invoke($null,[object[]]@($taskAuthRequest.PSObject.BaseObject))) ('Case-insensitive policy is incorrect: '+$taskAuthAction)
}
foreach($taskAuthAction in $taskAuthChanges){
    Require-WorkerAuthorization (-not [bool]$taskAuthUnelevated.Invoke($null,[object[]]@($taskAuthAction))) ('Machine change was classified as non-elevated: '+$taskAuthAction)
    $taskAuthRequest=New-Object EinfachNetzwerk.ShareRequest;$taskAuthRequest.Action=$taskAuthAction
    Require-WorkerAuthorization ([bool]$taskAuthRequired.Invoke($null,[object[]]@($taskAuthRequest.PSObject.BaseObject))) ('Machine change lost its administrator requirement: '+$taskAuthAction)
    $taskAuthRequest.DryRun=$true
    Require-WorkerAuthorization (-not [bool]$taskAuthRequired.Invoke($null,[object[]]@($taskAuthRequest.PSObject.BaseObject))) ('Validated DryRun incorrectly needs elevation: '+$taskAuthAction)
}
Require-WorkerAuthorization (-not [bool]$taskAuthUnelevated.Invoke($null,[object[]]@('UnknownAction'))) 'An unknown action was classified as non-elevated.'

# Compare the independent trusted PowerShell defense with the shared C# policy.
$taskAuthResource=$taskAuthAssembly.GetManifestResourceStream('EinfachNetzwerk.ShareWorker.ps1')
Require-WorkerAuthorization ($null -ne $taskAuthResource) 'The trusted embedded worker is missing.'
$taskAuthReader=New-Object IO.StreamReader($taskAuthResource,[Text.Encoding]::UTF8)
try{$taskAuthWorker=$taskAuthReader.ReadToEnd()}finally{$taskAuthReader.Dispose()}
$taskAuthTokens=$null;$taskAuthErrors=$null
$taskAuthAst=[Management.Automation.Language.Parser]::ParseInput($taskAuthWorker,[ref]$taskAuthTokens,[ref]$taskAuthErrors)
Require-WorkerAuthorization (@($taskAuthErrors).Count -eq 0) 'The embedded worker syntax is invalid.'
$taskAuthGuards=@($taskAuthAst.FindAll({param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('$action -notin') -and $node.Clauses[0].Item1.Extent.Text.Contains("'DryRun'")
},$true))
Require-WorkerAuthorization ($taskAuthGuards.Count -eq 1) 'The independent worker administrator gate is ambiguous.'
$taskAuthPsActions=@($taskAuthGuards[0].Clauses[0].Item1.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -ne [Management.Automation.Language.StringConstantType]::BareWord},$true)|ForEach-Object{$_.Value}|Where-Object{$_ -ne 'DryRun'})
Require-WorkerAuthorization ($taskAuthPsActions.Count -eq $taskAuthAllowed.Count) 'C# and PowerShell contain different non-elevated action sets.'
foreach($taskAuthAction in $taskAuthAllowed){Require-WorkerAuthorization ($taskAuthAction -in $taskAuthPsActions) ('The embedded PowerShell worker lost its non-admin action: '+$taskAuthAction)}

$taskAuthRoot=Join-Path ([IO.Path]::GetTempPath()) ('EinfachNetzwerk-worker-auth-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($taskAuthRoot)
[IO.File]::WriteAllText((Join-Path $taskAuthRoot '.isolated-test'),'Real non-admin EXE worker authorization only; no Windows configuration changes.')
$script:taskAuthCalls=0
function Invoke-ActualWorker([string]$action,[bool]$blocked){
    $script:taskAuthCalls++
    $directory=Join-Path $taskAuthRoot ('case-'+$script:taskAuthCalls)
    [void][IO.Directory]::CreateDirectory($directory)
    $requestPath=Join-Path $directory 'Request.json';$resultPath=Join-Path $directory 'Result.json'
    $request=[ordered]@{
        Action=$action;DryRun=$false;AdapterId=7;Mode='Guest';AllowGuestSettings=$true;AllowAdvancedRepair=$true
        ShareName='NeverCreatedAuthFixture';FolderPath=(Join-Path $taskAuthRoot 'UncreatedDataFolder')
        UserName='AuthFixture';ComputerName='AUTH-QA';RemoteHost='NEVER-EXISTS';RemoteShareName='AuthFixture';RemoteUserName='NEVER-EXISTS\Guest'
        ProtectedPassword='';OriginalUserSid=$taskAuthIdentity.User.Value
    }
    [IO.File]::WriteAllText($requestPath,(ConvertTo-Json -InputObject $request -Compress),(New-Object Text.UTF8Encoding($false)))
    $process=Start-Process -FilePath $taskAuthExecutable -ArgumentList @('--worker',('"'+$requestPath+'"'),('"'+$resultPath+'"')) -WindowStyle Hidden -PassThru
    try{
        if(-not $process.WaitForExit(45000)){
            # Only this read-only or non-admin child is stopped, never a user app.
            $process.Kill();$process.WaitForExit();throw ('Isolated worker exceeded45 seconds: '+$action)
        }
        Require-WorkerAuthorization ([IO.File]::Exists($resultPath)) ('The actual Program.RunWorker did not write its guarded result: '+$action)
        $result=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($blocked){
            Require-WorkerAuthorization ($process.ExitCode -eq 1 -and -not $result.Success) ('Actual non-admin RunWorker accepted a machine change: '+$action)
            Require-WorkerAuthorization ($result.Message -eq 'Diese Einrichtung benötigt Windows-Administratorrechte.') ('The change did not stop at Program authorization: '+$action+' / '+$result.Message)
            Require-WorkerAuthorization (-not [IO.File]::Exists(($resultPath+'.phase'))) ('The blocked change reached embedded PowerShell before authorization: '+$action)
            Require-WorkerAuthorization ($result.ErrorType -eq 'System.InvalidOperationException' -and $result.ErrorCode -match '0x80131509') ('The guarded native diagnostic identity was lost: '+$action)
        }else{
            Require-WorkerAuthorization ($result.Message -ne 'Diese Einrichtung benötigt Windows-Administratorrechte.') ('Readonly real worker was still rejected by Program: '+$action)
            Require-WorkerAuthorization ([IO.File]::Exists(($resultPath+'.phase'))) ('Readonly real worker never reached its embedded module: '+$action+' / '+$result.Message)
            Require-WorkerAuthorization ($process.ExitCode -eq $(if($result.Success){0}else{1})) ('The real worker exit code and actual result disagree: '+$action)
            if($action -eq 'InspectResetShares'){
                Require-WorkerAuthorization (@($result.Checks|Where-Object{$_.Code -in @('RESET_SHARE_INVENTORY_CONFIRMED','RESET_SHARE_INVENTORY_UNCONFIRMED')}).Count -eq 1) 'Real reset inventory did not report confirmed inventory or an honest query failure.'
                $counted=[IO.File]::ReadAllText(($resultPath+'.phase'),[Text.Encoding]::UTF8)|ConvertFrom-Json
                Require-WorkerAuthorization ($counted.Total -eq 8 -and $counted.Percent -lt 100) 'The real reset inventory skipped its actual counted worker plan.'
            }
        }
        Require-WorkerAuthorization (-not $result.ConnectionVerified -and -not $result.NativeConnectionVerified -and -not $result.NamedConnectionVerified -and -not $result.RemoteComputerEnumerationVerified) ('Authorization regression claimed a remote share connection: '+$action)
        return [pscustomobject]@{Action=$action;Blocked=$blocked;Success=$result.Success;Message=$result.Message;ErrorCode=$result.ErrorCode}
    }finally{$process.Dispose()}
}
try{
    $outcomes=New-Object 'Collections.Generic.List[object]'
    foreach($taskAuthAction in @('InspectResetShares','InspectClient','InspectServices')){$outcomes.Add((Invoke-ActualWorker $taskAuthAction $false))}
    foreach($taskAuthAction in $taskAuthChanges){$outcomes.Add((Invoke-ActualWorker $taskAuthAction $true))}
    $outputReport=Join-Path $PSScriptRoot 'worker-authorization-results.json'
    [IO.File]::WriteAllText($outputReport,(ConvertTo-Json -InputObject ([ordered]@{Success=$true;Assertions=$script:taskAuthPassed;RealWorkerInvocations=$script:taskAuthCalls;Executable=$taskAuthExecutable;AdministratorToken=$taskAuthAdmin;Results=$outcomes.ToArray();Scope='Real Program.RunWorker and embedded readonly modules; machine changes rejected before PowerShell; no reset or Windows configuration mutations.'}) -Depth 8),(New-Object Text.UTF8Encoding($false)))
    Write-Output ('PASS: '+$script:taskAuthPassed+' worker authorization checks; '+$script:taskAuthCalls+' real non-admin EXE workers; no reset or Windows configuration changes. Report: '+$outputReport)
}finally{
    $taskAuthResolved=[IO.Path]::GetFullPath($taskAuthRoot);$taskAuthTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($taskAuthResolved.StartsWith($taskAuthTemp,[StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists((Join-Path $taskAuthResolved '.isolated-test'))){Microsoft.PowerShell.Management\Remove-Item -LiteralPath $taskAuthResolved -Recurse -Force}
}
