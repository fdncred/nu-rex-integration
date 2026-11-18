# Tests for nurx.nu. Each test drives nu in a hidden Rex session, which no Rex window shows, and
# reads back what Rex recorded. It needs the rex CLI and a Rex server it can reach.
#
#   nu test.nu            # every test
#   nu test.nu layout     # only tests whose name contains "layout"
#
# The probe nu runs with -n and --no-history, and its cache and data folders point into a new
# temporary folder, so the tests leave your history, cache, and trusted layouts alone.

use std/assert
const MODULE = path self nurx.nu
const LUA = path self nurx.lua
const CHANGELOG = path self CHANGELOG.md
use $MODULE *

const LABEL = "nurx-test"

# Probe helpers ----------------------------------------------------------------------------------

# Start nu in a hidden Rex session, import the module, run SETUP, and wait for the prompt.
# VARS become environment variables of the probe, which typed commands can read.
def "probe start" [
    setup: string = ""
    --vars: record = {}
    --import: string = "*" # what `use nurx.nu` imports; "" imports the module by name
]: nothing -> record {
    let dir = $env.NURX_TEST_DIR
    let env_args = (
        {XDG_CACHE_HOME: ($dir | path join cache), XDG_DATA_HOME: ($dir | path join data)}
        | merge $vars
        | items {|k, v| $"($k)=($v)" }
    )
    let code = $"use ($MODULE) ($import)\n($setup)"
    let argv = [/usr/bin/env -u AWS_PROFILE ...$env_args $nu.current-exe -n --no-history -e $code]
    let r = (^rex new $LABEL --json --shell none -- ...$argv | from json)
    let p = {s: $r.session_id, b: $r.initial_windows.0.block_ids.0}
    probe wait $p
    $p
}

# A pane's screen and scrollback as text, with soft-wrapped lines joined. BLOCK defaults to the
# probe's own pane.
def "probe screen" [p: record, block?: string]: nothing -> string {
    ^rex capture -s $p.s -b ($block | default $p.b) --unwrap --trim
}

# Wait until the last line on the screen is a prompt, which ends with `>`.
def "probe wait" [p: record, --timeout: duration = 15sec]: nothing -> nothing {
    let deadline = (date now) + $timeout
    loop {
        let last = (probe screen $p | lines | where $it != "" | last 1 | get -o 0 | default "")
        if ($last | str ends-with ">") { break }
        if (date now) > $deadline { error make {msg: $"no prompt within ($timeout); last line: ($last)"} }
        sleep 200ms
    }
}

# Type CMD and press Enter, then wait for the next prompt unless --no-wait.
def "probe run" [p: record, cmd: string, --no-wait]: nothing -> nothing {
    # rex send refuses empty text, so an empty command is a bare Enter.
    if $cmd != "" { ^rex send -s $p.s -b $p.b $cmd }
    ^rex send-key -s $p.s -b $p.b enter
    if not $no_wait {
        sleep 300ms
        probe wait $p
    }
}

def "probe key" [p: record, ...keys: string]: nothing -> nothing {
    ^rex send-key -s $p.s -b $p.b ...$keys
}

# Run CODE at the probe's prompt and return its value, read back from the screen as nuon.
def "probe eval" [p: record, code: string]: nothing -> any {
    let mark = $"@@(random chars --length 8)@@"
    probe run $p $"\(($code)\) | to nuon --raw | '($mark)' + $in | print"
    probe screen $p | lines | where {|l| $l | str starts-with $mark } | last | str substring ($mark | str length).. | from nuon
}

# The OSC 7501 records Rex holds for the probe's pane.
def "probe status" [p: record]: nothing -> table {
    {session_id: $p.s, block_id: $p.b, method: program_status, args: {}}
    | to json -r
    | ^rex api call block.method $in
    | from json
    | get records
    | select -o id state msg
}

# The probe's last saved value, as nuon text, or null.
def "probe saved" [p: record]: nothing -> any {
    let file = ($env.NURX_TEST_DIR | path join cache nushell nurx last $"($p.b | str replace 'block:' '').nuon")
    if ($file | path exists) { open --raw $file } else { null }
}

# Call CHECK until it returns something other than null or false, and return that.
def "wait for" [check: closure, --timeout: duration = 10sec]: nothing -> any {
    let deadline = (date now) + $timeout
    loop {
        let got = (do $check)
        if $got != null and $got != false { return $got }
        if (date now) > $deadline { error make {msg: $"timed out after ($timeout): (view source $check)"} }
        sleep 200ms
    }
}

# Kill every session the tests started.
def cleanup []: nothing -> nothing {
    ^rex ls --json | from json | get sessions | where label == $LABEL | each {|s| ^rex kill $s.session_id } | ignore
}

