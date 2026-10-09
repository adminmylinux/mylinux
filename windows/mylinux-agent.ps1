# myLinux: what runs in a Windows machine's session, from sign-in to sign-out (setup.ps1 starts it at every sign-in,
# hidden). Two things, both between Windows and the Mac window it lives in. Windows PowerShell 5.1, nothing to install.
#
# The display follows the window. It starts at the size run-windows.sh chose for the window; from then on the virtio
# display driver (viogpudo) learns the size the Mac window wants at every change and signals an event, and this
# asks the driver for that size and switches Windows to it, as the driver's own helper
# (viogpuap, from the virtio-win project, whose steps these are) does. That helper is not used here: it stops looking
# at the first display adapter that is not the virtio one, and a Windows installed on the firmware's framebuffer keeps
# "Microsoft Basic Display Driver" in first place.
#
# The clipboard is shared. Text and pictures copied on the Mac can be pasted in Windows and the other way round. It
# speaks what Omarchy's own agent speaks (tools/omarchy-clipboard.py and the launcher's --omarchy-clipboard are the Mac
# side): one JSON object a line over the virtio serial port dev.tryomarchy.clipboard,
#     {"type": "clipboard", "format": "text/plain;charset=utf-8" | "image/png", "data": "<base64>"}
# and {"type": "sync"} to ask for the Mac's clipboard when it starts. What it was just given is not sent back (the
# same fingerprint within two seconds). It waits for the port, and opens it again when it went away.
param([string]$Port = '\\.\Global\dev.tryomarchy.clipboard', [switch]$Once)

