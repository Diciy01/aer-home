param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\AER HOME'),
    [switch]$NoShortcut
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'app'
if (!(Test-Path -LiteralPath (Join-Path $source 'aer_home_desktop.exe'))) { throw 'Incomplete package: app executable missing' }
$target = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if (Test-Path -LiteralPath $target) { throw 'InstallDir already exists. Choose a new directory; existing files are never overwritten.' }
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AER HOME.lnk'
if (!$NoShortcut -and (Test-Path -LiteralPath $shortcutPath)) { throw 'AER HOME shortcut already exists. It was not overwritten.' }
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $target 'app') -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination $target
$manifest = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
    @{ path = $_.FullName.Substring($target.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
if (!$NoShortcut) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $target 'app\aer_home_desktop.exe'
    $shortcut.WorkingDirectory = Join-Path $target 'app'
    $shortcut.Save()
    $shortcutHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash
} else { $shortcutPath = $null; $shortcutHash = $null }
@{ files = $manifest; shortcut = $shortcutPath; shortcutHash = $shortcutHash } | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $target 'installed-files.json') -Encoding UTF8
Write-Output "Installed AER HOME in $target. Core runs separately; no services or autostart were installed."