# Run CODE with the rex CLI pointed at a Rex server of its own, which no Rex app connects to, so a
# question for the apps never shows up on your screen. Returns what CODE returned.
def "with private server" [
    code: closure
    --init: string = "" # the server's init.lua
]: nothing -> any {
    let dir = ($env.NURX_TEST_DIR | path join $"server-(random chars --length 4)")
    mkdir $dir
    $init | save -f ($dir | path join init.lua)
    let address = $"unix://($dir)/rex.sock"
    job spawn {
        ^rex server run --listen $address --state-dir ($dir | path join state) --restore=false --config ($dir | path join init.lua) o+e> ($dir | path join server.log)
    } | ignore
    let outcome = (try {
        wait for {|| ($dir | path join rex.sock | path exists) }
        {value: (with-env {REX_SERVER: $address} { hide-env -i REX_SESSION REX_BLOCK; do $code })}
    } catch {|e| {error: ($e.rendered? | default $e.msg)} })
    ^rex --autostart=false -S $address server stop | complete | ignore
    if $outcome.error? != null { error make {msg: $outcome.error} }
    $outcome.value
}

# Tests ------------------------------------------------------------------------------------------

def "test isolation" [] {
    let p = (probe start)
    let got = (probe eval $p '{cache: $nu.cache-dir, data: $nu.data-dir, history: $nu.history-enabled}')
    assert ($got.cache | str starts-with $env.NURX_TEST_DIR) $"cache dir is ($got.cache)"
    assert ($got.data | str starts-with $env.NURX_TEST_DIR) $"data dir is ($got.data)"
    assert equal $got.history false
}

def "test enable checks its arguments" [] {
    assert error {|| nurx enable }
    assert error {|| nurx enable status bogus }
}

# The module's commands share a prefix with none of the rex binary's subcommands.
def "test no command hides a rex subcommand" [] {
    let names = (^$nu.current-exe -n --no-history -c $"use ($MODULE) *; scope modules | where name == nurx | get 0.commands.name | to nuon" | from nuon)
    assert ($names | is-not-empty)
    assert equal ($names | where {|n| $n == "rex" or ($n | str starts-with "rex ") }) []
    assert equal ($names | where {|n| $n != "nurx" and not ($n | str starts-with "nurx ") }) []
}

# `nurx version` matches the newest section of CHANGELOG.md.
def "test version matches the changelog" [] {
    let got = (nurx version)
    assert ($got.nurx =~ '^\d+\.\d+\.\d+$') $"($got.nurx) isn't a semantic version"
    let newest = (open --raw $CHANGELOG | lines | parse --regex '^## (?<version>\d+\.\d+\.\d+)' | get -o 0.version)
    assert equal $got.nurx $newest
    assert equal $got.nushell (version | get version)
    assert ($got.rex != null) "the Rex server should report its version"
}

def "test picker checks its input" [] {
    for bad in [null 42 [] (0x[01])] {
        assert error {|| $bad | nurx "Pick one" } $"($bad | describe) should be refused"
    }
    let too_many = (try { 1.. | nurx; "no error" } catch {|e| $e.msg })
    assert str contains $too_many "at most 2000 items"
}

# Typed alone, nurx shows its help with a Subcommands section between Usage and Flags, the way
# `help str` does, under the names the import gave the commands.
def "test nurx alone shows its help and subcommands" [] {
    let names = (scope modules | where name == nurx | get 0.commands.name | where $it != nurx | sort)
    let descriptions = (scope commands | where name in $names | sort-by name | get description)
    let not_one_line = ($descriptions | where {|d| $d == "" or ($d | str contains "\n") })
    assert equal $not_one_line [] "each command needs a one-line description"
    let section = '(?s)\nUsage:\n  > nurx [^\n]*\n\nSubcommands:\n(?<entries>.*?)\n\nFlags:'
    let entries = {|text|
        $text | ansi strip | parse -r $section | get -o 0.entries | default "" | lines
        | parse '  {name} (custom) - {description}'
    }
    let shown = (do $entries (nurx))
    assert equal $shown.name $names
    # help drops the backticks around the code it highlights.
    assert equal $shown.description ($descriptions | str replace -a '`' '')
    let plain = (do $entries (^$nu.current-exe -n --no-history -c $"use ($MODULE); nurx"))
    assert equal $plain.name ($names | each {|n| $"nurx ($n)" })
}

