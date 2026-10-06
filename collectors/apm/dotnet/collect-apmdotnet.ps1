# WhaTap Global Groundtruth -- APM .NET agent collector (Windows)
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap .NET-agent developer repeatedly asks
# a field engineer for, from the Windows host where the instrumented .NET
# application runs (IIS w3wp, .NET Core services). Derived from an exhaustive
# review of #ask-dev-apm .NET support threads (2025-06 .. 2026-08), the
# dotnet-apm source repo (installer release.iss, ClrProfiler, Tracer, Loader,
# Startup), and docs.whatap.io (install-check, supported-spec).
#
# Sections: [1] collection environment, A host & platform, B agent
# installation on disk, C profiler registration & environment scopes,
# D WhaTap service & runtime processes, E IIS topology, F agent
# configuration, G agent logs, H network endpoints, I Windows event logs,
# J application facts; then status. The question each answers: README.md,
# "Facts collected".
#
# THE CONTRACT (../../../CONTRACT.md):
#   1. Facts only. No conclusion is stated on any emitted line.
#   2. Discover, never assume. Registry, service env, process args, config.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned. Seed v0 by the Global team; ownership transfers to
#      the .NET agent developers.
#
# DESIGN GUIDELINES (../../../docs/collector-engineering.md): MECE sections,
# Tier-0 load-safe defaults (bounded reads, -Tail/-TotalCount caps, MaxEvents
# caps), reasoned absence for every missing value. Nothing is written to the
# target system; the only processes executed are read-only queries (appcmd
# list, dotnet --list-runtimes, netstat). No app pool is recycled, no
# registry value is set.
#
# Requires Windows PowerShell 5.1+ (default on Windows Server 2016+). Run it
# in a 64-bit elevated PowerShell for full coverage; without elevation the
# probes that need it degrade to reasoned n/a lines instead of failing.
#
# Usage:
#   .\collect-apmdotnet.ps1                 print this help (no collection)
#   .\collect-apmdotnet.ps1 -File           write report -> .\whatap-apmdotnet-<host>-<UTC>.txt
#   .\collect-apmdotnet.ps1 -Stdout         print report to stdout
#   .\collect-apmdotnet.ps1 -AgentHome <dir>  add an agent install dir the discovery cannot see
#   powershell -ExecutionPolicy Bypass -File .\collect-apmdotnet.ps1 -File
#
# Saved as UTF-8 with a BOM and kept ASCII in every emitted string, so Windows
# PowerShell 5.1 reads it the same way pwsh 7 does.
# -----------------------------------------------------------------------------
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$File,
    [switch]$Stdout,
    [switch]$Quiet,
    [switch]$Help,
    # Not "$Home": PowerShell variables are case-insensitive, so a parameter
    # named Home is the read-only automatic $HOME and every run died with
    # "Cannot overwrite variable Home" (collect-db-mssql.ps1 0.2.0).
    [string[]]$AgentHome = @(),
    # -Out DIR: a switch, and its directory is read from the arguments below.
    # Not a string parameter: then a -Out with no value is PowerShell's
    # "Missing an argument", not this script's usage. It must be declared:
    # undeclared, -Out is an ambiguous prefix of -OutVariable / -OutBuffer.
    # Named OutFlag with the alias Out: a variable $Out would be the same
    # variable as any $out in the script and turn a path into "True".
    [Alias("Out")]
    [switch]$OutFlag,
    # everything else, read below: -Home DIR (not declared, so that -h means
    # -Help alone and a -Home with no value is a usage error), the directory
    # of -Out, the shell collectors' spellings (--stdout, --file, --quiet,
    # --help, -h, --home DIR, --out DIR, --home=DIR, --out=DIR), and anything
    # unknown, which stops the run with usage on stderr and exit 2, as the
    # shell CLI does
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$COLLECTOR_NAME = "whatap-apmdotnet"
# History: CHANGELOG.md (next to this file).
$VERSION        = "0.9.1"
$DOMAIN         = "apm"
$CompName = $env:COMPUTERNAME; if (-not $CompName) { $CompName = [Environment]::MachineName }
$TARGET         = "host/$CompName"

function Usage {
    return @"
$COLLECTOR_NAME $VERSION -- a WhaTap Global Groundtruth collector (facts only).
Target: a Windows host where the WhaTap .NET agent and the instrumented
application (IIS / .NET Core) run. Run in a 64-bit elevated PowerShell for
full coverage; without elevation some probes degrade to reasoned n/a lines.
A collection needs an explicit action flag so nothing starts by accident.

  .\collect-apmdotnet.ps1                  print this help (no collection)
  .\collect-apmdotnet.ps1 -File            write report -> .\$COLLECTOR_NAME-<host>-<UTC>.txt
  .\collect-apmdotnet.ps1 -Stdout          print report to stdout
  .\collect-apmdotnet.ps1 -Quiet ...       silence progress narration
  .\collect-apmdotnet.ps1 -Home <dir>      add an agent install dir the discovery cannot see (also -AgentHome)
  .\collect-apmdotnet.ps1 -File -Out <dir> write the report into <dir> (default: the current directory)
  .\collect-apmdotnet.ps1 -Help | -h       print this help
The shell spellings --file, --stdout, --quiet, --home <dir>, --out <dir> and --help work too.

If script execution is blocked by policy, run:
  powershell -ExecutionPolicy Bypass -File .\collect-apmdotnet.ps1 -File
"@
}
# pwsh 7 hands "--out=C:\x" over as "--out=C" and "\x", the drive colon
# dropped: such a pair is put back together
$_rest = New-Object System.Collections.Generic.List[string]
foreach ($_ra in @($Rest)) {
    $_rs = "$_ra"; $_rl = $_rest.Count - 1
    if ($_rl -ge 0 -and $_rs -match '^[\\/]' -and $_rest[$_rl] -match '^--?(out|home)=[A-Za-z]$') { $_rest[$_rl] += ":" + $_rs }
    elseif ($_rl -ge 0 -and $_rs -match '^[\\/]' -and $_rest[$_rl] -match '^--?(out|home)=[A-Za-z]:$') { $_rest[$_rl] += $_rs }
    else { $_rest.Add($_rs) }
}
$OutPath = ""; $wantHelp = $false; $badArg = @(); $_loose = @()
for ($_ci = 0; $_ci -lt $_rest.Count; $_ci++) {
    $_ca = $_rest[$_ci]
    if ($_ca -in @('--help', '-help', '-h', '/?')) { $wantHelp = $true }
    elseif ($_ca -eq '--file')   { $File = [switch]$true }
    elseif ($_ca -eq '--stdout') { $Stdout = [switch]$true }
    elseif ($_ca -eq '--quiet')  { $Quiet = [switch]$true }
    elseif ($_ca -in @('--home', '-home')) {
        if ($_ci + 1 -ge $_rest.Count) { $badArg += "$_ca (needs a directory)"; continue }
        $_ci++; $AgentHome += $_rest[$_ci]
    }
    elseif ($_ca -match '^--?home[=:](.+)$') { $AgentHome += $Matches[1] }
    elseif ($_ca -match '^--?out[=:](.+)$') { $OutPath = $Matches[1] }
    elseif ($_ca -notmatch '^-') { $_loose += $_ca }
    else { $badArg += $_ca }
}
# -Out / --out bind the switch; the directory is the one argument left over
if ($OutFlag -and -not $OutPath) {
    if ($_loose.Count -ge 1) { $OutPath = $_loose[0]; $_loose = @($_loose | Select-Object -Skip 1) }
    else { $badArg += "-Out (needs a directory)" }
}
$badArg += $_loose
if ($badArg.Count -gt 0) {
    [Console]::Error.WriteLine("unknown argument: " + ($badArg -join ' '))
    [Console]::Error.WriteLine((Usage))
    exit 2
}
if ($Help -or $wantHelp -or (-not $File -and -not $Stdout)) {
    Write-Output (Usage)
    exit 0
}
# The report directory: -Out, else the current file-system location. Checked
# before anything is collected, by creating and removing a file in it, so a
# mistyped or read-only directory costs no run.
$OutDir = (Get-Location -PSProvider FileSystem).ProviderPath
if ($OutPath) {
    try { $OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath) } catch { $OutDir = $OutPath }
    # Test-Path throws, in Windows PowerShell 5.1, for a path with characters
    # a path cannot hold; that is a directory that is not there either
    $isDir = $false; try { $isDir = Test-Path -LiteralPath $OutDir -PathType Container -ErrorAction Stop } catch { }
    if (-not $isDir) {
        [Console]::Error.WriteLine("!! output directory not found: $OutDir")
        exit 1
    }
}
if (-not $Stdout) {
    $_wp = Join-Path $OutDir (".whatap-write-test-" + [guid]::NewGuid().ToString('N'))
    try { [System.IO.File]::WriteAllText($_wp, ""); [System.IO.File]::Delete($_wp) }
    catch {
        $_wx = $_.Exception; while ($_wx.InnerException) { $_wx = $_wx.InnerException }
        [Console]::Error.WriteLine("!! output directory not writable: $OutDir ($($_wx.Message))")
        exit 1
    }
}

# ---- ps1: emit helpers — DO NOT EDIT -----------------------------------------
# members: apmdotnet db-mssql
$script:SectionN = 0
$script:Lines = New-Object System.Collections.Generic.List[string]

# a carriage return inside a line (an event message, a verbatim file line) is
# dropped, so the report stays LF-only; the byte facts of a conf count CRs
function Emit([string]$s) { $script:Lines.Add(($s -replace "`r", "")) }
# Fmt-Time DATETIME -> yyyy-MM-dd HH:mm:ss (local time), the one format of every
# timestamp in the report. A DateTime interpolated into a string comes out as
# MM/dd/yyyy, and one formatted with -f in the current culture: on a Korean
# Windows that puts non-ASCII AM/PM words in the report (0.4.0 mixed both).
function Fmt-Time($d) { if ($d -is [DateTime]) { return $d.ToString('yyyy-MM-dd HH:mm:ss') } return "n/a" }
function Fact([string]$s) { Emit ("    " + $s) }
function Section([string]$t) {
    $script:SectionN++
    Emit ""
    Emit ("[{0}] {1}" -f $script:SectionN, $t)
    Progress "[$script:SectionN] $t"
}
# ---- end ps1: emit helpers

# ---- ps1: run helpers — DO NOT EDIT ------------------------------------------
# members: apmdotnet db-mssql
# The port of the shell blocks "run helpers", "privilege" and "boot time" in
# templates/collector-skeleton/collector-skeleton.sh. Keep the two in step.
#
# Operator streams. Progress (silenced by -Quiet), Warn and Notice (never
# silenced) go to stderr through [Console]::Error.WriteLine. Write-Host reaches
# stdout when the script runs as `pwsh -File ... > out`, and 13 ">>" lines once
# landed in a report that way (found 2026-09-25). docs/output-format.md,
# operator streams table.
#
# Emitted strings stay ASCII: Windows PowerShell 5.1 reads a script without a
# BOM as the ANSI code page, and a UTF-8 dash then arrives garbled.
function Progress([string]$s) { if (-not $Quiet) { [Console]::Error.WriteLine(">> $s") } }
function Warn([string]$s)     { [Console]::Error.WriteLine("!! $s") }
function Notice([string]$s)   { [Console]::Error.WriteLine(">> $s") }

