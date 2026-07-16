# Tool dependency policy

When a tool reports a missing package — mypy `Library stubs not installed`,
pytest `ModuleNotFoundError`, eslint `Cannot find module`, ruff plugin not
found, etc. — **never** run `pip install`, `uv pip install`, `npm install`,
`pnpm add`, or `brew install` on the fly.

## Why

The macOS sandbox blocks outbound to `files.pythonhosted.org`,
`registry.npmjs.org`, and most package CDNs. Fly-installs:

- Always fail with `tunnel error` after 30–90s of retries.
- Burn turn budget on retries the agent silently classifies as "transient".
- Mask the real issue: a missing dependency declaration.

## How to apply

When you encounter the error:

1. **Check whether the package IS already in the project venv:**
   ```bash
   ls .venv/lib/python*/site-packages/ | grep <package>
   # or for node:
   ls node_modules/.bin/ | grep <tool>
   ```

2. **If present:** the real problem is configuration — wrong python version,
   stale `PATH`, multiple venvs in play. Investigate that. The package is
   not the issue.

3. **If absent:** the project's `pyproject.toml` or `package.json` is missing
   the dependency. **Do not install it.** Instead:
   - Add it to the manifest (`[project.optional-dependencies] dev = [...]`
     for Python; `devDependencies` for Node).
   - Surface it in the phase report as `dependency missing — added to
     pyproject.toml; run \`uv sync --extra dev\` to provision`.
   - Continue the phase if possible (skip the gated check); fail loudly
     if not.

4. **Never retry** an install that returned a tunnel error. One attempt
   teaches you the network is blocked; further attempts only burn turns.

## Exception

`worktree.sh new` and `autopilot.sh` preflight may invoke `uv sync --extra
dev` and `pnpm install --frozen-lockfile` because they run before any
sandbox-restricted phase and the user has explicitly delegated provisioning
to them. Phase-level commands (/implement, /qa, /static-analysis) inherit
the provisioned venv and **must not** re-attempt provisioning.