# No Rex app connects to the private server, so every question ends in `no_client`. Getting that
# far means rex.ui.pick accepted the items, since it checks them before it asks the apps.
def "test picker asks rex" [] {
    let inputs = [
        {|| ls $env.NURX_TEST_DIR | nurx }
        {|| ls $env.NURX_TEST_DIR | nurx --multi "Files" }
        {|| [a b c] | nurx }
        {|| 1..10 | nurx --index }
        {|| {a: 1, b: "two\nlines", c: [1 2], d: (date now)} | nurx }
        {|| "one\ntwo]]three]=]four" | nurx }
        {|| [[n v]; [x 1] [y 2]] | nurx --display {|r| $"($r.n)=($r.v)" } }
        {|| [[n v]; [x 1] [y 2]] | nurx --display v }
        {|| [{a: null, b: {|| 1 }, c: 0x[0102], d: 1.5, e: 3sec, f: 2kb, g: true, type: dir}] | nurx }
    ]
    let errors = (with private server --init $"dofile\(($LUA | to json)\)" {||
        $inputs | each {|code| try { do $code; "no error" } catch {|e| $e.msg } }
    })
    for e in ($errors | enumerate) {
        assert str contains $e.item "no Rex app is connected" $"input ($e.index)"
    }
}

# Without nurx.lua in init.lua, nurx says which line to add.
def "test picker needs nurx.lua" [] {
    let got = (with private server {|| try { [a b] | nurx; "no error" } catch {|e| $e.msg } })
    assert str contains $got "Rex has no nurx_pick action"
    assert str contains $got $"dofile\(($LUA | to json)\)"
}

def "test keeps your hooks" [] {
    let setup = '
        $env.config.hooks.pre_execution = [{|| $env.MINE_EXEC = ($env.MINE_EXEC? | default 0) + 1 }]
        $env.config.hooks.pre_prompt = [{|| $env.MINE_PROMPT = ($env.MINE_PROMPT? | default 0) + 1 }]
        $env.config.hooks.env_change.PWD = [{|_, after| $env.MINE_PWD = $after }]
        $env.config.hooks.display_output = {|| to json -r }
        nurx enable status last layout tint
        nurx enable status last layout tint
    '
    let p = (probe start $setup --vars {TEST_DIR: $env.NURX_TEST_DIR})
    probe run $p 'cd $env.TEST_DIR'
    probe run $p '^false'
    let status = (probe status $p)
    assert equal ($status | get state) [error]
    assert ($status.0.msg | str starts-with '^false · exit 1 · ')
    probe run $p '{a: [1 2]}'
    assert str contains (probe screen $p) '{"a":[1,2]}'
    assert equal (probe saved $p) '{a: [1, 2]}'
    let got = (probe eval $p '{
        exec: $env.MINE_EXEC
        prompt: $env.MINE_PROMPT
        pwd: $env.MINE_PWD
        pre_execution: ($env.config.hooks.pre_execution | length)
        pre_prompt: ($env.config.hooks.pre_prompt | length)
        pwd_hooks: ($env.config.hooks.env_change.PWD | length)
        display: (view source $env.config.hooks.display_output)
    }')
    # Yours plus status; yours plus status and tint; yours plus layout.
    assert equal [$got.pre_execution $got.pre_prompt $got.pwd_hooks] [2 3 2]
    # Your hooks ran for cd, ^false, the value, and this command.
    assert equal $got.exec 4
    assert equal $got.prompt 4
    assert equal ($got.pwd | path basename) ($env.NURX_TEST_DIR | path basename)
    # Enabling `last` twice wrapped your display hook once.
    assert equal ($got.display | split row NURX_LAST_STASH | length) 2
}

def "test last keeps your display hook" [] {
    let cases = [
        [import setup expect];
        ["*" '$env.config.hooks.display_output = {|| to json -r }' '{"a":[1,2]}']
        ["*" '$env.config.hooks.display_output = "to json -r"' '{"a":[1,2]}']
        ["*" '$env.config.hooks.display_output = "table -e"' '│ 0 │ 1 │']
        ["*" '' '[list 2 items]']
        ["*" '$env.config.hooks.display_output = null' '[list 2 items]']
        ["" '$env.config.hooks.display_output = "to json -r"' '{"a":[1,2]}']
    ]
    for c in $cases {
        let enable = if $c.import == "*" { "nurx enable last" } else { "nurx nurx enable last" }
        let p = (probe start $"($c.setup)\n($enable)" --import $c.import)
        probe run $p '{a: [1 2]}'
        assert str contains (probe screen $p) $c.expect $"import '($c.import)', setup: ($c.setup)"
        assert equal (probe saved $p) '{a: [1, 2]}' $"import '($c.import)', setup: ($c.setup)"
        ^rex kill $p.s
    }
}

