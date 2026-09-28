# templates/groups/ps1.ps1 - owner of the ps1 group blocks
# -----------------------------------------------------------------------------
# NOT A SCRIPT. Nothing dot-sources this file: every collector stays one file
# that runs by itself (CONTRACT rule 3). The blocks below are copied verbatim
# into the PowerShell collectors by
#   tools/sync-shared-block.sh --apply     (--check reports drift)
# the same way apm.sh's blocks reach the apm shell collectors.
#
# They are the PowerShell port of the skeleton's shell blocks (emit helpers,
# run helpers, privilege, boot time, collection completeness) plus the fact
# helpers both .ps1 collectors share. The block format (banner, `# members:`,
# STRAY) is defined once in
# [tools/sync-shared-block.sh](../../tools/sync-shared-block.sh); here the
# banner reads `# ---- ps1: <name> - DO NOT EDIT` with an em dash in the file,
# matched by the end line `# ---- end ps1: <name>`, and members are named by
# the stem of their file name (collect-<stem>.ps1).
#
# To change a helper here: edit this file, run --apply, bump each member's
# VERSION and add its CHANGELOG entry, and compare the members' reports before
# and after (pwsh -NoProfile -File <member> -Stdout, then tools/validate.sh
# --report). To add a helper: it goes in only when it is byte-identical in
# every member; one that differs (DumpFile) stays in its collector.
#
# What the blocks rely on the members to define: the -Quiet switch ($Quiet,
# read by Progress) and $script:PRIV_GAP (set by the member's privilege line in
# [1], read by Priv-Hint). Everything else they use they set themselves.
# Saved as UTF-8 with a BOM like the members, so Windows PowerShell 5.1 reads
# the em dash of the banners as one character.
# -----------------------------------------------------------------------------
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
