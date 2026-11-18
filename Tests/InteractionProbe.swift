import AVFoundation
import AppKit
import QuartzCore

final class InteractionProbe {
  let e: Editor, window: NSWindow, cfg: [String: String]
  var rows = [[String: Any]](), index = 0
  var begin = 0.0, handler = 0.0, draw = 0.0, ready = 0.0
  var task = "", sawEdit = false
  let steps = ["标注", "转场", "素材", "加箭头", "撤销"]
  init(_ editor: Editor, _ w: NSWindow) {
    e = editor
    window = w
    cfg =
      (try! JSONSerialization.jsonObject(
        with: Data(
          contentsOf: Bundle.main.url(forResource: "InteractionProbe", withExtension: "json")!)))
      as! [String: String]
  }
  func start() {
    e.open(URL(fileURLWithPath: cfg["project"]!))
    waitLoad()
  }
  let timeout = Date().addingTimeInterval(60)
  func fail(_ reason: String) {
    try? JSONSerialization.data(withJSONObject: ["error": reason]).write(
      to: URL(fileURLWithPath: cfg["result"]!), options: .atomic)
    NSApp.terminate(nil)
  }
  func waitLoad() {
    if let reason = e.error {
      fail(reason)
      return
    }
    if Date() > timeout {
      fail("预览初始化超时")
      return
    }
    if e.busy || e.player.currentItem?.status != .readyToPlay {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitLoad() }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.next() }
  }
  func toolButton(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.toolTip == title + "面板" { return button }
    return view.subviews.lazy.compactMap { self.toolButton(title, in: $0) }.first
  }
  func next() {
    if index == steps.count * 4 {
      do {
        try EditingChecks.run()
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: cfg["result"]!), options: .atomic)
        NSApp.terminate(nil)
      } catch { fail(error.localizedDescription) }
      return
    }
    task = steps[index % steps.count]
    sawEdit = (task == "加箭头" || task == "撤销")
    let button = window.contentView.flatMap { toolButton(task, in: $0) }
    begin = CACurrentMediaTime()
    switch task {
    case "加箭头": e.add(.arrow)
    case "撤销": e.undo()
    default:
      guard let button else {
        fail("未找到「" + task + "」按钮")
        return
      }
      _ = button.sendAction(button.action, to: button.target)

    }
    handler = CACurrentMediaTime() - begin
    DispatchQueue.main.async {
      self.window.contentView?.layoutSubtreeIfNeeded()
      self.window.displayIfNeeded()
      CATransaction.flush()
      self.draw = CACurrentMediaTime() - self.begin
      self.settle()
    }
  }
  func settle() {
    if sawEdit && (e.busy || e.player.currentItem?.status != .readyToPlay)
      && CACurrentMediaTime() - begin < 10
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { self.settle() }
      return
    }
    ready = CACurrentMediaTime() - begin
    rows.append([
      "step": task, "rep": index / steps.count, "handlerMs": handler * 1000,
      "layoutMs": draw * 1000, "readyMs": ready * 1000, "clips": e.p.clips.count,
      "tab": e.toolTab.rawValue,
    ])
    index += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.next() }
  }
}
