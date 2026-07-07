<!-- Example docs-sentinel policy. Copy to .github/docs-sentinel/policy.md and edit.
     This file is appended to the generic auditor prompt — it supplies everything
     repo-specific: the rule, the in-scope docs, and what to cross-check. -->

## The rule you are enforcing

> Documentation must stay current with every change: whenever a change alters a command,
> port, env var, schema, API route, or convention that `README.md` or anything under
> `docs/` describes, the affected doc must be updated in the same change.

## Documentation in scope (the ONLY files you may edit)

- **`README.md`** (root) — quickstart commands, ports, env vars, project layout.
- **`docs/**`** — architecture and how-to guides.

## Out of scope — never touch

- **`CHANGELOG.md`** (generated).
- Anything else: source, config, tests, lockfiles.

## Triggers worth checking specifically

Cross-reference the diff against the docs when it touches any of: CLI commands or scripts in
`package.json`; dev/server **ports**; **env vars**; DB **schema**; API route prefixes; the
project layout (new/removed/renamed packages or directories).

## How to verify facts

Read the source directly — e.g. `package.json` scripts for commands, the server entrypoint for
ports — with Read/Grep/Glob. Never run build, install, or dev commands.
