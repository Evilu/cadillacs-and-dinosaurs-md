-- Scroll 1 (text layer) probe for MAME's cps1 driver, dino.
-- Per frame: scroll position, visible non-blank cells, cells changed since the last
-- frame, distinct 8x8 patterns, palettes and colours actually drawn (pens used).
-- Over the run: frames each screen cell (48 x 28) shows a pattern, and the palettes
-- and patterns seen. For the HUD band (screen rows 0 to BAND_ROWS - 1): distinct
-- pattern and palette pairs per frame, and every attribute word written there.
-- Plays the same script as cps1_trace.lua.
-- env: TRACE_OUT, TRACE_FRAMES, LAYER_CTRL (hex, dino 0a), S1_MASK (hex, dino 16),
--      GRID_EVERY (write the screen grid of codes every N frames, 0 = never)

local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "21600")
local layer_ctrl = tonumber(os.getenv("LAYER_CTRL") or "0a", 16)
local s1_mask = tonumber(os.getenv("S1_MASK") or "16", 16)
local grid_every = tonumber(os.getenv("GRID_EVERY") or "0")
local band_rows = tonumber(os.getenv("BAND_ROWS") or "5")
local band_attr = {}

local mem = manager.machine.memory.shares
local gfx = mem[":gfxram"]
local cpsa = mem[":cps_a_regs"]
local cpsb = mem[":cps_b_regs"]
local rom = manager.machine.memory.regions[":gfx"]
local rom_size = rom.size

local function a(r) return cpsa:read_u16(r * 2) end
local function g(off) return gfx:read_u16(off & 0x3fffe) end
local function base(v) return (v * 256 - 0x900000) & 0x3ffff end

local pen_memo = {}
local function pens(code, half)
  local key = code * 2 + half
  local v = pen_memo[key]
  if v then return v end
  v = 0
  for r = 0, 7 do
    local o = (code * 64 + r * 8 + half * 4) % rom_size
    local b0, b1, b2, b3 = rom:read_u8(o), rom:read_u8(o + 1), rom:read_u8(o + 2), rom:read_u8(o + 3)
    for x = 0, 7 do
      local m = 1 << x
      local p = ((b3 & m) ~= 0 and 8 or 0) | ((b2 & m) ~= 0 and 4 or 0) | ((b1 & m) ~= 0 and 2 or 0) | ((b0 & m) ~= 0 and 1 or 0)
      v = v | (1 << p)
    end
  end
  pen_memo[key] = v
  return v
end

