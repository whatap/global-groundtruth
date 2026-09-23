# WhaTap Global Groundtruth -- APM .NET agent collector (Windows)
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap .NET-agent developer repeatedly asks
# a field engineer for, from the Windows host where the instrumented .NET
# application runs (IIS w3wp, .NET Core services). Derived from an exhaustive
# review of #ask-dev-apm .NET support threads (2025-06 .. 2026-08), the
# dotnet-apm source repo (installer release.iss, ClrProfiler, Tracer, Loader,
# Startup), and docs.whatap.io (install-check, supported-spec).
#
# Recurring field questions this report answers with facts:
#   * Which agent build is actually installed? The native/managed DLL file
#     versions are pinned at 1.0.0.0 across product releases, so the product
#     version lives in the uninstall registry (DisplayVersion of
#     "WhaTap .NET_is1") plus file mtimes/SHA256 of both profiler DLL copies.
#   * Are the CLR injection variables present at the scopes that matter?
#     COR_*/CORECLR_*/DOTNET_STARTUP_HOOKS are written to the W3SVC and WAS
#     service registry Environment (multi-sz), NOT machine-wide; machine env
#     carries only WHATAP_* keys. Both scopes are dumped verbatim.
#   * Does the DOTNET_STARTUP_HOOKS / COR_PROFILER_PATH value point at a file
#     that exists? (A mistyped dll name in that variable has been a full
#     instrumentation outage in the field.)
#   * Which profiler DLL did each w3wp actually load (loaded-module scan)?
#   * Native profiler log (C:\ProgramData\WhaTap\dotnet\logs\core-*.log) and
#     managed tracer logs (<date>-<id>.log) -- including the version/banner
#     lines, and file owners (log files owned by another app pool's identity
#     have caused w3wp CPU spins after PID reuse).
#   * IIS topology: app pool CLR version / bitness / identity, app -> pool
#     mapping, physical paths -- and per-app web.config assemblyBinding plus
#     bin\ facade assembly versions (System.Net.Http and friends).
#   * whatap.conf resolution chain and verbatim content, with byte-level facts
#     (BOM, CR count) that plain type/cat hides.
#   * Is the "WhaTap .NET" relay service running, and does anything hold the
#     local UDP 6600 / remote TCP 6600 endpoints?
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
# -----------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch]$File,
    [switch]$Stdout,
    [switch]$Quiet,
    [string[]]$AgentHome = @()
)

$COLLECTOR_NAME = "whatap-apmdotnet"
$VERSION        = "0.2.0"
$DOMAIN         = "apm/dotnet"
$CompName = $env:COMPUTERNAME; if (-not $CompName) { $CompName = [Environment]::MachineName }
$TARGET         = "host/$CompName"

if (-not $File -and -not $Stdout) {
    Write-Output @"
$COLLECTOR_NAME $VERSION -- a WhaTap Global Groundtruth collector (facts only).
Target: a Windows host where the WhaTap .NET agent and the instrumented
application (IIS / .NET Core) run. Run in a 64-bit elevated PowerShell for
full coverage; without elevation some probes degrade to reasoned n/a lines.
A collection needs an explicit action flag so nothing starts by accident.

  .\collect-apmdotnet.ps1                  print this help (no collection)
  .\collect-apmdotnet.ps1 -File            write report -> .\$COLLECTOR_NAME-<host>-<UTC>.txt
  .\collect-apmdotnet.ps1 -Stdout          print report to stdout
  .\collect-apmdotnet.ps1 -Quiet ...       silence progress narration
  .\collect-apmdotnet.ps1 -AgentHome <dir> add an agent install dir the discovery cannot see

If script execution is blocked by policy, run:
  powershell -ExecutionPolicy Bypass -File .\collect-apmdotnet.ps1 -File
"@
    exit 0
}

# ---- emit helpers -------------------------------------------------------------
$script:SectionN = 0
$script:Lines = New-Object System.Collections.Generic.List[string]

