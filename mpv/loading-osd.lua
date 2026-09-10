-- Shows a "Loading..." OSD the instant the mpv window opens (mpv's own
-- window appears immediately with --force-window=immediate, but otherwise
-- stays blank with no feedback until the stream has buffered enough to
-- decode a first frame -- can be a few seconds for a freshly-resolved
-- stream). Cleared automatically once real playback actually starts.
mp.osd_message("Loading...", 30)

mp.register_event("playback-restart", function()
  mp.osd_message("", 0)
end)
