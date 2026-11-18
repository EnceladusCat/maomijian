import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class Transport: ObservableObject {
  @Published var frame = 0
  @Published var playing = false
}
final class ShelfState: ObservableObject {
  let tabs = CurrentValueSubject<ToolTab, Never>(.media)
  var toolTab: ToolTab {
    get { tabs.value }
    set { if tabs.value != newValue { tabs.send(newValue) } }
  }
  @Published var transitionSection = TransitionSection.blur
  @Published var targetJoinID: UUID?
  @Published var transitionFrames = 15
  @Published var transitionStyle = TransitionLook.slide
  @Published var dropJoin: UUID?
  @Published var targetEdge: EdgeTarget?
  @Published var dropEdge: EdgeTarget?
}
final class PanelUpdates: ObservableObject {
  private var subscriptions = Set<AnyCancellable>()
  private var stale = false
  init(editor: Editor, tab: ToolTab) {
    let changed: () -> Void = { [weak self, weak editor] in
      guard let self, let editor else { return }
      if editor.toolTab == tab { self.objectWillChange.send() } else { self.stale = true }
    }
    editor.$p.dropFirst().sink { [weak editor] next in
      guard let editor else { return }
      let previous = editor.p
      switch tab {
      case .captions:
        if next.captionStyle != previous.captionStyle { changed() }
      case .filters:
        if previous.clips.filter({ $0.kind == .video }) != next.clips.filter({ $0.kind == .video })
        {
          changed()
        }
      case .media:
        if next.assets != previous.assets { changed() }
      case .transitions:
        let slide = editor.shelf.transitionSection == .slide
        if next.assets != previous.assets
          || (slide
            ? previous.clips != next.clips
            : previous.clips.filter { $0.kind == .video } != next.clips.filter { $0.kind == .video })
        {
          changed()
        }
      default: break
      }
    }.store(in: &subscriptions)
    if tab == .media {
      editor.$libraryIDs.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
      editor.$thumbnails.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
    }
    if tab == .filters {
      editor.$selectedIDs.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
    }
    if tab == .transitions {
      editor.$selectedIDs.dropFirst().sink { [weak editor] _ in
        if editor?.shelf.transitionSection != .blur { changed() }
      }.store(in: &subscriptions)
    }
    editor.shelf.tabs.sink { [weak self] next in
      if let self, next == tab, self.stale {
        self.stale = false
        self.objectWillChange.send()
      }
    }.store(in: &subscriptions)
  }
}
final class PreviewStatus: ObservableObject {
  @Published var busy = false
  @Published var message = "就绪"
}
final class Editor: ObservableObject {
  @Published var p = Project()
  let shelf = ShelfState()
  private var panelObservers = [ToolTab: PanelUpdates]()
  func panelUpdates(_ tab: ToolTab) -> PanelUpdates {
    if let existing = panelObservers[tab] { return existing }
    let observer = PanelUpdates(editor: self, tab: tab)
    panelObservers[tab] = observer
    return observer
  }
  var toolTab: ToolTab { shelf.toolTab }
  var dropBands: [DropBand] = []
  @Published var drawShape = RegionShape.rectangle
  @Published var regionTool: Kind?
  @Published var cropID: UUID?
  @Published private(set) var mediaSizes = [UUID: CGSize]()
  private var pendingAudition: Range<Int>?
  private var auditionEnd: Int?
  private var scrubSession: UUID?
  private var scrubFrame: Int?
  private var seekInFlight = false
  @Published var selectedIDs: [UUID] = []
  @Published var libraryIDs: [UUID] = []
  var libraryFocus = false
  private var timelineAnchor: UUID?, libraryAnchor: UUID?
  var selected: UUID? {
    get { selectedIDs.last }
    set {
      libraryFocus = false
      timelineAnchor = newValue
      let ids = newValue.map { [$0] } ?? []
      if selectedIDs != ids { selectedIDs = ids }
    }
  }
  var selectedClips: [Clip] {
    let ids = Set(selectedIDs)
    return p.clips.filter { ids.contains($0.id) }
  }
  private func selection(
    _ id: UUID, in order: [UUID], current: [UUID],
    anchor: inout UUID?, modifiers: NSEvent.ModifierFlags
  ) -> [UUID] {
    if modifiers.contains(.shift), let anchor, let a = order.firstIndex(of: anchor),
      let b = order.firstIndex(of: id)
    {
      let range = Array(order[min(a, b)...max(a, b)])
      return modifiers.contains(.command) ? current + range.filter { !current.contains($0) } : range
    }
    anchor = id
    if modifiers.contains(.command) {
      return current.contains(id) ? current.filter { $0 != id } : current + [id]
    }
    return [id]
  }
  func pickClip(_ id: UUID, lane: [UUID], modifiers: NSEvent.ModifierFlags) {
    libraryFocus = false
    let order =
      timelineAnchor.map(lane.contains) == true
      ? lane : p.clips.sorted { $0.start < $1.start }.map(\.id)
    let next = selection(
      id, in: order, current: selectedIDs, anchor: &timelineAnchor, modifiers: modifiers)
    if selectedIDs != next { selectedIDs = next }
  }
  func pickAsset(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
    libraryFocus = true
    libraryIDs = selection(
      id, in: p.assets.map(\.id), current: libraryIDs, anchor: &libraryAnchor, modifiers: modifiers)
  }
  let timelineMarquee = MarqueeSelection()
  let libraryMarquee = MarqueeSelection()
  func pickMarquee(_ hits: [UUID], modifiers: NSEvent.ModifierFlags, inLibrary: Bool) {
    let current = inLibrary ? libraryIDs : selectedIDs
    let existing = Set(current)
    let next: [UUID]
    if modifiers.contains(.command) {
      let hitIDs = Set(hits)
      next = current.filter { !hitIDs.contains($0) } + hits.filter { !existing.contains($0) }
    } else if modifiers.contains(.shift) {
      next = current + hits.filter { !existing.contains($0) }
    } else {
      next = hits
    }
    libraryFocus = inLibrary
    if inLibrary {
      libraryAnchor = next.last
      if libraryIDs != next { libraryIDs = next }
    } else {
      timelineAnchor = next.last
      if selectedIDs != next { selectedIDs = next }
    }
  }
  func selectAllItems() {
    if libraryFocus && toolTab == .media {
      libraryIDs = p.assets.map(\.id)
      libraryAnchor = libraryIDs.first
    } else {
      selectedIDs = p.clips.map(\.id)
      timelineAnchor = selectedIDs.first
      libraryFocus = false
    }
  }
  @Published var url: URL?
  @Published var error: String?
  let previewStatus = PreviewStatus()
  var status: String {
    get { previewStatus.message }
    set { if previewStatus.message != newValue { previewStatus.message = newValue } }
  }
  var busy: Bool {
    get { previewStatus.busy }
    set { if previewStatus.busy != newValue { previewStatus.busy = newValue } }
  }
  @Published var preview = 1080
  @Published var progress: Double?
  @Published var exportShort = 1080
  private var exportSettings = ExportSettings()
  @Published var thumbnails = [UUID: NSImage]()
  let transport = Transport(), player = AVPlayer()
  private var baseline = Project(), undoStack = [Project](), redoStack = [Project](),
    observer: Any?, itemObservation: NSKeyValueObservation?
  private var graphSnapshot: Project?, previewGraph: MediaGraph?
  private var buildTicket: Progress?
  private var playWhenReady = false
  private var revision = 0, generation = UUID(), pending: DispatchWorkItem?, job: ExportJob?
  private let queue = DispatchQueue(label: "framecut.preview", qos: .userInitiated)
  var clip: Clip? { p.clips.first { $0.id == selected } }
  var dirty: Bool { p != baseline }
  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }
  init() {
    player.actionAtItemEnd = .pause
    observer = player.addPeriodicTimeObserver(forInterval: time(2), queue: .main) { [weak self] t in
      guard let self, self.transport.playing, !self.playWhenReady, t.seconds.isFinite else {
        return
      }
      let f = Int((t.seconds * 30).rounded())
      if let end = self.auditionEnd, f >= end {
        self.seek(end)
        return
      }
      self.transport.frame = bound(f, 0, self.p.duration)
      if self.player.rate == 0 && f >= self.p.duration - 2 { self.transport.playing = false }
    }
    NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] note in
      if let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem {
        self.transport.playing = false
        self.transport.frame = self.p.duration
      }
    }
  }
  func pause() {
    playWhenReady = false
    scrubSession = nil
    scrubFrame = nil
    seekInFlight = false
    auditionEnd = nil
    pendingAudition = nil
    if player.rate != 0 || transport.playing { player.pause() }
    if transport.playing { transport.playing = false }
  }
  func seek(_ f: Int) {
    pause()
    transport.frame = bound(f, 0, p.duration)
    position()
  }
  // Keep a single decode in flight while dragging. A release or a transport
  // command invalidates its callback and seeks the exact requested frame.
  func scrub(_ frame: Int) {
    guard player.currentItem != nil else {
      seek(frame)
      return
    }
    if scrubSession == nil {
      pause()
      scrubSession = UUID()
    }
    let next = bound(frame, 0, p.duration)
    if transport.frame != next { transport.frame = next }
    scrubFrame = min(next, max(0, p.duration - 1))
    if !seekInFlight { seekLatestScrub() }
  }
  private func seekLatestScrub() {
    guard let session = scrubSession, let item = player.currentItem, let frame = scrubFrame else {
      return
    }
    scrubFrame = nil
    seekInFlight = true
    player.seek(to: time(frame), toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak item] _ in
      DispatchQueue.main.async {
        guard let self, self.scrubSession == session, self.player.currentItem === item else {
          return
        }
        self.seekInFlight = false
        if self.scrubFrame == frame { self.scrubFrame = nil }
        if self.scrubFrame != nil { self.seekLatestScrub() }
      }
    }
  }
  private func position() {
    player.seek(
      to: time(min(transport.frame, max(0, p.duration - 1))), toleranceBefore: .zero,
      toleranceAfter: .zero)
  }
  func play() {
    if scrubSession != nil { seek(transport.frame) }
    if transport.playing {
      pause()
      return
    }
    guard p.duration > 0 else { return }
    if busy {
      playWhenReady = true
      transport.playing = true
      return
    }
    guard player.currentItem != nil else { return }
    if transport.frame >= p.duration - 1 { seek(0) }
    transport.playing = true
    player.play()
  }
  func change(_ body: (inout Project) -> Void) {
    var next = p
    body(&next)
    guard next != p else { return }
    do { _ = try next.checked() } catch {
      self.error = error.localizedDescription
      return
    }
    undoStack.append(p)
    if undoStack.count > 80 { undoStack.removeFirst() }
    redoStack.removeAll()
    install(next)
  }
  private func install(_ next: Project) {
    pause()
    p = next
    let valid = Set(next.clips.map(\.id))
    let assets = Set(next.assets.map(\.id))
    if let cropID, !valid.contains(cropID) { self.cropID = nil }
    if !selectedIDs.allSatisfy(valid.contains) { selectedIDs.removeAll { !valid.contains($0) } }
    if !libraryIDs.allSatisfy(assets.contains) { libraryIDs.removeAll { !assets.contains($0) } }
    if transport.frame > p.duration { transport.frame = p.duration }
    rebuild()
  }
  func undo() {
    guard let back = undoStack.popLast() else { return }
    redoStack.append(p)
    install(back)
  }
  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(p)
    install(next)
  }
  func rebuild() {
    pause()
    pending?.cancel()
    buildTicket?.cancel()
    let ticket = Progress(totalUnitCount: 1)
    buildTicket = ticket
    revision += 1
    let n = revision
    let snap = p
    let short = preview
    if snap.duration == 0 {
      previewGraph = nil
      graphSnapshot = nil
      player.replaceCurrentItem(with: nil)
      busy = false
      status = "就绪"
      return
    }
    let reuse = graphSnapshot.flatMap { previous -> MediaGraph? in
      guard previous.duration == snap.duration && previous.assets == snap.assets else { return nil }
      let before = previous.clips.filter { $0.kind.isMedia }
      let after = snap.clips.filter { $0.kind.isMedia }
      return before.count == after.count && zip(before, after).allSatisfy { $0.sameSource(as: $1) }
        ? previewGraph : nil
    }
    busy = true
    if reuse == nil { status = "正在准备预览" }
    let existingItem = reuse == nil ? nil : player.currentItem
    let work = DispatchWorkItem { [weak self] in
      let result = Result {
        try buildComposition(
          snap, short: short, preview: true, reusing: reuse, cancelled: { ticket.isCancelled })
      }
      if let existingItem, case .success(let composition) = result, !ticket.isCancelled {
        existingItem.videoComposition = composition.video
      }
      DispatchQueue.main.async {
        guard let self, self.revision == n else { return }
        self.busy = false
        switch result {
        case .success(let composition):
          self.graphSnapshot = snap
          self.previewGraph = composition.graph
          if let existingItem, existingItem === self.player.currentItem {
            self.position()
            self.didPrepare()
            return
          }
          let item = composition.item()
          self.player.replaceCurrentItem(with: item)
          self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
              DispatchQueue.main.async {
                guard let self, self.revision == n else { return }
                self.status = "预览失败"
                self.error = item.error?.localizedDescription ?? "系统无法解码该媒体。"
              }
            }
          }
          self.position()
          self.status = "就绪"
          self.didPrepare()
        case .failure(let e):
          self.previewGraph = nil
          self.graphSnapshot = nil
          self.pause()
          self.player.replaceCurrentItem(with: nil)
          self.status = "预览未就绪"
          self.error = e.localizedDescription
        }
      }
    }
    pending = work
    queue.async(execute: work)
  }
  private func didPrepare() {
    if playWhenReady {
      playWhenReady = false
      player.play()
    } else if let range = pendingAudition {
      previewTransition(range)
    }
  }
  func edit(_ id: UUID, _ body: (inout Clip) -> Void) {
    change { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { body(&p.clips[i]) } }
  }
  func beginCrop(_ c: Clip) {
    guard c.kind == .video else { return }
    regionTool = nil
    if cropID == c.id {
      cropID = nil
      return
    }
    pause()
    if !(c.start..<c.end).contains(transport.frame) { seek(c.start) }
    cropID = c.id
  }
  func applyFilter(_ look: FootageFilter) {
    let ids = Set(selectedIDs)
    change { project in
      for i in project.clips.indices
      where ids.contains(project.clips[i].id) && project.clips[i].kind == .video {
        project.clips[i].footageFilter = look == .none ? nil : look
      }
    }
    if let clip = selectedClips.first(where: { $0.kind == .video }),
      !selectedClips.contains(where: {
        $0.kind == .video && ($0.start..<$0.end).contains(transport.frame)
      })
    {
      seek(clip.start)
    }
  }
  func add(_ kind: Kind) {
    if cropID != nil { cropID = nil }
    pause()
    if regionTool != nil { regionTool = nil }
    if kind.isRegion {
      regionTool = kind
      return
    }
    let start = transport.frame
    var c = Clip.annotation(kind, at: start)
    c.length = min(c.length, maxFrames - start)
    change { $0.clips.append(c) }
    selected = c.id
  }
  func append(_ asset: Media, at start: Int) { insertAssets([asset], at: start) }
  func insertAssets(_ assets: [Media], at start: Int) {
    guard !assets.isEmpty else { return }
    var cursor = start
    var clips: [Clip] = []
    for asset in assets {
      guard asset.frames <= maxFrames - cursor else {
        error = "素材超出工程时长上限。"
        return
      }
      clips.append(
        Clip(
          kind: asset.video ? .video : .audio, asset: asset.id, start: cursor, length: asset.frames)
      )
      cursor += asset.frames
    }
    change { project in
      for asset in assets where project.asset(asset.id) == nil { project.assets.append(asset) }
      project.clips += clips
    }
    selectedIDs = clips.map(\.id)
    timelineAnchor = selectedIDs.first
    libraryFocus = false
    seek(start)
  }
  func insertSound(_ sound: BuiltInSound) {
    guard let url = sound.url else {
      error = "找不到内置音效 " + sound.rawValue
      return
    }
    let asset =
      p.assets.first { $0.soundID == sound.rawValue }
      ?? Media(
        path: url.path, frames: sound.frames, video: false, audio: true, soundID: sound.rawValue)
    append(asset, at: transport.frame)
  }
  var canBatchCut: Bool {
    !selectedIDs.isEmpty && selectedClips.allSatisfy { $0.kind.isMedia }
  }
  func batchCut() {
    guard canBatchCut, let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
    pause()
    let snapshot = p
    let clips = selectedClips.sorted { $0.start < $1.start }
    let draft = BatchCutDraft(project: snapshot, clips: clips)
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 850, height: 530),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    sheet.minSize = CGSize(width: 840, height: 480)
    sheet.appearance = NSAppearance(named: .darkAqua)
    sheet.title = "批量切割"
    let cancel = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
    sheet.contentView = NSHostingView(
      rootView: BatchCutPanel(draft: draft, cancel: cancel) { plan in
        guard self.p == snapshot else {
          draft.message = "工程已改动，请重新打开批量切割。"
          return
        }
        do {
          let edited = try snapshot.applying(plan)
          self.change { $0 = edited.project }
          self.selectedIDs = edited.selected
          self.timelineAnchor = edited.selected.first
          self.libraryFocus = false
          cancel()
        } catch { draft.message = error.localizedDescription }
      })
    window.beginSheet(sheet) { _ in sheet.contentView = nil }
  }
  func split() {
    let f = transport.frame
    let ids = selectedClips.filter { $0.start < f && f < $0.end }.map(\.id)
    guard !ids.isEmpty else {
      status = "请把播放头移到所选片段的中间"
      return
    }
    var pieces: [UUID] = selectedIDs.filter { !ids.contains($0) }
    change { project in pieces += ids.compactMap { project.cut($0, at: f) } }
    selectedIDs = pieces
    timelineAnchor = pieces.last
  }
  func remove() {
    let ids = Set(selectedIDs)
    guard !ids.isEmpty else { return }
    change {
      $0.clips.removeAll { ids.contains($0.id) }
      for i in $0.clips.indices where $0.clips[i].from.map(ids.contains) == true {
        $0.clips[i].from = nil
      }
    }
  }
  func ripple() {
    let clips = selectedClips.sorted { $0.start < $1.start }
    guard let first = clips.first else { return }
    var ranges: [Range<Int>] = []
    for clip in clips {
      if let last = ranges.last, clip.start <= last.upperBound {
        ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, clip.end)
      } else {
        ranges.append(clip.start..<clip.end)
      }
    }
    change { project in
      for span in ranges.reversed() { project.deleteInterval(span.lowerBound, span.upperBound) }
    }
    seek(first.start)
  }
  func adjustMedia(_ ids: Set<UUID>, rate: Double? = nil, pitch: Double? = nil) {
    var next = p
    do {
      for i in next.clips.indices where ids.contains(next.clips[i].id) && next.clips[i].kind.isMedia
      {
        if let rate, next.asset(next.clips[i].asset)?.isStill != true {
          try next.clips[i].retime(rate)
        }
        if let pitch, next.asset(next.clips[i].asset)?.audio == true {
          next.clips[i].pitchSemitones = pitch == 0 ? nil : pitch
        }
      }
      change { $0 = next }
    } catch { self.error = error.localizedDescription }
  }
  func groupDelta(_ requested: Int) -> Int {
    let clips = selectedClips
    return bound(
      requested, -(clips.map(\.start).min() ?? 0), maxFrames - (clips.map(\.end).max() ?? maxFrames)
    )
  }
  func detach() {
    guard var c = clip, c.kind == .video, c.volume > 0, p.asset(c.asset)?.audio == true else {
      return
    }
    let id = c.id
    c.id = UUID()
    c.kind = .audio
    c.from = nil
    change { p in
      if let i = p.clips.firstIndex(where: { $0.id == id }) {
        p.clips[i].volume = 0
        p.clips.append(c)
      }
    }
    selected = c.id
  }
  func finishRegion(_ rect: CGRect) {
    guard let kind = regionTool else { return }
    regionTool = nil
    var c = Clip.annotation(kind, at: transport.frame)
    c.length = min(c.length, maxFrames - c.start)
    c.regionShape = drawShape
    c.setRegion(drawShape.fit(rect, in: p.canvas.size(540)))
    change { $0.clips.append(c) }
    selected = c.id
  }
  func chooseJoin(_ join: Project.Join) {
    pause()
    regionTool = nil
    shelf.toolTab = .transitions
    shelf.transitionSection = .blur
    shelf.targetEdge = nil
    shelf.targetJoinID = join.id
    if join.active {
      shelf.transitionFrames = join.after.blend
      shelf.transitionStyle = join.after.transitionStyle
    }
  }
  func openTab(_ tab: ToolTab) {
    guard toolTab != tab else { return }
    if tab != .media { libraryMarquee.cancel() }
    libraryFocus = tab == .media
    if regionTool != nil { regionTool = nil }
    if tab == .transitions {
      let joins = p.joins
      if let j = joins.first(where: { $0.id == selected }) ?? joins.first(where: {
        $0.id == shelf.targetJoinID
      }) ?? joins.min(by: { abs($0.frame - transport.frame) < abs($1.frame - transport.frame) }) {
        if shelf.targetJoinID != j.id { shelf.targetJoinID = j.id }
        if j.active {
          if shelf.transitionFrames != j.after.blend { shelf.transitionFrames = j.after.blend }
          if shelf.transitionStyle != j.after.transitionStyle {
            shelf.transitionStyle = j.after.transitionStyle
          }
        }
      }
    }
    shelf.toolTab = tab
  }
  var edgeTarget: EdgeTarget? {
    if let target = shelf.targetEdge,
      p.clips.contains(where: { $0.id == target.clipID && $0.kind == .video })
    {
      return target
    }
    if let c = clip, c.kind == .video { return EdgeTarget(clipID: c.id, end: .head) }
    return p.clips.first(where: { $0.kind == .video }).map { EdgeTarget(clipID: $0.id, end: .head) }
  }
  func chooseEdge(_ target: EdgeTarget) {
    guard let c = p.clips.first(where: { $0.id == target.clipID && $0.kind == .video }) else {
      return
    }
    pause()
    regionTool = nil
    shelf.targetEdge = target
    shelf.transitionSection = .edge
    if let effect = c.effect(at: target.end) {
      shelf.transitionFrames = effect.frames
      shelf.transitionStyle = effect.style
    }
    shelf.toolTab = .transitions
  }
  func edgeTransition(_ target: EdgeTarget, frames: Int, style: TransitionLook? = nil) {
    var next = p
    do {
      try next.setEdgeEffect(target, frames: frames, style: style)
      change { $0 = next }
      chooseEdge(target)
      selected = target.clipID
    } catch { self.error = error.localizedDescription }
  }
  func previewEdge(_ target: EdgeTarget) {
    guard let c = p.clips.first(where: { $0.id == target.clipID }),
      let range = c.transitionRange(at: target.end)
    else { return }
    previewTransition(max(0, range.lowerBound - 7)..<min(p.duration, range.upperBound + 9))
  }
  func applyTransitionCard(_ style: TransitionLook) {
    if shelf.transitionSection == .edge {
      if let edgeTarget {
        edgeTransition(edgeTarget, frames: shelf.transitionFrames, style: style)
      } else {
        status = "请选择图片或视频片段的首端或末端"
      }
      return
    }
    let joins = p.joins
    guard let j = joins.first(where: { $0.id == shelf.targetJoinID }) ?? joins.first else {
      status = "先将两个视频首尾相接，或用 ⌘B 分割视频"
      return
    }
    transition(j.id, frames: shelf.transitionFrames, style: style)
  }
  func previewJoin(_ id: UUID) {
    guard let j = p.joins.first(where: { $0.id == id }), j.active else { return }
    previewTransition(
      max(j.before.start, j.range.lowerBound - 7)..<min(j.after.end, j.range.upperBound + 9))
  }
  private func previewTransition(_ range: Range<Int>) {
    if busy {
      pendingAudition = range
      return
    }
    seek(range.lowerBound)
    auditionEnd = range.upperBound
    play()
  }
  func transition(_ id: UUID, frames: Int, style: TransitionLook? = nil) {
    var next = p
    do {
      shelf.targetJoinID = id
      try next.setTransition(id, frames: frames, style: style)
      change { $0 = next }
      if frames > 0, let updated = p.clips.first(where: { $0.id == id }) {
        if shelf.transitionStyle != updated.transitionStyle {
          shelf.transitionStyle = updated.transitionStyle
        }
        if shelf.transitionFrames != updated.blend { shelf.transitionFrames = updated.blend }
      }
      selected = id

    } catch { self.error = error.localizedDescription }
  }
  func move(_ c: Clip, by delta: Int, edge: Int) {
    if edge == 0, selectedIDs.count > 1, selectedIDs.contains(c.id) {
      let shift = groupDelta(delta)
      let ids = Set(selectedIDs)
      change { project in
        for index in project.clips.indices where ids.contains(project.clips[index].id) {
          project.clips[index].start += shift
        }
      }
      return
    }
    let asset = p.asset(c.asset)
    let timedSource = c.kind.isMedia && asset?.isStill != true
    let maxLen = asset?.frames ?? maxFrames
    edit(c.id) { v in
      if edge < 0 {
        let available = timedSource ? Int(floor(c.sourceIn / c.effectiveRate + 1e-8)) : c.start
        let d = bound(delta, -min(c.start, available), c.length - 1)
        v.start = c.start + d
        v.length = c.length - d
        if c.kind == .timer { v.timerPhase = (c.timerPhase ?? 0) + d }
        if timedSource { v.setSource(c.sourceFrame(at: c.start + d), c.sourceEnd) }
      } else if edge > 0 {
        let maxLength = timedSource ? c.maximumLength(assetFrames: maxLen) : maxFrames - c.start
        v.length = bound(c.length + delta, 1, maxLength)
        if timedSource {
          v.setSource(c.sourceIn, c.sourceIn + Double(v.length) * c.effectiveRate)
        }
      } else {
        v.start = bound(c.start + delta, 0, maxFrames - c.length)
      }
    }
  }
  func loadThumb(_ m: Media) {
    guard m.video else { return }
    DispatchQueue.global(qos: .utility).async {
      let url = URL(fileURLWithPath: m.path)
      let dimensions: CGSize?
      let thumb: CGImage?
      if m.isStill {
        dimensions = StillImages.dimensions(url)
        thumb = StillImages.image(url, limit: 140)
      } else {
        let asset = AVURLAsset(url: url)
        dimensions = asset.tracks(withMediaType: .video).first.map { track in
          CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform).size
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 140, height: 90)
        thumb = try? generator.copyCGImage(at: time(min(10, m.frames / 2)), actualTime: nil)
      }
      DispatchQueue.main.async {
        guard self.p.asset(m.id)?.path == m.path else { return }
        if let dimensions, dimensions.width > 0 && dimensions.height > 0 {
          self.mediaSizes[m.id] = dimensions
        }
        if let thumb { self.thumbnails[m.id] = NSImage(cgImage: thumb, size: .zero) }
      }
    }
  }
  func importPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio, .image]
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { importURLs(panel.urls) }
  }
  func importURLs(_ urls: [URL]) {
    let gen = generation
    DispatchQueue.global(qos: .userInitiated).async {
      let results = urls.map { u in Result { try inspect(u) } }
      DispatchQueue.main.async {
        guard gen == self.generation else { return }
        var errors = [String]()
        var added: UUID?
        var start: Int?
        self.change { p in
          for r in results {
            switch r {
            case .success(var m):
              if let known = p.assets.first(where: { $0.path == m.path }) {
                m = known
              } else {
                p.assets.append(m)
              }
              let kind: Kind = m.video ? .video : .audio
              let end = p.clips.filter { $0.kind == kind }.map(\.end).max() ?? 0
              let c = Clip(kind: kind, asset: m.id, start: end, length: m.frames)
              if start == nil { start = end }
              p.clips.append(c)
              added = c.id
            case .failure(let e): errors.append(e.localizedDescription)
            }
          }
        }
        if let id = added {
          self.selected = id
          self.seek(start ?? 0)
        }
        self.p.assets.filter { self.thumbnails[$0.id] == nil }.forEach { self.loadThumb($0) }
        if !errors.isEmpty { self.error = errors.joined(separator: "\n") }
      }
    }
  }
  func relink(_ m: Media) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio, .image]
    guard panel.runModal() == .OK, let u = panel.url else { return }
    do {
      var replacement = try inspect(u)
      replacement.id = m.id
      let needed =
        p.clips.filter { $0.asset == m.id }.map { Int(ceil($0.sourceEnd - 1e-8)) }.max() ?? 0
      guard replacement.isStill == m.isStill, replacement.isStill || replacement.frames >= needed,
        !m.video || replacement.video,
        !m.audio || replacement.audio
      else { throw EditError.message("替代素材需要包含原有轨道，且时长要覆盖所有剪辑。") }
      change { p in
        if let i = p.assets.firstIndex(where: { $0.id == m.id }) { p.assets[i] = replacement }
      }
      loadThumb(replacement)
    } catch { self.error = error.localizedDescription }
  }
  func subtitleImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
    guard panel.runModal() == .OK, let u = panel.url else { return }
    do {
      let list = try SRT.parse(String(contentsOf: u, encoding: .utf8))
      change { $0.clips += list }
      selected = list.first?.id
      seek(list[0].start)
    } catch { self.error = error.localizedDescription }
  }
  func subtitleExport() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "字幕.srt"
    guard panel.runModal() == .OK, let u = panel.url else { return }
    do { try SRT.write(p.clips).write(to: u, atomically: true, encoding: .utf8) } catch {
      self.error = error.localizedDescription
    }
  }
  @discardableResult func save(as copy: Bool = false) -> Bool {
    var dest = url
    if copy || dest == nil {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [UTType(filenameExtension: "framecut") ?? .json]
      panel.nameFieldStringValue = url?.lastPathComponent ?? "未命名.framecut"
      guard panel.runModal() == .OK, let u = panel.url else { return false }
      dest = u.pathExtension.isEmpty ? u.appendingPathExtension("framecut") : u
    }
    do {
      try p.write(to: dest!)
      url = dest
      baseline = p
      status = "工程已保存"
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func mayLeave() -> Bool {
    if progress != nil {
      error = "正在导出。请等待完成或先取消导出。"
      return false
    }
    guard dirty else { return true }
    let a = NSAlert()
    a.messageText = "保存当前工程？"
    a.informativeText = "关闭前可以将这次剪辑保存为工程文件。"
    a.addButton(withTitle: "保存")
    a.addButton(withTitle: "取消")
    a.addButton(withTitle: "放弃更改")
    switch a.runModal() {
    case .alertFirstButtonReturn: return save()
    case .alertThirdButtonReturn: return true
    default: return false
    }
  }
  private func reset(_ next: Project, _ file: URL?) {
    timelineMarquee.cancel()
    libraryMarquee.cancel()
    graphSnapshot = nil
    previewGraph = nil
    regionTool = nil
    generation = UUID()
    undoStack = []
    redoStack = []
    thumbnails = [:]
    mediaSizes = [:]
    cropID = nil
    libraryIDs = []
    libraryAnchor = nil
    selected = nil
    let firstJoin = next.joins.first
    shelf.targetJoinID = firstJoin?.id
    shelf.targetEdge = nil
    shelf.dropEdge = nil
    shelf.transitionFrames = firstJoin?.active == true ? firstJoin!.after.blend : 15
    shelf.transitionStyle = firstJoin?.active == true ? firstJoin!.after.transitionStyle : .slide
    url = file
    baseline = next
    transport.frame = 0
    install(next)
    next.assets.forEach { loadThumb($0) }
  }
  func new() { if mayLeave() { reset(Project(), nil) } }
  func open() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "framecut") ?? .json, .json]
    if panel.runModal() == .OK, let u = panel.url { open(u) }
  }
  func open(_ u: URL) {
    do {
      let next = try Project.read(from: u)
      if mayLeave() { reset(next, u) }
    } catch { self.error = error.localizedDescription }
  }
  func export() {
    guard progress == nil, p.duration > 0 else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.prompt = "导出"
    if exportSettings.short != exportShort { exportSettings.customMbps = nil }
    exportSettings.short = exportShort
    let options = ExportOptions(settings: exportSettings, project: p)
    let accessory = NSHostingView(
      rootView: ExportAccessory(options: options).preferredColorScheme(.dark))
    accessory.frame = CGRect(x: 0, y: 0, width: 440, height: 181)
    panel.accessoryView = accessory
    panel.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "剪辑") + ".mp4"
    let response = panel.runModal()
    options.cancelSample()
    guard response == .OK, let dest = panel.url else { return }
    guard
      !p.assets.contains(where: {
        URL(fileURLWithPath: $0.path).standardizedFileURL == dest.standardizedFileURL
      })
    else {
      error = "请选择与原素材不同的导出文件名。"
      return
    }
    panel.makeFirstResponder(nil)
    let settings = options.settings
    exportSettings = settings
    exportShort = settings.short
    pause()
    let task = ExportJob()
    let snap = p
    job = task
    progress = 0
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result {
        try task.run(snap, to: dest, settings: settings) { v in
          DispatchQueue.main.async { self.progress = v }
        }
      }
      DispatchQueue.main.async {
        self.progress = nil
        self.job = nil
        switch result {
        case .success:
          self.status = "已导出 " + dest.lastPathComponent
          NSWorkspace.shared.activateFileViewerSelecting([dest])
        case .failure(let e):
          if task.cancelled { self.status = "已取消导出" } else { self.error = e.localizedDescription }
        }
      }
    }
  }
  func cancelExport() { job?.cancel() }
}