def "test last opens explore" [] {
    let p = (probe start 'nurx enable last')
    probe run $p '[[name size]; [a 1] [b 2]]'
    let saved = (probe saved $p)
    probe run $p '^echo external'
    probe run $p '{|| 1 }'
    assert equal (probe saved $p) $saved "external output and closures keep the saved value"
    probe run $p 'nurx last'
    let layer = (wait for {|| nurx panes -s $p.s | where block_id != $p.b | get -o 0.block_id })
    wait for {|| probe screen $p $layer | str contains 'size' }
    ^rex send-key -s $p.s -b $layer q
    wait for {|| nurx panes -s $p.s | where block_id != $p.b | is-empty }
}

def "test status" [] {
    let p = (probe start "nurx enable status\n$env.NURX_STATUS_DONE_AFTER = 1sec")
    probe run $p ''
    assert equal (probe status $p) []

    probe run $p 'sleep 2sec' --no-wait
    let working = (wait for {|| probe status $p | where state == working | get -o 0 })
    assert equal $working.msg 'sleep 2sec'
    probe wait $p
    let done = (probe status $p)
    assert equal ($done | get state) [done]
    assert ($done.0.msg | str starts-with 'sleep 2sec · exit 0 · ')

    probe run $p 'ls | length'
    assert equal (probe status $p) [] "a quick success clears the record"

    probe run $p '^false'
    assert equal (probe status $p | get state) [error]

    # Enter after an open brace continues the command on a new line.
    probe run $p 'if true {' --no-wait
    probe run $p 'sleep 2sec }' --no-wait
    let multi = (wait for {|| probe status $p | where state == working | get -o 0 })
    assert equal ($multi.msg | str replace -ar ' +' ' ') 'if true { sleep 2sec }'
    probe wait $p

    probe run $p '^sleep 10' --no-wait
    wait for {|| probe status $p | where state == working | is-not-empty }
    probe key $p ctrl+c
    probe wait $p
    let idle = (probe status $p)
    assert equal ($idle | get state) [idle]
    assert str contains $idle.0.msg 'exit -2'
}

def "test status in a nested nu" [] {
    let p = (probe start 'nurx enable status')
    probe run $p $"^$nu.current-exe -n --no-history -e 'use ($MODULE) *; nurx enable status'"
    probe run $p ''
    probe run $p '^false'
    assert not (probe screen $p | str contains 'Error:') "the inner nu's hooks failed"
    assert equal (probe status $p | get state) [error]
    probe run $p 'exit'
}

def "test status send" [] {
    let p = (probe start)
    probe run $p 'nurx status send error --msg "line one\nline two"'
    let got = (probe status $p)
    assert equal ($got | get state) [error]
    assert equal $got.0.msg 'line one line two'
}

def "test layout" [] {
    let proj = ($env.NURX_TEST_DIR | path join proj)
    let file = ($proj | path join .nurx layout.nuon)
    mkdir ($file | path dirname)
    let label = $"nurx-test-(random chars --length 6)"
    {
        label: $label
        layout: {right: ["print left-pane-ran", {below: [{run: "print top-ran", label: top}, {label: shell}]}], ratio: 0.6}
    } | to nuon | save -f $file
    let setup = "nurx enable layout\n$env.NURX_LAYOUT_COMMAND = [$nu.current-exe -n --no-history]"
    let p = (probe start $setup --vars {TEST_PROJ: $proj})
    let hint = 'run `nurx layout allow` to trust it'

    probe run $p 'cd $env.TEST_PROJ'
    assert str contains (probe screen $p) $hint
    assert equal (nurx panes -s $p.s | get tab | uniq | length) 1 "an untrusted layout opens nothing"

    probe run $p 'nurx layout allow'
    assert ($env.NURX_TEST_DIR | path join data nushell nurx layouts-allowed.nuon | path exists)
    probe run $p 'cd ..'
    probe run $p 'cd $env.TEST_PROJ'
    assert str contains (probe screen $p) $"opened the ($label) tab"
    let panes = (nurx panes -s $p.s | where tab == $label)
    assert equal ($panes | get pane) ['print left-pane-ran' top shell]
    let left = ($panes | where pane == 'print left-pane-ran' | get 0.block_id)
    wait for {|| probe screen $p $left | lines | any {|l| $l == 'left-pane-ran' } }

    probe run $p 'cd ..'
    probe run $p 'cd $env.TEST_PROJ'
    assert equal (nurx panes -s $p.s | where tab == $label | length) 3 "entering again opens no second tab"

    "\n# edited\n" | save --append $file
    probe run $p 'cd ..'
    probe run $p 'cd $env.TEST_PROJ'
    assert equal (probe screen $p | split row $hint | length) 3 "an edited layout is untrusted again"
}

