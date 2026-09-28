# collect-k8s.sh — changelog

The version history of [`collect-k8s.sh`](collect-k8s.sh), newest first. Every
change to the script bumps its `VERSION` and adds one entry at the top of this
list (docs/authoring-guide.md, step 2); `tools/validate.sh` checks that the
newest entry is the script's `VERSION`.

- **0.13.2** — Drop curl from the [1] tool row (only run inside the pod);
  split discover_workloads, _rep_inpod's exec plan, _rep_operator_chain's
  webhook/service loop, and _rep_logs into smaller named helpers, with no
  report change.
- **0.13.1** — Collection status (skeleton `_emit_time`): when a bounded call was slow, capped or not run, the per-command "where the time went" table (sums largest first, time outside bounded calls) gives way to the time log's own records, one line per such call in the order they ran (`<ms> ms  <outcome>  <command>`, the first 40, then `(N more in this run)`); CONTRACT rule 1. `_run_init` sets its EXIT/INT/TERM/HUP traps before it creates the private directory: a signal in between left `ggt.*` behind.
- **0.13.0** — Removed `--kubeconfig PATH` / `--kubeconfig=PATH`: `KUBECONFIG=<path>
  collect-k8s.sh ...` does the same, for kubectl/oc/helm alike, so a separate
  flag only duplicated it. The flag is stub-exit (exit 2, one stderr line)
  rather than ignored, because silently dropping it would collect a different
  cluster than the one the caller named. `--context` is unchanged. `usage()`
  and the Environment block now name `KUBECONFIG=PATH` instead of the flag;
  the `KOPTS`/`HOPTS` builders (kubectl, and helm in both the Tier 0 helm
  section and the bundle collector) no longer append `--kubeconfig=...`
  themselves — kubectl/oc/helm each read `$KUBECONFIG` (or `~/.kube/config`)
  on their own, so the report's `KUBECONFIG env` and `cli global options`
  lines still show what is in effect.
- **0.12.2** — `_run_init` (skeleton) also takes the script as read from stdin when `$0` is the shell's own binary (`/bin/bash -s`, `$0 -ef /proc/$$/exe`): bash 3.2 under musl otherwise faulted in a loop at full CPU after `4<&0`.
- **0.12.1** — Section D ("rbac & identity") prints the WhaTap credential
  Secrets decoded: `whatap-credentials` in the whatap namespace and the
  Secrets the WhatapAgent CR spec names (a field ending in `secretName`, or
  the `name` of a field ending in `secretRef`); pod env/envFrom references
  are not followed. Only keys `WHATAP_*` (any case) are decoded, one
  `secret <name> <key>=<value>` line each: UTF-8 text as is with newline
  and CR escaped as `\n` / `\r`, else `<N bytes, not text>`; other keys are
  listed by name, and a key ending in `.key` or `.pem` is never decoded. A
  refused or failed read is `n/a (<reason>)`, an absent Secret `none`. User
  decision 2026-09-27: WhaTap credentials are collected verbatim; the Finnet
  and MEA cases took round trips to learn which host and port the agents
  were given. Other Secrets stay name/type only. The section J line that follows each app log head is renamed
  `WhaTap version lines` (the pattern also matches operator lines such as
  `whatap-injection--v1-`). Lab: `whatap-credentials` WHATAP_HOST, LICENSE,
  PORT printed; report 1634 → 1638 lines, run 20 s.
