# Claude Install… and Codex Install… for a Windows machine (the launcher's wizards, in the window's ⌘ menu): the part
# inside Windows. Windows PowerShell 5.1, nothing to install.
#
#     claude_codex_setup.ps1 claude status   what is there: Claude Code and its version, Git for Windows (Claude Code
#                                            works through it), the saved subscriptions (their aliases and account
#                                            names, never a token), the status line, and whether the aliases are found
#     claude_codex_setup.ps1 claude apply    carries out the request on its standard input (JSON): Git and Claude Code
#                                            installed when missing, a subscription saved as an alias (cc1, cc2, …)
#                                            with its long-lived token, the status line that shows its account, and
#                                            Claude, the desktop app, installed and pinned to the taskbar
#     claude_codex_setup.ps1 codex status    Codex and its version, whether it is signed in, the alias cx
#     claude_codex_setup.ps1 codex apply     Codex installed (winget), the alias cx, on request OpenAI's desktop app
#                                            (the Microsoft Store's, its terms accepted by the user), and the login of the Mac this
#                                            machine runs on (~/.codex/auth.json there) put in place
#
# Nothing is read from a share and nothing is left on a disk on the way: the launcher sends this file with every
# question over the machine's own port (dev.mylinux.host), the agent (mylinux-agent.ps1) runs it as the signed-in user
# and sends back every line it prints, one JSON object each: {"kind": "status" | "step" | "result", "data": {…}}.
# No secret is printed.
#
# What it writes, all in the user's own folder (the Linux machines' places, where Windows has them):
#     .config\mylinux\claude-accounts\<alias>.env   the token and MYLINUX_CLAUDE_ACCOUNT (which the status line
#                                                   shows), readable by this account only
#     .local\bin\<alias>.cmd                        the alias: Claude Code with that subscription; cc.cmd and cx.cmd
#     .claude\statusline.ps1, .claude\settings.json the status line and the setting that runs it
#     .codex\auth.json                              Codex's login
#     .config\mylinux\claude-desktop-pinned         that Claude was pinned to the taskbar once (it is not pinned
#                                                   again after you take it off)
# With "makeDefault" the token is also the login of plain claude and cc: the user's own environment variables
# CLAUDE_CODE_OAUTH_TOKEN and MYLINUX_CLAUDE_ACCOUNT, which every new terminal has.
param([string]$Tool = '', [string]$What = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'                     # a download with a progress bar is many times slower here
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
Add-Type -AssemblyName System.Web.Extensions

$User = $env:USERPROFILE
$Bin = Join-Path $User '.local\bin'
$Config = Join-Path $User '.config\mylinux'
$Accounts = Join-Path $Config 'claude-accounts'
$ClaudeDir = Join-Path $User '.claude'
$StatusLine = Join-Path $ClaudeDir 'statusline.ps1'
$Settings = Join-Path $ClaudeDir 'settings.json'
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $User '.codex' }
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ClaudeInstaller = 'https://claude.ai/install.ps1'
$NoBom = New-Object Text.UTF8Encoding($false)

$AliasRe = '^[A-Za-z_][A-Za-z0-9_-]{0,31}$'
$AccountRe = '^[A-Za-z0-9._@-]{1,40}$'
$TokenRe = '^[A-Za-z0-9_-]{20,}$'

# ---- what goes back to the Mac ----------------------------------------------------------------------------------------
$stdout = [Console]::OpenStandardOutput()
function Emit([string]$kind, $data) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json ([ordered]@{ kind = $kind; data = $data }) -Compress -Depth 12) + "`n")
    $stdout.Write($bytes, 0, $bytes.Length); $stdout.Flush()
}
$script:Secrets = @()
$script:Steps = New-Object Collections.ArrayList
function Step([string]$step, [string]$title, [string]$state, [string]$detail = '') {
    foreach ($s in $script:Secrets) { if ($s) { $detail = $detail.Replace($s, '***') } }
    $row = [ordered]@{ step = $step; title = $title; state = $state; detail = $detail }
    for ($i = $script:Steps.Count - 1; $i -ge 0; $i--) { if ($script:Steps[$i].step -eq $step) { $script:Steps.RemoveAt($i) } }
    [void]$script:Steps.Add($row)
    Emit 'step' $row
}

