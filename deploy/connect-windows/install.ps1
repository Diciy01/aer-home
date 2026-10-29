param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\AER Connect'),
    [switch]$NoShortcut,
    # Replace an earlier installation in InstallDir. Only its own unchanged
    # files are replaced; anything added or modified there stops the upgrade.
    [switch]$Upgrade
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'app'
if (!(Test-Path -LiteralPath (Join-Path $source 'aer_connect.exe'))) { throw 'Incomplete package: app executable missing' }
$target = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AER Connect.lnk'
$keepShortcut = $false
if ($Upgrade) {
    $manifestPath = Join-Path $target 'installed-files.json'
    if (!(Test-Path -LiteralPath $manifestPath)) { throw 'No earlier AER Connect installation in InstallDir (installed-files.json missing)' }
    $running = Get-Process -Name 'aer_connect','aer-connect-host','aer-shadow' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) }
    if ($running) { throw 'Close AER Connect before upgrading' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $known = @{}
    foreach ($entry in $manifest.files) {
        $path = [IO.Path]::GetFullPath((Join-Path $target $entry.path))
        if (!$path.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package manifest path' }
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Installed file was changed or removed: $($entry.path). Upgrade stopped; nothing was replaced."
        }
        $known[$path.ToLowerInvariant()] = $true
    }
    $extra = @(Get-ChildItem -LiteralPath $target -Recurse -File | Where-Object {
        $_.FullName -ne $manifestPath -and !$known.ContainsKey($_.FullName.ToLowerInvariant()) })
    if ($extra.Count -gt 0) { throw "Files not from the package are in InstallDir (e.g. $($extra[0].FullName)). Upgrade stopped; nothing was replaced." }
    foreach ($path in $known.Keys) { Remove-Item -LiteralPath $path }
    # Only directories left empty by the removal above.
    Get-ChildItem -LiteralPath $target -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0 } | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $manifestPath
    $keepShortcut = $manifest.shortcut -eq $shortcutPath -and (Test-Path -LiteralPath $shortcutPath) -and
        (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash -eq $manifest.shortcutHash
    if ($keepShortcut) { Remove-Item -LiteralPath $shortcutPath }
} elseif (Test-Path -LiteralPath $target) {
    throw 'InstallDir already exists. Choose a new directory or use -Upgrade; existing files are never overwritten.'
}
if (!$NoShortcut -and (Test-Path -LiteralPath $shortcutPath)) { throw 'AER Connect shortcut already exists. It was not overwritten.' }
if (!(Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target | Out-Null }
Copy-Item -LiteralPath $source -Destination (Join-Path $target 'app') -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination $target
$manifest = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
    @{ path = $_.FullName.Substring($target.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
if (!$NoShortcut) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $target 'app\aer_connect.exe'
    $shortcut.WorkingDirectory = Join-Path $target 'app'
    $shortcut.Save()
    $shortcutHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash
} else { $shortcutPath = $null; $shortcutHash = $null }
@{ files = $manifest; shortcut = $shortcutPath; shortcutHash = $shortcutHash } | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $target 'installed-files.json') -Encoding UTF8
Write-Output "Installed AER Connect in $target. No services, firewall rules or autostart were installed; the device registration (if any) stays in the user's protected profile."
