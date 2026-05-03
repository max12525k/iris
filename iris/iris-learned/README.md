# iris-learned/

Iris's **learning manifest** — the canonical record of every tool, library, or
system package she has acquired since the repo was created.

Each entry lands here in two ways:

1. **Runtime install.** The package was installed in the live container when
   Iris ran `iris-learn <ecosystem> <package> [reason]`.
2. **Manifest commit.** The same call appended to the manifest and committed
   on an `iris-self/learn-<package>` branch for human review.

When the image is rebuilt, the Dockerfile reads these files and bakes every
listed package into the image, so a fresh clone on a new machine gets the same
Iris — same tools, same skills, same routines.

## Files

| File | Format | Consumed by |
|---|---|---|
| `apt.txt` | One package per line, comments with `#` | `apt-get install -y $(grep -v '^#' apt.txt)` |
| `python.txt` | pip requirements format (pins, comments OK) | `pip install -r python.txt` into Hermes's venv |
| `npm.txt` | One package per line, comments with `#` | `npm install -g` (one at a time) |
| `rationale.md` | Markdown journal — what / when / why | Human review surface |

## How learning persists

Three storage layers, one source of truth:

```
[Source of truth] iris/iris-learned/*  (committed in repo)
        ↓
[Build-time bake]  Dockerfile reads manifests at `make rebuild`
        ↓
[Runtime cache]   apt's /var/lib/dpkg + Hermes's venv
```

If any cache is lost, it's reconciled from the source of truth automatically:

- `restart` → trivial, filesystem unchanged.
- `--force-recreate` → entrypoint replays manifest (idempotent).
- `make rebuild` → Dockerfile bakes manifest into the image layer.
- Fresh clone on a new machine → same Dockerfile, same manifest, same Iris.

## Editing by hand

Both Iris and a human can edit these files. Iris's `iris-learn` wrapper does
it atomically (install + manifest update + commit on a single branch). Humans
appending directly is fine too — the next `make rebuild` picks up the changes.
Lines starting with `#` are comments and ignored by all consumers.
