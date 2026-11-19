-- Logs every command the dino 68000 writes to the QSound board's shared RAM and every
-- register the sound Z80 writes to the QSound DSP, with the time of each.
-- env: TRACE_OUT, TRACE_FRAMES, LEVEL (stage 0-7), TRACE_INPUT=none to stay in attract mode,
--      DUMP_Z80=1 to write the Z80's decrypted opcodes and data (z80_opcodes.bin, z80_data.bin)
-- out: sound_log.csv (seconds, kind, address or register, value)
--      kind: c = 68000 write to shared RAM (offset from 0xF18000), q = QSound register write
local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "7200")
local level = tonumber(os.getenv("LEVEL") or "")
local play = os.getenv("TRACE_INPUT") ~= "none"
local main = manager.machine.devices[":maincpu"].spaces["program"]
local z80 = manager.machine.devices[":audiocpu"]
local snd = z80.spaces["program"]

local log = io.open(out_dir .. "/sound_log.csv", "w")
local function now() return manager.machine.time:as_double() end
local data = 0
taps = {}
taps[#taps + 1] = snd:install_write_tap(0xd000, 0xd002, "dsp", function(offset, value)
  if offset == 0xd000 then data = (data & 0x00ff) | (value << 8)
  elseif offset == 0xd001 then data = (data & 0xff00) | value
  else log:write(string.format("%.6f,q,%02x,%04x\n", now(), value, data)) end
end)
taps[#taps + 1] = main:install_write_tap(0xf18000, 0xf19fff, "cmd", function(offset, value, mask)
  if mask & 0xff ~= 0 then log:write(string.format("%.6f,c,%04x,%02x\n", now(), (offset - 0xf18000) // 2, value & 0xff)) end
end)

local function field(name)
  for _, p in pairs(manager.machine.ioport.ports) do
    if p.fields[name] then return p.fields[name] end
  end
end
local inputs = {}
for k, n in pairs({ coin = "Coin 1", start = "1 Player Start", right = "P1 Right", left = "P1 Left", up = "P1 Up", down = "P1 Down", attack = "P1 Button 1", jump = "P1 Button 2" }) do
  inputs[k] = field(n)
end
local function press(k, on)
  if inputs[k] then inputs[k]:set_value(on and 1 or 0) end
end

local frame, began = 0, nil
sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if play and not began then
    local cyc = frame % 120
    press("coin", cyc < 6)
    press("start", cyc >= 60 and cyc < 66)
    press("attack", cyc >= 90 and cyc < 96)
    if level then main:write_u8(0xff84d9, level) end
    if main:read_u8(0xff84cc) == 1 and main:read_u8(0xff84d0) == 12 then
      began = frame
      press("coin", false)
      press("start", false)
      log:write(string.format("%.6f,p,0000,0000\n", now()))
    end
  elseif play then
    main:write_u16(0xffb2e0, 100)
    local t = frame - began
    local cyc = t % 300
    press("right", cyc < 200)
    press("left", cyc >= 280)
    press("up", cyc >= 200 and cyc < 280 and t % 80 < 20)
    press("down", cyc >= 200 and cyc < 280 and t % 80 >= 40 and t % 80 < 55)
    press("attack", t % 12 < 4)
    press("jump", cyc < 200 and t % 140 >= 70 and t % 140 < 76)
  end
  if frame >= max_frames then
    log:close()
    if os.getenv("DUMP_Z80") == "1" then
      local f = io.open(out_dir .. "/z80_opcodes.bin", "wb")
      f:write(z80.spaces["opcodes"]:read_range(0, 0x7fff, 8))
      f:close()
      f = io.open(out_dir .. "/z80_data.bin", "wb")
      f:write(snd:read_range(0, 0xffff, 8))
      f:close()
    end
    manager.machine:exit()
  end
end)
