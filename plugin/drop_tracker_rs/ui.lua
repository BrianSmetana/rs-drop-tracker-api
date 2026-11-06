-- Friendly output for Drop Tracker. Uses the PrettyUI plugin (optional dependency) for a window;
-- without it, falls back to a short chat line. M.format is pure so it can be tested without the client.

local M = {}

local MAX_BOSSES = 6
local GOLD, GREY = "<col=f2c66d>", "<col=b8b8b8>"

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

--- state = { http = bool, pending = n, bosses = { {name, kc, kills, drops = { {item, count}, ... }}, ... } }
--- (bosses ordered most recent first). Returns status_line, body_text.
function M.format(state)
  local status
  if not state.http then
    status = "<col=ff7f50>Not syncing: HTTP permission not granted</col>"
  elseif state.pending > 0 then
    status = "<col=ffd700>Syncing: " .. plural(state.pending, "event") .. " queued</col>"
  else
    status = "<col=7fff7f>All synced</col>"
  end

  if #state.bosses == 0 then
    return status, GREY .. "No tracked kills yet. Kill a tracked boss to get started.</col>"
  end

  local lines = {}
  for i = 1, math.min(#state.bosses, MAX_BOSSES) do
    local b = state.bosses[i]
    lines[#lines + 1] = GOLD .. b.name .. "</col>"
    lines[#lines + 1] = "  Kill count " .. b.kc .. GREY .. "  (" .. b.kills .. " this session)</col>"
    if #b.drops == 0 then
      lines[#lines + 1] = GREY .. "  No tracked drops yet</col>"
    else
      for _, d in ipairs(b.drops) do
        lines[#lines + 1] = "  <col=7fff7f>" .. d.item .. "</col> x" .. d.count
      end
    end
  end
  return status, table.concat(lines, "<br>")
end

local LINE_HEIGHT = 18

--- Pixel height for a text box holding `text` (lines are separated by <br>).
function M.body_height(text)
  local _, breaks = text:gsub("<br>", "")
  return (breaks + 1) * LINE_HEIGHT + 8
end

--- Short one-line notices, used when there is no window.
function M.kill_line(boss, kc, kills) return "Drop Tracker: " .. boss .. " kill " .. kc .. " (" .. kills .. " this session)" end
function M.drop_line(boss, item) return "Drop Tracker: " .. item .. " from " .. boss .. "!" end

--- Radio-button groups for the enrage bosses. `strategies` is rates.strategies. Returns
--- { { name, default, choices = { {text, value}, ... } }, ... } ordered by boss name; each group ends with "off".
function M.strategy_groups(strategies)
  local names = {}
  for name in pairs(strategies or {}) do names[#names + 1] = name end
  table.sort(names)
  local groups = {}
  for _, name in ipairs(names) do
    local s = strategies[name]
    local choices = {}
    for _, o in ipairs(s.options) do choices[#choices + 1] = { text = o.label, value = o.id } end
    choices[#choices + 1] = { text = "Off (no enrage-based labels)", value = "off" }
    groups[#groups + 1] = { name = name, default = s.default, choices = choices }
  end
  return groups
end

--- Returns a presenter { update(state, show), notify(line) }.
--- `opts` (optional) = { strategies = rates.strategies, selected = { [group] = id }, on_change = function(group, id) }
--- adds a "how do you farm it" choice per enrage boss to the window.
function M.new(G, log, opts)
  opts = opts or {}
  local P = G.PrettyUI
  local presenter = {}

  local function chat(line)
    local ok = pcall(function()
      if G.Chat and G.Plugin.HasPermission(G.PluginPermissions.chatAccess) then G.Chat.AddMessage(line) end
    end)
    if not ok then log(line) end
  end

  if P and P.Window and G.ui and G.id then
    local made, win, status, body = pcall(function()
      local parent = G.ui.Interfaces:GetComponent(G.id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
      local w = P.Window.new(parent, { title = "Drop Tracker", x = 60, y = 120, width = 340, height = 480, resizable = true })
      -- Text boxes centre vertically by default, which floats short text in the middle of a tall box.
      local top = G.ui.AlignMode and G.ui.AlignMode.TOPLEFT or nil
      local s = w:AddText({ text = "", height = 24, alignVertical = top })
      -- Enrage bosses: their drop chances depend on enrage and killstreak, which the plugin cannot see, so the player
      -- says how they farm each one. A failure here must not cost the window its kill list.
      if opts.strategies and w.AddRadioButton then
        pcall(function()
          w:AddText({ text = GOLD .. "Enrage bosses</col><br>" .. GREY .. "How do you farm them? Collection log luck assumes every kill is made that way.</col>",
                      height = 40, alignVertical = top })
          for _, g in ipairs(M.strategy_groups(opts.strategies)) do
            w:AddText({ text = GOLD .. g.name .. "</col>", height = 20, alignVertical = top })
            local chosen = (opts.selected and opts.selected[g.name]) or g.default
            w:AddRadioButton(g.choices, { selectedValue = chosen, onChange = function(_, value)
              if opts.on_change then opts.on_change(g.name, value) end
            end })
          end
        end)
      end
      local b = w:AddText({ text = "", height = M.body_height(""), alignVertical = top })
      return w, s, b
    end)
    if made then
      presenter.window = win
      function presenter.update(state, show)
        local s, b = M.format(state)
        status.content, body.content = s, b
        pcall(function() body:SetSize(0, M.body_height(b), 1.0, 0) end) -- fit the box to the text
        if show then win:Show() end
      end
      function presenter.notify() end -- the window is the notification
      function presenter.destroy() pcall(function() win:Destroy() end) end
      return presenter
    end
    log("PrettyUI window failed: " .. tostring(win) .. " (falling back to chat)")
  end

  function presenter.update() end
  function presenter.destroy() end
  function presenter.notify(line) log(line) chat(line) end
  return presenter
end

return M
