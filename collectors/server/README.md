# collectors/server: STUB

> **Status: NOT IMPLEMENTED.** No collection code exists here yet. The host/server
> collector will be a host shell script the field engineer runs on the machine (one
> command, paste the output; CONTRACT rule 3), owned by the server domain team
> (CONTRACT rule 4) and managed by the Global team until handover. Start from
> [../../templates/collector-skeleton/](../../templates/collector-skeleton/) and
> [../../docs/authoring-guide.md](../../docs/authoring-guide.md).

Intended facts (discovered, not assumed; absent values `n/a`): OS / distro / kernel /
architecture; CPU count, memory and cgroup limits; filesystems, free space and mount
options for paths the agent writes to; interfaces, DNS resolvers and outbound proxy
settings; clock source / NTP state; WhaTap server agent presence, version, `whatap.conf`
location and contents, and whether the process is running.
