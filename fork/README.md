# Tony's Ghostty fork

Branch `tony/control-api` = upstream `main` + our patches:

- `dev.tony.Ghostty.Control` D-Bus interface (`GetLayout`, `ApplyLayout`, `Focus`) in `src/apprt/gtk/control/`.
- `ghostty +ctl` CLI (`src/cli/ctl.zig`, `src/cli/ctl/`) with a bundled agent skill (`+ctl skill show|install`).
- `move_split:left|right|up|down` keybind action.

## Install and update

`ghostty-fork` (this directory) builds and installs it like `omp-fork` does for omp:

```bash
ghostty-fork setup          # once: install the script, desktop integration and the daily timer
ghostty-fork install        # build the committed branch and switch to it
ghostty-fork install --dirty  # try uncommitted edits
ghostty-fork update         # rebase onto upstream main, test, build, install (what the timer runs)
ghostty-fork status         # installed build, patches, which Ghostty processes need a relaunch
ghostty-fork rollback       # previous build
```

Builds live in `~/.local/lib/ghostty-fork/<version>-<sha>-sys/` (`zig build -p` prefixes, the last
three kept plus any still running); `current` and `~/.local/bin/ghostty` point at the active one.
They link fontconfig, freetype, harfbuzz, libpng, zlib and oniguruma from the system, as Arch's
package does: the bundled fontconfig crashed a single-instance Ghostty in `FcFontSort`.
The desktop entry (a hand-written override keeps its flags), D-Bus service, systemd user unit,
icons and shell completions point at those stable paths, so a relaunched Ghostty runs the new
build and open windows keep theirs.

`ghostty-fork.timer` runs `update` daily at 04:00; a successful update force-pushes the branch to
the `fork` remote (github.com/tonybart1337/ghostty). A rebase conflict starts an agent
(`agent run -p personal omp`) in the transient unit `ghostty-fork-resolve` once per upstream
commit; results and failures go to Telegram via `agent-notify`.

## Developing

Edit on `tony/control-api` in `~/projects/home/ghostty`, then `ghostty-fork install --dirty` to try
it and relaunch Ghostty. Unit tests: `mise exec zig@0.17.0 -- zig build test -Dtest-filter=<name>`
(see `TESTS` in `ghostty-fork`). GUI tests run on the throwaway display `:9` inside
`dbus-run-session --config-file=fork/test-bus.conf` with a `--class` of their own.