function Emit([string]$s) { $script:Lines.Add($s) }
function Fact([string]$s) { Emit ("    " + $s) }
function Progress([string]$s) { if (-not $Quiet) { Write-Host ">> $s" } }
function Section([string]$t) {
    $script:SectionN++
    Emit ""
    Emit ("[{0}] {1}" -f $script:SectionN, $t)
    Progress "[$script:SectionN] $t"
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
$script:Goals = [ordered]@{}   # key -> label
$script:Oks   = @{}            # key -> $true
$script:Gaps  = @{}            # key -> reason

function Add-Goal([string]$key, [string]$label) { $script:Goals[$key] = $label }
function Set-Got([string]$key)                  { $script:Oks[$key] = $true }
function Set-Missed([string]$key, [string]$why) { $script:Gaps[$key] = $why }

# Notice: like Progress, but NOT silenced by -Quiet. The one line that decides
# whether a run is worth sending is not narration; an automated caller wants it.
function Notice([string]$s) { Write-Host ">> $s" }

function Emit-Status {
    if ($script:Goals.Count -eq 0) { return }
    $total = $script:Goals.Count
    $ok    = @($script:Goals.Keys | Where-Object { $script:Oks.ContainsKey($_) })
    $gapKeys = @($script:Goals.Keys | Where-Object { -not $script:Oks.ContainsKey($_) })
    Section "Collection status"
    Fact ("goals: {0} declared, {1} obtained, {2} not obtained" -f $total, $ok.Count, $gapKeys.Count)
    if ($ok.Count -gt 0) {
        Fact ("obtained: " + (($ok | ForEach-Object { $script:Goals[$_] }) -join ", "))
    }
    if ($gapKeys.Count -eq 0) {
        Fact "status: COMPLETE"
        Notice ("status: COMPLETE — {0} of {1} goals obtained" -f $ok.Count, $total)
    } else {
        Fact "not obtained:"
        foreach ($k in $gapKeys) {
            $why = if ($script:Gaps.ContainsKey($k)) { $script:Gaps[$k] } else { "not reached" }
            Fact ("    {0} — {1}" -f $script:Goals[$k], $why)
        }
        Fact "status: INCOMPLETE"
        Notice ("status: INCOMPLETE — {0} of {1} goals not obtained" -f $gapKeys.Count, $total)
        foreach ($k in $gapKeys) {
            $why = if ($script:Gaps.ContainsKey($k)) { $script:Gaps[$k] } else { "not reached" }
            Notice ("  {0} — {1}" -f $script:Goals[$k], $why)
        }
    }
}
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
    try { FactBlock $label (& $sb) }
    catch { Fact "${label}: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
}

# ---- reasoned-absence helpers -------------------------------------------------
# DumpFile: verbatim, line-capped. Framework policy: configuration is dumped
# verbatim, never masked (see README security note).
function DumpFile([string]$label, [string]$path, [int]$max = 400) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $content = @(Get-Content -LiteralPath $path -TotalCount ($max + 1) -ErrorAction Stop)
        if ($content.Count -eq 0) { Fact "${label}: (empty file)"; return }
        $more = ""
        if ($content.Count -gt $max) { $content = $content[0..($max-1)]; $more = " (first $max lines, truncated)" }
        Fact "$label (verbatim$more):"
        $content | ForEach-Object { Emit ("        " + $_) }
    } catch { Fact "${label}: n/a (unreadable: $path -- $($_.Exception.Message.Split("`n")[0]))" }
}
function TailFile([string]$label, [string]$path, [int]$n = 150) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $t = @(Get-Content -LiteralPath $path -Tail $n -ErrorAction Stop)
        if ($t.Count -eq 0) { Fact "${label}: (empty file)"; return }
        Fact "$label (last $($t.Count) lines):"
        $t | ForEach-Object { Emit ("        " + $_) }
    } catch { Fact "${label}: n/a (unreadable: $path -- $($_.Exception.Message.Split("`n")[0]))" }
}
function HeadFile([string]$label, [string]$path, [int]$n = 60) {
    if (-not (Test-Path -LiteralPath $path)) { Fact "${label}: n/a (path not found: $path)"; return }
    try {
        $t = @(Get-Content -LiteralPath $path -TotalCount $n -ErrorAction Stop)
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
# RegValue: one registry value with reasoned absence.
function RegValue([string]$label, [string]$key, [string]$name) {
    if (-not (Test-Path -LiteralPath $key)) { Fact "${label}: n/a (registry key not found: $key)"; return }
    try {
        $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        if ($null -eq $p.$name -and -not ($p.PSObject.Properties.Name -contains $name)) { Fact "${label}: not set (key present: $key)"; return }
        $v = $p.$name
        if ($v -is [System.Array]) { FactBlock $label $v } else { Fact "${label}: $v" }
    } catch { Fact "${label}: n/a (error: $($_.Exception.Message.Split("`n")[0]))" }
}
function TcpProbe([string]$label, [string]$dsthost, [int]$port, [int]$timeoutSec = 5) {
    if (-not $dsthost -or -not $port) { Fact "${label}: n/a (not applicable: host/port not set)"; return }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $t = $c.BeginConnect($dsthost, $port, $null, $null)
        if ($t.AsyncWaitHandle.WaitOne($timeoutSec * 1000) -and $c.Connected) {
            Fact "${label}: tcp connect to ${dsthost}:$port succeeded"
        } else {
            Fact "${label}: tcp connect to ${dsthost}:$port did not connect within ${timeoutSec}s"
        }
        $c.Close()
    } catch { Fact "${label}: tcp connect to ${dsthost}:$port did not connect ($($_.Exception.Message.Split("`n")[0]))" }
}
function ConfGet([string]$path, [string]$key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $m = Get-Content -LiteralPath $path -ErrorAction SilentlyContinue |
         Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -Last 1
    if ($m) { return ($m -split '=', 2)[1].Trim() }
    return $null
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
$ENV_NAME_PATTERN = '^(WHATAP_|COR_ENABLE_PROFILING|COR_PROFILER|CORECLR_|DOTNET_STARTUP_HOOKS|WT_TRACE_LOG_PATH)'

# ---- discovery: agent home candidates ------------------------------------------
$homeCandidates = New-Object System.Collections.Generic.List[string]
function AddHome([string]$p, [string]$src) {
    if (-not $p) { return }
    $p = $p.Trim('"').TrimEnd('\')
    if (-not $p) { return }
    foreach ($e in $homeCandidates) { if ($e -ieq "$p|$src") { return } }
    foreach ($e in $homeCandidates) { if (($e -split '\|', 2)[0] -ieq $p) { return } }
    $homeCandidates.Add("$p|$src")
}
foreach ($h in $AgentHome) { AddHome $h "parameter -AgentHome" }
if ($env:WHATAP_DOTNET_HOME) { AddHome $env:WHATAP_DOTNET_HOME "collector process env WHATAP_DOTNET_HOME" }
try {
    $me = Get-ItemProperty -LiteralPath $MACHINE_ENV_KEY -ErrorAction Stop
    if ($me.WHATAP_DOTNET_HOME) { AddHome $me.WHATAP_DOTNET_HOME "machine env registry WHATAP_DOTNET_HOME" }
} catch { }
# service-env profiler paths -> home = parent of parent of ...\core\Whatap.ClrProfiler.dll
$svcEnvLines = @()
foreach ($svc in @("W3SVC", "WAS")) {
    try {
        $v = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -ErrorAction Stop).Environment
        if ($v) { $svcEnvLines += @($v) }
    } catch { }
}
foreach ($line in $svcEnvLines) {
    if ($line -match '^(COR_PROFILER_PATH|CORECLR_PROFILER_PATH)(_32|_64)?=(.+)$') {
        $d = Split-Path -Parent (Split-Path -Parent $Matches[3].Trim('"'))
        AddHome $d "service env profiler path"
    }
    if ($line -match '^DOTNET_STARTUP_HOOKS=(.+)$') {
        $d = Split-Path -Parent (Split-Path -Parent $Matches[1].Trim('"'))
        AddHome $d "service env DOTNET_STARTUP_HOOKS"
    }
}
# CLSID InProcServer32 -> same parent-of-parent rule
foreach ($ck in @("HKLM:\SOFTWARE\Classes\CLSID\$CLSID_CURRENT\InProcServer32",
                  "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$CLSID_CURRENT\InProcServer32")) {
    try {
        $v = (Get-ItemProperty -LiteralPath $ck -ErrorAction Stop).'(default)'
        if ($v) { AddHome (Split-Path -Parent (Split-Path -Parent $v)) "CLSID InProcServer32" }
    } catch { }
}
# uninstall registry InstallLocation
$uninstallEntries = @()
foreach ($uk in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                  "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")) {
    try {
        $uninstallEntries += @(Get-ChildItem -LiteralPath $uk -ErrorAction Stop | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match '[Ww]ha[Tt]ap') { $p | Add-Member NoteProperty RegPath $_.PSPath -PassThru }
        } | Where-Object { $_ })
    } catch { }
}
foreach ($u in $uninstallEntries) { if ($u.InstallLocation) { AddHome $u.InstallLocation "uninstall registry InstallLocation" } }
# installer defaults (release.iss DefaultDirName; debug variant; x86 sibling)
AddHome "$ProgFiles\WhaTap .NET" "installer default"
if (${env:ProgramFiles(x86)}) { AddHome "${env:ProgramFiles(x86)}\WhaTap .NET" "installer default (x86 copy)" }
AddHome "$ProgFiles\WhaTap .NET Debug" "debug installer default"

