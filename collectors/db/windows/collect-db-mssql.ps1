# WhaTap Global Groundtruth -- DB collector, Windows / MSSQL agent host
# -----------------------------------------------------------------------------
# Collects facts about a WhaTap DBX agent installation monitoring SQL Server
# on a Windows host. The DBX agent queries the DB over JDBC, so this host and
# the SQL Server host may differ; DB-internal facts come from the companion
# windows/mssql.sql pack (run via sqlcmd with the monitoring account).
#
# Usage (PowerShell 5.1+):
#   .\collect-db-mssql.ps1                 print this help (no collection)
#   .\collect-db-mssql.ps1 -File          write report -> .\whatap-db-mssql-<host>-<UTC>.txt
#   .\collect-db-mssql.ps1 -Stdout        print report to stdout
#   .\collect-db-mssql.ps1 -AgentHome <dir>  add an agent install dir the process scan cannot see
#
# CONTRACT (../../CONTRACT.md): facts only -- no conclusion in any emitted line;
# discover, never assume; one field command -> paste. Config files are dumped
# verbatim (framework policy: no masking); README.md, "What the report can
# contain", lists every place a secret can arrive from.
#
# Saved as UTF-8 with a BOM and kept ASCII in every emitted string, so Windows
# PowerShell 5.1 reads it the same way pwsh 7 does.
# -----------------------------------------------------------------------------
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$File,
    [switch]$Stdout,
    [switch]$Quiet,
    # Not "$Home": PowerShell variables are case-insensitive, so a parameter
    # named Home is the read-only automatic $HOME and every run died with
    # "Cannot overwrite variable Home" (0.2.0). -Home still binds, as an alias.
    [Alias("Home")]
    [string[]]$AgentHome = @()
)

$COLLECTOR_NAME = "whatap-db-mssql"
$VERSION        = "0.3.0"
$DOMAIN         = "db"
$CompName = $env:COMPUTERNAME; if (-not $CompName) { $CompName = [Environment]::MachineName }
$TARGET         = "db-host/$CompName"

if (-not $File -and -not $Stdout) {
    Write-Output @"
$COLLECTOR_NAME $VERSION -- a WhaTap Global Groundtruth collector (facts only).
Target: a Windows host running the WhaTap DBX agent for SQL Server.
A collection needs an explicit action flag so nothing starts by accident.

  .\collect-db-mssql.ps1                 print this help (no collection)
  .\collect-db-mssql.ps1 -File           write report -> .\$COLLECTOR_NAME-<host>-<UTC>.txt
  .\collect-db-mssql.ps1 -Stdout         print report to stdout
  .\collect-db-mssql.ps1 -Quiet ...      silence progress narration
  .\collect-db-mssql.ps1 -AgentHome <dir> add an agent install dir (repeatable via array)

Companion SQL pack: windows\mssql.sql, run through sqlcmd with the monitoring
account (the command is in README.md); paste its output with this report.
"@
    exit 0
}

$script:SectionN = 0
$script:Lines = New-Object System.Collections.Generic.List[string]

function Emit([string]$s) { $script:Lines.Add($s) }
function Fact([string]$s) { Emit ("    " + $s) }
function FactBlock([string]$label, $body) {
    $arr = @($body | Where-Object { $_ -ne $null } | ForEach-Object { "$_" })
    if ($arr.Count -eq 0 -or ($arr.Count -eq 1 -and $arr[0].Trim() -eq "")) { Fact "${label}: n/a (empty output)"; return }
    if ($arr.Count -eq 1) { Fact "${label}: $($arr[0])" }
    else {
        Fact "${label}:"
        $arr | ForEach-Object { Emit ("        " + $_) }
    }
}
function Section([string]$t) {
    $script:SectionN++
    Emit ""
    Emit ("[{0}] {1}" -f $script:SectionN, $t)
    Progress "[$script:SectionN] $t"
}


