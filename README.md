# Omahours

How long you've worked on each project, right in your Omarchy bar: $\color{#4ade80}\texttt{4h37m}$

Right-click starts or pauses, left-click switches projects. Lock the screen and the clock stops with you. Your times stay in one small file on your machine: no account, no cloud, nothing sent anywhere.

![Omahours panel](preview.png)

## Features

- The bar shows your last project's time in whole minutes: `40m`, `22h2m`.
- One project runs at a time; starting another pauses the current one.
- Suspend pauses it too, and it continues when you're back.
- Green while running, dark red while paused, or plain like your other bar icons.
- Every panel action has a key.
- The file is plain JSON. Keep it in your Dropbox, or any other folder you sync, and your times follow you to your other machines.

## Install

```sh
omarchy plugin add https://github.com/duderik/omahours --enable
```

Nothing else to install: Omahours only needs Omarchy.

The widget appears on the right of the bar. To move it:

```sh
omarchy bar move io.github.duderik.omahours --section <section>
```

## Remove

```sh
omarchy plugin remove io.github.duderik.omahours
```

Your projects stay (see Data). Omarchy drops the widget's settings, so set a custom data file again after reinstalling.

## Panel

Each row: project, time, buttons to start or pause, edit, delete. `+ New` adds a project, the gear opens the settings.

| Key | Action |
|---|---|
| `j` `k` or arrows | select |
| `Enter` `Space` | start or pause |
| `e` | edit |
| `d` | delete |
| `n` | new project |
| `s` | settings |
| `Esc` | back or close |

The time field accepts:

| Input | Effect |
|---|---|
| `2h22m`, `1h30`, `90m` | sets |
| `+2h22m` | adds |
| `-90m` | subtracts, not below zero |
| `0` | resets |

Invalid input turns the field red and saves nothing: an empty or duplicate name, an unreadable time, more than 99999h. Names are case-sensitive: `abc` and `ABC` are two projects.

## Settings

Two switches behind the gear, both on by default:

- Pause on lock/suspend: off keeps the timer running. A project you paused yourself never restarts.
- Colored timer: off uses the bar icon color, dimmed while paused.

The data file is set in the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.duderik.omahours", "dataFile": "~/Dropbox/omahours/projects.json" }
```

Default: `~/.local/share/omahours/projects.json`.

## Data

The file changes only when you start, pause, add, edit or delete, so a synced folder works. Don't track on two machines in the same file at once.

Power loss or a shell crash while a project runs: on the next start, Omahours counts up to the last heartbeat (written every minute to `~/.local/state/omahours/heartbeat`) and pauses the project.

An unreadable data file, after a broken edit or a sync conflict, shows `!` in the bar and the file name in the panel. Omahours won't write to it until it's fixed, so nothing in it is lost.

## Tests

The tests need Node.js.

```sh
node tests/model.test.js
node tests/model-extreme.test.js
```

## License

MIT, see [LICENSE](LICENSE).
