import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar button + popup that plays a random video inline. "Random" here means
// the *source* is responsible for it: each configured URL is expected to
// already serve a different video on every request (a personal
// random-video endpoint, a redirect service, etc.) -- this plugin just
// picks one of the configured URLs at random, cache-busts the request so
// nothing in between serves a stale response, and plays it straight in the
// popup via QtMultimedia. A button next to it launches the same URL into
// mpv for a real standalone window.
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
  property var sourceUrls: []

  // The exact (cache-busted) URL currently loaded in the player -- also
  // what "Open in mpv" launches, so both ways of watching a reroll show the
  // same pick.
  property string currentVideoUrl: ""
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
        root.sourceUrls = arr.map(function(u) { return String(u || "") })
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
    configFile.setText(JSON.stringify({ sources: root.sourceUrls }, null, 2) + "\n")
  }

  function addSource() {
    root.sourceUrls = root.sourceUrls.concat([""])
  }

  function updateSource(index, value) {
    var arr = root.sourceUrls.slice()
    arr[index] = value
    root.sourceUrls = arr
    root.saveSources()
  }

  function removeSource(index) {
    var arr = root.sourceUrls.slice()
    arr.splice(index, 1)
    root.sourceUrls = arr
    root.saveSources()
    // The removed row might have been the one currently playing -- rather
    // than guess, just leave the player showing whatever it already loaded
    // until the next explicit reroll.
  }

  function validSources() {
    return root.sourceUrls
      .map(function(u) { return String(u || "").trim() })
      .filter(function(u) { return u !== "" })
  }

  // Appends a fresh, unpredictable query param so a URL that's meant to
  // serve something different every time isn't ever served from a cache
  // (browser-style HTTP cache, a CDN in front of the source, anything in
  // between) sitting on the exact same URL string.
  function cacheBust(url) {
    var sep = url.indexOf("?") === -1 ? "?" : "&"
    return url + sep + "_rv=" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
  }

  function reroll() {
    root.playerError = ""
    var valid = root.validSources()
    if (valid.length === 0) {
      root.currentVideoUrl = ""
      return
    }
    var pick = valid[Math.floor(Math.random() * valid.length)]
    root.currentVideoUrl = root.cacheBust(pick)
  }

  function openInMpv() {
    if (root.currentVideoUrl === "") return
    Quickshell.execDetached(["mpv", root.currentVideoUrl])
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
  // source URL list), and PopupCard doesn't reliably route keyboard focus
  // to a child TextField (see the Cameras/MWB Bridge plugins' own notes on
  // this same gotcha).
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(root.popupWidth))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    onOpenChanged: {
      if (open && root.currentVideoUrl === "" && root.validSources().length > 0) {
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
        visible: root.currentVideoUrl === "" && root.validSources().length === 0
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Add a source URL below to get started."
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
          text: "Reroll"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.validSources().length > 0
          onClicked: root.reroll()
        }

        Button {
          text: "Open in mpv"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.currentVideoUrl !== ""
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
        text: "One URL per row. Each one should already return a different video on every request -- this plugin doesn't need to know a video list up front, it just picks a source and asks it fresh (with a cache-busting query param) each time."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.sourceUrls

        Row {
          id: sourceRow
          required property string modelData
          required property int index
          width: column.width
          spacing: Style.space(6)

          TextField {
            id: sourceField
            width: sourceRow.width - removeButton.width - sourceRow.spacing
            text: sourceRow.modelData
            placeholderText: "https://example.com/random-video"
            onEditingFinished: root.updateSource(sourceRow.index, text)
          }

          Button {
            id: removeButton
            text: "✕"
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
