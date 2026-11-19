# Nushell integration for the Rex terminal multiplexer.
#
#   use ~/src/nu-rex-integration/nurx.nu *
#   nurx enable status tint
#
# Commands return Rex's state as tables and run closures on other Rex hosts. Hooks are opt-in:
# `nurx enable` turns on only the features you name. Every command starts with `nurx`, so none
# of them hides a subcommand of the `rex` binary. `nurx` on its own shows its help and lists
# them. The picker, `VALUE | nurx`, also needs nurx.lua loaded from Rex's init.lua.

# This module's version. CHANGELOG.md has a section for each one, and test.nu checks they match.
const VERSION = "0.2.1"

const TERMINAL = "com.superlogical.terminal"
const FEATURES = [status last layout tint]

# Rex API ----------------------------------------------------------------------------------------

# Call a server method with a record of arguments. --server picks another Rex host.
def api [method: string, args: record = {}, --server: list<string> = []]: nothing -> any {
    $args | to json -r | ^rex ...$server api call $method $in | from json
}

# Call one of a terminal pane's methods, such as process, pwd, or program_status.
def "pane api" [
    session_id: string
    block_id: string
    method: string
    args: record = {}
    --server: list<string> = []
]: nothing -> any {
    api block.method {session_id: $session_id, block_id: $block_id, method: $method, args: $args} --server $server
}

# Rex state as tables ----------------------------------------------------------------------------

# Every terminal pane in every session, or in one session.
export def "nurx panes" [
    --session (-s): string # only this session, by ID or label
    --details (-d) # add each pane's foreground program, folder, and status records
]: nothing -> table {
    let sessions = (api session.list | get sessions | where {|s| $session == null or $s.session_id == $session or $s.label == $session })
    let panes = ($sessions | each {|s|
        let view = (api session.view {session_id: $s.session_id})
        $view.windows | each {|w|
            $w.layers | get blocks | flatten | where creator_name == $TERMINAL | each {|b| {
                session: $view.label
                tab: $w.label
                pane: $b.label
                focused: ($b.block_id == $w.focused_block_id)
                session_id: $s.session_id
                block_id: $b.block_id
            } }
        } | flatten
    } | flatten)
    if not $details { return $panes }
    $panes | par-each --keep-order {|p|
        let process = (try { pane api $p.session_id $p.block_id process } catch { {} })
        let pwd = (try { pane api $p.session_id $p.block_id pwd | get -o pwd } catch { null })
        let status = (try { pane api $p.session_id $p.block_id program_status | get records } catch { [] })
        $p
        | insert process ($process.foreground?.name?)
        | insert pwd ($pwd | default "" | str replace -r '^file://[^/]*' '')
        | insert status $status
    }
}

# Every OSC 7501 status record in every pane, newest first: what is running, blocked, failed, or done.
export def "nurx status" [--session (-s): string]: nothing -> table {
    nurx panes --details --session $session
    | where ($it.status | is-not-empty)
    | each {|p| $p.status | each {|r| {
        session: $p.session
        tab: $p.tab
        pane: $p.pane
        state: $r.state
        msg: $r.msg?
        app: $r.effective_app?
        at: ($r.updated_at | into datetime)
        session_id: $p.session_id
        block_id: $p.block_id
    } } }
    | flatten
    | sort-by at --reverse
}

# The server's events as a stream of flat records.
#
# They're named the way Rex's Lua `rex.on` names them (terminal.pwd_changed, window_created, ...).
# Every rex call connects a client, so client_* events are left out unless you pass --clients.
export def "nurx events" [
    --session (-s): string # one session's events, including its panes'; without it, only session-level changes
    --all (-a) # every server event
    --clients # keep client_* events
]: nothing -> list<record> {
    let flags = if $session != null { [-s $session] } else if $all { [--all] } else { [] }
    ^rex events --json ...$flags
    | lines
    | each {|line|
        let e = ($line | from json)
        if $e.type != "session_event" { return {type: $e.type, session_id: null, block_id: null, data: $e.payload?} }
        let inner = $e.payload.event
        if $inner.type == "block_event" {
            let creator = ($inner.payload.creator_name | split row "." | last)
            {type: $"($creator).($inner.payload.name)", session_id: $e.payload.session_id, block_id: $inner.payload.block_id, data: $inner.payload.payload?}
        } else {
            {type: $inner.type, session_id: $e.payload.session_id, block_id: null, data: $inner.payload?}
        }
    }
    | where {|e| $clients or not ($e.type | str starts-with "client_") }
}

