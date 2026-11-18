-- The Rex half of `nurx`, the picker in nurx.nu. Load it from your Rex init.lua:
--
--   dofile(os.getenv("HOME") .. "/src/nu-rex-integration/nurx.lua")
--
-- rex.ui.pick asks the Rex apps only from an action the server runs, not from a script that
-- `rex do` runs, so `nurx` sends its question here with `rex do nurx_pick --args -`.
-- It returns { ids = {...} } with the picked ids, or { reason = ..., detail = ... } when nothing
-- was picked.
rex.action{
  name        = "nurx_pick",
  title       = "nurx: Pick From a Nushell Value",
  description = "Used by nurx in nushell. Pipe a value into nurx to pick from it.",
  category    = "nushell",
  args        = { title = "string", items = "array", multiple = "boolean?" },
  run         = function(ctx, args)
    if rex.ui == nil then return { reason = "no_ui" } end
    local answer, why, detail = rex.ui.pick{
      title    = args.title,
      items    = args.items,
      multiple = args.multiple,
    }
    if answer == nil then return { reason = why, detail = detail } end
    if type(answer) == "string" then answer = { answer } end
    return { ids = answer }
  end,
}
