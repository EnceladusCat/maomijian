import AVFoundation
import ScreenCaptureKit
import SwiftUI

private enum RecordingArea: CaseIterable {
  case display, region
  var title: String { self == .display ? L("整个屏幕") : L("选定区域") }
}

private extension NSScreen {
  var captureID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

private final class RecordingPanel: NSPanel {
  var allowsKey = false
  override var canBecomeKey: Bool { allowsKey }
}

@MainActor
final class ScreenRecorder: NSObject, ObservableObject, NSMenuDelegate {
  enum Phase { case idle, setup, starting, recording, paused, finishing }
  @Published private(set) var phase = Phase.idle
  @Published fileprivate var area = RecordingArea.display { didSet { updateRegionMode() } }
  @Published fileprivate var screenID: CGDirectDisplayID = 0 { didSet { if oldValue != screenID { showSelection() } } }
  @Published fileprivate var sound = RecordingSound.none {
    didSet { UserDefaults.standard.set(sound.rawValue, forKey: "editor.recording.sound") }
  }
  @Published fileprivate var showTimer = true {
    didSet {
      hud?.ignoresMouseEvents = !showTimer
      if !showTimer { pointerOverHUD = false }
      UserDefaults.standard.set(showTimer, forKey: "editor.recording.showTimer")
    }
  }
  @Published fileprivate var pointerOverHUD = false
  @Published fileprivate var folder: URL {
    didSet { UserDefaults.standard.set(folder.path, forKey: "editor.recording.folder") }
  }
  private let saved: (URL) -> Void
  private let failed: (String) -> Void
  private var toolbar: NSPanel?
  private var selection: NSPanel?
  private var hud: NSPanel?
  private var status: NSStatusItem?
  private var screenRegion: RecordingRegionView?
  private var capture: ScreenRecordingCapture?
  private var captureID: UUID?
  private var clock = RecordingTimeline()
  private var startTimeout: Task<Void, Never>?
  private weak var editorWindow: NSWindow?

  init(saved: @escaping (URL) -> Void, failed: @escaping (String) -> Void) {
    self.saved = saved
    self.failed = failed
    let home = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    let defaults = UserDefaults.standard
    folder = defaults.string(forKey: "editor.recording.folder").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? home.appendingPathComponent("毛咪剪录屏", isDirectory: true)
    super.init()
    showTimer = defaults.object(forKey: "editor.recording.showTimer") as? Bool ?? true
    if let value = defaults.string(forKey: "editor.recording.sound").flatMap(RecordingSound.init(rawValue:)),
      RecordingSound.available.contains(value) { sound = value }
  }

  var isCapturing: Bool { phase != .idle && phase != .setup }
  var canPause: Bool { phase == .recording || phase == .paused }
  fileprivate var pauseTitle: String { phase == .paused ? L("继续录屏") : L("暂停录屏") }
  fileprivate var pauseIcon: String { phase == .paused ? "play.fill" : "pause.fill" }

  func open(from window: NSWindow) {
    if phase == .setup { toolbar?.makeKeyAndOrderFront(nil); return }
    if isCapturing {
      status?.button?.performClick(nil)
      return
    }
    guard window.attachedSheet == nil, NSApp.modalWindow == nil,
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? window.screen ?? NSScreen.main, let id = screen.captureID else { return }
    editorWindow = window
    screenID = id
    phase = .setup
    let panel = makePanel(size: CGSize(width: 554, height: 129))
    panel.allowsKey = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    panel.title = L("录制屏幕")
    panel.contentView = NSHostingView(rootView: RecordingToolbar(recorder: self))
    toolbar = panel
    showSelection()
    panel.makeKeyAndOrderFront(nil)
  }

  private func makePanel(size: CGSize, nonactivating: Bool = false) -> RecordingPanel {
    let panel = RecordingPanel(contentRect: CGRect(origin: .zero, size: size),
      styleMask: nonactivating ? [.borderless, .nonactivatingPanel] : [.borderless],
      backing: .buffered, defer: false)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    if nonactivating { panel.becomesKeyOnlyIfNeeded = true }
    return panel
  }

