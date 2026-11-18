-- Hardware access and work RAM usage map for a CPS-1 68000 program under MAME.
-- Records every instruction address that reads or writes arcade hardware
-- (I/O and CPS registers, GFX RAM, QSound/extra I/O) and every work RAM byte written.
-- env: TRACE_OUT, TRACE_FRAMES, BOOT_CLEAR (PC range of the reset RAM clear, hex "lo-hi", not counted),
--      RAM_FROM_FRAME (ignore RAM writes before this frame, to skip boot-time tests)
-- out: access_pcs.csv (pc, region, reads, writes, lowest address, highest address)
--      ram_written.bin (65536 bytes: 1 where the byte at 0xFF0000+i was written)

local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "10800")
local cpu = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]
local curpc = cpu.state["CURPC"]

local clear_lo, clear_hi = 1, 0
if os.getenv("BOOT_CLEAR") then
  local lo, hi = os.getenv("BOOT_CLEAR"):match("(%x+)-(%x+)")
  clear_lo, clear_hi = tonumber(lo, 16), tonumber(hi, 16)
end

local ram_from = tonumber(os.getenv("RAM_FROM_FRAME") or "0")
local frame = 0

local acc = {}
local function note(region, write)
  return function(offset, data, mask)
    local key = (curpc.value & 0xffffff) * 4 + region
    local e = acc[key]
    if not e then
      e = { 0, 0, offset, offset }
      acc[key] = e
    end
    if write then e[2] = e[2] + 1 else e[1] = e[1] + 1 end
    if offset < e[3] then e[3] = offset end
    if offset > e[4] then e[4] = offset end
  end
end
local regions = { { 0x800000, 0x8001ff }, { 0x900000, 0x92ffff }, { 0xf18000, 0xf1ffff } }
taps = {}
for i, r in ipairs(regions) do
  taps[#taps + 1] = prog:install_read_tap(r[1], r[2], "r" .. i, note(i - 1, false))
  taps[#taps + 1] = prog:install_write_tap(r[1], r[2], "w" .. i, note(i - 1, true))
end

local written = {}
taps[#taps + 1] = prog:install_write_tap(0xff0000, 0xffffff, "ram", function(offset, data, mask)
  if frame < ram_from then return end
  local pc = curpc.value & 0xffffff
  if pc >= clear_lo and pc < clear_hi then return end
  local a = offset & 0xfffe
  if mask & 0xff00 ~= 0 then written[a] = true end
  if mask & 0x00ff ~= 0 then written[a + 1] = true end
end)

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

sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local t = frame % 1800
  press("Coin 1", t >= 60 and t < 66)
  press("1 Player Start", t >= 120 and t < 126)
  local cyc = frame % 300
  local walk, fight, back = cyc < 150, cyc >= 150 and cyc < 270, cyc >= 270
  press("P1 Right", walk)
  press("P1 Left", back)
  press("P1 Up", fight and frame % 80 < 10)
  press("P1 Down", fight and frame % 80 >= 40 and frame % 80 < 50)
  press("P1 Button 1", fight and frame % 12 < 3)
  press("P1 Button 2", walk and frame % 140 == 70)
  if frame >= max_frames then
    local f = io.open(out_dir .. "/access_pcs.csv", "w")
    f:write("pc,region,reads,writes,low,high\n")
    for key, e in pairs(acc) do
      f:write(string.format("%06x,%d,%d,%d,%06x,%06x\n", key // 4, key % 4, e[1], e[2], e[3], e[4]))
    end
    f:close()
    local parts = {}
    for i = 0, 0xffff do parts[#parts + 1] = written[i] and "\1" or "\0" end
    local b = io.open(out_dir .. "/ram_written.bin", "wb")
    b:write(table.concat(parts))
    b:close()
    manager.machine:exit()
  end
end)
