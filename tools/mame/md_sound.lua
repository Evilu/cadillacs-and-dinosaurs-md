-- Makes the Mega Drive build play one sound command by itself. The hardware layer marks
-- the QSound shared RAM's stand-in (0xFF1200) ready at each VBlank; at the chosen frame
-- that write is turned into a packet handed over, as the game would leave it.
-- env: TRACE_FRAMES, SOUND_CMD (hex), SOUND_AT (frame, default 600: the attract mode is silent)
-- Run with -wavwrite to record it.
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "3600")
local cmd = tonumber(os.getenv("SOUND_CMD") or "02", 16)
local at = tonumber(os.getenv("SOUND_AT") or "600")
local frame, armed = 0, false
tap = prog:install_write_tap(0xff121e, 0xff121f, "flag", function(offset, data, mask)
  if armed and mask & 0xff ~= 0 then
    armed = false
    prog:write_u8(0xff1201, 0)
    prog:write_u8(0xff1203, cmd)
    return data & 0xff00
  end
end)
sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == at then armed = true end
  if frame >= max_frames then manager.machine:exit() end
end)