# Windows's first-run screens run as an account of their own (defaultuser0): nothing here is for it
if ($env:USERNAME -match '^defaultuser\d+$') { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$data = Join-Path $env:LOCALAPPDATA 'myLinux'
New-Item -ItemType Directory -Force $data | Out-Null
$log = Join-Path $data 'agent.log'
Set-Content -Path $log -Value ("{0} agent started" -f (Get-Date -Format s))

# What this start of the machine asks for: run-windows.sh's words in the machine's SMBIOS (OEM strings), mylinux.res=WxH
# (the window's size in pixels), mylinux.scale (pixels to a point of the Mac window: 2 on a Retina display, where
# Windows's scaling becomes 200%) and mylinux.run (a new word at every start). Windows's boot loader picks a screen mode of
# its own and the window takes that one, so the size is set here, once for each start of the machine; after that the
# window's own changes are followed.
$oem = @{}
try { foreach ($word in (Get-CimInstance Win32_ComputerSystem).OEMStringArray) { if ($word -match '^mylinux\.(\w+)=(.+)$') { $oem[$Matches[1]] = $Matches[2] } } } catch { }

# The start of the machine in which Windows was installed still has the installer's hardware (the firmware's 1024x768
# framebuffer): said once, with what to do about it, in front of whatever is open (a box of a hidden program opens
# behind the others otherwise), and before the slower parts below.
if (-not $oem.res -and -not (Test-Path (Join-Path $data 'told'))) {
    Set-Content -Path (Join-Path $data 'told') -Value (Get-Date -Format s)
    $note = [PowerShell]::Create().AddScript({
        Add-Type -AssemblyName System.Windows.Forms
        $front = New-Object Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
        [Windows.Forms.MessageBox]::Show($front, "Windows is installed.`n`nRestart the machine: Machine > Restart in the Mac's menu bar, or shut Windows down and start it again from myLinux Launcher. From then on its display fills the Mac window and follows its size.`n`n(Restart in Windows's own Start menu is not enough.)", 'myLinux', 'OK', 'Information') | Out-Null
        $front.Dispose()
    })
    $null = $note.BeginInvoke()             # beside everything below, which does not wait for the answer
}

# ---- the display follows the window: on a thread of its own ---------------------------------------------------------
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using System.Security.AccessControl; using System.Threading;
namespace MyLinux {
public static class Display {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DISPLAY_DEVICE { public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
    [StructLayout(LayoutKind.Sequential)] struct OPENADAPTER { public IntPtr hDc; public uint hAdapter; public uint LuidLow; public int LuidHigh; public uint VidPnSourceId; }
    [StructLayout(LayoutKind.Sequential)] struct ESCAPE { public uint hAdapter, hDevice; public int Type; public uint Flags; public IntPtr pPrivateDriverData; public uint PrivateDriverDataSize, hContext; }
    [StructLayout(LayoutKind.Sequential)] struct CLOSEADAPTER { public uint hAdapter; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE d, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE m);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE m, IntPtr hwnd, uint flags, IntPtr param);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateDC(string driver, string device, IntPtr output, IntPtr init);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromHdc(ref OPENADAPTER a);
    [DllImport("gdi32.dll")] static extern int D3DKMTEscape(ref ESCAPE e);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CLOSEADAPTER c);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, IntPtr pathArray, ref uint modes, IntPtr modeArray, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr packet);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(IntPtr packet);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [StructLayout(LayoutKind.Sequential)] struct MEMORYSTATUSEX { public uint dwLength, dwMemoryLoad; public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

    static string logFile;
    static int startWidth, startHeight, startScale;

    // Windows's scaling ("Scale" in Settings > Display) as a percentage: 200 where one point of the Mac window is two
    // pixels. Windows counts it in steps from the one it recommends; the display's own question (what Settings asks)
    // tells how many steps below that 100% is.
    static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
    static void Scale(int percent) {
        uint np, nm;
        if (Array.IndexOf(Steps, percent) < 0 || GetDisplayConfigBufferSizes(2, out np, out nm) != 0 || np == 0) return;
        IntPtr paths = Marshal.AllocHGlobal((int)np * 72), modes = Marshal.AllocHGlobal((int)Math.Max(nm, 1) * 64), packet = Marshal.AllocHGlobal(32);
        try {
            if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0 || np == 0) return;     // the active displays: the one there is
            long adapter = Marshal.ReadInt64(paths, 0); int source = Marshal.ReadInt32(paths, 8);
            Marshal.WriteInt32(packet, 0, -3); Marshal.WriteInt32(packet, 4, 32); Marshal.WriteInt64(packet, 8, adapter); Marshal.WriteInt32(packet, 16, source);
            Marshal.WriteInt32(packet, 20, 0); Marshal.WriteInt32(packet, 24, 0); Marshal.WriteInt32(packet, 28, 0);
            if (DisplayConfigGetDeviceInfo(packet) != 0) return;
            int min = Marshal.ReadInt32(packet, 20), now = Marshal.ReadInt32(packet, 24), max = Marshal.ReadInt32(packet, 28);
            int want = Math.Min(Array.IndexOf(Steps, percent) + min, max);
            if (want == now) return;
            Marshal.WriteInt32(packet, 0, -4); Marshal.WriteInt32(packet, 4, 24); Marshal.WriteInt32(packet, 20, want);
            int r = DisplayConfigSetDeviceInfo(packet);
            Log("scale " + Steps[Math.Max(0, Math.Min(Steps.Length - 1, want - min))] + "%" + (r == 0 ? "" : " refused (" + r + ")"));
        } finally { Marshal.FreeHGlobal(paths); Marshal.FreeHGlobal(modes); Marshal.FreeHGlobal(packet); }
    }
    static void Log(string text) { try { File.AppendAllText(logFile, DateTime.Now.ToString("s") + " display: " + text + "\r\n"); } catch { } }

    // What the Mac says about the display the window is on now (the launcher's helper, over the virtio port
    // dev.mylinux.host): "scale=1" or "scale=2", that display's pixels to a point ("ping" while it cannot tell). Dragged from a Retina display to
    // another kind or back, the window keeps its size and Windows gets half or twice the pixels (followed below, as
    // every size is): its scaling goes with them, and what is on the screen stays as large as it was.
    // Windows keeps its scaling as steps from the one it recommends, and what it recommends goes with the number of
    // pixels: the scaling is set at the Mac's word and once more when the new size has come (either may be first).
    static readonly object scaling = new object();
    static int hostScale;                                               // the Mac's last word as a percentage, 0 before any
    static DateTime hostScaleAt = DateTime.MinValue;
    static void Host() {
        while (true) {
            try {
                // (GENERIC_READ | GENERIC_WRITE, OPEN_EXISTING, FILE_FLAG_OVERLAPPED: as the clipboard's port is opened;
                // a stream with no buffer of its own, read and written in turn by this one thread)
                using (var port = CreateFile("\\\\.\\Global\\dev.mylinux.host", 0xC0000000, 0, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero)) {
                    if (!port.IsInvalid) {
                        using (var stream = new FileStream(port, FileAccess.ReadWrite, 1, true))
                        using (var reader = new StreamReader(stream)) {
                            string line;
                            while ((line = reader.ReadLine()) != null) {
                                // every word from the Mac (one every three seconds) is answered with what Windows's
                                // memory is at, as Task Manager counts it: the launcher shows that beside the machine
                                MEMORYSTATUSEX m = new MEMORYSTATUSEX(); m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
                                if (GlobalMemoryStatusEx(ref m) && m.ullTotalPhys > 0) {
                                    byte[] answer = System.Text.Encoding.ASCII.GetBytes("memory=" + (m.ullTotalPhys - m.ullAvailPhys) + "/" + m.ullTotalPhys + "\n");
                                    stream.Write(answer, 0, answer.Length); stream.Flush();
                                }
                                if (line != "scale=1" && line != "scale=2") continue;
                                int percent = line == "scale=2" ? 200 : 100;
                                lock (scaling) {
                                    if (percent != hostScale) { hostScale = percent; hostScaleAt = DateTime.Now; Scale(percent); }
                                }
                            }
                        }
                    }
                }
            } catch (Exception) { }
            Thread.Sleep(5000);                                          // no such port (a start without the helper), or it went away
        }
    }

    // the virtio display among Windows's adapters, wherever in the list it is: its device name (\\.\DISPLAYn)
    static string Find() {
        for (uint i = 0; i < 16; i++) {
            DISPLAY_DEVICE d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref d, 0)) continue;
            if ((d.StateFlags & 1) != 0 && d.DeviceID != null && d.DeviceID.StartsWith("PCI\\VEN_1AF4&DEV_1050", StringComparison.OrdinalIgnoreCase)) return d.DeviceName;
        }
        return null;
    }
    // the driver's private questions (viogpum.h in the virtio-win sources): 0 its number, 1 the size the host wants,
    // 2 a size of our choosing as that size (width in the low half, height in the high)
    static bool Ask(uint adapter, ushort type, uint value, out uint answer) {
        answer = 0;
        IntPtr data = Marshal.AllocHGlobal(8);
        try {
            Marshal.WriteInt64(data, 0); Marshal.WriteInt16(data, 0, (short)type); Marshal.WriteInt16(data, 2, 4); Marshal.WriteInt32(data, 4, (int)value);
            ESCAPE e = new ESCAPE(); e.hAdapter = adapter; e.pPrivateDriverData = data; e.PrivateDriverDataSize = 8;
            if (D3DKMTEscape(ref e) < 0) return false;
            answer = (uint)Marshal.ReadInt32(data, 4);
            return true;
        } finally { Marshal.FreeHGlobal(data); }
    }
    static void Sync(string device, uint adapter) {
        uint wanted;
        if (!Ask(adapter, 1, 0, out wanted)) return;
        int w = (int)(wanted & 0xffff), h = (int)(wanted >> 16);
        if (w < 640 || h < 480) return;
        DEVMODE now = new DEVMODE(); now.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettings(device, -1, ref now) && now.dmPelsWidth == w && now.dmPelsHeight == h) return;
        DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        m.dmPelsWidth = w; m.dmPelsHeight = h; m.dmFields = 0x80000 | 0x100000;       // DM_PELSWIDTH | DM_PELSHEIGHT
        int r = ChangeDisplaySettingsEx(device, ref m, IntPtr.Zero, 1, IntPtr.Zero);  // CDS_UPDATEREGISTRY
        Log(w + "x" + h + (r == 0 ? "" : " refused (" + r + ")"));
    }
    static void Run() {
        while (true) {
            IntPtr dc = IntPtr.Zero; uint adapter = 0;
            try {
                string device = Find();
                if (device == null) { Thread.Sleep(5000); continue; }     // no virtio display (Windows on the firmware's framebuffer)
                dc = CreateDC(null, device, IntPtr.Zero, IntPtr.Zero);
                OPENADAPTER open = new OPENADAPTER(); open.hDc = dc;
                if (dc == IntPtr.Zero || D3DKMTOpenAdapterFromHdc(ref open) < 0) throw new Exception("the adapter of " + device + " did not open");
                adapter = open.hAdapter;
                uint number;
                if (!Ask(adapter, 0, 0, out number)) throw new Exception("the driver did not answer");
                using (EventWaitHandle changed = EventWaitHandle.OpenExisting("Global\\VioGpuResolutionEvent" + number, EventWaitHandleRights.Synchronize)) {
                    Log("following the window on " + device);
                    bool first = startWidth > 0;
                    if (first) {                                         // once: the size this start of the machine asked for
                        uint ignored; Ask(adapter, 2, (uint)(startWidth | (startHeight << 16)), out ignored); startWidth = 0;
                    }
                    Sync(device, adapter);
                    if (first && startScale > 0) { Thread.Sleep(1500); lock (scaling) { Scale(startScale * 100); } }    // and its scaling, once the size is there
                    while (true) {
                        changed.WaitOne();
                        Thread.Sleep(150);                               // a drag sends many sizes: the last one counts
                        Sync(device, adapter);
                        lock (scaling) { if (hostScale > 0 && (DateTime.Now - hostScaleAt).TotalSeconds < 15) Scale(hostScale); }
                        if (Find() != device) break;                     // the display was taken away or changed
                    }
                }
            } catch (Exception e) { Log(e.Message); Thread.Sleep(3000); }
            finally {
                if (adapter != 0) { CLOSEADAPTER c = new CLOSEADAPTER(); c.hAdapter = adapter; D3DKMTCloseAdapter(ref c); }
                if (dc != IntPtr.Zero) DeleteDC(dc);
            }
        }
    }
    public static void Start(string log, int width, int height, int scale) {
        logFile = log; startWidth = width; startHeight = height; startScale = scale;
        Thread t = new Thread(Run); t.IsBackground = true; t.Start();
        Thread h = new Thread(Host); h.IsBackground = true; h.Start();
    }
}
}
'@
$width = 0; $height = 0; $scale = 0
$stamp = Join-Path $data 'run'
if ($oem.res -match '^(\d+)x(\d+)$' -and $oem.run -and (Get-Content $stamp -ErrorAction SilentlyContinue) -ne $oem.run) {
    $width = [int]$Matches[1]; $height = [int]$Matches[2]
    if ($oem.scale -match '^[12]$') { $scale = [int]$oem.scale }
    Set-Content -Path $stamp -Value $oem.run
}
[MyLinux.Display]::Start($log, $width, $height, $scale)

