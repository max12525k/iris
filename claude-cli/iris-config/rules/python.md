# Python rules

**Always use `uv` for Python.** Never `pip`, `pipx`, `pip3`, `python -m pip`, or `python -m venv`.

## Command equivalents

| Old habit                       | Use instead                       |
|---------------------------------|-----------------------------------|
| `pipx install <pkg>`            | `uv tool install <pkg>`           |
| `pipx run <pkg>`                | `uvx <pkg>` (or `uv tool run`)    |
| `pip install <pkg>` (in project)| `uv add <pkg>`                    |
| `pip install -r requirements.txt`| `uv sync`                        |
| `python -m venv .venv`          | `uv venv` (auto-managed by `uv run`) |
| `python script.py`              | `uv run script.py`                |
| `python -m pip install --upgrade <pkg>` | `uv tool upgrade <pkg>`   |

**`uv run` vs `uvx`:** use `uv run` for scripts that depend on the project's `pyproject.toml`; use `uvx` for ephemeral one-shot CLIs not installed in the project.

## Defaults

- Pin Python version per project: `uv python pin 3.13` (or whatever the project needs).
- Prefer `pyproject.toml` over `requirements.txt` for new projects. `uv add <pkg>` writes to it.
- Lockfile is `uv.lock` — commit it.
- Prefer `uv run` over `source .venv/bin/activate` — activates per-command and stays current with the lockfile.
- If a tool is "global" (used across projects), install it via `uv tool install`, not as a project dep.

## Tooling defaults

- **Lint + format:** [`ruff`](https://docs.astral.sh/ruff/) via `uv run ruff check` and `uv run ruff format`. Replaces black, isort, flake8.
- **Type check:** `pyright` — the `pyright-lsp@claude-plugins-official` plugin is already enabled in this harness; lean on that instead of installing mypy separately.
- **Test runner:** `pytest` via `uv run pytest`.

## When you catch yourself typing `pip`

Stop. Rewrite the command in `uv` form before running.

---
**Sources:** [Astral — uv docs](https://docs.astral.sh/uv/), [Astral — ruff docs](https://docs.astral.sh/ruff/), [Microsoft — pyright](https://github.com/microsoft/pyright).
