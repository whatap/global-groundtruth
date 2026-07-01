# collectors/db — STUB

> **Status: NOT IMPLEMENTED.** This directory describes what a database
> collector will gather and how it will be delivered. No collection code exists
> here yet. It will be owned by the DB domain team (CONTRACT rule 4); until
> handover it is managed by the Global team.

## (a) Hidden facts to collect

Facts a remote WhaTap agent developer repeatedly asks a field engineer for about
a monitored database:

- **Engine & version** — product and exact version/build.
- **Key server parameters** — the configuration values relevant to monitoring
  (as reported by the engine itself).
- **Monitoring account privileges** — what the WhaTap agent's DB user is granted
  vs. what the agent needs to read.
- **Installed monitoring objects** — extensions / views / packages the agent
  relies on, and whether they are present.
- **Agent connection config** — the WhaTap DB agent's target host/port/user and
  which instance it is set to monitor (`whatap.conf` dump).

Discovered by querying the engine and reading the agent config as-is
(CONTRACT rule 2); absent values reported as `n/a`.

## (b) Delivery mechanism

A **SQL script** the field engineer runs through the DB client (its result set
is the report body) **plus an agent-config dump** — together, one paste
(CONTRACT rule 3). Output still conforms to
[../../docs/output-format.md](../../docs/output-format.md).

## (c) How to implement

Model the SQL output on the shared format (header fields, numbered sections,
footer), follow [../../docs/authoring-guide.md](../../docs/authoring-guide.md),
keep to facts only, and validate the wrapper script with `tools/validate.sh`.
