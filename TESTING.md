# Testing

```nushell
nu test.nu           # every test
nu test.nu layout    # tests whose name contains "layout"
```

The tests need the `rex` CLI on your PATH and a running Rex server, and take about 30 seconds. Each test prints PASS or FAIL with its time, and the run exits with status 1 if any test failed.

## How they work

Each test starts `nu -n --no-history` in a hidden Rex session, types commands into it with `rex send`, and checks what Rex recorded: status records, screen text, panes, tabs and the background color. No Rex window shows a hidden session, so the tests don't change anything on your screen. The runner kills a test's sessions when the test ends.

The probe's cache and data folders point into a new temporary folder, so the tests leave your history, cache and trusted layouts alone. A passing run deletes that folder. A failed run keeps it and prints its path, so you can look at what the probe saved.

The picker tests start a Rex server of their own with `rex server run`, on a socket in that temporary folder, and stop it afterwards. No Rex app connects to that server, so a question never appears on your screen, and Rex answers each one with "no app connected". Getting that answer means Rex accepted the items, because it checks them before it looks for an app. The test server loads `nurx.lua` from its own `init.lua`, the same way yours does.

The version test checks that `VERSION` in `nurx.nu` matches the newest section of CHANGELOG.md.

## What they can't check

Hidden sessions and the test server have no app attached, so the tests can't see what the Rex app draws, and they can't answer a picker question. [TODO.md](TODO.md) lists what still needs a look in the app.

## Adding a test

Write a `def "test ..."` command in `test.nu` and add it to the table in `main`. The helpers:

- `probe start` opens a hidden nu with the module imported and runs optional setup code.
- `probe run` types a command and waits for the next prompt.
- `probe eval` runs an expression in the probe and returns its value.
- `probe screen` returns a pane's text, and `probe status` returns its status records.
- `wait for` retries a closure until it returns something.
- `with private server` runs a closure against a Rex server of its own.

Make sure a new test can fail, since a test that can't fail checks nothing. Break the code it covers in a copy of the repo and run the test against that copy.
