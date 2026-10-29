param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$FreeRdpPrefix,
    # AER Connect Anywhere host half (ADR-018): the native Windows Host bundle
    # (cmake --install of native/aer_shadow) and aer-connect-host.exe.
    [Parameter(Mandatory=$true)][string]$HostBundle,
    [Parameter(Mandatory=$true)][string]$HostExe,
    [string]$BundlePath = (Join-Path $PSScriptRoot '..\..\apps\connect\build\windows\x64\runner\Release'),
    # Optional owner preset: server address and pinned certificate (not secrets).
    [string]$GatewayAddress = '',
    [string]$GatewayFingerprint = ''
)
$ErrorActionPreference = 'Stop'
$required = @('aer_connect.exe','flutter_windows.dll','aer_rdp.dll','freerdp3.dll','freerdp-client3.dll','winpr3.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','data\app.so','data\icudtl.dat')
foreach ($name in $required) {
    if (!(Test-Path -LiteralPath (Join-Path $BundlePath $name))) { throw "Incomplete Release bundle: $name missing" }
}
foreach ($name in @('aer-shadow.exe','freerdp-server3.dll','freerdp-shadow3.dll','winpr-tools3.dll')) {
    if (!(Test-Path -LiteralPath (Join-Path $HostBundle $name))) { throw "Incomplete native Host bundle: $name missing" }
}
if (!(Test-Path -LiteralPath $HostExe)) { throw 'aer-connect-host.exe missing (go build -ldflags=-H=windowsgui ./cmd/aer-connect-host)' }
if (($GatewayAddress -eq '') -ne ($GatewayFingerprint -eq '')) { throw 'GatewayAddress and GatewayFingerprint: both or neither' }
if ($GatewayFingerprint -ne '' -and ($GatewayFingerprint -replace '[:\s-]','') -notmatch '^[0-9a-fA-F]{64}$') { throw 'GatewayFingerprint: SHA-256 of the Gateway certificate' }
$output = [IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath $output) { throw 'OutputDir already exists; use a new directory' }
New-Item -ItemType Directory -Path $output | Out-Null
$app = Join-Path $output 'app'
Copy-Item -LiteralPath $BundlePath -Destination $app -Recurse
# Keep the existing installer entry point and provide the portable product name.
Copy-Item -LiteralPath (Join-Path $app 'aer_connect.exe') -Destination (Join-Path $app 'AER-Connect.exe')
# Host files from an explicit allow-list. Shared runtime DLLs must be the
# very same build as the viewer's; a different one is refused, not mixed.
foreach ($name in @('aer-shadow.exe','freerdp-server3.dll','freerdp-shadow3.dll','winpr-tools3.dll','freerdp3.dll','winpr3.dll',
    'cjson.dll','z.dll','libcrypto-3-x64.dll','libssl-3-x64.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll',
    'msvcp140_1.dll','msvcp140_2.dll','msvcp140_atomic_wait.dll','msvcp140_codecvt_ids.dll','concrt140.dll')) {
    $source = Join-Path $HostBundle $name
    if (!(Test-Path -LiteralPath $source)) { continue }
    $target = Join-Path $app $name
    if (Test-Path -LiteralPath $target) {
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw "Host and viewer ship different $name" }
    } else { Copy-Item -LiteralPath $source -Destination $target }
}
Copy-Item -LiteralPath $HostExe -Destination (Join-Path $app 'aer-connect-host.exe')
if ($GatewayAddress -ne '') {
    @{ gateway = $GatewayAddress; fingerprint = $GatewayFingerprint } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $app 'connect.json') -Encoding UTF8
}
$licenses = Join-Path $app 'licenses'
New-Item -ItemType Directory -Path $licenses | Out-Null
foreach ($package in @('freerdp','openssl','winpr','zlib','cjson')) {
    $copyright = Join-Path $FreeRdpPrefix "share\$package\copyright"
    if (Test-Path -LiteralPath $copyright) {
        Copy-Item -LiteralPath $copyright -Destination (Join-Path $licenses "$package.txt")
    } elseif ($package -ne 'winpr') { throw "Missing third-party license: $package" }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\deploy\connect-windows\install.ps1'),(Join-Path $PSScriptRoot '..\..\deploy\connect-windows\uninstall.ps1') -Destination $output
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\docs\AER_CONNECT_AUTOREGISTRATION.md') -Destination (Join-Path $output 'README.md')
Compress-Archive -LiteralPath $app,(Join-Path $output 'install.ps1'),(Join-Path $output 'uninstall.ps1'),(Join-Path $output 'README.md') -DestinationPath ($output + '.zip')
Write-Output "Package: $output.zip"
