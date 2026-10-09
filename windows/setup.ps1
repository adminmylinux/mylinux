# myLinux: what a Windows machine needs to live in a myLinux window, from the tools disc run-windows.sh attaches
# (mylinux\ and drivers\ on it). Windows Setup runs it once while it installs (autounattend.xml, the specialize pass),
# and a task it leaves behind runs it again at every start of Windows, from the disc when it is there: a newer launcher's
# files reach a machine made earlier, and a second run changes nothing. It needs the system's or an administrator's rights.
#   drivers    virtio network (NetKVM), display (viogpudo) and serial ports (vioserial), from the virtio-win project
#   display    the virtio display draws its pointer as the Mac's (the driver's HWCursor); Windows never turns the
#              display off or goes to sleep here, and it does not hibernate (every start is a real start)
#   agent      mylinux-agent.ps1 at every sign-in: the display follows the Mac window's size, and the clipboard is
#              shared with the Mac, text and pictures both ways
#   log        what was done goes to C:\ProgramData\myLinux\setup.log and to the Mac (the virtio port dev.mylinux.setup,
#              which run-windows.sh keeps as setup.log in the machine's folder: "installed" there, said when Windows's
#              first-run screens are over, ends the install phase)
$ErrorActionPreference = 'Continue'
$src = $PSScriptRoot
$disc = Split-Path $src -Parent
$dst = Join-Path $env:ProgramFiles 'myLinux'
$data = Join-Path $env:ProgramData 'myLinux'
New-Item -ItemType Directory -Force $dst, $data | Out-Null
$log = Join-Path $data 'setup.log'
$lines = New-Object Collections.Generic.List[string]
function Say([string]$text) { $lines.Add($text); Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format s), $text) }
Say "setup from $src as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# ---- drivers: into Windows's driver store, and onto the devices that are there now --------------------------------
# The network card's waits until Windows's first-run screens are done: without a network they offer "I don't have
# internet" and a local account (autounattend.xml allows it); with one they insist on an account online, and a test
# machine was shown an organisation's sign-in page there. "Done" is Windows's own word (OOBEComplete): the registry's
# SystemSetupInProgress is 1 only while Setup installs, and 0 again when the first-run screens are up.
function FirstRunDone {
    try {
        if (-not ('MyLinux.Oobe' -as [type])) {
            Add-Type -Namespace MyLinux -Name Oobe -MemberDefinition '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool OOBEComplete(out bool done);'
        }
        $done = $false
        if ([MyLinux.Oobe]::OOBEComplete([ref]$done)) { return $done }
    } catch { }
    # no answer: done when somebody other than the first-run screens' own stand-in account (defaultuser0) has a profile
    return [bool](Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath -notmatch '\\defaultuser\d+$' })
}
function AddDriver($inf) {
    $out = & pnputil.exe /add-driver $inf.FullName /install 2>&1 | Out-String
    Say ("driver {0}: {1}" -f $inf.Name, (($out -split "`r?`n" | Where-Object { $_ -match 'successfully|already|Failed|error' }) -join '; '))
}
$installing = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue).SystemSetupInProgress -eq 1
$settingUp = $installing -or -not (FirstRunDone)
$network = $null
$drivers = Join-Path $disc 'drivers'
if (Test-Path $drivers) {
    foreach ($inf in Get-ChildItem $drivers -Recurse -Filter *.inf) {
        if ($settingUp -and $inf.Name -eq 'netkvm.inf') { $network = $inf; Say 'driver netkvm.inf: after the first-run screens'; continue }
        AddDriver $inf
    }
}

# ---- files: the helpers live on the disk, so they work without the disc -----------------------------------------------
foreach ($f in 'setup.ps1', 'setup.cmd', 'mylinux-agent.ps1') {
    if (Test-Path (Join-Path $src $f)) { Copy-Item (Join-Path $src $f) $dst -Force }
}
# the pointer as the Mac's own (the driver asks QEMU to draw it): on the virtio display's driver key, once it exists
$class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
foreach ($key in Get-ChildItem $class -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
    if ($p.MatchingDeviceId -like 'pci\ven_1af4&dev_1050*' -and $p.HWCursor -ne 1) {
        Set-ItemProperty $key.PSPath -Name HWCursor -Value 1 -Type DWord
        $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' } | Select-Object -First 1
        if ($device) { & pnputil.exe /restart-device $device.InstanceId | Out-Null }
        Say 'pointer: drawn by the Mac from now on'
    }
}
# a window on a Mac: the display never turns off and Windows does not go to sleep by itself
& powercfg.exe /change monitor-timeout-ac 0; & powercfg.exe /change standby-timeout-ac 0
& powercfg.exe /change monitor-timeout-dc 0; & powercfg.exe /change standby-timeout-dc 0
# and no hibernation, so none of Windows's "fast startup" either: with it a shut-down Windows is resumed and not
# started, which here means the hardware of the start before (the installer's, at the first start after installing),
# this script not run at the start, and the window's size as it was said last time. It also takes its file off the disk.
& powercfg.exe /hibernate off 2>$null

