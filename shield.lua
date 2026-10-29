-- shield v0.0.1 by loopmasta
-- check your shield's ins/outs
--
-- monitors audio, network,
-- usb, midi and controls
--
-- hold K2: test tone L, then R
-- hold K3: MIDI test notes out

engine.name = 'Shield'

local HOLD = 1.0        -- seconds to hold K2 / K3 for a test
local GLOW = 0.4        -- seconds an activity light takes to fade
local LOG_LINES = 3

-- the audio jacks, left to right as they sit on the shieldXL's rear edge
local JACKS = {
  {label = "L-I", poll = "amp_in_l"},
  {label = "R-I", poll = "amp_in_r"},
  {label = "L-O", poll = "amp_out_l"},
  {label = "R-O", poll = "amp_out_r"},
}

local net = nil         -- "LAN", "WLAN" or nil (no connection)
local pi4 = false       -- a Pi 4: Ethernet left of the USB ports (Pi 3: the other way round)
local level = {}        -- poll -> level 0..1 (smoothed)
local sounding = {}     -- poll -> true while there is a signal
local polls = {}
local lit = {}          -- name -> time of the last activity
local held = {}         -- key -> time it went down
local enc_count = {0, 0, 0}
local log = {}
local busy = nil        -- a running test's name
local redraw_metro

local function now() return util.time() end

local function light(name) lit[name] = now() end

-- an activity light as 0..1: 1 right after, fading to 0 over GLOW seconds
local function activity(name)
  local t = lit[name]
  if not t then return 0 end
  return math.max(0, 1 - (now() - t) / GLOW)
end

local function add_log(text)
  table.insert(log, 1, text)
  while #log > LOG_LINES do table.remove(log) end
end

-- network ---------------------------------------------------------------------

-- an interface is connected when the kernel reports it up
local function is_up(iface)
  local f = io.open("/sys/class/net/" .. iface .. "/operstate", "r")
  if not f then return false end
  local state = f:read("*l")
  f:close()
  return state == "up"
end

-- the Pi model, e.g. "Raspberry Pi 4 Model B Rev 1.5"
local function pi_model()
  local f = io.open("/proc/device-tree/model", "r")
  if not f then return "" end
  local m = f:read("*a") or ""
  f:close()
  return m:gsub("%z", "")
end

local function check_net()
  if is_up("eth0") then net = "LAN"
  elseif is_up("wlan0") then net = "WLAN"
  else net = nil end
end

-- MIDI ------------------------------------------------------------------------

local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local function note_name(n) return NOTE_NAMES[n % 12 + 1] .. (math.floor(n / 12) - 1) end

-- a short description of a MIDI message, e.g. "note C4 v100 ch1"
local function describe(m)
  local ch = m.ch and (" ch" .. m.ch) or ""
  if m.type == "note_on" then return "note " .. note_name(m.note) .. " v" .. m.vel .. ch
  elseif m.type == "note_off" then return "off " .. note_name(m.note) .. ch
  elseif m.type == "cc" then return "cc " .. m.cc .. " = " .. m.val .. ch
  elseif m.type == "program_change" then return "prog " .. m.val .. ch
  elseif m.type == "pitchbend" then return "bend " .. m.val .. ch
  elseif m.type == "clock" then return nil -- too many to log
  end
  return m.type
end

-- the shieldXL's TRS jacks: norns' "virtual" device; everything else is USB
local function is_trs(dev) return dev.name == "virtual" end

local function watch(dev)
  dev.event = function(data)
    local m = midi.to_msg(data)
    light(is_trs(dev) and "midi_in" or "usb")
    local d = describe(m)
    if d then add_log((is_trs(dev) and "in: " or "usb: ") .. d) end
  end
end

local function trs_device()
  for _, dev in pairs(midi.devices) do
    if is_trs(dev) then return dev end
  end
end

