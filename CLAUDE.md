# CLAUDE.md — omahours

Omarchy bar plugin "Omahours" (Quickshell/QML). Public repository: nothing private goes in here, no paths, names or data from a personal machine. Everything is in English.

- Plugin files sit in the repository root (`manifest.json`, `Panel.qml`, `Model.js`, `i18n/`), as the Omarchy marketplace requires. No symlinks inside the folder: `omarchy plugin validate` rejects them.
- All interface text goes through `i18n/en.json`.
- Logic belongs in `Model.js` (no QML) and gets a case in `tests/`. Before and after every change: `node tests/model.test.js && node tests/model-extreme.test.js && omarchy plugin validate .`
- The data file must never be overwritten unless it was read completely (`Model.check`). Do not weaken this lock.
- Show any text from files or input with `textFormat: Text.PlainText`.
- No network access, no privilege escalation, no services: the marketplace security check flags even a mention of such commands in the README or code.
- On a running desktop, test only through IPC (`omarchy-shell omahours status`) and screenshots, never with injected key presses: they end up in other windows. Opening the panel also takes keyboard focus for a moment.
- After code changes run `omarchy restart shell`; a plain reload keeps the old version running.
- `todo/` holds private notes and is ignored by Git; nothing from it belongs in public files.
