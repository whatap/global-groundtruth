# collectors/collection-server

The **collection server** is the WhaTap backend that receives agent data and
stores/aggregates it: `yard` (core store/aggregate), `proxy` (agent TCP
ingress), plus `gateway` / `keeper` / `account` / `notihub` / `eureka` /
`front` and others, usually co-located on one host. Three collectors live here,
owned for now by the Global team (framework owner). Handover transfers ongoing
ownership to the collection-server (backend) team (CONTRACT rule 4).

| Entrypoint | Token | What it answers | Documentation |
| ---------- | ----- | --------------- | ------------- |
| [`collect-collserver.sh`](collect-collserver.sh) | `collserver` | the WhaTap backend itself: services, ports, configs, logs | [collect-collserver.md](collect-collserver.md) |
| [`collect-collzfs.sh`](collect-collzfs.sh) | `collzfs` | ZFS under the backend's data path: block sizing, allocation classes, the write path, free-space fragmentation | [collect-collzfs.md](collect-collzfs.md) |
| [`collect-collmysql.sh`](collect-collmysql.sh) | `collmysql` | the MySQL that holds the backend's `account` / `notihub` metadata: replication and HA state, binary log growth and content, InnoDB I/O counters | [collect-collmysql.md](collect-collmysql.md) |

Each document opens with that collector's status line. Its "validated at"
version is the last one run on a real environment, not the script's current
`VERSION`; a gap between the two means later changes have not met a real host
yet. The version history is in [CHANGELOG.md](CHANGELOG.md).

## Which one to run

`collect-collserver.sh` for anything about the backend (services, ports,
configs, logs). `collect-collzfs.sh` when the question is about the ZFS
filesystem under it. `collect-collmysql.sh` when the question is about the
backend's own MySQL. They are each self-contained; running any combination is
fine and normal. Which filesystem and dataset `yardbase` is on is in
collserver's section C; collzfs reports ZFS only and does not look for WhaTap,
so the two join on the dataset name.

## Shared code

The helpers two or three of them share word for word (the removed-option check,
file dumping, the systemd helpers, the sampling-window duration parser,
`_need_int` (collmysql and collserver only), and the `_give_back`
chown-to-operator-under-sudo helper) are the group blocks
`collection-server: <name>`, owned by
[templates/groups/collection-server.sh](../../templates/groups/collection-server.sh):
edit them there and run `tools/sync-shared-block.sh --apply`. The path helpers
and process scan are collserver's own code; the probe helpers (`probe`,
`probe_merged`) are in the skeleton's run helpers block.

## How to maintain

Each collector was copied from
[../../templates/collector-skeleton/](../../templates/collector-skeleton/) and
follows [../../docs/authoring-guide.md](../../docs/authoring-guide.md) and
[../../docs/collector-engineering.md](../../docs/collector-engineering.md)
(MECE domains, load tiers, portability, reasoned absence). Keep to facts only
and re-validate after edits:

```sh
../../tools/validate.sh collect-collserver.sh   # or collect-collzfs.sh, collect-collmysql.sh
```

Two habits apply to any of them: ask the binary what it supports instead of
inferring from a version (a build that lacks a property omits it, and the
omission is reported as a fact), and parse tool output by column name, not
position (the columns of `zpool list -v` differ between ZFS versions, such as
`CKPOINT`, `EXPANDSZ` and `DEDUP`).