# Closures on other hosts -----------------------------------------------------------------------

# Run a closure in nu on each host's Rex server and collect the results.
#
# Each host gets a hidden session, which is killed afterwards. The closure's source travels as
# text, so variables it captured don't exist on the other host; pass data with --with.
export def "nurx on" [
    hosts: list<string> # host labels from `rex hosts`, or "local" for this server
    code: closure
    --with: any # a value passed to the closure as its argument
]: nothing -> table {
    let call_code = if $with == null { $"do (view source $code)" } else { $"do (view source $code) ($with | to nuon)" }
    let script = $"print '@@nurx-on-begin@@'; ($call_code) | to nuon | print; print '@@nurx-on-end@@'"
    $hosts | par-each --keep-order {|host|
        let server = if $host == "local" { [] } else { [-S $host] }
        let session_id = (^rex ...$server new nurx-on --json | from json | get session_id)
        let run = (^rex ...$server run -s $session_id --wait --keep-open --focus=false --json -- nu -n -c $script | complete)
        let block_id = ($run.stdout | from json | get block_ids.0)
        let text = (pane api $session_id $block_id format {format: text, unwrap: true} --server $server | get content)
        ^rex ...$server kill $session_id
        let body = ($text | lines | skip until {|l| $l == "@@nurx-on-begin@@" } | skip 1 | take until {|l| $l == "@@nurx-on-end@@" } | str join "\n")
        let result = (try { $body | from nuon } catch { null })
        {host: $host, exit_code: $run.exit_code, result: $result, error: (if $result == null and $run.exit_code != 0 { $text | str trim } else { null })}
    }
}

# Picking from a value ----------------------------------------------------------------------------

# Rex's palette lists at most this many items.
const PICK_LIMIT = 2000

# The Lua half of the picker, which init.lua loads.
const PICK_LUA = path self nurx.lua

# Item icons for the `type` column that `ls` gives each row.
const PICK_ICONS = {dir: folder, file: document, symlink: link}

# VALUE as one line of text: dates as "3 days ago", nested values as nuon, control characters as
# spaces, cut at WIDTH characters.
def "pick text" [value: any, width: int = 120]: nothing -> string {
    let text = match ($value | describe -d | get type) {
        "string" => $value
        "nothing" => ""
        "datetime" => ($value | date humanize)
        "list" | "record" => ($value | to nuon --raw)
        "binary" => $"($value | bytes length) bytes"
        _ => (try { $value | into string } catch { $value | describe })
    }
    let flat = ($text | str replace -ar '[\x00-\x1f\x7f]+' ' ' | str trim)
    if ($flat | str length) > $width { $"($flat | str substring 0..<($width - 1))…" } else { $flat }
}

# What there is to pick from: a list's items, a range's numbers, a record's fields as
# {key, value} rows, or a string's lines.
def "pick rows" [input: any]: nothing -> list<any> {
    match ($input | describe -d | get type) {
        "list" => $input
        "range" => ($input | take ($PICK_LIMIT + 1))
        "record" => ($input | transpose key value)
        "string" => ($input | lines)
        _ => (error make {msg: $"pipe a list, table, range, record, or text into nurx, not ($input | describe)"})
    }
}

# One palette item for ROW. A record shows DISPLAY, or its first text column, as the title, and
# its other columns underneath.
def "pick item" [row: any, index: int, display: any]: nothing -> record {
    let shown = if $display == null { null } else if ($display | describe) == "closure" { do $display $row } else { $row | get $display }
    if ($row | describe -d | get type) != "record" {
        return {id: ($index | into string), title: (pick text ($shown | default $row))}
    }
    let fields = ($row | items {|key, value| {key: $key, value: $value} })
    let title_key = if $display == null {
        $fields | where {|f| ($f.value | describe -d | get type) == "string" } | get -o 0.key | default ($fields | get -o 0.key)
    } else if ($display | describe) == "cell-path" {
        $display | split cell-path | get -o 0.value
    }
    let title = if $display == null { pick text ($fields | where key == $title_key | get -o 0.value) } else { pick text $shown }
    let subtitle = ($fields | where key != $title_key | each {|f| $"($f.key): (pick text $f.value 40)" } | str join " · ")
    let type = ($fields | where key == type | get -o 0.value)
    let icon = ($PICK_ICONS | transpose type icon | where type == $type | get -o 0.icon)
    {id: ($index | into string), title: $title}
    | if $subtitle == "" { $in } else { insert subtitle (pick text $subtitle 200) }
    | if $icon == null { $in } else { insert icon $icon }
}

