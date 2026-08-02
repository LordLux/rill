-- Spike 03 / Q2 check 4 — drive mpv non-interactively and print a verdict.
--
-- Task 02's suite passed while playback was broken because it only ever issued
-- bounded ranges. The point of this script is the mid-file seek: that is where a
-- URL that refuses repositioned requests falls over, and it is the thing a human
-- clicking a progress bar does constantly.
--
-- Verdict line is machine-readable so the runner can score a matrix of options:
--   SPIKE VERDICT loaded=<bool> played=<bool> seek_ok=<bool> ...

local mp = require 'mp'
local msg = require 'mp.msg'

local SEEK_TO = 300      -- mid-file on a 634 s video
local SEEK_AT = 8        -- wall seconds after start
local QUIT_AT = 24

local loaded = false
local pos_before_seek = nil
local pos_after_seek = nil
local pos_final = nil

local function pos() return mp.get_property_number("time-pos") end

local function snapshot(label)
  msg.info(string.format(
    "SPIKE %s time-pos=%s audio-pts=%s avsync=%s hwdec=%s dropped=%s cache-end=%s",
    label, tostring(pos()),
    tostring(mp.get_property_number("audio-pts")),
    tostring(mp.get_property_number("avsync")),
    tostring(mp.get_property("hwdec-current")),
    tostring(mp.get_property_number("frame-drop-count")),
    tostring(mp.get_property_number("demuxer-cache-time"))
  ))
end

mp.register_event("file-loaded", function()
  loaded = true
  msg.info("SPIKE file-loaded video=" .. tostring(mp.get_property("video-codec")) ..
           " audio=" .. tostring(mp.get_property("audio-codec")) ..
           " duration=" .. tostring(mp.get_property_number("duration")))
end)

mp.add_timeout(4, function() snapshot("t+4") end)

mp.add_timeout(SEEK_AT, function()
  pos_before_seek = pos()
  snapshot("t+8 pre-seek")
  msg.info("SPIKE seeking to " .. SEEK_TO)
  mp.commandv("seek", SEEK_TO, "absolute", "exact")
end)

mp.add_timeout(SEEK_AT + 6, function()
  pos_after_seek = pos()
  snapshot("t+14 post-seek")
end)

mp.add_timeout(QUIT_AT, function()
  pos_final = pos()
  snapshot("final")

  -- Playback happened if the position moved off zero before we touched anything.
  local played = (pos_before_seek or 0) > 0.5
  -- The seek landed *and kept going*. mpv sets time-pos to the target the moment
  -- the seek is queued, so "time-pos == 300" proves nothing on its own — only a
  -- position past the target proves frames are still arriving from the new offset.
  local seek_ok = (pos_final or 0) > (SEEK_TO + 0.5)

  msg.info(string.format(
    "SPIKE VERDICT loaded=%s played=%s seek_ok=%s pre=%s post=%s final=%s hwdec=%s",
    tostring(loaded), tostring(played), tostring(seek_ok),
    tostring(pos_before_seek), tostring(pos_after_seek), tostring(pos_final),
    tostring(mp.get_property("hwdec-current"))
  ))
  mp.commandv("quit")
end)
