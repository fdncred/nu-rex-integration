# TODO

## Not checked yet

Most tests read Rex's state from the server in hidden sessions, which no Rex window shows. In the Rex app, the tint, the tab spinner and the picker's palette work. Nobody has checked these yet:

- picking an item in the Rex app and getting it back in nu
- the session picker's mark for a session with a finished command
- whether an `error` record marks the tab
- `nurx on` against a second machine. The first one will be a Windows host, where the screen text may have Windows line endings.
- the tint over ssh

The screenshots in the README come from the Rex app, and Ctrl-C closed both palettes. Nobody has picked an item through one yet.

## Known gaps

- `nurx on` stops at the first host that fails, so the other hosts' results are lost. A name that `rex hosts` doesn't list goes to Rex as a network address, and the error you get is Rex's raw connection log.