  private func showSelection() {
    guard phase == .setup, let toolbar,
      let screen = NSScreen.screens.first(where: { $0.captureID == screenID }) else { return }
    selection?.orderOut(nil)
    let region = RecordingRegionView(size: screen.frame.size)
    let overlay = makePanel(size: screen.frame.size, nonactivating: true)
    overlay.title = L("录屏范围")
    overlay.hasShadow = false
    overlay.setFrame(screen.frame, display: true)
    overlay.contentView = region
    screenRegion = region
    selection = overlay
    updateRegionMode()
    overlay.orderFrontRegardless()
    let visible = screen.visibleFrame
    toolbar.setFrameOrigin(CGPoint(x: visible.midX - toolbar.frame.width / 2, y: visible.minY + 36))
    toolbar.orderFrontRegardless()
  }

  private func updateRegionMode() {
    screenRegion?.useRegion = area == .region
    selection?.ignoresMouseEvents = area == .display
  }

  fileprivate func chooseFolder() {
    guard let toolbar, phase == .setup else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = L("选取文件夹")
    panel.directoryURL = folder
    panel.beginSheetModal(for: toolbar) { [weak self] response in
      if response == .OK, let destination = panel.url { self?.folder = destination }
    }
  }

  fileprivate func cancelSetup() {
    guard phase == .setup, toolbar?.attachedSheet == nil else { return }
    closeSelection()
    phase = .idle
    editorWindow?.makeKeyAndOrderFront(nil)
  }

  private func closeSelection() {
    selection?.orderOut(nil)
    selection = nil
    screenRegion = nil
    toolbar?.orderOut(nil)
    toolbar = nil
  }

