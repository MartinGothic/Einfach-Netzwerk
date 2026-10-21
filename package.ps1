param([string]$ExecutablePath=(Join-Path $PSScriptRoot 'dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference = 'Stop'
$taskExe = Get-Item -LiteralPath $ExecutablePath -ErrorAction Stop
$taskVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($taskExe.FullName).ProductVersion -replace '\.0$',''
if ($taskVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version.' }
$taskDist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $taskDist -Force | Out-Null
$taskGuide = Join-Path $PSScriptRoot 'docs\ANLEITUNG.md'
foreach ($taskExtension in @('md','txt')) {
    Copy-Item -LiteralPath $taskGuide -Destination (Join-Path $taskDist ('Anleitung.'+$taskExtension)) -Force
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-ProjectArchive {
    param([string]$Destination, [object[]]$Entries)
    $archiveStream = [IO.File]::Open($Destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($archiveStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            foreach ($entry in $Entries) {
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$entry.Source,$entry.Name,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        } finally { $archive.Dispose() }
    } finally { $archiveStream.Dispose() }
}

$taskPackage = Join-Path $taskDist ('Einfach-Netzwerk-'+$taskVersion+'.zip')
Write-ProjectArchive -Destination $taskPackage -Entries @(
    @{Source=$taskExe.FullName;Name=$taskExe.Name},
    @{Source=(Join-Path $taskDist 'Anleitung.txt');Name='Anleitung.txt'}
)

# Preserve the public source folders. Builds, downloads and generated test data
# are not source inputs and are never included in this archive.
$taskSourceFiles = @('.gitignore','README.md','build.ps1','package.ps1') | ForEach-Object { Get-Item -LiteralPath (Join-Path $PSScriptRoot $_) }
$taskSourceFiles += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -File -Recurse | Where-Object { $_.Extension -in @('.cs','.ps1','.manifest','.ico') })
$taskSourceFiles += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'tests') -File -Filter '*.ps1')
$taskSourceFiles += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'docs') -File -Filter '*.md')
$taskSourceFiles += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'tools') -File -Filter '*.py')
$taskSourceEntries = @($taskSourceFiles | Sort-Object FullName -Unique | ForEach-Object {
    @{Source=$_.FullName;Name=$_.FullName.Substring($PSScriptRoot.Length+1).Replace('\','/')}
})
$taskSourcePackage = Join-Path $taskDist ('Einfach-Netzwerk-Quellcode-'+$taskVersion+'.zip')
Write-ProjectArchive -Destination $taskSourcePackage -Entries $taskSourceEntries
Get-Item -LiteralPath $taskPackage,$taskSourcePackage | Select-Object FullName,Length
