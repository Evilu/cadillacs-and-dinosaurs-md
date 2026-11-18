-- Sampling profiler for the Mega Drive build under MAME's genesis driver.
-- Samples the PC about PROFILE_HZ times a second and buckets it by hardware-layer symbol
-- (SYMS: csv of "hexaddr,name" sorted by address) or "game" for Capcom's program.
-- Also counts sprite lists the game finishes (flag word 0xFFE9B4 flipping) per 60 frames.
-- env: TRACE_OUT, TRACE_FRAMES, PROFILE_HZ (default 9600), SYMS, PRESS_FROM (frame the scripted
--      play starts, default 700), PROFILE_FROM / PROFILE_TO (frame range sampled), PROFILE_GRAN (mask for game PCs)

local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "7200")
local hz = tonumber(os.getenv("PROFILE_HZ") or "9600")
local from = tonumber(os.getenv("PROFILE_FROM") or "0")
local to = tonumber(os.getenv("PROFILE_TO") or "1000000")
local gran = tonumber(os.getenv("PROFILE_GRAN") or "0xfffe0")
local start_at = tonumber(os.getenv("PRESS_FROM") or "700")

local syms = {}
if os.getenv("SYMS") then
  for line in io.lines(os.getenv("SYMS")) do
    local a, n = line:match("(%x+),(.+)")
    if a then syms[#syms + 1] = { tonumber(a, 16), n } end
  end
end

local cpu = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]
local pad = manager.machine.ioport.ports[":ctrl1:mdpad:PAD"]
local function press(n, on) if pad.fields[n] then pad.fields[n]:set_value(on and 1 or 0) end end

local function bucket(pc)
  if pc < 0x180000 then return string.format("game %05x", pc & gran) end
  local lo, hi = 1, #syms
  local best = "hal?"
  while lo <= hi do
    local mid = (lo + hi) // 2
    if syms[mid][1] <= pc then best = syms[mid][2] lo = mid + 1 else hi = mid - 1 end
  end
  return best
end

local counts, total = {}, 0
local frame, done = 0, false
local last_flag, flips, window = nil, 0, {}
local w_idle, w_hal, w_all = 0, 0, 0
local last_conv, convs, entries = nil, 0, 0
sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local t = frame - start_at
  if frame == start_at then press("P1 A", true) elseif frame == start_at + 8 then press("P1 A", false) end
  if frame == start_at + 100 then press("P1 Start", true) elseif frame == start_at + 108 then press("P1 Start", false) end
  if t > 400 then
    local cyc = (t - 400) % 300
    local walk, fight = cyc < 150, cyc >= 150 and cyc < 270
    press("P1 Right", walk)
    press("P1 Left", cyc >= 270)
    press("P1 B", fight and frame % 12 < 3)
    press("P1 C", walk and frame % 140 == 70)
    press("P1 Up", fight and frame % 80 < 10)
    press("P1 Down", fight and frame % 80 >= 40 and frame % 80 < 50)
  end
  prog:write_u16(0xffb2e0, 100)
  local cc = prog:read_u16(0xff1310)
  if cc ~= last_conv then
    if last_conv ~= nil and frame >= from and frame <= to then
      convs = convs + 1
      entries = entries + prog:read_u16(0xff12c4)
    end
    last_conv = cc
  end
  local flag = prog:read_u16(0xffe9b4)
  if last_flag ~= nil and flag ~= last_flag then flips = flips + 1 end
  last_flag = flag
  if frame % 60 == 0 then
    window[#window + 1] = string.format("%d:%d/%d/%d", flips, w_idle, w_hal, w_all)
    flips, w_idle, w_hal, w_all = 0, 0, 0, 0
  end
  if frame >= max_frames then done = true end
end)

local function sample()
  if frame < from or frame > to then return end
  local pc = cpu.state["PC"].value & 0xffffff
  w_all = w_all + 1
  if pc >= 0x83c and pc < 0x8a2 then w_idle = w_idle + 1 elseif pc >= 0x180000 then w_hal = w_hal + 1 end
  local b = bucket(pc)
  counts[b] = (counts[b] or 0) + 1
  total = total + 1
end

local step = 1 / hz
while not done do
  emu.wait(step)
  local ok, e = pcall(sample)
  if not ok then print("profile error: " .. tostring(e)) break end
end

local f = io.open(out_dir .. "/md_profile.txt", "w")
f:write("per 60 frames lists:idle/hal/samples ", table.concat(window, " "), "\n")
f:write("conversions ", convs, " sat entries ", entries, "\n")
local list = {}
for k, v in pairs(counts) do list[#list + 1] = { k, v } end
table.sort(list, function(a, b) return a[2] > b[2] end)
for _, e in ipairs(list) do f:write(string.format("%-24s %6d %5.1f%%\n", e[1], e[2], 100 * e[2] / total)) end
f:close()
manager.machine:exit()
