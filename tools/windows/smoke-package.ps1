param(
    [Parameter(Mandatory=$true)][string]$AppDir,
    [Parameter(Mandatory=$true)][string]$CoreUrl,
    [Parameter(Mandatory=$true)][string]$CoreTokenFile,
    [Parameter(Mandatory=$true)][string]$DataDir
)
$ErrorActionPreference = 'Stop'
$uri = [uri]$CoreUrl
if ($uri.Host -ne '127.0.0.1' -or $uri.Port -eq 8787) { throw 'Use an isolated loopback Core, not 8787' }
if (Test-Path -LiteralPath $DataDir) { throw 'Use a new test profile directory' }
$app = [IO.Path]::GetFullPath($AppDir).TrimEnd('\')
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class AerM10Window {
    private delegate bool Callback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Callback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder title, int size);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    public static IntPtr Find(int pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            if (owner != pid) return true;
            var title = new StringBuilder(256); GetWindowText(hwnd, title, title.Capacity);
            if (title.ToString() != "AER HOME") return true;
            found = hwnd; return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$env:PATH = Join-Path $env:SystemRoot 'System32'
Remove-Item Env:AER_RDP_LIB,Env:AER_FREERDP_PREFIX,Env:VCPKG_ROOT -ErrorAction SilentlyContinue
$env:AER_CORE_URL = $CoreUrl
$env:AER_CORE_TOKEN_FILE = $CoreTokenFile
$env:AER_DESKTOP_DATA_DIR = $DataDir
$env:AER_REMOTE_SECRET_STORE = 'file'
$process = Start-Process -FilePath (Join-Path $app 'aer_home_desktop.exe') -WorkingDirectory $app -WindowStyle Hidden -PassThru
$window = [IntPtr]::Zero
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) { throw "Packaged app exited: $($process.ExitCode)" }
        $window = [AerM10Window]::Find($process.Id)
        $cachePath = Join-Path $DataDir 'monitoring-cache.json'
    } while (($window -eq [IntPtr]::Zero -or !(Test-Path -LiteralPath $cachePath)) -and [DateTime]::UtcNow -lt $deadline)
    if ($window -eq [IntPtr]::Zero) { throw 'No owned AER HOME window (hidden windows are included)' }
    if (!(Test-Path -LiteralPath $cachePath)) { throw 'No authenticated Core snapshot' }
    $modules = @($process.Modules)
    foreach ($name in @('aer_rdp.dll','freerdp3.dll','freerdp-client3.dll','winpr3.dll','libcrypto-3-x64.dll','vcruntime140.dll','msvcp140.dll')) {
        $module = $modules | Where-Object ModuleName -eq $name
        if (!$module -or !$module.FileName.StartsWith($app + '\',[StringComparison]::OrdinalIgnoreCase)) { throw "Dependency not package-local: $name" }
        Write-Output "$name : package-local"
    }
    Write-Output 'PASS: hidden Release window, authenticated Core snapshot, PATH=System32, SDK/vcpkg overrides absent'
} finally {
    $process.Refresh()
    if (!$process.HasExited) {
        if ($window -ne [IntPtr]::Zero) { $null = [AerM10Window]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        if (!$process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit(); throw 'Owned package process did not close after WM_CLOSE' }
    }
}
