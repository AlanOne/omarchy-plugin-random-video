# Random Video (Omarchy plugin)

A bar button that opens a popup and plays a random video right inline, with
a "Reroll" button for another pick and a one-click "Open in mpv" for its own
window (with sound — see below).

## What counts as a "source"

Each configured source is one of two kinds:

- **URL** — a link that already serves a different video on every request
  (a personal random-video endpoint, a redirect service), or just a plain
  video/YouTube link.
- **Cmd** — a shell command whose stdout is such a URL. This is for sites
  where the "random video" only exists behind real client-side logic — no
  URL you can just fetch directly returns it. `ytroulette.com` is exactly
  this: its page has nothing to scrape (confirmed — even yt-dlp's generic
  extractor fails on the raw page), because its own JS calls a random
  category + position, POSTs those to its `roulette.php`, and gets back
  `{"idVideo": "...", ...}` as JSON. [`resolvers/ytroulette.sh`](resolvers/ytroulette.sh)
  replicates that exact call and prints a plain `youtube.com/watch?v=...`
  URL — paste `bash /path/to/resolvers/ytroulette.sh` as a Cmd source to
  use it, or use it as a template for another site that needs the same
  treatment.

Either way, on each reroll the plugin picks one configured source at random,
runs it if it's a command, then resolves the resulting URL with `yt-dlp`
before playing it — a plain already-playable URL round-trips through
unchanged; a YouTube (or other yt-dlp-supported site) link gets turned into
a real stream URL.

## A real constraint worth knowing: YouTube's split streams

Modern YouTube essentially never serves a single URL with both audio and
video anymore — video and audio come back as two separate streams by
design. A single inline video player can only take one URL, so **the
inline popup preview for a YouTube-resolved source plays silently**
(clearly labeled in the popup when this applies). Click **"Open in mpv"**
for full audio+video — mpv does its own proper stream muxing via its
`ytdl` hook, using the pre-resolution URL directly rather than whatever
single (silent) stream this plugin resolved for the inline preview.

A source that's already a plain, directly-playable video file (the
original design this plugin started with) is unaffected by any of this —
yt-dlp's generic extractor just returns it unchanged, and it plays with
sound inline exactly as before.

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

- `yt-dlp` — resolves every source (including a Cmd source's output) to a
  real playable stream. If it's missing or fails on a given URL, the
  plugin falls back to treating that URL as already directly playable
  (the original behavior), rather than failing outright.
- `mpv` for the "Open in mpv" button.
- `bash` for Cmd sources (each one runs as `bash -c "<your command>"`).
- Qt Multimedia's FFmpeg backend (`qt6-multimedia`, `qt6-multimedia-ffmpeg`
  on Arch/Omarchy) for inline playback — already part of a stock Omarchy
  install, since `omarchy-shell` itself depends on `qt6-multimedia`.

## Settings

Click the bar icon to open the popup, then edit the source list right
there — one row per source, a "URL"/"Cmd" toggle button, a text field, and
a "✕" to remove it. Changes save immediately, no separate save step.

`popupWidth` and `videoHeight` (pixels) are configurable through Omarchy's
usual per-widget settings (`shell.json`'s layout entry for this widget).

## Security note on Cmd sources

A Cmd source runs exactly what you type, as your own user, via
`bash -c`. This is no different from running the same command yourself in
a terminal — it's your own configured command, not something derived from
untrusted input — but it's worth knowing plainly rather than assuming the
plugin sandboxes it in any way. It doesn't.

## Notes

- Config lives at `~/.local/share/omarchy-random-video/config.json` — just
  `{"sources": [{"type": "url"|"command", "value": "..."}, ...]}`.
- "Open in mpv" always uses the pre-resolution URL (the configured URL, or
  a Cmd source's own output) — not this plugin's yt-dlp-resolved stream —
  so mpv can do its own (better) extraction and audio+video muxing.
- A resolver command or yt-dlp call that hangs gives up after 20 seconds
  rather than leaving "Resolving..." on screen forever.