# w3wp / dotnet / whatap process inventory (used by several sections)
$procW3wp = @(); $procDotnet = @(); $procWhatap = @()
try {
    $allProc = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $procW3wp   = @($allProc | Where-Object { $_.Name -ieq 'w3wp.exe' })
    $procDotnet = @($allProc | Where-Object { $_.Name -ieq 'dotnet.exe' })
    $procWhatap = @($allProc | Where-Object { $_.Name -imatch 'whatap' })
} catch { $allProc = $null }

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
Fact "user: $env:USERDOMAIN\$env:USERNAME"
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
Fact "administrator role: $isAdmin"
Fact "64-bit OS: $([Environment]::Is64BitOperatingSystem)   64-bit collector process: $([Environment]::Is64BitProcess)"
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Fact "note: 32-bit process on 64-bit OS -- HKLM\SOFTWARE and Program Files views below are WOW64-redirected"
}
TryFact "execution policy" { Get-ExecutionPolicy }
$appcmd = "$WinDir\System32\inetsrv\appcmd.exe"
Fact "appcmd.exe present: $(Test-Path -LiteralPath $appcmd) ($appcmd)"
Fact "WebAdministration module available: $([bool](Get-Module -ListAvailable -Name WebAdministration -ErrorAction SilentlyContinue))"
Fact "dotnet on PATH: $([bool](Get-Command dotnet -ErrorAction SilentlyContinue))"
Fact "Get-NetTCPConnection available: $([bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue))"

