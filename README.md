# Notch bar widget

A bar widget for aliasOS and Omarchy that shows your running [notch](https://github.com/aliasproject/notch) timer and lets you start, stop and edit time entries without opening the TUI.

## What it does

- **In the bar:** your running timer. Click it to open the popout.
- **In the popout:**
  - Today's and this week's totals.
  - Your recent tasks: start or stop one with a click, or expand it to see its sessions.
  - Quick add: type a task name and press Enter. It starts under Uncategorized, and you can assign a client and project afterwards.
  - Edit: rename the running timer or a whole task, or move it to another client and project. Change the running timer's notes, or a single session's start time, end time and notes.
  - Delete a task, a single session, or the running timer, with confirmation.
  - Keyboard control: arrow keys to move and expand, Enter or Space to start or stop the selected row (or the running timer when nothing is selected), `n` to quick add, `e` to edit, `s` to stop, `o` to open the TUI, and `x` or Delete to delete.
  - A link that opens the full notch TUI.

The widget has no daemon of its own. Every action is a one-shot `notch` CLI call: `status`, `tasks`, `summary`, `entries`, `projects` and `clients` (with `-json`) to read, and `start`, `stop`, `edit` and `delete` to write. It also runs `notch watch` to pick up changes you make in the TUI right away.

## Requirements

- `notch` on your `PATH`. Some of the popout needs notch v0.10.0 or later (`notch upgrade`): the totals (`summary`), a task's sessions (`entries`), delete (`delete`), and editing a whole task or a session's times (`edit --from-project`/`--from-task`, `--start`/`--end`).
- **aliasOS:** the shell's `Color` palette is reached as `Commons.Color`, which Qt 6.12 requires (see aliasOS's `docs/plugins.md`).
- **aliasOS 1.11.0 or later:** the bar icon is fitted with `OpticalGlyph.paintedSize`, which arrived with 1.11.0's bar icons.

## Install

On aliasOS:

```sh
aliasos-plugin-add https://github.com/aliasproject/notch-plugin
aliasos-plugin-enable io.github.aliasproject.notch
```

It goes in the center section by default. You can drag it anywhere on the bar.

## Develop

Edit the files here, then copy them over the installed plugin and restart the shell. The shell loads plugins only once, at startup:

```sh
cp BarWidget.qml Model.js manifest.json ~/.config/aliasos/plugins/io.github.aliasproject.notch/
aliasos-restart-shell
```

To open the popout without clicking:

```sh
quickshell ipc -p /usr/share/aliasos/shell call io.github.aliasproject.notch open
```

Errors from the plugin show up in `quickshell log -p /usr/share/aliasos/shell`.

## License

MIT. See [LICENSE](LICENSE).
