param([Parameter(Mandatory=$true)][string]$OutputDir,
      [Parameter(Mandatory=$true)][string]$NativeBundle,
      [Parameter(Mandatory=$true)][string]$AgentExe,
      [Parameter(Mandatory=$true)][string]$FreeRdpPrefix)
$ErrorActionPreference='Stop'
foreach($file in @('aer-shadow.exe','freerdp-server3.dll','freerdp-shadow3.dll','freerdp3.dll','winpr3.dll','cjson.dll','libcrypto-3-x64.dll','libssl-3-x64.dll','vcruntime140.dll','msvcp140.dll')) {
    if(!(Test-Path -LiteralPath (Join-Path $NativeBundle $file))){throw "Incomplete native Host package: $file"}
}
if(!(Test-Path -LiteralPath $AgentExe)){throw 'Built remote host agent missing'}
if(Test-Path -LiteralPath $OutputDir){throw 'Use a new OutputDir'}
New-Item -ItemType Directory -Path $OutputDir | Out-Null
# Explicit allow-list: native test binaries/viewer extras never enter the Host ZIP.
foreach($file in @('aer-shadow.exe','freerdp-server3.dll','freerdp-shadow3.dll','freerdp3.dll','winpr3.dll','winpr-tools3.dll',
 'cjson.dll','z.dll','libcrypto-3-x64.dll','libssl-3-x64.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll',
 'msvcp140_1.dll','msvcp140_2.dll','msvcp140_atomic_wait.dll','msvcp140_codecvt_ids.dll','concrt140.dll')) {
    $source=Join-Path $NativeBundle $file
    if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination $OutputDir}
}
Copy-Item -LiteralPath $AgentExe -Destination (Join-Path $OutputDir 'aer-remote-host.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\deploy\remote-host.windows-shadow.example.json') -Destination $OutputDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\docs\WINDOWS_HOST.md') -Destination (Join-Path $OutputDir 'README.md')
$licenses=Join-Path $OutputDir 'licenses';New-Item -ItemType Directory -Path $licenses | Out-Null
foreach($name in @('freerdp','openssl','cjson','zlib')) {
    $source=Join-Path $FreeRdpPrefix "share\$name\copyright"
    if(!(Test-Path -LiteralPath $source)){throw "Missing license: $name"}
    Copy-Item -LiteralPath $source -Destination (Join-Path $licenses "$name.txt")
}
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath ($OutputDir+'.zip')
Write-Output "Host package: $OutputDir.zip. No service, driver, firewall or Windows RDP configuration is installed."
