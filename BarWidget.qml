import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar button + popup that plays a random video inline. "Random" here means
// the *source* is responsible for it: each configured source is either a
// URL that already serves a different video on every request, or a shell
// command whose stdout is a video URL (for sites where getting that URL
// takes real client-side logic -- see README, ytroulette.com is the
// motivating example). Either way, the resulting URL is resolved with
// yt-dlp before playback: a plain already-playable URL round-trips through
// unchanged, while something like a YouTube link gets turned into a real
// stream URL. A button next to it launches the same pre-resolution URL into
// mpv, which does its own (better) audio+video handling via its ytdl hook.
BarWidget {
  id: root
  moduleName: "io.github.alanone.random-video"
  // See the MWB Bridge / Cameras plugins' own notes on this: a bare Item
  // (which BarWidget extends) never derives implicitWidth/Height from an
  // anchors.fill child, so the bar's ModuleSlot can't size the slot at all
  // without this -- the widget would load cleanly and just never appear.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: root.home + "/.local/share/omarchy-random-video"
  readonly property string configPath: root.dataDir + "/config.json"

  // This widget's own directory, resolved from the QML file's own URL
  // rather than assuming the canonical ~/.config/omarchy/plugins/... path
  // (see the MWB Bridge plugin's identical pattern) -- used to find the
  // bundled mpv/loading-osd.lua script regardless of where this got
  // checked out.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.substring("file://".length)
    return url.replace(/\/+$/, "")
  }

  readonly property real popupWidth: Math.max(200, Number(root.setting("popupWidth", 360)) || 360)
  readonly property real videoHeight: Math.max(80, Number(root.setting("videoHeight", 220)) || 220)

  property bool popupOpen: false
  // Each entry: { type: "url" | "command", value: "..." }
  property var sources: []

  property bool resolving: false
  // Bumped on every reroll() call and every time resolution is abandoned
  // (popup closed, timed out) -- lets a resolver/yt-dlp response that
  // arrives after its own request was abandoned recognize itself as stale
  // and get ignored, rather than overwriting state a newer (or no) request
  // set up in the meantime. Killing a Process via `.running = false`
  // doesn't stop its StdioCollector's onStreamFinished from firing with
  // whatever partial output it already captured -- without this check,
  // closing the popup mid-resolution and reopening it could show a leftover
  // "no output"/error from the abandoned request instead of the fresh one.
  property int rerollGeneration: 0
  property int pendingGeneration: -1
  // Which kind of source the in-flight (or most recently resolved) request
  // came from -- onYtdlpResolved needs this to know whether falling back to
  // playing currentBaseUrl verbatim (when yt-dlp itself fails) makes any
  // sense at all: fine for a "url" source that might already be a direct
  // video file, nonsensical for a "command" source, whose output is
  // virtually always a page/id reference that needs yt-dlp, never a
  // directly-playable file.
  property string pendingSourceType: "url"
  // How many *automatic* retries (a failed resolution or a playback error
  // silently trying another random source instead of giving up) have
  // happened since the last manual reroll() call. Capped so a source that's
  // reliably broken (or a fully offline network) can't retry forever.
  property int autoRetryCount: 0
  readonly property int maxAutoRetries: 3
  // The URL as configured (or a resolver command's own stdout) -- what
  // "Open in window" launches, letting mpv's own ytdl hook do the real
  // audio+video handling rather than reusing whatever yt-dlp gave us here.
  property string currentBaseUrl: ""
  // What's actually fed to the inline Video element -- either the same
  // base URL (cache-busted, if yt-dlp couldn't resolve it further) or a
  // real resolved stream URL.
  property string currentVideoUrl: ""
  property bool videoSilent: false
  property string videoTitle: ""
  property string playerError: ""

  function close() { root.popupOpen = false }

  Component.onCompleted: {
    mkdirProc.running = true
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.dataDir]
    onExited: function(exitCode) { configFile.reload() }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var cfg = JSON.parse(String(text() || ""))
        var arr = Array.isArray(cfg.sources) ? cfg.sources : []
        root.sources = arr.map(function(s) {
          // Migrates the very first version's plain-string-array format
          // (no type, just a URL) into the current { type, value } shape.
          if (typeof s === "string") return { type: "url", value: s }
          return {
            type: (s && s.type === "command") ? "command" : "url",
            value: String((s && s.value) || "")
          }
        })
      } catch (e) {
        // Malformed/first-ever run -- start from an empty list rather than
        // blocking on it.
      }
    }
    onLoadFailed: function(error) {
      // No config yet (fresh install) -- nothing to load, empty list is
      // already the initial value.
    }
  }

  function saveSources() {
    configFile.setText(JSON.stringify({ sources: root.sources }, null, 2) + "\n")
  }

  function addSource() {
    root.sources = root.sources.concat([{ type: "url", value: "" }])
  }

  function updateSourceValue(index, value) {
    var arr = root.sources.slice()
    arr[index] = { type: arr[index].type, value: value }
    root.sources = arr
    root.saveSources()
  }

  function toggleSourceType(index) {
    var arr = root.sources.slice()
    arr[index] = { type: arr[index].type === "command" ? "url" : "command", value: arr[index].value }
    root.sources = arr
    root.saveSources()
  }

  function removeSource(index) {
    var arr = root.sources.slice()
    arr.splice(index, 1)
    root.sources = arr
    root.saveSources()
  }

  function validSources() {
    return root.sources.filter(function(s) { return s && String(s.value || "").trim() !== "" })
  }

  // Appends a fresh, unpredictable query param so a URL that's meant to
  // serve something different every time isn't ever served from a cache
  // sitting on the exact same URL string. Only used as a last resort (see
  // onYtdlpResolved) -- never applied to an already-resolved, signed
  // stream URL, which it would just break.
  function cacheBust(url) {
    var sep = url.indexOf("?") === -1 ? "?" : "&"
    return url + sep + "_rv=" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
  }

  function formatTime(ms) {
    if (!ms || ms <= 0) return "0:00"
    var totalSeconds = Math.floor(ms / 1000)
    var m = Math.floor(totalSeconds / 60)
    var s = totalSeconds % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // Public entry point -- a real user-initiated attempt (Reroll button, or
  // the popup's own first-open), so it resets the auto-retry budget.
  function reroll() {
    root.autoRetryCount = 0
    root.attemptReroll()
  }

  function attemptReroll() {
    if (root.resolving) return
    var valid = root.validSources()
    root.playerError = ""
    root.videoTitle = ""
    root.videoSilent = false
    root.currentBaseUrl = ""
    root.currentVideoUrl = ""
    if (valid.length === 0) return

    var pick = valid[Math.floor(Math.random() * valid.length)]
    root.pendingSourceType = pick.type
    root.resolving = true
    root.rerollGeneration++
    root.pendingGeneration = root.rerollGeneration
    resolveTimeoutTimer.restart()
    if (pick.type === "command") {
      resolverProc.command = ["bash", "-c", pick.value]
      resolverProc.running = true
    } else {
      root.startYtdlp(String(pick.value).trim())
    }
  }

  // A source that failed to resolve or actually play is far more likely to
  // just be a bad pick (dead link, a resolver hiccup, yt-dlp choking on
  // this one video) than the whole feature being broken -- silently trying
  // another random source reads much better than dumping an error on
  // screen, as long as it can't retry forever.
  function handleFailure(message) {
    if (root.autoRetryCount < root.maxAutoRetries) {
      root.autoRetryCount++
      root.attemptReroll()
    } else {
      root.playerError = message
    }
  }

  function onResolverOutput(out) {
    if (root.pendingGeneration !== root.rerollGeneration) return
    var rawUrl = String(out || "").trim()
    if (rawUrl === "") {
      resolveTimeoutTimer.stop()
      root.resolving = false
      root.handleFailure("Resolver command produced no output.")
      return
    }
    root.startYtdlp(rawUrl)
  }

  function startYtdlp(url) {
    root.currentBaseUrl = url
    // Forcing YouTube's android client instead of yt-dlp's default is a
    // deliberate choice, not a random flag: it's both meaningfully faster
    // (skips the slower default client(s), avoids failed-format retries)
    // and, for most regular videos, still exposes the classic single-file
    // muxed format (itag 18, audio+video together) that the default/web
    // client no longer offers at all -- confirmed empirically on a video
    // that had zero combined formats otherwise. Harmless no-op for any
    // non-YouTube URL (yt-dlp ignores extractor-args for extractors that
    // don't match).
    ytdlpProc.command = ["yt-dlp", "--no-warnings", "--extractor-args", "youtube:player_client=android", "-f", "best/bv*", "-j", url]
    ytdlpProc.running = true
  }

  function onYtdlpResolved(jsonText) {
    if (root.pendingGeneration !== root.rerollGeneration) return
    resolveTimeoutTimer.stop()
    root.resolving = false
    var resolvedUrl = ""
    var silent = false
    var title = ""
    try {
      var data = JSON.parse(String(jsonText || ""))
      if (data && data.url) {
        resolvedUrl = String(data.url)
        silent = String(data.acodec || "") === "none"
        title = String(data.title || "")
      }
    } catch (e) {
      // Not resolvable via yt-dlp (unsupported URL, network hiccup, yt-dlp
      // missing, etc.). For a "url" source, currentBaseUrl might already be
      // a directly-playable video file -- worth trying verbatim, the
      // original behavior this plugin started with. For a "command"
      // source, currentBaseUrl is virtually always a page/id reference a
      // resolver script produced (e.g. a youtube.com/watch?v=... URL) --
      // never something a video player can open directly -- so treat it as
      // a real failure instead of feeding that straight to the player
      // (confirmed live: that produced a bare "Could not open file").
    }
    if (resolvedUrl === "" && root.pendingSourceType === "command") {
      root.handleFailure("Couldn't resolve a playable video from this source.")
      return
    }
    root.videoSilent = silent
    root.videoTitle = title
    root.currentVideoUrl = resolvedUrl !== "" ? resolvedUrl : root.cacheBust(root.currentBaseUrl)
  }

  // A resolver command that hangs (bad script, dead endpoint) or a stalled
  // yt-dlp call would otherwise leave "Resolving..." on screen forever with
  // Reroll disabled -- this guarantees a way out.
  Timer {
    id: resolveTimeoutTimer
    interval: 20000
    onTriggered: {
      resolverProc.running = false
      ytdlpProc.running = false
      root.resolving = false
      root.rerollGeneration++
      root.handleFailure("Timed out resolving this source.")
    }
  }

  Process {
    id: resolverProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onResolverOutput(text)
    }
  }

  Process {
    id: ytdlpProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onYtdlpResolved(text)
    }
  }

  function openInMpv() {
    // Prefer the URL this plugin already resolved -- it's usually a real
    // combined audio+video stream now (see startYtdlp's comment), and mpv
    // can just play it directly with no further work. Only fall back to
    // handing mpv the pre-resolution URL (letting its own, slower ytdl
    // hook take a separate shot at it) when our own resolution came back
    // silent -- redoing that same silent resolution again would be pure
    // wasted latency for no benefit.
    var target = (root.currentVideoUrl !== "" && !root.videoSilent)
      ? root.currentVideoUrl
      : root.currentBaseUrl
    if (target === "") return
    var title = root.videoTitle

    // Close (and let the popup's own onOpenChanged stop the inline preview
    // and cancel any in-flight resolution) before reading anything else off
    // root -- both title and target are already captured above.
    root.popupOpen = false

    var args = [
      "mpv",
      // Opens the window immediately instead of waiting for a decoded
      // frame -- otherwise a freshly-resolved stream can leave the user
      // staring at nothing for a few seconds with no feedback at all.
      "--force-window=immediate",
      // Shows "Loading..." on that blank window right away, clearing once
      // real playback actually starts (see mpv/loading-osd.lua).
      "--script=" + root.pluginDir + "/mpv/loading-osd.lua",
      // A bit bigger than mpv's own default OSC -- more comfortable to
      // read/click for what's meant to be a quick "watch this" window,
      // not a full media-player session.
      "--script-opts=osc-scalewindowed=1.4,osc-scalefullscreen=1.3"
    ]
    if (title !== "") args.push("--force-media-title=" + title)
    args.push(target)
    Quickshell.execDetached(args)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "▶"
    slotSize: Style.bar.statusSlot
    active: root.popupOpen
    foreground: root.bar.barForeground
    tooltipText: "Random Video"

    onPressed: function(b) { root.popupOpen = !root.popupOpen }
  }

  // KeyboardPanel, not PopupCard -- this popup has real text fields (the
  // source list), and PopupCard doesn't reliably route keyboard focus to a
  // child TextField (see the Cameras/MWB Bridge plugins' own notes on this
  // same gotcha).
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(root.popupWidth))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    onOpenChanged: {
      if (open) {
        if (root.currentVideoUrl === "" && !root.resolving && root.validSources().length > 0) {
          root.reroll()
        }
      } else {
        // Stop playback (and any in-flight resolution) the moment the
        // popup closes, rather than leaving it running silently in the
        // background -- reopening picks a fresh video, same as a first
        // open. "Open in window" windows are untouched -- those are the
        // user's own separate windows, not tied to this popup's lifetime.
        player.stop()
        resolverProc.running = false
        ytdlpProc.running = false
        resolveTimeoutTimer.stop()
        root.resolving = false
        root.rerollGeneration++
        root.currentVideoUrl = ""
        root.currentBaseUrl = ""
        root.videoTitle = ""
        root.videoSilent = false
        root.playerError = ""
      }
    }

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: "Random Video"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        width: parent.width
        visible: root.resolving
        textFormat: Text.PlainText
        text: "Resolving..."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        visible: !root.resolving && root.videoTitle !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
        text: root.videoTitle
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Rectangle {
        width: parent.width
        height: Style.space(root.videoHeight)
        color: Qt.darker(root.bar.foreground, 6)
        visible: root.currentVideoUrl !== ""
        clip: true

        Video {
          id: player
          anchors.fill: parent
          autoPlay: true
          fillMode: VideoOutput.PreserveAspectFit
          source: root.currentVideoUrl
          onErrorOccurred: function(error, errorString) {
            // Also fires when `source` gets cleared out from under it (e.g.
            // on popup close) -- only treat it as a real failure worth
            // retrying when we were actually expecting something to play.
            if (root.currentVideoUrl === "") return
            root.handleFailure(errorString || "Playback error")
          }
        }

        // Minimal overlay strip -- just enough to pause/resume the preview
        // and see how long it is, not a full player UI (that's what "Open
        // in window" is for).
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(28)
          color: Qt.rgba(0, 0, 0, 0.55)

          Button {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(4)
            // "⏸" (U+23F8) renders as a colored emoji (yellow rounded
            // square) in many fonts -- "▮▮" is a plain geometric-shapes
            // glyph like "▶", so both stay the same flat white style.
            text: player.playbackState === MediaPlayer.PlayingState ? "▮▮" : "▶"
            foreground: "white"
            // "▮▮" renders noticeably *larger* than "▶" at the same
            // fontSize in this shell's actual font (JetBrainsMono Nerd
            // Font) -- scaled down ~0.65x here to visually match, measured
            // via a side-by-side isolated render using that exact font
            // (an earlier attempt measured this against the wrong default
            // font and scaled the wrong direction).
            fontSize: player.playbackState === MediaPlayer.PlayingState ? Style.font.bodySmall * 0.65 : Style.font.bodySmall
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(2)
            onClicked: {
              if (player.playbackState === MediaPlayer.PlayingState) player.pause()
              else player.play()
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Style.space(8)
            textFormat: Text.PlainText
            text: root.formatTime(player.position) + " / " + root.formatTime(player.duration)
            color: "white"
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        width: parent.width
        visible: root.videoSilent && root.currentVideoUrl !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "No audio in this preview — click \"Open in window\" for sound."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: !root.resolving && root.currentVideoUrl === "" && root.validSources().length === 0
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Add a source below to get started."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        visible: root.playerError !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.playerError
        color: Color.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Button {
          text: root.resolving ? "Resolving..." : "Reroll"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: !root.resolving && root.validSources().length > 0
          onClicked: root.reroll()
        }

        Button {
          text: "Open in window"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.currentBaseUrl !== ""
          onClicked: root.openInMpv()
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.darker(root.bar.foreground, 4)
      }

      Text {
        textFormat: Text.PlainText
        text: "Sources"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "URL: a link that already serves a different video each time (or a plain video/YouTube link). Cmd: a shell command whose output is such a link -- for sites where getting it takes real client-side logic (see README). Either way the result is resolved with yt-dlp before playing."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.sources

        Row {
          id: sourceRow
          required property var modelData
          required property int index
          width: column.width
          spacing: Style.space(6)

          Button {
            id: typeButton
            text: sourceRow.modelData.type === "command" ? "Cmd" : "URL"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.space(4)
            onClicked: root.toggleSourceType(sourceRow.index)
          }

          TextField {
            id: sourceField
            width: sourceRow.width - typeButton.width - removeButton.width - sourceRow.spacing * 2
            text: sourceRow.modelData.value
            placeholderText: sourceRow.modelData.type === "command"
              ? "shell command that prints a video URL"
              : "https://example.com/random-video"
            onEditingFinished: root.updateSourceValue(sourceRow.index, text)
          }

          Button {
            id: removeButton
            text: "✕"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.space(4)
            onClicked: root.removeSource(sourceRow.index)
          }
        }
      }

      Button {
        text: "+ Add source"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.space(4)
        onClicked: root.addSource()
      }
    }
  }
}
