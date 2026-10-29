param(
    [Parameter(Mandatory=$true)][string]$RunDir,
    [Parameter(Mandatory=$true)][string]$LabExe,
    [Parameter(Mandatory=$true)][string]$ShadowExe,
    [Parameter(Mandatory=$true)][switch]$OwnerConsented
)
# EXPLICIT live acceptance only. Launch through the ordinary Explorer broker.
# No capture in this script: the production Host still asks for local consent.
$ErrorActionPreference='Stop'
if (!$OwnerConsented) { throw 'Explicit owner consent is required' }
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class AerAcceptanceTarget : Form {
    public int Clicks, Keys, Chars, LastKey;
    public AerAcceptanceTarget() {
        Text="AER M14.4 - SAFE INPUT TARGET (TEST ONLY)";
        ClientSize=new Size(620,420); StartPosition=FormStartPosition.Manual;
        FormBorderStyle=FormBorderStyle.FixedSingle; MaximizeBox=false; MinimizeBox=false;
        var screen=Screen.PrimaryScreen.WorkingArea;
        Location=new Point(Math.Max(0,screen.Right-Width-24),Math.Max(0,screen.Bottom-Height-24));
        TopMost=true; KeyPreview=true; BackColor=Color.FromArgb(244,239,231);
        DoubleBuffered=true;
    }
    public void KeepInsidePrimary() {
        var area=Screen.PrimaryScreen.WorkingArea;
        var expected=new Point(Math.Max(area.Left,area.Right-Width-24),Math.Max(area.Top,area.Bottom-Height-24));
        if(Location!=expected) Location=expected;
    }
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        using(var a=new SolidBrush(Color.FromArgb(32,145,210))) e.Graphics.FillRectangle(a,20,20,80,80);
        using(var b=new SolidBrush(Color.FromArgb(221,68,92))) e.Graphics.FillRectangle(b,120,20,80,80);
        e.Graphics.DrawString("AER TEST ONLY - remote input stays inside this window\n\n"+
          "Clicks: "+Clicks+"    Keys: "+Keys+"    Characters: "+Chars+"\n\n"+
          "Close this window to end the acceptance stand.",Font,Brushes.Black,20,130);
    }
    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e); if(e.Button==MouseButtons.Left) { Clicks++; Focus(); Invalidate(); }
    }
    protected override void OnKeyDown(KeyEventArgs e) {
        Keys++; LastKey=(int)e.KeyCode; Invalidate(); base.OnKeyDown(e);
    }
    protected override void OnKeyPress(KeyPressEventArgs e) {
        Chars++; Invalidate(); base.OnKeyPress(e);
    }
    public delegate bool EnumCallback(IntPtr w,IntPtr p);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr w,uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr w);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback,IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr w,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr w,System.Text.StringBuilder name,int max);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr w,int id);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr w);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr w);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr w,uint msg,IntPtr wp,IntPtr lp);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll")] public static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll")] public static extern bool GetTokenInformation(IntPtr token,int info,out int value,int length,out int returned);
    public static bool Elevated(int pid) {
        IntPtr p=OpenProcess(0x1000,false,pid),t=IntPtr.Zero;
        if(p==IntPtr.Zero && Marshal.GetLastWin32Error()==87) return false; // Child already exited.
        try { int value,n; if(p==IntPtr.Zero || !OpenProcessToken(p,8,out t) ||
          !GetTokenInformation(t,20,out value,4,out n)) throw new Exception("Cannot inspect process token");
          return value!=0;
        } finally { if(t!=IntPtr.Zero) CloseHandle(t); if(p!=IntPtr.Zero) CloseHandle(p); }
    }
    public static IntPtr FindOwnedStop(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows(delegate(IntPtr w,IntPtr p) {
            uint owner; GetWindowThreadProcessId(w,out owner);
            var name=new System.Text.StringBuilder(128); GetClassName(w,name,128);
            if(owner==(uint)pid && name.ToString()=="AerRemoteConsent" && IsWindowVisible(w)) {
                var button=GetDlgItem(w,1);
                if(button!=IntPtr.Zero && IsWindowVisible(button) && IsWindowEnabled(button)) found=button;
            } return true;
        },IntPtr.Zero);
        return found;
    }
    public static bool PressOwnedStop(int pid) {
        var button=FindOwnedStop(pid); if(button==IntPtr.Zero) return false;
        SendMessage(button,0xF5,IntPtr.Zero,IntPtr.Zero); return true;
    }
}
'@
$run=[IO.Path]::GetFullPath($RunDir)
if (!(Test-Path -LiteralPath $run -PathType Container)) { throw 'Use an existing private test directory' }
$utf8=[Text.UTF8Encoding]::new($false)
$script:snapshot=0
function Write-Json($name,$value) {
    # Publish immutable snapshots, avoiding Windows share/delete races with Dart.
    if ($name -eq 'target.json') {
        $script:snapshot++
        $name='target-'+$script:snapshot.ToString('D8')+'.json'
    }
    $path=Join-Path $run $name
    [IO.File]::WriteAllText($path+'.tmp',($value | ConvertTo-Json -Depth 8 -Compress),$utf8)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($path+'.tmp',$path,[NullString]::Value) }
    else { [IO.File]::Move($path+'.tmp',$path) }
}
if ([AerAcceptanceTarget]::Elevated($PID)) {
    Write-Json 'fixture-error.json' @{error='Refusing elevated fixture/Host';pid=$PID}
    exit 3
}
[AerAcceptanceTarget]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$env:TEMP=$run
$env:TMP=$run
$env:AER_DESKTOP_ACCEPTANCE='1'
$start=[Diagnostics.ProcessStartInfo]::new($LabExe,('-shadow "'+$ShadowExe+'" -desktop-acceptance -no-clipboard -no-files'))
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardInput=$true
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.WorkingDirectory=$run
$lab=[Diagnostics.Process]::Start($start)
$line=$lab.StandardOutput.ReadLineAsync()
$errors=$lab.StandardError.ReadToEndAsync()
$script:infoWritten=$false
$script:networkWritten=$false
$script:lastCommand=0
$script:stopPressed=$false
$script:children=@()
$form=[AerAcceptanceTarget]::new()
$timer=[Windows.Forms.Timer]::new()
$timer.Interval=200
$until=[DateTime]::UtcNow.AddMinutes(12)
function Stop-OwnedLab {
    if (!$lab.HasExited) {
        $lab.StandardInput.Close()
        if (!$lab.WaitForExit(10000)) { $lab.Kill(); $lab.WaitForExit(5000) | Out-Null }
    }
    # Only still-owned children of this exact stand, never a global name kill.
    foreach($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($lab.Id)")) {
        if ($child.ExecutablePath -eq $ShadowExe) { Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue }
    }
}
$timer.Add_Tick({
    try {
        if ([DateTime]::UtcNow -gt $until) { throw 'Acceptance deadline reached' }
        if (!$script:infoWritten -and $line.IsCompleted) {
            $info=$line.Result | ConvertFrom-Json
            if ($null -eq $info -or $info.hostMode -ne 'desktop') { throw 'Real desktop stand did not become ready' }
            Write-Json 'lab.json' $info
            $script:infoWritten=$true
        }
        if ($lab.HasExited) { throw 'Stand exited; closing safe target' }
        $form.KeepInsidePrimary()
        $script:children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($lab.Id)" | Where-Object { $_.ExecutablePath -eq $ShadowExe -and $_.CommandLine -notmatch '--probe' })
        $levels=@($script:children | ForEach-Object { @{pid=[int]$_.ProcessId;elevated=[AerAcceptanceTarget]::Elevated([int]$_.ProcessId);stopVisible=([AerAcceptanceTarget]::FindOwnedStop([int]$_.ProcessId) -ne [IntPtr]::Zero)} })
        if (@($levels | Where-Object { $_.elevated }).Count -gt 0 -or [AerAcceptanceTarget]::Elevated($lab.Id)) { throw 'Elevated test child detected' }
        if (!$script:networkWritten -and @($levels | Where-Object { $_.stopVisible }).Count -gt 0) {
            $ownedPids=@($lab.Id)+@($levels | ForEach-Object { $_.pid })
            $listeners=@(Get-NetTCPConnection -State Listen | Where-Object { $_.OwningProcess -in $ownedPids } | ForEach-Object {
                @{address=$_.LocalAddress;port=$_.LocalPort;pid=$_.OwningProcess}
            })
            if (@($listeners | Where-Object { $_.address -ne '127.0.0.1' }).Count -gt 0) { throw 'Owned listener is not strict IPv4 loopback' }
            Write-Json 'network.json' @{listeners=$listeners}
            $script:networkWritten=$true
        }
        $commandFile=Get-ChildItem -LiteralPath $run -Filter 'command-*.json' | Sort-Object Name | Select-Object -Last 1
        if ($null -ne $commandFile) {
            $command=[IO.File]::ReadAllText($commandFile.FullName) | ConvertFrom-Json
            if ($command.id -ne $script:lastCommand) {
                $script:lastCommand=$command.id
                switch($command.action) {
                    'focus' { $form.Activate(); [AerAcceptanceTarget]::SetForegroundWindow($form.Handle) | Out-Null }
                    'stop-host' {
                        foreach($child in $script:children) {
                            if ([AerAcceptanceTarget]::PressOwnedStop([int]$child.ProcessId)) { $script:stopPressed=$true }
                        }
                        if (!$script:stopPressed) { throw 'Owned visible Stop button not found' }
                    }
                    'close' { $form.Close(); return }
                    default { throw 'Unknown fixture command' }
                }
            }
        }
        $point=$form.PointToScreen([Drawing.Point]::new(300,250))
        $a=$form.PointToScreen([Drawing.Point]::new(50,50))
        $b=$form.PointToScreen([Drawing.Point]::new(150,50))
        Write-Json 'target.json' @{
            pid=$PID;labPid=$lab.Id;elevated=$false;hostProcesses=$levels;utcMs=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();
            x=$point.X;y=$point.Y;markerA=@($a.X,$a.Y);markerB=@($b.X,$b.Y);
            width=[Windows.Forms.Screen]::PrimaryScreen.Bounds.Width;height=[Windows.Forms.Screen]::PrimaryScreen.Bounds.Height;
            clear=([AerAcceptanceTarget]::GetAncestor([AerAcceptanceTarget]::WindowFromPoint($point),2) -eq $form.Handle);
            foreground=([AerAcceptanceTarget]::GetForegroundWindow() -eq $form.Handle);
            clicks=$form.Clicks;keys=$form.Keys;chars=$form.Chars;lastKey=$form.LastKey;stopPressed=$script:stopPressed
        }
    } catch {
        Write-Json 'fixture-error.json' @{error=$_.Exception.Message;pid=$PID}
        $form.Close()
    }
})
$form.Add_FormClosed({
    $timer.Stop()
    Stop-OwnedLab
    Write-Json 'closed.json' @{pid=$PID;labPid=$lab.Id;labExited=$lab.HasExited;exitCode=$lab.ExitCode;stopPressed=$script:stopPressed}
})
try { $timer.Start(); [Windows.Forms.Application]::Run($form) }
finally { $timer.Dispose(); $form.Dispose(); Stop-OwnedLab; $lab.Dispose() }
