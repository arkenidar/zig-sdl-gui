-- THE app logic. Edit this file while the app is running: it hot-reloads and the
-- window updates within a frame (state below is preserved across reloads).
--
-- The `ui` table is the widget-building API; `s` is your persistent state table.
-- Interactions are return values, not callbacks: `if ui.button(...) then ... end`.

function frame(ui, s)
  -- lazy state init (persists across hot-reloads because `s` survives)
  s.count = s.count or 0
  s.vol = s.vol or 0.5
  if s.dark == nil then
    s.dark = true
  end

  ui.label("zig-sdl - Lua app (edit scripts/app.lua live)")

  -- counter row: [ - ] [ count ] [ + ]
  ui.row { 48, -1, 48 }
  if ui.button("-") then
    s.count = s.count - 1
  end
  ui.label("count: " .. s.count)
  if ui.button("+") then
    s.count = s.count + 1
  end

  s.vol = ui.slider("volume", s.vol, 0, 1)
  s.dark = ui.checkbox("dark mode", s.dark)

  if ui.button("Reset count") then
    s.count = 0
  end
end