# Ask the connected Rex apps QUESTION, a rex.ui.pick table, and wait for an answer. Returns the
# picked ids, or null when the person closed the palette or pressed ctrl+c in the shell, which
# stops the action and closes the palette. rex.ui asks only from an action the server runs, so
# the question goes to the nurx_pick action that nurx.lua adds to init.lua.
def "pick ask" [question: record]: nothing -> any {
    let run = ($question | to json -r | ^rex do nurx_pick --args - | complete)
    if $run.exit_code != 0 {
        if ($run.stderr | str trim) == "Error: interrupted" { return null }
        if ($run.stderr | str contains 'no action named "nurx_pick"') {
            error make {msg: $"Rex has no nurx_pick action. Add this line to your Rex init.lua, then run `rex config reload`:\n  dofile\(($PICK_LUA | to json)\)"}
        }
        error make {msg: $"rex do nurx_pick failed: ($run.stderr | str trim)"}
    }
    let answer = ($run.stdout | from json)
    if $answer.ids? != null {
        # Lua writes an empty list as {}.
        return (if ($answer.ids | describe -d | get type) == "record" { [] } else { $answer.ids })
    }
    let reason = ($answer.reason? | default "failed")
    if $reason == "cancelled" { return null }
    let why = match $reason {
        "no_ui" => "this Rex has no rex.ui. The picker needs Rex 0.1.0-preview.21 or newer"
        "unsupported" => "no connected Rex app can show it. The apps may be older than the server"
        "no_client" => "no Rex app is connected"
        "busy" => "every Rex app is already showing a question"
        "timeout" => "nobody answered within 5 minutes"
        _ => ($answer.detail? | default $reason)
    }
    error make {msg: $"Rex couldn't show the picker: ($why)"}
}

# What the person picked, as INPUT's own values: list items, record fields, or lines. --index
# gives the positions instead.
def "pick result" [input: any, rows: list<any>, ids: list<any>, multi: bool, index: bool]: nothing -> any {
    let positions = ($ids | each {|id| $id | into int })
    if $index { return (if $multi { $positions } else { $positions.0 }) }
    let picked = ($positions | each {|i| $rows | get $i })
    if ($input | describe -d | get type) == "record" {
        return ($picked | reduce --fold {} {|f, acc| $acc | merge {($f.key): $f.value} })
    }
    if $multi { $picked } else { $picked.0 }
}

# `help nurx` with a Subcommands section after Usage, the way `str` shows its help. nushell looks
# for a module main's subcommands under the name `main`, so `help nurx` lists none. scope gives
# the names the caller imported, so a plain `use nurx.nu` lists `nurx nurx panes` and so on. The
# section borrows its colors from the help text, the heading's from Usage and the names' from
# --help, so it follows the color config and use_ansi_coloring.
def "pick help" []: nothing -> string {
    let help = (help nurx)
    let code = '(?<code>(?:\x1b\[[0-9;]*m)?)'
    let heading = ($help | parse -r $"($code)Usage" | get 0.code)
    let name = ($help | parse -r $"($code)--help" | get 0.code)
    let reset = if $heading == "" { "" } else { ansi reset }
    let entries = (
        scope commands
        | where name starts-with "nurx "
        # The first line of a command's help is its description, with backticked code highlighted.
        | each {|c| $"  ($name)($c.name) ($heading)\(custom\)($reset) - (help $c.name | lines | first)\n" }
        | str join
    )
    let parts = ($help | parse -r '(?s)^(?<usage>.*?\n  > [^\n]*\n)(?<rest>.*)$' | first)
    $"($parts.usage)\n($heading)Subcommands($reset):\n($entries)($parts.rest)"
}

