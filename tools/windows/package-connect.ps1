param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$FreeRdpPrefix,
    [string]$BundlePath = (Join-Path $PSScriptRoot '..\..\apps\connect\build\windows\x64\runner\Release')
)
$ErrorActionPreference = 'Stop'
$required = @('aer_connect.exe','flutter_windows.dll','aer_rdp.dll','freerdp3.dll','freerdp-client3.dll','winpr3.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','data\app.so','data\icudtl.dat')
foreach ($name in $required) {
    if (!(Test-Path -LiteralPath (Join-Path $BundlePath $name))) { throw "Incomplete Release bundle: $name missing" }
}
$output = [IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath $output) { throw 'OutputDir already exists; use a new directory' }
New-Item -ItemType Directory -Path $output | Out-Null
Copy-Item -LiteralPath $BundlePath -Destination (Join-Path $output 'app') -Recurse
$licenses = Join-Path $output 'app\licenses'
New-Item -ItemType Directory -Path $licenses | Out-Null
foreach ($package in @('freerdp','openssl','winpr','zlib','cjson')) {
    $copyright = Join-Path $FreeRdpPrefix "share\$package\copyright"
    if (Test-Path -LiteralPath $copyright) {
        Copy-Item -LiteralPath $copyright -Destination (Join-Path $licenses "$package.txt")
    } elseif ($package -ne 'winpr') { throw "Missing third-party license: $package" }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\deploy\connect-windows\install.ps1'),(Join-Path $PSScriptRoot '..\..\deploy\connect-windows\uninstall.ps1') -Destination $output
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\docs\AER_CONNECT.md') -Destination (Join-Path $output 'README.md')
Compress-Archive -LiteralPath (Join-Path $output 'app'),(Join-Path $output 'install.ps1'),(Join-Path $output 'uninstall.ps1'),(Join-Path $output 'README.md') -DestinationPath ($output + '.zip')
Write-Output "Package: $output.zip"
