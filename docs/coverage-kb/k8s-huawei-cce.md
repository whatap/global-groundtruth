# Coverage KB — Huawei Cloud CCE (Kubernetes)

**What this is:** a coverage knowledge-base entry. It records environment-specific
**facts** that a real cluster in this environment exhibits, so a collector author
knows what a "discover, never assume" (CONTRACT rule 2) collector will surface
here — and so that no one is tempted to hardcode a single environment's paths.

It is a reference, not a branch in any script. A collector should **resolve**
these values at runtime, not special-case "CCE". Like every artifact in this
repo, the entries below are facts only — no diagnosis.

Environment: **Huawei Cloud CCE** (Cloud Container Engine).

---

## Container log path

- On a standard cluster, `/var/log/containers/<pod>_<ns>_<container>-<id>.log`
  is a symlink that resolves (via `/var/log/pods/...`) into the runtime's log
  directory.
- On CCE, the same `/var/log/containers/*.log` entries have been observed to
  resolve into **`/mnt/paas/runtime/container_logs/`** instead.

Consequence for a collector: report the **resolved** target of
`/var/log/containers/*.log` (`readlink -f`). The standard path and the CCE path
then both appear correctly from the same code, with no environment check.

## kubelet root-dir

- The kubelet default root directory is `/var/lib/kubelet`.
- CCE has been observed to run the kubelet with a **custom `--root-dir`** (not
  the default).

Consequence for a collector: discover the value from the kubelet process
arguments (e.g. parse `--root-dir` from the kubelet command line / `/proc`),
rather than assuming `/var/lib/kubelet`. If it cannot be found, report `n/a`.

## cgroup version

- CCE nodes have been observed running **cgroup v2** (unified hierarchy).
- A fact-level check: `stat -fc %T /sys/fs/cgroup` returns `cgroup2fs` on cgroup
  v2 and `tmpfs` on cgroup v1.

Consequence for a collector: report the detected cgroup version as a fact; do
not assume v1 or v2.

---

## Adding another environment

Copy the structure above into a new `docs/coverage-kb/<platform>.md`: name the
environment, then list each fact as *observed value* + *how a collector should
discover it at runtime*. Keep it to observations — no cause, no recommendation.
