import AppKit
import SwiftUI

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let e = Editor()
  var window: NSWindow!, monitor: Any?
  var deferredURL: URL?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let view = Workspace(e: e)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1190, height: 770),
      styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "毛咪剪"
    window.minSize = NSSize(width: 880, height: 640)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(rootView: view)
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("FramecutWorkspace")
    menus()
    #if FRAME_BENCH
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { PlaybackProbe.launch(self.e) }
      window.orderBack(nil)
    #elseif INTERACTION_BENCH
      window.orderBack(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        InteractionProbe(self.e, self.window).start()
      }
    #else
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    #endif
    if let u = deferredURL {
      e.open(u)
      deferredURL = nil
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.window.isKeyWindow, NSApp.modalWindow == nil,
        !(self.window.firstResponder is NSTextView),
        event.modifierFlags.intersection([.command, .option, .control]).isEmpty
      else { return event }
      switch event.keyCode {
      case 53:
        if self.e.timelineMarquee.cancel() || self.e.libraryMarquee.cancel() { return nil }
        if self.e.cropID != nil {
          self.e.cropID = nil
          return nil
        }
        guard self.e.regionTool != nil else { return event }
        self.e.regionTool = nil
      case 49: self.e.play()
      case 51, 117:
        if self.e.libraryFocus && self.e.toolTab == .media { return event }
        if event.modifierFlags.contains(.shift) { self.e.ripple() } else { self.e.remove() }
      case 123:
        self.e.seek(self.e.transport.frame - (event.modifierFlags.contains(.shift) ? 30 : 1))
      case 124:
        self.e.seek(self.e.transport.frame + (event.modifierFlags.contains(.shift) ? 30 : 1))
      default: return event
      }
      return nil
    }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let u = urls.first else { return }
    if window == nil { deferredURL = u } else { e.open(u) }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    e.mayLeave() ? .terminateNow : .terminateCancel
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }
  func menus() {
    let bar = NSMenu()
    NSApp.mainMenu = bar
    func menu(_ name: String) -> NSMenu {
      let item = NSMenuItem()
      bar.addItem(item)
      let m = NSMenu(title: name)
      item.submenu = m
      return m
    }
    func add(
      _ m: NSMenu, _ name: String, _ s: Selector, _ key: String = "", shift: Bool = false,
      target: AnyObject? = nil
    ) {
      let item = NSMenuItem(title: name, action: s, keyEquivalent: key)
      item.target = target
      item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
      m.addItem(item)
    }
    let app = menu("毛咪剪")
    add(app, "关于毛咪剪", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    app.addItem(.separator())
    add(app, "隐藏毛咪剪", #selector(NSApplication.hide(_:)), "h")
    add(app, "退出毛咪剪", #selector(NSApplication.terminate(_:)), "q")
    let file = menu("文件")
    add(file, "新建工程", #selector(newFile), "n", target: self)
    add(file, "打开工程…", #selector(openFile), "o", target: self)
    add(file, "保存", #selector(saveFile), "s", target: self)
    add(file, "另存为…", #selector(saveAs), "s", shift: true, target: self)
    file.addItem(.separator())
    add(file, "导入图片和音视频…", #selector(media), "i", target: self)
    add(file, "导入 SRT…", #selector(subIn), target: self)
    add(file, "导出 SRT…", #selector(subOut), target: self)
    add(file, "导出 MP4…", #selector(render), "e", target: self)
    let edit = menu("编辑")
    add(edit, "撤销", #selector(undoEdit), "z", target: self)
    add(edit, "重做", #selector(redoEdit), "z", shift: true, target: self)
    edit.addItem(.separator())
    add(edit, "剪切", #selector(NSText.cut(_:)), "x")
    add(edit, "复制", #selector(NSText.copy(_:)), "c")
    add(edit, "粘贴", #selector(NSText.paste(_:)), "v")
    add(edit, "全选", #selector(selectItems), "a", target: self)
    edit.addItem(.separator())
    add(edit, "在播放头分割", #selector(split), "b", target: self)
    add(edit, "批量切割…", #selector(batchCut), "b", shift: true, target: self)
    add(edit, "编组", #selector(groupClips), "g", target: self)
    add(edit, "取消编组", #selector(ungroupClips), "g", shift: true, target: self)
    let win = menu("窗口")
    add(win, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(win, "缩放", #selector(NSWindow.performZoom(_:)))
    NSApp.windowsMenu = win
  }
  @objc func newFile() { e.new() }
  @objc func openFile() { e.open() }
  @objc func saveFile() { e.save() }
  @objc func saveAs() { e.save(as: true) }
  @objc func media() { e.importPanel() }
  @objc func subIn() { e.subtitleImport() }
  @objc func subOut() { e.subtitleExport() }
  @objc func render() { e.export() }
  @objc func undoEdit() { e.undo() }
  @objc func redoEdit() { e.redo() }
  @objc func selectItems() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
      text.selectAll(nil)
    } else {
      e.selectAllItems()
    }
  }
  @objc func split() { e.split() }
  @objc func batchCut() { e.batchCut() }
  @objc func groupClips() { e.groupSelection() }
  @objc func ungroupClips() { e.ungroupSelection() }
}
do {
  let args = CommandLine.arguments
  if args.count >= 4, args[1] == "--render" {
    let project = try Project.read(from: URL(fileURLWithPath: args[2]))
    let resolution = args.count > 4 ? Int(args[4]) ?? 1080 : 1080
    guard [360, 540, 720, 1080].contains(resolution) else {
      throw EditError.message("分辨率应为 360、540、720 或 1080。")
    }
    try ExportJob().run(project, to: URL(fileURLWithPath: args[3]), short: resolution) { _ in }
    exit(0)
  }
  if args.count == 3, args[1] == "--check" {
    let p = try Project.read(from: URL(fileURLWithPath: args[2]))
    let result = try buildComposition(p, short: 540)
    print(
      "frames=\(p.duration) instructions=\(result.video.instructions.count) tracks=\(result.asset.tracks.count)"
    )
    exit(0)
  }
  let app = NSApplication.shared
  let delegate = Delegate()
  app.setActivationPolicy(.regular)
  app.delegate = delegate
  app.run()
} catch {
  FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
