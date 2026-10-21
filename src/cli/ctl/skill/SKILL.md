---
name: ghostty-ctl
description: Inspect or rearrange Ghostty windows, tabs and splits (move/swap/group terminals, new tabs with commands, focus a session) via `ghostty +ctl` on Tony's Ghostty fork. Use when asked to organise terminals or find which pane runs what.
---

# ghostty-ctl

Tony's Ghostty fork exposes the D-Bus interface `dev.tony.Ghostty.Control`, wrapped by `ghostty +ctl` (this skill ships with it: `ghostty +ctl skill show`). Running terminals are re-parented, never restarted: an omp session keeps its process when moved. Full details per command: `ghostty +ctl <command> --help`.

Check it's available first: `ghostty +ctl layout get >/dev/null`. An unknown `+ctl` action means upstream Ghostty is installed; an unknown-interface D-Bus error means the running instance isn't the fork. Either way, stop and say so.

## Read the layout

```bash
ghostty +ctl layout get --pretty
```

- `windows[].tabs[].tree` is a binary tree. Splits are `{"type":"split","layout":"horizontal"|"vertical","ratio":R,"left":…,"right":…}`. `horizontal` = left|right, `vertical` = top/bottom; `ratio` = left/top share.
- Leaves are `{"type":"surface","id":"0x…","pid","fg_pid","fg_comm","fg_cmdline","title","cwd","focused"}`. Use `fg_comm`/`fg_cmdline`/`title`/`cwd` to identify what runs where (omp titles start with `π`).
- Your own pane: `$GHOSTTY_SURFACE_ID`.

## Simple edits: one command each

| Want | Command |
|---|---|
| Focus a pane (selects tab, raises window) | `ghostty +ctl focus ID` |
| Put SRC next to TGT | `ghostty +ctl move SRC --to=TGT --edge=left\|right\|up\|down` |
| Exchange two panes (any tabs/windows) | `ghostty +ctl swap A B` |
| Pane into its own tab / window | `ghostty +ctl to-tab SRC [--window=WID\|--new-window] [--position=N]` |
| Resize | `ghostty +ctl ratio ID --layout=horizontal --value=0.7` |
| Revert the last `+ctl` change | `ghostty +ctl layout undo` |

## Bigger rearrangements: edit the whole layout

1. `ghostty +ctl layout get > /tmp/layout.json`.
2. Write the desired document with `jq` or by hand. Keep every existing surface somewhere; keep `"id"` leaves as they are (extra fields are ignored). Rebuild trees freely: reorder `tabs`, move leaves between tabs/windows, change `layout`/`ratio`, drop a window's `"id"` to make it a new window.
3. New terminals: a leaf `{"type":"surface","new":{"name":"n1","command":["htop"],"cwd":"/tmp","title":"…"}}`. `command` may also be a shell string; omit it for the default shell. Names must be unique.
4. Optional `"focus": "0x…"` or a `new` name; optional per-window `"selected_tab"`, per-tab `"zoomed"`.
5. Validate: `ghostty +ctl layout apply --dry-run /tmp/new.json`. Errors name the exact JSON path or surface.
6. Apply: `ghostty +ctl layout apply /tmp/new.json`. The result maps each `new` name to its id.

Rules:
- A surface left out is an error. `--allow-close` closes it, which KILLS its process (possibly another agent session): only with the user's explicit OK for those exact panes.
- Show the user the planned arrangement before a large apply; mention `ghostty +ctl layout undo` afterwards.
- Quick-terminal windows are excluded and can't be targeted.

## Keyboard

The fork adds `move_split:left|right|up|down` (swap the focused split with its neighbour). Tony's binding: `alt+shift+arrows`.