# Pick from any value in Rex's command palette and get back what you picked.
#
# A table shows one item per row: its first text column as the title, the other columns
# underneath, and an icon for `ls` rows. A list shows its items, a record its fields, and text its
# lines. Escape, or ctrl+c in the shell, returns nothing. Every connected Rex app is asked, and the
# first answer wins.
#
# Typed alone, with nothing piped in and no arguments, nurx shows this help with its subcommands.
@example "pick a file" { ls | nurx }
@example "pick several branches" { ^git branch | nurx --multi "Branches to delete" }
@example "pick environment variables" { $env | nurx --multi }
export def main [
    prompt?: string # the question at the top of the palette
    --multi (-m) # tick any number of items and get a list back
    --index (-i) # return positions instead of the items
    --display (-d): oneof<cell-path, closure> # the column, or a closure, whose text titles each item
]: any -> any {
    let input = $in
    if $input == null and $prompt == null and $display == null and not ($multi or $index) {
        return (pick help)
    }
    let rows = (pick rows $input)
    if ($rows | is-empty) { error make {msg: "there is nothing to pick from"} }
    if ($rows | length) > $PICK_LIMIT {
        error make {msg: $"Rex's palette lists at most ($PICK_LIMIT) items. Narrow the input first, for example with `first ($PICK_LIMIT)` or `where`"}
    }
    let ids = (pick ask {
        title: ($prompt | default (if $multi { "Pick items" } else { "Pick an item" }))
        items: ($rows | enumerate | each {|r| pick item $r.item $r.index $display })
        multiple: $multi
    })
    if $ids == null { return null }
    pick result $input $rows $ids $multi $index
}

# Command status ---------------------------------------------------------------------------------

# Report a state for this pane with OSC 7501.
#
# Rex drops a report whose msg or title holds a control character, a newline included, so those
# become spaces, and text is cut at 200 characters.
export def "nurx status send" [
    state: string # idle, working, done, blocked, error, or clear
    --msg: string
    --id: string # slash-separated record path, such as job/3
    --title: string
    --progress: int # 0-100, only with working or blocked
    --kind: string # permission, question, or auth, only with blocked
    --app: string = "nu"
]: nothing -> nothing {
    let line = {|text|
        let flat = ($text | str replace -ar '[\x00-\x1f\x7f]+' ' ')
        let cut = if ($flat | str length) > 200 { $"($flat | str substring 0..<199)…" } else { $flat }
        $cut | encode base64
    }
    mut pairs = [$"state=($state)" $"app=($app)"]
    if $id != null { $pairs ++= [$"id=($id)"] }
    if $kind != null { $pairs ++= [$"kind=($kind)"] }
    if $progress != null { $pairs ++= [$"progress=($progress)"] }
    if $title != null { $pairs ++= [$"title=(do $line $title)"] }
    if $msg != null { $pairs ++= [$"msg=(do $line $msg)"] }
    print -n $"\e]7501;($pairs | str join ':')\e\\"
}

# pre_execution: report the command line as working. Rex drops working records at the prompt
# mark, which reedline sends after pre_prompt, so working has to be sent from here. The running
# command is kept as a record, which nu doesn't pass to child processes, so a nu started from
# this one doesn't inherit it.
def --env "status started" []: nothing -> nothing {
    let cmd = (commandline)
    if ($cmd | str trim) == "" { return }
    $env.NURX_STATUS_RUNNING = {cmd: $cmd, start: (date now)}
    nurx status send working --msg $cmd
}

# pre_prompt: report how the command ended. A quick success clears the record, so tabs don't
# collect a done mark from every `ls`.
def --env "status finished" []: nothing -> nothing {
    let running = $env.NURX_STATUS_RUNNING?
    if ($running | describe) !~ '^record' { return }
    $env.NURX_STATUS_RUNNING = null
    let took = ((date now) - $running.start)
    let code = $env.LAST_EXIT_CODE
    let msg = $"($running.cmd) · exit ($code) · ($took | format duration sec)"
    if $code < 0 {
        # Killed by a signal, usually ctrl+c. The spec asks a cancelled program to report idle.
        nurx status send idle --msg $msg
    } else if $code != 0 {
        nurx status send error --msg $msg
    } else if $took >= ($env.NURX_STATUS_DONE_AFTER? | default 3sec) {
        nurx status send done --msg $msg
    } else {
        nurx status send clear
    }
}

# Last value -------------------------------------------------------------------------------------

# Where this pane's last displayed value is kept, as nuon.
def "stash path" []: nothing -> path {
    $nu.cache-dir | path join nurx last $"($env.REX_BLOCK | str replace 'block:' '').nuon"
}

# Save the value for this pane and pass it through unchanged. Outside Rex there's no pane to
# save it for. Values `to nuon` can't write, such as closures, keep the previous file.
def "stash value" []: any -> any {
    tee {
        let value = $in
        if $value != null and ($env.REX_BLOCK? | is-not-empty) {
            try {
                let path = (stash path)
                mkdir ($path | path dirname)
                $value | to nuon | save -f $path
            }
        }
    }
}

