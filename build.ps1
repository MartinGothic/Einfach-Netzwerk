param([switch]$SkipTests, [string]$OutputName = 'Einfach-Netzwerk.exe')
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework-Compiler fehlt. Das Programm wird auf Windows mit .NET Framework 4.8 gebaut.' }
$destination = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
if ([IO.Path]::GetFileName($OutputName) -ne $OutputName -or $OutputName -notmatch '^[A-Za-z0-9._-]+\.exe$') { throw 'Invalid executable filename.' }
$executable = Join-Path $destination $OutputName
$sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' -File | Sort-Object Name | ForEach-Object {$_.FullName})
$arguments = @('/nologo','/target:winexe','/platform:anycpu','/langversion:5','/optimize+','/debug-',('/out:'+$executable),('/win32manifest:'+(Join-Path $PSScriptRoot 'app.manifest')),('/resource:'+(Join-Path $PSScriptRoot 'ShareWorker.ps1')+',EinfachNetzwerk.ShareWorker.ps1'),'/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll','/reference:System.Security.dll','/reference:System.Xml.dll')
$arguments += '/resource:' + (Join-Path $PSScriptRoot 'ClientAccessWorker.ps1') + ',EinfachNetzwerk.ClientAccessWorker.ps1'
$arguments += '/resource:' + (Join-Path $PSScriptRoot 'ServiceHealthWorker.ps1') + ',EinfachNetzwerk.ServiceHealthWorker.ps1'
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'network.ico')) { $arguments += '/win32icon:'+(Join-Path $PSScriptRoot 'network.ico') }
& $compiler @arguments @sources
if ($LASTEXITCODE -ne 0) { throw 'Der Build ist fehlgeschlagen.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $destination 'Anleitung.md') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $destination 'Anleitung.txt') -Force
if (-not $SkipTests) {
    $report = Join-Path $PSScriptRoot 'test-results.json'
    $test = Start-Process -FilePath $executable -ArgumentList @('--self-test',('"'+$report+'"')) -Wait -PassThru -WindowStyle Hidden
    if ($test.ExitCode -ne 0) { throw ('Selbsttest fehlgeschlagen. Details: '+$report) }
}
Get-Item -LiteralPath $executable | Select-Object FullName,Length
