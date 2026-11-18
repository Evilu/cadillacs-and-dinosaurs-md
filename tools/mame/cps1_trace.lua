-- CPS-1 video trace for MAME's cps1 driver.
-- Reads the sprite list, the three tilemaps and the palettes from GFX RAM every
-- frame and logs what the Mega Drive would have to reproduce to cps1_frames.csv.
-- env: TRACE_OUT, TRACE_FRAMES, TRACE_SNAP_EVERY,
--      LAYER_CTRL (CPS-B layer control offset, hex), LAYER_MASKS ("02,04,08"),
--      VRAM_PATTERNS (cache size used for the streaming estimate, default 1400)

local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "18000")
local snap_every = tonumber(os.getenv("TRACE_SNAP_EVERY") or "0")
local layer_ctrl = tonumber(os.getenv("LAYER_CTRL") or "2e", 16)
local masks = {}
for m in string.gmatch(os.getenv("LAYER_MASKS") or "02,04,08", "[^,]+") do masks[#masks + 1] = tonumber(m, 16) end
local cache_cap = tonumber(os.getenv("VRAM_PATTERNS") or "1400")
-- IDLE_FLAG: address of the frame flag the scheduler loop polls once per task slot
-- (ffight ff1100, dino ff0152). Reads per frame measure time spent in the scheduler.
local idle_flag = tonumber(os.getenv("IDLE_FLAG") or "0", 16)
local idle_reads = 0

local mem = manager.machine.memory.shares
local gfx = mem[":gfxram"]
local cpsa = mem[":cps_a_regs"]
local cpsb = mem[":cps_b_regs"]
local cpu = manager.machine.devices[":maincpu"]
local rom = manager.machine.memory.regions[":gfx"]
local rom_size = rom.size

local function blank_rows(off, rows, stride, width)
  for r = 0, rows - 1 do
    for b = 0, width - 1 do
      local o = off + r * stride + b
      if o >= rom_size or rom:read_u8(o) ~= 0xff then return false end
    end
  end
  return true
end

-- patterns: number of non-blank 8x8 cells in a tile
local pat_memo = {}
local function patterns(kind, code, half)
  local key = kind .. ":" .. code .. ":" .. (half or 0)
  local v = pat_memo[key]
  if v then return v end
  v = 0
  if kind == 1 then
    local base = (code * 64) % rom_size + (half or 0) * 4
    v = blank_rows(base, 8, 8, 4) and 0 or 1
  elseif kind == 2 then
    local base = (code * 128) % rom_size
    for q = 0, 3 do
      local qx, qy = q % 2, q // 2
      if not blank_rows(base + qy * 64 + qx * 4, 8, 8, 4) then v = v + 1 end
    end
  else
    local base = (code * 512) % rom_size
    for q = 0, 15 do
      local qx, qy = q % 4, q // 4
      if not blank_rows(base + qy * 128 + qx * 4, 8, 16, 4) then v = v + 1 end
    end
  end
  pat_memo[key] = v
  return v
end

local function a(r) return cpsa:read_u16(r * 2) end
local function g(off) return gfx:read_u16(off & 0x3fffe) end
local function base(v) return (v * 256 - 0x900000) & 0x3ffff end

local cache, cache_size = {}, 0
local function touch(key, cost, frame, stats)
  local e = cache[key]
  if e then
    e.t = frame
  else
    cache[key] = { t = frame, c = cost }
    cache_size = cache_size + cost
    stats.miss = stats.miss + cost
  end
end
local function evict(frame)
  if cache_size <= cache_cap then return 0 end
  local list = {}
  for k, e in pairs(cache) do
    if e.t < frame then list[#list + 1] = { k = k, t = e.t, c = e.c } end
  end
  table.sort(list, function(x, y) return x.t < y.t end)
  local i = 1
  while cache_size > cache_cap and i <= #list do
    cache[list[i].k] = nil
    cache_size = cache_size - list[i].c
    i = i + 1
  end
  return cache_size
end

local prev_visible = {}

local function frame_stats(frame)
  local st = { miss = 0 }
  local visible = {}
  local colours, pal_used = {}, {}
  local pal_base = base(a(5))

  local function use_pal(page, pal)
    local k = page * 32 + pal
    if pal_used[k] then return end
    pal_used[k] = true
    for pen = 0, 14 do colours[g(pal_base + page * 0x400 + pal * 32 + pen * 2) & 0x0fff] = true end
  end

  local ob = base(a(0))
  local entries, tiles, md_sprites = 0, 0, 0
  local line_tiles = {}
  local codes, ncodes = {}, 0
  local hash = 0
  for i = 0, 255 do
    local e = ob + i * 8
    local attr = g(e + 6)
    if (attr & 0xff00) == 0xff00 then break end
    local x, y, code = g(e) & 0x1ff, g(e + 2) & 0x1ff, g(e + 4)
    hash = (hash * 31 + x * 7 + y * 13 + code + attr) % 1000000007
    local nx, ny = ((attr >> 8) & 15) + 1, ((attr >> 12) & 15) + 1
    local any = false
    local blocks = {}
    for row = 0, ny - 1 do
      for col = 0, nx - 1 do
        local sx = (x + col * 16) & 0x1ff
        local sy = (y + row * 16) & 0x1ff
        local t = (code & ~0xf) + ((code + col) & 0xf) + 0x10 * row
        local np = patterns(2, t)
        if np > 0 and sx > 48 and sx < 448 and sy > 0 and sy < 240 then
          any = true
          tiles = tiles + 1
          local key = "o" .. t
          if not codes[key] then codes[key] = true ncodes = ncodes + 1 end
          visible[key] = np
          blocks[(col // 2) .. ":" .. (row // 2)] = true
          for l = math.max(sy, 16), math.min(sy + 15, 239) do line_tiles[l] = (line_tiles[l] or 0) + 1 end
        end
      end
    end
    if any then
      entries = entries + 1
      for _ in pairs(blocks) do md_sprites = md_sprites + 1 end
      use_pal(0, attr & 0x1f)
    end
  end
  local line_max, over20 = 0, 0
  for l = 16, 239 do
    local n = line_tiles[l] or 0
    if n > line_max then line_max = n end
    if n * 16 > 320 then over20 = over20 + 1 end
  end

  local ctrl = cpsb:read_u16(layer_ctrl)
  local lay = {}
  local sizes = { 8, 16, 32 }
  for L = 1, 3 do
    local r = { cells = 0, uniq = 0, pals = 0, prio = 0, on = (ctrl & masks[L]) ~= 0 and 1 or 0 }
    if r.on == 1 then
      local ts = sizes[L]
      local lb = base(a(L))
      local sx, sy = a(4 + L * 2), a(5 + L * 2)
      local c0, r0 = ((sx + 64) // ts), ((sy + 16) // ts)
      local seen, pals = {}, {}
      for rr = 0, 224 // ts do
        for cc = 0, 384 // ts do
          local col, row = (c0 + cc) & 63, (r0 + rr) & 63
          local idx
          if L == 1 then idx = (row & 0x1f) + (col << 5) + ((row & 0x20) << 6)
          elseif L == 2 then idx = (row & 0x0f) + (col << 4) + ((row & 0x30) << 6)
          else idx = (row & 0x07) + (col << 3) + ((row & 0x38) << 6) end
          local code, at = g(lb + idx * 4), g(lb + idx * 4 + 2)
          local half = L == 1 and ((idx >> 5) & 1) or nil
          local np = patterns(L == 1 and 1 or (L == 2 and 2 or 3), code, half)
          if np > 0 then
            r.cells = r.cells + 1
            local key = "s" .. L .. ":" .. code .. ":" .. (half or 0)
            if not seen[key] then seen[key] = true r.uniq = r.uniq + 1 end
            visible[key] = np
            if not pals[at & 0x1f] then pals[at & 0x1f] = true r.pals = r.pals + 1 use_pal(L, at & 0x1f) end
            if L > 1 and (at & 0x180) ~= 0 then r.prio = r.prio + 1 end
          end
        end
      end
    end
    lay[L] = r
  end

  local delta, ws = 0, 0
  for k, c in pairs(visible) do
    ws = ws + c
    touch(k, c, frame, st)
    if not prev_visible[k] then delta = delta + c end
  end
  prev_visible = visible
  evict(frame)

  local ncol, npal = 0, 0
  for _ in pairs(colours) do ncol = ncol + 1 end
  for _ in pairs(pal_used) do npal = npal + 1 end
  return string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%x",
    entries, tiles, ncodes, md_sprites, line_max, over20,
    lay[1].on, lay[1].uniq, lay[1].pals,
    lay[2].on, lay[2].uniq, lay[2].pals, lay[2].prio,
    lay[3].on, lay[3].uniq, lay[3].pals, lay[3].prio,
    npal, ncol, ws, delta, st.miss, cache_size, hash, ctrl, cpu.state["PC"].value)
end

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

local csv = io.open(out_dir .. "/cps1_frames.csv", "w")
csv:write("frame,obj_entries,obj_tiles,obj_unique,md_sprites_est,obj_line_tiles_max,obj_lines_over_320px," ..
  "s1_on,s1_unique,s1_pals,s2_on,s2_unique,s2_pals,s2_prio_cells,s3_on,s3_unique,s3_pals,s3_prio_cells," ..
  "palettes,colours,working_set_patterns,new_patterns_vs_prev,lru_miss_patterns,lru_size,obj_hash,layer_ctrl,pc,idle_reads\n")
if idle_flag ~= 0 then
  idle_tap = cpu.spaces["program"]:install_read_tap(idle_flag & ~1, idle_flag | 1, "idle", function()
    idle_reads = idle_reads + 1
  end)
end

local frame = 0
local errs = 0
local function on_frame()
  frame = frame + 1
  csv:write(frame, ",", frame_stats(frame), ",", idle_reads, "\n")
  idle_reads = 0
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
  if snap_every > 0 and frame % snap_every == 0 then manager.machine.video:snapshot() end
  if frame >= max_frames then
    csv:close()
    manager.machine:exit()
  end
end
sub = emu.add_machine_frame_notifier(function()
  local ok, e = pcall(on_frame)
  if not ok and errs < 5 then errs = errs + 1 print("trace error: " .. tostring(e)) end
end)
