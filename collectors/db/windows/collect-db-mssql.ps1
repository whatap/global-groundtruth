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

$COLLECTOR_NAME = "whatap-db-mssql"
# History: ../CHANGELOG.md, section windows/collect-db-mssql.ps1 (next to the db README).
$VERSION        = "0.7.3"
$DOMAIN         = "db"
$CompName = $env:COMPUTERNAME; if (-not $CompName) { $CompName = [Environment]::MachineName }
$TARGET         = "db-host/$CompName"

function Usage {
    return @"
$COLLECTOR_NAME $VERSION -- a WhaTap Global Groundtruth collector (facts only).
Target: a Windows host running the WhaTap DBX agent for SQL Server.
A collection needs an explicit action flag so nothing starts by accident.

  .\collect-db-mssql.ps1                 print this help (no collection)
  .\collect-db-mssql.ps1 -File           write report -> .\$COLLECTOR_NAME-<host>-<UTC>.txt
  .\collect-db-mssql.ps1 -Stdout         print report to stdout
  .\collect-db-mssql.ps1 -Quiet ...      silence progress narration
  .\collect-db-mssql.ps1 -Home <dir>     add an agent install dir, repeatable (also -AgentHome)
  .\collect-db-mssql.ps1 -File -Out <dir> write the report into <dir> (default: the current directory)
  .\collect-db-mssql.ps1 -Help | -h      print this help
The shell spellings --file, --stdout, --quiet, --home <dir>, --out <dir> and --help work too.

Companion SQL pack: windows\mssql.sql, run through sqlcmd with the monitoring
account (the command is in README.md); paste its output with this report.
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
# Windows that puts non-ASCII AM/PM words in the report.
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
# stdout when the script runs as `pwsh -File ... > out`, so its lines would
# land in the report. docs/output-format.md, operator streams table.
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
# a not elevated local logon that reads every other class). WMI refuses every
# class to a non-administrator's network logon (OpenSSH), about 5 s per
# refusal, where the same account in a local logon reads them. The first query
# is the probe below.
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
#     a second in turn, so on a 4-vCPU host one read takes several seconds,
#     uses up the shared budget and leaves every field n/a;
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
# with room for WMI's refusal of a network logon (about 5 s, more than the
# host load's 4 s, which would end as "Timed out" first). A refusal of this
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
# collectors do with _priv_hint. $PRIV_GAP is set by the member's privilege line
# in [1] when the run is not elevated, and stays empty otherwise.
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
# decodes a file without a BOM in the ANSI code page, which garbles the
# non-ASCII text (a Korean comment) of a BOM-less UTF-8 whatap.conf in the
# verbatim dump. Reads at most 1 MiB, the size of no conf file.
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
# answer is logged as capped, so the time it spent shows in the time log. An
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
function DumpFile([string]$label, [string]$path, [int]$max = 400) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $content = @(Read-Lines $path)
        $total = @($content).Count
        if ($total -eq 0) { Fact "${label}: (empty file)"; return }
        $shown = if ($total -gt $max) { ", first $max shown" } else { "" }
        if ($script:ReadNote) { $shown += ", $($script:ReadNote)" }
        Fact "$label (verbatim, $total lines$shown):"
        @($content)[0..([Math]::Min($total, $max) - 1)] | ForEach-Object { Emit ("        " + $_) }
        # past the cap, every line that can set a key: not blank, not a # comment
        if ($total -gt $max) {
            $all = @($content)
            $rest = @(for ($k = $max; $k -lt $total; $k++) { if ($all[$k] -notmatch '^\s*(#|$)') { "$($k + 1): $($all[$k])" } })
            if ($rest.Count -gt 0) { Fact "$label, lines after line $max that are not blank or # comments (line: text):"; $rest | ForEach-Object { Emit ("        " + $_) } }
            else { Fact "$label, lines after line $max that are not blank or # comments: none" }
        }
    } catch { Fact "${label}: n/a (permission denied or unreadable: $path)" }
}
# Log-Lines LINES SCOPE SPECS -> for each pattern of SPECS (@(label, regex,
# mode), case-insensitive as Select-String is) what LINES hold: with mode a
# number N the number of matching lines and the first N of them; with mode
# "code" the number of matches (occurrences, as -AllMatches counts them) and,
# per distinct match (a WA code) in order of first appearance, its
# occurrences and the first line holding it. Such a first line is cut at
# 400 UTF-8 bytes on a character boundary, and one already printed in this
# call is named instead; the N sample lines (N > 1, the 0.6.0 samples) are
# printed whole.
function Cut-Line([string]$l) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($l)
    if ($b.Length -le 400) { return $l }
    $n = 400; while ($n -gt 0 -and ($b[$n] -band 0xC0) -eq 0x80) { $n-- }
    return ([System.Text.Encoding]::UTF8.GetString($b, 0, $n) + " (first $n of $($b.Length) bytes)")
}
function Log-Lines($lines, [string]$scope, $specs) {
    Fact "lines read for the patterns below: $(@($lines).Count) ($scope)"
    $shown = @{}
    $show = { param($l, $tag) if ($shown.ContainsKey($l)) { "(the line shown for $($shown[$l]))" } else { $shown[$l] = $tag; Cut-Line $l } }
    foreach ($sp in $specs) {
        $re = New-Object System.Text.RegularExpressions.Regex($sp[1], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $c = 0; $firsts = New-Object System.Collections.Generic.List[string]
        $codes = New-Object System.Collections.Generic.List[string]; $n = @{}; $l1 = @{}
        foreach ($l in $lines) {
            if (-not $re.IsMatch($l)) { continue }
            if ($sp[2] -ne 'code') { $c++; if ($firsts.Count -lt [int]$sp[2]) { $firsts.Add($l) }; continue }
            foreach ($m in $re.Matches($l)) {
                $v = ($m.Value -replace '[()]', '').ToUpperInvariant()
                if (-not $n.ContainsKey($v)) { $codes.Add($v); $n[$v] = 0; $l1[$v] = $l }
                $n[$v]++; $c++
            }
        }
        if ($c -eq 0) { Fact "$($sp[0]): none"; continue }
        if ($sp[2] -eq 'code') {
            Fact "$($sp[0]) ($c occurrences); per code, its occurrences and the first line holding it:"
            foreach ($v in $codes) { Emit ("        {0} ({1} occurrences): {2}" -f $v, $n[$v], (& $show $l1[$v] $v)) }
        } elseif ([int]$sp[2] -eq 1) { Fact "$($sp[0]) ($c lines): $(& $show $firsts[0] $sp[0])" }
        else {
            Fact "$($sp[0]) ($c lines), first $($firsts.Count):"
            foreach ($l in $firsts) { Emit ("        " + $l) }
        }
    }
}

# ---- discovery ---------------------------------------------------------------
# Win32_Process.CommandLine is empty for another user's process when the run is
# not elevated, so an agent process can be invisible to the scan; java
# processes whose command line could not be read are counted for that reason.
$agentProcs = @(); $procErr = ""; $javaUnread = @()
try {
    $allProc = @(Get-CimBounded Win32_Process)
    $agentProcs = @($allProc | Where-Object { $_.CommandLine -match 'whatap\.agent\.(dbx|dmx|prx|xos)' -or $_.CommandLine -match 'dbxc' })
    $javaUnread = @($allProc | Where-Object { $_.Name -match '^javaw?\.exe$' -and -not $_.CommandLine })
} catch { $allProc = $null; $procErr = $_.Exception.Message.Split("`n")[0].Trim() }

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
TryFact "os" { $o = Get-CimBounded Win32_OperatingSystem; "$($o.Caption) $($o.Version)" }
if ($env:PROCESSOR_ARCHITECTURE) { Fact "architecture: $env:PROCESSOR_ARCHITECTURE" }
else { TryFact "architecture (PROCESSOR_ARCHITECTURE not set; runtime OSArchitecture)" { "$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" } }
TryFact "memory MB (total/free)" { $os = Get-CimBounded Win32_OperatingSystem; "{0} / {1}" -f [int]($os.TotalVisibleMemorySize/1024), [int]($os.FreePhysicalMemory/1024) }
Fact "system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') (timezone: $([TimeZoneInfo]::Local.Id))"
Fact "system time (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
TryFact "java on PATH" { Invoke-Bounded java @("-version") }

Section "B. Component discovery"
if ($null -eq $allProc) { Fact "process inventory: n/a (Win32_Process query failed: $procErr)"; Fact "whatap agent processes found: n/a (process inventory not read)" }
else { Fact "whatap agent processes found: $($agentProcs.Count)" }
Fact "java processes whose command line was not readable: $($javaUnread.Count)"
foreach ($p in $agentProcs) {
    $cl = if ($p.CommandLine.Length -gt 180) { $p.CommandLine.Substring(0,180) + " ..." } else { $p.CommandLine }
    Fact "process: pid=$($p.ProcessId) start=$(Fmt-Time $p.CreationDate) cmd=$cl"
}
# from the Win32_Process inventory read above, not a second process list; the
# command line carries the instance (-sMSSQLSERVER, -sDBX2), empty when
# another account's process is not readable to this run
if ($null -eq $allProc) { Fact "sqlservr processes on this host: n/a (process inventory not read)" }
else {
    $sp = @($allProc | Where-Object { $_.Name -ieq 'sqlservr.exe' })
    if ($sp.Count -eq 0) { Fact "sqlservr processes on this host: none" }
    else { FactBlock "sqlservr processes on this host" @($sp | ForEach-Object { "pid=$($_.ProcessId) start=$(Fmt-Time $_.CreationDate) cmd=$(if ($_.CommandLine) { $_.CommandLine } else { 'n/a (not readable)' })" }) }
}
# SQL Server instances installed on this host, from the registry every account
# may read (no SQL login, no process access): Instance Names\SQL maps each
# instance name to its id, and <id>\Setup holds Version, PatchLevel, Edition
# and SQLBinRoot, whose sqlservr.exe carries the FileVersion. Both registry
# views on a 64-bit OS: a 32-bit instance registers under WOW6432Node.
$sqlRoot = 'SOFTWARE\Microsoft\Microsoft SQL Server'
$sqlViews = @(,@('64-bit', [Microsoft.Win32.RegistryView]::Registry64))
if ([Environment]::Is64BitOperatingSystem) { $sqlViews += ,@('32-bit', [Microsoft.Win32.RegistryView]::Registry32) }
else { $sqlViews = @(,@('32-bit', [Microsoft.Win32.RegistryView]::Registry32)) }
foreach ($sv in $sqlViews) {
    $vlabel = "SQL Server instances ($($sv[0]) registry view, HKLM\$sqlRoot\Instance Names\SQL)"
    $base = $null; $names = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $sv[1])
        $names = $base.OpenSubKey("$sqlRoot\Instance Names\SQL", $false)
    } catch { Fact "${vlabel}: n/a (error: $($_.Exception.Message.Split("`n")[0]))"; if ($base) { $base.Close() }; continue }
    if (-not $names) { Fact "${vlabel}: none (registry key not found)"; $base.Close(); continue }
    $inst = @($names.GetValueNames() | Where-Object { $_ })
    Fact "${vlabel}: $($inst.Count)"
    foreach ($iname in $inst) {
        $iid = "$($names.GetValue($iname))"
        $setup = $null
        try { $setup = $base.OpenSubKey("$sqlRoot\$iid\Setup", $false) }
        catch { Fact "instance ${iname} (id $iid): n/a (error: $($_.Exception.Message.Split("`n")[0]))"; continue }
        if (-not $setup) { Fact "instance ${iname} (id $iid): n/a (registry key not found: HKLM\$sqlRoot\$iid\Setup)"; continue }
        $sv2 = @{}
        foreach ($vn in @('Version', 'PatchLevel', 'Edition', 'SQLBinRoot')) {
            $v = $setup.GetValue($vn); $sv2[$vn] = if ($null -eq $v) { "n/a (value not set)" } else { "$v" }
        }
        $setup.Close()
        Fact "instance ${iname} (id $iid): Version=$($sv2.Version)  PatchLevel=$($sv2.PatchLevel)  Edition=$($sv2.Edition)"
        if ($sv2.SQLBinRoot -like 'n/a*') { Fact "instance ${iname} sqlservr.exe: n/a (Setup\SQLBinRoot not set)"; continue }
        $exe = Join-Path $sv2.SQLBinRoot "sqlservr.exe"
        try {
            $fv = (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.FileVersion
            Fact "instance ${iname} sqlservr.exe: $exe  FileVersion=$(if ($fv) { $fv } else { 'n/a (no version resource)' })"
        } catch {
            $st = if ($_.Exception -is [System.Management.Automation.ItemNotFoundException]) { "path not found" } else { "unreadable: $($_.Exception.Message.Split("`n")[0])" }
            Fact "instance ${iname} sqlservr.exe: n/a (${st}: $exe)"
        }
    }
    $names.Close(); $base.Close()
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
            ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Length, (Fmt-Time $_.LastWriteTime) }
    }
    $jdbc = Join-Path $h "jdbc"
    if (Test-Path -LiteralPath $jdbc) { TryFact "jdbc drivers" { Get-ChildItem -LiteralPath $jdbc -Name } }
    else { Fact "jdbc drivers: n/a (path not found: $jdbc)" }
    foreach ($f in @("uid.bat","db.user","start.bat","startd.bat","stop.bat","dbx.conf")) {
        $p = Join-Path $h $f
        if (Test-Path -LiteralPath $p) { $fi = Get-Item -LiteralPath $p; Fact "${f}: present ($($fi.Length) bytes, $(Fmt-Time $fi.LastWriteTime))" }
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
TryFact "services matching whatap/dbx (name, state, start mode, account, path)" {
    $s = @(Get-CimBounded Win32_Service | Where-Object { $_.Name -match 'whatap|dbx' -or $_.DisplayName -match 'whatap|dbx' })
    if ($s.Count -eq 0) { "none" }
    else { $s | ForEach-Object { "{0}  state={1}  startmode={2}  account={3}  path={4}" -f $_.Name, $_.State, $_.StartMode, $_.StartName, $_.PathName } }
}
# schtasks, not Get-ScheduledTask: the same task list, but importing the
# ScheduledTasks module in a bounded runspace took 2.8-5.5 s against 1.8 s
# for schtasks (0.4.0, Windows Server 2022). The lines are verbatim CSV:
# "folder\name","next run time","status", localized by Windows.
TryFact "scheduled tasks matching whatap/dbx (schtasks /query /fo csv)" {
    $m = @(Invoke-Bounded schtasks @("/query", "/fo", "csv", "/nh") | Where-Object { $_ -match 'whatap|dbx' })
    if ($m.Count -eq 0) { $(if ($isAdmin) { "none" } else { "none among the tasks this account can see (not elevated)" }) } else { $m }
}

Section "F. Agent logs"
$anyLog = $false
foreach ($h in $homes) {
    foreach ($ld in @((Join-Path $h "logs"), $h)) {
        $logs = @(Get-ChildItem -LiteralPath $ld -Filter "whatap*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($logs.Count -eq 0) { continue }
        $anyLog = $true
        Emit ""; Emit "    -- log dir: $ld --"
        FactBlock "log files (newest 15)" ($logs | Select-Object -First 15 | ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Length, (Fmt-Time $_.LastWriteTime) })
        $n = $logs[0]
        Fact "newest agent log: $($n.FullName)  $($n.Length) bytes  mtime $(Fmt-Time $n.LastWriteTime)"
        $win = @(Get-Content -LiteralPath $n.FullName -Tail 5000 -Encoding UTF8 -ErrorAction SilentlyContinue)
        Fact "system time at collection: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        Log-Lines $win "the last 5000 lines of the log; the last 200 of them follow verbatim" @(
            @('WA codes', '\(WA\d{3}\)', 'code'),
            @('exception lines', 'Exception|SQLException', '3'),
            @('TLS/SSL/login lines', 'TLS|SSL|Login failed', '1'))
        Emit ""; Emit "    -- verbatim tail (200 lines): $($n.FullName) --"
        @($win | Select-Object -Last 200) | ForEach-Object { Emit ("        " + $_) }
        break
    }
}
if (-not $anyLog) { Fact "agent logs: n/a (no whatap*.log under discovered homes)" }

Section "G. Topology & network (per instance)"
# the .NET interface list, in process: Get-NetIPAddress gave the same
# addresses in 1.4 s (module import), this in 0.2 s (0.4.0, Windows Server 2022)
TryFact "local ipv4 addresses" {
    @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { "$($_.Address)" }) -join " "
}
if ($instances.Count -eq 0) { Fact "n/a (no instance dir discovered)" }
foreach ($i in $instances) {
    Emit ""; Emit "    -- instance: $i --"
    $cf = Join-Path $i "whatap.conf"
    try { $null = Get-Content -LiteralPath $cf -TotalCount 1 -ErrorAction Stop }
    catch { Fact "whatap.conf: n/a (not readable: $cf)"; continue }
    # the keys are in section D (verbatim); each probe line names its target
    $dbip = ConfGet $cf "db_ip"; $dbport = ConfGet $cf "db_port"
    $whost = ConfGet $cf "whatap\.server\.host"; $wport = ConfGet $cf "whatap\.server\.port"
    $wp = 6600; if ($wport -match '^\d+$') { $wp = [int]$wport }
    if ($dbip -and $dbport -match '^\d+$') { TcpProbe "db reachability" $dbip ([int]$dbport) }
    else { Fact "db reachability: n/a (not applicable: db_ip / numeric db_port not set)" }
    if ($whost) { foreach ($w in ($whost -split '[/,]')) { if ($w.Trim()) { TcpProbe "collection server reachability" $w.Trim() $wp } } }
    else { Fact "collection server reachability: n/a (not applicable: whatap.server.host not set)" }
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
elseif ($null -eq $allProc) { Set-Missed install ("Win32_Process query failed: $procErr" + $(if ($procErr -match 'denied') { Priv-Hint } else { "" })) }
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