# ---- helpers -----------------------------------------------------------------------------------------------------------
# The PATH as a new terminal would have it (this process has the one of the sign-in), with where the installers put things first.
function Refresh-Path {
    $parts = @($Bin, (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'), (Join-Path $env:ProgramFiles 'WinGet\Links'), (Join-Path $env:ProgramFiles 'Git\cmd'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'))
    foreach ($scope in 'User', 'Machine') { $parts += ([string][Environment]::GetEnvironmentVariable('Path', $scope)) -split ';' }
    $seen = @{}; $out = @()
    foreach ($p in $parts) { $q = "$p".Trim().TrimEnd('\'); if ($q -and -not $seen.ContainsKey($q)) { $seen[$q] = $true; $out += $q } }
    $env:Path = $out -join ';'
}
function Find-Program([string]$name) {
    Refresh-Path
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return [string]$c.Source }
    return $null
}
# A program with nobody at the keyboard: its exit code and what it printed.
function Run([string]$file, [string]$arguments, [int]$seconds = 900) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $file; $info.Arguments = $arguments
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = $true
    $info.WorkingDirectory = $User
    try { $p = [Diagnostics.Process]::Start($info) } catch { return @{ code = 127; out = [string]$_.Exception.Message } }
    try { $p.StandardInput.Close() } catch { }
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($seconds * 1000)) {
        try { $p.Kill() } catch { }
        return @{ code = 124; out = "stopped after $([int]($seconds / 60)) minutes" }
    }
    $p.WaitForExit()
    return @{ code = $p.ExitCode; out = ([string]$o.Result) + "`n" + ([string]$e.Result) }
}
# The end of a command's output, without the colours installers print.
function Tail([string]$text, [int]$lines = 12) {
    $clean = [regex]::Replace("$text", "\x1b\[[0-9;?]*[A-Za-z]", '') -replace "`r", "`n"
    $kept = @($clean -split "`n" | Where-Object { "$_".Trim() })
    if ($kept.Count -gt $lines) { $kept = $kept[($kept.Count - $lines)..($kept.Count - 1)] }
    return ($kept -join "`n")
}
function Short([string]$path) {
    if ($path -and $path.StartsWith($User, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $path.Substring($User.Length) }
    return $path
}
# For this account only (and the system): no entry inherited from the folder above.
function Protect([string]$path, [bool]$folder = $false) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    if ($folder) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        foreach ($sid in $me, $system) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))) }
    } else {
        $acl = New-Object Security.AccessControl.FileSecurity
        foreach ($sid in $me, $system) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow'))) }
    }
    $acl.SetAccessRuleProtection($true, $false)
    if ($folder) { [IO.Directory]::SetAccessControl($path, $acl) } else { [IO.File]::SetAccessControl($path, $acl) }
}
function Write-Private([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force (Split-Path $path -Parent) | Out-Null
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text, $NoBom)
    Protect $tmp
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
# %USERPROFILE%\.local\bin in the user's own PATH, so a new terminal finds what is put there.
function Bin-OnPath {
    $have = ([string][Environment]::GetEnvironmentVariable('Path', 'User')) -split ';' | ForEach-Object { "$_".Trim().TrimEnd('\') }
    return ($have -contains $Bin.TrimEnd('\'))
}
function Add-BinToPath {
    New-Item -ItemType Directory -Force $Bin | Out-Null
    if (Bin-OnPath) { return $false }
    $p = ([string][Environment]::GetEnvironmentVariable('Path', 'User')).TrimEnd(';')
    [Environment]::SetEnvironmentVariable('Path', ((@($p, $Bin) | Where-Object { $_ }) -join ';'), 'User')
    return $true
}
function Write-Cmd([string]$name, [string[]]$lines) {
    New-Item -ItemType Directory -Force $Bin | Out-Null
    [IO.File]::WriteAllText((Join-Path $Bin "$name.cmd"), (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
}

# JSON files that are not ours alone (settings.json, .claude.json): read whole and written back whole, every key kept
# as it was (ConvertFrom-Json refuses keys that differ only in case, and such files have them).
$Json = New-Object Web.Script.Serialization.JavaScriptSerializer
$Json.MaxJsonLength = [int]::MaxValue; $Json.RecursionLimit = 200
function Read-Json([string]$file) {
    try {
        if (-not (Test-Path -LiteralPath $file)) { return $null }
        return , $Json.DeserializeObject([IO.File]::ReadAllText($file))
    } catch { return $null }
}
function Key($d, [string]$k) {
    if ($d -is [Collections.IDictionary] -and $d.ContainsKey($k)) { return , $d[$k] }
    return $null
}
$Escapes = @{ '"' = '\"'; '\' = '\\'; "`n" = '\n'; "`r" = '\r'; "`t" = '\t' }
function Json-String([string]$s) {
    return '"' + [regex]::Replace($s, '["\\\x00-\x1f]', { param($m) if ($Escapes.ContainsKey($m.Value)) { $Escapes[$m.Value] } else { '\u{0:x4}' -f [int][char]$m.Value } }) + '"'
}
function To-Json($v, [int]$depth = 0) {
    $pad = '  ' * $depth; $in = '  ' * ($depth + 1)
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) { return (Json-String $v) }
    if ($v -is [Collections.IDictionary]) {
        if ($v.Count -eq 0) { return '{}' }
        $rows = @(); foreach ($k in @($v.Keys)) { $rows += $in + (Json-String ([string]$k)) + ': ' + (To-Json $v[$k] ($depth + 1)) }
        return "{`n" + ($rows -join ",`n") + "`n$pad}"
    }
    if ($v -is [Collections.IEnumerable]) {
        $rows = @(); foreach ($i in $v) { $rows += $in + (To-Json $i ($depth + 1)) }
        if ($rows.Count -eq 0) { return '[]' }
        return "[`n" + ($rows -join ",`n") + "`n$pad]"
    }
    return $Json.Serialize($v)                                # a number
}
function Write-Json([string]$file, $value) {
    New-Item -ItemType Directory -Force (Split-Path $file -Parent) | Out-Null
    $tmp = "$file.mylinux-tmp"
    [IO.File]::WriteAllText($tmp, (To-Json $value) + "`n", $NoBom)
    Move-Item -LiteralPath $tmp -Destination $file -Force
}
function Read-Input {
    $text = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd()
    try { return , $Json.DeserializeObject($text) } catch { return $null }
}
function Winget([string]$id, [int]$seconds = 1200) {
    $winget = Find-Program 'winget'
    if (-not $winget) { return @{ code = 127; out = 'winget is not there yet: open Microsoft Store once and let App Installer update, then try again' } }
    # (the winget source only, which asks for no agreement; nobody is there to answer a question)
    return (Run $winget "install --id $id -e --source winget --disable-interactivity" $seconds)
}

# ---- Claude Code: what is there ---------------------------------------------------------------------------------------
function Read-Env([string]$file) {
    $out = @{}
    foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if ("$line" -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $out[$Matches[1]] = $Matches[2].Trim() }
    }
    return $out
}
function Alias-Names {
    if (-not (Test-Path -LiteralPath $Bin)) { return @() }
    return @(Get-ChildItem -LiteralPath $Bin -Filter '*.cmd' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.BaseName } | Sort-Object)
}
function Claude-Accounts {
    $names = Alias-Names
    $out = @()
    if (Test-Path -LiteralPath $Accounts) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Accounts -Filter '*.env' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $alias = [string]$f.BaseName
            if ($alias -notmatch $AliasRe) { continue }
            $vars = Read-Env $f.FullName
            $out += [ordered]@{ alias = $alias; account = [string]$vars['MYLINUX_CLAUDE_ACCOUNT']; token = [bool]$vars['CLAUDE_CODE_OAUTH_TOKEN']; aliasLine = ($names -contains $alias) }
        }
    }
    return , $out
}
function Line-State {
    $text = ''
    if (Test-Path -LiteralPath $StatusLine) { try { $text = [IO.File]::ReadAllText($StatusLine) } catch { } }
    $command = [string](Key (Key (Read-Json $Settings) 'statusLine') 'command')
    return [ordered]@{ script = [bool]$text; showsAccount = $text.Contains('MYLINUX_CLAUDE_ACCOUNT')
                       configured = (($command -replace '\\', '/') -like '*/.claude/statusline.ps1*'); command = $command }
}
# Claude, the desktop app (winget's Anthropic.Claude: an installer of its own that puts it in the user's folder, with
# a shortcut in the Start menu), and whether it is on the taskbar.
$DesktopLink = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Anthropic\Claude.lnk'
$TaskbarPins = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$PinnedOnce = Join-Path $Config 'claude-desktop-pinned'
function Desktop-State {
    $entry = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnthropicClaude' -ErrorAction SilentlyContinue
    return [ordered]@{ installed = (Test-Path -LiteralPath $DesktopLink); version = [string]$entry.DisplayVersion
                       pinned = (Test-Path -LiteralPath (Join-Path $TaskbarPins 'Claude.lnk')); pinnedOnce = (Test-Path -LiteralPath $PinnedOnce) }
}
function Claude-Status {
    $path = Find-Program 'claude'
    $version = ''
    if ($path) { $r = Run $path '--version' 30; if ($r.out -match '\d+\.\d+\.\d+[^\s]*') { $version = $Matches[0] } }
    $git = [bool](Find-Program 'git') -or (Test-Path (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    $token = [string][Environment]::GetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'User')
    return [ordered]@{
        version = 1; system = 'windows'; user = [string]$env:USERNAME
        claude = [ordered]@{ installed = [bool]$path; version = $version; path = (Short $path) }
        git = $git
        # plain claude and cc: a token every new terminal has, or a login made in the browser
        default = [ordered]@{ token = [bool]$token; account = [string][Environment]::GetEnvironmentVariable('MYLINUX_CLAUDE_ACCOUNT', 'User')
                              browser = (Test-Path -LiteralPath (Join-Path $ClaudeDir '.credentials.json')) }
        accounts = (Claude-Accounts)
        aliases = [ordered]@{ names = @(Alias-Names); loaded = (Bin-OnPath) }
        statusLine = (Line-State)
        apiKey = $false
        onboarded = ((Key (Read-Json (Join-Path $User '.claude.json')) 'hasCompletedOnboarding') -eq $true)
        desktop = (Desktop-State)
    }
}

# ---- Claude Code: the setup -------------------------------------------------------------------------------------------
# The status line, as mylinux.app's is for the Linux machines (statusline.sh there, which needs bash and jq).
$StatusLineText = @'
# Claude Code status line from myLinux (Claude Install… in myLinux Launcher puts it here and in settings.json's
# statusLine). One line: the folder, the git branch (yellow with * when changed), lines added and removed,
# [ctx: context used | 5h and 7d limits, with their reset time from 70% | cost], [model | effort], the subscription
# (MYLINUX_CLAUDE_ACCOUNT, set by the alias that started Claude Code) and the session. Windows PowerShell 5.1 and git.
$ErrorActionPreference = 'SilentlyContinue'
$raw = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd()
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { }
if (-not $j) { exit 0 }
$e = [string][char]27
$arrow = [string][char]0x2192
function Num($v) { if ($null -eq $v -or "$v" -eq '') { return [double]0 }; return [double]$v }
function Clock($unix, [string]$format) { return [DateTimeOffset]::FromUnixTimeSeconds([long]$unix).LocalDateTime.ToString($format, [Globalization.CultureInfo]::InvariantCulture) }
$cwd = [string]$j.workspace.current_dir
$shown = $cwd
if ($env:USERPROFILE -and $cwd.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { $shown = '~' + $cwd.Substring($env:USERPROFILE.Length) }
$model = [string]$j.model.display_name
$effort = [string]$j.effort.level
if ($effort) { $model = $model + ' | ' + $effort.Substring(0, 1).ToUpper() + $effort.Substring(1) }
if ($j.fast_mode -eq $true) { $model = $model + ' ' + [string][char]0x26A1 }
$git = ''
if ($cwd -and (Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $cwd)) {
    $branch = [string](& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $branch) {
        & git -C $cwd --no-optional-locks diff --quiet 2>$null
        $changed = $LASTEXITCODE -ne 0
        if (-not $changed) { & git -C $cwd --no-optional-locks diff --cached --quiet 2>$null; $changed = $LASTEXITCODE -ne 0 }
        if ($changed) { $git = " $e[33m($branch *)$e[0m" } else { $git = " $e[32m($branch)$e[0m" }
    }
}
$lines = ''
$added = Num $j.cost.total_lines_added; $removed = Num $j.cost.total_lines_removed
if ($added -ne 0 -or $removed -ne 0) { $lines = " $e[32m+$added$e[0m/$e[31m-$removed$e[0m" }
$parts = @()
$five = $j.rate_limits.five_hour.used_percentage; $week = $j.rate_limits.seven_day.used_percentage
if ($null -ne $five) {
    $p = '5h:' + [Math]::Round((Num $five)) + '%'
    $reset = $j.rate_limits.five_hour.resets_at
    if ($reset -and (Num $five) -ge 70) { $p = $p + $arrow + (Clock $reset 'HH:mm') }
    $parts += $p
}
if ($null -ne $week) {
    $p = '7d:' + [Math]::Round((Num $week)) + '%'
    $reset = $j.rate_limits.seven_day.resets_at
    if ($reset -and (Num $week) -ge 70) { $p = $p + $arrow + (Clock $reset 'ddd HH:mm') }
    $parts += $p
}
$rate = ''
if ($parts.Count -gt 0) { $rate = ($parts -join ' ') + ' | ' }
$used = Num $j.context_window.used_percentage
$cost = '$' + (Num $j.cost.total_cost_usd).ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture)
$account = ''
if ($env:MYLINUX_CLAUDE_ACCOUNT) { $account = " $e[36m$($env:MYLINUX_CLAUDE_ACCOUNT)$e[0m" }
$session = [string]$j.session_id
if ($session.Length -gt 8) { $session = $session.Substring(0, 8) }
if ($session) { $session = " $e[90m[$session]$e[0m" }
$line = "$e[34m$shown$e[0m$git$lines $e[33m[ctx: $used% | $rate$cost]$e[0m $e[35m[$model]$e[0m$account$session"
$bytes = [Text.Encoding]::UTF8.GetBytes($line + "`n")
$out = [Console]::OpenStandardOutput(); $out.Write($bytes, 0, $bytes.Length); $out.Flush()
'@

function Install-Git {
    $r = Winget 'Git.Git'
    $have = [bool](Find-Program 'git') -or (Test-Path (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    if ($have) { return @{ ok = $true; detail = 'installed from winget' } }
    return @{ ok = $false; detail = "Git for Windows did not install`n" + (Tail $r.out) }
}
function Install-Claude {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('mylinux-claude-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $dir | Out-Null
    try {
        $inst = Join-Path $dir 'install.ps1'
        # downloaded whole, then run: never a script that arrived in part
        try { Invoke-WebRequest -UseBasicParsing -Uri $ClaudeInstaller -OutFile $inst -TimeoutSec 120 }
        catch { return @{ ok = $false; detail = "could not download $ClaudeInstaller (is the machine online?)`n" + [string]$_.Exception.Message } }
        Add-BinToPath | Out-Null
        Refresh-Path
        # (a download of 250 MB that Windows then checks: in a machine that has just been installed, and is busy with
        # its own first hour, that took more than a quarter of an hour)
        $r = Run $PowerShellExe "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$inst`"" 2400
        $path = Find-Program 'claude'
        if (-not $path) { return @{ ok = $false; detail = "Claude Code's installer did not finish`n" + (Tail $r.out) } }
        $version = ''
        $v = Run $path '--version' 30
        if ($v.out -match '\d+\.\d+\.\d+[^\s]*') { $version = $Matches[0] }
        return @{ ok = $true; detail = $version }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
function Account-Cmd([string]$alias, [string]$account) {
    return @('@echo off',
             "rem myLinux: Claude Code as $account (Claude Install in myLinux Launcher wrote this; it is rewritten there)",
             'setlocal',
             "for /f `"usebackq eol=# tokens=1,* delims==`" %%a in (`"%USERPROFILE%\.config\mylinux\claude-accounts\$alias.env`") do set `"%%a=%%b`"",
             'set "ANTHROPIC_API_KEY="',
             'call claude update',
             'call claude --dangerously-skip-permissions %*')
}
function Save-Account([string]$alias, [string]$account, [string]$token) {
    New-Item -ItemType Directory -Force $Accounts | Out-Null
    Protect $Accounts $true
    Write-Private (Join-Path $Accounts "$alias.env") ("# myLinux: Claude Code as $account (the alias $alias); a long-lived token from claude setup-token`r`nCLAUDE_CODE_OAUTH_TOKEN=$token`r`nMYLINUX_CLAUDE_ACCOUNT=$account`r`n")
}
# Every saved subscription's alias, and cc when it is not there: the names written.
function Write-Aliases {
    $written = @()
    foreach ($a in (Claude-Accounts)) {
        $lines = Account-Cmd $a.alias $a.account
        $file = Join-Path $Bin "$($a.alias).cmd"
        $have = ''
        if (Test-Path -LiteralPath $file) { $have = [IO.File]::ReadAllText($file) }
        if ($have -ne (($lines -join "`r`n") + "`r`n")) { Write-Cmd $a.alias $lines; $written += $a.alias }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'cc.cmd'))) {
        Write-Cmd 'cc' @('@echo off', 'rem myLinux: cc starts Claude Code, updated first, without permission prompts', 'call claude update', 'call claude --dangerously-skip-permissions %*')
        $written += 'cc'
    }
    return , $written
}
# .claude.json says the first-run screens are done: the login is the token, so Claude Code starts straight in.
function Mark-Onboarded {
    $file = Join-Path $User '.claude.json'
    $data = $null
    if (Test-Path -LiteralPath $file) {
        if ((Get-Item -LiteralPath $file).Length -gt 0) {
            $data = Read-Json $file
            if (-not ($data -is [Collections.IDictionary])) { return }       # not JSON (being written?): left alone, Claude Code asks once
        }
    }
    if ($null -eq $data) { $data = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
    if ((Key $data 'hasCompletedOnboarding') -eq $true) { return }
    $data['hasCompletedOnboarding'] = $true
    Write-Json $file $data
}
function Install-StatusLine {
    New-Item -ItemType Directory -Force $ClaudeDir | Out-Null
    if (Test-Path -LiteralPath $StatusLine) {
        $have = [IO.File]::ReadAllText($StatusLine)
        if ($have -ne $StatusLineText -and -not $have.Contains('MYLINUX_CLAUDE_ACCOUNT')) { Copy-Item -LiteralPath $StatusLine -Destination "$StatusLine.before-mylinux" -Force }
    }
    [IO.File]::WriteAllText($StatusLine, $StatusLineText, (New-Object Text.UTF8Encoding($true)))     # (with the mark Windows PowerShell reads UTF-8 by)
    $doc = $null                                             # (not $settings: PowerShell's names do not tell upper from lower case)
    if ((Test-Path -LiteralPath $Settings) -and (Get-Item -LiteralPath $Settings).Length -gt 0) {
        $doc = Read-Json $Settings
        if (-not ($doc -is [Collections.IDictionary])) { throw "$(Short $Settings) is not JSON: left as it is" }
    }
    if ($null -eq $doc) { $doc = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
    $line = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $line['type'] = 'command'
    # (Claude Code runs it through Git's bash: forward slashes, and quotes for a user name with a space)
    $line['command'] = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + ($StatusLine -replace '\\', '/') + '"'
    $doc['statusLine'] = $line
    Write-Json $Settings $doc
}
function Install-Desktop {
    $r = Winget 'Anthropic.Claude'
    # winget is done when Claude's own installer has started; the shortcut is there when that one is
    for ($i = 0; $i -lt 120 -and -not (Test-Path -LiteralPath $DesktopLink); $i++) { Start-Sleep -Seconds 2 }
    # installed, and its installer did not get to its shortcut (a machine too busy at the time, or an install a
    # second run finds there): the app's own updater makes it
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (-not (Test-Path -LiteralPath $DesktopLink) -and (Test-Path -LiteralPath (Join-Path $squirrel 'Update.exe')) -and (Test-Path -LiteralPath (Join-Path $squirrel 'claude.exe'))) {
        Run (Join-Path $squirrel 'Update.exe') '--createShortcut=claude.exe --shortcut-locations=StartMenu' 180 | Out-Null
        for ($i = 0; $i -lt 15 -and -not (Test-Path -LiteralPath $DesktopLink); $i++) { Start-Sleep -Seconds 2 }
    }
    if (Test-Path -LiteralPath $DesktopLink) { return @{ ok = $true; detail = [string](Desktop-State).version } }
    return @{ ok = $false; detail = "Claude did not install`n" + (Tail $r.out) }
}
# Claude on the taskbar. Windows has no call for that; what it has is a taskbar layout, a file named by a policy,
# which Explorer reads as it starts and adds to the pins. So: the layout (the Store apps pinned now, which a layout
# that leaves them out would take off, and Claude), the policy, Explorer started again, and then the policy and the
# file away again: the pin stays, as one made by hand. Not when a layout policy is there already (somebody's own).
function Pin-Desktop {
    $policy = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    foreach ($hive in 'HKCU:', 'HKLM:') {
        $have = Get-ItemProperty "$hive\Software\Policies\Microsoft\Windows\Explorer" -ErrorAction SilentlyContinue
        if ($have -and $have.StartLayoutFile) { return @{ ok = $false; skipped = $true; detail = 'this Windows has a taskbar layout of its own (a policy): right-click Claude in the Start menu to pin it' } }
    }
    $apps = @()
    $band = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -ErrorAction SilentlyContinue
    if ($band -and $band.Favorites) {
        $names = [Text.Encoding]::Unicode.GetString([byte[]]$band.Favorites)
        $apps = @([regex]::Matches($names, '[A-Za-z0-9][A-Za-z0-9.\-]+_[a-z0-9]{13}![A-Za-z0-9.\-_]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
    }
    $rows = @($apps | ForEach-Object { '        <taskbar:UWA AppUserModelID="' + [Security.SecurityElement]::Escape($_) + '" />' })
    $rows += '        <taskbar:DesktopApp DesktopApplicationLinkPath="' + [Security.SecurityElement]::Escape($DesktopLink) + '" />'
    $layout = Join-Path $Config 'taskbar-layout.xml'
    New-Item -ItemType Directory -Force $Config | Out-Null
    [IO.File]::WriteAllText($layout, (@('<?xml version="1.0" encoding="utf-8"?>',
        '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
        '  <CustomTaskbarLayoutCollection>', '    <defaultlayout:TaskbarLayout>', '      <taskbar:TaskbarPinList>') + $rows + @('      </taskbar:TaskbarPinList>', '    </defaultlayout:TaskbarLayout>', '  </CustomTaskbarLayoutCollection>', '</LayoutModificationTemplate>') -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
    $made = -not (Test-Path $policy)
    try {
        New-Item $policy -Force | Out-Null
        Set-ItemProperty $policy -Name StartLayoutFile -Value $layout -Type ExpandString
        Set-ItemProperty $policy -Name LockedStartLayout -Value 1 -Type DWord
        # this session's Explorer; Windows starts it again by itself
        $session = (Get-Process -Id $PID).SessionId
        Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force -ErrorAction SilentlyContinue
        $pin = Join-Path $TaskbarPins 'Claude.lnk'
        for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath $pin); $i++) {
            Start-Sleep -Milliseconds 500
            if ($i -eq 30 -and -not (Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })) { Start-Process explorer.exe }
        }
        if (-not (Test-Path -LiteralPath $pin)) { return @{ ok = $false; detail = 'Windows did not take the pin: right-click Claude in the Start menu to pin it' } }
        [IO.File]::WriteAllText($PinnedOnce, (Get-Date -Format s) + "`r`n")
        return @{ ok = $true; detail = 'Windows''s taskbar was started again for it' }
    } finally {
        Remove-ItemProperty $policy -Name StartLayoutFile, LockedStartLayout -ErrorAction SilentlyContinue
        $left = Get-Item $policy -ErrorAction SilentlyContinue
        if ($made -and $left -and $left.ValueCount -eq 0 -and $left.SubKeyCount -eq 0) { Remove-Item $policy -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $layout -Force -ErrorAction SilentlyContinue
    }
}
function Claude-Checked($request) {
    if (-not ($request -is [Collections.IDictionary])) { return @{ problem = 'the request is not what the launcher sends' } }
    $r = @{ problem = $null }
    foreach ($k in 'alias', 'account', 'token') { $r[$k] = ([string](Key $request $k)) -replace '\s', '' }
    $r.makeDefault = ((Key $request 'makeDefault') -eq $true)
    $r.statusLine = ((Key $request 'statusLine') -ne $false)
    $r.desktop = ((Key $request 'desktop') -ne $false)
    if ($r.token) {
        if ($r.alias -notmatch $AliasRe) { $r.problem = 'the alias is one word: letters, digits, - and _, starting with a letter' }
        elseif (@('claude', 'cc', 'cx', 'codex', 'git', 'winget') -contains $r.alias.ToLower()) { $r.problem = "$($r.alias) is taken: pick another name (cc1, cc2, ...)" }
        elseif (-not (Test-Path -LiteralPath (Join-Path $Accounts "$($r.alias).env")) -and (Find-Program $r.alias)) { $r.problem = "$($r.alias) is already a program on this machine: pick another name" }
        elseif ($r.account -notmatch $AccountRe) { $r.problem = 'the account name is one word: letters, digits, . _ @ -' }
        elseif ($r.token -notmatch $TokenRe) { $r.problem = 'that does not look like a token from claude setup-token (sk-ant-oat01-...)' }
    }
    return $r
}
function Claude-Apply {
    $r = Claude-Checked (Read-Input)
    $script:Secrets = @([string]$r.token)
    if ($r.problem) { Step 'request' 'Checking the request' 'failed' $r.problem; return [ordered]@{ ok = $false; steps = @($script:Steps) } }
    # one setup at a time for this account
    $created = $false
    $lock = New-Object Threading.Mutex($false, 'myLinux-claude-setup', [ref]$created)
    $mine = $false
    try { $mine = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mine = $true }
    if (-not $mine) { Step 'request' 'Checking the request' 'failed' 'another Claude setup is running in this machine: wait for it to finish'; return [ordered]@{ ok = $false; steps = @($script:Steps) } }
    try {
        $ok = $true
        $before = Claude-Status
        $adding = [bool]$r.token

        # 1. Git for Windows, which Claude Code works through, and Claude Code itself
        if (-not $before.claude.installed) {
            if ($before.git) { Step 'git' 'Git for Windows' 'done' 'already installed' }
            else {
                Step 'git' 'Installing Git for Windows' 'running' 'Claude Code works through it'
                $g = Install-Git
                Step 'git' 'Installing Git for Windows' $(if ($g.ok) { 'done' } else { 'failed' }) $g.detail
                $ok = $ok -and $g.ok
            }
            Step 'claude' 'Installing Claude Code' 'running'
            $c = Install-Claude
            Step 'claude' 'Installing Claude Code' $(if ($c.ok) { 'done' } else { 'failed' }) $(if ($c.ok -and $c.detail) { "version $($c.detail)" } else { $c.detail })
            $ok = $ok -and $c.ok
        } else {
            Step 'claude' 'Claude Code' 'done' ('already installed' + $(if ($before.claude.version) { ", version $($before.claude.version)" } else { '' }))
        }

        # 2. the subscription: its token and name, then the aliases and the PATH that finds them
        try {
            if ($adding) {
                Step 'account' "Saving $($r.account) as $($r.alias)" 'running'
                Save-Account $r.alias $r.account $r.token
                $detail = "~\.config\mylinux\claude-accounts\$($r.alias).env, for your account only"
                if ($r.makeDefault) {
                    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', $r.token, 'User')
                    [Environment]::SetEnvironmentVariable('MYLINUX_CLAUDE_ACCOUNT', $r.account, 'User')
                    $detail += '; plain claude and cc use it too'
                }
                Step 'account' "Saving $($r.account) as $($r.alias)" 'done' $detail
            }
            if ($adding -or @($before.accounts).Count -gt 0) {
                Step 'aliases' 'Aliases for new terminals' 'running'
                $names = Write-Aliases
                $onPath = Add-BinToPath
                $have = @((Claude-Accounts) | ForEach-Object { $_.alias })
                Step 'aliases' 'Aliases for new terminals' 'done' (($have -join ', ') + $(if (@($names).Count -gt 0) { ' (wrote ' + (@($names) -join ', ') + ')' } else { '' }) + $(if ($onPath) { '; ~\.local\bin is on your PATH now' } else { '' }))
            }
            Mark-Onboarded
        } catch {
            Step 'account' 'Saving the subscription' 'failed' ([string]$_.Exception.Message)
            $ok = $false
        }

        # 3. the status line, which shows the subscription's name
        $line = Line-State
        if ($r.statusLine -and -not ($line.script -and $line.showsAccount -and $line.configured)) {
            Step 'statusline' 'Installing the status line' 'running'
            try {
                Install-StatusLine
                Step 'statusline' 'Installing the status line' 'done' 'folder, branch, context, limits, model and the account'
            } catch {
                Step 'statusline' 'Installing the status line' 'failed' ([string]$_.Exception.Message)
                $ok = $false
            }
        } elseif ($r.statusLine) {
            Step 'statusline' 'The status line' 'done' 'already shows the account'
        }
        # 4. Claude, the desktop app, and its place on the taskbar (once: taken off by hand, it stays off)
        if ($r.desktop) {
            $desk = Desktop-State
            if (-not $desk.installed) {
                Step 'desktop' 'Installing Claude, the desktop app' 'running' 'from winget'
                $d = Install-Desktop
                Step 'desktop' 'Installing Claude, the desktop app' $(if ($d.ok) { 'done' } else { 'failed' }) $(if ($d.ok) { $(if ($d.detail) { "version $($d.detail); " } else { '' }) + 'it asks you to sign in when you open it' } else { $d.detail })
                $ok = $ok -and $d.ok
                $desk = Desktop-State
            }
            if ($desk.installed -and -not $desk.pinned -and -not $desk.pinnedOnce) {
                Step 'taskbar' 'Pinning Claude to the taskbar' 'running'
                try { $t = Pin-Desktop } catch { $t = @{ ok = $false; detail = [string]$_.Exception.Message } }
                # (a pin that did not come is told, and is not the setup's failure: Claude is in the Start menu)
                Step 'taskbar' 'Pinning Claude to the taskbar' $(if ($t.ok) { 'done' } else { 'skipped' }) $t.detail
            }
        }
        return [ordered]@{ ok = $ok; steps = @($script:Steps); alias = $(if ($adding) { $r.alias } else { '' }); account = $(if ($adding) { $r.account } else { '' })
                           makeDefault = ($adding -and $r.makeDefault); status = (Claude-Status) }
    } finally { try { $lock.ReleaseMutex() } catch { } }
}

# ---- Codex -------------------------------------------------------------------------------------------------------------
# cx, as this writes it. Codex 0.161 starts a background server of its own for its terminal, and on Windows that
# one stops at once ("the CLI package does not match this platform or executable", with winget's Arm64 package and
# started by its real path too); --no-daemon, which the message names, starts Codex without it.
$CxLines = @('@echo off', 'rem myLinux: cx starts Codex without approvals or sandbox, and without its background server', 'call codex --no-daemon --dangerously-bypass-approvals-and-sandbox %*')
function Cx-Current {
    $file = Join-Path $Bin 'cx.cmd'
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    return [IO.File]::ReadAllText($file).Contains('--no-daemon')
}
# OpenAI's desktop app with Codex in it: the ChatGPT app, from the Microsoft Store (OpenAI's page for Windows gives
# winget install --id 9PLM9XGG6VKS -s msstore). The Store asks for its terms to be accepted, and that is the user's to
# do: installed only when the request says they have (storeTerms).
$CodexStoreId = '9PLM9XGG6VKS'
function CodexApp-State {
    $found = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenAI.*' } | Select-Object -First 1)
    if ($found.Count -eq 0) { return [ordered]@{ installed = $false; version = ''; package = '' } }
    return [ordered]@{ installed = $true; version = [string]$found[0].Version; package = [string]$found[0].Name }
}
function Install-CodexApp {
    $winget = Find-Program 'winget'
    if (-not $winget) { return @{ ok = $false; detail = 'winget is not there yet: open Microsoft Store once and let App Installer update, then try again' } }
    $r = Run $winget "install --id $CodexStoreId --source msstore --accept-source-agreements --accept-package-agreements --disable-interactivity" 1800
    # (the Store goes on for a moment after winget has answered)
    for ($i = 0; $i -lt 30 -and -not (CodexApp-State).installed; $i++) { Start-Sleep -Seconds 2 }
    $state = CodexApp-State
    if ($state.installed) { return @{ ok = $true; detail = "version $($state.version); it asks you to sign in when you open it" } }
    return @{ ok = $false; detail = "the app did not install`n" + (Tail $r.out) }
}
function Codex-Status {
    $path = Find-Program 'codex'
    $version = ''; $said = ''
    if ($path) {
        $r = Run $path '--version' 30
        if ($r.out -match '\d+\.\d+\.\d+[^\s]*') { $version = $Matches[0] }
    }
    $auth = Join-Path $CodexHome 'auth.json'
    $file = (Read-Json $auth) -is [Collections.IDictionary]
    # a login file is there; whether Codex takes it is Codex's word (without Codex, the file is all there is to go by)
    $accepted = $file
    if ($path -and $file) {
        $r = Run $path 'login status' 20
        $said = [string](@((Tail $r.out 3) -split "`n") | Select-Object -First 1)
        $accepted = ($r.code -eq 0)
    }
    return [ordered]@{
        version = 1; system = 'windows'; user = [string]$env:USERNAME
        codex = [ordered]@{ installed = [bool]$path; version = $version; path = (Short $path) }
        login = [ordered]@{ file = $file; accepted = $accepted; says = $said }
        alias = [ordered]@{ cx = (Test-Path -LiteralPath (Join-Path $Bin 'cx.cmd')); current = (Cx-Current); loaded = (Bin-OnPath) }
        desktop = (CodexApp-State)
        winget = [bool](Find-Program 'winget')
    }
}
function Codex-Apply {
    $request = Read-Input
    if (-not ($request -is [Collections.IDictionary])) { Step 'request' 'Checking the request' 'failed' 'the request is not what the launcher sends'; return [ordered]@{ ok = $false; steps = @($script:Steps) } }
    $login = [string](Key $request 'login')
    $script:Secrets = @()
    $ok = $true
    $before = Codex-Status

    # 1. Codex itself: OpenAI's Arm64 build, from winget
    if ($before.codex.installed) {
        Step 'codex' 'Codex' 'done' ('already installed' + $(if ($before.codex.version) { ", version $($before.codex.version)" } else { '' }))
    } elseif ((Key $request 'install') -ne $false) {
        Step 'codex' 'Installing Codex' 'running' 'from winget'
        $r = Winget 'OpenAI.Codex'
        $path = Find-Program 'codex'
        $version = ''
        if ($path) { $v = Run $path '--version' 30; if ($v.out -match '\d+\.\d+\.\d+[^\s]*') { $version = $Matches[0] } }
        Step 'codex' 'Installing Codex' $(if ($path) { 'done' } else { 'failed' }) $(if ($path) { $(if ($version) { "version $version" } else { '' }) } else { "Codex did not install`n" + (Tail $r.out) })
        $ok = $ok -and [bool]$path
    }

    # 2. cx: Codex without approvals or sandbox, as the Linux machines' cx
    if ((Key $request 'alias') -ne $false) {
        try {
            $wrote = $false
            $file = Join-Path $Bin 'cx.cmd'
            # not there, or the cx of before (this wizard's, or the snippet's): one that is somebody's own is left
            $old = (Test-Path -LiteralPath $file) -and -not (Cx-Current) -and [IO.File]::ReadAllText($file).Contains('codex --dangerously-bypass-approvals-and-sandbox')
            if (-not (Test-Path -LiteralPath $file) -or $old) {
                Write-Cmd 'cx' $CxLines
                $wrote = $true
            }
            $onPath = Add-BinToPath
            Step 'alias' 'The alias cx' 'done' ($(if ($wrote) { 'cx starts Codex without approvals or sandbox, and without its background server' } else { 'already there' }) + $(if ($onPath) { '; ~\.local\bin is on your PATH now' } else { '' }))
        } catch {
            Step 'alias' 'The alias cx' 'failed' ([string]$_.Exception.Message)
            $ok = $false
        }
    }

    # 3. the Mac's login, as OpenAI documents for a computer without a browser: its auth.json, here
    if ($login) {
        Step 'login' 'Signing Codex in as on the Mac' 'running'
        try {
            $parsed = $null
            try { $parsed = $Json.DeserializeObject($login) } catch { }
            if (-not ($parsed -is [Collections.IDictionary])) { throw 'what came from the Mac is not a Codex login file' }
            New-Item -ItemType Directory -Force $CodexHome | Out-Null
            $auth = Join-Path $CodexHome 'auth.json'
            $kept = ''
            if ((Test-Path -LiteralPath $auth) -and (Get-Item -LiteralPath $auth).Length -gt 0 -and [IO.File]::ReadAllText($auth) -ne $login) {
                Copy-Item -LiteralPath $auth -Destination "$auth.before-mac" -Force
                $kept = '; the login that was here is kept as auth.json.before-mac'
            }
            Write-Private $auth $login
            $says = ''
            $path = Find-Program 'codex'
            if ($path) {
                $r = Run $path 'login status' 20
                $says = [string](@((Tail $r.out 3) -split "`n") | Select-Object -First 1)
                if ($r.code -ne 0) { throw "the login is in place, and Codex does not take it: $says" }
            }
            Step 'login' 'Signing Codex in as on the Mac' 'done' ($(if ($says) { $says } else { '~\.codex\auth.json, for your account only' }) + $kept)
        } catch {
            Step 'login' 'Signing Codex in as on the Mac' 'failed' ([string]$_.Exception.Message)
            $ok = $false
        }
    }
    # 4. the desktop app (ChatGPT, with Codex in it): when asked for, and only with the Store's terms accepted by the user
    if ((Key $request 'desktop') -eq $true) {
        $store = CodexApp-State
        if ($store.installed) {
            Step 'app' 'The desktop app' 'done' "already installed, version $($store.version)"
        } elseif ((Key $request 'storeTerms') -ne $true) {
            Step 'app' 'Installing the desktop app' 'failed' "it comes from the Microsoft Store, whose terms are the user's to accept: when they have said so, add --accept-store-terms"
            $ok = $false
        } else {
            Step 'app' 'Installing the desktop app' 'running' 'ChatGPT, with Codex in it, from the Microsoft Store'
            $made = Install-CodexApp
            Step 'app' 'Installing the desktop app' $(if ($made.ok) { 'done' } else { 'failed' }) $made.detail
            $ok = $ok -and $made.ok
        }
    }
    return [ordered]@{ ok = $ok; steps = @($script:Steps); status = (Codex-Status) }
}

# ---- the question -------------------------------------------------------------------------------------------------------
$known = @{ 'claude status' = { Emit 'status' (Claude-Status) }; 'codex status' = { Emit 'status' (Codex-Status) }
            'claude apply' = { Emit 'result' (Claude-Apply) }; 'codex apply' = { Emit 'result' (Codex-Apply) } }
$ask = "$Tool $What"
if (-not $known.ContainsKey($ask)) { [Console]::Error.WriteLine('usage: claude_codex_setup.ps1 claude|codex status|apply'); exit 64 }
try {
    & $known[$ask]
} catch {
    # whatever went wrong, the wizard is told
    $failed = [ordered]@{ step = 'setup'; title = 'The setup'; state = 'failed'; detail = ([string]$_.Exception.Message + "`n" + [string]$_.ScriptStackTrace) }
    if ($What -eq 'apply') { Emit 'result' ([ordered]@{ ok = $false; steps = @(@($script:Steps) + $failed) }) }
    else { [Console]::Error.WriteLine([string]$_.Exception.Message); exit 1 }
}
exit 0