local function md_colour(w)
  local bright = (w >> 12) & 15
  local function ch(n) return math.floor((n * 0x11 * (0x0f + 2 * bright) // 0x2d) * 7 / 255 + 0.5) end
  return ch((w >> 8) & 15) * 64 + ch((w >> 4) & 15) * 8 + ch(w & 15)
end

local cell_frames = {}
local cell_pal = {}
local pat_seen, pal_frames, code_min, code_max = {}, {}, 0xffff, 0
local pal_pens = {}
local prev = {}

local function field(name)
  for _, p in pairs(manager.machine.ioport.ports) do
    if p.fields[name] then return p.fields[name] end
  end
end
local inputs = {}
for _, n in ipairs({ "Coin 1", "1 Player Start", "P1 Right", "P1 Left", "P1 Up", "P1 Down", "P1 Button 1", "P1 Button 2" }) do
  inputs[n] = field(n)
end
local function press(n, on)
  if inputs[n] then inputs[n]:set_value(on and 1 or 0) end
end

local csv = io.open(out_dir .. "/s1_frames.csv", "w")
csv:write("frame,on,scroll_x,scroll_y,cells,cells_cropped,changed,patterns,palettes,pal_list,colours_arcade,colours_md,lowest_row,band_keys\n")
local grid = grid_every > 0 and io.open(out_dir .. "/s1_grids.txt", "w") or nil

local function frame_stats(frame)
  local on = (cpsb:read_u16(layer_ctrl) & s1_mask) ~= 0
  local sx, sy = a(6), a(7)
  if not on then return string.format("0,%d,%d,0,0,0,0,0,,0,0,-1,0", sx, sy) end
  local lb = base(a(1))
  local pal_base = base(a(5)) + 0x400
  local c0, r0 = (sx + 64) // 8, (sy + 16) // 8
  local cells, cropped, changed, lowest = 0, 0, 0, -1
  local pats, npats, pals, cols, mdcols = {}, 0, {}, {}, {}
  local now = {}
  local bkeys, nbkeys = {}, 0
  local lines = grid and (frame % grid_every == 0) and {} or nil
  for rr = 0, 27 do
    local line = lines and {} or nil
    for cc = 0, 47 do
      local col, row = (c0 + cc) & 63, (r0 + rr) & 63
      local idx = (row & 0x1f) + (col << 5) + ((row & 0x20) << 6)
      local code, at = g(lb + idx * 4), g(lb + idx * 4 + 2)
      local half = (idx >> 5) & 1
      local used = pens(code, half) & 0x7fff
      local k = rr * 48 + cc
      if rr < band_rows then band_attr[at] = (band_attr[at] or 0) + 1 end
      now[k] = code * 65536 + at
      if prev[k] ~= now[k] then changed = changed + 1 end
      if used ~= 0 then
        cells = cells + 1
        if cc < 4 or cc >= 44 then cropped = cropped + 1 end
        lowest = rr
        cell_frames[k] = (cell_frames[k] or 0) + 1
        local pal = at & 0x1f
        cell_pal[k] = cell_pal[k] or {}
        cell_pal[k][pal] = (cell_pal[k][pal] or 0) + 1
        local pk = code * 2 + half
        if rr < band_rows then
          local bk = pk * 32 + pal
          if not bkeys[bk] then bkeys[bk] = true nbkeys = nbkeys + 1 end
        end
        if not pats[pk] then pats[pk] = true npats = npats + 1 end
        pat_seen[pk] = true
        if code < code_min then code_min = code end
        if code > code_max then code_max = code end
        pals[pal] = (pals[pal] or 0) | used
        if line then line[#line + 1] = string.format("%03x", code & 0xfff) end
      elseif line then
        line[#line + 1] = " . "
      end
    end
    if line then lines[#lines + 1] = table.concat(line, "") end
  end
  prev = now
  local plist, npal = {}, 0
  for pal, used in pairs(pals) do
    npal = npal + 1
    plist[#plist + 1] = string.format("%02x", pal)
    pal_frames[pal] = (pal_frames[pal] or 0) + 1
    pal_pens[pal] = (pal_pens[pal] or 0) | used
    for p = 0, 14 do
      if used & (1 << p) ~= 0 then
        local w = g(pal_base + pal * 32 + p * 2)
        cols[w & 0xfff] = true
        mdcols[md_colour(w)] = true
      end
    end
  end
  table.sort(plist)
  local nc, nm = 0, 0
  for _ in pairs(cols) do nc = nc + 1 end
  for _ in pairs(mdcols) do nm = nm + 1 end
  if lines then
    grid:write(string.format("frame %d scroll %d,%d\n", frame, sx, sy))
    for _, l in ipairs(lines) do grid:write(l, "\n") end
  end
  return string.format("1,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d",
    sx, sy, cells, cropped, changed, npats, npal, table.concat(plist, " "), nc, nm, lowest, nbkeys)
end

local function finish()
  csv:close()
  if grid then grid:close() end
  local f = io.open(out_dir .. "/s1_cells.csv", "w")
  f:write("row,col,frames,main_palette\n")
  for k, n in pairs(cell_frames) do
    local best, bn = -1, -1
    for pal, c in pairs(cell_pal[k]) do if c > bn then best, bn = pal, c end end
    f:write(string.format("%d,%d,%d,%02x\n", k // 48, k % 48, n, best))
  end
  f:close()
  local s = io.open(out_dir .. "/s1_summary.txt", "w")
  local np = 0
  for _ in pairs(pat_seen) do np = np + 1 end
  s:write(string.format("patterns seen %d, codes %03x-%03x\n", np, code_min, code_max))
  for pal = 0, 31 do
    if pal_frames[pal] then
      local list = {}
      for p = 0, 14 do if pal_pens[pal] & (1 << p) ~= 0 then list[#list + 1] = p end end
      s:write(string.format("palette %02x: %d frames, pens %s\n", pal, pal_frames[pal], table.concat(list, " ")))
    end
  end
  local attrs = {}
  for at, n in pairs(band_attr) do attrs[#attrs + 1] = { at, n } end
  table.sort(attrs, function(x, y) return x[1] < y[1] end)
  for _, e in ipairs(attrs) do s:write(string.format("band attribute %04x: %d cell-frames\n", e[1], e[2])) end
  s:close()
end

local frame = 0
local errs = 0
local function on_frame()
  frame = frame + 1
  csv:write(frame, ",", frame_stats(frame), "\n")
  local t = frame % 1800
  press("Coin 1", t >= 60 and t < 66)
  press("1 Player Start", t >= 120 and t < 126)
  local cyc = frame % 300
  local walk = cyc < 150
  local fight = cyc >= 150 and cyc < 270
  local back = cyc >= 270
  press("P1 Right", walk)
  press("P1 Left", back)
  press("P1 Up", fight and frame % 80 < 10)
  press("P1 Down", fight and frame % 80 >= 40 and frame % 80 < 50)
  press("P1 Button 1", fight and frame % 12 < 3)
  press("P1 Button 2", walk and frame % 140 == 70)
  if frame >= max_frames then
    finish()
    manager.machine:exit()
  end
end
sub = emu.add_machine_frame_notifier(function()
  local ok, e = pcall(on_frame)
  if not ok and errs < 5 then errs = errs + 1 print("trace error: " .. tostring(e)) end
end)
