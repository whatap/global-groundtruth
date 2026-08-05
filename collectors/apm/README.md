# collectors/apm — language sub-family collectors

> **Status: PARTIALLY SEEDED.** `python/` holds a working v0
> ([python/collect-apmpython.sh](python/collect-apmpython.sh), see
> [python/README.md](python/README.md)). The other language runtimes are not
> implemented yet. Each collector will be owned by its agent's developers
> (CONTRACT rule 4); until handover they are managed by the Global team.

## Note: this domain has language sub-families

APM is not one collector but a **family, one per language runtime**:
`nodejs`, `java`, `python`, `php`, `dotnet`. Each has its own attach mechanism
and its own hidden facts, so each gets its own collector script under this
directory (e.g. `apm/java/…`, `apm/nodejs/…`).

## (a) Hidden facts to collect

Per language runtime, the facts a remote WhaTap agent developer repeatedly asks
a field engineer for:

- **Runtime version** — JVM / Node / Python / PHP / .NET version and vendor.
- **How the agent is attached** — e.g. `-javaagent` on the JVM command line;
  Node `--require` / preload; Python `sitecustomize` / import hook; PHP
  extension (`.ini`); .NET profiler environment variables.
- **Agent version** actually loaded.
- **Agent config** — `whatap.conf` location and contents; relevant `WHATAP_*`
  environment variables.
- **App server / framework** hosting the process.

Discovered from the live process and its environment (CONTRACT rule 2); absent
values reported as `n/a`.

## (b) Delivery mechanism

A **per-language script** run **in-host or in-container** next to the target
process — one command, paste the output (CONTRACT rule 3). In containers, it is
run via `kubectl exec` / `docker exec` into the app container.

## (c) How to implement

Copy [../../templates/collector-skeleton/](../../templates/collector-skeleton/)
once per language, follow
[../../docs/authoring-guide.md](../../docs/authoring-guide.md), keep to facts
only, and validate each with `tools/validate.sh`.