-- other USB devices: grid and arc (monome), keyboards and gamepads (HID). Their
-- events light up USB too (raw USB traffic isn't visible to a script)
local function watch_grid(g)
  g.key = function(x, y, z) light("usb"); add_log("grid: " .. x .. "," .. y .. " " .. z) end
end

local function watch_arc(a)
  a.delta = function(n, d) light("usb") end
  a.key = function(n, z) light("usb"); add_log("arc: key " .. n .. " " .. z) end
end

local function watch_hid(h)
  h.event = function(typ, code, val) light("usb") end
end

local function watch_usb()
  for _, g in pairs(grid.devices) do watch_grid(g) end
  for _, a in pairs(arc.devices) do watch_arc(a) end
  for _, h in pairs(hid.devices) do watch_hid(h) end
  grid.add = function(g) watch_grid(g); light("usb"); add_log("usb: " .. g.name) end
  arc.add = function(a) watch_arc(a); light("usb"); add_log("usb: " .. a.name) end
  hid.add = function(h) watch_hid(h); light("usb"); add_log("usb: " .. h.name) end
end

-- tests -----------------------------------------------------------------------

local function tone_test()
  busy = "tone"
  clock.run(function()
    add_log("tone: left")
    engine.tone(-1, 440, 0.6)
    clock.sleep(1)
    add_log("tone: right")
    engine.tone(1, 660, 0.6)
    clock.sleep(1)
    busy = nil
  end)
end

local function midi_test()
  local dev = trs_device()
  if not dev then add_log("no MIDI jacks found") return end
  busy = "midi"
  add_log("out: C E G C ch1")
  clock.run(function()
    for _, n in ipairs({60, 64, 67, 72}) do
      dev:send({0x90, n, 100})
      light("midi_out")
      clock.sleep(0.2)
      dev:send({0x80, n, 0})
      clock.sleep(0.05)
    end
    busy = nil
  end)
end

-- norns -----------------------------------------------------------------------

function init()
  for _, j in ipairs(JACKS) do
    level[j.poll] = 0
    local p = poll.set(j.poll, function(v)
      -- dB, -60..0, as 0..1; fast up, slower down
      local x = v > 0 and util.clamp((20 * math.log(v, 10) + 60) / 60, 0, 1) or 0
      level[j.poll] = math.max(x, level[j.poll] * 0.8)
      -- name the jack when a signal starts (about -40 dB), so you know which is which
      if level[j.poll] > 0.33 and not sounding[j.poll] then
        sounding[j.poll] = true
        add_log("signal: " .. j.label)
      elseif level[j.poll] < 0.2 then
        sounding[j.poll] = nil
      end
    end)
    p.time = 1 / 20
    p:start()
    polls[#polls + 1] = p
  end
  for _, dev in pairs(midi.devices) do watch(dev) end
  midi.add = function(dev) watch(dev); light(is_trs(dev) and "midi_in" or "usb"); add_log("midi: " .. dev.name) end
  watch_usb()
  add_log("hold K3: midi out")
  add_log("hold K2: tone L/R")
  pi4 = pi_model():find("Pi 4") ~= nil
  check_net()
  clock.run(function()
    while true do clock.sleep(2); check_net() end
  end)
  -- call redraw through a function: norns swaps the global redraw while it loads
  -- a script, so passing redraw itself would keep its blank stand-in
  redraw_metro = metro.init(function() redraw() end, 1 / 30)
  redraw_metro:start()
end

function key(n, z)
  if z == 1 then
    held[n] = now()
    light("k" .. n)
    add_log("K" .. n .. (n == 1 and " held" or " down"))
    -- a long press on K2 / K3 starts a test
    if n > 1 then
      clock.run(function()
        local t = held[n]
        clock.sleep(HOLD)
        if held[n] == t and not busy then
          if n == 2 then tone_test() else midi_test() end
        end
      end)
    end
  else
    held[n] = nil
    light("k" .. n)
  end
end

function enc(n, d)
  enc_count[n] = enc_count[n] + d
  light("e" .. n)
  add_log("E" .. n .. " " .. (d > 0 and "+" or "") .. d .. " = " .. enc_count[n])
end

-- screen ----------------------------------------------------------------------

-- one item: a label and right below it a 1 px bar as wide as the label, filled
-- by the activity (0..1); `y` is the item's top (0 = the top line)
local function item(x, y, label, act)
  local w = screen.text_extents(label)
  screen.level(10)
  screen.move(x, y + 6)
  screen.text(label)
  screen.level(1)
  screen.rect(x, y + 8, w, 1)
  screen.fill()
  local f = math.floor(util.clamp(act, 0, 1) * w + 0.5)
  if f > 0 then
    screen.level(15)
    screen.rect(x, y + 8, f, 1)
    screen.fill()
  end
  return w
end

-- an item flush with the right edge
local function item_right(y, label, act)
  item(128 - screen.text_extents(label), y, label, act)
end

-- a key: a square, filled while held (norns passes K1 on only when it's held;
-- a short press opens the menu)
local SIZE = 16

local function draw_key(n, x, y)
  if held[n] then
    screen.level(15)
    screen.rect(x, y, SIZE, SIZE)
    screen.fill()
  else
    screen.level(4)
    screen.rect(x + 0.5, y + 0.5, SIZE - 1, SIZE - 1)
    screen.stroke()
  end
end

-- a round circle, pixel by pixel (midpoint algorithm): norns' screen.circle
-- draws small circles as octagons on this screen
local function circle(cx, cy, r)
  local x, y, d = r, 0, 1 - r
  while x >= y do
    for _, p in ipairs({{x, y}, {y, x}, {-y, x}, {-x, y}, {-x, -y}, {-y, -x}, {y, -x}, {x, -y}}) do
      screen.pixel(cx + p[1], cy + p[2])
    end
    y = y + 1
    if d < 0 then d = d + 2 * y + 1
    else x = x - 1; d = d + 2 * (y - x) + 1 end
  end
  screen.fill()
end

-- a filled round disc, line by line (the same shape as circle())
local function disc(cx, cy, r)
  local x, y, d = r, 0, 1 - r
  while x >= y do
    screen.rect(cx - x, cy + y, 2 * x + 1, 1)
    screen.rect(cx - x, cy - y, 2 * x + 1, 1)
    screen.rect(cx - y, cy + x, 2 * y + 1, 1)
    screen.rect(cx - y, cy - x, 2 * y + 1, 1)
    y = y + 1
    if d < 0 then d = d + 2 * y + 1
    else x = x - 1; d = d + 2 * (y - x) + 1 end
  end
  screen.fill()
end

-- an encoder: a circle, filled while it turns (fading out after)
local function draw_enc(n, cx, cy)
  local r = SIZE / 2
  local act = activity("e" .. n)
  if act > 0 then
    screen.level(math.floor(4 + 11 * act + 0.5))
    disc(cx, cy, r)
  else
    screen.level(4)
    circle(cx, cy, r)
  end
end

-- the top row: the four audio jacks from the left, the network at the right;
-- MIDI in and out (the shieldXL's TRS jacks) at the right edge, in the middle
function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  local x = 0
  for _, j in ipairs(JACKS) do
    x = x + item(x, 0, j.label, level[j.poll]) + 6
  end
  -- the keys and encoders, where they sit on the unit: K1 / E1 top left,
  -- K2 / E2 and K3 / E3 bottom right
  -- (as on the unit: E1 right of K1; E2 / E3 above their key, a bit to the right)
  -- (6 px between all of them)
  draw_key(1, 0, 14)
  draw_enc(1, 30, 22)
  draw_key(2, 61, 48)
  draw_enc(2, 73, 34)
  draw_key(3, 83, 48)
  draw_enc(3, 95, 34)
  -- the network and USB at the rear right, in the order of the Pi's ports:
  -- a Pi 4 has Ethernet left of the USB ports, a Pi 3 the other way round
  local net_label = net or "NET"
  local outer = pi4 and {"USB", activity("usb")} or {net_label, net and 1 or 0}
  local inner = pi4 and {net_label, net and 1 or 0} or {"USB", activity("usb")}
  item_right(0, outer[1], outer[2])
  item(128 - screen.text_extents(outer[1]) - 6 - screen.text_extents(inner[1]), 0, inner[1], inner[2])
  -- MIDI in and out at the right edge, around its middle (where the jacks are)
  item_right(22, "M-I", activity("midi_in"))
  item_right(34, "M-O", activity("midi_out"))
  screen.update()
end

function cleanup()
  for _, p in ipairs(polls) do p:stop() end
  midi.add = function() end
end
