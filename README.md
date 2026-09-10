# Random Video (Omarchy plugin)

A bar button that opens a popup and plays a random video right inline, with
a "Reroll" button for another pick and a one-click "Open in window" for its own
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

Modern YouTube's default web client essentially never serves a single URL
with both audio and video anymore — video and audio come back as two
separate streams by design. This plugin resolves YouTube URLs via
yt-dlp's android client instead (`--extractor-args
"youtube:player_client=android"`), which is both noticeably faster (skips
slower/failing client attempts) and, for most regular videos, still
exposes the classic single muxed format (audio+video together) that the
default client dropped — so most of the time, the inline preview plays
with sound.

For the videos where even that doesn't yield a combined stream, a single
inline video player still can't take two separate URLs, so **the inline
preview plays silently** in that case (clearly labeled in the popup).
Click **"Open in window"** for guaranteed audio+video either way — when this
plugin's own resolution already has audio, mpv just plays that same URL
directly (instant); when it came back silent, mpv falls back to doing its
own separate resolution via its `ytdl` hook.

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
- `mpv` for the "Open in window" button.
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
- Clicking "Open in window" closes the popup immediately (stopping the
  inline preview) and opens mpv right away with a "Loading..." message,
  rather than leaving you looking at a blank window while the stream
  buffers. It uses this plugin's own already-resolved URL when that has
  audio (the common case — see above), falling back to the pre-resolution
  URL (letting mpv's own `ytdl` hook take a separate shot at it) only when
  the resolution came back silent.
- The mpv window opens with slightly larger on-screen controls than mpv's
  own default (meant for a quick "watch this" session, not a full
  media-player), and its title bar shows the actual video title when one's
  known.
- A resolver command or yt-dlp call that hangs gives up after 20 seconds
  rather than leaving "Resolving..." on screen forever.
