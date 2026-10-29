$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$manifestPath = Join-Path $root 'installed-files.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
# Remove only unchanged package files. User data is outside the installation;
# even files added here by the owner are retained. No recursive deletion.
foreach ($entry in $manifest.files) {
    $path = [IO.Path]::GetFullPath((Join-Path $root $entry.path))
    if (!$path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package manifest path' }
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $entry.sha256) {
        Remove-Item -LiteralPath $path
    }
}
$expectedShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'AER Connect.lnk'
if ($manifest.shortcut -eq $expectedShortcut -and (Test-Path -LiteralPath $expectedShortcut) -and
    (Get-FileHash -LiteralPath $expectedShortcut -Algorithm SHA256).Hash -eq $manifest.shortcutHash) {
    Remove-Item -LiteralPath $expectedShortcut
}
# "Start with Windows" is the user's own setting; remove it only
# when it points at this installation.
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$run = (Get-ItemProperty -LiteralPath $runKey -Name 'AER Connect' -ErrorAction SilentlyContinue).'AER Connect'
if ($run -and $run.Trim('"') -ieq (Join-Path $root 'app\aer_connect.exe')) {
    Remove-ItemProperty -LiteralPath $runKey -Name 'AER Connect'
}
Remove-Item -LiteralPath $manifestPath
Write-Output 'Removed unchanged application files. Core, credentials, the device registration, caches and added/modified files were retained.'
