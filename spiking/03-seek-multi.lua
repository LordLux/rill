-- Spike 03 - multiple seeks, forward and backward.
--
-- One successful seek could be luck. A user drags the progress bar repeatedly,
-- including backwards, which is the case most likely to need a fresh connection
-- at a lower offset. Verdict counts how many of the planned seeks actually
-- resumed playback.

local mp = require 'mp'
local msg = require 'mp.msg'

local PLAN = { {at = 8, to = 300}, {at = 16, to = 60}, {at = 24, to = 500}, {at = 32, to = 120} }
local QUIT_AT = 40

local results = {}
local played_before = nil

local function pos() return mp.get_property_number("time-pos") end

mp.register_event("file-loaded", function()
  msg.info("SPIKE file-loaded video=" .. tostring(mp.get_property("video-codec")) ..
           " duration=" .. tostring(mp.get_property_number("duration")))
end)

for i, step in ipairs(PLAN) do
  mp.add_timeout(step.at, function()
    if i == 1 then played_before = pos() end
    msg.info(string.format("SPIKE seek %d -> %d (from %s)", i, step.to, tostring(pos())))
    mp.commandv("seek", step.to, "absolute", "exact")
  end)
  -- Check 5 s later: playback resumed only if the position moved past the target.
  mp.add_timeout(step.at + 5, function()
    local p = pos() or -1
    local ok = p > step.to + 0.5
    results[i] = ok
    msg.info(string.format("SPIKE seek %d %s target=%d pos=%s dropped=%s",
      i, ok and "OK" or "STALLED", step.to, tostring(p),
      tostring(mp.get_property_number("frame-drop-count"))))
  end)
end

mp.add_timeout(QUIT_AT, function()
  local okc = 0
  for _, v in ipairs(results) do if v then okc = okc + 1 end end
  msg.info(string.format("SPIKE VERDICT played=%s seeks_ok=%d/%d hwdec=%s final=%s",
    tostring((played_before or 0) > 0.5), okc, #PLAN,
    tostring(mp.get_property("hwdec-current")), tostring(pos())))
  mp.commandv("quit")
end)