  fileprivate func start() {
    guard phase == .setup, let screen = NSScreen.screens.first(where: { $0.captureID == screenID }) else { return }
    let displayID = screenID
    let rectangle = area == .region ? screenRegion?.region.rect : nil
    let sound = self.sound
    closeSelection()
    phase = .starting
    let id = UUID()
    captureID = id
    clock = RecordingTimeline()
    Task {
      do {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
          throw EditError.message(L("macOS 尚未授权屏幕录制。请在「系统设置 › 隐私与安全性 › 屏幕与系统音频录制」中允许毛咪剪，重新打开应用后再录制。"))
        }
        if sound == .microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
          throw EditError.message(L("请允许麦克风访问，或改用其他录屏声音来源。"))
        }
        let destination = try newRecordingURL(id: id)
        let panel = showHUD(on: screen)
        let filter = try await captureFilter(displayID: displayID, hiding: CGWindowID(panel.windowNumber))
        let crop = rectangle?.intersection(CGRect(origin: .zero, size: filter.contentRect.size))
        if let crop, crop.isNull || crop.width < 16 || crop.height < 16 {
          throw EditError.message(L("录屏范围已超出屏幕，请重新框选。"))
        }
        let task = try ScreenRecordingCapture(filter: filter, crop: crop, sound: sound, url: destination,
          began: { [weak self] time in
            DispatchQueue.main.async {
              guard let self, self.captureID == id else { return }
              self.clock.begin(at: time)
              if self.phase == .starting { self.beginRecording() }
            }
          }, interrupted: { [weak self] error in
            DispatchQueue.main.async {
              guard let self, self.captureID == id else { return }
              self.stop(interruption: error)
            }
          })
        capture = task
        try await task.start()
        guard captureID == id, phase == .starting else { return }
        startTimeout = Task { [weak self] in
          try? await Task.sleep(nanoseconds: 6_000_000_000)
          guard !Task.isCancelled, let self, self.captureID == id, self.phase == .starting else { return }
          self.stop(interruption: EditError.message(L("系统没有送来可录制的画面。请确认录屏权限，并检查所选屏幕是否仍然连接。")))
        }
      } catch {
        guard captureID == id, phase == .starting else { return }
        reset()
        report(error.localizedDescription)
      }
    }
  }

  private func beginRecording() {
    startTimeout?.cancel()
    startTimeout = nil
    phase = .recording
    addStatusItem()
  }

  private func newRecordingURL(id: UUID) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let date = formatter.string(from: Date())
    let name = "\(L("录屏")) \(date)"
    let usual = folder.appendingPathComponent(name).appendingPathExtension("mov")
    if !FileManager.default.fileExists(atPath: usual.path) { return usual }
    return folder.appendingPathComponent(name + " " + id.uuidString.prefix(8)).appendingPathExtension("mov")
  }

  private func showHUD(on screen: NSScreen) -> NSPanel {
    let panel = makePanel(size: CGSize(width: 126, height: 36), nonactivating: true)
    panel.title = L("录屏控制")
    panel.level = .statusBar
    pointerOverHUD = false
    panel.contentView = RecordingHUDHost(rootView: RecordingHUD(recorder: self))
    panel.ignoresMouseEvents = !showTimer
    let visible = screen.visibleFrame
    panel.setFrameOrigin(CGPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - panel.frame.height - 8))
    hud = panel
    panel.orderFrontRegardless()
    return panel
  }

  private func captureFilter(displayID: CGDirectDisplayID, hiding windowID: CGWindowID) async throws -> SCContentFilter {
    let processID = ProcessInfo.processInfo.processIdentifier
    for attempt in 0..<4 {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw EditError.message(L("所选屏幕已断开，请重新选择。"))
      }
      if let controls = content.windows.first(where: { $0.windowID == windowID }) {
        return SCContentFilter(display: display, excludingWindows: [controls])
      }
      if attempt == 3, let app = content.applications.first(where: { $0.processID == processID }) {
        // Some systems omit floating or transparent windows from the shareable list.
        let editorWindows = content.windows.filter { $0.owningApplication?.processID == processID }
        return SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: editorWindows)
      }
      if attempt < 3 { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    throw EditError.message(L("无法将录屏控制浮窗从画面中隐藏，请重试。"))
  }

  fileprivate func elapsedText() -> String {
    let seconds = Int(clock.elapsed(at: RecordingTimeline.now).seconds)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  @objc func togglePause() {
    guard canPause, let capture else { return }
    let pause = phase == .recording
    let now = RecordingTimeline.now
    clock.setPaused(pause, at: now)
    capture.setPaused(pause, at: now)
    phase = pause ? .paused : .recording
    updateStatusIcon()
  }

  @objc func stopRecording() { stop() }

  private func stop(interruption: Error? = nil) {
    guard (canPause || phase == .starting), let capture, let id = captureID else { return }
    let now = RecordingTimeline.now
    clock.setPaused(true, at: now)
    phase = .finishing
    updateStatusIcon()
    capture.stop(at: now) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.captureID == id else { return }
        self.reset()
        NSApp.activate(ignoringOtherApps: true)
        self.editorWindow?.makeKeyAndOrderFront(nil)
        switch result {
        case .success(let url):
          self.saved(url)
          if let interruption {
            self.report(L("录屏已提前结束，已保存现有内容。\n\(interruption.localizedDescription)"))
          }
        case .failure(let error):
          self.report((interruption ?? error).localizedDescription)
        }
      }
    }
  }

  private func reset() {
    startTimeout?.cancel()
    startTimeout = nil
    capture = nil
    captureID = nil
    if let status { NSStatusBar.system.removeStatusItem(status) }
    status = nil
    hud?.orderOut(nil)
    hud = nil
    phase = .idle
  }

  private func report(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    editorWindow?.makeKeyAndOrderFront(nil)
    failed(message)
  }

  private func addStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    status = item
    updateStatusIcon()
  }

  private func updateStatusIcon() {
    let icon = phase == .paused ? "pause.circle.fill" : "record.circle.fill"
    status?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: L("录屏控制"))
    status?.button?.toolTip = L("毛咪剪录屏控制")
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if phase == .finishing {
      menu.addItem(withTitle: L("正在保存录屏…"), action: nil, keyEquivalent: "")
      return
    }
    menu.addItem(withTitle: pauseTitle, action: #selector(togglePause), keyEquivalent: "").target = self
    let timer = menu.addItem(withTitle: L("右上角计时"), action: #selector(toggleTimer), keyEquivalent: "")
    timer.target = self
    timer.state = showTimer ? .on : .off
    menu.addItem(.separator())
    menu.addItem(withTitle: L("停止录屏"), action: #selector(stopRecording), keyEquivalent: "").target = self
  }

  @objc private func toggleTimer() { showTimer.toggle() }
}

private struct RecordingToolbar: View {
  @ObservedObject var recorder: ScreenRecorder

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(L("录制屏幕"), systemImage: "record.circle").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(UI.coral)
        Spacer()
        Tool(symbol: "xmark", label: L("取消"), size: 21, act: recorder.cancelSetup)
          .foregroundStyle(UI.muted).keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 8) {
        PanelSegments(title: L("录屏范围"), options: RecordingArea.allCases, selection: $recorder.area) { $0.title }
          .frame(width: 166)
        if NSScreen.screens.count > 1 {
          Picker(L("屏幕"), selection: $recorder.screenID) {
            ForEach(NSScreen.screens.compactMap { screen in screen.captureID.map { ($0, screen.localizedName) } }, id: \.0) {
              Text($0.1).tag($0.0)
            }
          }.labelsHidden().controlSize(.small)
        } else {
          Text(recorder.area == .region ? L("拖动边框调整范围") : L("录制当前屏幕"))
            .font(.caption).foregroundStyle(UI.muted).lineLimit(1)
        }
        Spacer(minLength: 4)
        Button(L("开始录屏"), action: recorder.start).buttonStyle(PrimaryButton(tint: UI.coral))
          .keyboardShortcut(.defaultAction)
      }
      HStack(spacing: 12) {
        Toggle(L("右上角计时"), isOn: $recorder.showTimer).fixedSize()
        Picker(L("声音"), selection: $recorder.sound) {
          ForEach(RecordingSound.available, id: \.self) { Text($0.title).tag($0) }
        }.fixedSize()
        Spacer()
        Button { recorder.chooseFolder() } label: {
          Label(recorder.folder.lastPathComponent, systemImage: "folder").lineLimit(1)
        }.buttonStyle(QuietButton()).help(recorder.folder.path).accessibilityLabel(L("选择录屏保存文件夹"))
      }.font(.caption).controlSize(.small).foregroundStyle(UI.muted)
    }.padding(.horizontal, 14).frame(width: 554, height: 129)
      .background(UI.panel, in: RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(UI.well, lineWidth: 1).allowsHitTesting(false) }
      .foregroundStyle(.white).preferredColorScheme(.dark)
  }
}

