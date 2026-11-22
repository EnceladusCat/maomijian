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
  let chartDataEdits = PassthroughSubject<UUID, Never>()
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
        if next.captionStyle != previous.captionStyle || next.captionTerms != previous.captionTerms
          || next.clips != previous.clips || next.assets != previous.assets { changed() }
      case .filters:
        if previous.clips.filter({ $0.kind == .video }) != next.clips.filter({ $0.kind == .video })
        {
          changed()
        }
      case .charts:
        if previous.clips.filter({ $0.kind == .chart }) != next.clips.filter({ $0.kind == .chart }) {
          changed()
        }
      case .quickEdit:
        if next.clips != previous.clips { changed() }
      case .annotations:
        if next.assets != previous.assets || next.clips != previous.clips { changed() }
      case .media:
        if next.assets != previous.assets { changed() }
      case .transitions:
        let slide = editor.shelf.transitionSection == .slide
        if next.assets != previous.assets
          || (slide
            ? previous.clips != next.clips
            : previous.clips.filter { $0.kind.supportsTransitions } != next.clips.filter { $0.kind.supportsTransitions })
        {
          changed()
        }
      default: break
      }
    }.store(in: &subscriptions)
    if tab == .annotations {
      editor.$regionTool.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
    }
    if tab == .media {
      editor.$libraryIDs.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
      editor.$thumbnails.dropFirst().sink { _ in changed() }.store(in: &subscriptions)
    }
    if tab == .filters || tab == .captions || tab == .charts || tab == .quickEdit || tab == .annotations {
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
  @Published var message = L("就绪")
}
final class Editor: ObservableObject {
  private static let timelineClipboardType = NSPasteboard.PasteboardType("local.framecut.timeline-clips.v1")
  private var copiedProperties: (clip: Clip, hasAudio: Bool)?
  @Published private(set) var p = Project() {
    didSet {
      cachedTimelineLayout = nil
      timelineDuration = p.duration
    }
  }
  private var cachedTimelineLayout: TimelineLayout?
  private(set) var timelineDuration = 0
  var timelineLayout: TimelineLayout {
    if let cachedTimelineLayout { return cachedTimelineLayout }
    let layout = TimelineLayout(p)
    cachedTimelineLayout = layout
    return layout
  }
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
  @Published private(set) var pathDrawingID: UUID?
  @Published private(set) var backgroundColorPick: BackgroundColorPick?
  private var preparingBackgroundPick: UUID?
  @Published private(set) var mediaSizes = [UUID: CGSize]()
  private var pendingAudition: Range<Int>?
  private var auditionEnd: Int?
  private var scrubSession: UUID?
  private var scrubFrame: Int?
  private var seekInFlight = false
  private var submittedScrubFrame: Int?
  private var scrubSources: [UUID: ScrubPreview.Source] = [:]
  private var exactScrubSeek: UUID?
  private var currentScrubFrame: Int?
  private var lastScrubTick: CFTimeInterval?
  private var scrubRefresh: DispatchWorkItem?
  private var scrubVelocity = 0.0
  @Published var selectedIDs: [UUID] = [] {
    didSet {
      if let pathDrawingID, selectedIDs != [pathDrawingID] { cancelPathDrawing() }
      if let pick = backgroundColorPick, selectedIDs != [pick.clipID] { cancelBackgroundColorPick() }
    }
  }
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
  var canCopyClips: Bool { !libraryFocus && selectedTransition == nil && !selectedIDs.isEmpty }
  var canPasteClips: Bool {
    NSPasteboard.general.availableType(from: [Self.timelineClipboardType]) != nil
  }
  func selectForClipMenu(_ id: UUID) {
    regionTool = nil
    if selectedIDs.contains(id) {
      deselectTransition()
      libraryFocus = false
    } else {
      selected = id
    }
  }
  @discardableResult func copyClips() -> Bool {
    guard canCopyClips else { return false }
    let payload = TimelineClipboard(project: p, selection: selectedIDs)
    guard !payload.clips.isEmpty, let data = try? JSONEncoder().encode(payload) else { return false }
    let clipboard = NSPasteboard.general
    let item = NSPasteboardItem()
    guard item.setData(data, forType: Self.timelineClipboardType) else { return false }
    clipboard.clearContents()
    guard clipboard.writeObjects([item]) else { return false }
    status = L("已复制 \(payload.clips.count) 个片段")
    return true
  }
  func cutClips() {
    if copyClips() { remove() }
  }
  func pasteClips() {
    guard let data = NSPasteboard.general.data(forType: Self.timelineClipboardType) else { return }
    let start = transport.frame
    var next = p
    let existingAssets = Set(p.assets.map(\.id))
    do {
      let payload = try JSONDecoder().decode(TimelineClipboard.self, from: data)
      let pasted = try payload.paste(into: &next, at: start)
      guard !pasted.isEmpty else { return }
      change { $0 = next }
      let installed = Set(p.clips.map(\.id))
      guard pasted.allSatisfy(installed.contains) else { return }
      deselectTransition()
      libraryFocus = false
      selectedIDs = pasted
      timelineAnchor = pasted.first
      for asset in p.assets where !existingAssets.contains(asset.id) { loadThumb(asset) }
      seek(start)
    } catch { self.error = error.localizedDescription }
  }
  func copyProperties(from id: UUID) {
    guard let source = p.clips.first(where: { $0.id == id }) else { return }
    copiedProperties = (source, source.kind.isMedia && p.asset(source.asset)?.audio == true)
    status = L("已复制片段属性")
  }
  var hasCopiedProperties: Bool { copiedProperties != nil }
  func pasteProperties() {
    guard let copiedProperties else { return }
    let ids = Set(selectedIDs)
    let audioAssets = Set(p.assets.filter(\.audio).map(\.id))
    var matched = 0
    change { project in
      for index in project.clips.indices where ids.contains(project.clips[index].id) {
        let clip = project.clips[index]
        let audio = copiedProperties.hasAudio && clip.kind.isMedia && clip.asset.map(audioAssets.contains) == true
        guard clip.acceptsProperties(from: copiedProperties.clip, sharedAudio: audio) else { continue }
        project.clips[index].applyProperties(from: copiedProperties.clip, sharedAudio: audio)
        matched += 1
      }
    }
    status = matched > 0 ? L("已粘贴 \(matched) 个片段的属性") : L("所选片段没有可以共用的属性")
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
    let order: [UUID]
    if modifiers.contains(.shift) {
      order = timelineAnchor.map(lane.contains) == true
        ? lane : p.clips.sorted { $0.start < $1.start }.map(\.id)
    } else {
      order = []
    }
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
  weak var workspaceWindow: NSWindow?
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
  let automaticCaptions = AutomaticCaptions()
  let captionVoiceover = CaptionVoiceover()
  let recentProjects = RecentProjects()
  let transport = Transport(), player = AVPlayer()
  let liveCanvas = LiveCanvasPreview()
  let scrubPreview = ScrubPreview()
  private var baseline = Project(), undoStack = [Project](), redoStack = [Project](),
    observer: Any?, itemObservation: NSKeyValueObservation?
  private let recovery = ProjectRecovery()
  private var graphSnapshot: Project?, previewGraph: MediaGraph?
  private var previewComposition: Composition?
  private var buildTicket: Progress?
  private var playWhenReady = false
  private var revision = 0, generation = UUID(), pending: DispatchWorkItem?, job: ExportJob?
  private let queue = DispatchQueue(label: "framecut.preview", qos: .userInitiated)
  private let fileReads = DispatchQueue(label: "framecut.import", qos: .userInitiated, attributes: .concurrent)
  private var openingProject: UUID?
  private var pendingRelinks = [UUID: UUID]()
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
      let next = bound(f, 0, self.timelineDuration)
      if self.transport.frame != next { self.transport.frame = next }
      if self.player.rate == 0 && f >= self.timelineDuration - 2 { self.transport.playing = false }
    }
    NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] note in
      if let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem {
        self.transport.playing = false
        self.transport.frame = self.timelineDuration
      }
    }
  }
  func pause() {
    stopTransport(keepScrubImage: false)
  }

  private func stopTransport(keepScrubImage: Bool) {
    playWhenReady = false
    exactScrubSeek = nil
    if keepScrubImage { scrubPreview.stopKeepingImage() } else { scrubPreview.clear() }
    if scrubSession != nil { transport.playback.setScrubbing(false) }
    scrubSession = nil
    scrubFrame = nil
    seekInFlight = false
    submittedScrubFrame = nil
    currentScrubFrame = nil
    lastScrubTick = nil
    scrubRefresh?.cancel()
    scrubRefresh = nil
    scrubVelocity = 0
    auditionEnd = nil
    pendingAudition = nil
    if player.rate != 0 || transport.playing { player.pause() }
    if transport.playing { transport.playing = false }
  }
  func seek(_ f: Int) {
    cancelBackgroundColorPick()
    liveCanvas.clear()
    let keepPreview = scrubSession != nil && scrubPreview.frame != nil
    stopTransport(keepScrubImage: keepPreview)
    let next = bound(f, 0, timelineDuration)
    if transport.frame != next { transport.frame = next }
    if keepPreview {
      let id = UUID()
      exactScrubSeek = id
      let frame = min(next, max(0, timelineDuration - 1))
      player.seek(to: time(frame), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
          guard let self, self.exactScrubSeek == id else { return }
          self.exactScrubSeek = nil
          self.scrubPreview.clear()
        }
      }
    } else {
      position()
    }
  }
  // Keep a single decode in flight while dragging. A release or a transport
  // command invalidates its callback and seeks the exact requested frame.
  func scrub(_ frame: Int) {
    cancelBackgroundColorPick()
    guard player.currentItem != nil else {
      seek(frame)
      return
    }
    if scrubSession == nil {
      liveCanvas.clear()
      let keepPreview = exactScrubSeek != nil && scrubPreview.frame != nil
      stopTransport(keepScrubImage: keepPreview)
      player.currentItem?.cancelPendingSeeks()
      scrubSession = UUID()
      transport.playback.setScrubbing(true)
    }
    let next = bound(frame, 0, timelineDuration)
    if transport.frame != next { transport.frame = next }
    let target = min(next, max(0, timelineDuration - 1))
    let now = CACurrentMediaTime()
    if let previous = currentScrubFrame, let tick = lastScrubTick, now > tick, now - tick < 0.15 {
      scrubVelocity = 0.55 * scrubVelocity + 0.45 * Double(target - previous) / max(0.008, now - tick)
    } else {
      scrubVelocity = 0
    }
    currentScrubFrame = target
    lastScrubTick = now
    scrubRefresh?.cancel()
    scrubRefresh = nil
    if let session = scrubSession, let request = fastScrubRequest(target) {
      if target != submittedScrubFrame {
        submittedScrubFrame = target
        scrubFrame = nil
        updateScrubPreview(request, session: session, predictsMotion: true)
      }
      if abs(scrubVelocity) * scrubPreview.decodeDelay > 3 {
        // A stopped pointer gets its original target back without waiting
        // for mouse-up, even if the last decoded request used motion lead.
        let refresh = DispatchWorkItem { [weak self] in
          guard let self, self.scrubSession == session, self.lastScrubTick == now else { return }
          self.scrubVelocity = 0
          self.updateScrubPreview(request, session: session, predictsMotion: false)
        }
        scrubRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.085, execute: refresh)
      }
      return
    }
    scrubPreview.clear()
    scrubFrame = target == submittedScrubFrame ? nil : target
    if !seekInFlight { seekLatestScrub() }
  }

  private func updateScrubPreview(_ request: ScrubPreview.Request, session: UUID, predictsMotion: Bool) {
    scrubPreview.update(request, session: session, latest: { [weak self] frame in
      guard predictsMotion, let self, self.scrubSession == session, self.currentScrubFrame == frame else {
        return nil
      }
      // Compensate for decode time on sustained motion, within the current slice.
      let lead = Int(bound(self.scrubVelocity * self.scrubPreview.decodeDelay, -900, 900).rounded())
      let predicted = bound(frame + lead, request.bounds.lowerBound, request.bounds.upperBound - 1)
      return request.moving(to: predicted)
    }) { [weak self] rejected in
      guard let self, self.scrubSession == session, self.submittedScrubFrame == rejected else { return }
      self.scrubPreview.stopKeepingImage()
      self.scrubFrame = rejected
      if !self.seekInFlight { self.seekLatestScrub() }
    }
  }

  private func fastScrubRequest(_ frame: Int) -> ScrubPreview.Request? {
    guard !busy, let composition = previewComposition, let painter = composition.scrubPainter,
      let slice = composition.instruction(at: frame) as? Slice, slice.sources.count == 1,
      let clip = slice.clips.first(where: { $0.kind == .video }),
      !slice.clips.contains(where: { slice.stills[$0.id] != nil }),
      (clip.start..<clip.end).contains(frame), let id = clip.asset,
      let sourceMap = slice.sources[clip.id], sourceMap.opaque,
      let media = p.asset(id), !media.isStill else { return nil }
    let range = slice.timeRange
    let start = max(clip.start, Int((range.start.seconds * Double(fps)).rounded()))
    let end = min(clip.end, Int((range.end.seconds * Double(fps)).rounded()))
    guard start <= frame, frame < end else { return nil }
    if scrubSources.count >= 4 && scrubSources[id] == nil { scrubSources.removeAll(keepingCapacity: true) }
    let source = scrubSources[id] ?? ScrubPreview.Source(media.path, size: painter.size)
    scrubSources[id] = source
    return .init(frame: frame, slice: slice, clip: clip, source: source, transform: sourceMap.transform,
                 bounds: start..<end, painter: painter)
  }

  private func seekLatestScrub() {
    guard let session = scrubSession, let item = player.currentItem, let frame = scrubFrame else {
      return
    }
    scrubFrame = nil
    seekInFlight = true
    submittedScrubFrame = frame
    let tolerance = previewComposition?.scrubTolerance(at: frame)
    player.seek(to: time(frame), toleranceBefore: tolerance?.before ?? .zero,
                toleranceAfter: tolerance?.after ?? .zero) {
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
      to: time(min(transport.frame, max(0, timelineDuration - 1))), toleranceBefore: .zero,
      toleranceAfter: .zero)
  }
  func play() {
    cancelBackgroundColorPick()
    cancelPathDrawing()
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
    next.syncAudioVisualizations()
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
    cancelBackgroundColorPick()
    cancelPathDrawing()
    pause()
    let previousProjectWasDirty = dirty
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
    if dirty {
      recovery.schedule(
        RecoveryDraft(project: p, original: url, frame: transport.frame, savedAt: Date())
      ) { [weak self] _ in self?.status = L("无法自动保存草稿，请手动保存工程") }
    } else if previousProjectWasDirty {
      recovery.discard()
    }
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
    scrubSources.removeAll(keepingCapacity: true)
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
      status = L("就绪")
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
    if reuse == nil { status = L("正在准备预览") }
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
                self.status = L("预览失败")
                self.error = item.error?.localizedDescription ?? L("系统无法解码该媒体。")
              }
            }
          }
          self.position()
          self.status = L("就绪")
          self.didPrepare()
        case .failure(let e):
          self.previewGraph = nil
          self.graphSnapshot = nil
          self.previewComposition = nil
          self.cancelBackgroundColorPick()
          self.liveCanvas.clear()
          self.pause()
          self.player.replaceCurrentItem(with: nil)
          self.status = L("预览未就绪")
          self.error = e.localizedDescription
        }
      }
    }
    pending = work
    queue.async(execute: work)
  }
  private func didPrepare() {
    prepareBackgroundColorPick()
    // Start after the initial player seek so priming does not contend with
    // the frame the editor needs to paint as soon as an item opens.
    let revision = revision
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
      guard let self, self.revision == revision, self.scrubSession == nil,
        let request = self.fastScrubRequest(self.transport.frame) else { return }
      self.scrubPreview.warm(request.source, at: request.clip.sourceFrame(at: request.frame))
    }
    if playWhenReady {
      playWhenReady = false
      player.play()
    } else if let range = pendingAudition {
      previewRange(range)
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
    cancelBackgroundColorPick()
    cancelPathDrawing()
    regionTool = nil
    if cropID == c.id {
      cropID = nil
      return
    }
    pause()
    if !(c.start..<c.end).contains(transport.frame) { seek(c.start) }
    cropID = c.id
  }
  func beginPathDrawing(for id: UUID) {
    guard selectedIDs == [id], let c = clip, c.supportsMotion, c.length > 1 else { return }
    regionTool = nil
    cropID = nil
    seek(c.start)
    pathDrawingID = id
  }

  func cancelPathDrawing() {
    if pathDrawingID != nil { pathDrawingID = nil }
  }

  func finishPathDrawing(for id: UUID, stroke: [CGPoint], canvas: CGSize) {
    guard pathDrawingID == id, selectedIDs == [id], let first = stroke.first,
      let path = MotionPath(stroke: stroke, in: canvas) else { return }
    cancelPathDrawing()
    edit(id) { clip in
      if clip.motion == .slide { clip.slideFrames = clip.entranceFrames }
      clip.motion = .path
      clip.motionPath = path
      clip.x = bound(first.x / canvas.width, 0, 1)
      clip.y = bound(first.y / canvas.height, 0, 1)
    }
  }

  func previewPath(_ c: Clip) { previewRange(c.start..<c.end) }

  func beginBackgroundColorPick(clipID: UUID, filterIndex: Int) {
    finishWorkspaceTextEditing()
    guard selectedIDs == [clipID], let clip, clip.kind == .video,
      clip.filters.indices.contains(filterIndex), clip.filters[filterIndex].look == .backgroundKey
    else { return }
    if backgroundColorPick?.clipID == clipID && backgroundColorPick?.filterIndex == filterIndex {
      cancelBackgroundColorPick()
      return
    }

    pause()
    liveCanvas.clear()
    cancelPathDrawing()
    regionTool = nil
    cropID = nil
    if !(clip.start..<clip.end).contains(transport.frame) { seek(clip.start) }
    backgroundColorPick = BackgroundColorPick(clipID: clipID, filterIndex: filterIndex, frame: transport.frame)
    prepareBackgroundColorPick()
  }

  func cancelBackgroundColorPick() {
    if backgroundColorPick != nil { backgroundColorPick = nil }
    preparingBackgroundPick = nil
  }

  private func prepareBackgroundColorPick() {
    guard !busy, let pick = backgroundColorPick, pick.image == nil, preparingBackgroundPick != pick.token,
      let clip, clip.id == pick.clipID else { return }
    guard let composition = previewComposition else {
      cancelBackgroundColorPick()
      status = L("取色画面未就绪，请再试一次。")
      return
    }
    preparingBackgroundPick = pick.token
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let image = autoreleasepool {
        guard let snapshot = composition.canvasFrame(at: pick.frame),
          let picture = snapshot.pictures[pick.clipID] else { return nil as CGImage? }
        return snapshot.painter.backgroundKeyPreview(clip, picture: picture, frame: pick.frame,
                                                     filterIndex: pick.filterIndex)
      }
      DispatchQueue.main.async {
        guard let self, self.backgroundColorPick?.token == pick.token else { return }
        self.preparingBackgroundPick = nil
        if let image {
          self.backgroundColorPick?.image = image
        } else {
          self.cancelBackgroundColorPick()
          self.status = L("取色画面未就绪，请再试一次。")
        }
      }
    }
  }

  func useBackgroundSample(at point: CGPoint) {
    guard let pick = backgroundColorPick, let image = pick.image else { return }
    guard let color = BackgroundKey.sample(image, at: point) else {
      status = L("请点击当前素材内有颜色的位置。")
      return
    }
    cancelBackgroundColorPick()
    edit(pick.clipID) { clip in
      var filters = clip.filters
      guard filters.indices.contains(pick.filterIndex), filters[pick.filterIndex].look == .backgroundKey
      else { return }
      filters[pick.filterIndex].keyColor = color
      clip.filters = filters
    }
  }

  func addFilter(_ look: FootageFilter) {
    guard look != .none else { return }
    editSelectedFilters { filters in
      if look == .backgroundKey {
        if !filters.contains(where: { $0.look == .backgroundKey }) { filters.insert(ClipFilter(look: look), at: 0) }
      } else {
        filters.append(ClipFilter(look: look))
      }
    }
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
    guard kind != .chart && kind != .editorial && kind != .audioVisual else { return }
    cancelBackgroundColorPick()
    cancelPathDrawing()
    if cropID != nil { cropID = nil }
    pause()
    if kind.isRegion {
      if regionTool != kind { regionTool = kind }
      return
    }
    if regionTool != nil { regionTool = nil }
    insertAnnotation(Clip.annotation(kind, at: min(transport.frame, maxFrames - 1)))
  }
  func addChart(_ chart: ChartSpec, appearance: ChartAppearance?, color: String) {
    guard chart.valid else { return }
    pause()
    cropID = nil
    regionTool = nil
    var clip = Clip.annotation(.chart, at: min(transport.frame, maxFrames - 1))
    let size = p.canvas.size(540)
    clip.h = min(0.72, clip.w * size.width / size.height * 0.72)
    clip.chart = chart
    clip.chartAppearance = appearance
    clip.color = color
    insertAnnotation(clip)
  }
  var audioVisualizationSource: Clip? {
    guard let clip, clip.kind.isMedia, p.asset(clip.asset)?.audio == true else { return nil }
    return clip
  }
  func addAudioVisualization(_ style: AudioVisualStyle) {
    guard let source = audioVisualizationSource else { return }
    var next = p
    guard let id = next.addAudioVisualization(for: source.id, style: style) else { return }
    cropID = nil
    regionTool = nil
    change { $0 = next }
    selected = id
    if !(source.start..<source.end).contains(transport.frame) { seek(source.start) }
  }
  func addEditorial(_ style: EditorialStyle) {
    pause()
    cropID = nil
    regionTool = nil
    insertAnnotation(style.clip(at: min(transport.frame, maxFrames - 1)))
  }

  func useQuickMetricStyle(reveal: Bool) {
    pause()
    cropID = nil
    regionTool = nil
    let frame = min(transport.frame, maxFrames - 1)
    let single = selectedIDs.count == 1 ? selected : nil
    var id: UUID?
    change { project in id = project.useQuickMetricStyle(reveal: reveal, selected: single, at: frame) }
    selected = id
  }

  func alignMetricRevealToPlayhead(_ id: UUID) {
    let frame = transport.frame
    guard let clip = p.clips.first(where: { $0.id == id }), clip.editorial?.activeMetricReveal != nil else { return }
    guard (clip.start..<clip.end).contains(frame) else {
      status = L("请把播放头移到数字片段内。")
      return
    }
    edit(id) { $0.editorial?.metricReveal?.offsetFrames = frame - clip.start }
    status = L("已对齐揭晓时刻 \(tc(frame))")
  }
  var pictureInsetSelection: (host: Clip, backdrop: Clip?)? {
    guard let clip, clip.kind == .video, clip.pictureInset == nil else { return nil }
    if selectedIDs.count == 1 { return (clip, nil) }
    if selectedIDs.count == 2, let other = selectedClips.first(where: {
      $0.id != clip.id && $0.kind == .video && $0.start < clip.end && clip.start < $0.end
    }) { return (clip, other) }
    return nil
  }
  func enablePictureInset() {
    guard let selection = pictureInsetSelection else { return }
    cropID = nil
    var next = p
    guard let id = next.applyPictureInset(to: selection.host.id, over: selection.backdrop?.id),
      let inset = next.clips.first(where: { $0.id == id })
    else { return }
    change { $0 = next }
    selected = id
    if !(inset.start..<inset.end).contains(transport.frame) { seek(inset.start) }
  }
  func applyDataStory() {
    if selectedIDs.count == 1, let clip, clip.kind == .chart {
      if !(clip.start..<clip.end).contains(transport.frame) { seek(clip.start) }
      edit(clip.id) { $0.applyDataStoryStyle() }
      return
    }
    let points = [18.0, 23, 17, 28, 25, 34, 31, 46].enumerated().map {
      ChartPoint(label: String($0.offset + 1), y: $0.element)
    }
    let spec = ChartSpec(kind: .line, title: L("示例走势"), points: points,
                         marker: ChartMarker(row: 5, title: L("关键节点")))
    addChart(spec, appearance: ChartAppearance(backgroundOpacity: 0.87, areaFill: true),
             color: "#B29BFF")
  }
  func editChartData(_ clip: Clip) {
    guard let chart = p.clips.first(where: { $0.id == clip.id })?.chart, let window = sheetWindow else { return }
    pause()
    let sheet = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 540, height: 420),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    sheet.minSize = CGSize(width: 390, height: 280)
    sheet.appearance = NSAppearance(named: .darkAqua)
    sheet.title = L("编辑图表数据")
    let close = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
    let generation = generation
    sheet.contentView = NSHostingView(rootView: ChartDataEditor(chart: chart, cancel: close) { [weak self] updated in
      close()
      guard let self, self.generation == generation, updated != chart else { return }
      self.edit(clip.id) { $0.chart = updated }
      self.shelf.chartDataEdits.send(clip.id)
    })
    window.beginSheet(sheet) { _ in sheet.contentView = nil }
  }
  func editEditorialCards(_ clip: Clip) {
    guard let clip = p.clips.first(where: { $0.id == clip.id }),
      let spec = clip.editorial, spec.style == .cards, let window = sheetWindow else { return }
    pause()
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 840, height: 517),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    panel.minSize = CGSize(width: 675, height: 480)
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.title = L("编辑三张卡片")
    let close = { [weak window, weak panel] in if let panel { window?.endSheet(panel) } }
    let generation = generation
    let size = p.canvas.size(540)
    panel.contentView = NSHostingView(rootView: EditorialCardEditor(
      spec: spec, title: clip.text, accent: clip.color,
      aspect: (size.width * clip.w) / (size.height * clip.h), background: p.background, cancel: close,
      chooseImage: { [weak panel] complete in
        guard let panel else { complete(nil); return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.beginSheetModal(for: panel) { response in complete(response == .OK ? picker.url : nil) }
      }
    ) { [weak self] cards in
      close()
      guard let self, self.generation == generation, cards != spec.cards else { return }
      self.edit(clip.id) { $0.editorial?.cards = cards }
    })
    window.beginSheet(panel) { _ in panel.contentView = nil }
  }
  private func insertAnnotation(_ clip: Clip) {
    var c = clip
    c.length = min(c.length, maxFrames - c.start)
    change { $0.clips.append(c) }
    guard p.clips.last?.id == c.id else { return }
    selected = c.id
    if !(c.start..<c.end).contains(transport.frame) { seek(c.start) }
  }
  func append(_ asset: Media, at start: Int) { insertAssets([asset], at: start) }
  func insertAssets(_ assets: [Media], at start: Int) {
    guard !assets.isEmpty else { return }
    var cursor = start
    var clips: [Clip] = []
    for asset in assets {
      guard asset.frames <= maxFrames - cursor else {
        error = L("素材超出工程时长上限。")
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
      error = L("找不到内置音效 ") + sound.name
      return
    }
    let asset =
      p.assets.first { $0.soundID == sound.rawValue }
      ?? Media(
        path: url.path, frames: sound.frames, video: false, audio: true, soundID: sound.rawValue)
    append(asset, at: transport.frame)
  }
  var canBatchCut: Bool {
    !selectedIDs.isEmpty
  }
  func batchCut() {
    guard canBatchCut, let window = sheetWindow else { return }
    pause()
    let snapshot = p
    let clips = selectedClips.sorted { $0.start < $1.start }
    let draft = BatchCutDraft(project: snapshot, clips: clips)
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 850, height: 530),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    sheet.minSize = CGSize(width: 840, height: 480)
    sheet.appearance = NSAppearance(named: .darkAqua)
    sheet.title = L("批量切割")
    let cancel = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
    sheet.contentView = NSHostingView(
      rootView: BatchCutPanel(draft: draft, cancel: cancel) { plan in
        guard self.p == snapshot else {
          draft.message = L("工程已改动，请重新打开批量切割。")
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
      status = L("请把播放头移到所选片段的中间")
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
  func detach() {
    guard var c = clip, c.kind == .video, c.volume > 0, p.asset(c.asset)?.audio == true else {
      return
    }
    let id = c.id
    c.id = UUID()
    c.kind = .audio
    if c.motion == .path {
      c.motion = .none
      c.motionPath = nil
    }
    c.pictureInset = nil
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
    var c = Clip.annotation(kind, at: min(transport.frame, maxFrames - 1))
    c.regionShape = drawShape
    c.setRegion(drawShape.fit(rect, in: p.canvas.size(540)))
    insertAnnotation(c)
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
    cancelBackgroundColorPick()
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
  func moveTransition(from origin: TransitionTarget, to destination: TransitionTarget) {
    guard origin != destination else { return }
    var next = p
    do {
      try next.moveTransition(from: origin, to: destination)
      if next != p {
        change { $0 = next }
        selectTransition(destination)
      }
    } catch { self.error = error.localizedDescription }
  }
  func applyTransitionCard(_ style: TransitionLook) {
    if let target = selectedTransition {
      placeTransition(style, on: [target])
      return
    }
    let targets = TransitionTarget.cardTargets(for: selectedClips)
    guard !targets.isEmpty else {
      status = L("把效果拖到时间线上的可用片段")
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
      previewRange(
        max(join.before.start, join.range.lowerBound - 7)..<min(join.after.end, join.range.upperBound + 9))
    case .edge(let edge):
      guard let clip = p.clips.first(where: { $0.id == edge.clipID }),
        let range = clip.transitionRange(at: edge.end)
      else { return }
      previewRange(max(0, range.lowerBound - 7)..<min(p.duration, range.upperBound + 9))
    }
  }
  private func previewRange(_ range: Range<Int>) {
    if busy {
      pendingAudition = range
      return
    }
    seek(range.lowerBound)
    auditionEnd = range.upperBound
    play()
  }
  func dragRange(for c: Clip, edge: Int) -> ClosedRange<Int> {
    if edge == 0 {
      let moving = selectedIDs.count > 1 && selectedIDs.contains(c.id) ? selectedClips : [c]
      return -(moving.map(\.start).min() ?? c.start)...(maxFrames - (moving.map(\.end).max() ?? c.end))
    }
    let asset = p.asset(c.asset)
    let timedSource = c.kind.isMedia && asset?.isStill != true
    if edge < 0 {
      let available = timedSource ? Int(floor(c.sourceIn / c.effectiveRate + 1e-8)) : c.start
      return -min(c.start, available)...(c.length - 1)
    }
    let length = timedSource ? c.maximumLength(assetFrames: asset?.frames ?? maxFrames) : maxFrames - c.start
    return (1 - c.length)...(length - c.length)
  }
  func move(_ c: Clip, by delta: Int, edge: Int) {
    let range = dragRange(for: c, edge: edge)
    let shift = bound(delta, range.lowerBound, range.upperBound)
    guard shift != 0 else { return }
    if edge == 0, selectedIDs.count > 1, selectedIDs.contains(c.id) {
      let ids = Set(selectedIDs)
      let selectedAudio = Set(selectedClips.filter { $0.kind.isMedia }.map(\.audioFamily))
      change { project in
        for index in project.clips.indices where ids.contains(project.clips[index].id) {
          project.clips[index].start += shift
          if let source = project.clips[index].audioVisualization?.source, !selectedAudio.contains(source) {
            project.clips[index].audioVisualization?.followsSource = false
          }
        }
      }
      return
    }
    let asset = p.asset(c.asset)
    let timedSource = c.kind.isMedia && asset?.isStill != true
    edit(c.id) { v in
      v.audioVisualization?.followsSource = false
      if edge < 0 {
        v.start = c.start + shift
        v.length = c.length - shift
        if c.kind == .timer { v.timerPhase = (c.timerPhase ?? 0) + shift }
        v.editorial?.shiftReveal(by: -shift)
        if shift > 0 { v.motionPath = c.pathMotion(in: v.start..<v.end) }
        if timedSource { v.setSource(c.sourceFrame(at: c.start + shift), c.sourceEnd) }
      } else if edge > 0 {
        v.length = c.length + shift
        if shift < 0 { v.motionPath = c.pathMotion(in: v.start..<v.end) }
        if timedSource {
          v.setSource(c.sourceIn, c.sourceIn + Double(v.length) * c.effectiveRate)
        }
      } else {
        v.start = c.start + shift
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
    let request = UUID()
    let generation = generation
    pendingRelinks[m.id] = request
    status = L("正在读取替代素材…")
    fileReads.async { [weak self] in
      let result = Result { try inspect(u) }
      DispatchQueue.main.async {
        guard let self, self.generation == generation, self.pendingRelinks[m.id] == request else { return }
        self.pendingRelinks.removeValue(forKey: m.id)
        guard let original = self.p.asset(m.id), original.path == m.path else { return }
        do {
          var replacement = try result.get()
          replacement.id = m.id
          let needed = self.p.clips.lazy.filter { $0.asset == m.id }
            .map { Int(ceil($0.sourceEnd - 1e-8)) }.max() ?? 0
          guard replacement.isStill == original.isStill, replacement.isStill || replacement.frames >= needed,
            !original.video || replacement.video, !original.audio || replacement.audio
          else { throw EditError.message(L("替代素材需要包含原有轨道，且时长要覆盖所有剪辑。")) }
          self.change { p in
            if let i = p.assets.firstIndex(where: { $0.id == m.id }) { p.assets[i] = replacement }
          }
          self.loadThumb(replacement, refresh: true)
          self.status = L("已重新链接素材")
        } catch {
          self.status = L("就绪")
          self.error = error.localizedDescription
        }
      }
    }
  }
  func subtitleImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
    guard panel.runModal() == .OK, let u = panel.url else { return }
    let generation = generation
    status = L("正在读取字幕…")
    fileReads.async { [weak self] in
      let result = Result { try SRT.parse(String(contentsOf: u, encoding: .utf8)) }
      DispatchQueue.main.async {
        guard let self, self.generation == generation else { return }
        switch result {
        case .success(let list):
          guard let first = list.first else { return }
          self.change { $0.clips += list }
          self.selected = first.id
          self.seek(first.start)
          self.status = L("已导入 \(list.count) 条字幕")
        case .failure(let error):
          self.status = L("就绪")
          self.error = error.localizedDescription
        }
      }
    }
  }
  var captionAudioSelection: Clip? {
    guard selectedIDs.count == 1, let clip, clip.kind.isMedia, clip.volume > 0,
      let media = p.asset(clip.asset), !media.isStill, media.audio || clip.kind == .audio
    else { return nil }
    return clip
  }

  private func captionAudio(_ id: UUID?) -> (Project, Int)? {
    let timedAssets = Set(p.assets.lazy.filter { !$0.isStill }.map(\.id))
    var clips = p.clips.filter {
      $0.kind.isMedia && $0.volume > 0 && (id == nil || $0.id == id)
        && $0.asset.map(timedAssets.contains) == true
    }
    guard !clips.isEmpty else { return nil }
    let offset = id == nil ? 0 : clips[0].start
    for index in clips.indices { clips[index].start -= offset }
    let ids = Set(clips.compactMap(\.asset))
    var audio = Project()
    audio.assets = p.assets.filter { ids.contains($0.id) }
    audio.clips = clips
    return (audio, offset)
  }

  func generateCaptions(language: CaptionLanguage, selection: Bool, replacing: Bool) {
    let id = selection ? captionAudioSelection?.id : nil
    guard !selection || id != nil, let (audio, offset) = captionAudio(id) else { return }
    let terms = (p.captionTerms ?? "").split(whereSeparator: { ",，、;；\n".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let generation = generation
    automaticCaptions.start(project: audio, offset: offset, language: language, terms: Array(terms.prefix(100))) {
      [weak self] result in
      guard let self, self.generation == generation else { return }
      switch result {
      case .success(let captions):
        guard let (current, anchor) = self.captionAudio(id), current == audio, offset == anchor else {
          self.error = L("音频时间线已更改，请重新生成字幕。")
          return
        }
        guard !captions.isEmpty else {
          self.error = L("这段音频里没有识别出可用的口播。")
          return
        }
        let end = offset + audio.duration
        var existing = self.p.clips.filter { $0.kind == .caption }
        if replacing {
          existing.removeAll { $0.start >= offset && $0.end <= end }
        }
        let additions = captions.filter { caption in
          !existing.contains { $0.start < caption.end && caption.start < $0.end }
        }
        let removed = Set(self.p.clips.filter {
          replacing && $0.kind == .caption && $0.start >= offset && $0.end <= end
        }.map(\.id))
        self.change { project in
          project.clips.removeAll { removed.contains($0.id) }
          project.clips.append(contentsOf: additions)
        }
        self.status = L("已添加 \(additions.count) 条自动字幕")
          + (captions.count > additions.count ? L("，跳过 \(captions.count - additions.count) 条重叠字幕") : "")
      case .failure(let error):
        self.error = L("自动字幕失败。") + error.localizedDescription
      }
    }
  }

  func generateVoiceover(from captions: [Clip], source: VoiceoverText, voice: VoiceoverProfile?) {
    let cues = captions.map { VoiceoverCue($0, source: source) }.filter { !$0.text.isEmpty }
    let generation = generation
    captionVoiceover.start(cues, voice: voice) { [weak self] output in
      guard let self, self.generation == generation else {
        output.discard()
        return ""
      }
      let current = Dictionary(uniqueKeysWithValues: self.p.clips.lazy
        .filter { $0.kind == .caption }.map { ($0.id, VoiceoverCue($0, source: source)) })
      guard cues.allSatisfy({ current[$0.id] == $0 }) else {
        output.discard()
        return L("字幕文字或时间已更改，请重新生成配音。")
      }
      self.change {
        $0.assets += output.assets
        $0.clips += output.clips
      }
      guard let first = output.clips.first, self.p.clips.last?.id == output.clips.last?.id else {
        output.discard()
        return L("无法将配音添加到时间线。")
      }
      output.assets.forEach { self.loadWaveform($0) }
      self.selected = first.id
      self.seek(first.start)
      let extended = zip(cues, output.clips).filter { $1.length > $0.length }.count
      if extended > 0 {
        return L("已添加 \(cues.count) 段配音，\(extended) 段长于对应字幕。")
      }
      return L("已添加 \(cues.count) 段配音。")
    }
  }

  func translateSubtitles(from source: CaptionLanguage) {
    guard let window = sheetWindow else { return }
    let lines = SubtitleTranslationLine.snapshot(in: p)
    guard !lines.isEmpty else { return }
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 478, height: 392),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = L("翻译字幕")
    sheet.appearance = NSAppearance(named: .darkAqua)
    let generation = generation
    let close = { [weak window, weak sheet] in
      if let sheet { window?.endSheet(sheet) }
    }
    let view = CaptionTranslationPanel(
      lines: lines, source: source, close: close
    ) { [weak self] mode, text in
      guard let self, self.generation == generation,
        SubtitleTranslationLine.snapshot(in: self.p) == lines else { return false }
      self.change { mode.apply(text, to: &$0) }
      close()
      return true
    }
    sheet.contentView = NSHostingView(rootView: view)
    window.beginSheet(sheet) { _ in sheet.contentView = nil }
  }

  func reviewSubtitles() {
    guard canExportSubtitles, let window = sheetWindow else { return }
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 476),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = L("批量校对字幕")
    sheet.appearance = NSAppearance(named: .darkAqua)
    let generation = generation
    let view = CaptionReview(
      captions: p.clips.filter { $0.kind == .caption },
      seek: { [weak self] in self?.seek($0) },
      cancel: { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
    ) { [weak self, weak window, weak sheet] edited in
      guard let self, let sheet else { return }
      window?.endSheet(sheet)
      guard self.generation == generation else { return }
      let rows = Dictionary(uniqueKeysWithValues: edited.map { ($0.id, $0) })
      self.change { project in
        for index in project.clips.indices where project.clips[index].kind == .caption {
          if let row = rows[project.clips[index].id] {
            project.clips[index].text = row.text
            project.clips[index].captionTranslation = row.captionTranslation
          }
        }
      }
    }
    sheet.contentView = NSHostingView(rootView: view)
    window.beginSheet(sheet) { _ in sheet.contentView = nil }
  }

  var canExportSubtitles: Bool { p.clips.contains { $0.kind == .caption } }
  var canExportAudio: Bool {
    p.clips.contains { $0.kind.isMedia && $0.volume > 0 && p.asset($0.asset)?.isStill != true }
  }

  func subtitleExport() {
    guard canExportSubtitles, let window = exportWindow else { return }
    chooseExportDestination(on: window, ext: "srt", type: UTType(filenameExtension: "srt") ?? .plainText) {
      [weak self] destination in
      guard let self else { return }
      do {
        try ExportJob.writeSubtitles(self.p, to: destination)
        self.status = L("已导出 ") + destination.lastPathComponent
      } catch { self.error = error.localizedDescription }
    }
  }

  func audioExport() {
    guard canExportAudio, let window = exportWindow else { return }
    chooseExportDestination(on: window, ext: "m4a", type: .mpeg4Audio) { [weak self] destination in
      self?.startExport { task, project, report in
        try task.runAudio(project, to: destination, progress: report)
        return [destination]
      }
    }
  }

  func audioAndSubtitleExport() {
    guard canExportAudio, canExportSubtitles, let window = exportWindow else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.prompt = L("导出到此处")
    panel.message = L("选择音频和字幕的保存文件夹。")
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let folder = panel.url, let self else { return }
      let name = self.exportName
      self.startExport { task, project, report in
        try task.runAudioAndSubtitles(project, in: folder, name: name, progress: report)
      }
    }
  }
  @discardableResult func save(as copy: Bool = false) -> Bool {
    var dest = url
    if copy || dest == nil {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [UTType(filenameExtension: "framecut") ?? .json]
      panel.nameFieldStringValue = url?.lastPathComponent ?? L("未命名.framecut")
      guard panel.runModal() == .OK, let u = panel.url else { return false }
      dest = u.pathExtension.isEmpty ? u.appendingPathExtension("framecut") : u
    }
    do {
      try p.write(to: dest!)
      url = dest
      recentProjects.record(dest!)
      baseline = p
      recovery.discard()
      status = L("工程已保存")
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func mayLeave() -> Bool {
    if progress != nil {
      error = L("正在导出。请等待完成或先取消导出。")
      return false
    }
    guard dirty else { return true }
    let a = NSAlert()
    a.messageText = L("保存当前工程？")
    a.informativeText = L("关闭前可以将这次剪辑保存为工程文件。")
    a.addButton(withTitle: L("保存"))
    a.addButton(withTitle: L("取消"))
    a.addButton(withTitle: L("放弃更改"))
    switch a.runModal() {
    case .alertFirstButtonReturn: return save()
    case .alertThirdButtonReturn:
      recovery.discard()
      return true
    default: return false
    }
  }
  private func reset(_ next: Project, _ file: URL?, saved: Project? = nil, frame: Int = 0) {
    automaticCaptions.cancel()
    captionVoiceover.cancel()
    timelineMarquee.cancel()
    libraryMarquee.cancel()
    graphSnapshot = nil
    previewGraph = nil
    previewComposition = nil
    liveCanvas.clear()
    regionTool = nil
    generation = UUID()
    openingProject = nil
    pendingRelinks.removeAll()
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
    baseline = saved ?? next
    transport.frame = frame
    install(next)
    next.assets.forEach { loadThumb($0) }
  }
  func offerRecovery() -> Bool {
    let draft: RecoveryDraft
    do {
      guard let recovered = try recovery.load() else { return false }
      draft = recovered
    } catch {
      self.error = L("无法读取自动保存的草稿。") + error.localizedDescription
      return false
    }
    let saved = draft.original.flatMap { try? Project.read(from: $0) }
    if saved == draft.project {
      recovery.discard()
      return false
    }
    let alert = NSAlert()
    alert.messageText = L("恢复自动保存的草稿？")
    let name = draft.original?.lastPathComponent ?? L("未命名工程")
    let date = DateFormatter.localizedString(from: draft.savedAt, dateStyle: .medium, timeStyle: .short)
    alert.informativeText = L("\(name) 有一份在 \(date) 保存的恢复草稿。恢复后可以继续编辑并手动保存。")
    alert.addButton(withTitle: L("恢复草稿"))
    alert.addButton(withTitle: L("放弃草稿"))
    let choice = alert.runModal()
    guard choice == .alertFirstButtonReturn else {
      if choice == .alertSecondButtonReturn { recovery.discard() }
      return false
    }
    reset(draft.project, saved == nil ? nil : draft.original, saved: saved ?? Project(), frame: draft.frame)
    return true
  }
  func new() { if mayLeave() { reset(Project(), nil) } }
  func open() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "framecut") ?? .json, .json]
    if panel.runModal() == .OK, let u = panel.url { open(u) }
  }
  func open(_ u: URL) {
    let request = UUID()
    openingProject = request
    status = L("正在读取工程…")
    fileReads.async { [weak self] in
      let result = Result { try Project.read(from: u) }
      DispatchQueue.main.async {
        guard let self, self.openingProject == request else { return }
        self.status = L("就绪")
        defer { if self.openingProject == request { self.openingProject = nil } }
        do {
          let next = try result.get()
          guard self.mayLeave(), self.openingProject == request else { return }
          self.reset(next, u)
          self.recentProjects.record(u)
        } catch { self.error = error.localizedDescription }
      }
    }
  }
  private var exportName: String { url?.deletingPathExtension().lastPathComponent ?? L("剪辑") }
  private var sheetWindow: NSWindow? {
    guard NSApp.modalWindow == nil, let window = workspaceWindow ?? NSApp.keyWindow,
      window.sheetParent == nil, window.attachedSheet == nil else { return nil }
    return window
  }
  private var exportWindow: NSWindow? { progress == nil ? sheetWindow : nil }

  func export() {
    guard p.duration > 0, let window = exportWindow else { return }
    pause()
    var initial = exportSettings
    if initial.short != exportShort { initial.customMbps = nil }
    initial.short = exportShort
    let options = ExportOptions(settings: initial, project: p)
    let sheet = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 466, height: 286),
      styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = L("导出设置")
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
      let settings = options.settings
      self.chooseExportDestination(on: window, ext: "mp4", type: .mpeg4Movie) { [weak self] destination in
        guard let self else { return }
        self.exportSettings = settings
        self.exportShort = settings.short
        self.startExport { task, project, report in
          try task.run(project, to: destination, settings: settings, progress: report)
          return [destination]
        }
      }
    }
  }

  private func chooseExportDestination(
    on window: NSWindow, ext: String, type: UTType, perform: @escaping (URL) -> Void
  ) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.prompt = L("导出")
    panel.nameFieldStringValue = exportName + "." + ext
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let dest = panel.url else { return }
      perform(dest)
    }
  }

  private func startExport(
    _ operation: @escaping (ExportJob, Project, @escaping (Double) -> Void) throws -> [URL]
  ) {
    guard progress == nil else { return }
    pause()
    let task = ExportJob()
    let snap = p
    job = task
    progress = 0
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result {
        try operation(task, snap) { v in
          DispatchQueue.main.async { self.progress = v }
        }
      }
      DispatchQueue.main.async {
        self.progress = nil
        self.job = nil
        switch result {
        case .success(let files):
          self.status = L("已导出 ") + files.map(\.lastPathComponent).joined(separator: "、")
          NSWorkspace.shared.activateFileViewerSelecting(files)
        case .failure(let e):
          if task.cancelled { self.status = L("已取消导出") } else { self.error = e.localizedDescription }
        }
      }
    }
  }
  func cancelExport() { job?.cancel() }
}
