import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.UPower
import QtMultimedia

// Live wallpapers. When the current background is <theme>/backgrounds/<name>.*
// and the theme has <theme>/live/<name>.frag.qsb, that shader animates it.
// Omarchy's still background is a frame of the same scene. Three modes:
//   full     the whole scene moves (drawn at reduced resolution)
//   details  the still stays; only the small patches listed in
//            <theme>/live/<name>.json move, each its own little surface, so the
//            compositor only redraws those spots
//   still    no animation
// It stops while a window covers the screen. Settings live in
// ~/.config/omarchy/live-wallpaper.json:
//   { "mode": "theme", "batteryMode": "theme", "fps": 30, "batteryFps": 10,
//     "renderScale": 1, "batteryRenderScale": 0.5 }
// "theme" follows the theme's own live/mode.json (so picking "Topside" or
// "Topside Lite" decides); renderScale applies when a mode is set here.
// renderScale is the share of the screen's resolution Full mode draws at
// (full resolution costs about +0.6 W more than half on battery, measured).
// Measured on the Latitude 9520 on battery, full mode costs about +1.2 W at
// 10 fps and +3 W at 30 fps, mostly Hyprland recompositing the whole screen.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"

  property string shader: ""   // file path of the current live shader, "" for none
  property var details: []     // [[x0, y0, x1, y1], ...] in scene coordinates
  property real time: 0
  property string clockFor: ""   // the shader the clock was last started for
  property string shaderVersion: ""
  // A painted scene animates its theme's own picture (backgrounds/<name>.png),
  // which its shader samples as `source` ({"painted": true} in live/<name>.json).
  // ("plate": "<file>" in live/ instead: a copy of the picture with what the
  // scene draws itself, like moving vehicles, painted out.)
  property bool painted: false
  property string plate: ""
  // More pictures for a scene, from live/ ("layers": ["a.png", ...]), sampled
  // as layer1, layer2, ... (up to 4): parallax layers, or parts drawn on top.
  property var layers: []
  // A looping video for full motion ("video": "<file>" in live/), sampled as
  // `video`: e.g. a character cut out of a green screen, colour and mask side
  // by side. Decoded by the GPU; paused whenever the animation is.
  property string video: ""
  property var videoSize: [1048, 414]   // ("videoSize": [w, h]: the texture the shader samples)
  readonly property string videoUrl: painted && shader && video ? "file://" + shader.replace(/\/[^\/]*$/, "/" + video) : ""
  function layerUrl(i) {
    return painted && shader && layers.length > i ? "file://" + shader.replace(/\/[^\/]*$/, "/" + layers[i]) + "?v=" + shaderVersion : ""
  }
  readonly property string paintingUrl: !painted || !shader ? ""
    : plate && plate.indexOf("/") === -1 ? "file://" + shader.replace(/\/[^\/]*$/, "/" + plate) + "?v=" + shaderVersion
    : "file://" + shader.replace(/\/live\/([^\/]*)\.frag\.qsb$/, "/backgrounds/$1.png") + "?v=" + shaderVersion
  // Qt caches a shader by its URL, so a rebuilt one at the same path would
  // keep showing the old version: the build time in the URL makes it new.
  readonly property string shaderUrl: shader ? "file://" + shader + "?v=" + shaderVersion : ""
  property var settings: ({})
  readonly property bool onBattery: UPower.onBattery
  function setting(key, fallback) { var v = settings[key]; return v === undefined || v === null ? fallback : v }
  // The theme says how it animates (<theme>/live/mode.json, e.g. "Topside" is
  // {"mode": "full", "renderScale": 1} and "Topside Lite" {"mode": "details"});
  // the settings' "theme" (the default) follows it, or override it per power
  // source with "full", "details" or "still".
  property var themeLive: ({})
  readonly property bool followTheme: String(setting(onBattery ? "batteryMode" : "mode", "theme")) === "theme"
  readonly property string mode: {
    if (setting("enabled", true) === false) return "still"
    var m = followTheme ? String(themeLive.mode || "full") : String(setting(onBattery ? "batteryMode" : "mode", "theme"))
    return ["full", "details", "still"].indexOf(m) !== -1 ? m : "full"
  }
  readonly property int fps: Math.max(0, Math.min(60, Number(setting(onBattery ? "batteryFps" : "fps", onBattery ? 10 : 30)) || 0))
  // How sharp to draw: on battery "batteryRenderScale" (half by default);
  // plugged in, your "renderScale" if you set one, else the theme's, else full.
  // (The theme's used to win over both, so battery ran at full resolution.)
  readonly property real renderScale: Math.min(1, Math.max(.25, Number(onBattery
    ? setting("batteryRenderScale", .5)
    : setting("renderScale", themeLive.renderScale !== undefined ? themeLive.renderScale : 1)) || .5))
  readonly property bool live: shader !== "" && mode !== "still"
  property var activeScreens: ({})   // screen key -> true while it's showing and animating
  property int screenCount: 0        // numbers each screen's scope, for its key above
  readonly property bool anyActive: Object.keys(activeScreens).some(function(k) { return activeScreens[k] })

  // Which shader goes with the current background, if any.
  Process {
    id: lookup
    command: ["bash", "-c", "b=$(readlink -f \"$1\") || exit 0; s=\"${b%/backgrounds/*}/live/$(basename \"${b%.*}\").frag.qsb\"; [[ $b == */backgrounds/* && -f $s ]] && echo \"$s $(stat -c %Y \"$s\")\" || true", "_", root.backgroundLink]
    // A theme switch can keep the same path ("Topside" -> "Topside Lite" both
    // show backgrounds/1-topside.png), so re-read the theme's files every time.
    stdout: StdioCollector {
      onStreamFinished: {
        // "<path> <mtime>": the shader file and when it was last built
        var parts = String(text || "").trim().split(" ")
        root.shaderVersion = parts[1] || ""
        root.shader = parts[0] || ""
        detailsFile.reload()
        modeFile.reload()
      }
    }
  }
  // Look now, and again once a theme switch has settled: theme.name changes
  // mid-switch, before the background link points at the new wallpaper.
  function refresh() {
    if (!lookup.running) lookup.running = true
    settleLook.restart()
  }
  Timer { id: settleLook; interval: 350; onTriggered: if (!lookup.running) lookup.running = true }
  Timer { id: lateLook; interval: 1200; onTriggered: if (!lookup.running) lookup.running = true }
  Connections { target: settleLook; function onTriggered() { lateLook.restart() } }

  // The background link is replaced on every theme or wallpaper change; a
  // replaced link is noticed late (seconds), so also watch theme.name, which
  // every theme switch rewrites.
  FileView {
    path: root.backgroundLink
    watchChanges: true
    onFileChanged: root.refresh()
  }
  FileView {
    path: root.home + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refresh() }
  }
  Timer { interval: 20000; running: true; repeat: true; onTriggered: root.refresh() }

  // While a live wallpaper shows, picking another background has to take it
  // away at once, but the replaced link above is noticed late. So watch the
  // link's folder (inotifywait, or a check a second without it) and report
  // when the link points somewhere new. Each wait is bounded, so nothing
  // outlives this process for long.
  Process {
    id: linkWatch
    running: root.shader !== ""
    command: ["bash", "-c", "d=${1%/*}; last=$(readlink \"$1\"); while :; do if command -v inotifywait >/dev/null; then inotifywait -qq -t 30 -e create,moved_to,delete \"$d\" || true; else sleep 1; fi; now=$(readlink \"$1\"); if [[ $now != \"$last\" ]]; then last=$now; echo changed; fi; done", "_", root.backgroundLink]
    stdout: SplitParser { onRead: root.refresh() }
  }

  FileView {
    path: root.home + "/.config/omarchy/live-wallpaper.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.settings = JSON.parse(text()) } catch (e) { root.settings = {} } }
    onLoadFailed: root.settings = {}
  }

  // The patches that move in Details mode, next to the shader.
  FileView {
    id: detailsFile
    path: root.shader ? root.shader.replace(/\.frag\.qsb$/, ".json") : ""
    printErrors: false
    // Start the clock at the still's moment: Lite's patches then begin in step
    // with the picture around them, and full motion starts from that frame.
    onLoaded: {
      try {
        var info = JSON.parse(text())
        root.details = info.details || []
        root.painted = info.painted === true
        root.plate = String(info.plate || "")
        root.videoSize = Array.isArray(info.videoSize) && info.videoSize.length === 2 ? info.videoSize.map(Number) : [1048, 414]
        root.video = String(info.video || "").indexOf("/") === -1 ? String(info.video || "") : ""
        root.layers = Array.isArray(info.layers) ? info.layers.map(String).filter(function(f) { return f.indexOf("/") === -1 }) : []
        if (root.clockFor !== root.shader) {   // only when the scene changes
          root.clockFor = root.shader
          root.time = Number(info.still) || 0
        }
      } catch (e) { root.details = [] }
    }
    onLoadFailed: root.details = []
  }
  FileView {
    id: modeFile
    path: root.shader ? root.shader.replace(/\/[^\/]*$/, "/mode.json") : ""
    printErrors: false
    onLoaded: { try { root.themeLive = JSON.parse(text()) || {} } catch (e) { root.themeLive = {} } }
    onLoadFailed: root.themeLive = {}
  }

  Component.onCompleted: refresh()

  // Lite copies of live themes ("Topside" -> "Topside Lite"), made and kept up
  // to date by make-lite.sh next to this file: at startup, then every 10
  // minutes (after `omarchy theme install` or `update`).
  Process {
    id: makeLite
    command: ["bash", String(Qt.resolvedUrl("make-lite.sh")).replace(/^file:\/\//, "")]
    running: true
  }
  Timer { interval: 600000; running: true; repeat: true; onTriggered: if (!makeLite.running) makeLite.running = true }

  // The clock. Wrapped every two hours to keep float maths precise.
  Timer {
    interval: Math.round(1000 / Math.max(root.fps, 1))
    running: root.live && root.fps > 0 && root.anyActive
    repeat: true
    property double last: 0
    onRunningChanged: last = Date.now()
    onTriggered: {
      var now = Date.now()
      root.time = (root.time + Math.min(now - last, 250) / 1000) % 7200
      last = now
    }
  }

  // Window events refresh Hyprland's client list (positions, fullscreen),
  // and screen changes its monitor list (sizes, for the check below).
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (/window|workspace|fullscreen|move|monitor/.test(event.name)) Hyprland.refreshToplevels()
      if (/monitor/.test(event.name)) Hyprland.refreshMonitors()
    }
  }

  Variants {
    model: Quickshell.screens

    Scope {
      id: screenScope
      required property var modelData

      // Shown a moment after the shell starts so the surfaces stack above
      // Omarchy's own background (same layer; later surfaces draw on top).
      property bool ready: false
      Timer { interval: 1500; running: true; onTriggered: screenScope.ready = true }

      readonly property var monitor: Hyprland.monitorFor(modelData)
      property bool covered: false

      // Stop when a fullscreen window, or one filling ~90% of the screen,
      // is on this screen's workspace.
      function checkCovered() {
        var mon = monitor, ws = mon && mon.activeWorkspace
        if (!ws) { covered = false; return }
        var m = mon.lastIpcObject || {}
        // A screen that just came back (lid, dock) has no size yet: fetch it
        // rather than count every window as covering a 1x1 screen.
        if (!m.width || !m.height) { Hyprland.refreshMonitors(); covered = false; return }
        var area = m.width / (m.scale || 1) * m.height / (m.scale || 1)
        var list = Hyprland.toplevels.values
        var hidden = false
        for (var i = 0; i < list.length; i++) {
          var o = list[i].lastIpcObject
          if (!o || !o.workspace || o.workspace.id !== ws.id || !o.size) continue
          if (o.fullscreen > 0 || o.size[0] * o.size[1] >= area * .9) { hidden = true; break }
        }
        covered = hidden
      }
      Timer { interval: 1000; running: screenScope.ready && root.live; repeat: true; onTriggered: screenScope.checkCovered() }

      readonly property bool animating: ready && root.live && !covered
      // Each scope has its own key, not just the screen's name: when a screen
      // comes back (lid, dock) the old scope for that name can still report
      // "not animating" after the new one said it is, which stopped the clock
      // for good.
      property string activeKey: ""
      Component.onCompleted: activeKey = modelData.name + "#" + (++root.screenCount)
      function report() {
        if (!activeKey) return
        var a = Object.assign({}, root.activeScreens)
        a[activeKey] = animating
        root.activeScreens = a
      }
      onAnimatingChanged: report()
      onActiveKeyChanged: report()
      Component.onDestruction: {
        var a = Object.assign({}, root.activeScreens)
        delete a[activeKey]
        root.activeScreens = a
      }

      // Full mode: the whole scene, drawn small and scaled up.
      PanelWindow {
        screen: screenScope.modelData
        visible: screenScope.ready && root.live && root.mode === "full"
        WlrLayershell.namespace: "live-wallpaper"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        mask: Region {}   // clicks go through to Omarchy's background

        Item {
          anchors.fill: parent
          layer.enabled: true
          layer.smooth: true
          layer.textureSize: Qt.size(Math.round(width * root.renderScale), Math.round(height * root.renderScale))

          ShaderEffect {
            anchors.fill: parent
            property real time: root.time
            property size resolution: Qt.size(Math.round(width * root.renderScale), Math.round(height * root.renderScale))
            property rect viewport: Qt.rect(0, 0, 1, 1)
            property real detail: 0
            property var source: fullPainting
            property var layer1: fullL1
            property var layer2: fullL2
            property var layer3: fullL3
            property var layer4: fullL4
            property var video: videoTexture
            fragmentShader: root.shaderUrl
          }
          Image { id: fullL1; visible: false; source: root.layerUrl(0); asynchronous: true; smooth: true }
          Image { id: fullL2; visible: false; source: root.layerUrl(1); asynchronous: true; smooth: true }
          Image { id: fullL3; visible: false; source: root.layerUrl(2); asynchronous: true; smooth: true }
          Image { id: fullL4; visible: false; source: root.layerUrl(3); asynchronous: true; smooth: true }
          Image { id: fullPainting; visible: false; source: root.paintingUrl; asynchronous: true; smooth: true; mipmap: true }
        }

        // The video sits outside the scene's layer, and the shader picks up its
        // newest frame only on the clock's tick: inside, each video frame
        // (24 a second) redrew the whole scene on top of the clock's own
        // redraws, which weren't in step with them, so the scene was drawn
        // up to ~54 times a second whatever the fps setting.
        MediaPlayer {
          id: player
          source: root.videoUrl && root.mode === "full" ? root.videoUrl : ""
          loops: MediaPlayer.Infinite
          videoOutput: videoOut
          readonly property bool wanted: source != "" && screenScope.animating && root.fps > 0
          onWantedChanged: wanted ? play() : pause()
          onSourceChanged: if (wanted) play()
        }
        VideoOutput { id: videoOut; width: root.videoSize[0]; height: root.videoSize[1]; fillMode: VideoOutput.Stretch }
        ShaderEffectSource { id: videoTexture; sourceItem: videoOut; hideSource: true; live: false; visible: false }
        Connections {
          target: root
          enabled: player.wanted
          function onTimeChanged() { videoTexture.scheduleUpdate() }
        }
      }

      // Details mode: one small surface per moving patch, at full resolution so
      // it matches the still around it.
      Variants {
        model: screenScope.ready && root.live && root.mode === "details" ? root.details : []

        PanelWindow {
          id: patch
          required property var modelData
          screen: screenScope.modelData
          readonly property real sw: screen ? screen.width : 1
          readonly property real sh: screen ? screen.height : 1
          readonly property real aspect: sw / sh
          // scene coordinates -> pixels (y up from the middle, height = 1)
          readonly property int px: Math.max(0, Math.floor((modelData[0] / aspect + .5) * sw))
          readonly property int py: Math.max(0, Math.floor((.5 - modelData[3]) * sh))
          readonly property int pw: Math.min(sw, Math.ceil((modelData[2] / aspect + .5) * sw)) - px
          readonly property int ph: Math.min(sh, Math.ceil((.5 - modelData[1]) * sh)) - py
          visible: pw > 0 && ph > 0

          WlrLayershell.namespace: "live-wallpaper-detail"
          WlrLayershell.layer: WlrLayer.Background
          WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
          exclusionMode: ExclusionMode.Ignore
          anchors { top: true; left: true }
          margins { top: py; left: px }
          implicitWidth: Math.max(pw, 1)
          implicitHeight: Math.max(ph, 1)
          color: "transparent"
          mask: Region {}

          ShaderEffect {
            anchors.fill: parent
            readonly property real dpr: patch.screen ? patch.screen.devicePixelRatio || 1 : 1
            property real time: root.time
            property size resolution: Qt.size(patch.sw * dpr, patch.sh * dpr)
            property rect viewport: Qt.rect(patch.px / patch.sw, patch.py / patch.sh, patch.pw / patch.sw, patch.ph / patch.sh)
            property real detail: 1
            property var source: patchPainting
            property var layer1: patchL1
            property var layer2: patchL2
            property var layer3: patchL3
            property var layer4: patchL4
            property var video: patchL4
            fragmentShader: root.shaderUrl
          }
          Image { id: patchL1; visible: false; source: root.layerUrl(0); asynchronous: true; smooth: true }
          Image { id: patchL2; visible: false; source: root.layerUrl(1); asynchronous: true; smooth: true }
          Image { id: patchL3; visible: false; source: root.layerUrl(2); asynchronous: true; smooth: true }
          Image { id: patchL4; visible: false; source: root.layerUrl(3); asynchronous: true; smooth: true }
          Image { id: patchPainting; visible: false; source: root.paintingUrl; asynchronous: true; smooth: true }
        }
      }
    }
  }
}
