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
$VERSION        = "0.1.0"
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

Section "Collection environment"
Fact "powershell: $($PSVersionTable.PSVersion)"
Fact "user: $env:USERDOMAIN\$env:USERNAME"
TryFact "administrator role" { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

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
Emit "==== END OF COLLECTION (no diagnosis by design) ===="

# ---- output --------------------------------------------------------------------
if ($Stdout) {
    $script:Lines | ForEach-Object { Write-Output $_ }
} else {
    $out = ".\$COLLECTOR_NAME-$env:COMPUTERNAME-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).txt"
    $script:Lines | Set-Content -Path $out -Encoding UTF8
    if (-not $Quiet) { Write-Host ">> report written: $out" }
}