# Bounded execution, the port of _bounded / RUN_DEADLINE.
# Invoke-Bounded runs an external program: it is killed at CMD_TIMEOUT seconds
# (its output pipes too, when a child holds them open after it exits), nothing
# runs once RUN_DEADLINE has passed, and it throws "timed out: Ns" or "run
# deadline reached: Ns", which TryFact turns into the n/a reason. A non-zero
# exit is kept in $script:BoundedExit and TryFact labels it "(exit N)", as the
# shell probe does. Invoke-BoundedBlock runs a cmdlet pipeline in its own
# runspace under the same caps, for cmdlets with no timeout of their own
# (Get-Service, Get-NetTCPConnection, Get-WinEvent, ...). Get-CimBounded runs
# a CIM query with -OperationTimeoutSec under the same caps.
#
# Each bounded call is timed (Stopwatch) and logged for Emit-Status: only the
# command name and, for a subcommand tool (appcmd list, netsh show), that word,
# or the class of a CIM query. Never an argument: it can hold a path or a
# credential. CMD_TIMEOUT and RUN_DEADLINE come from the environment when they
# are whole numbers 1..999999, as in the shell collectors.
function Cap-Or([string]$name, [string]$v, [int]$def) {
    if ($v -eq "") { return $def }
    if ($v -match '^[1-9][0-9]{0,5}$') { return [int]$v }
    Warn "$name=$v ignored (not a whole number 1..999999 without leading zeros), using $def"
    return $def
}
$script:CMD_TIMEOUT  = Cap-Or CMD_TIMEOUT "$env:CMD_TIMEOUT" 20
$script:RUN_DEADLINE = Cap-Or RUN_DEADLINE "$env:RUN_DEADLINE" 300
$script:RunStart     = [DateTime]::UtcNow
$script:BoundedExit  = $null
$script:SLOW_SEC     = 3      # a bounded call at least this long is named in the status
$script:TimeLog      = New-Object System.Collections.Generic.List[object]   # {ms; kind; name} per call
$script:Load0        = ""     # Host-Load at the start of the run
function Past-Deadline { return (([DateTime]::UtcNow - $script:RunStart).TotalSeconds -ge $script:RUN_DEADLINE) }
function Bounded-Seconds([int]$sec) {
    if ($sec -le 0) { $sec = $script:CMD_TIMEOUT }
    $left = [int][Math]::Floor($script:RUN_DEADLINE - ([DateTime]::UtcNow - $script:RunStart).TotalSeconds)
    if ($left -le 0) { throw "run deadline reached: $($script:RUN_DEADLINE)s" }
    if ($left -lt $sec) { $sec = $left }
    return $sec
}
function Bounded-Timeout([int]$sec) {
    if (Past-Deadline) { throw "run deadline reached: $($script:RUN_DEADLINE)s" }
    throw "timed out: ${sec}s"
}
# Time-Log MS KIND CMD [ARGS] -> one record for Emit-Status: the command name
# (path and .exe dropped) and, for a subcommand tool, the first argument after
# any -opt=value when it is a plain lowercase word; for Get-CimInstance, the
# class. No other argument is kept; a name with odd characters is "?".
function Time-Log([long]$ms, [string]$kind, [string]$cmd, [object[]]$argv = @()) {
    $c = ($cmd -replace '^.*[\\/]', '') -replace '\.exe$', ''
    $w = ""
    $rest = @($argv | ForEach-Object { "$_" })
    $i = 0; while ($i -lt $rest.Count -and $rest[$i] -match '^-.*=') { $i++ }
    $first = if ($i -lt $rest.Count) { $rest[$i] } else { "" }
    if ($c -in @('kubectl','oc','helm','zfs','zpool','systemctl','journalctl','timedatectl','chronyc','npm','pip','pip3','openssl','docker','crictl','ctr','ip','appcmd','netsh','sc','reg','wevtutil')) {
        if ($first -cmatch '^[a-z][a-z0-9-]*$') { $w = " $first" }
    } elseif ($c -eq 'Get-CimInstance') {
        if ($first -match '^[A-Za-z][A-Za-z0-9_]*$') { $w = " $first" }
    }
    if ($c -notmatch '^[A-Za-z0-9._+-]+$') { $c = '?' }
    $script:TimeLog.Add([pscustomobject]@{ ms = $ms; kind = $kind; name = "$c$w" })
}
# Cap-Kind SEC REQUESTED -> how a call that hit its limit is logged: the
# deadline cut it when it had less than it asked for
function Cap-Kind([int]$sec, [int]$req) {
    if ($sec -lt $req) { return "cut at the deadline" }
    return "capped at ${sec}s"
}
# Block-Cmd { ... } -> the first command a script block runs, for the log
function Block-Cmd([scriptblock]$sb) {
    $c = $sb.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    if ($c) { $n = $c.GetCommandName(); if ($n) { return $n } }
    return "?"
}
# Log-NotRun { ... } -> a "not run" record for each bounded call in a block
# that TryFact skips past the deadline, read from the block's syntax tree so
# nothing in it runs. A program name held in a variable is read from the
# caller's scope; a program that is not on this host is not listed, as the
# shell probe lists no command it cannot find.
function Log-NotRun([scriptblock]$sb) {
    $all = $sb.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($_ln in $all) {
        $_le = $_ln.CommandElements
        $_lv = @(); if ($_le.Count -gt 1) { try { $_lv = @($_le[1].SafeGetValue()) } catch { $_lv = @() } }
        switch ($_ln.GetCommandName()) {
            'Invoke-Bounded' {
                $_lx = ""
                if ($_lv.Count -gt 0) { $_lx = "$($_lv[0])" }
                elseif ($_le.Count -gt 1 -and $_le[1] -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $_lx = "$(Get-Variable -Name $_le[1].VariablePath.UserPath -ValueOnly -ErrorAction SilentlyContinue)"
                }
                if (-not $_lx) { Time-Log 0 "not run" "?"; break }
                if (-not (Test-Path -LiteralPath $_lx) -and -not (Get-Command $_lx -CommandType Application -ErrorAction SilentlyContinue)) { break }
                $_la = @(); if ($_le.Count -gt 2) { try { $_la = @($_le[2].SafeGetValue()) } catch { $_la = @() } }
                Time-Log 0 "not run" $_lx $_la
            }
            'Invoke-BoundedBlock' {
                if ($_le.Count -gt 1 -and $_le[1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    Time-Log 0 "not run" (Block-Cmd $_le[1].ScriptBlock.GetScriptBlock())
                } else { Time-Log 0 "not run" "?" }
            }
            'Get-CimBounded' { Time-Log 0 "not run" "Get-CimInstance" @($_lv | Select-Object -First 1) }
        }
    }
}
# Quote-Arg -> one argument quoted the way CommandLineToArgvW splits it back:
# backslashes are literal except before a quote, where they are doubled
function Quote-Arg([string]$a) {
    if ($a -ne "" -and $a -notmatch '[\s"]') { return $a }
    $q = '"'; $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq [char]92) { $bs++; continue }
        if ($ch -eq [char]34) { $q += ([string][char]92 * (2 * $bs + 1)) + '"' }
        else { $q += ([string][char]92 * $bs) + $ch }
        $bs = 0
    }
    return $q + ([string][char]92 * (2 * $bs)) + '"'
}
# Stop-Tree PROCESS PIPEINODES -> kill the process and everything it started.
# Windows keeps a dead parent's id in ParentProcessId, so the tree is read from
# one Win32_Process snapshot and still finds a child whose parent has exited.
# Linux reparents such a child, so there the holders of the child's output
# pipes are found through /proc/<pid>/fd instead. Kill($true) is not used: it
# does not exist in Windows PowerShell 5.1 and it misses reparented children.
function Stop-Tree($p, [string[]]$pipes) {
    $ids = New-Object System.Collections.Generic.List[int]
    $isWin = ($env:OS -eq "Windows_NT")
    if ($isWin) {
        try {
            $all = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object ProcessId, ParentProcessId)
            $front = @($p.Id)
            while ($front.Count -gt 0) {
                $next = @($all | Where-Object { $front -contains $_.ParentProcessId -and -not $ids.Contains([int]$_.ProcessId) } | ForEach-Object { [int]$_.ProcessId })
                foreach ($n in $next) { $ids.Add($n) }
                $front = $next
            }
        } catch { }
    } else {
        foreach ($d in @(Get-ChildItem -LiteralPath /proc -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' })) {
            if ([int]$d.Name -eq $PID -or [int]$d.Name -eq $p.Id) { continue }
            try {
                foreach ($f in [System.IO.Directory]::GetFiles("$($d.FullName)/fd")) {
                    $t = ([System.IO.FileInfo]::new($f)).LinkTarget
                    if ($t -and ($pipes -contains "$t")) { $ids.Add([int]$d.Name); break }
                }
            } catch { }
        }
    }
    foreach ($n in $ids) { try { [System.Diagnostics.Process]::GetProcessById($n).Kill() } catch { } }
    try { $p.Kill() } catch { }
}
# _pipe_id STREAM -> "pipe:[inode]" of a redirected stream on Linux, else ""
function Pipe-Id($stream) {
    if ($env:OS -eq "Windows_NT") { return "" }
    try {
        $h = $stream.SafePipeHandle; if (-not $h) { $h = $stream.SafeFileHandle }
        return "$((Get-Item -LiteralPath "/proc/self/fd/$($h.DangerousGetHandle().ToInt64())" -ErrorAction Stop).Target)"
    } catch { return "" }
}
# Invoke-Bounded EXE [ARGS] [SECONDS] -> stdout then stderr lines of EXE
function Invoke-Bounded([string]$exe, [string[]]$argv = @(), [int]$sec = 0) {
    $script:BoundedExit = $null
    $req = $sec; if ($req -le 0) { $req = $script:CMD_TIMEOUT }
    try { $sec = Bounded-Seconds $req } catch { Time-Log 0 "not run" $exe $argv; throw }
    $path = $exe
    if (-not (Test-Path -LiteralPath $exe)) {
        $c = @(Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($c.Count -eq 0) { throw "command not found: $exe" }
        $path = $c[0].Source; if (-not $path) { $path = $c[0].Path }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $path
    $psi.Arguments = (@($argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $t0 = [DateTime]::UtcNow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { Time-Log $sw.ElapsedMilliseconds "ran" $exe $argv; throw }
    $pipes = @((Pipe-Id $p.StandardOutput.BaseStream), (Pipe-Id $p.StandardError.BaseStream)) | Where-Object { $_ }
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $done = $p.WaitForExit($sec * 1000)
    if ($done) {
        # the pipes close when every holder exits; a background child can keep
        # them open after the process itself is gone
        $rem = [int][Math]::Max(0, $sec * 1000 - ([DateTime]::UtcNow - $t0).TotalMilliseconds)
        $done = $o.Wait($rem) -and $e.Wait([int][Math]::Max(0, $sec * 1000 - ([DateTime]::UtcNow - $t0).TotalMilliseconds))
    }
    if (-not $done) {
        Stop-Tree $p $pipes
        Time-Log $sw.ElapsedMilliseconds (Cap-Kind $sec $req) $exe $argv
        Bounded-Timeout $sec
    }
    Time-Log $sw.ElapsedMilliseconds "ran" $exe $argv
    if ($p.ExitCode -ne 0) { $script:BoundedExit = $p.ExitCode }
    $text = ($o.Result + $e.Result) -replace "`r", ""
    if ($text -eq "") { return @() }
    return @($text.TrimEnd("`n") -split "`n")
}
# Invoke-BoundedBlock { cmdlets } [SECONDS] -> the block's output. The block
# runs in a fresh runspace: it sees only its own text (pass values with
# $using-free literals or -ArgumentList via $args), not this script's functions.
function Invoke-BoundedBlock([scriptblock]$sb, [object[]]$argList = @(), [int]$sec = 0) {
    $req = $sec; if ($req -le 0) { $req = $script:CMD_TIMEOUT }
    $name = Block-Cmd $sb
    try { $sec = Bounded-Seconds $req } catch { Time-Log 0 "not run" $name; throw }
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $kind = "ran"
    $ps = [PowerShell]::Create()
    try {
        $null = $ps.AddScript($sb.ToString())
        foreach ($a in $argList) { $null = $ps.AddArgument($a) }
        $h = $ps.BeginInvoke()
        if (-not $h.AsyncWaitHandle.WaitOne($sec * 1000)) {
            # stop it; dispose only once the stop has landed, since disposing a
            # pipeline that does not stop would block the run
            $stopped = $false
            try { $sh = $ps.BeginStop($null, $null); $stopped = $sh.AsyncWaitHandle.WaitOne(2000) } catch { }
            if (-not $stopped) { $ps = $null }
            $kind = Cap-Kind $sec $req
            Bounded-Timeout $sec
        }
        try { $out = $ps.EndInvoke($h) }
        catch {
            # an -ErrorAction Stop error arrives wrapped; report its own message
            $x = $_.Exception
            while ($x.InnerException) { $x = $x.InnerException }
            if ($x.ErrorRecord) { throw $x.ErrorRecord.Exception.Message.Split("`n")[0] }
            throw $x.Message.Split("`n")[0]
        }
        if ($ps.Streams.Error.Count -gt 0 -and $out.Count -eq 0) { throw "$($ps.Streams.Error[0])".Split("`n")[0] }
        return @($out)
    } finally {
        if ($ps) {
            try { $rs = $ps.Runspace; $ps.Dispose(); if ($rs) { $rs.Dispose() } } catch { }
        }
        Time-Log $sw.ElapsedMilliseconds $kind $name
    }
}
# Get-CimBounded CLASS [FILTER] [SECONDS] -> the instances of a CIM class, the
# query limited by -OperationTimeoutSec, skipped past the deadline, and timed.
# A query that fails once its time is up throws "timed out: Ns" like the others.
# Fail fast: once WMI has refused this run ("Access denied") before any query
# of it succeeded, later queries throw the same refusal without asking again;
# a refusal after a success is that class's own (Win32_Service is refused to
# a not elevated local logon that reads every other class). A non-administrator
# logged on over OpenSSH (a network logon) waited 5 s for each refusal, 25 s of
# a 36 s run, while the same account in a local logon read every class (0.4.0,
# Windows Server 2022). The first query is the probe below.
$script:CimDenied = ""; $script:CimOk = $false
function Get-CimBounded([string]$class, [string]$filter = "", [int]$sec = 0) {
    if ($script:CimDenied) { throw "$($script:CimDenied) (WMI refused this run earlier; not asked again)" }
    $req = $sec; if ($req -le 0) { $req = $script:CMD_TIMEOUT }
    try { $sec = Bounded-Seconds $req } catch { Time-Log 0 "not run" "Get-CimInstance" @($class); throw }
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $kind = "ran"
    try {
        $a = @{ ClassName = $class; OperationTimeoutSec = $sec; ErrorAction = 'Stop' }
        if ($filter) { $a.Filter = $filter }
        $r = @(Get-CimInstance @a); $script:CimOk = $true
        return $r
    } catch {
        $m = "$($_.Exception.Message)".Split("`n")[0].Trim()
        if ($_.Exception -is [System.UnauthorizedAccessException] -or $m -match '^Access (is )?denied') { if (-not $script:CimOk) { $script:CimDenied = $m }; throw $m }
        if ($sw.ElapsedMilliseconds -ge [long]$sec * 1000 - 250) { $kind = Cap-Kind $sec $req; Bounded-Timeout $sec }
        throw
    } finally { Time-Log $sw.ElapsedMilliseconds $kind "Get-CimInstance" @($class) }
}

# Host-Load -> one line, the Windows counterpart of the shell _host_load: CPU
# busy, processor queue length, disk queue length, available memory. Read at
# the start and, when Emit-Status names slow calls, at the end. CIM reads of
# raw counters, which cost tens of milliseconds each:
#   Win32_PerfRawData_PerfOS_Processor(_Total).PercentProcessorTime, read twice
#     250 ms apart: busy = 100 * (1 - d(idle ticks) / d(Timestamp_Sys100NS)).
#     Not Win32_Processor.LoadPercentage: WMI samples each processor for about
#     a second in turn, and on a 4-vCPU Windows Server 2022 VM one read took
#     4.2-5.5 s, used up the shared budget and left every field n/a (0.5.0);
#   Win32_PerfRawData_PerfOS_System.ProcessorQueueLength and
#   Win32_PerfRawData_PerfDisk_PhysicalDisk(_Total).CurrentDiskQueueLength,
#     raw gauges, so the raw class is exact and skips the formatted class's
#     cooking;
#   Win32_OperatingSystem.FreePhysicalMemory (the Available MBytes counter's
#     value) of TotalVisibleMemorySize.
# CIM class names are not localized; Get-Counter paths are, and fail on a
# non-English Windows. The reads share 4 seconds; what is left after that is n/a.
function Host-Load {
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return "n/a (Get-CimInstance is not available in this runtime)" }
    if ($script:CimDenied) { return "n/a ($($script:CimDenied): WMI refused this run)" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $q = {
        param($class, $filter)
        $left = 4 - [int][Math]::Floor($sw.Elapsed.TotalSeconds)
        if ($left -le 0 -or $script:CimDenied) { return $null }
        $a = @{ ClassName = $class; OperationTimeoutSec = $left; ErrorAction = 'Stop' }
        if ($filter) { $a.Filter = $filter }
        try { return @(Get-CimInstance @a) } catch { return $null }
    }
    $parts = @()
    $c0 = & $q "Win32_PerfRawData_PerfOS_Processor" "Name='_Total'"
    if ($c0) { Start-Sleep -Milliseconds 250 }
    $c1 = $(if ($c0) { & $q "Win32_PerfRawData_PerfOS_Processor" "Name='_Total'" } else { $null })
    $busy = "cpu busy n/a"
    if ($c0 -and $c1) {
        $dt = [double]@($c1)[0].Timestamp_Sys100NS - [double]@($c0)[0].Timestamp_Sys100NS
        $di = [double]@($c1)[0].PercentProcessorTime - [double]@($c0)[0].PercentProcessorTime
        if ($dt -gt 0) { $busy = "cpu busy {0}% (250 ms sample)" -f [int][Math]::Round([Math]::Min(100, [Math]::Max(0, 100 * (1 - $di / $dt)))) }
    }
    $parts += $busy
    $r = & $q "Win32_PerfRawData_PerfOS_System" ""
    $parts += $(if ($r) { "processor queue $(@($r)[0].ProcessorQueueLength)" } else { "processor queue n/a" })
    $r = & $q "Win32_PerfRawData_PerfDisk_PhysicalDisk" "Name='_Total'"
    $parts += $(if ($r) { "disk queue $(@($r)[0].CurrentDiskQueueLength)" } else { "disk queue n/a" })
    $r = & $q "Win32_OperatingSystem" ""
    $parts += $(if ($r) { "mem available {0} of {1} MiB" -f [int64][Math]::Floor(@($r)[0].FreePhysicalMemory / 1024), [int64][Math]::Floor(@($r)[0].TotalVisibleMemorySize / 1024) } else { "mem n/a" })
    return ($parts -join "; ")
}
# Cim-Probe: one Win32_OperatingSystem read before anything else asks WMI,
# with room for WMI's refusal of a network logon (about 5 s; the host load's
# 4 s ran out first and said "Timed out", 0.5.0 lab check). A refusal of this
# basic class is WMI refusing the logon, so later CIM reads fail at once; a
# host that refuses only some classes is not affected. The instance is kept
# for the boot time, so the probe costs no extra round trip.
$script:CimOS = $null
if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    try { $script:CimOS = @(Get-CimBounded Win32_OperatingSystem "" 10)[0] } catch { }
}
$script:Load0 = Host-Load

# Priv-Hint -> " (not elevated: <gap>)", or "" when the run is elevated. Append
# it to the reason of any goal that the missing elevation blocked, as the shell
# collectors do with _priv_hint. $PRIV_GAP is set by the privilege line in [1].
$script:PRIV_GAP = ""
function Priv-Hint { if ($script:PRIV_GAP) { return " (not elevated: $($script:PRIV_GAP))" } return "" }

# Note-Boot -> the two boot facts of [1], worded as the shell _note_boot. Most
# of what a report carries is cumulative since boot; without the boot time it
# has no denominator. Win32_OperatingSystem first; where CIM is absent (pwsh on
# Linux) the monotonic tick count since boot, which .NET Core exposes as
# TickCount64 (Windows PowerShell 5.1 has only the 32-bit TickCount, which
# wraps after 24.9 days, so it is not used).
function Note-Boot {
    $boot = $null; $why = ""
    try { $boot = $(if ($script:CimOS) { $script:CimOS.LastBootUpTime } else { (Get-CimBounded Win32_OperatingSystem).LastBootUpTime }) }
    catch { $why = $_.Exception.Message.Split("`n")[0] }
    $now = (Get-Date).ToUniversalTime()
    if ($boot) {
        $b = $boot.ToUniversalTime()
        Fact ("host boot(UTC): " + $b.ToString("yyyy-MM-ddTHH:mm:ssZ"))
        Fact ("host uptime(s): " + [int64][Math]::Floor(($now - $b).TotalSeconds))
        return
    }
    $ms = $null
    try { $ms = [Environment]::TickCount64 } catch { $ms = $null }
    if ($null -ne $ms -and $ms -gt 0) {
        $up = [int64][Math]::Floor($ms / 1000)
        Fact ("host boot(UTC): " + $now.AddSeconds(-$up).ToString("yyyy-MM-ddTHH:mm:ssZ"))
        Fact ("host uptime(s): " + $up)
    } else {
        Fact "host boot(UTC): n/a (Win32_OperatingSystem not readable: $why)"
        Fact "host uptime(s): n/a (Win32_OperatingSystem not readable, no TickCount64 in this runtime)"
    }
}
# ---- end ps1: run helpers

# ---- ps1: completeness — DO NOT EDIT -----------------------------------------
# members: apmdotnet db-mssql
# The port of the shell block "collection completeness". Keep the two in step:
# the same three outcomes, the same lines, the same rules.
#
# A collector knows, at the host, whether it obtained what it came for. Saying
# so is a fact about THIS RUN, not a claim about the environment (CONTRACT rule
# 1, "Saying whether the collection worked"). Set-Na when the absence IS the
# answer and every input behind it was read; Set-Missed when this run was
# blocked (a permission, a missing tool, a failed or refused call). Only
# Set-Missed makes a run INCOMPLETE.
#
# Declare a goal once, resolve it exactly once, after the last fallback. A goal
# left unresolved is blocked with "not reached". A goal resolved twice with
# different outcomes is blocked and says "resolved N times: ...", because the
# second call usually hides the first. A resolution of an undeclared goal is
# listed. A requested opt-in is a goal; an unrequested one is not.
$script:Goals = [ordered]@{}   # key -> label
$script:Res   = New-Object System.Collections.Generic.List[object]   # {k; o; r} per resolution

function Add-Goal([string]$key, [string]$label) { if (-not $script:Goals.Contains($key)) { $script:Goals[$key] = (Flat $label) } }
# tabs and newlines inside a reason are flattened, as the shell _flat does
function Flat([string]$s) { return ($s -replace "[`t`r`n]", " ") }
function Set-Got([string]$key)                  { $script:Res.Add([pscustomobject]@{ k = $key; o = "got"; r = "" }) }
function Set-Na([string]$key, [string]$why)     { $script:Res.Add([pscustomobject]@{ k = $key; o = "na"; r = (Flat $why) }) }
function Set-Missed([string]$key, [string]$why) { $script:Res.Add([pscustomobject]@{ k = $key; o = "missed"; r = (Flat $why) }) }

# Emit-Time -> the run time; when a call was slow (SLOW_SEC), capped or not
# run, also the host load at start and end, the counts, and each such call as
# the time log has it (ms, outcome, command), in the order they happened. No
# sums or sorting (CONTRACT.md, rule 1). The lines are the shell _emit_time's.
function Emit-Time {
    Fact ("run time: {0}s of {1}s allowed" -f [int][Math]::Floor(([DateTime]::UtcNow - $script:RunStart).TotalSeconds), $script:RUN_DEADLINE)
    $log = $script:TimeLog.ToArray()
    if ($log.Count -eq 0) { return }
    $capped = @($log | Where-Object { $_.kind -match '^(capped|cut)' }).Count
    $notrun = @($log | Where-Object { $_.kind -eq "not run" }).Count
    $slow   = @($log | Where-Object { $_.kind -ne "not run" -and $_.ms -ge $script:SLOW_SEC * 1000 }).Count
    if ($capped -eq 0 -and $notrun -eq 0 -and $slow -eq 0) { return }
    Fact ("host load at start: " + $(if ($script:Load0) { $script:Load0 } else { "n/a" }))
    Fact ("host load at end:   " + (Host-Load))
    Fact ("bounded calls: {0}; stopped at their cap or the deadline: {1}; not run past the deadline: {2}" -f $log.Count, $capped, $notrun)
    Fact ("bounded calls that were slow ({0}s+), stopped or not run, in order (ms, outcome, command):" -f $script:SLOW_SEC)
    $k = 0
    foreach ($e in $log) {
        if ($e.kind -eq "ran" -and $e.ms -lt $script:SLOW_SEC * 1000) { continue }
        $k++
        if ($k -le 40) { Fact ("    {0} ms  {1}  {2}" -f $e.ms, $e.kind, $e.name) }
    }
    if ($k -gt 40) { Fact ("    ({0} more in this run)" -f ($k - 40)) }
}

function Emit-Status {
    if ($script:Goals.Count -eq 0) { return }
    $total = $script:Goals.Count
    $oks = @(); $nas = @(); $gaps = @()
    foreach ($k in $script:Goals.Keys) {
        $lab  = $script:Goals[$k]
        $mine = @($script:Res | Where-Object { $_.k -eq $k })
        $outs = @($mine | ForEach-Object { $_.o })
        $kinds = @($outs | Select-Object -Unique)
        if ($outs.Count -gt 0 -and $kinds.Count -eq 1 -and $kinds[0] -eq "got") { $oks += $lab; continue }
        if ($outs.Count -gt 0 -and $kinds.Count -eq 1 -and $kinds[0] -eq "na") { $nas += ("{0} - {1}" -f $lab, $mine[0].r); continue }
        $why = (@($mine | Where-Object { $_.o -eq "missed" } | ForEach-Object { $_.r }) -join "; ")
        if ($outs.Count -eq 0) { $why = "not reached" }
        elseif ($kinds.Count -gt 1) {
            $w = "resolved {0} times: {1}" -f $outs.Count, ($outs -join ", ")
            if ($why) { $w += " - $why" }
            $why = $w
        }
        $gaps += ("{0} - {1}" -f $lab, $why)
    }
    $deadline = Past-Deadline
    $stray = @($script:Res | ForEach-Object { $_.k } | Where-Object { -not $script:Goals.Contains($_) } | Select-Object -Unique)
    Section "Collection status"
    Fact ("goals: {0} declared, {1} obtained, {2} not applicable here, {3} blocked" -f $total, $oks.Count, $nas.Count, $gaps.Count)
    if ($oks.Count -gt 0) { Fact ("obtained: " + ($oks -join ", ")) }
    if ($nas.Count -gt 0) {
        Fact "not applicable to this host (this is an answer, not a gap):"
        foreach ($l in $nas) { Fact ("    " + $l) }
    }
    if ($stray.Count -gt 0) { Fact ("resolved but never declared: " + ($stray -join ", ")) }
    if ($deadline) { Fact ("run deadline: reached at {0}s; commands after it were not run" -f $script:RUN_DEADLINE) }
    Emit-Time
    if ($gaps.Count -eq 0 -and -not $deadline) {
        Fact "status: COMPLETE"
        $suffix = if ($nas.Count -gt 0) { " ({0} not applicable to this host)" -f $nas.Count } else { "" }
        Notice ("status: COMPLETE - nothing was blocked" + $suffix)
    } else {
        if ($gaps.Count -gt 0) {
            Fact "blocked (running this differently would obtain these):"
            foreach ($l in $gaps) { Fact ("    " + $l) }
        }
        Fact "status: INCOMPLETE"
        Notice (("status: INCOMPLETE - {0} of {1} goals blocked" -f $gaps.Count, $total) + $(if ($deadline) { ", run deadline reached" } else { "" }))
        foreach ($l in $gaps) { Notice ("  " + $l) }
    }
}
# ---- end ps1: completeness

# ---- ps1: fact helpers — DO NOT EDIT -----------------------------------------
# members: apmdotnet db-mssql
function FactBlock([string]$label, $body) {
    $arr = @($body | Where-Object { $_ -ne $null } | ForEach-Object { "$_" })
    if ($arr.Count -eq 0 -or ($arr.Count -eq 1 -and $arr[0].Trim() -eq "")) { Fact "${label}: n/a (empty output)"; return }
    if ($arr.Count -eq 1) { Fact "${label}: $($arr[0])" }
    else {
        Fact "${label}:"
        $arr | ForEach-Object { Emit ("        " + $_) }
    }
}
function TryFact([string]$label, [scriptblock]$sb) {
    if (Past-Deadline) { Log-NotRun $sb; Fact "${label}: n/a (run deadline reached: $($script:RUN_DEADLINE)s)"; return }
    $script:BoundedExit = $null
    try {
        $r = & $sb
        $l = $label; if ($null -ne $script:BoundedExit) { $l = "$label (exit $($script:BoundedExit))" }
        FactBlock $l $r
    }
    catch {
        $m = $_.Exception.Message.Split("`n")[0]
        if ($m -match '^(timed out: |run deadline reached: |command not found: )') { Fact "${label}: n/a ($m)" }
        else { Fact "${label}: n/a (error: $m)" }
    }
}
# Read-Lines PATH -> the file's lines, decoded as UTF-8 (a BOM is dropped),
# else, when the bytes are not valid UTF-8, in the ANSI code page, with
# $script:ReadNote saying so. Not Get-Content's default: Windows PowerShell 5.1
# decodes a file without a BOM in the ANSI code page, and the Korean comment of
# a BOM-less UTF-8 whatap.conf arrived garbled in the verbatim dump (0.5.0 lab
# check). Reads at most 1 MiB, the size of no conf file.
$script:ReadNote = ""
function Read-Lines([string]$path) {
    $script:ReadNote = ""
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $len = [int][Math]::Min($fs.Length, 1048576)
        $b = New-Object byte[] $len; $got = 0
        while ($got -lt $len) { $n = $fs.Read($b, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
        if ($fs.Length -gt $len) { $script:ReadNote = "first 1 MiB read" }
    } finally { $fs.Close() }
    $off = 0; if ($got -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $off = 3 }
    try { $txt = (New-Object System.Text.UTF8Encoding $false, $true).GetString($b, $off, $got - $off) }
    catch {
        # the ANSI code page of the current culture, not Encoding.Default,
        # which is UTF-8 under pwsh 7 (a cp1252 "caf\xE9" came out "caf?");
        # .NET Core has the legacy code pages only through CodePagesEncodingProvider
        $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
        try { $enc = [System.Text.Encoding]::GetEncoding($cp) } catch { $enc = [System.Text.Encoding]::GetEncoding(28591); $cp = 28591 }
        $txt = $enc.GetString($b, 0, $got)
        $script:ReadNote = (@($script:ReadNote, "not valid UTF-8, read in code page $cp") | Where-Object { $_ }) -join "; "
    }
    if ($txt -eq "") { return }
    return ($txt.TrimEnd("`r", "`n") -split "`r`n|`n|`r")
}
function ConfGet([string]$path, [string]$key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $m = Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue |
         Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -Last 1
    if ($m) { return ($m -split '=', 2)[1].Trim() }
    return $null
}
# TcpProbe: one TCP connect, bounded like any other call. It is timed and
# logged as "tcp-connect", honours RUN_DEADLINE, and a connect that gets no
# answer is logged as capped: two unanswered probes spent 10 s of a 16 s run
# outside every other log line (0.4.0, Windows Server 2022 lab host). An
# endpoint is probed once per run; a second conf naming it gets the first
# answer (Windows retries a refused connect, about 2 s each).
$script:TcpSeen = @{}
function TcpProbe([string]$label, [string]$dsthost, [int]$port, [int]$timeoutSec = 5) {
    if (-not $dsthost -or -not $port) { Fact "${label}: n/a (not applicable: host/port not set)"; return }
    $key = "${dsthost}:$port".ToLowerInvariant()
    if ($script:TcpSeen.ContainsKey($key)) { Fact "${label}: $($script:TcpSeen[$key]) (probed once above)"; return }
    $req = $timeoutSec
    try { $timeoutSec = Bounded-Seconds $req } catch { Time-Log 0 "not run" "tcp-connect"; Fact "${label}: tcp connect to ${dsthost}:$port n/a ($($_.Exception.Message))"; return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $kind = "ran"
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.BeginConnect($dsthost, $port, $null, $null)
        if (-not $t.AsyncWaitHandle.WaitOne($timeoutSec * 1000)) {
            $kind = Cap-Kind $timeoutSec $req
            $r = "tcp connect to ${dsthost}:$port did not connect within ${timeoutSec}s"
        } else {
            $c.EndConnect($t)
            $r = "tcp connect to ${dsthost}:$port succeeded"
        }
    } catch {
        $x = $_.Exception; while ($x.InnerException) { $x = $x.InnerException }
        $r = "tcp connect to ${dsthost}:$port did not connect ($($x.Message.Split("`n")[0]))"
    } finally { $c.Close(); Time-Log $sw.ElapsedMilliseconds $kind "tcp-connect" }
    $script:TcpSeen[$key] = $r
    Fact "${label}: $r"
}
# ---- end ps1: fact helpers

# ---- reasoned-absence helpers -------------------------------------------------
# Path-State PATH -> "present", "absent", or "denied" when the run may not look
# (Test-Path answers $false and writes an error for a path under a directory
# this account cannot list, which read as "path not found": 0.4.0 said that of
# applicationHost.config for a not elevated run)
function Path-State([string]$p) {
    try { if (Test-Path -LiteralPath $p -ErrorAction Stop) { return "present" } return "absent" }
    catch { if ($_.Exception -is [System.UnauthorizedAccessException] -or "$($_.Exception.Message)" -match 'denied') { return "denied" } return "absent" }
}
# DumpFile: verbatim, line-capped. Framework policy: configuration is dumped
# verbatim, never masked (see README security note).
function DumpFile([string]$label, [string]$path, [int]$max = 400) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $content = @(Read-Lines $path)
        if ($content.Count -eq 0) { Fact "${label}: (empty file)"; return }
        $more = ""
        if ($content.Count -gt $max) { $content = $content[0..($max-1)]; $more = " (first $max lines, truncated)" }
        if ($script:ReadNote) { $more += " ($($script:ReadNote))" }
        Fact "$label (verbatim$more):"
        $content | ForEach-Object { Emit ("        " + $_) }
    } catch { Fact "${label}: n/a (unreadable: $path -- $($_.Exception.Message.Split("`n")[0]))" }
}
function TailFile([string]$label, [string]$path, [int]$n = 150) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $t = @(Get-Content -LiteralPath $path -Tail $n -Encoding UTF8 -ErrorAction Stop)
        if ($t.Count -eq 0) { Fact "${label}: (empty file)"; return }
        Fact "$label (last $($t.Count) lines):"
        $t | ForEach-Object { Emit ("        " + $_) }
    } catch { Fact "${label}: n/a (unreadable: $path -- $($_.Exception.Message.Split("`n")[0]))" }
}
function HeadFile([string]$label, [string]$path, [int]$n = 60) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $t = @(Get-Content -LiteralPath $path -TotalCount $n -Encoding UTF8 -ErrorAction Stop)
        if ($t.Count -eq 0) { Fact "${label}: (empty file)"; return }
        Fact "$label (first $($t.Count) lines):"
        $t | ForEach-Object { Emit ("        " + $_) }
    } catch { Fact "${label}: n/a (unreadable: $path -- $($_.Exception.Message.Split("`n")[0]))" }
}
# FileFacts: existence, size, mtime, FileVersion/ProductVersion, SHA256.
# FileVersion is emitted even though WhaTap builds pin it at 1.0.0.0 -- the
# pinned value is itself a fact, and third-party DLLs carry real versions.
function FileFacts([string]$label, [string]$path, [switch]$Hash) {
    if (-not $path) { Fact "${label}: n/a (no path)"; return }
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: not present ($path)"; return }
    try {
        $fi = Get-Item -LiteralPath $path -ErrorAction Stop
        $v = $fi.VersionInfo
        $line = "$path  size=$($fi.Length)  mtime=$($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        if ($v -and $v.FileVersion) { $line += "  FileVersion=$($v.FileVersion)  ProductVersion=$($v.ProductVersion)" }
        Fact "${label}: $line"
        if ($Hash) {
            try { Fact "${label} sha256: $((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash)" }
            catch { Fact "${label} sha256: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
        }
    } catch { Fact "${label}: n/a (unreadable: $path)" }
}
# AsmFacts: managed assembly identity via metadata-only read (no code runs).
function AsmFacts([string]$label, [string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: not present ($path)"; return }
    $fi = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    $av = "n/a"
    try { $av = [System.Reflection.AssemblyName]::GetAssemblyName($path).Version.ToString() }
    catch { $av = "(native or non-.NET image)" }
    Fact "${label}: AssemblyVersion=$av  FileVersion=$($fi.VersionInfo.FileVersion)  size=$($fi.Length)  mtime=$($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}
# ConfBytes: byte-level facts a text dump hides (BOM, CR count, size).
function ConfBytes([string]$label, [string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $first = ($bytes | Select-Object -First 3 | ForEach-Object { $_.ToString("X2") }) -join " "
        $cr = @($bytes | Where-Object { $_ -eq 13 }).Count
        Fact "${label}: size $($bytes.Length) bytes, first bytes: $first, CR (0x0D) bytes: $cr"
    } catch { Fact "${label}: n/a (unreadable: $path)" }
}
function OwnerOf([string]$path) {
    try { return (Get-Acl -LiteralPath $path -ErrorAction Stop).Owner } catch { return "owner n/a" }
}
# Reg-Open "HKLM:\..." | "HKCU:\..." -> a read-only RegistryKey, or $null when
# the key does not exist; throws when it exists but cannot be opened. The .NET
# registry API, not Test-Path / Get-ItemProperty: on Windows Server 2022 the
# registry provider took 1.2-1.5 s to answer for each absent key under
# HKLM:\SOFTWARE\Classes, and the six CLSID reads cost 8 s of a 22 s run on a
# host without the agent (0.4.0). The key's owner closes it.
function Reg-Open([string]$key) {
    if ($key -notmatch '^(HKLM|HKCU):\\(.*)$') { throw "unsupported registry path: $key" }
    $hive = if ($Matches[1] -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    if (-not $hive) { throw "no Windows registry in this runtime" }
    return $hive.OpenSubKey($Matches[2], $false)
}
# RegValue: one registry value with reasoned absence. "(default)" names the
# key's unnamed value.
function RegValue([string]$label, [string]$key, [string]$name) {
    $k = $null
    try { $k = Reg-Open $key } catch { Fact "${label}: n/a (error: $($_.Exception.Message.Split("`n")[0]))"; return }
    if (-not $k) { Fact "${label}: n/a (registry key not found: $key)"; return }
    try {
        $vn = if ($name -eq '(default)') { '' } else { $name }
        if (-not (@($k.GetValueNames()) -contains $vn)) { Fact "${label}: not set (key present: $key)"; return }
        $v = $k.GetValue($vn)
        if ($v -is [System.Array]) { FactBlock $label $v } else { Fact "${label}: $v" }
    } catch { Fact "${label}: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
    finally { $k.Close() }
}

# ---- constants from the dotnet-apm source (installer release.iss) -------------
# env vars are the discovery source; the literal fallbacks below only engage
# when an env var is unset (never the case on a standard Windows host) and
# then merely produce "path not found" facts instead of null-path errors.
$WinDir = $env:windir; if (-not $WinDir) { $WinDir = "C:\Windows" }
$ProgData = $env:ProgramData; if (-not $ProgData) { $ProgData = [Environment]::GetFolderPath('CommonApplicationData') }
if (-not $ProgData) { $ProgData = "C:\ProgramData" }
$ProgFiles = $env:ProgramFiles; if (-not $ProgFiles) { $ProgFiles = "C:\Program Files" }
$CLSID_CURRENT = "{21CAE18A-4E44-4578-83FD-0576AAA47E68}"   # unified profiler, 2.5.x line
$CLSID_LEGACY  = "{D76F1D76-A9E0-4C87-874F-C0AD93D4229B}"   # legacy 450/core line
# string concatenation, not Join-Path: Join-Path validates the drive letter
# and throws where the drive is absent; these constants must never throw
$PROGDATA_LOGS = "$ProgData\WhaTap\dotnet\logs"
$PROGDATA_AUDIT = "$ProgData\WhaTap\dotnet\audit"
$MACHINE_ENV_KEY = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
$ENV_NAME_PATTERN = '^(WHATAP_|COR_ENABLE_PROFILING|COR_PROFILER|CORECLR_|DOTNET_STARTUP_HOOKS|WT_TRACE_LOG_PATH|MicrosoftInstrumentationEngine_)'

# ---- discovery: agent home candidates ------------------------------------------
$homeCandidates = New-Object System.Collections.Generic.List[string]
# A discovery read that failed (not one whose key is simply absent) means an
# empty candidate list is not an answer; the agent goal is then missed.
$script:DiscErr = @(); $script:DiscDenied = $false
function Note-DiscErr([string]$what, $err) {
    if ($err.Exception -is [System.Management.Automation.ItemNotFoundException]) { return }
    if ($err.Exception -is [System.UnauthorizedAccessException] -or $err.Exception -is [System.Security.SecurityException] -or
        "$($err.Exception.Message)" -match 'denied|not allowed') { $script:DiscDenied = $true }
    $script:DiscErr += ("{0}: {1}" -f $what, $err.Exception.Message.Split("`n")[0])
}
function AddHome([string]$p, [string]$src) {
    if (-not $p) { return }
    $p = $p.Trim('"').TrimEnd('\')
    if (-not $p) { return }
    foreach ($e in $homeCandidates) { if ($e -ieq "$p|$src") { return } }
    foreach ($e in $homeCandidates) { if (($e -split '\|', 2)[0] -ieq $p) { return } }
    $homeCandidates.Add("$p|$src")
}
$homeBad = @()
foreach ($h in $AgentHome) { AddHome $h "parameter -AgentHome"; if (-not (Test-Path -LiteralPath $h)) { $homeBad += $h } }
if ($env:WHATAP_DOTNET_HOME) { AddHome $env:WHATAP_DOTNET_HOME "collector process env WHATAP_DOTNET_HOME" }
try {
    $me = Get-ItemProperty -LiteralPath $MACHINE_ENV_KEY -ErrorAction Stop
    if ($me.WHATAP_DOTNET_HOME) { AddHome $me.WHATAP_DOTNET_HOME "machine env registry WHATAP_DOTNET_HOME" }
} catch { Note-DiscErr "machine env registry" $_ }
# Home-Of FILE -> the agent home a profiler or startup-hook path names: the
# directory above its core\ / net6.0\ / net461\ folder, however deep the file
# sits below it (core\x86\Whatap.ClrProfiler.dll), else the parent of its
# parent. Parent-of-parent alone made ...\WhaTap .NET\core a second home
# from a COR_PROFILER_PATH_32 under core\x86 (0.4.0, seen on a lab host).
function Home-Of([string]$f) {
    $f = $f.Trim('"')
    if ($f -match '^(.+?)\\(core|net6\.0|net461)\\') { return $Matches[1] }
    return (Split-Path -Parent (Split-Path -Parent $f))
}
# service-env profiler paths -> the home of ...\core\Whatap.ClrProfiler.dll
$svcEnvLines = @()
foreach ($svc in @("W3SVC", "WAS")) {
    try {
        $v = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -ErrorAction Stop).Environment
        if ($v) { $svcEnvLines += @($v) }
    } catch { Note-DiscErr "$svc service registry" $_ }
}
foreach ($line in $svcEnvLines) {
    if ($line -match '^(COR_PROFILER_PATH|CORECLR_PROFILER_PATH)(_32|_64)?=(.+)$') {
        $d = Home-Of $Matches[3]
        AddHome $d "service env profiler path"
    }
    if ($line -match '^DOTNET_STARTUP_HOOKS=(.+)$') {
        $d = Home-Of $Matches[1]
        AddHome $d "service env DOTNET_STARTUP_HOOKS"
    }
}
# CLSID InProcServer32 -> same parent-of-parent rule
foreach ($ck in @("HKLM:\SOFTWARE\Classes\CLSID\$CLSID_CURRENT\InProcServer32",
                  "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$CLSID_CURRENT\InProcServer32")) {
    try {
        $k = Reg-Open $ck
        if ($k) {
            $v = $k.GetValue(''); $k.Close()
            if ($v) { AddHome (Home-Of $v) "CLSID InProcServer32" }
        }
    } catch { Note-DiscErr "CLSID registry" $_ }
}
# uninstall registry InstallLocation
$uninstallEntries = @(); $uninstallAll = @(); $uninstallRead = 0
foreach ($uk in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                  "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")) {
    try {
        $entries = @(Get-ChildItem -LiteralPath $uk -ErrorAction Stop | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName) { $p | Add-Member NoteProperty RegPath $_.PSPath -PassThru }
        } | Where-Object { $_ })
        $uninstallAll += $entries
        $uninstallEntries += @($entries | Where-Object { $_.DisplayName -match '[Ww]ha[Tt]ap' })
        if ($uk -like "HKLM:*") { $uninstallRead++ }
    } catch { Note-DiscErr "uninstall registry $uk" $_ }
}
foreach ($u in $uninstallEntries) { if ($u.InstallLocation) { AddHome $u.InstallLocation "uninstall registry InstallLocation" } }
# installer defaults (release.iss DefaultDirName; debug variant; x86 sibling)
AddHome "$ProgFiles\WhaTap .NET" "installer default"
if (${env:ProgramFiles(x86)}) { AddHome "${env:ProgramFiles(x86)}\WhaTap .NET" "installer default (x86 copy)" }
AddHome "$ProgFiles\WhaTap .NET Debug" "debug installer default"

# w3wp / dotnet / whatap process inventory (used by several sections)
$procW3wp = @(); $procDotnet = @(); $procWhatap = @()
try {
    $allProc = @(Get-CimBounded Win32_Process)
    $procW3wp   = @($allProc | Where-Object { $_.Name -ieq 'w3wp.exe' })
    $procDotnet = @($allProc | Where-Object { $_.Name -ieq 'dotnet.exe' })
    $procWhatap = @($allProc | Where-Object { $_.Name -imatch 'whatap' })
} catch { $allProc = $null; $procErr = $_.Exception.Message.Split("`n")[0].Trim() }

# ---- report --------------------------------------------------------------------
Emit "==== WhaTap Global Groundtruth Collection ===="
Emit ("Collector:      {0}" -f $COLLECTOR_NAME)
Emit ("Version:        {0}" -f $VERSION)
Emit ("Timestamp(UTC): {0}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
Emit ("Domain:         {0}" -f $DOMAIN)
Emit ("Target:         {0}" -f $TARGET)
Emit "==============================================="

# What this run is for. Resolved just before Emit-Status, where the discovery
# variables are final.
Add-Goal agent "whatap .NET agent installation"
Add-Goal conf  "agent configuration"

Section "Collection environment"
Fact "collector: $COLLECTOR_NAME $VERSION"
Fact "powershell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$UserId = if ($env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { "$([Environment]::UserDomainName)\$([Environment]::UserName)" }
Fact "user: $UserId"
# The Windows port of the shell collectors' privilege line. It states one thing:
# whether this process carries an elevated token. It does not speak for any
# other authority the collection needs, and goals name their own.
#
# IsInRole is the test, not group membership. Under UAC's split token an
# unelevated process still lists Administrators, as a deny-only SID, so asking
# by membership reports an unelevated run as elevated.
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
if ($isAdmin) {
    $PRIV_WHY = "elevated ($UserId)"; $script:PRIV_GAP = ""
} else {
    $PRIV_WHY = "not elevated ($UserId)"
    $script:PRIV_GAP = "run PowerShell as Administrator"
}
Fact "privilege: $PRIV_WHY"
Note-Boot
Fact "64-bit OS: $([Environment]::Is64BitOperatingSystem)   64-bit collector process: $([Environment]::Is64BitProcess)"
TryFact "execution policy" { Get-ExecutionPolicy }
$appcmd = "$WinDir\System32\inetsrv\appcmd.exe"
Fact "appcmd.exe present: $(Test-Path -LiteralPath $appcmd) ($appcmd)"
Fact "WebAdministration module available: $([bool](Get-Module -ListAvailable -Name WebAdministration -ErrorAction SilentlyContinue))"
Fact "dotnet on PATH: $([bool](Get-Command dotnet -ErrorAction SilentlyContinue))"

Section "A. Host & platform"
TryFact "os" { $o = Get-CimBounded Win32_OperatingSystem; "$($o.Caption) $($o.Version) (build $($o.BuildNumber))" }
if ($env:PROCESSOR_ARCHITECTURE) { Fact "architecture: $env:PROCESSOR_ARCHITECTURE" }
else { TryFact "architecture (PROCESSOR_ARCHITECTURE not set; runtime OSArchitecture)" { "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" } }
TryFact "memory MB (total/free)" { $o = Get-CimBounded Win32_OperatingSystem; "{0} / {1}" -f [int]($o.TotalVisibleMemorySize/1024), [int]($o.FreePhysicalMemory/1024) }
Fact "system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') (timezone: $([TimeZoneInfo]::Local.Id))"
Fact "system time (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
RegValue "IIS version (InetStp VersionString)" "HKLM:\SOFTWARE\Microsoft\InetStp" "VersionString"
RegValue ".NET Framework 4.x Release (NDP\v4\Full)" "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Release"
RegValue ".NET Framework 4.x Version (NDP\v4\Full)" "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Version"
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    TryFact ".NET Core runtimes (dotnet --list-runtimes)" { Invoke-Bounded dotnet @("--list-runtimes") }
    TryFact ".NET SDKs (dotnet --list-sdks)" { Invoke-Bounded dotnet @("--list-sdks") }
} else {
    Fact ".NET Core runtimes: n/a (command not found: dotnet)"
    TryFact "dotnet shared framework dirs" {
        $d = Join-Path $env:ProgramFiles "dotnet\shared\Microsoft.NETCore.App"
        if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Name } else { "n/a (path not found: $d)" }
    }
}

Section "B. Agent installation on disk"
Fact "uninstall registry entries matching 'whatap': $($uninstallEntries.Count)"
foreach ($u in $uninstallEntries) {
    Fact "entry: $($u.RegPath -replace '^Microsoft\.PowerShell\.Core\\Registry::','')"
    Fact "  DisplayName=$($u.DisplayName)  DisplayVersion=$($u.DisplayVersion)  InstallDate=$($u.InstallDate)"
    Fact "  InstallLocation=$($u.InstallLocation)"
    Fact "  UninstallString=$($u.UninstallString)"
}
Emit ""
Fact "agent home candidates: $($homeCandidates.Count)"
$existingHomes = @()
foreach ($entry in $homeCandidates) {
    $p, $src = $entry -split '\|', 2
    $exists = Test-Path -LiteralPath $p
    $marker = $false
    if ($exists) {
        $marker = (Test-Path -LiteralPath (Join-Path $p "whatap.conf")) -or
                  (Test-Path -LiteralPath (Join-Path $p "whatap_dotnet.exe")) -or
                  (Test-Path -LiteralPath (Join-Path $p "core\Whatap.ClrProfiler.dll")) -or
                  ($p -imatch 'whatap')
    }
    Fact "candidate: $p (from: $src) exists: $exists agent-markers: $marker"
    if ($exists -and $marker) { $existingHomes += $p }
}
foreach ($h in $existingHomes) {
    Emit ""; Emit "    -- home: $h --"
    TryFact "top-level entries" {
        $es = @(Get-ChildItem -LiteralPath $h -ErrorAction Stop)
        if ($es.Count -eq 0) { "no entries" }
        $es | ForEach-Object {
            $t = "{0}  {1}  {2}" -f $_.Name, $(if ($_.PSIsContainer) { "<dir>" } else { $_.Length }), $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            $t
        }
    }
    FileFacts "whatap_dotnet.exe (relay service binary)" (Join-Path $h "whatap_dotnet.exe")
    FileFacts "native profiler (core\Whatap.ClrProfiler.dll)" (Join-Path $h "core\Whatap.ClrProfiler.dll") -Hash
    foreach ($sub in @("core", "net461", "net6.0")) {
        $d = Join-Path $h $sub
        if (Test-Path -LiteralPath $d) {
            TryFact "$sub\ inventory (name size mtime FileVersion)" {
                $fs = @(Get-ChildItem -LiteralPath $d -File -ErrorAction Stop)
                if ($fs.Count -eq 0) { "no files" }
                $fs | ForEach-Object {
                    "{0}  {1}  {2}  {3}" -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $_.VersionInfo.FileVersion
                }
            }
        } else { Fact "${sub}\: not present" }
    }
    foreach ($fa in @("System.Net.Http.dll", "System.IO.Compression.dll", "System.Runtime.CompilerServices.Unsafe.dll", "System.Diagnostics.DiagnosticSource.dll", "System.Memory.dll")) {
        $p = Join-Path $h "net461\$fa"
        if (Test-Path -LiteralPath $p) { AsmFacts "net461 facade $fa" $p }
    }
    DumpFile "perfcounter.json" (Join-Path $h "perfcounter.json") 60
    FileFacts "VERSION file" (Join-Path $h "VERSION")
    if (Test-Path -LiteralPath (Join-Path $h "VERSION")) { HeadFile "VERSION content" (Join-Path $h "VERSION") 3 }
    TryFact "whatap_isapi_filter.dll under home (depth 3)" {
        $hits = @(Invoke-BoundedBlock { param($d) Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter "whatap_isapi_filter.dll" -ErrorAction SilentlyContinue } @($h) | Select-Object -First 3)
        if ($hits.Count -eq 0) { "not present" } else { $hits | ForEach-Object { $_.FullName } }
    }
}
if ($existingHomes.Count -eq 0) { Fact "agent home: n/a (no candidate directory exists on this host)" }
Emit ""
$gac = "$WinDir\Microsoft.NET\assembly\GAC_MSIL"
TryFact "GAC_MSIL WhaTap-related assemblies (installer set: Whatap.Tracer/Loader/Startup, DiagnosticSource, System.Memory, Microsoft.Diagnostics.*, Sigil, Renci.SshNet)" {
    if (-not (Test-Path -LiteralPath $gac)) { return "n/a (path not found: $gac)" }
    $names = @("Whatap.*", "Sigil", "System.Diagnostics.DiagnosticSource", "System.Memory", "Microsoft.Diagnostics.Runtime", "Microsoft.Diagnostics.NETCore.Client", "Renci.SshNet")
    $out = @()
    foreach ($n in $names) {
        foreach ($d in @(Get-ChildItem -LiteralPath $gac -Directory -Filter $n -ErrorAction SilentlyContinue)) {
            foreach ($v in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                $dll = @(Get-ChildItem -LiteralPath $v.FullName -Filter "*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1)
                $m = if ($dll.Count -gt 0) { $dll[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { "no dll" }
                $out += "{0}\{1}  {2}" -f $d.Name, $v.Name, $m
            }
        }
    }
    if ($out.Count -eq 0) { "none found under $gac" } else { $out }
}
TryFact "machine Path (registry $MACHINE_ENV_KEY) segments containing 'whatap'" {
    $mp = (Get-ItemProperty -LiteralPath $MACHINE_ENV_KEY -ErrorAction Stop).Path
    $segs = @(("$mp" -split ';') | Where-Object { $_ -imatch 'whatap' })
    if ($segs.Count -eq 0) { "none" } else { $segs }
}

Section "C. Profiler registration & environment scopes"
# scope 1: machine environment (registry) -- installer writes WHATAP_* here only
Fact "-- scope: machine environment registry ($MACHINE_ENV_KEY) --"
$machineEnvPairs = @()
try {
    $me = Get-ItemProperty -LiteralPath $MACHINE_ENV_KEY -ErrorAction Stop
    $hits = @($me.PSObject.Properties | Where-Object { $_.Name -match $ENV_NAME_PATTERN })
    if ($hits.Count -eq 0) { Fact "machine env: no WHATAP_*/COR_*/CORECLR_*/DOTNET_STARTUP_HOOKS values" }
    foreach ($p in $hits) { Fact "machine env: $($p.Name)=$($p.Value)"; $machineEnvPairs += "$($p.Name)=$($p.Value)" }
} catch { Fact "machine env: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
# scope 2: service-level env (W3SVC / WAS) -- installer writes COR_*/CORECLR_* here
foreach ($svc in @("W3SVC", "WAS")) {
    Fact "-- scope: service registry Environment (HKLM\SYSTEM\CurrentControlSet\Services\$svc) --"
    RegValue "$svc Environment (multi-sz, verbatim)" "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" "Environment"
}
# scope 3: env visible to this collector process (inherited machine+user env)
$liveHits = @(Get-ChildItem Env: | Where-Object { $_.Name -match $ENV_NAME_PATTERN })
if ($liveHits.Count -eq 0) { Fact "collector process env: no WHATAP_*/COR_*/CORECLR_*/DOTNET_STARTUP_HOOKS values" }
foreach ($p in $liveHits) { Fact "collector process env: $($p.Name)=$($p.Value)" }
# scope 4: per-app-pool env (applicationHost.config
# <applicationPools><add name=POOL><environmentVariables><add name= value=>) --
# IIS hands these to that pool's w3wp only; another profiler product may
# register here instead of in W3SVC/WAS
$ahc = "$WinDir\System32\inetsrv\config\applicationHost.config"
$poolEnvPairs = @()
Fact "-- scope: app pool environmentVariables ($ahc) --"
$ahcState = Path-State $ahc
if ($ahcState -eq "denied") { Fact "app pool env: n/a (access denied: $ahc)" }
elseif ($ahcState -eq "absent") { Fact "app pool env: n/a (path not found: $ahc)" }
else {
    try {
        [xml]$ahcXml = Get-Content -LiteralPath $ahc -Raw -Encoding UTF8 -ErrorAction Stop
        # <applicationPoolDefaults> holds what every pool inherits; it is shown as pool=(defaults)
        $poolVars = @($ahcXml.SelectNodes("//applicationPools/add/environmentVariables/add | //applicationPools/applicationPoolDefaults/environmentVariables/add"))
        $shown = 0
        foreach ($v in $poolVars) {
            $n = $v.GetAttribute("name")
            if ($n -notmatch $ENV_NAME_PATTERN) { continue }
            $owner = $v.ParentNode.ParentNode
            $pool = $(if ($owner.LocalName -eq 'applicationPoolDefaults') { '(defaults)' } else { $owner.GetAttribute("name") })
            $poolEnvPairs += "$n=$($v.GetAttribute('value'))"
            if ($shown -lt 80) { Fact "app pool env: pool=$pool $n=$($v.GetAttribute('value'))" }
            $shown++
        }
        if ($shown -eq 0) { Fact "app pool env: no WHATAP_*/COR_*/CORECLR_*/DOTNET_STARTUP_HOOKS/MicrosoftInstrumentationEngine_* values in any pool" }
        elseif ($shown -gt 80) { Fact "(further app pool env values omitted: $($shown - 80) more)" }
    } catch { Fact "app pool env: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
}
Emit ""
# every configured profiler/hook path -> does that exact file exist, and what is it
$cfgPaths = @{}
foreach ($line in ($svcEnvLines + $machineEnvPairs + $poolEnvPairs + @($liveHits | ForEach-Object { "$($_.Name)=$($_.Value)" }))) {
    if ($line -match '^(COR_PROFILER_PATH(_32|_64)?|CORECLR_PROFILER_PATH(_32|_64)?|DOTNET_STARTUP_HOOKS|MicrosoftInstrumentationEngine_RawProfilerHookPath(_32|_64)?)=(.+)$') {
        $cfgPaths[$Matches[1] + "=" + $Matches[5]] = $Matches[5]
    }
}
if ($cfgPaths.Count -eq 0) { Fact "configured profiler/startup-hook paths: none found in any scope above" }
foreach ($k in ($cfgPaths.Keys | Sort-Object)) {
    $var = ($k -split '=', 2)[0]
    FileFacts "configured $var target" $cfgPaths[$k] -Hash
}
Emit ""
# every profiler CLSID named in any scope (COR_PROFILER, CORECLR_PROFILER, the
# CLR Instrumentation Engine raw profiler hook) plus the two WhaTap CLSIDs
$envLinesAll = @($svcEnvLines + $machineEnvPairs + $poolEnvPairs + @($liveHits | ForEach-Object { "$($_.Name)=$($_.Value)" }))
$clsids = [ordered]@{}
$clsids[$CLSID_CURRENT] = "WhaTap current 2.5.x line"
$clsids[$CLSID_LEGACY]  = "WhaTap legacy 450/core line"
foreach ($line in $envLinesAll) {
    if ($line -match '^(COR_PROFILER|CORECLR_PROFILER|MicrosoftInstrumentationEngine_RawProfilerHook)=(\{[0-9A-Fa-f-]{36}\})\s*$') {
        $c = $Matches[2].ToUpper()
        if (-not $clsids.Contains($c)) { $clsids[$c] = "named by $($Matches[1])" }
    }
}
$clsidDlls = @()
foreach ($c in $clsids.Keys) {
    $tag = $clsids[$c]
    foreach ($view in @(@("64-bit view", "HKLM:\SOFTWARE\Classes\CLSID\$c\InProcServer32"), @("WOW6432Node view", "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$c\InProcServer32"))) {
        RegValue "CLSID $c ($tag) InProcServer32 ($($view[0]))" $view[1] "(default)"
        try { $k = Reg-Open $view[1]; if ($k) { $v = $k.GetValue(''); $k.Close(); if ($v) { $clsidDlls += "$c|$v" } } } catch { }
    }
}
foreach ($cd in ($clsidDlls | Select-Object -Unique)) {
    $c, $dll = $cd -split '\|', 2
    if ($c -ne $CLSID_CURRENT -and $c -ne $CLSID_LEGACY) { FileFacts "CLSID $c registered DLL" $dll -Hash }
}
Emit ""
# CLR Instrumentation Engine configuration files named by MicrosoftInstrumentationEngine_ConfigPath*
$iePaths = @{}
foreach ($line in $envLinesAll) {
    if ($line -match '^(MicrosoftInstrumentationEngine_ConfigPath\w*)=(.+)$') { $iePaths[$Matches[1] + "=" + $Matches[2]] = $Matches[2] }
}
if ($iePaths.Count -eq 0) { Fact "MicrosoftInstrumentationEngine_ConfigPath* values: none in any scope above" }
foreach ($k in ($iePaths.Keys | Sort-Object)) {
    $var = ($k -split '=', 2)[0]
    FileFacts "$var file" $iePaths[$k]
    HeadFile "$var content" $iePaths[$k] 80
}
# uninstall entries of other profiler products: the CLR Instrumentation Engine
# by name (a shared host, its DLL lives in its own folder), and any entry whose
# InstallLocation contains a profiler DLL, a registered CLSID DLL or a CLRIE
# configuration file seen above -- found from the configuration, not from a
# product name, so any vendor's product is caught the same way
# an InstallLocation as a folder prefix ending in '\', so C:\Foo does not match
# C:\FooBar; none for a drive root or a Program Files / Windows folder itself,
# which would match every file under it. Quotes and spaces around it are dropped.
function Install-Prefix($loc) {
    $p = "$loc".Trim().Trim('"').Trim().TrimEnd('\')
    if (-not $p -or $p -match '^[A-Za-z]:$') { return $null }
    foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:SystemRoot)) {
        if ($r -and $p -ieq "$r".TrimEnd('\')) { return $null }
    }
    return $p + '\'
}
$profDlls = @($cfgPaths.Values) + @($clsidDlls | ForEach-Object { ($_ -split '\|', 2)[1] }) + @($iePaths.Values)
$otherEntries = @($uninstallAll | Where-Object {
    $u = $_
    ($u.DisplayName -notmatch '[Ww]ha[Tt]ap') -and (
        ($u.DisplayName -match 'Instrumentation Engine') -or
        (($loc = Install-Prefix $u.InstallLocation) -and @($profDlls | Where-Object { $_ -and "$_".Trim().Trim('"').StartsWith($loc, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0))
})
Fact "uninstall entries of other profiler products (CLR Instrumentation Engine by name, or InstallLocation holding a profiler DLL, CLSID DLL or CLRIE configuration file above): $($otherEntries.Count)"
foreach ($u in $otherEntries) {
    Fact "  DisplayName=$($u.DisplayName)  DisplayVersion=$($u.DisplayVersion)  Publisher=$($u.Publisher)  InstallDate=$($u.InstallDate)  InstallLocation=$($u.InstallLocation)"
}
# paths section D treats as profiler modules besides its vendor-name list: every
# profiler DLL and CLRIE configuration folder named above, and the install
# folders of the products found above
$profPrefixes = @(@($profDlls | Where-Object { $_ } | ForEach-Object { $d = "$_".Trim().Trim('"'); if ($d -imatch '\.xml$') { Install-Prefix (Split-Path -Parent $d) } else { $d } }) +
    @($otherEntries | ForEach-Object { Install-Prefix $_.InstallLocation })) | Where-Object { $_ } | Select-Object -Unique
# Windows Installer history of those products: when each was installed,
# updated or removed, to the second. The WhaTap installer is not an MSI; its
# last run is the mtime of unins000.dat in section B. Not bounded by the 7-day
# window of section I: the newest 200 MsiInstaller product events, whatever age
# the Application log still holds.
$msiNames = @(@($otherEntries | ForEach-Object { [regex]::Escape("$($_.DisplayName)") } | Where-Object { $_ }) + 'Instrumentation Engine') -join '|'
TryFact "Application log: Windows Installer product events (1033 installed, 1034 removed, 1035 reconfigured, 1036 updated) naming the products above or the Instrumentation Engine (newest 20 of the MsiInstaller ones among the newest 200 events with these ids)" {
    # filtered by id only, the provider picked afterwards: a ProviderName key
    # reads provider metadata that a non-elevated account cannot (Get-WinEvent
    # then reports no such provider), and an XPath or XML filter is refused to a
    # non-elevated network logon, while this form reads the same events
    $raw = @(Invoke-BoundedBlock {
        try { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1033, 1034, 1035, 1036 } -MaxEvents 200 -ErrorAction Stop | Where-Object { $_.ProviderName -eq 'MsiInstaller' } }
        catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
    })
    $ev = @($raw | Where-Object { "$($_.Message)" -match $msiNames } | Select-Object -First 20)
    if ($raw.Count -gt 0) { "oldest MsiInstaller product event read: $($raw[-1].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" }
    if ($ev.Count -eq 0) { $(if ($isAdmin) { "none naming the products above" } else { "none naming the products above among the events this account can read (not elevated)" }) }
    else {
        $ev | ForEach-Object {
            $msg = ("$($_.Message)" -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + " ..." }
            "{0}  id={1}  {2}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $_.Id, $msg
        }
    }
}
Emit ""
Fact "-- Fusion assembly-binding log settings (HKLM\SOFTWARE\Microsoft\Fusion; read-only report) --"
foreach ($n in @("EnableLog", "ForceLog", "LogFailures", "LogResourceBinds", "LogPath")) {
    RegValue "Fusion $n" "HKLM:\SOFTWARE\Microsoft\Fusion" $n
}
TryFact "applicationHost.config lines matching COR/CORECLR/WHATAP/STARTUP_HOOKS/InstrumentationEngine (with line numbers)" {
    $st = Path-State $ahc
    if ($st -eq "denied") { "n/a (access denied: $ahc)" }
    elseif ($st -eq "absent") { "n/a (path not found: $ahc)" }
    else {
        $m = @(Select-String -LiteralPath $ahc -Pattern 'CORECLR|COR_|WHATAP|STARTUP_HOOKS|InstrumentationEngine' -Encoding UTF8 -ErrorAction Stop | Select-Object -First 40)
        if ($m.Count -eq 0) { "no matching lines" } else { $m | ForEach-Object { "{0}: {1}" -f $_.LineNumber, $_.Line.Trim() } }
    }
}

Section "D. WhaTap service & runtime processes"
# the CLR a process loaded: clr.dll (.NET Framework 4.x), coreclr.dll (.NET
# Core / 5+), aspnetcorev2*.dll (the ASP.NET Core Module and its in-process
# handler); their FileVersion is the runtime build actually running
$RUNTIME_MODULES  = '\\(clr|coreclr|aspnetcorev2[^\\]*)\.dll$'
$PROFILER_MODULES = 'whatap|clrprofiler|InstrumentationEngine|datadog|dynatrace|newrelic|appdynamics|instana|elastic.apm|contrast|scouter|jennifer'
if ($profPrefixes.Count -gt 0) { $PROFILER_MODULES += '|' + (@($profPrefixes | ForEach-Object { [regex]::Escape($_) }) -join '|') }
# Module lists of the w3wp and the first 10 dotnet.exe processes, read once.
# A live process always has modules (ntdll at least): an empty list is one
# this run could not read, which 0.4.0 printed as "none". Windows PowerShell
# 5.1 (.NET Framework) lists only the WOW64 layer of a 32-bit process (ntdll,
# wow64*.dll): the 32-bit Classic32 pool read "none" for both lists while
# pwsh 7 listed its clr.dll (0.5.1, lab host, 2026-09-27). The lists of such
# processes are read again by the 32-bit Windows PowerShell, in one bounded
# call for all of them.
$ModList = @{}; $ModErr = @{}; $ModNote = @{}; $wowPids = @()
foreach ($p in @($procW3wp) + @($procDotnet | Select-Object -First 10)) {
    $id = [int]$p.ProcessId
    try {
        $l = @((Get-Process -Id $id -ErrorAction Stop).Modules | Where-Object { $_ })
        $ModList[$id] = $l
        if ([Environment]::Is64BitProcess -and @($l | Where-Object { $_.FileName -imatch '\\wow64\.dll$' }).Count -gt 0 -and
            @($l | Where-Object { $_.FileName -imatch '\\kernel32\.dll$' }).Count -eq 0) { $wowPids += $id }
    } catch { $ModErr[$id] = $_.Exception.Message.Split("`n")[0] }
}
if ($wowPids.Count -gt 0) {
    $ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $why = ""
    if (-not (Test-Path -LiteralPath $ps32)) { $why = "path not found: $ps32" }
    else {
        $src = @'
foreach ($i in @(PIDS)) {
    try { (Get-Process -Id $i -ErrorAction Stop).Modules | ForEach-Object { $v = ""; if ($_.FileName -imatch 'PATTERN') { $v = $_.FileVersionInfo.FileVersion }; "$i|$($_.FileName)|$v" } }
    catch { "$i|!|$($_.Exception.Message.Split("`n")[0])" }
}
'@
        $src = $src.Replace('PIDS', ($wowPids -join ',')).Replace('PATTERN', "$PROFILER_MODULES|$RUNTIME_MODULES".Replace("'", "''"))
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($src))
        try {
            $got = @{}
            foreach ($line in @(Invoke-Bounded $ps32 @("-NoProfile", "-NonInteractive", "-EncodedCommand", $enc))) {
                $f = "$line" -split '\|', 3
                if ($f.Count -lt 3 -or $f[0] -notmatch '^\d+$') { continue }
                $id = [int]$f[0]
                if ($f[1] -eq '!') { $ModErr[$id] = "32-bit process; its module list through the 32-bit Windows PowerShell: $($f[2])"; $got[$id] = $true; continue }
                if (-not $got.ContainsKey($id)) { $got[$id] = $true; $ModList[$id] = @() }
                $ModList[$id] += [pscustomobject]@{ FileName = $f[1]; FileVersionInfo = [pscustomobject]@{ FileVersion = $f[2] } }
                $ModNote[$id] = " (32-bit process: listed by the 32-bit Windows PowerShell)"
            }
            foreach ($id in $wowPids) { if (-not $got.ContainsKey($id)) { $why = "no module lines from $ps32"; break } }
        } catch { $why = "$ps32 -- $($_.Exception.Message.Split("`n")[0])" }
    }
    if ($why) {
        foreach ($id in $wowPids) { if (-not $ModNote.ContainsKey($id) -and -not $ModErr.ContainsKey($id)) {
            $ModErr[$id] = "32-bit process; this PowerShell lists only its WOW64 modules, and the 32-bit read did not complete: $why" } }
    }
}
TryFact "services matching 'whatap'" {
    $s = @(Get-CimBounded Win32_Service | Where-Object { $_.Name -imatch 'whatap' -or $_.DisplayName -imatch 'whatap' })
    if ($s.Count -eq 0) { "none" }
    else { $s | ForEach-Object { "{0}  state={1}  startmode={2}  account={3}  pid={4}  path={5}" -f $_.Name, $_.State, $_.StartMode, $_.StartName, $_.ProcessId, $_.PathName } }
}
Fact "whatap-named processes: $($procWhatap.Count)"
foreach ($p in $procWhatap) {
    $cl = "$($p.CommandLine)"; if ($cl.Length -gt 240) { $cl = $cl.Substring(0, 240) + " ..." }
    if (-not $cl) { $cl = "n/a (not readable)" }
    Fact "process: pid=$($p.ProcessId) name=$($p.Name) start=$(Fmt-Time $p.CreationDate) cmd=$cl"
}
Emit ""
Fact "w3wp.exe worker processes: $($procW3wp.Count)"
foreach ($p in $procW3wp) {
    # CommandLine and ExecutablePath are empty for another account's process
    # when the run is not elevated; 0.4.0 then printed "exe= [64-bit path]"
    $pool = if ($p.CommandLine) { "n/a (no -ap in the command line)" } else { "n/a (command line not readable)" }
    if ($p.CommandLine -match '-ap\s+"([^"]+)"') { $pool = $Matches[1] }
    if ($p.ExecutablePath) {
        $bitMark = if ("$($p.ExecutablePath)" -imatch 'SysWOW64') { "32-bit (SysWOW64 path)" } else { "64-bit path" }
        $exeTxt = "$($p.ExecutablePath) [$bitMark]"
    } else { $exeTxt = "n/a (not readable)" }
    Fact "w3wp: pid=$($p.ProcessId) apppool=$pool start=$(Fmt-Time $p.CreationDate) ws_kb=$([int]($p.WorkingSetSize/1KB)) exe=$exeTxt"
    $id = [int]$p.ProcessId
    if ($ModErr.ContainsKey($id)) { Fact "  loaded profiler-related modules: n/a ($($ModErr[$id]))"; Fact "  loaded runtime modules: n/a ($($ModErr[$id]))"; continue }
    $all = @($ModList[$id]); $note = "$($ModNote[$id])"
    if ($all.Count -eq 0) { Fact "  loaded profiler-related modules: n/a (module list not readable)"; Fact "  loaded runtime modules: n/a (module list not readable)"; continue }
    $mods = @($all | Where-Object { $_.FileName -imatch $PROFILER_MODULES })
    if ($mods.Count -eq 0) { Fact "  loaded profiler-related modules: none$note" }
    else { foreach ($m in $mods) { Fact "  loaded module: $($m.FileName)  FileVersion=$($m.FileVersionInfo.FileVersion)" } }
    $rt = @($all | Where-Object { $_.FileName -imatch $RUNTIME_MODULES })
    if ($rt.Count -eq 0) { Fact "  loaded runtime modules (clr, coreclr, aspnetcorev2*): none$note" }
    else { foreach ($m in $rt) { Fact "  loaded runtime module: $($m.FileName)  FileVersion=$($m.FileVersionInfo.FileVersion)$note" } }
}
Emit ""
Fact "dotnet.exe processes: $($procDotnet.Count)"
$dnShown = 0
foreach ($p in $procDotnet) {
    if ($dnShown -ge 10) { Fact "(further dotnet.exe processes omitted: $($procDotnet.Count - 10) more)"; break }
    $cl = "$($p.CommandLine)"; if ($cl.Length -gt 240) { $cl = $cl.Substring(0, 240) + " ..." }
    if (-not $cl) { $cl = "n/a (not readable)" }
    Fact "dotnet: pid=$($p.ProcessId) start=$(Fmt-Time $p.CreationDate) cmd=$cl"
    $dnShown++
    $id = [int]$p.ProcessId
    if ($ModErr.ContainsKey($id)) { Fact "  loaded runtime modules: n/a ($($ModErr[$id]))"; continue }
    $all = @($ModList[$id]); $note = "$($ModNote[$id])"
    if ($all.Count -eq 0) { Fact "  loaded runtime modules: n/a (module list not readable)"; continue }
    $mods = @($all | Where-Object { $_.FileName -imatch 'whatap|clrprofiler' })
    foreach ($m in $mods) { Fact "  loaded module: $($m.FileName)  FileVersion=$($m.FileVersionInfo.FileVersion)" }
    $rt = @($all | Where-Object { $_.FileName -imatch $RUNTIME_MODULES })
    if ($rt.Count -eq 0) { Fact "  loaded runtime modules (clr, coreclr, aspnetcorev2*): none$note" }
    else { foreach ($m in $rt) { Fact "  loaded runtime module: $($m.FileName)  FileVersion=$($m.FileVersionInfo.FileVersion)$note" } }
}
if ($null -eq $allProc) { Fact "process inventory: n/a (Win32_Process query failed: $procErr)" }

Section "E. IIS topology"
if (Test-Path -LiteralPath $appcmd) {
    TryFact "app pools (appcmd list apppools)" { Invoke-Bounded $appcmd @("list", "apppools") }
    TryFact "sites (appcmd list sites)" { Invoke-Bounded $appcmd @("list", "sites") }
    TryFact "apps (appcmd list apps)" { Invoke-Bounded $appcmd @("list", "apps") }
    TryFact "vdirs with physical paths (appcmd list vdirs)" { Invoke-Bounded $appcmd @("list", "vdirs") }
    TryFact "ISAPI filters (appcmd list config -section:isapiFilters)" { Invoke-Bounded $appcmd @("list", "config", "-section:isapiFilters") | Select-Object -First 60 }
} else {
    Fact "appcmd: n/a (path not found: $appcmd)"
}
if (Get-Module -ListAvailable -Name WebAdministration -ErrorAction SilentlyContinue) {
    TryFact "app pool details (WebAdministration: CLR version / pipeline / 32-bit flag / identity / state)" {
        Import-Module WebAdministration -ErrorAction Stop
        Get-ChildItem IIS:\AppPools -ErrorAction Stop | ForEach-Object {
            "{0}  state={1}  clr={2}  pipeline={3}  enable32BitAppOnWin64={4}  identityType={5}  autoStart={6}" -f `
                $_.Name, $_.State, $_.managedRuntimeVersion, $_.managedPipelineMode, $_.enable32BitAppOnWin64, $_.processModel.identityType, $_.autoStart
        }
    }
} else {
    Fact "WebAdministration app pool details: n/a (module not available)"
    TryFact "applicationHost.config <applicationPools> section" {
        $st = Path-State $ahc
        if ($st -eq "denied") { "n/a (access denied: $ahc)" }
        elseif ($st -eq "absent") { "n/a (path not found: $ahc)" }
        else {
            $txt = Get-Content -LiteralPath $ahc -Encoding UTF8 -ErrorAction Stop -Raw
            if ($txt -match '(?s)(<applicationPools>.*?</applicationPools>)') {
                @($Matches[1] -split "`r?`n" | Select-Object -First 120)
            } else { "no <applicationPools> section found" }
        }
    }
}

Section "F. Agent configuration"
# conf search order implemented by the managed tracer (ConfigObserver.cs):
# 1) %WHATAP_DOTNET_HOME%\whatap.conf  2) grandparent of COR_PROFILER_PATH
# 3) "WhaTap .NET Debug" default dir if present, else "WhaTap .NET"
$confSeen = @{}
$confRead = @(); $confUnread = @()
foreach ($h in $existingHomes) {
    $cf = Join-Path $h "whatap.conf"
    if ($confSeen.ContainsKey($cf.ToLower())) { continue }
    $confSeen[$cf.ToLower()] = $true
    Emit ""; Emit "    -- conf candidate: $cf --"
    if (Test-Path -LiteralPath $cf) {
        try { $null = Get-Content -LiteralPath $cf -TotalCount 1 -ErrorAction Stop; $confRead += $cf }
        catch { $confUnread += $cf }
        $fi = Get-Item -LiteralPath $cf -ErrorAction SilentlyContinue
        Fact "whatap.conf: present, mtime=$($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')), owner=$(OwnerOf $cf)"
        ConfBytes "whatap.conf bytes" $cf
        DumpFile "whatap.conf" $cf 200
    } else {
        Fact "whatap.conf: n/a (path not found: $cf)"
    }
}
if ($existingHomes.Count -eq 0) { Fact "whatap.conf: n/a (no agent home directory exists)" }

Section "G. Agent logs"
$runningPids = @()
if ($allProc) { $runningPids = @($allProc | ForEach-Object { $_.ProcessId }) }
foreach ($ld in @($PROGDATA_LOGS) + @($existingHomes | ForEach-Object { Join-Path $_ "logs" })) {
    Emit ""; Emit "    -- log dir: $ld --"
    if (-not (Test-Path -LiteralPath $ld)) { Fact "log dir: n/a (path not found: $ld)"; continue }
    $logs = @(Get-ChildItem -LiteralPath $ld -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    Fact "log files: $($logs.Count) (newest 25 listed: name size mtime owner)"
    foreach ($f in ($logs | Select-Object -First 25)) {
        Fact "  $($f.Name)  $($f.Length)  $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))  $(OwnerOf $f.FullName)"
    }
    # native profiler log: core-YYYYMMDD.log (fixed dir; logger.hpp)
    $core = @($logs | Where-Object { $_.Name -match '^core-\d{8}\.log$' } | Select-Object -First 1)
    if ($core.Count -gt 0) {
        TryFact "native profiler banner lines in $($core[0].Name) ('CLR Profiler ... Initialize', first 500 lines scanned)" {
            $m = @(Get-Content -LiteralPath $core[0].FullName -TotalCount 500 -Encoding UTF8 -ErrorAction Stop | Select-String -Pattern 'CLR Profiler' | Select-Object -First 5)
            if ($m.Count -eq 0) { "no matching lines in first 500" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        TryFact "CLR Instrumentation Engine / loader-injection lines in $($core[0].Name) (first 20 matching lines of the last 5000)" {
            $m = @(Get-Content -LiteralPath $core[0].FullName -Tail 5000 -Encoding UTF8 -ErrorAction Stop | Select-String -Pattern 'Instrumentation Engine|UserBuffer|LOADER INJECTION|AddIISPreStartInitFlags|ILRewriter' | Select-Object -First 20)
            if ($m.Count -eq 0) { "no matching lines" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        HeadFile "native profiler log $($core[0].Name)" $core[0].FullName 40
        TailFile "native profiler log $($core[0].Name)" $core[0].FullName 120
    } else {
        Fact "native profiler log (core-YYYYMMDD.log): none in this dir"
    }
    # managed tracer logs: <yyyyMMdd>-<id>.log (id: guid in 2.5.x, pid in older lines)
    $tracer = @($logs | Where-Object { $_.Name -match '^\d{8}-.+\.log$' })
    Fact "managed tracer logs (<yyyyMMdd>-<id>.log): $($tracer.Count) file(s)"
    if ($tracer.Count -gt 0) {
        $t0 = $tracer[0]
        TryFact "version/identity lines in newest $($t0.Name) (whatap.version / framework.version / runtime.version / whatap.home, first 400 lines scanned)" {
            $m = @(Get-Content -LiteralPath $t0.FullName -TotalCount 400 -Encoding UTF8 -ErrorAction Stop | Select-String -Pattern 'whatap\.version|framework\.version|runtime\.version|whatap\.home|WA002' | Select-Object -First 12)
            if ($m.Count -eq 0) { "no matching lines in first 400" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        HeadFile "newest tracer log $($t0.Name)" $t0.FullName 40
        TailFile "newest tracer log $($t0.Name)" $t0.FullName 120
        TryFact "exception-line count in last 500 lines of $($t0.Name)" {
            @(Get-Content -LiteralPath $t0.FullName -Tail 500 -Encoding UTF8 -ErrorAction Stop | Select-String -Pattern 'Exception|ERROR').Count
        }
    }
    # PID-named log files vs live pids (PID reuse has produced files owned by
    # another app pool's identity; the reader compares owner vs current pools)
    $pidLogs = @($logs | Where-Object { $_.Name -match '^\d{8}-(\d+)\.log$' })
    if ($pidLogs.Count -gt 0) {
        Fact "PID-named log files: $($pidLogs.Count); running pids on host: $($runningPids.Count)"
        foreach ($f in ($pidLogs | Select-Object -First 15)) {
            $logPid = [int]($f.Name -replace '^\d{8}-(\d+)\.log$', '$1')
            $alive = $runningPids -contains $logPid
            Fact "  $($f.Name)  pid=$logPid  pid-currently-running=$alive  owner=$(OwnerOf $f.FullName)"
        }
    }
}
Emit ""
if (Test-Path -LiteralPath $PROGDATA_AUDIT) {
    $af = @()
    try { $af = @(Invoke-BoundedBlock { param($d) Get-ChildItem -LiteralPath $d -File -Recurse -Depth 3 -ErrorAction SilentlyContinue } @($PROGDATA_AUDIT)) }
    catch { Fact "audit dir listing: n/a ($($_.Exception.Message.Split("`n")[0]))" }
    $asz = 0; foreach ($f in $af) { $asz += $f.Length }
    $anew = "n/a"; if ($af.Count -gt 0) { $anew = ($af | Sort-Object LastWriteTime -Descending)[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
    Fact "audit dir ${PROGDATA_AUDIT}: $($af.Count) file(s), total $asz bytes, newest mtime $anew, owner=$(OwnerOf $PROGDATA_AUDIT)"
    Fact "audit dir content: not dumped (presence and size only)"
} else {
    Fact "audit dir ${PROGDATA_AUDIT}: n/a (path not found)"
}
if ($env:WT_TRACE_LOG_PATH) { Fact "WT_TRACE_LOG_PATH (collector process env): $env:WT_TRACE_LOG_PATH" }

Section "H. Network endpoints"
# tracer -> UDP 127.0.0.1:6600 -> whatap_dotnet.exe -> TCP 6600 -> collection server
# netstat -ano, one call for TCP and UDP with the owning pid. Not
# Get-NetTCPConnection / Get-NetUDPEndpoint: the same rows, but importing their
# module took 1.9 s and each bounded runspace imports it again (0.4.0, Windows
# Server 2022); netstat took 0.2 s.
TryFact "netstat -ano lines with :6600 (proto, local, remote, state, pid)" {
    $m = @(Invoke-Bounded netstat @("-ano") | Select-String -Pattern ':6600\s' | Select-Object -First 40)
    if ($m.Count -eq 0) { "none" } else { $m | ForEach-Object { $_.Line.Trim() } }
}
foreach ($h in $existingHomes) {
    $cf = Join-Path $h "whatap.conf"
    $sh = ConfGet $cf "whatap\.server\.host"
    $sp = ConfGet $cf "whatap\.server\.port"
    if (-not $sp) { $sp = "6600" }
    if ($sh) {
        Fact "conf ${cf}: whatap.server.host=$sh whatap.server.port=$sp"
        foreach ($w in ($sh -split '[/,]')) {
            if ($w.Trim()) { TcpProbe "collection server reachability" $w.Trim() ([int]$sp) }
        }
    }
}

# Event-Text MESSAGE -> the event message on one line, its lines joined with
# " | ". A message over 400 characters keeps its first line and the lines that
# name what failed (Event message, Exception type/message, the application
# path, the process): an ASP.NET 1310 event separates its 70 lines with bare
# CRs, and three lines of it dropped the "Could not load file or assembly"
# text that section J is read against (0.5.0 lab check).
function Event-Text([string]$m) {
    $ls = @("$m" -split "`r`n|`r|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ls.Count -eq 0) { return "" }
    $all = $ls -join ' | '
    if ($all.Length -le 400) { return $all }
    $keep = @($ls[0]) + @($ls | Select-Object -Skip 1 | Where-Object { $_ -match '^(Event message|Exception type|Exception message|Application Virtual Path|Application Path|Process name|Account name):' })
    $keep = @($keep | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) + " ..." } else { $_ } })
    return ($keep -join ' | ') + " | ... ($($ls.Count) lines)"
}
Section "I. Windows event logs (bounded, last 7 days)"
TryFact "Application log: .NET/ASP.NET/crash/WhaTap events (newest 15 of last 300 err+warn)" {
    # Get-WinEvent throws NoMatchingEventsFound for an empty window: that is none
    # (matched by its error id; the message text is localized)
    $raw = @(Invoke-BoundedBlock {
        try { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction Stop }
        catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
    })
    $ev = @($raw |
        Where-Object { $_.ProviderName -match '\.NET Runtime|ASP\.NET|AspNetCore|Application Error|Windows Error Reporting|[Ww]ha[Tt]ap' } |
        Select-Object -First 15)
    if ($ev.Count -eq 0) { $(if ($isAdmin) { "none matching in window" } else { "none matching among the events this account can read (not elevated)" }) }
    else {
        $ev | ForEach-Object {
            $msg = Event-Text $_.Message
            "{0}  {1}  id={2}  {3}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $_.ProviderName, $_.Id, $msg
        }
    }
}
TryFact "System log: WAS/W3SVC/HTTP events (newest 10 of last 300 err+warn)" {
    # Get-WinEvent throws NoMatchingEventsFound for an empty window: that is none
    # (matched by its error id; the message text is localized)
    $raw = @(Invoke-BoundedBlock {
        try { Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction Stop }
        catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
    })
    $ev = @($raw |
        Where-Object { $_.ProviderName -match 'WAS|W3SVC|IIS|HTTP' } |
        Select-Object -First 10)
    if ($ev.Count -eq 0) { $(if ($isAdmin) { "none matching in window" } else { "none matching among the events this account can read (not elevated)" }) }
    else {
        $ev | ForEach-Object {
            $msg = Event-Text $_.Message
            "{0}  {1}  id={2}  {3}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $_.ProviderName, $_.Id, $msg
        }
    }
}

Section "J. Application facts (per IIS application)"
# physical paths come from appcmd list vdirs; env vars inside paths expanded
$appPaths = @()
if (Test-Path -LiteralPath $appcmd) {
    try {
        foreach ($line in @(Invoke-Bounded $appcmd @("list", "vdirs"))) {
            if ("$line" -match 'VDIR\s+"([^"]+)"\s+\(physicalPath:([^)]*)\)') {
                $appPaths += ,@($Matches[1], [Environment]::ExpandEnvironmentVariables($Matches[2]))
            }
        }
    } catch { }
}
if ($appPaths.Count -eq 0) {
    if (-not (Test-Path -LiteralPath $appcmd)) { Fact "IIS application physical paths: n/a (path not found: $appcmd)" }
    elseif (-not $isAdmin) { Fact "IIS application physical paths: n/a (appcmd returned no vdir lines; run not elevated)" }
    else { Fact "IIS application physical paths: n/a (appcmd returned no vdir lines)" }
}
$appShown = 0
foreach ($ap in $appPaths) {
    if ($appShown -ge 10) { Fact "(further applications omitted: $($appPaths.Count - 10) more)"; break }
    $vdir = $ap[0]; $phys = $ap[1]
    Emit ""; Emit "    -- app: $vdir -> $phys --"
    if (-not (Test-Path -LiteralPath $phys)) { Fact "physical path: n/a (path not found: $phys)"; $appShown++; continue }
    $wc = Join-Path $phys "web.config"
    if (Test-Path -LiteralPath $wc) {
        $fi = Get-Item -LiteralPath $wc -ErrorAction SilentlyContinue
        Fact "web.config: present, size=$($fi.Length), mtime=$($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        TryFact "targetFramework lines" {
            $m = @(Select-String -LiteralPath $wc -Pattern 'targetFramework' -Encoding UTF8 -ErrorAction Stop | Select-Object -First 5)
            if ($m.Count -eq 0) { "no targetFramework attribute" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        TryFact "hostingModel lines" {
            $m = @(Select-String -LiteralPath $wc -Pattern 'hostingModel' -Encoding UTF8 -ErrorAction Stop | Select-Object -First 5)
            if ($m.Count -eq 0) { "no hostingModel attribute" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        TryFact "web.config <runtime> block (assemblyBinding, verbatim)" {
            $txt = Get-Content -LiteralPath $wc -Encoding UTF8 -ErrorAction Stop -Raw
            if ($txt -match '(?s)(<runtime>.*?</runtime>)') { @($Matches[1] -split "`r?`n" | Select-Object -First 80) }
            else { "no <runtime> block" }
        }
    } else {
        Fact "web.config: not present at $phys"
    }
    $bin = Join-Path $phys "bin"
    if (Test-Path -LiteralPath $bin) {
        foreach ($fa in @("System.Net.Http.dll", "System.IO.Compression.dll", "System.Runtime.dll", "System.Diagnostics.DiagnosticSource.dll")) {
            $p = Join-Path $bin $fa
            if (Test-Path -LiteralPath $p) { AsmFacts "bin\$fa" $p }
        }
        TryFact "bin\Whatap.* files" {
            $w = @(Get-ChildItem -LiteralPath $bin -Filter "Whatap.*" -ErrorAction SilentlyContinue)
            if ($w.Count -eq 0) { "none" } else { $w | ForEach-Object { "$($_.Name)  $($_.Length)  $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" } }
        }
    } else { Fact "bin\: not present" }
    TryFact ".NET Core markers (*.runtimeconfig.json / *.deps.json / appsettings.json)" {
        $m = @(Get-ChildItem -LiteralPath $phys -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.runtimeconfig\.json$|\.deps\.json$|^appsettings\.json$|^web\.config$' })
        if ($m.Count -eq 0) { "none at top level" } else { $m | ForEach-Object { $_.Name } }
    }
    foreach ($rc in @(Get-ChildItem -LiteralPath $phys -Filter "*.runtimeconfig.json" -File -ErrorAction SilentlyContinue | Select-Object -First 2)) {
        DumpFile "runtimeconfig $($rc.Name)" $rc.FullName 30
    }
    $appShown++
}

if ($homeBad.Count -gt 0) { Set-Missed agent ("-AgentHome path not found: " + ($homeBad -join ', ')) }
elseif ($existingHomes.Count -gt 0 -or $uninstallEntries.Count -gt 0) { Set-Got agent }
elseif ($uninstallRead -eq 0 -or $script:DiscErr.Count -gt 0) {
    $dw = @($script:DiscErr); if ($uninstallRead -eq 0 -and $dw.Count -eq 0) { $dw = @("HKLM uninstall registry not read") }
    Set-Missed agent ("no agent home found, and discovery reads failed: " + ($dw -join "; ") + $(if ($script:DiscDenied) { Priv-Hint } else { "" }))
}
else { Set-Na agent "no agent home in any candidate (parameter, env, service env, CLSID, uninstall registry, installer defaults) and no whatap uninstall entry" }
if ($confUnread.Count -gt 0) { Set-Missed conf ("whatap.conf not readable: $($confUnread -join ', ')" + (Priv-Hint)) }
elseif ($confRead.Count -gt 0) { Set-Got conf }
elseif ($existingHomes.Count -eq 0 -and ($homeBad.Count -gt 0 -or $uninstallRead -eq 0 -or $script:DiscErr.Count -gt 0) -and $uninstallEntries.Count -eq 0) { Set-Missed conf "no agent home resolved (see the agent goal)" }
elseif ($existingHomes.Count -eq 0 -and $uninstallEntries.Count -gt 0) { Set-Missed conf "an uninstall entry names the agent but no agent home directory exists to read a whatap.conf from (pass -AgentHome <dir>)" }
elseif ($existingHomes.Count -eq 0) { Set-Na conf "no agent home exists to hold a whatap.conf" }
else { Set-Missed conf "agent home discovered but no whatap.conf in it" }
Emit-Status
Emit ""
Emit "==== END OF COLLECTION (no diagnosis by design) ===="

# ---- output --------------------------------------------------------------------
if ($Stdout) {
    $script:Lines | ForEach-Object { Write-Output $_ }
} else {
    # UTF-8 without a BOM and LF line ends, the bytes a shell collector writes.
    # Not Set-Content -Encoding UTF8: Windows PowerShell 5.1 prefixes a BOM and
    # both editions end lines with CRLF, and validate.sh --report then fails
    # the footer and header lines (seen on Windows Server 2022, 0.4.0). The
    # directory is -Out, else the current file-system location, resolved
    # above because .NET resolves a relative path against the process
    # directory, which Set-Location does not change.
    $out = Join-Path $OutDir "$COLLECTOR_NAME-$CompName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).txt"
    try { [System.IO.File]::WriteAllText($out, (($script:Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false)) }
    catch { Warn "the report was not written: $out ($($_.Exception.Message.Split("`n")[0]))"; exit 1 }
    Progress "report written: $out"
}