- **0.12.0** — Collects what confirms a root cause, and drops views that
  restated raw output already in the report (user decision 2026-09-27; no
  option added or removed; no fact lost). Removed, and where the same fact is
  now read: section C's six per-CR jsonpath extracts after the CR yaml (env
  names, identity + master switches, targets, init image overrides) → the
  `cr yaml` (managedFields write history stays: kubectl's yaml leaves it out);
  section J's CR names, `named 'whatap'` check, targets and selectors → one
  list in section C, `every whatapagent: name / targets / selectors`, over
  every listed CR (the yaml stays capped at 3, and the CR named `whatap` is
  always among them, first); section J's per-namespace, per-language and
  init-image tallies → the instrumented-pod list, now uncapped (was first
  100); section D's per-hook summary line and caBundle size → the webhook
  yaml, the ready-address count → the endpoints table (3-way CA fingerprint
  comparison, call counters and shared hook-name check unchanged). Section E
  describes only pods with restarts or a container not ready (first two),
  else one line says none qualified; its pod table gains not-ready count and
  node; `--bundle` still writes the describe of the top-2 restart pods.
  `--bundle` no longer writes the CR, operator, webhook and DaemonSet yaml,
  the sa/secret tables and the image list (all in the report); it keeps the
  CRD schema, `get rs -o wide` of the namespace, the pod table, describe,
  logs, events, nodes, helm and the `--apm-target` originals.
  Added, load-free and read-only, after the MEA case (2026-08, x509 on the
  webhook call under `failurePolicy: Ignore`), whose cause was the
  kube-apiserver's `https_proxy` with a `no_proxy` lacking `.svc` and the
  cluster CIDRs, found only from a field screenshot, and whose serving chain
  was measured by hand (`session-probe.sh`): section D **kube-apiserver proxy
  environment** — per kube-apiserver pod in kube-system and container, env
  entries named `http_proxy`/`https_proxy`/`no_proxy` in any case (verbatim),
  envFrom sources, env count, or n/a naming why (no such pod: managed control
  planes do not expose it; a refused list: its reason); section I reads the
  proxy lines of the node's `/etc/kubernetes/manifests/kube-apiserver.yaml`
  when an exec sample runs on a kube-apiserver node (the without-restarts
  sample prefers such a node; no exec added). Section D **webhook serving
  certificate chain as presented** — `openssl s_client -showcerts` from the
  collector host to the first 2 ready endpoint addresses and the Service
  ClusterIP, SNI `<svc>.<ns>.svc`, `-CAfile` = the hook's caBundle,
  `-verify_hostname` where s_client has it (LibreSSL has not: the line says
  so); per certificate subject, issuer, notAfter, sha256 fingerprint and SANs
  (from `x509 -text`, as openssl 1.0.2 and LibreSSL have no `-ext`) and
  `Verify return code`; min(CMD_TIMEOUT, 3) s per address, the rest not tried
  after one timeout. Version facts (the supported-range check): the WhaTap
  banner line of each app-container log head in section J (any case,
  `whatap.*(v|ver|version)[ .]?<digit>`: `WhaTap Node Agent version 2.0.6`,
  `WhaTap Kube Agent ver 1.9.10`); `imageID` in the
  pod container status table and a `image imageID` list of the whatap
  namespace pods (section H); the init containers' `command` and `args` in the
  pod init-container table (the operator's init only copies whatap.conf,
  which engineers checked by opening pods, #ask-dev-apm); with `--apm-exec`,
  `readlink /proc/1/exe` with the runtime's `release` file (else the version
  flag of java, node or python only; any other binary is not executed: a Go
  app that ignores the flag started a second instance in the verifier's
  repro), the agent `package.json` version and the first 5 lines of each agent
  log. The kube-apiserver pod list is read once before the report.
  Lab (kubeadm 1.32, 4 nodes, same host): report 1866 → 1634 lines, run
  18 → 20 s (one 3 s s_client timeout: the pod network is not routed from the
  analysis host); from the control-plane node both addresses presented
  `CN=whatap-admission-controller.whatap-monitoring.svc` issued by
  `CN=whatap-webhook-ca`, verify 0; the lab kube-apiserver has no env
  entries. The chain code was also run under openssl 1.0.2g and LibreSSL with
  bash 3.2.
- **0.11.5** — Shortened long comment runs: the top-of-file block now points at
  README.md for section/tier detail instead of restating it; the merged-calls
  and deep-operator-log-tail algorithm rationale moved to a new README.md
  "Design notes" section, with a short pointer left in the code; the webhook
  cert mismatch root cause and the pod-probe fallback rules were tightened in
  place. Comments only; report content unchanged.
- **0.11.4** — The batched-call store keeps each group's segments contiguous
  (start KM_GS, count KM_GC per group; KM_SK holds KEY only), so a lookup reads
  only that group's segments and a re-run unsets only its own range instead of
  copying every segment; _km_drop is folded into _km_reset and the pod-probe
  segments are the reserved group "" (_PX_GI). 500 pods × 10 keys: 50 small
  km_get 19.7 s → 0.3 s, _pod_probes_run + _px ×20 9.0 s → 0.03 s (0.11.2:
  0.3 s, 0.02 s). Report content unchanged.
- **0.11.3** — Split _rep_operator and _rep_apm into per-subsection and
  per-level functions; the batched-call store uses flat arrays keyed GROUP/KEY
  instead of 14 evals over generated names; repeated code is _seg_flush,
  _x509_fp and _ns_found. Report content unchanged.
- **0.11.2** — Shared code in synced blocks (R2 refactor): the skeleton's emit
  helpers now hold _optval, _emit_labeled, _tool_rows (the [1] tool table) and
  _indent (the indent loops), and its run helpers hold probe and read_proc.
  Report change: probe (helm version, helm history, helm values) prints the
  output of a command that exits non-zero under "label (exit N):" instead of
  "label: n/a (...)". No goal reads that text. Compared with 0.11.1 on this
  host: reports equal but live values (operator log lines).
- **0.11.1** — [1]'s privilege line says when uid 0 has no CAP_SYS_PTRACE (bit 19
  of CapEff; the default in docker and k8s): "root without
  CAP_SYS_PTRACE (other uids' /proc/\<pid>/environ, root, cwd are not
  readable: run as the target's uid, ...)". It read "root" while
  another uid's environ, root and cwd were denied. A bounded call
  leaves no process to PID 1: the watchdog is ended by USR1 and reaps
  its sleep (a KILL left it to PID 1), and busybox timeout(1), whose
  timer outlived each call, is not used; the watchdog caps instead.
  Under a PID 1 that does not reap (sleep infinity), one run of each
  collector left 1 zombie on debian and 41-55 on alpine; now 0 (2026-09-27).
- **0.11.0** — The Tier 0 log lines per container come from the environment,
  LOG_TAIL_LINES (default 200, 1..999999; another value is named in a
  !! line and 200 is used). --tail is refused, naming LOG_TAIL_LINES.
  The help shows -n for --namespace. An --out directory that cannot be
  written stops the run before it collects (2026-09-26).
  A value option given nothing, or a value starting with '-', exits 2
  ("missing value for --out"); it took the next option as its value.
- **0.10.0** — Section [1] states the API round trip: the time of the one
  reachability call (get --raw /version) in ms, no extra call
  (2026-09-26).
- **0.9.0** — The whatap namespace, the whatap workloads and the node-agent pods are
  goals: a refused, failed or timed-out list behind them is missed and
  the run INCOMPLETE (it was COMPLETE). The operator log tail is cut from
  the 4000-line read when that read holds it (one call instead of two).
- **0.8.6** — --apm-exec reads the runtime versions without JAVA_TOOL_OPTIONS and the
  other agent variables: the JVM loaded the WhaTap agent, which wrote a
  Start block to the app's whatap.log on every run.
- **0.8.5** — Readability refactor; report unchanged. Fewer API calls, same
  answers: section J reads each workload and each pod in one call
  (14 -> 1 per pod), the operator deployment and operator pod list reads
  of section D are merged, and section A counts namespaces from the list
  section J prints (3 --apm-target, lab cluster: 111 s -> 75 s).
- **0.8.4** — A CMD_TIMEOUT from the environment is used (it was overwritten by a
  fixed value after _run_init had checked it) (2026-09-26).
