-- lib/f.lua — helpers UI (barras en color)

local f = {}

-- Intenta cargar temas si existen; si no, usa defaults
local THEMES = { minimalist = { bg = colors.black, fg = colors.white, accent = colors.orange } }
do
  local ok, t = pcall(dofile, "themes.lua")
  if ok and type(t) == "table" then THEMES = t end
end

-- Busca tema o usa default
local function getTheme(name)
  return (name and THEMES[name]) or THEMES.minimalist
end

-- Limpia pantalla con colores de tema
function f.clear(mon, themeName)
  mon = mon or term
  local t = getTheme(themeName)
  mon.setBackgroundColor(t.bg or colors.black)
  mon.setTextColor(t.fg or colors.white)
  mon.clear()
  mon.setCursorPos(1,1)
end

-- Centrar texto
function f.center(mon, y, text, themeName)
  mon = mon or term
  local w = mon.getSize()
  local t = getTheme(themeName)
  mon.setTextColor(t.fg or colors.white)
  mon.setCursorPos(math.floor((w - #tostring(text))/2)+1, y)
  mon.write(tostring(text))
end

-- Barra horizontal de color usando espacios (no símbolos raros)
-- colorFill/bg opcionales; si no se dan, usa el tema.
function f.hbar(mon, x, y, w, h, value, max, colorFill, colorBg, themeName)
  mon = mon or term
  local t = getTheme(themeName)
  local fill = math.floor(math.min(1, math.max(0, (value or 0)/(max or 1))) * w)
  local oldBg = t.bg or colors.black

  local fillCol = colorFill or t.accent or colors.orange
  local bgCol   = colorBg   or t.bg     or colors.black

  for row = 0, (h or 1)-1 do
    mon.setCursorPos(x, y + row)
    mon.setBackgroundColor(fillCol)
    if fill > 0 then mon.write(string.rep(" ", fill)) end
    if fill < w then
      mon.setBackgroundColor(bgCol)
      mon.write(string.rep(" ", w - fill))
    end
  end
  mon.setBackgroundColor(oldBg)
end

-- Botón rectangular simple
function f.button(mon, x1, y1, x2, y2, label, themeName)
  mon = mon or term
  local t = getTheme(themeName)
  mon.setBackgroundColor(t.bg)
  mon.setTextColor(t.fg)
  -- fondo del botón
  mon.setBackgroundColor(t.accent or colors.orange)
  for y = y1, y2 do
    mon.setCursorPos(x1, y)
    mon.write(string.rep(" ", x2 - x1 + 1))
  end
  -- etiqueta centrada
  local cx = x1 + math.floor((x2 - x1 - #label)/2)
  local cy = y1 + math.floor((y2 - y1)/2)
  mon.setTextColor(t.fg or colors.white)
  mon.setCursorPos(math.max(x1, cx), math.max(y1, cy))
  mon.write(label)
  mon.setBackgroundColor(t.bg)
end

return f
