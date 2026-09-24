# WhaTap Global Groundtruth — DB collector, Windows / MSSQL agent host
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
#   .\collect-db-mssql.ps1 -Home <dir>    add an agent install dir the process scan cannot see
#
# CONTRACT (../../CONTRACT.md): facts only — no conclusion in any emitted line;
# discover, never assume; one field command -> paste. Config files are dumped
# verbatim (framework policy: sensitive material is stored encrypted).
# -----------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch]$File,
    [switch]$Stdout,
    [switch]$Quiet,
    [string[]]$Home = @()
)

$COLLECTOR_NAME = "whatap-db-mssql"
$VERSION        = "0.2.0"
$DOMAIN         = "db"
$TARGET         = "db-host/$env:COMPUTERNAME"

if (-not $File -and -not $Stdout) {
    Write-Output @"
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Target: a Windows host running the WhaTap DBX agent for SQL Server.
A collection needs an explicit action flag so nothing starts by accident.

  .\collect-db-mssql.ps1                 print this help (no collection)
  .\collect-db-mssql.ps1 -File           write report -> .\$COLLECTOR_NAME-<host>-<UTC>.txt
  .\collect-db-mssql.ps1 -Stdout         print report to stdout
  .\collect-db-mssql.ps1 -Home <dir>     add an agent install dir (repeatable via array)

Companion SQL pack: run windows\mssql.sql via sqlcmd with the monitoring
account and paste its output together with this report.
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
    if (-not $Quiet) { Write-Host ">> [$script:SectionN] $t" }
}

# ---- collection completeness — DO NOT EDIT ----------------------------------
# A collector knows, at the host, whether it obtained what it came for. Saying so
# is a fact about THIS COLLECTION RUN, not a claim about the environment, so it
# stays inside CONTRACT rule 1 ("Saying whether the collection worked").
#
# Why it exists. A report full of "n/a (permission denied)" reads as finished to
# an operator whose console only said ">> done.". They package it and send it,
# and the gap surfaces days later in another time zone. Real case: two of three
# collection-server bundles came back carrying no conf at all (Smartfren,
# 2026-09-23). Every fact needed to catch that was already on the host.
#
# This is the PowerShell port of the shell block in
# templates/collector-skeleton/collector-skeleton.sh. Keep the two in step.
# Three outcomes, not two. The status answers one question: send this, or change
# something and run again? An absence is Set-Na when it IS the answer and no
# re-run would change it (the product is not installed here); it is Set-Missed
# when this run was blocked and running it differently would obtain the value.
# Only Set-Missed makes a run INCOMPLETE — marking a normal environment
# INCOMPLETE would teach the field to ignore the line.
$script:Goals = [ordered]@{}   # key -> label
$script:Oks   = @{}            # key -> $true
$script:Nas   = @{}            # key -> reason it does not apply here
$script:Gaps  = @{}            # key -> reason this run was blocked

function Add-Goal([string]$key, [string]$label) { $script:Goals[$key] = $label }
function Set-Got([string]$key)                  { $script:Oks[$key] = $true }
function Set-Na([string]$key, [string]$why)     { $script:Nas[$key] = $why }
function Set-Missed([string]$key, [string]$why) { $script:Gaps[$key] = $why }

# Notice: like Progress, but NOT silenced by -Quiet. The one line that decides
# whether a run is worth sending is not narration; an automated caller wants it.
function Notice([string]$s) { Write-Host ">> $s" }

