-- Prints the arcade program's kernel and shadow-register state while it runs as a
-- Mega Drive ROM. env: TRACE_FRAMES, STATE_EVERY, PRESS ("frame:button,..." e.g. "300:A,420:Start")
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local pad = manager.machine.ioport.ports[":ctrl1:mdpad:PAD"]
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "1800")
local every = tonumber(os.getenv("STATE_EVERY") or "300")
local presses = {}
for f, b in string.gmatch(os.getenv("PRESS") or "", "(%d+):(%a+)") do presses[tonumber(f)] = b end
local held, release = nil, 0
local frame = 0
sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if presses[frame] then
    held, release = "P1 " .. presses[frame], frame + 8
    pad.fields[held]:set_value(1)
  elseif held and frame >= release then
    pad.fields[held]:set_value(0)
    held = nil
  end
  if frame % every == 0 then
    local slots = {}
    for i = 0, 15 do slots[#slots + 1] = string.format("%02x", prog:read_u8(0xff0052 + i * 16)) end
    local regs = {}
    for _, o in ipairs({ 0x100, 0x102, 0x104, 0x106, 0x10a, 0x10c, 0x110, 0x114, 0x122, 0x14a }) do
      regs[#regs + 1] = string.format("%03x=%04x", o, prog:read_u16(0xff1000 + o))
    end
    print(string.format("frame %5d pc %06x vblanks %d  in-game %02x  player1 active %02x  stage %02x  p1 x %04x",
      frame, cpu.state["PC"].value, prog:read_u32(0xff12c0), prog:read_u8(0xff84cc), prog:read_u8(0xffb274),
      prog:read_u8(0xff84d9), prog:read_u16(0xffb27c)))
    print("   task slots: " .. table.concat(slots, " "))
    print("   registers:  " .. table.concat(regs, " "))
  end
  if frame >= max_frames then manager.machine:exit() end
end)
