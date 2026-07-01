# collectors/server — STUB

> **Status: NOT IMPLEMENTED.** This directory describes what a host/server
> collector will gather and how it will be delivered. No collection code exists
> here yet. It is owned by the server domain team (CONTRACT rule 4).

## (a) Hidden facts to collect

Host environment facts a remote WhaTap agent developer repeatedly asks for:

- **OS / distro / kernel / architecture** (`/etc/os-release`, `uname`).
- **Resources** — CPU count, memory, and any cgroup limits the process runs under.
- **Disk & mounts** — filesystems, free space, mount options for paths the agent
  writes to.
- **Network** — interfaces, DNS resolvers, and outbound proxy settings (relevant
  to whether the agent can reach the collector servers).
- **Time sync** — clock source / NTP state (affects timestamp correctness).
- **WhaTap server agent** — presence, version, and config (`whatap.conf`)
  location and contents; whether the agent process is running.

Discovered, not assumed (CONTRACT rule 2); absent values reported as `n/a`.

## (b) Delivery mechanism

A **host shell script** the field engineer runs directly on the machine — one
command, paste the output (CONTRACT rule 3).

## (c) How to implement

Copy [../../templates/collector-skeleton/](../../templates/collector-skeleton/),
follow [../../docs/authoring-guide.md](../../docs/authoring-guide.md), keep to
facts only, and validate with `tools/validate.sh`.