# ---- the agent, at every sign-in: a task and not a Run entry, because it needs an administrator's full rights (the
# virtio serial port of the clipboard opens for nobody else) and a task gets them without Windows asking; hidden
# (conhost's headless mode shows no window)
$arguments = '--headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $dst 'mylinux-agent.ps1')
try {
    $task = Get-ScheduledTask -TaskName 'myLinux agent' -ErrorAction SilentlyContinue
    if (-not $task -or $task.Actions[0].Arguments -ne $arguments) {
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest        # whoever signs in
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'myLinux agent' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Say 'agent: starts at sign-in'
    }
} catch { Say "agent: no sign-in task yet ($($_.Exception.Message))" }

# ---- this script again at every start of Windows and at every sign-in, from the disc when it is attached ------------
# (a file in ProgramData: the task's command is one plain path)
$startup = Join-Path $data 'startup.cmd'
$text = "@echo off`r`nrem myLinux: at every start of Windows and at every sign-in, setup from the tools disc when it is attached, else the copy on the disk`r`n" +
        "for %%d in (D E F G H I J K) do if exist %%d:\mylinux\setup.cmd (call %%d:\mylinux\setup.cmd & exit /b)`r`n" +
        ('call "{0}"' -f (Join-Path $dst 'setup.cmd')) + "`r`n"
if (-not (Test-Path $startup) -or (Get-Content $startup -Raw) -ne $text) { [IO.File]::WriteAllText($startup, $text, [Text.Encoding]::ASCII) }
$tasks = $true
try {
    $task = Get-ScheduledTask -TaskName 'myLinux setup' -ErrorAction SilentlyContinue
    if (-not $task -or $task.Triggers.Count -ne 2) {
        $action = New-ScheduledTaskAction -Execute $startup
        $triggers = (New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'myLinux setup' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Say 'start-up task: in place'
    }
} catch { $tasks = $false; Say "start-up task: not yet ($($_.Exception.Message))" }
if (-not $tasks -or -not (Get-ScheduledTask -TaskName 'myLinux agent' -ErrorAction SilentlyContinue)) {
    # Windows Setup may run this before the task scheduler is up: once more when Setup has finished
    $scripts = Join-Path $env:WINDIR 'Setup\Scripts'
    New-Item -ItemType Directory -Force $scripts | Out-Null
    $complete = Join-Path $scripts 'SetupComplete.cmd'
    $line = 'call "{0}"' -f (Join-Path $dst 'setup.cmd')
    if (-not (Test-Path $complete) -or -not (Select-String -Path $complete -SimpleMatch $line -Quiet)) { Add-Content -Path $complete -Value $line -Encoding Ascii }
}
# someone is signed in already and the agent is not running (this ran after the sign-in, or brought a newer agent): now
if (-not $settingUp -and (Get-ScheduledTask -TaskName 'myLinux agent' -ErrorAction SilentlyContinue) -and (Get-Process explorer -ErrorAction SilentlyContinue)) {
    $running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*-Sta*mylinux-agent.ps1*' }
    if (-not $running) { Start-ScheduledTask -TaskName 'myLinux agent' -ErrorAction SilentlyContinue }
}

# ---- tell the Mac: installed, and what was done ---------------------------------------------------------------------
function Report {
    for ($try = 0; $try -lt 20; $try++) {
        try {
            # (through cmd: .NET's own file classes refuse a device path)
            $report = Join-Path $data 'report.txt'
            [IO.File]::WriteAllText($report, ((($lines | ForEach-Object { "mylinux-setup: $_" }) -join "`n") + "`n"), [Text.Encoding]::ASCII)
            & cmd.exe /c "type `"$report`" > \\.\Global\dev.mylinux.setup" 2>$null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2            # the serial driver was installed a moment ago: its port is not there yet
        } catch { Start-Sleep -Seconds 2 }
    }
    $lines.Clear()
}
# "installed" is said when Windows's first-run screens are over: from then on run-windows.sh starts the machine with
# the virtio display and without Microsoft's ISO, and the launcher's page stops calling it an install.
if ($settingUp) { Say 'first-run screens next' } else { Say 'installed' }
Report

# ---- the end of the first-run screens: this run waits for it (not inside Setup's own pass, which waits for this
# script; the start of Windows after it is the run that does), then the network card gets its driver
if ($settingUp -and -not $installing) {
    $until = (Get-Date).AddHours(12)
    while (-not (FirstRunDone) -and (Get-Date) -lt $until) { Start-Sleep -Seconds 3 }
    if (FirstRunDone) {
        if ($network) { AddDriver $network }
        Say 'installed'
        Report
    }
}
