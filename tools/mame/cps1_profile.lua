-- Sampling profiler for a CPS-1 68000 program under MAME.
-- Samples the PC and a heuristic call stack many times per frame, for the frames
-- listed in PROFILE_FRAMES (one frame number per line; all frames if unset).
-- env: TRACE_OUT, TRACE_FRAMES, PROFILE_FRAMES, PROFILE_HZ (samples per second, default 12000),
--      TASK_PTR (address of the kernel's current-task pointer, hex; dino ff0158),
--      TASK_BASE (address of slot 0, hex; dino ff0052), ROM_SIZE (hex, default 180000)
--      IDLE (scheduler idle loop PC range, hex "lo-hi"), KERNEL (kernel call PC range),
--      SPIN_SLOT / SPIN (slot and PC range of a task that only polls and yields).
-- Also writes profile_frames.csv: per frame, samples taken and samples that were real work
-- (not the idle loop, and not the polling task or kernel calls made on its behalf).

local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "10800")
local hz = tonumber(os.getenv("PROFILE_HZ") or "12000")
local task_ptr = tonumber(os.getenv("TASK_PTR") or "0", 16)
local task_base = tonumber(os.getenv("TASK_BASE") or "0", 16)
local rom_size = tonumber(os.getenv("ROM_SIZE") or "180000", 16)

local function range(name)
  local v = os.getenv(name)
  if not v then return 1, 0 end
  local lo, hi = v:match("(%x+)-(%x+)")
  return tonumber(lo, 16), tonumber(hi, 16)
end
local idle_lo, idle_hi = range("IDLE")
local kern_lo, kern_hi = range("KERNEL")
local spin_lo, spin_hi = range("SPIN")
local spin_slot = tonumber(os.getenv("SPIN_SLOT") or "-1")
local focus_slot = tonumber(os.getenv("FOCUS_SLOT") or "-1")
local focus = {}
local f_samples, f_work = 0, 0
local frames_csv = io.open(out_dir .. "/profile_frames.csv", "w")
frames_csv:write("frame,samples,work\n")

local cpu = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]
local want = nil
if os.getenv("PROFILE_FRAMES") then
  want = {}
  for line in io.lines(os.getenv("PROFILE_FRAMES")) do want[tonumber(line)] = true end
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

local frame = 0
local done = false
sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  frames_csv:write(frame, ",", f_samples, ",", f_work, "\n")
  f_samples, f_work = 0, 0
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
  if frame >= max_frames then done = true end
end)

local leaf, incl, tasks, modes = {}, {}, {}, { user = 0, super = 0 }
local samples = 0

local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function callee(ret)
  if ret & 1 ~= 0 or ret < 0x400 or ret >= rom_size then return nil end
  if prog:read_u16(ret - 6) == 0x4eb9 then
    local t = prog:read_u32(ret - 4)
    if t < rom_size then return t end
  end
  local w4 = prog:read_u16(ret - 4)
  if w4 == 0x4eba or w4 == 0x6100 then return (ret - 2 + s16(prog:read_u16(ret - 2))) & 0xffffff end
  if w4 >= 0x4ea8 and w4 <= 0x4eaf then return -(ret - 4) end
  local w2 = prog:read_u16(ret - 2)
  if (w2 & 0xff00) == 0x6100 and (w2 & 0xff) ~= 0 and (w2 & 0xff) ~= 0xff then
    local d = w2 & 0xff
    if d >= 0x80 then d = d - 0x100 end
    return ret + d
  end
  if w2 >= 0x4e90 and w2 <= 0x4e97 then return -(ret - 2) end
  return nil
end

local function sample()
  local pc = cpu.state["PC"].value & 0xffffff
  local sr = cpu.state["SR"].value
  local slot = -1
  if task_ptr ~= 0 then slot = ((prog:read_u32(task_ptr) & 0xffffff) - task_base) // 16 end
  f_samples = f_samples + 1
  local overhead = (pc >= idle_lo and pc < idle_hi)
    or (slot == spin_slot and ((pc >= kern_lo and pc < kern_hi) or (pc >= spin_lo and pc < spin_hi)))
  if not overhead then f_work = f_work + 1 end
  if want and not want[frame + 1] then return end
  samples = samples + 1
  leaf[pc] = (leaf[pc] or 0) + 1
  if slot == focus_slot and sr & 0x2000 == 0 then focus[pc] = (focus[pc] or 0) + 1 end
  if sr & 0x2000 ~= 0 then modes.super = modes.super + 1 else modes.user = modes.user + 1 end
  if task_ptr ~= 0 then
    local key = (sr & 0x2000 ~= 0) and ("super:" .. slot) or ("task:" .. slot)
    tasks[key] = (tasks[key] or 0) + 1
  end
  local sp = ((sr & 0x2000 ~= 0) and cpu.state["SP"].value or cpu.state["USP"].value) & 0xffffff
  if sp < 0xff0000 then return end
  local seen = {}
  for i = 0, 47 do
    local a = sp + i * 2
    if a > 0xfffffc then break end
    local v = prog:read_u32(a)
    if v >= 0x400 and v < rom_size and v & 1 == 0 then
      local t = callee(v)
      if t and not seen[t] then
        seen[t] = true
        incl[t] = (incl[t] or 0) + 1
      end
    end
  end
end

local function dump(name, t)
  local f = io.open(out_dir .. "/" .. name, "w")
  for k, v in pairs(t) do f:write(tostring(k), ",", v, "\n") end
  f:close()
end

local step = 1 / hz
while not done do
  emu.wait(step)
  local ok, e = pcall(sample)
  if not ok then print("profile error: " .. tostring(e)) break end
end
frames_csv:close()
dump("profile_leaf.csv", leaf)
if focus_slot >= 0 then dump("profile_slot.csv", focus) end
dump("profile_incl.csv", incl)
dump("profile_tasks.csv", tasks)
dump("profile_modes.csv", { samples = samples, user = modes.user, super = modes.super, frames = frame })
manager.machine:exit()
