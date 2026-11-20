import AppKit
import SwiftUI

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
  let e = Editor()
  var window: NSWindow!, monitor: Any?
  var deferredURL: URL?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let view = Workspace(e: e)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1190, height: 770),
      styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = AppLanguage.appName
    e.workspaceWindow = window
    window.minSize = NSSize(width: 880, height: 640)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(rootView: view)
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("FramecutWorkspace")
    menus()
    DispatchQueue.global(qos: .utility).async { try? MediaScratch.shared.cleanAbandoned() }
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
      if e.offerRecovery() { deferredURL = nil }
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
        if self.e.pathDrawingID != nil {
          self.e.cancelPathDrawing()
          return nil
        }
        if self.e.cropID != nil {
          self.e.cropID = nil
          return nil
        }
        guard self.e.regionTool != nil else { return event }
        self.e.regionTool = nil
      case 49:
        guard !event.modifierFlags.contains(.shift), self.window.attachedSheet == nil else { return event }
        if !event.isARepeat { self.togglePlayback() }
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
  func applicationWillTerminate(_ notification: Notification) {
    e.automaticCaptions.cancel()
    MediaScratch.shared.close()
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
    let app = menu(AppLanguage.appName)
    add(app, L("关于毛咪剪"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    add(app, L("缓存管理…"), #selector(cachePanel), target: self)
    let language = NSMenu(title: L("语言"))
    for choice in AppLanguage.allCases {
      let item = NSMenuItem(title: choice.menuTitle, action: #selector(changeLanguage(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = choice.rawValue
      item.state = choice == AppLanguage.current ? .on : .off
      language.addItem(item)
    }
    let languageMenu = NSMenuItem(title: L("语言"), action: nil, keyEquivalent: "")
    languageMenu.submenu = language
    app.addItem(languageMenu)
    app.addItem(.separator())
    add(app, L("隐藏毛咪剪"), #selector(NSApplication.hide(_:)), "h")
    add(app, L("退出毛咪剪"), #selector(NSApplication.terminate(_:)), "q")
    let file = menu(L("文件"))
    add(file, L("新建工程"), #selector(newFile), "n", target: self)
    add(file, L("打开工程…"), #selector(openFile), "o", target: self)
    add(file, L("保存"), #selector(saveFile), "s", target: self)
    add(file, L("另存为…"), #selector(saveAs), "s", shift: true, target: self)
    file.addItem(.separator())
    add(file, L("导入图片和音视频…"), #selector(media), "i", target: self)
    add(file, L("导入 SRT…"), #selector(subIn), target: self)
    file.addItem(.separator())
    add(file, L("导出 MP4…"), #selector(render), "e", target: self)
    add(file, L("仅导出音频（M4A）…"), #selector(audioOut), target: self)
    add(file, L("仅导出字幕（SRT）…"), #selector(subOut), target: self)
    add(file, L("导出音频和字幕…"), #selector(audioAndSubtitleOut), target: self)
    let edit = menu(L("编辑"))
    add(edit, L("撤销"), #selector(undoEdit), "z", target: self)
    add(edit, L("重做"), #selector(redoEdit), "z", shift: true, target: self)
    edit.addItem(.separator())
    add(edit, L("剪切"), #selector(cutSelection(_:)), "x", target: self)
    add(edit, L("复制"), #selector(copySelection(_:)), "c", target: self)
    add(edit, L("粘贴"), #selector(pasteSelection(_:)), "v", target: self)
    add(edit, L("全选"), #selector(selectItems), "a", target: self)
    edit.addItem(.separator())
    add(edit, L("播放 / 暂停（空格）"), #selector(togglePlayback), target: self)
    add(edit, L("在播放头分割"), #selector(split), "b", target: self)
    add(edit, L("批量切割…"), #selector(batchCut), "b", shift: true, target: self)
    add(edit, L("编组"), #selector(groupClips), "g", target: self)
    add(edit, L("取消编组"), #selector(ungroupClips), "g", shift: true, target: self)
    let win = menu(L("窗口"))
    add(win, L("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")
    add(win, L("缩放"), #selector(NSWindow.performZoom(_:)))
    NSApp.windowsMenu = win
  }
  @objc func newFile() { e.new() }
  @objc func openFile() { e.open() }
  @objc func saveFile() { e.save() }
  @objc func saveAs() { e.save(as: true) }
  @objc func media() { e.importPanel() }
  @objc func subIn() { e.subtitleImport() }
  @objc func subOut() { e.subtitleExport() }
  @objc func audioOut() { e.audioExport() }
  @objc func audioAndSubtitleOut() { e.audioAndSubtitleExport() }
  @objc func render() { e.export() }
  @objc func changeLanguage(_ item: NSMenuItem) {
    guard let value = item.representedObject as? String, let choice = AppLanguage(rawValue: value),
      choice != AppLanguage.current, window.attachedSheet == nil else { return }
    let wasReady = e.status == L("就绪")
    choice.select()
    if wasReady { e.status = L("就绪") }
    window.title = AppLanguage.appName
    window.contentView = NSHostingView(rootView: Workspace(e: e))
    menus()
  }
  @objc func cachePanel() {
    guard window.attachedSheet == nil else { return }
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 164),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = L("缓存管理")
    sheet.appearance = NSAppearance(named: .darkAqua)
    sheet.contentView = NSHostingView(rootView: CachePanel { [weak self, weak sheet] in
      if let sheet { self?.window.endSheet(sheet) }
    })
    window.beginSheet(sheet) { _ in sheet.contentView = nil }
  }
  @objc func undoEdit() { e.undo() }
  @objc func redoEdit() { e.redo() }
  @objc func togglePlayback() { e.play() }
  private var textEditor: NSText? { NSApp.keyWindow?.firstResponder as? NSText }
  @objc func cutSelection(_ sender: Any?) {
    if let textEditor { textEditor.cut(sender) }
    else if window.isKeyWindow { e.cutClips() }
  }
  @objc func copySelection(_ sender: Any?) {
    if let textEditor { textEditor.copy(sender) }
    else if window.isKeyWindow { e.copyClips() }
  }
  @objc func pasteSelection(_ sender: Any?) {
    if let textEditor { textEditor.paste(sender) }
    else if window.isKeyWindow { e.pasteClips() }
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(togglePlayback): return window.isKeyWindow && window.attachedSheet == nil && e.p.duration > 0
    case #selector(render): return e.progress == nil && e.p.duration > 0
    case #selector(audioOut): return e.progress == nil && e.canExportAudio
    case #selector(subOut): return e.progress == nil && e.canExportSubtitles
    case #selector(audioAndSubtitleOut): return e.progress == nil && e.canExportAudio && e.canExportSubtitles
    case #selector(cutSelection(_:)):
      if let textEditor { return textEditor.isEditable && textEditor.selectedRange.length > 0 }
      return window.isKeyWindow && e.canCopyClips
    case #selector(copySelection(_:)):
      if let textEditor { return textEditor.selectedRange.length > 0 }
      return window.isKeyWindow && e.canCopyClips
    case #selector(pasteSelection(_:)):
      if let textEditor { return textEditor.isEditable && NSPasteboard.general.string(forType: .string) != nil }
      return window.isKeyWindow && e.canPasteClips
    default: return true
    }
  }
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
      throw EditError.message(L("分辨率应为 360、540、720 或 1080。"))
    }
    try ExportJob().run(project, to: URL(fileURLWithPath: args[3]), short: resolution) { _ in }
    MediaScratch.shared.close()
    exit(0)
  }
  if args.count == 3, args[1] == "--check" {
    let p = try Project.read(from: URL(fileURLWithPath: args[2]))
    let result = try buildComposition(p, short: 540)
    print(
      "frames=\(p.duration) instructions=\(result.video.instructions.count) tracks=\(result.asset.tracks.count)"
    )
    MediaScratch.shared.close()
    exit(0)
  }
  let app = NSApplication.shared
  let delegate = Delegate()
  app.setActivationPolicy(.regular)
  app.delegate = delegate
  app.run()
} catch {
  MediaScratch.shared.close()
  FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
