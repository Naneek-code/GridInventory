# Patch Notes Convention

## Structure

```
pathnotes/
├── README.md          ← you are here
├── hotfix.txt         ← ALWAYS the latest hotfix notes (overwrite on each hotfix)
├── update.txt         ← ALWAYS the latest major update notes (overwrite on each update)
└── archive/           ← old versions, never delete
    ├── hotfix-2026-08-21.txt
    ├── update-2026-08-14.txt
    └── ...
```

## Naming Convention

- **`hotfix.txt`** — current/latest hotfix patch notes. Overwrite every time a hotfix is released.
- **`update.txt`** — current/latest major/content update notes. Overwrite every time a major update is released.
- **`archive/hotfix-YYYY-MM-DD.txt`** — archived hotfix copy, dated by the commit date.
- **`archive/update-YYYY-MM-DD.txt`** — archived update copy, dated by the commit date.

## When to Use Which

- **hotfix.txt** — bug fixes, crash fixes, small QoL tweaks, performance improvements.
- **update.txt** — new features, new systems, major content additions, breaking changes.

## Workflow

When committing a new hotfix:

1. **Archive** the current `hotfix.txt` → move to `archive/hotfix-YYYY-MM-DD.txt`.
2. **Overwrite** `hotfix.txt` with the new notes.
3. Commit both changes together.

When committing a new major update:

1. **Archive** the current `update.txt` → move to `archive/update-YYYY-MM-DD.txt`.
2. **Overwrite** `update.txt` with the new notes.
3. Commit both changes together.

If the file doesn't exist yet (first time), just create it — no archive needed.

## Format

- Steam Workshop uses **BBCode** (not Markdown).
- Always start with `[h1]Title — Hotfix/Update (Month Day, Year)[/h1]`.
- Use `[h2]` for sections, `[*]` for bullet points, `[b]` for bold.
- Keep it concise: one line per fix/feature, bold the keyword.
- Write in **English** (Steam Workshop is international).

## For Agents

- `hotfix.txt` and `update.txt` are the **single source of truth** for the latest notes.
- When the user says "commita" or "gera o hotfix", update `hotfix.txt`.
- When the user says "update notes" or "major update", update `update.txt`.
- If the user asks for patch notes and doesn't specify, ask if it's a hotfix or an update.
- Never delete archive files.
