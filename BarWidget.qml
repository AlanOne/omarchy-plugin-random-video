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

  readonly property real popupWidth: Math.max(200, Number(root.setting("popupWidth", 360)) || 360)
  readonly property real videoHeight: Math.max(80, Number(root.setting("videoHeight", 220)) || 220)

  property bool popupOpen: false
  // Each entry: { type: "url" | "command", value: "..." }
  property var sources: []

  property bool resolving: false
  // The URL as configured (or a resolver command's own stdout) -- what
  // "Open in mpv" launches, letting mpv's own ytdl hook do the real
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

  function reroll() {
    if (root.resolving) return
    var valid = root.validSources()
    root.playerError = ""
    root.videoTitle = ""
    root.videoSilent = false
    root.currentBaseUrl = ""
    root.currentVideoUrl = ""
    if (valid.length === 0) return

    var pick = valid[Math.floor(Math.random() * valid.length)]
    root.resolving = true
    resolveTimeoutTimer.restart()
    if (pick.type === "command") {
      resolverProc.command = ["bash", "-c", pick.value]
      resolverProc.running = true
    } else {
      root.startYtdlp(String(pick.value).trim())
    }
  }

  function onResolverOutput(out) {
    var rawUrl = String(out || "").trim()
    if (rawUrl === "") {
      resolveTimeoutTimer.stop()
      root.resolving = false
      root.playerError = "Resolver command produced no output."
      return
    }
    root.startYtdlp(rawUrl)
  }

  function startYtdlp(url) {
    root.currentBaseUrl = url
    ytdlpProc.command = ["yt-dlp", "--no-warnings", "-f", "best/bv*", "-j", url]
    ytdlpProc.running = true
  }

  function onYtdlpResolved(jsonText) {
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
      // missing, etc.) -- fall back to treating the base URL as already a
      // directly-playable video, the original behavior this plugin started
      // with.
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
      root.playerError = "Timed out resolving this source."
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
    if (root.currentBaseUrl === "") return
    Quickshell.execDetached(["mpv", root.currentBaseUrl])
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
      if (open && root.currentVideoUrl === "" && !root.resolving && root.validSources().length > 0) {
        root.reroll()
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
            root.playerError = errorString || "Playback error"
          }
        }
      }

      Text {
        width: parent.width
        visible: root.videoSilent && root.currentVideoUrl !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "No audio in this preview — click \"Open in mpv\" for sound."
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
          text: "Open in mpv"
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