# ---- the clipboard --------------------------------------------------------------------------------------------------
Add-Type -Namespace MyLinux -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
'@

$MimeText = 'text/plain;charset=utf-8'; $MimePng = 'image/png'       # (not $TEXT: PowerShell's names do not tell upper from lower case, and $text is used below)
$MAX = 16MB
$sha = [Security.Cryptography.SHA256]::Create()
function Fingerprint([string]$format, [byte[]]$data) {
    [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($format) + [byte]0 + $data))
}

# The clipboard is a shared thing: another program may hold it for a moment.
function Retry([scriptblock]$what) {
    for ($i = 0; $i -lt 8; $i++) { try { return & $what } catch { Start-Sleep -Milliseconds 60 } }
    return $null
}
function Read-Clipboard {
    if (Retry { [Windows.Forms.Clipboard]::ContainsImage() }) {
        $image = Retry { [Windows.Forms.Clipboard]::GetImage() }
        if ($image) {
            $m = New-Object IO.MemoryStream
            $image.Save($m, [Drawing.Imaging.ImageFormat]::Png); $image.Dispose()
            return @{ format = $MimePng; data = $m.ToArray() }
        }
    }
    if (Retry { [Windows.Forms.Clipboard]::ContainsText() }) {
        $text = Retry { [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText) }
        # Windows keeps lines apart with CR LF; the Mac and Linux with LF
        if ($text) { return @{ format = $MimeText; data = [Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n")) } }
    }
    return $null
}
function Write-Clipboard([string]$format, [byte[]]$data) {
    if ($format -eq $MimePng) {
        $image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $data)))
        Retry { [Windows.Forms.Clipboard]::SetImage($image); $true } | Out-Null
    } elseif ($format -eq $MimeText) {
        $text = [Text.Encoding]::UTF8.GetString($data).Replace("`r`n", "`n").Replace("`n", "`r`n")
        if ($text.Length) { Retry { [Windows.Forms.Clipboard]::SetText($text, [Windows.Forms.TextDataFormat]::UnicodeText); $true } | Out-Null }
    }
}