function Emit-Status {
    if ($script:Goals.Count -eq 0) { return }
    $total = $script:Goals.Count
    $ok      = @($script:Goals.Keys | Where-Object { $script:Oks.ContainsKey($_) })
    $naKeys  = @($script:Goals.Keys | Where-Object { -not $script:Oks.ContainsKey($_) -and $script:Nas.ContainsKey($_) })
    $gapKeys = @($script:Goals.Keys | Where-Object { -not $script:Oks.ContainsKey($_) -and -not $script:Nas.ContainsKey($_) })
    Section "Collection status"
    Fact ("goals: {0} declared, {1} obtained, {2} not applicable here, {3} blocked" -f $total, $ok.Count, $naKeys.Count, $gapKeys.Count)
    if ($ok.Count -gt 0) {
        Fact ("obtained: " + (($ok | ForEach-Object { $script:Goals[$_] }) -join ", "))
    }
    if ($naKeys.Count -gt 0) {
        Fact "not applicable to this host (this is an answer, not a gap):"
        foreach ($k in $naKeys) { Fact ("    {0} — {1}" -f $script:Goals[$k], $script:Nas[$k]) }
    }
    if ($gapKeys.Count -eq 0) {
        Fact "status: COMPLETE"
        $suffix = if ($naKeys.Count -gt 0) { " ({0} not applicable to this host)" -f $naKeys.Count } else { "" }
        Notice ("status: COMPLETE — nothing was blocked" + $suffix)
    } else {
        Fact "blocked (running this differently would obtain these):"
        foreach ($k in $gapKeys) {
            $why = if ($script:Gaps.ContainsKey($k)) { $script:Gaps[$k] } else { "not reached" }
            Fact ("    {0} — {1}" -f $script:Goals[$k], $why)
        }
        Fact "status: INCOMPLETE"
        Notice ("status: INCOMPLETE — {0} of {1} goals blocked" -f $gapKeys.Count, $total)
        foreach ($k in $gapKeys) {
            $why = if ($script:Gaps.ContainsKey($k)) { $script:Gaps[$k] } else { "not reached" }
            Notice ("  {0} — {1}" -f $script:Goals[$k], $why)
        }
    }
}
function TryFact([string]$label, [scriptblock]$sb) {
    try { FactBlock $label (& $sb) }
    catch { Fact "${label}: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
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
$agentProcs = @()
try {
    $agentProcs = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -match 'whatap\.agent\.(dbx|dmx|prx|xos)' -or $_.CommandLine -match 'dbxc' })
} catch { }

$homes = New-Object System.Collections.Generic.List[string]
foreach ($h in $Home) { if (Test-Path -LiteralPath $h) { $homes.Add((Resolve-Path -LiteralPath $h).Path) } }
foreach ($p in $agentProcs) {
    if ($p.CommandLine -match '([A-Za-z]:\\[^"\s]*whatap\.agent\.[a-z]+[^"\s]*\.jar)') {
        $d = Split-Path -Parent $Matches[1]
        if ((Test-Path -LiteralPath $d) -and (-not $homes.Contains($d))) { $homes.Add($d) }
    }
    try {
        $d = (Get-Process -Id $p.ProcessId -ErrorAction Stop).Path | Split-Path -Parent
        if ($d -and (Test-Path -LiteralPath $d) -and (-not $homes.Contains($d))) { $homes.Add($d) }
    } catch { }
}
$instances = New-Object System.Collections.Generic.List[string]
foreach ($h in $homes) {
    Get-ChildItem -LiteralPath $h -Filter whatap.conf -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        ForEach-Object { $d = $_.DirectoryName; if (-not $instances.Contains($d)) { $instances.Add($d) } }
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
Add-Goal instance "agent instance (a dir holding whatap.conf)"

Section "Collection environment"
Fact "powershell: $($PSVersionTable.PSVersion)"
Fact "user: $env:USERDOMAIN\$env:USERNAME"
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
    $PRIV_WHY = "elevated ($env:USERDOMAIN\$env:USERNAME)"; $PRIV_GAP = ""
} else {
    $PRIV_WHY = "not elevated ($env:USERDOMAIN\$env:USERNAME)"
    $PRIV_GAP = "run PowerShell as Administrator"
}
Fact "privilege: $PRIV_WHY"