private struct RecordingHUD: View {
  @ObservedObject var recorder: ScreenRecorder

  var body: some View {
    HStack(spacing: 5) {
      if recorder.showTimer {
        if recorder.pointerOverHUD && recorder.canPause {
          Tool(symbol: recorder.pauseIcon, label: recorder.pauseTitle, size: 22, act: recorder.togglePause)
            .foregroundStyle(UI.mint)
          Tool(symbol: "stop.fill", label: L("停止录屏"), size: 22, act: recorder.stopRecording)
            .foregroundStyle(UI.coral)
        } else {
          Image(systemName: recorder.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
            .foregroundStyle(recorder.phase == .paused ? UI.buttonTint : UI.coral)
            .accessibilityLabel(recorder.phase == .paused ? L("录屏已暂停") : L("正在录屏"))
        }
        Spacer(minLength: 0)
        if recorder.phase == .starting {
          Text(L("等待画面…")).lineLimit(1)
        } else if recorder.phase == .finishing {
          Text(L("正在保存…")).lineLimit(1)
        } else {
          TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let duration = recorder.elapsedText()
            Text(duration).monospacedDigit().accessibilityLabel(L("录制时间")).accessibilityValue(duration)
          }
        }
      }
    }.font(.system(size: 12, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 9).frame(width: 126, height: 36)
      .background(recorder.showTimer ? UI.deep : .clear, in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9).strokeBorder(recorder.showTimer ? UI.well : .clear, lineWidth: 1)
          .allowsHitTesting(false)
      }.foregroundStyle(.white)
  }
}

private final class RecordingHUDHost: NSHostingView<RecordingHUD> {
  private var tracking: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    // The controls must still respond while the recorded app owns keyboard focus.
    let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { rootView.recorder.pointerOverHUD = true }
  override func mouseExited(with event: NSEvent) { rootView.recorder.pointerOverHUD = false }
}