Section "A. Host & platform"
TryFact "os" { $o = Get-CimInstance Win32_OperatingSystem; "$($o.Caption) $($o.Version) (build $($o.BuildNumber))" }
Fact "architecture: $env:PROCESSOR_ARCHITECTURE"
TryFact "memory MB (total/free)" { $o = Get-CimInstance Win32_OperatingSystem; "{0} / {1}" -f [int]($o.TotalVisibleMemorySize/1024), [int]($o.FreePhysicalMemory/1024) }
TryFact "last boot" { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') }
Fact "system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') (timezone: $([TimeZoneInfo]::Local.Id))"
Fact "system time (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
RegValue "IIS version (InetStp VersionString)" "HKLM:\SOFTWARE\Microsoft\InetStp" "VersionString"
RegValue ".NET Framework 4.x Release (NDP\v4\Full)" "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Release"
RegValue ".NET Framework 4.x Version (NDP\v4\Full)" "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Version"
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    TryFact ".NET Core runtimes (dotnet --list-runtimes)" { & dotnet --list-runtimes 2>&1 }
    TryFact ".NET SDKs (dotnet --list-sdks)" { & dotnet --list-sdks 2>&1 }
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
Fact "note: agent DLL FileVersions are pinned at 1.0.0.0 across product releases; DisplayVersion above and file mtime/sha256 below identify the installed build"
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
        Get-ChildItem -LiteralPath $h -ErrorAction Stop | ForEach-Object {
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
                Get-ChildItem -LiteralPath $d -File -ErrorAction Stop | ForEach-Object {
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
    TryFact "whatap_isapi_filter.dll under home" {
        $hits = @(Get-ChildItem -LiteralPath $h -Recurse -Filter "whatap_isapi_filter.dll" -ErrorAction SilentlyContinue | Select-Object -First 3)
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
TryFact "machine Path segments containing 'whatap'" {
    $segs = @(($env:Path -split ';') | Where-Object { $_ -imatch 'whatap' })
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
Emit ""
# every configured profiler/hook path -> does that exact file exist, and what is it
$cfgPaths = @{}
foreach ($line in ($svcEnvLines + $machineEnvPairs + @($liveHits | ForEach-Object { "$($_.Name)=$($_.Value)" }))) {
    if ($line -match '^(COR_PROFILER_PATH(_32|_64)?|CORECLR_PROFILER_PATH(_32|_64)?|DOTNET_STARTUP_HOOKS)=(.+)$') {
        $cfgPaths[$Matches[1] + "=" + $Matches[4]] = $Matches[4]
    }
}
if ($cfgPaths.Count -eq 0) { Fact "configured profiler/startup-hook paths: none found in any scope above" }
foreach ($k in ($cfgPaths.Keys | Sort-Object)) {
    $var = ($k -split '=', 2)[0]
    FileFacts "configured $var target" $cfgPaths[$k]
}
Emit ""
foreach ($pair in @(@($CLSID_CURRENT, "current 2.5.x line"), @($CLSID_LEGACY, "legacy 450/core line"))) {
    $clsid = $pair[0]; $tag = $pair[1]
    RegValue "CLSID $clsid ($tag) InProcServer32 (64-bit view)" "HKLM:\SOFTWARE\Classes\CLSID\$clsid\InProcServer32" "(default)"
    RegValue "CLSID $clsid ($tag) InProcServer32 (WOW6432Node view)" "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid\InProcServer32" "(default)"
}
Emit ""
Fact "-- Fusion assembly-binding log settings (HKLM\SOFTWARE\Microsoft\Fusion; read-only report) --"
foreach ($n in @("EnableLog", "ForceLog", "LogFailures", "LogResourceBinds", "LogPath")) {
    RegValue "Fusion $n" "HKLM:\SOFTWARE\Microsoft\Fusion" $n
}
$ahc = "$WinDir\System32\inetsrv\config\applicationHost.config"
TryFact "applicationHost.config lines matching COR/CORECLR/WHATAP/STARTUP_HOOKS (with line numbers)" {
    if (-not (Test-Path -LiteralPath $ahc)) { "n/a (path not found: $ahc)" }
    else {
        $m = @(Select-String -LiteralPath $ahc -Pattern 'CORECLR|COR_|WHATAP|STARTUP_HOOKS' -ErrorAction Stop | Select-Object -First 40)
        if ($m.Count -eq 0) { "no matching lines" } else { $m | ForEach-Object { "{0}: {1}" -f $_.LineNumber, $_.Line.Trim() } }
    }
}

Section "D. WhaTap service & runtime processes"
TryFact "services matching 'whatap'" {
    $s = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -imatch 'whatap' -or $_.DisplayName -imatch 'whatap' })
    if ($s.Count -eq 0) { "none" }
    else { $s | ForEach-Object { "{0}  state={1}  startmode={2}  account={3}  pid={4}  path={5}" -f $_.Name, $_.State, $_.StartMode, $_.StartName, $_.ProcessId, $_.PathName } }
}
Fact "whatap-named processes: $($procWhatap.Count)"
foreach ($p in $procWhatap) {
    $cl = "$($p.CommandLine)"; if ($cl.Length -gt 240) { $cl = $cl.Substring(0, 240) + " ..." }
    Fact "process: pid=$($p.ProcessId) name=$($p.Name) start=$($p.CreationDate) cmd=$cl"
}
Emit ""
Fact "w3wp.exe worker processes: $($procW3wp.Count)"
foreach ($p in $procW3wp) {
    $pool = "n/a"
    if ($p.CommandLine -match '-ap\s+"([^"]+)"') { $pool = $Matches[1] }
    $bitMark = if ("$($p.ExecutablePath)" -imatch 'SysWOW64') { "32-bit (SysWOW64 path)" } else { "64-bit path" }
    Fact "w3wp: pid=$($p.ProcessId) apppool=$pool start=$($p.CreationDate) ws_kb=$([int]($p.WorkingSetSize/1KB)) exe=$($p.ExecutablePath) [$bitMark]"
    try {
        $mods = @((Get-Process -Id $p.ProcessId -ErrorAction Stop).Modules | Where-Object { $_.FileName -imatch 'whatap|clrprofiler|datadog|dynatrace|newrelic|appdynamics|instana|elastic.apm|contrast|scouter|jennifer' })
        if ($mods.Count -eq 0) { Fact "  loaded profiler-related modules: none" }
        else { foreach ($m in $mods) { Fact "  loaded module: $($m.FileName)  FileVersion=$($m.FileVersionInfo.FileVersion)" } }
    } catch { Fact "  loaded profiler-related modules: n/a ($($_.Exception.Message.Split("`n")[0]))" }
}
Emit ""
Fact "dotnet.exe processes: $($procDotnet.Count)"
$dnShown = 0
foreach ($p in $procDotnet) {
    if ($dnShown -ge 10) { Fact "(further dotnet.exe processes omitted: $($procDotnet.Count - 10) more)"; break }
    $cl = "$($p.CommandLine)"; if ($cl.Length -gt 240) { $cl = $cl.Substring(0, 240) + " ..." }
    Fact "dotnet: pid=$($p.ProcessId) start=$($p.CreationDate) cmd=$cl"
    try {
        $mods = @((Get-Process -Id $p.ProcessId -ErrorAction Stop).Modules | Where-Object { $_.FileName -imatch 'whatap|clrprofiler' })
        if ($mods.Count -gt 0) { foreach ($m in $mods) { Fact "  loaded module: $($m.FileName)  FileVersion=$($m.FileVersionInfo.FileVersion)" } }
    } catch { }
    $dnShown++
}
if ($null -eq $allProc) { Fact "process inventory: n/a (Win32_Process query did not run)" }

Section "E. IIS topology"
if (Test-Path -LiteralPath $appcmd) {
    TryFact "app pools (appcmd list apppools)" { & $appcmd list apppools 2>&1 }
    TryFact "sites (appcmd list sites)" { & $appcmd list sites 2>&1 }
    TryFact "apps (appcmd list apps)" { & $appcmd list apps 2>&1 }
    TryFact "vdirs with physical paths (appcmd list vdirs)" { & $appcmd list vdirs 2>&1 }
    TryFact "ISAPI filters (appcmd list config -section:isapiFilters)" { & $appcmd list config -section:isapiFilters 2>&1 | Select-Object -First 60 }
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
        if (-not (Test-Path -LiteralPath $ahc)) { "n/a (path not found: $ahc)" }
        else {
            $txt = Get-Content -LiteralPath $ahc -ErrorAction Stop -Raw
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
Fact "conf search order (from agent source): WHATAP_DOTNET_HOME, then grandparent of COR_PROFILER_PATH, then default install dirs"
$confSeen = @{}
foreach ($h in $existingHomes) {
    $cf = Join-Path $h "whatap.conf"
    if ($confSeen.ContainsKey($cf.ToLower())) { continue }
    $confSeen[$cf.ToLower()] = $true
    Emit ""; Emit "    -- conf candidate: $cf --"
    if (Test-Path -LiteralPath $cf) {
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
            $m = @(Get-Content -LiteralPath $core[0].FullName -TotalCount 500 -ErrorAction Stop | Select-String -Pattern 'CLR Profiler' | Select-Object -First 5)
            if ($m.Count -eq 0) { "no matching lines in first 500" } else { $m | ForEach-Object { $_.Line.Trim() } }
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
            $m = @(Get-Content -LiteralPath $t0.FullName -TotalCount 400 -ErrorAction Stop | Select-String -Pattern 'whatap\.version|framework\.version|runtime\.version|whatap\.home|WA002' | Select-Object -First 12)
            if ($m.Count -eq 0) { "no matching lines in first 400" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        HeadFile "newest tracer log $($t0.Name)" $t0.FullName 40
        TailFile "newest tracer log $($t0.Name)" $t0.FullName 120
        TryFact "exception-line count in last 500 lines of $($t0.Name)" {
            @(Get-Content -LiteralPath $t0.FullName -Tail 500 -ErrorAction Stop | Select-String -Pattern 'Exception|ERROR').Count
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
    $af = @(Get-ChildItem -LiteralPath $PROGDATA_AUDIT -File -Recurse -ErrorAction SilentlyContinue)
    $asz = 0; foreach ($f in $af) { $asz += $f.Length }
    $anew = "n/a"; if ($af.Count -gt 0) { $anew = ($af | Sort-Object LastWriteTime -Descending)[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
    Fact "audit dir ${PROGDATA_AUDIT}: $($af.Count) file(s), total $asz bytes, newest mtime $anew, owner=$(OwnerOf $PROGDATA_AUDIT)"
    Fact "audit dir content: not dumped (db-audit files hold customer SQL data; presence and size only)"
} else {
    Fact "audit dir ${PROGDATA_AUDIT}: n/a (path not found)"
}
if ($env:WT_TRACE_LOG_PATH) { Fact "WT_TRACE_LOG_PATH override is set: $env:WT_TRACE_LOG_PATH (tracer writes there instead of ProgramData)" }

Section "H. Network endpoints"
# tracer -> UDP 127.0.0.1:6600 -> whatap_dotnet.exe -> TCP 6600 -> collection server
if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    TryFact "tcp connections with port 6600 (either side)" {
        $c = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.RemotePort -eq 6600 -or $_.LocalPort -eq 6600 })
        if ($c.Count -eq 0) { "none" }
        else { $c | ForEach-Object { "{0}:{1} -> {2}:{3}  state={4}  owningpid={5}" -f $_.LocalAddress, $_.LocalPort, $_.RemoteAddress, $_.RemotePort, $_.State, $_.OwningProcess } }
    }
    TryFact "udp endpoints on port 6600" {
        $u = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.LocalPort -eq 6600 })
        if ($u.Count -eq 0) { "none" }
        else { $u | ForEach-Object { "{0}:{1}  owningpid={2}" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess } }
    }
} else {
    TryFact "netstat -ano lines with :6600" {
        $m = @(& netstat -ano 2>&1 | Select-String -Pattern ':6600' | Select-Object -First 40)
        if ($m.Count -eq 0) { "none" } else { $m | ForEach-Object { $_.Line.Trim() } }
    }
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

Section "I. Windows event logs (bounded, last 7 days)"
TryFact "Application log: .NET/ASP.NET/crash/WhaTap events (newest 15 of last 300 err+warn)" {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match '\.NET Runtime|ASP\.NET|Application Error|Windows Error Reporting|[Ww]ha[Tt]ap' } |
        Select-Object -First 15)
    if ($ev.Count -eq 0) { "none matching in window" }
    else {
        $ev | ForEach-Object {
            $msg = "$($_.Message)" -split "`r?`n" | Select-Object -First 3
            "{0}  {1}  id={2}  {3}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $_.ProviderName, $_.Id, ($msg -join ' | ')
        }
    }
}
TryFact "System log: WAS/W3SVC/HTTP events (newest 10 of last 300 err+warn)" {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match 'WAS|W3SVC|IIS|HTTP' } |
        Select-Object -First 10)
    if ($ev.Count -eq 0) { "none matching in window" }
    else {
        $ev | ForEach-Object {
            $msg = "$($_.Message)" -split "`r?`n" | Select-Object -First 2
            "{0}  {1}  id={2}  {3}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $_.ProviderName, $_.Id, ($msg -join ' | ')
        }
    }
}

Section "J. Application facts (per IIS application)"
# physical paths come from appcmd list vdirs; env vars inside paths expanded
$appPaths = @()
if (Test-Path -LiteralPath $appcmd) {
    try {
        foreach ($line in @(& $appcmd list vdirs 2>&1)) {
            if ("$line" -match 'VDIR\s+"([^"]+)"\s+\(physicalPath:([^)]*)\)') {
                $appPaths += ,@($Matches[1], [Environment]::ExpandEnvironmentVariables($Matches[2]))
            }
        }
    } catch { }
}
if ($appPaths.Count -eq 0) {
    Fact "IIS application physical paths: n/a (appcmd returned no vdir lines; IIS config read requires elevation)"
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
            $m = @(Select-String -LiteralPath $wc -Pattern 'targetFramework' -ErrorAction Stop | Select-Object -First 5)
            if ($m.Count -eq 0) { "no targetFramework attribute" } else { $m | ForEach-Object { $_.Line.Trim() } }
        }
        TryFact "web.config <runtime> block (assemblyBinding, verbatim)" {
            $txt = Get-Content -LiteralPath $wc -ErrorAction Stop -Raw
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
    } else { Fact "bin\: not present (not a .NET Framework bin-deployed app, or path differs)" }
    TryFact ".NET Core markers (*.runtimeconfig.json / *.deps.json / appsettings.json)" {
        $m = @(Get-ChildItem -LiteralPath $phys -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.runtimeconfig\.json$|\.deps\.json$|^appsettings\.json$|^web\.config$' })
        if ($m.Count -eq 0) { "none at top level" } else { $m | ForEach-Object { $_.Name } }
    }
    foreach ($rc in @(Get-ChildItem -LiteralPath $phys -Filter "*.runtimeconfig.json" -File -ErrorAction SilentlyContinue | Select-Object -First 2)) {
        DumpFile "runtimeconfig $($rc.Name)" $rc.FullName 30
    }
    $appShown++
}

Emit ""
if ($existingHomes.Count -gt 0 -or $uninstallEntries.Count -gt 0) { Set-Got agent }
else { Set-Missed agent "no agent home and no whatap uninstall registry entry found" }
$confSeen = $false
foreach ($h in $existingHomes) {
    if (Test-Path -LiteralPath (Join-Path $h "whatap.conf")) { $confSeen = $true }
}
if ($confSeen) { Set-Got conf } else { Set-Missed conf "no readable whatap.conf under any discovered agent home" }
Emit-Status
Emit "==== END OF COLLECTION (no diagnosis by design) ===="

# ---- output --------------------------------------------------------------------
if ($Stdout) {
    $script:Lines | ForEach-Object { Write-Output $_ }
} else {
    $out = ".\$COLLECTOR_NAME-$CompName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).txt"
    $script:Lines | Set-Content -Path $out -Encoding UTF8
    Progress "report written: $out"
}