# ---- run helpers (PowerShell port) - keep identical in every .ps1 collector --
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
# (Get-Service, Get-NetTCPConnection, Get-WinEvent, ...). CIM queries carry
# -OperationTimeoutSec $script:CMD_TIMEOUT instead.
$script:CMD_TIMEOUT  = 20
$script:RUN_DEADLINE = 300
$script:RunStart     = [DateTime]::UtcNow
$script:BoundedExit  = $null
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
    $sec = Bounded-Seconds $sec
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
    $p = [System.Diagnostics.Process]::Start($psi)
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
        Bounded-Timeout $sec
    }
    if ($p.ExitCode -ne 0) { $script:BoundedExit = $p.ExitCode }
    $text = ($o.Result + $e.Result) -replace "`r", ""
    if ($text -eq "") { return @() }
    return @($text.TrimEnd("`n") -split "`n")
}
# Invoke-BoundedBlock { cmdlets } [SECONDS] -> the block's output. The block
# runs in a fresh runspace: it sees only its own text (pass values with
# $using-free literals or -ArgumentList via $args), not this script's functions.
function Invoke-BoundedBlock([scriptblock]$sb, [object[]]$argList = @(), [int]$sec = 0) {
    $sec = Bounded-Seconds $sec
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
    }
}

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
    try { $boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec $script:CMD_TIMEOUT -ErrorAction Stop).LastBootUpTime }
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
# ---- end run helpers (PowerShell port)

# ---- collection completeness (PowerShell port) - keep identical in every .ps1 collector
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
# ---- end collection completeness (PowerShell port)