function Open-Port {
    # GENERIC_READ | GENERIC_WRITE (0xC0000000, which PowerShell 5 reads as a negative number when written in hex),
    # OPEN_EXISTING, FILE_FLAG_OVERLAPPED: read and write at the same time
    $handle = [MyLinux.Native]::CreateFile($Port, [uint32]3221225472, 0, [IntPtr]::Zero, 3, [uint32]1073741824, [IntPtr]::Zero)
    if (-not $handle -or $handle.IsInvalid) { return $null }
    New-Object IO.FileStream($handle, [IO.FileAccess]::ReadWrite, 4096, $true)
}
function Send($stream, [hashtable]$message) {
    $line = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $message -Compress) + "`n")
    $stream.Write($line, 0, $line.Length); $stream.Flush()
}

while ($true) {
    $stream = Open-Port
    if (-not $stream) { if ($Once) { exit 2 }; Start-Sleep -Seconds 3; continue }
    Add-Content -Path $log -Value ("{0} clipboard: shared with the Mac" -f (Get-Date -Format s))
    try {
        $given = ''; $givenAt = [DateTime]::MinValue          # what the Mac gave last: not told back to it
        $told = ''                                           # what the Mac was told last: not told twice
        $seen = [MyLinux.Native]::GetClipboardSequenceNumber()
        $buffer = New-Object byte[] 65536
        $partial = New-Object IO.MemoryStream
        Send $stream @{ type = 'sync' }
        $reading = $stream.ReadAsync($buffer, 0, $buffer.Length)
        while ($true) {
            if ($reading.IsCompleted) {
                $n = $reading.Result
                if ($n -le 0) { throw 'the port was closed' }
                for ($i = 0; $i -lt $n; $i++) {
                    if ($buffer[$i] -ne 10) { if ($partial.Length -lt ($MAX * 2)) { $partial.WriteByte($buffer[$i]) }; continue }
                    $line = [Text.Encoding]::UTF8.GetString($partial.ToArray()); $partial.SetLength(0)
                    try { $message = ConvertFrom-Json $line } catch { continue }
                    if ($message.type -eq 'clipboard' -and ($message.format -eq $MimeText -or $message.format -eq $MimePng)) {
                        $data = [Convert]::FromBase64String($message.data)
                        if ($data.Length -and $data.Length -le $MAX) {
                            $given = Fingerprint $message.format $data; $givenAt = [DateTime]::UtcNow
                            Write-Clipboard $message.format $data
                            Add-Content -Path $log -Value ("{0} clipboard: from the Mac ({1}, {2} bytes)" -f (Get-Date -Format s), $message.format, $data.Length)
                            $seen = [MyLinux.Native]::GetClipboardSequenceNumber()
                        }
                    } elseif ($message.type -eq 'sync') {
                        $told = ''; $seen = 0               # the Mac asks: tell it what is here
                    }
                }
                $reading = $stream.ReadAsync($buffer, 0, $buffer.Length)
            }
            $now = [MyLinux.Native]::GetClipboardSequenceNumber()
            if ($now -ne $seen) {
                $seen = $now
                $c = Read-Clipboard
                if ($c -and $c.data.Length -le $MAX) {
                    $print = Fingerprint $c.format $c.data
                    $echo = $print -eq $given -and ([DateTime]::UtcNow - $givenAt).TotalSeconds -lt 2
                    if (-not $echo -and $print -ne $told) {
                        $told = $print
                        Send $stream @{ type = 'clipboard'; format = $c.format; data = [Convert]::ToBase64String($c.data) }
                        Add-Content -Path $log -Value ("{0} clipboard: to the Mac ({1}, {2} bytes)" -f (Get-Date -Format s), $c.format, $c.data.Length)
                    }
                }
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        # the machine was stopped or the port went away: opened again when it is back
        Add-Content -Path $log -Value ("{0} clipboard: {1}" -f (Get-Date -Format s), $_.Exception.Message)
    } finally {
        $stream.Dispose()
    }
    if ($Once) { exit 1 }
    Start-Sleep -Seconds 2
}