Section "A. Host & platform"
TryFact "os" { (Get-CimInstance Win32_OperatingSystem).Caption + " " + (Get-CimInstance Win32_OperatingSystem).Version }
Fact "architecture: $env:PROCESSOR_ARCHITECTURE"
TryFact "memory MB (total/free)" { $os = Get-CimInstance Win32_OperatingSystem; "{0} / {1}" -f [int]($os.TotalVisibleMemorySize/1024), [int]($os.FreePhysicalMemory/1024) }
Fact "system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') (timezone: $([TimeZoneInfo]::Local.Id))"
Fact "system time (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
TryFact "java on PATH" { (& java -version 2>&1) }

Section "B. Component discovery & host role"
Fact "whatap agent processes found: $($agentProcs.Count)"
foreach ($p in $agentProcs) {
    $cl = if ($p.CommandLine.Length -gt 180) { $p.CommandLine.Substring(0,180) + " ..." } else { $p.CommandLine }
    Fact "process: pid=$($p.ProcessId) start=$($p.CreationDate) cmd=$cl"
}
TryFact "sqlservr process on this host" { @(Get-Process sqlservr -ErrorAction Stop | ForEach-Object { "pid=$($_.Id) start=$($_.StartTime)" }) }
if ($homes.Count -eq 0) { Fact "agent install dir: n/a (no whatap agent process found and no -Home given)" }
foreach ($h in $homes) { Fact "install dir candidate: $h" }
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
    @(Get-Service -ErrorAction Stop | Where-Object { $_.Name -match 'whatap|dbx' -or $_.DisplayName -match 'whatap|dbx' } |
        ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Status, $_.StartType })
}
TryFact "scheduled tasks matching whatap" {
    @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -match 'whatap|dbx' } |
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
TryFact "local ip addresses" { @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { $_.IPAddress }) -join " " }
if ($instances.Count -eq 0) { Fact "n/a (no instance dir discovered)" }
foreach ($i in $instances) {
    Emit ""; Emit "    -- instance: $i --"
    $cf = Join-Path $i "whatap.conf"
    $dbms  = ConfGet $cf "dbms";  $dbip = ConfGet $cf "db_ip"
    $dbport = ConfGet $cf "db_port"; $whost = ConfGet $cf "whatap\.server\.host"
    Fact "dbms: $(if ($dbms) { $dbms } else { 'n/a (key not set)' })"
    Fact "db_ip: $(if ($dbip) { $dbip } else { 'n/a' })   db_port: $(if ($dbport) { $dbport } else { 'n/a' })"
    Fact "whatap.server.host: $(if ($whost) { $whost } else { 'n/a (key not set)' })"
    if ($dbip -and $dbport) { TcpProbe "db reachability" $dbip ([int]$dbport) }
    if ($whost) { foreach ($w in ($whost -split '[/,]')) { if ($w.Trim()) { TcpProbe "collection server reachability" $w.Trim() 6600 } } }
}

Section "H. Companion steps for DB-side facts"
Fact "this report covers host-side facts only; DB-internal facts (permissions,"
Fact "AlwaysOn state, encryption) come from the companion T-SQL pack:"
Fact "run windows\mssql.sql via sqlcmd with the monitoring account and paste its output, e.g.:"
Fact "  sqlcmd -S <db_ip>,<db_port> -U <monitoring_user> -P *** -i mssql.sql -o mssql-facts.txt"

Emit ""
if ($homes.Count -gt 0) { Set-Got install }
else { Set-Na install "no whatap DB agent is installed on this host (no agent process, no -Home given)" }
if ($instances.Count -gt 0) { Set-Got instance }
elseif ($homes.Count -eq 0) { Set-Na instance "no install dir exists to hold an instance" }
else { Set-Missed instance "install dir discovered but no directory under it holds a readable whatap.conf" }
Emit-Status
Emit "==== END OF COLLECTION (no diagnosis by design) ===="

# ---- output --------------------------------------------------------------------
if ($Stdout) {
    $script:Lines | ForEach-Object { Write-Output $_ }
} else {
    $out = ".\$COLLECTOR_NAME-$env:COMPUTERNAME-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).txt"
    $script:Lines | Set-Content -Path $out -Encoding UTF8
    if (-not $Quiet) { Write-Host ">> report written: $out" }
}