function TryFact([string]$label, [scriptblock]$sb) {
    if (Past-Deadline) { Fact "${label}: n/a (run deadline reached: $($script:RUN_DEADLINE)s)"; return }
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
function DumpFile([string]$label, [string]$path, [int]$max = 400) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $content = Get-Content -LiteralPath $path -ErrorAction Stop
        $total = @($content).Count
        $shown = if ($total -gt $max) { " , first $max shown" } else { "" }
        Fact "$label (verbatim, $total lines$shown):"
        @($content)[0..([Math]::Min($total, $max) - 1)] | ForEach-Object { Emit ("        " + $_) }
    } catch { Fact "${label}: n/a (permission denied or unreadable: $path)" }
}
function ConfGet([string]$path, [string]$key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $m = Get-Content -LiteralPath $path -ErrorAction SilentlyContinue |
         Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -Last 1
    if ($m) { return ($m -split '=', 2)[1].Trim() }
    return $null
}
function TcpProbe([string]$label, [string]$dbhost, [int]$port, [int]$timeoutSec = 5) {
    if (-not $dbhost -or -not $port) { Fact "${label}: n/a (not applicable: host/port not set)"; return }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $t = $c.BeginConnect($dbhost, $port, $null, $null)
        if ($t.AsyncWaitHandle.WaitOne($timeoutSec * 1000) -and $c.Connected) {
            Fact "${label}: tcp connect to ${dbhost}:$port succeeded"
        } else {
            Fact "${label}: tcp connect to ${dbhost}:$port did not connect within ${timeoutSec}s"
        }
        $c.Close()
    } catch { Fact "${label}: tcp connect to ${dbhost}:$port did not connect ($($_.Exception.Message.Split("`n")[0]))" }
}

# ---- discovery ---------------------------------------------------------------
# Win32_Process.CommandLine is empty for another user's process when the run is
# not elevated, so an agent process can be invisible to the scan; java
# processes whose command line could not be read are counted for that reason.
$agentProcs = @(); $procErr = ""; $javaUnread = @()
try {
    $allProc = @(Get-CimInstance Win32_Process -OperationTimeoutSec $script:CMD_TIMEOUT -ErrorAction Stop)
    $agentProcs = @($allProc | Where-Object { $_.CommandLine -match 'whatap\.agent\.(dbx|dmx|prx|xos)' -or $_.CommandLine -match 'dbxc' })
    $javaUnread = @($allProc | Where-Object { $_.Name -match '^javaw?\.exe$' -and -not $_.CommandLine })
} catch { $allProc = $null; $procErr = $_.Exception.Message.Split("`n")[0] }

# Install dirs come from an absolute whatap.agent jar path in the command line,
# or a -Dwhatap.home= property. The java.exe path is the runtime, not the agent
# home, so it is not used. A relative -jar path resolves against the process
# working directory, which Win32_Process does not expose: such a process is
# listed as unresolved.
$homes = New-Object System.Collections.Generic.List[string]
$unresolved = @(); $unresWhy = @(); $homeBad = @()
foreach ($h in $AgentHome) {
    if (Test-Path -LiteralPath $h) { $homes.Add((Resolve-Path -LiteralPath $h).Path) }
    else { $homeBad += $h }
}
foreach ($p in $agentProcs) {
    $d = $null; $why = "no absolute whatap.agent jar path or -Dwhatap.home in the command line"
    # a quoted path may hold spaces (C:\Program Files\...); an unquoted one may not
    if ($p.CommandLine -match '"([A-Za-z]:\\[^"]*whatap\.agent\.[a-z]+[^"]*\.jar)"') { $d = Split-Path -Parent $Matches[1] }
    elseif ($p.CommandLine -match '([A-Za-z]:\\[^"\s]*whatap\.agent\.[a-z]+[^"\s]*\.jar)') { $d = Split-Path -Parent $Matches[1] }
    elseif ($p.CommandLine -match '-Dwhatap\.home="([A-Za-z]:\\[^"]+)"') { $d = $Matches[1].TrimEnd('\') }
    elseif ($p.CommandLine -match '-Dwhatap\.home=([A-Za-z]:\\[^"\s]+)') { $d = $Matches[1].TrimEnd('\') }
    if ($d -and (Test-Path -LiteralPath $d)) { if (-not $homes.Contains($d)) { $homes.Add($d) }; continue }
    if ($d) { $why = "path from the command line not found: $d" }
    $unresolved += "pid $($p.ProcessId)"; $unresWhy += "pid $($p.ProcessId): $why"
}
$instances = New-Object System.Collections.Generic.List[string]
$confDenied = @(); $confFailed = @()
foreach ($h in $homes) {
    # bounded: the search runs in its own runspace; its errors come back as data
    $found = @()
    try {
        $found = @(Invoke-BoundedBlock { param($d)
            Get-ChildItem -LiteralPath $d -Filter whatap.conf -Recurse -Depth 2 -ErrorAction SilentlyContinue -ErrorVariable ev |
                ForEach-Object { $_.DirectoryName }
            if ($ev) { "!ERR" } } @($h))
    } catch { $confFailed += "$h ($($_.Exception.Message.Split("`n")[0]))" }
    foreach ($d in $found) {
        if ($d -eq "!ERR") { if (-not ($confDenied -contains $h)) { $confDenied += $h }; continue }
        if (-not $instances.Contains($d)) { $instances.Add($d) }
    }
}

# ---- report -------------------------------------------------------------------
Emit "==== WhaTap Global Groundtruth Collection ===="
Emit ("Collector:      {0}" -f $COLLECTOR_NAME)
Emit ("Version:        {0}" -f $VERSION)
Emit ("Timestamp(UTC): {0}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
Emit ("Domain:         {0}" -f $DOMAIN)
Emit ("Target:         {0}" -f $TARGET)
Emit "==============================================="

# What this run is for. Resolved just before Emit-Status, where the discovery
# variables are final.
Add-Goal install  "whatap agent install dir"
Add-Goal instance "agent instance (a readable whatap.conf)"

Section "Collection environment"
Fact "powershell: $($PSVersionTable.PSVersion)"
$UserId = if ($env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { "$([Environment]::UserDomainName)\$([Environment]::UserName)" }
Fact "user: $UserId"
# The Windows port of the shell collectors' privilege line. It states one thing:
# whether this process carries an elevated token. SQL Server access is decided
# by the login's server roles, not by this, so goals name their own authority.
#
# IsInRole is the test, not group membership. Under UAC's split token an
# unelevated process still lists Administrators, as a deny-only SID, so asking
# by membership reports an unelevated run as elevated. Not TryFact either: a
# throw there would drop the line, and section 0 always states the privilege.
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

Section "A. Host & platform"
TryFact "os" { $o = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec $script:CMD_TIMEOUT -ErrorAction Stop; "$($o.Caption) $($o.Version)" }
if ($env:PROCESSOR_ARCHITECTURE) { Fact "architecture: $env:PROCESSOR_ARCHITECTURE" }
else { TryFact "architecture (PROCESSOR_ARCHITECTURE not set; runtime OSArchitecture)" { "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" } }
TryFact "memory MB (total/free)" { $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec $script:CMD_TIMEOUT -ErrorAction Stop; "{0} / {1}" -f [int]($os.TotalVisibleMemorySize/1024), [int]($os.FreePhysicalMemory/1024) }
Fact "system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') (timezone: $([TimeZoneInfo]::Local.Id))"
Fact "system time (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
TryFact "java on PATH" { Invoke-Bounded java @("-version") }

Section "B. Component discovery & host role"
if ($null -eq $allProc) { Fact "process inventory: n/a (Win32_Process query failed: $procErr)"; Fact "whatap agent processes found: n/a (process inventory not read)" }
else { Fact "whatap agent processes found: $($agentProcs.Count)" }
Fact "java processes whose command line was not readable: $($javaUnread.Count)"
foreach ($p in $agentProcs) {
    $cl = if ($p.CommandLine.Length -gt 180) { $p.CommandLine.Substring(0,180) + " ..." } else { $p.CommandLine }
    Fact "process: pid=$($p.ProcessId) start=$($p.CreationDate) cmd=$cl"
}
TryFact "sqlservr process on this host" {
    $sp = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -ieq 'sqlservr' })
    if ($sp.Count -eq 0) { "none" } else { $sp | ForEach-Object { "pid=$($_.Id) start=$($_.StartTime)" } }
}
foreach ($u in $unresWhy) { Fact "install dir of $($u -replace ':.*$', ''): n/a ($($u -replace '^[^:]*: ', ''))" }
foreach ($h in $AgentHome) { Fact "-AgentHome given: $h (exists: $(Test-Path -LiteralPath $h))" }
if ($homes.Count -eq 0 -and $unresolved.Count -eq 0 -and $AgentHome.Count -eq 0) {
    if ($null -eq $allProc) { Fact "agent install dir: n/a (process inventory not read and no -AgentHome given)" }
    else { Fact "agent install dir: n/a (no whatap agent process found and no -AgentHome given)" }
}
foreach ($h in $homes) { Fact "install dir candidate: $h" }
if ($confDenied.Count -gt 0) { Fact "whatap.conf search incomplete (an entry was not readable) under: $($confDenied -join ', ')" }
Fact "agent instances (dir with whatap.conf): $($instances.Count)"
foreach ($i in $instances) { Fact "instance: $i" }

Section "C. Agent home inventory & component versions"
if ($homes.Count -eq 0) { Fact "n/a (no install dir discovered)" }
foreach ($h in $homes) {
    Emit ""; Emit "    -- home: $h --"
    TryFact "top-level" { Get-ChildItem -LiteralPath $h -Name -ErrorAction Stop }
    TryFact "whatap component files (name=version, with mtime)" {
        Get-ChildItem -LiteralPath $h -Filter "whatap.agent.*" -ErrorAction Stop |
            ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Length, $_.LastWriteTime }
    }
    $jdbc = Join-Path $h "jdbc"
    if (Test-Path -LiteralPath $jdbc) { TryFact "jdbc drivers" { Get-ChildItem -LiteralPath $jdbc -Name } }
    else { Fact "jdbc drivers: n/a (path not found: $jdbc)" }
    foreach ($f in @("uid.bat","db.user","start.bat","startd.bat","stop.bat","dbx.conf")) {
        $p = Join-Path $h $f
        if (Test-Path -LiteralPath $p) { $fi = Get-Item -LiteralPath $p; Fact "${f}: present ($($fi.Length) bytes, $($fi.LastWriteTime))" }
        else { Fact "${f}: not present at $h" }
    }
}

Section "D. Configuration (verbatim)"
if ($instances.Count -eq 0) { Fact "whatap.conf: n/a (no instance dir discovered)" }
foreach ($i in $instances) {
    Emit ""; Emit "    -- instance: $i --"
    DumpFile "whatap.conf" (Join-Path $i "whatap.conf")
}

Section "E. Services & scheduled tasks"
TryFact "services matching whatap/dbx" {
    @(Invoke-BoundedBlock { Get-Service -ErrorAction Stop } | Where-Object { $_.Name -match 'whatap|dbx' -or $_.DisplayName -match 'whatap|dbx' } |
        ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Status, $_.StartType })
}
TryFact "scheduled tasks matching whatap" {
    @(Invoke-BoundedBlock { Get-ScheduledTask -ErrorAction Stop } | Where-Object { $_.TaskName -match 'whatap|dbx' } |
        ForEach-Object { "{0}  {1}" -f $_.TaskName, $_.State })
}

Section "F. Agent logs"
$anyLog = $false
foreach ($h in $homes) {
    foreach ($ld in @((Join-Path $h "logs"), $h)) {
        $logs = @(Get-ChildItem -LiteralPath $ld -Filter "whatap*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($logs.Count -eq 0) { continue }
        $anyLog = $true
        Emit ""; Emit "    -- log dir: $ld --"
        FactBlock "log files (newest 15)" ($logs | Select-Object -First 15 | ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Length, $_.LastWriteTime })
        $n = $logs[0]
        Fact "newest agent log: $($n.FullName) (mtime $($n.LastWriteTime))"
        $win = @(Get-Content -LiteralPath $n.FullName -Tail 5000 -ErrorAction SilentlyContinue)
        Fact "last log line (verbatim): $(@($win)[-1])"
        Fact "system time at collection: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        $wa = $win | Select-String -Pattern '\(WA\d{3}\)' -AllMatches |
              ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
              Group-Object | Sort-Object Count -Descending | Select-Object -First 15
        if ($wa) { FactBlock "WA code histogram (last 5000 lines)" ($wa | ForEach-Object { "{0,7} {1}" -f $_.Count, $_.Name }) }
        else { Fact "WA code histogram: n/a (no WA codes in last 5000 lines)" }
        Fact "exception lines: $(@($win | Select-String -Pattern 'Exception|SQLException').Count) line(s) in last 5000 log lines"
        Fact "TLS/SSL/login lines: $(@($win | Select-String -Pattern 'TLS|SSL|Login failed').Count) line(s) in last 5000 log lines"
        FactBlock "exception lines (sample)" (@($win | Select-String -Pattern 'Exception|SQLException' | Select-Object -First 3 | ForEach-Object { $_.Line }))
        Emit ""; Emit "    -- verbatim tail (200 lines): $($n.FullName) --"
        @($win | Select-Object -Last 200) | ForEach-Object { Emit ("        " + $_) }
        break
    }
}
if (-not $anyLog) { Fact "agent logs: n/a (no whatap*.log under discovered homes)" }

Section "G. Topology & network (per instance)"
TryFact "local ip addresses" { @(Invoke-BoundedBlock { Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop } | ForEach-Object { $_.IPAddress }) -join " " }
if ($instances.Count -eq 0) { Fact "n/a (no instance dir discovered)" }
foreach ($i in $instances) {
    Emit ""; Emit "    -- instance: $i --"
    $cf = Join-Path $i "whatap.conf"
    try { $null = Get-Content -LiteralPath $cf -TotalCount 1 -ErrorAction Stop }
    catch { Fact "whatap.conf: n/a (not readable: $cf)"; continue }
    $dbms  = ConfGet $cf "dbms";  $dbip = ConfGet $cf "db_ip"
    $dbport = ConfGet $cf "db_port"; $whost = ConfGet $cf "whatap\.server\.host"
    $wport = ConfGet $cf "whatap\.server\.port"
    Fact "dbms: $(if ($dbms) { $dbms } else { 'n/a (key not set)' })"
    Fact "db_ip: $(if ($dbip) { $dbip } else { 'n/a' })   db_port: $(if ($dbport) { $dbport } else { 'n/a' })"
    Fact "whatap.server.host: $(if ($whost) { $whost } else { 'n/a (key not set)' })   whatap.server.port: $(if ($wport) { $wport } elseif ($whost) { 'not set (the connect probe below uses 6600)' } else { 'not set' })"
    $wp = 6600; if ($wport -match '^\d+$') { $wp = [int]$wport }
    if ($dbip -and $dbport -match '^\d+$') { TcpProbe "db reachability" $dbip ([int]$dbport) }
    if ($whost) { foreach ($w in ($whost -split '[/,]')) { if ($w.Trim()) { TcpProbe "collection server reachability" $w.Trim() $wp } } }
}

Section "H. SQL pack"
$packDir = if ($PSScriptRoot) { $PSScriptRoot } else { "." }
$pack = Join-Path $packDir "mssql.sql"
Fact "companion T-SQL pack: $pack (present: $(Test-Path -LiteralPath $pack))"
Notice "DB-internal facts (permissions, AlwaysOn state, encryption) come from windows\mssql.sql through sqlcmd with the monitoring account (README.md)"

# install: na only when the process scan saw every command line
$unreadConf = @($instances | Where-Object {
    $f = Join-Path $_ "whatap.conf"
    try { $null = Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction Stop; $false } catch { $true } })
if ($homeBad.Count -gt 0) {
    Set-Missed install ("-AgentHome path not found: " + ($homeBad -join ', '))
} elseif ($unresolved.Count -gt 0) {
    Set-Missed install (($unresWhy -join '; ') + " (pass -AgentHome <dir>)" + $(if ($homes.Count -eq 0) { "" } else { "; found: $($homes -join ', ')" }))
} elseif ($homes.Count -gt 0) { Set-Got install }
elseif ($null -eq $allProc) { Set-Missed install "Win32_Process query failed: $procErr" }
elseif ($javaUnread.Count -gt 0 -and -not $isAdmin) {
    Set-Missed install ("no whatap agent process in the command lines read; $($javaUnread.Count) java process(es) with an unreadable command line" + (Priv-Hint))
} else { Set-Na install "no whatap agent process in any process command line, no -AgentHome given" }
if ($unreadConf.Count -gt 0) { Set-Missed instance ("not readable: " + (@($unreadConf | ForEach-Object { Join-Path $_ "whatap.conf" }) -join ', ') + (Priv-Hint)) }
elseif ($confFailed.Count -gt 0) { Set-Missed instance ("search for whatap.conf did not finish: " + ($confFailed -join ', ')) }
elseif ($confDenied.Count -gt 0) { Set-Missed instance ("search for whatap.conf hit an unreadable entry under: $($confDenied -join ', ')" + (Priv-Hint)) }
elseif ($instances.Count -gt 0) { Set-Got instance }
elseif ($homes.Count -gt 0) { Set-Missed instance "install dir discovered but no whatap.conf within depth 2" }
elseif ($homeBad.Count -gt 0 -or $unresolved.Count -gt 0 -or $null -eq $allProc -or ($javaUnread.Count -gt 0 -and -not $isAdmin)) { Set-Missed instance "no install dir resolved (see the install goal)" }
else { Set-Na instance "no install dir on this host to hold a whatap.conf" }
Emit-Status
Emit ""
Emit "==== END OF COLLECTION (no diagnosis by design) ===="

# ---- output --------------------------------------------------------------------
if ($Stdout) {
    $script:Lines | ForEach-Object { Write-Output $_ }
} else {
    $out = Join-Path "." "$COLLECTOR_NAME-$CompName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).txt"
    try { $script:Lines | Set-Content -Path $out -Encoding UTF8 -ErrorAction Stop }
    catch { Warn "the report was not written: $out ($($_.Exception.Message.Split("`n")[0]))"; exit 1 }
    Progress "report written: $out"
}
