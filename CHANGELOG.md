# Changelog

Each version of nurx has a section here, newest first. `nurx version` prints the version you have.

Versions follow [semantic versioning](https://semver.org). Renaming or removing a command, flag, environment variable or file location breaks someone's `config.nu`, so it bumps the major version, or the minor version while nurx is at 0.x.

## 0.2.1 - Unreleased

### Fixed

- With `nurx enable last`, your own `display_output` hook's changes to `$env` are kept again, as they are without nurx. That includes `$env.LAST_EXIT_CODE`, so a failure your hook catches still reaches the prompt and the `status` report.

## 0.2.0 - 2026-11-18

### Added

- Typing `nurx` on its own shows its help with a Subcommands section that lists the other commands, the way `str` does. nushell's own `help nurx` and `nurx --help` still leave that section out. With no prompt or flags, `null | nurx` shows this help too, where it used to raise an error.

### Changed

- The help for `nurx events`, `nurx on`, `nurx status send`, `nurx layout allow`, `nurx layout open`, `nurx version` and `nurx enable` starts with a one-line summary, and the details follow in their own paragraph. The Subcommands section shows that summary.

## 0.1.0 - 2026-11-18

The first version.

### Added

- `VALUE | nurx` shows a list, table, range, record or text in Rex's command palette and returns what you pick. `--multi`, `--index` and `--display` work like they do for `input list`, and Escape or Ctrl-C returns nothing. It goes through the `nurx_pick` action in `nurx.lua`, which Rex's `init.lua` loads.
- `nurx panes`, `nurx status` and `nurx events` return Rex's panes, status records and server events as tables.
- `nurx on` runs a closure in nu on other Rex hosts and returns each host's result.
- `nurx status send` reports a state for the current pane with OSC 7501.
- `nurx enable` turns on four hooks. It keeps your own hooks, and enabling a feature twice doesn't add it twice.
  - `status` reports each command to Rex as working, then done, error or idle.
  - `last` saves each displayed value, and `nurx last` opens it in `explore` in a floating pane.
  - `layout` opens a project's `.nurx/layout.nuon` as a tab once you trust it with `nurx layout allow`. `nurx layout open` opens one by hand.
  - `tint` sets the pane's background while a rule in `NURX_TINT_RULES` matches.
- `nurx version` returns the versions of nurx, nushell and the Rex server.