# Open this pane's last displayed value in `explore`, in a floating layer over the tab. `q` closes it.
export def "nurx last" [
    --full (-f) # cover the whole tab instead of 90% of it
]: nothing -> nothing {
    if ($env.REX_BLOCK? | is-empty) { error make {msg: "nurx last works only in a Rex pane"} }
    let path = (stash path)
    if not ($path | path exists) {
        error make {msg: "no value saved for this pane yet. Run `nurx enable last`, then show a value"}
    }
    let window = (api session.describe_block {session_id: $env.REX_SESSION, block_id: $env.REX_BLOCK} | get block.window_id)
    let command = [$nu.current-exe "-n" "--no-history" "-c" $"open ($path | to nuon) | explore"]
    api session.new_layer {
        session_id: $env.REX_SESSION
        window_id: $window
        bounds: (if $full { [0 0 1 1] } else { [0.05 0.05 0.9 0.9] })
        focus: true
        layout: {block: {flavor: "com.superlogical.terminal.shell", label: "last value", options: {command: $command, shell: "none"}}}
    }
    | ignore
}

# display_output holds one hook, not a list, so wrap the one already there: save the value, then
# let that hook render it. A string hook is code, so the wrapper stays a string and reaches the
# stash through $env, which works however this module was imported. No hook means `table`. Your
# hook runs with `do --env`, so what it sets in $env, such as $env.LAST_EXIT_CODE, still counts.
def --env "enable last" []: nothing -> nothing {
    $env.NURX_LAST_STASH = {|| stash value }
    let current = $env.config.hooks.display_output?
    let kind = ($current | describe)
    if $kind == "string" and ($current | str contains "NURX_LAST_STASH") { return }
    if $kind == "closure" and (view source $current | str contains "NURX_LAST_STASH") { return }
    $env.config.hooks.display_output = if $kind == "closure" {
        {|| do $env.NURX_LAST_STASH | do --env $current }
    } else {
        $"do $env.NURX_LAST_STASH | do --env {|| ($current | default 'table') }"
    }
}

# Project layouts ---------------------------------------------------------------------------------

# The trusted layout files and their hashes.
def "layout trust store" []: nothing -> path {
    $nu.data-dir | path join nurx layouts-allowed.nuon
}

def "layout path" [dir: path]: nothing -> path {
    $dir | path expand | path join .nurx layout.nuon
}

# Whether this exact layout file, path and content, was trusted with `nurx layout allow`.
def "layout trusted" [file: path]: nothing -> bool {
    let hash = (open --raw $file | hash sha256)
    try { open (layout trust store) } catch { [] }
    | any {|a| $a.path == $file and $a.hash == $hash }
}

# Trust the layout file in DIR, which defaults to the current folder.
#
# Editing the file makes it untrusted again.
export def "nurx layout allow" [dir?: path]: nothing -> nothing {
    let file = (layout path ($dir | default $env.PWD))
    if not ($file | path exists) { error make {msg: $"no layout file at ($file)"} }
    let store = (layout trust store)
    mkdir ($store | path dirname)
    try { open $store } catch { [] }
    | where path != $file
    | append {path: $file, hash: (open --raw $file | hash sha256)}
    | save -f $store
}

# Turn one pane or split from layout.nuon into a node of Rex's layout tree.
def "layout tree" [node: any, dir: path]: nothing -> record {
    if ($node | describe -d | get type) == "string" { return (layout tree {run: $node} $dir) }
    let side = (["right" "below"] | where $it in $node | get -o 0)
    if $side != null {
        let pair = ($node | get $side)
        return {split: {
            direction: (if $side == "right" { "horizontal" } else { "vertical" })
            ratio: ($node.ratio? | default 0.5)
            before: (layout tree $pair.0 $dir)
            after: (layout tree $pair.1 $dir)
        }}
    }
    let cwd = if $node.cwd? == null { $dir } else { $dir | path join $node.cwd | path expand }
    let options = {command: ($env.NURX_LAYOUT_COMMAND? | default [$nu.current-exe]), shell: "none", cwd: $cwd}
    {block: {
        flavor: "com.superlogical.terminal.shell"
        label: ($node.label? | default ($node.run? | default "nu"))
        options: (if $node.run? == null { $options } else { $options | insert initial_input $"($node.run)\n" })
    }}
}

