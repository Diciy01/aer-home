param(
    [Parameter(Mandatory=$true)][string]$LabExe,
    [Parameter(Mandatory=$true)][string]$ShadowExe,
    [Parameter(Mandatory=$true)][string]$TempRoot,
    [Parameter(Mandatory=$true)][switch]$OwnerConsented
)
$ErrorActionPreference='Stop'
if (!$OwnerConsented) { throw 'Obtain explicit owner consent before live desktop acceptance' }
foreach($exe in @($LabExe,$ShadowExe)) {
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Missing acceptance executable' }
}
$run=Join-Path ([IO.Path]::GetFullPath($TempRoot)) ('codex-m144-desktop-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
# Restrict only this freshly-created test-data directory, never OS/user rights.
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
foreach($identity in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl',$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow'))
}
Set-Acl -LiteralPath $run -AclObject $acl
$fixture=Join-Path $PSScriptRoot 'windows-desktop-fixture.ps1'
$arguments='-NoProfile -NonInteractive -WindowStyle Hidden -File "'+$fixture+'" -RunDir "'+$run+'" -LabExe "'+[IO.Path]::GetFullPath($LabExe)+'" -ShadowExe "'+[IO.Path]::GetFullPath($ShadowExe)+'" -OwnerConsented'
$shell=New-Object -ComObject Shell.Application
$desktopHwnd=0
$desktop=$shell.Windows().FindWindowSW(0,0,8,[ref]$desktopHwnd,1)
if ($null -eq $desktop) { throw 'Ordinary Explorer desktop broker unavailable; do not fall back to elevation' }
$desktop.Document.Application.ShellExecute((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'),$arguments,$run,'open',0)
Write-Output $run
