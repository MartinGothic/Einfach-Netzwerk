param([string]$ExecutablePath = (Join-Path $PSScriptRoot '..\dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# Exercise only metadata helpers in memory. No Windows sharing cmdlet is run.
$codeTestCount = 0
function Assert-CodeTest([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    $script:codeTestCount++
}
$workerSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'))
$workerTokens = $null; $workerParseErrors = $null
$workerAst = [Management.Automation.Language.Parser]::ParseInput($workerSource, [ref]$workerTokens, [ref]$workerParseErrors)
Assert-CodeTest (@($workerParseErrors).Count -eq 0) 'Worker syntax invalid.'
foreach ($helperName in @('Get-Value', 'Hide-FailureSecrets', 'Set-FailureDetails')) {
    $helperAst = $workerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName }, $true)
    if ($null -eq $helperAst) { throw ('Missing diagnostic helper: ' + $helperName) }
    . ([scriptblock]::Create($helperAst.Extent.Text))
}
$script:Secret = 'private-failure-sentinel-!123'
$script:Request = [pscustomobject]@{ ProtectedPassword = 'encrypted-failure-sentinel-ABC' }
$script:Result = [ordered]@{ ErrorCode = ''; ErrorType = ''; ErrorStackTrace = '' }
try { throw (New-Object ComponentModel.Win32Exception(5, ('Denied ' + $script:Secret + ' ' + $script:Request.ProtectedPassword))) }
catch { $testFailureRecord = $_ }
Set-FailureDetails $testFailureRecord
Assert-CodeTest ($script:Result.ErrorCode -match 'Win32\[\d+\]: 5') 'Original native Windows code missing.'
Assert-CodeTest ($script:Result.ErrorCode -match 'HRESULT\[\d+\]: 0x[0-9A-F]{8}') 'Original HRESULT missing.'
Assert-CodeTest ($script:Result.ErrorCode -like '*PowerShell:*') 'PowerShell identifier missing.'
Assert-CodeTest (-not [string]::IsNullOrWhiteSpace($script:Result.ErrorType)) 'Original exception type missing.'
Assert-CodeTest ($script:Result.ErrorStackTrace -like '*test-failure-codes.ps1*') 'Script stack location missing.'
foreach ($secretValue in @($script:Secret, $script:Request.ProtectedPassword)) {
    Assert-CodeTest (-not ($script:Result.ErrorStackTrace.Contains($secretValue))) 'Credential retained in error stack.'
    Assert-CodeTest (-not ($script:Result.ErrorCode.Contains($secretValue))) 'Credential retained in error code.'
    Assert-CodeTest (-not ((Hide-FailureSecrets $testFailureRecord.Exception.Message).Contains($secretValue))) 'Credential retained in error message.'
}
# Execute only Apply-Share's real rollback catch with local doubles; preserve
# its original ErrorRecord through rethrow without running Apply-Share itself.
$applyAst = $workerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Apply-Share' }, $true)
$rollbackCatch = $applyAst.Find({ param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Body.Extent.Text.Contains('$failureRecord = $_') }, $true)
Assert-CodeTest ($null -ne $rollbackCatch) 'Rollback must retain the original ErrorRecord.'
$script:Transaction = [pscustomobject]@{ Status = 'Applying' }
function Write-Phase { param([string]$Text) }
function Undo-Transaction { param($Transaction) return $true }
function Write-JsonAtomic { param($Path, $Object) }
$backup = 'isolated-metadata-only'
$rollbackCode = [scriptblock]::Create($rollbackCatch.Body.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
try {
    try { throw (New-Object ComponentModel.Win32Exception(53, ('Network unavailable ' + $script:Secret))) }
    catch { & $rollbackCode }
} catch { $rollbackFailureRecord = $_ }
Set-FailureDetails $rollbackFailureRecord
Assert-CodeTest ($script:Result.ErrorCode -match 'Win32\[\d+\]: 53') 'Rollback converted native code to message text.'
Assert-CodeTest (-not ($script:Result.ErrorStackTrace.Contains($script:Secret))) 'Rollback retained plaintext in diagnostic stack.'
Assert-CodeTest ($script:Transaction.Status -eq 'RolledBack') 'Rollback status is unchanged by error metadata.'
$script:Secret = $null; $script:Request = $null

$codeAssembly = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($ExecutablePath))
$failureType = $codeAssembly.GetType('EinfachNetzwerk.BackendClient', $true)
$failureMethod = $failureType.GetMethod('Failure', [Reflection.BindingFlags]'NonPublic,Static', $null, [Type[]]@([string], [Exception]), $null)
$nativeCodeError = New-Object ComponentModel.Win32Exception(1060, 'Service does not exist')
$wrappedCodeError = New-Object InvalidOperationException('Wrapped failure', $nativeCodeError)
$backendResult = $failureMethod.Invoke($null, [object[]]@('Known failure', $wrappedCodeError.PSObject.BaseObject))
Assert-CodeTest (-not $backendResult.Success) 'Failure marked successful.'
Assert-CodeTest ($backendResult.ErrorCode -like '*Win32: 1060*') 'Backend native code lost.'
Assert-CodeTest ($backendResult.ErrorCode -like '*InnerException[[]1[]]*') 'Nested error code lost.'
Assert-CodeTest ($backendResult.ErrorType -eq 'System.InvalidOperationException') 'Backend error type lost.'
Assert-CodeTest ($backendResult.ErrorStackTrace -like '*Service does not exist*') 'Backend nested stack lost.'
Assert-CodeTest ($backendResult.Checks[0].Code -eq $backendResult.ErrorCode) 'Visible check code does not match original.'
$jsonType = $codeAssembly.GetType('EinfachNetzwerk.JsonData', $true)
$serialized = $jsonType.GetMethod('Serialize').Invoke($null, [object[]]@($backendResult))
Assert-CodeTest ($serialized -like '*"ErrorCode"*') 'JSON error-code field missing.'
$i18nType = $codeAssembly.GetType('EinfachNetzwerk.I18n', $true)
foreach ($languageCode in @('de', 'en', 'fr', 'es', 'it', 'pt', 'pl')) {
    $i18nType.GetProperty('Language').SetValue($null, $languageCode, $null)
    $translatedResult = $i18nType.GetMethod('TranslateResult').Invoke($null, [object[]]@($backendResult))
    Assert-CodeTest ($translatedResult.ErrorCode -eq $backendResult.ErrorCode) 'Language change alters original codes.'
    Assert-CodeTest ($translatedResult.ErrorStackTrace -eq $backendResult.ErrorStackTrace) 'Language change alters original stack.'
}
Write-Output ('PASS: ' + $codeTestCount + ' isolated failure-code/redaction checks; no Windows sharing mutations.')
