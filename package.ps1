param([string]$ExecutablePath=(Join-Path $PSScriptRoot 'dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference='Stop'
$taskExe=Get-Item -LiteralPath $ExecutablePath
$taskVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($taskExe.FullName).ProductVersion -replace '\.0$',''
if($taskVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid package version.'}
$taskDist=Join-Path $PSScriptRoot 'dist'
foreach($taskExtension in @('md','txt')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $taskDist ('Anleitung.'+$taskExtension)) -Force
}
$taskPackage=Join-Path $taskDist ('Einfach-Netzwerk-'+$taskVersion+'.zip')
Compress-Archive -LiteralPath @($taskExe.FullName,(Join-Path $taskDist 'Anleitung.txt')) -DestinationPath $taskPackage -CompressionLevel Optimal -Force
$taskSource=@(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {$_.Extension -in @('.cs','.ps1','.md','.manifest','.ico','.py')} | ForEach-Object {$_.FullName})
$taskSourcePackage=Join-Path $taskDist ('Einfach-Netzwerk-Quellcode-'+$taskVersion+'.zip')
Compress-Archive -LiteralPath $taskSource -DestinationPath $taskSourcePackage -CompressionLevel Optimal -Force
Get-Item -LiteralPath $taskPackage,$taskSourcePackage | Select-Object FullName,Length
