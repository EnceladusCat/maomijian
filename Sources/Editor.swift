import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class Transport: ObservableObject {
  @Published var frame = 0
  let playback = PreviewPlayback()
  @Published var playing = false {
    didSet { playback.setPlaying(playing) }
  }
}
final class ShelfState: ObservableObject {
  let tabs = CurrentValueSubject<ToolTab, Never>(.media)
  var toolTab: ToolTab {
    get { tabs.value }
    set { if tabs.value != newValue { tabs.send(newValue) } }
  }
  @Published var transitionSection = TransitionSection.effects
  @Published var dropTargets: [TransitionTarget] = []
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
        if editor?.shelf.transitionSection == .slide { changed() }
      }.store(in: &subscriptions)
      editor.$selectedTransition.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
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
  @Published private(set) var selectedTransition: TransitionTarget?
  private(set) var lastTransitionStyle = TransitionLook.dissolve
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
      deselectTransition()
      libraryFocus = false
      timelineAnchor = newValue
      let ids = newValue.map { p.expandingGroups([$0]) } ?? []
      if selectedIDs != ids { selectedIDs = ids }
    }
  }
  var selectedClips: [Clip] {
    let ids = Set(selectedIDs)
    return p.clips.filter { ids.contains($0.id) }
  }
  var isWholeGroupSelected: Bool {
    guard let id = selectedClips.first?.groupID else { return false }
    return selectedClips.allSatisfy { $0.groupID == id }
  }
  var canGroup: Bool { !libraryFocus && selectedIDs.count > 1 && !isWholeGroupSelected }
  var canUngroup: Bool { !libraryFocus && selectedClips.contains { $0.groupID != nil } }
  func groupSelection() {
    guard canGroup else { return }
    change { $0.group(selectedIDs) }
  }
  func ungroupSelection() {
    guard canUngroup else { return }
    change { $0.ungroup(selectedIDs) }
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
    deselectTransition()
    libraryFocus = false
    let order =
      timelineAnchor.map(lane.contains) == true
      ? lane : p.clips.sorted { $0.start < $1.start }.map(\.id)
    let next: [UUID]
    if modifiers.contains(.command), !modifiers.contains(.shift), selectedIDs.contains(id) {
      let members = Set(p.expandingGroups([id]))
      next = selectedIDs.filter { !members.contains($0) }
      timelineAnchor = id
    } else {
      next = p.expandingGroups(selection(
        id, in: order, current: selectedIDs, anchor: &timelineAnchor, modifiers: modifiers))
    }
    if selectedIDs != next { selectedIDs = next }
  }
  func pickAsset(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
    deselectTransition()
    libraryFocus = true
    libraryIDs = selection(
      id, in: p.assets.map(\.id), current: libraryIDs, anchor: &libraryAnchor, modifiers: modifiers)
  }
  let timelineMarquee = MarqueeSelection()
  let libraryMarquee = MarqueeSelection()
  func pickMarquee(_ hits: [UUID], modifiers: NSEvent.ModifierFlags, inLibrary: Bool) {
    deselectTransition()
    let hits = inLibrary ? hits : p.expandingGroups(hits)
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
    deselectTransition()
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
  let waveforms = WaveformStore()
  let transport = Transport(), player = AVPlayer()
  let liveCanvas = LiveCanvasPreview()
  private var baseline = Project(), undoStack = [Project](), redoStack = [Project](),
    observer: Any?, itemObservation: NSKeyValueObservation?
  private var graphSnapshot: Project?, previewGraph: MediaGraph?
  private var previewComposition: Composition?
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
    liveCanvas.clear()
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
      liveCanvas.clear()
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
    liveCanvas.clear()
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
  func change(keepingCanvasFrame: Bool = false, _ body: (inout Project) -> Void) {
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
    install(next, keepingCanvasFrame: keepingCanvasFrame)
  }
  private func install(_ project: Project, keepingCanvasFrame: Bool = false) {
    pause()
    var next = project
    let previous = p.assets == next.assets ? [:] : Dictionary(
      uniqueKeysWithValues: p.assets.map { ($0.id, $0) })
    if !previous.isEmpty {
      for index in next.assets.indices {
        let asset = next.assets[index]
        if !asset.audio, previous[asset.id]?.path == asset.path,
          waveforms.values[asset.id] != nil
        {
          next.assets[index].audio = true
        }
      }
    }
    p = next
    if let target = selectedTransition, next.transitionEffect(target) == nil { deselectTransition() }
    let valid = Set(next.clips.map(\.id))
    let assets = Set(next.assets.map(\.id))
    if let cropID, !valid.contains(cropID) { self.cropID = nil }
    let selection = next.expandingGroups(selectedIDs.filter(valid.contains))
    if selectedIDs != selection { selectedIDs = selection }
    if !libraryIDs.allSatisfy(assets.contains) { libraryIDs.removeAll { !assets.contains($0) } }
    if transport.frame > p.duration { transport.frame = p.duration }
    rebuild(keepingCanvasFrame: keepingCanvasFrame)
    if !previous.isEmpty {
      for asset in next.assets where previous[asset.id] != asset { loadWaveform(asset) }
    }
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
  func rebuild(keepingCanvasFrame: Bool = false) {
    if !keepingCanvasFrame { liveCanvas.clear() }
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
      previewComposition = nil
      liveCanvas.clear()
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
    let playback = transport.playback
    let work = DispatchWorkItem { [weak self] in
      let result = Result {
        try buildComposition(
          snap, short: short, preview: true, reusing: reuse, playback: playback,
          cancelled: { ticket.isCancelled })
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
          self.previewComposition = composition
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
          self.previewComposition = nil
          self.liveCanvas.clear()
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

  func previewCanvas(_ draft: Clip) {
    if transport.playing { pause() }
    guard let previewComposition, !busy else { return }
    liveCanvas.update(draft, frame: transport.frame, composition: previewComposition)
  }

  func commitCanvas(_ draft: Clip) {
    let keep = previewComposition != nil && liveCanvas.activeID == draft.id
    if keep, let previewComposition {
      liveCanvas.end(with: draft, frame: transport.frame, composition: previewComposition)
    }
    let prior = revision
    change(keepingCanvasFrame: keep) { project in
      guard let index = project.clips.firstIndex(where: { $0.id == draft.id }) else { return }
      project.clips[index].x = draft.x
      project.clips[index].y = draft.y
      project.clips[index].angle = draft.angle
      project.clips[index].visualScale = draft.visualScale
      project.clips[index].sourceCrop = draft.sourceCrop
    }
    if prior == revision { liveCanvas.clear() }
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
  func addFilter(_ look: FootageFilter) {
    guard look != .none else { return }
    editSelectedFilters { $0.append(ClipFilter(look: look)) }
  }

  func editSelectedFilters(_ edit: (inout [ClipFilter]) -> Void) {
    let ids = Set(selectedIDs)
    change { project in
      for i in project.clips.indices
      where ids.contains(project.clips[i].id) && project.clips[i].kind == .video {
        var filters = project.clips[i].filters
        edit(&filters)
        if filters != project.clips[i].filters { project.clips[i].filters = filters }
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
    assets.forEach { loadWaveform($0) }
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
          self.selectedIDs = self.p.expandingGroups(edited.selected)
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
    selectedIDs = p.expandingGroups(pieces)
    timelineAnchor = pieces.last
  }
  func remove() {
    if let selectedTransition {
      editTransition(selectedTransition, frames: 0)
      return
    }
    let ids = Set(selectedIDs)
    guard !ids.isEmpty else { return }
    change {
      $0.clips.removeAll { ids.contains($0.id) }
      $0.clearSingletonGroups()
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
  func deselectTransition() {
    if selectedTransition != nil { selectedTransition = nil }
  }
  func selectTransition(_ target: TransitionTarget) {
    pause()
    regionTool = nil
    if !selectedIDs.isEmpty { selected = nil }
    libraryFocus = false
    if selectedTransition != target { selectedTransition = target }
    shelf.transitionSection = .effects
    shelf.toolTab = .transitions
  }
  func openTab(_ tab: ToolTab) {
    guard toolTab != tab else { return }
    if tab != .media { libraryMarquee.cancel() }
    libraryFocus = tab == .media
    if regionTool != nil { regionTool = nil }
    shelf.toolTab = tab
  }

  func placeTransition(_ style: TransitionLook, on targets: [TransitionTarget]) {
    guard let first = targets.first else { return }
    var next = p
    do {
      try next.placeTransition(style, on: targets)
      change { $0 = next }
      lastTransitionStyle = style
      selectTransition(first)
    } catch { self.error = error.localizedDescription }
  }
  func applyTransitionCard(_ style: TransitionLook) {
    if let target = selectedTransition {
      placeTransition(style, on: [target])
      return
    }
    let targets = selectedClips.filter { $0.kind == .video }.flatMap { TransitionTarget.ends(of: $0) }
    guard !targets.isEmpty else {
      status = "把效果拖到时间线上的视频或图片"
      return
    }
    placeTransition(style, on: targets)
  }
  func editTransition(_ target: TransitionTarget, frames: Int) {
    var next = p
    do {
      try next.updateTransition(target, frames: frames)
      change { $0 = next }
      if frames > 0 { selectTransition(target) }
    } catch { self.error = error.localizedDescription }
  }
  func previewTransition(_ target: TransitionTarget) {
    switch target {
    case .join(let id):
      guard let join = p.joins.first(where: { $0.id == id && $0.active }) else { return }
      previewTransition(
        max(join.before.start, join.range.lowerBound - 7)..<min(join.after.end, join.range.upperBound + 9))
    case .edge(let edge):
      guard let clip = p.clips.first(where: { $0.id == edge.clipID }),
        let range = clip.transitionRange(at: edge.end)
      else { return }
      previewTransition(max(0, range.lowerBound - 7)..<min(p.duration, range.upperBound + 9))
    }
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
  private func loadWaveform(_ media: Media, refresh: Bool = false) {
    waveforms.load(media, refresh: refresh) { [weak self] in
      guard let self, let index = self.p.assets.firstIndex(where: {
        $0.id == media.id && $0.path == media.path && !$0.audio
      }) else { return }
      self.p.assets[index].audio = true
      if let previous = self.baseline.assets.firstIndex(where: {
        $0.id == media.id && $0.path == media.path
      }) { self.baseline.assets[previous].audio = true }
    }
  }
  func loadThumb(_ m: Media, refresh: Bool = false) {
    loadWaveform(m, refresh: refresh)
    guard m.video, refresh || thumbnails[m.id] == nil else { return }
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
              if let index = p.assets.firstIndex(where: { $0.path == m.path }) {
                if m.audio { p.assets[index].audio = true }
                m = p.assets[index]
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
        self.p.assets.forEach { self.loadThumb($0) }
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
      loadThumb(replacement, refresh: true)
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
    previewComposition = nil
    liveCanvas.clear()
    regionTool = nil
    generation = UUID()
    undoStack = []
    redoStack = []
    thumbnails = [:]
    waveforms.reset()
    mediaSizes = [:]
    cropID = nil
    libraryIDs = []
    libraryAnchor = nil
    selected = nil
    shelf.dropTargets = []
    lastTransitionStyle = .dissolve
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
    guard progress == nil, p.duration > 0, let window = NSApp.keyWindow,
      window.sheetParent == nil, window.attachedSheet == nil
    else { return }
    pause()
    var initial = exportSettings
    if initial.short != exportShort { initial.customMbps = nil }
    initial.short = exportShort
    let options = ExportOptions(settings: initial, project: p)
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 466, height: 252),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = "导出设置"
    sheet.appearance = NSAppearance(named: .darkAqua)
    let end: (NSApplication.ModalResponse) -> Void = { [weak window, weak sheet] response in
      guard let sheet else { return }
      if response == .OK { sheet.makeFirstResponder(nil) }
      window?.endSheet(sheet, returnCode: response)
    }
    sheet.contentView = NSHostingView(
      rootView: ExportSettingsView(
        options: options, cancel: { end(.cancel) }, proceed: { end(.OK) }))
    window.beginSheet(sheet) { [weak self, weak window] response in
      options.cancelSample()
      sheet.contentView = nil
      guard response == .OK, let self, let window else { return }
      self.chooseExportDestination(on: window, settings: options.settings)
    }
  }

  private func chooseExportDestination(on window: NSWindow, settings: ExportSettings) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.prompt = "导出"
    panel.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "剪辑") + ".mp4"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let dest = panel.url else { return }
      self?.startExport(to: dest, settings: settings)
    }
  }

  private func startExport(to dest: URL, settings: ExportSettings) {
    guard
      !p.assets.contains(where: {
        URL(fileURLWithPath: $0.path).standardizedFileURL == dest.standardizedFileURL
      })
    else {
      error = "请选择与原素材不同的导出文件名。"
      return
    }
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