def "test tint" [] {
    let prod = ($env.NURX_TEST_DIR | path join prod)
    mkdir $prod
    let p = (probe start 'nurx enable tint' --vars {TEST_PROD: $prod})
    let query = 'term query "\e]11;?\e\\" --prefix "\e]11;" --terminator "\e\\"'
    probe run $p 'cd $env.TEST_PROD'
    assert equal (probe eval $p $"($query) | decode") 'rgb:3a3a/0000/0000'
    probe run $p 'cd ..'
    # Rex answers the query only while a program-set background is in place, so after the reset
    # the query waits until ctrl+c.
    probe run $p $query --no-wait
    sleep 1.5sec
    let last = (probe screen $p | lines | where $it != "" | last)
    assert not ($last | str ends-with ">") "the background should be reset"
    probe key $p ctrl+c
    probe wait $p
}

def "test panes status events" [] {
    let p = (probe start 'nurx enable status')
    probe run $p '^false'
    assert equal (nurx panes -s $p.s | get block_id) [$p.b]
    let status = (nurx status -s $p.s)
    assert equal ($status | get state) [error]
    assert equal $status.0.block_id $p.b
    let details = (nurx panes -s $p.s --details | get 0)
    assert equal ($details.status | get state) [error]
    assert str contains (probe screen $p) '^false'
    assert equal $details.pwd (probe eval $p '$env.PWD')

    let job = (job spawn { nurx events -s $p.s | where type == terminal.pwd_changed | first | job send 0 })
    sleep 1sec
    probe run $p 'cd /'
    let event = (try { job recv --timeout 10sec } catch {|e| job kill $job; error make {msg: "no pwd_changed event"} })
    assert equal [$event.session_id $event.block_id] [$p.s $p.b]
}

def "test nurx on" [] {
    let got = (nurx on [local] {|| 1 + 1 })
    assert equal [$got.0.exit_code $got.0.result] [0 2]
    let doubled = (nurx on [local] {|a| 1..$a.n | each {|i| $i * 2 } } --with {n: 3})
    assert equal $doubled.0.result [2 4 6]
    let failed = (nurx on [local] {|| error make {msg: 'remote boom'} })
    assert equal $failed.0.exit_code 1
    assert str contains $failed.0.error 'remote boom'
    let left = (^rex ls --json | from json | get sessions | where label == nurx-on)
    assert equal $left [] "nurx on kills its sessions"
}

# Runner -----------------------------------------------------------------------------------------

def main [filter: string = ""] {
    if (which rex | is-empty) { error make {msg: "the rex CLI isn't on PATH"} }
    $env.NURX_TEST_DIR = (mktemp -d -t nurx-test.XXXXXX)
    let tests = [
        [name code];
        [isolation {|| test isolation }]
        ["enable checks its arguments" {|| test enable checks its arguments }]
        ["no command hides a rex subcommand" {|| test no command hides a rex subcommand }]
        ["version matches the changelog" {|| test version matches the changelog }]
        ["picker checks its input" {|| test picker checks its input }]
        ["nurx alone shows its help" {|| test nurx alone shows its help and subcommands }]
        ["picker asks rex" {|| test picker asks rex }]
        ["picker needs nurx.lua" {|| test picker needs nurx.lua }]
        ["keeps your hooks" {|| test keeps your hooks }]
        ["last keeps your display hook" {|| test last keeps your display hook }]
        ["last opens explore" {|| test last opens explore }]
        [status {|| test status }]
        ["status in a nested nu" {|| test status in a nested nu }]
        ["status send" {|| test status send }]
        [layout {|| test layout }]
        [tint {|| test tint }]
        ["panes status events" {|| test panes status events }]
        ["nurx on" {|| test nurx on }]
    ]
    let results = ($tests | where ($it.name | str contains $filter) | each {|t|
        let start = (date now)
        let error = (try { do $t.code; null } catch {|e| $e.rendered? | default $e.msg })
        cleanup
        let took = ((date now) - $start | format duration sec)
        print $"(if $error == null { 'PASS' } else { 'FAIL' }) ($t.name) \(($took)\)"
        if $error != null { print $error }
        {name: $t.name, ok: ($error == null)}
    })
    let failed = ($results | where not ok)
    if ($failed | is-empty) {
        rm --recursive $env.NURX_TEST_DIR
        print $"\n($results | length) tests passed."
    } else {
        print $"\n($results | length) tests, ($failed | length) failed. Test files: ($env.NURX_TEST_DIR)"
        exit 1
    }
}
