param([Parameter(Mandatory=$true)][string]$AppDir,
      [Parameter(Mandatory=$true)][string]$LogDir)
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
$exe=Join-Path $app 'aer_connect.exe'
if(!(Test-Path -LiteralPath $exe)){throw 'AER Connect executable missing'}
if(Test-Path -LiteralPath $LogDir){throw 'Use a new LogDir'}
New-Item -ItemType Directory -Path $LogDir | Out-Null
$start=[Diagnostics.ProcessStartInfo]::new($exe,'--no-profile')
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.WorkingDirectory=[IO.Path]::GetFullPath($LogDir)
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
foreach($key in @($start.EnvironmentVariables.Keys)) {
    if($key -match '^(AER_|VCPKG|FLUTTER|DART|PUB_|CMAKE|VSINSTALLDIR|VCINSTALLDIR|INCLUDE$|LIB$|LIBPATH$)') {
        $start.EnvironmentVariables.Remove($key)
    }
}
$start.EnvironmentVariables['PATH']=Join-Path $env:SystemRoot 'System32'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AerConnectSmokeWindow {
    public delegate bool Callback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint msg,IntPtr wp,IntPtr lp);
    public static IntPtr Find(uint process) {
        IntPtr result=IntPtr.Zero;
        EnumWindows((window,data)=> {uint owner;GetWindowThreadProcessId(window,out owner);
            if(owner==process) {result=window;return false;} return true;},IntPtr.Zero);
        return result;
    }
}
'@
$process=[Diagnostics.Process]::Start($start)
$out=$process.StandardOutput.ReadToEndAsync()
$err=$process.StandardError.ReadToEndAsync()
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    $window=[IntPtr]::Zero
    do {
        if($process.HasExited){throw "Client exited early: $($process.ExitCode)"}
        $window=[AerConnectSmokeWindow]::Find([uint32]$process.Id)
        if($window -ne [IntPtr]::Zero){break}
        Start-Sleep -Milliseconds 200
    } while([DateTime]::UtcNow -lt $deadline)
    if($window -eq [IntPtr]::Zero){throw 'Own application window not found'}
    $required=@('aer_rdp.dll','freerdp-client3.dll','freerdp3.dll','winpr3.dll','libcrypto-3-x64.dll','vcruntime140.dll','msvcp140.dll')
    # A native window exists before Flutter starts its Dart entry point.
    # Wait for the eager viewer load, refreshing .NET's process snapshot.
    do {
        if($process.HasExited){throw 'Client exited before Dart startup'}
        $process.Refresh()
        $modules=@($process.Modules)
        $missing=@($required | Where-Object {$wanted=$_; !($modules | Where-Object {$_.ModuleName -ieq $wanted})})
        if($missing.Count -eq 0){break}
        Start-Sleep -Milliseconds 200
    } while([DateTime]::UtcNow -lt $deadline)
    foreach($name in $required) {
        $module=$modules | Where-Object {$_.ModuleName -ieq $name} | Select-Object -First 1
        if(!$module -or ![IO.Path]::GetFullPath($module.FileName).StartsWith($app+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw "Native dependency not loaded from package: $name (actual: $($module.FileName))"
        }
        Write-Output "PASS package-local module: $name"
    }
    [AerConnectSmokeWindow]::PostMessage($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
    if(!$process.WaitForExit(15000)){throw 'Client failed to close its own window within 15 seconds'}
    if($process.ExitCode -ne 0){throw "Client exit: $($process.ExitCode)"}
    Write-Output 'PASS Release startup, native loader and window close without SDK/vcpkg in PATH; --no-profile used'
} finally {
    if(!$process.HasExited){$process.Kill();$process.WaitForExit()}
    [IO.File]::WriteAllText((Join-Path $LogDir 'stdout.log'),$out.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $LogDir 'stderr.log'),$err.GetAwaiter().GetResult())
    $process.Dispose()
}