# Open DIR's .nurx/layout.nuon as a new tab in this session, unless a tab with its label is open.
#
# DIR defaults to the current folder. This doesn't check trust, since you asked for it.
export def "nurx layout open" [dir?: path]: nothing -> nothing {
    let dir = ($dir | default $env.PWD | path expand)
    let spec = (open (layout path $dir))
    let label = ($spec.label? | default ($dir | path basename))
    let view = (api session.view {session_id: $env.REX_SESSION})
    if ($view.windows | any {|w| $w.label == $label }) { return }
    api session.new_window {session_id: $env.REX_SESSION, window_label: $label, focus: false, layout: (layout tree $spec.layout $dir)}
    | ignore
    print $"opened the ($label) tab from ($dir | path join .nurx layout.nuon)"
}

# env_change.PWD: open a trusted layout, or say how to trust an untrusted one.
def "layout entered" [dir: path]: nothing -> nothing {
    let file = (layout path $dir)
    if ($env.REX_SESSION? | is-empty) or not ($file | path exists) { return }
    if (layout trusted $file) {
        nurx layout open $dir
    } else {
        print $"($file) wants to open a tab; run `nurx layout allow` to trust it"
    }
}

# Pane tint -------------------------------------------------------------------------------------

def "tint rules" []: nothing -> list<record> {
    $env.NURX_TINT_RULES? | default [
        {when: {|| $env.PWD =~ '/prod(/|$)' }, bg: "#3a0000"}
        {when: {|| ($env.AWS_PROFILE? | default "") =~ 'prod' }, bg: "#3a0000"}
        {when: {|| is-admin }, bg: "#3a2a00"}
    ]
}

# pre_prompt: set the background for the first matching rule, or reset it. It keeps no state, so
# returning from an ssh session that tinted the pane resets it.
def "tint apply" []: nothing -> nothing {
    let bg = (tint rules | where {|rule| do $rule.when } | get -o 0.bg)
    if $bg == null { print -n "\e]111\e\\" } else { print -n $"\e]11;($bg)\e\\" }
}

# Version ------------------------------------------------------------------------------------------

# This module's version, with the versions of nushell and the Rex server, for bug reports.
#
# `rex` is null when the server can't be reached.
export def "nurx version" []: nothing -> record {
    {
        nurx: $VERSION
        nushell: (version | get version)
        rex: (try { api server.version | get rex_version } catch { null })
    }
}

# Turning features on -----------------------------------------------------------------------------

def features [] { $FEATURES }

# HOOKS with CODE appended, tagged with FEATURE. An earlier hook with the same tag is removed
# first, so enabling a feature twice doesn't run it twice. Your own hooks are kept.
def "hooks with" [hooks: any, feature: string, code: closure]: nothing -> list<any> {
    $hooks
    | default []
    | where {|hook| ($hook | describe) !~ '^record' or $hook.nurx? != $feature }
    | append {code: $code, nurx: $feature}
}

# Turn on the hooks for the features you name.
#
# Your own hooks are kept, and running it again doesn't add a feature twice. Call it at the end of
# config.nu, because a later `$env.config.hooks.pre_prompt = [...]` replaces the whole list.
#
# status   report each command's state to Rex with OSC 7501
# last     save each displayed value for `nurx last`
# layout   open a trusted .nurx/layout.nuon tab when you cd into its folder
# tint     tint the pane's background while a rule in $env.NURX_TINT_RULES matches
export def --env "nurx enable" [
    ...features: string@features
]: nothing -> nothing {
    let unknown = ($features | where $it not-in $FEATURES)
    if ($unknown | is-not-empty) {
        error make {msg: $"unknown feature ($unknown | str join ', '). Choose from ($FEATURES | str join ', ')"}
    }
    if ($features | is-empty) {
        error make {msg: $"name one or more features: ($FEATURES | str join ', ')"}
    }
    for feature in $features {
        match $feature {
            "status" => {
                $env.config.hooks.pre_execution = (hooks with $env.config.hooks.pre_execution? status {|| status started })
                $env.config.hooks.pre_prompt = (hooks with $env.config.hooks.pre_prompt? status {|| status finished })
            }
            "last" => { enable last }
            "layout" => {
                $env.config.hooks.env_change.PWD = (hooks with $env.config.hooks.env_change.PWD? layout {|_, after| layout entered $after })
            }
            "tint" => {
                $env.config.hooks.pre_prompt = (hooks with $env.config.hooks.pre_prompt? tint {|| tint apply })
            }
        }
    }
}
