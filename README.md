# Random Video (Omarchy plugin)

A bar button that opens a popup and plays a random video right inline, with
a "Reroll" button for another pick and a one-click "Open in mpv" for its own
window.

## What counts as a "source"

This plugin doesn't maintain its own list of videos. Instead, you configure
one or more **URLs that already serve a different video on every request** —
a personal random-video endpoint, a redirect service, anything that returns
something new each time it's fetched. On each reroll, the plugin:

1. Picks one of your configured URLs at random (if you only have one, it
   always uses that one — the source itself is still what decides which
   video comes back).
2. Appends a cache-busting query parameter, so nothing sitting in between
   (a browser-style cache, a CDN) can serve a stale response for the exact
   same URL string.
3. Plays the result inline in the popup via Qt Multimedia.

If you want a fixed list of specific video files instead, point a source URL
at something on your own end that picks randomly from that list server-side
— this plugin's job stops at "ask the URL, play what comes back."

## Install

```bash
omarchy plugin add https://github.com/AlanOne/omarchy-plugin-random-video --enable
```

Or manually:

```bash
git clone https://github.com/AlanOne/omarchy-plugin-random-video ~/.config/omarchy/plugins/io.github.alanone.random-video
omarchy plugin enable io.github.alanone.random-video
```

## Requirements

- `mpv` for the "Open in mpv" button (not required for inline playback,
  which uses Qt Multimedia directly).
- Qt Multimedia's FFmpeg backend (`qt6-multimedia`, `qt6-multimedia-ffmpeg`
  on Arch/Omarchy) — already part of a stock Omarchy install, since
  `omarchy-shell` itself depends on `qt6-multimedia`.

## Settings

Click the bar icon to open the popup, then edit the source list right
there — one URL per row, with an "+ Add source" button and a "✕" to
remove one. Changes save immediately, no separate save step.

`popupWidth` and `videoHeight` (pixels) are configurable through Omarchy's
usual per-widget settings (`shell.json`'s layout entry for this widget).

## Notes

- Config lives at `~/.local/share/omarchy-random-video/config.json` — just
  `{"sources": ["https://...", ...]}`.
- The same cache-busted URL used for inline playback is also what "Open in
  mpv" launches, so both ways of watching a reroll show the same pick.
- Qt Multimedia (not a web view) plays the response, so a source needs to
  return an actual video stream/file Qt's FFmpeg backend can decode — not
  an HTML page with an embedded player (e.g. a YouTube watch page won't
  work; a direct video URL will).
