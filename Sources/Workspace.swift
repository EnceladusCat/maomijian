import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

func finishWorkspaceTextEditing() {
  guard let window = NSApp.keyWindow, window.attachedSheet == nil,
    (window.firstResponder as? NSText)?.isEditable == true else { return }
  window.makeFirstResponder(nil)
}

enum UI {
  static let panel = Color(red: 0.145, green: 0.165, blue: 0.206),
    deep = Color(red: 0.097, green: 0.112, blue: 0.145)
  static let well = Color(red: 0.185, green: 0.208, blue: 0.26),
    accent = Color(red: 0.67, green: 0.65, blue: 1)
  static let muted = Color(red: 0.70, green: 0.74, blue: 0.81)
  static let buttonTint = Color(red: 1, green: 0.87, blue: 0.62)
  static let mint = Color(red: 0.74, green: 0.91, blue: 0.82)
  static let coral = Color(red: 0.98, green: 0.73, blue: 0.71)
  static func color(_ k: Kind) -> Color {
    switch k {
    case .video: return Color(red: 0.48, green: 0.68, blue: 0.92)
    case .audio: return Color(red: 0.45, green: 0.80, blue: 0.72)
    case .caption: return Color(red: 0.98, green: 0.77, blue: 0.48)
    case .zoom: return Color(red: 0.78, green: 0.60, blue: 0.92)
    case .chart: return mint
    case .editorial: return buttonTint
    case .audioVisual: return mint
    default: return Color(red: 0.95, green: 0.65, blue: 0.68)
    }
  }
}
struct PrimaryButton: ButtonStyle {
  var tint = UI.buttonTint
  @Environment(\.isEnabled) var enabled
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 9)
    configuration.label
      .font(.system(size: 13, weight: .semibold, design: .rounded))
      .padding(.horizontal, 11).frame(minHeight: 34)
      .foregroundStyle(UI.deep)
      .background(
        tint.opacity(configuration.isPressed ? 0.78 : 1), in: shape
      )
      .overlay {
        shape.strokeBorder(Color.white.opacity(hovering ? 0.76 : 0.28), lineWidth: 1)
          .allowsHitTesting(false)
      }
      .contentShape(shape)
      .opacity(enabled ? 1 : 0.42)
      .onHover { hovering = $0 }
  }
}
struct QuietButton: ButtonStyle {
  @Environment(\.isEnabled) var enabled
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .padding(.horizontal, 8).frame(minHeight: 26)
      .foregroundStyle(hovering && enabled ? .white : UI.muted)
      .background(
        Color.white.opacity(configuration.isPressed ? 0.17 : hovering ? 0.10 : 0.045),
        in: RoundedRectangle(cornerRadius: 6)
      ).contentShape(RoundedRectangle(cornerRadius: 6))
      .opacity(enabled ? 1 : 0.38)
      .onHover { hovering = $0 }
  }
}
struct PanelSegments<Value: Hashable>: View {
  let title: String
  let options: [Value]
  @Binding var selection: Value
  var tint = UI.accent
  let name: (Value) -> String

  var body: some View {
    HStack(spacing: 3) {
      ForEach(options, id: \.self) { option in
        let selected = option == selection
        Button { selection = option } label: {
          Text(name(option)).font(.system(size: 11, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.80)
            .padding(.horizontal, 4).frame(maxWidth: .infinity).frame(height: 25)
            .foregroundStyle(selected ? UI.deep : UI.muted)
            .background(selected ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
      }
    }.padding(3).background(UI.deep, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .contain).accessibilityLabel(title)
  }
}
struct Tool: View {
  let symbol: String, label: String
  var size: CGFloat = 25
  let act: () -> Void
  var body: some View {
    Button(action: act) {
      Image(systemName: symbol).frame(width: size, height: size).contentShape(Rectangle())
    }.buttonStyle(.plain).help(label).accessibilityLabel(label)
  }
}
struct SectionName: View {
  let name: String
  var body: some View {
    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.muted)
  }
}
struct PlayerSurface: NSViewRepresentable {
  final class Surface: NSView {
    let video = AVPlayerLayer()
    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer?.backgroundColor = NSColor.black.cgColor
      video.videoGravity = .resizeAspect
      layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
      super.layout()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      video.frame = bounds
      CATransaction.commit()
    }
  }
  let player: AVPlayer
  let background: String
  func makeNSView(context: Context) -> Surface {
    let v = Surface()
    v.video.player = player
    return v
  }
  func updateNSView(_ nsView: Surface, context: Context) {
    nsView.layer?.backgroundColor = ink(background)
  }
}
private struct CaptionCanvasPreview: View {
  let composition: Composition
  @ObservedObject var transport: Transport
  @ObservedObject var liveCanvas: LiveCanvasPreview

  var body: some View {
    if !transport.playing || composition.captionOnlyPreview,
      let preview = composition.captionPreview(at: transport.frame)
    {
      CaptionCanvasFrame(slice: preview.slice, frame: preview.frame, draft: liveCanvas.captionDraft)
        .equatable()
    }
  }
}

struct CaptionCanvasFrame: View, Equatable {
  let slice: Slice
  let frame: Int
  var draft: Clip? = nil

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.slice === rhs.slice && lhs.frame == rhs.frame && lhs.draft == rhs.draft
  }

  var body: some View {
    let fillsBackground = slice.compositedClips.isEmpty
    SwiftUI.Canvas(opaque: fillsBackground, rendersAsynchronously: true) { context, size in
      let painter = slice.painter
      context.withCGContext { target in
        // SwiftUI starts top-down, while the compositor painter takes a bottom-up context.
        target.translateBy(x: 0, y: size.height)
        target.scaleBy(x: size.width / painter.size.width, y: -size.height / painter.size.height)
        if fillsBackground {
          target.setFillColor(ink(painter.project.background))
          target.fill(CGRect(origin: .zero, size: painter.size))
        }
        let captions = draft.map { draft in slice.captions.map { $0.id == draft.id ? draft : $0 } }
        painter.paintCaptions(target, frame: frame, active: captions ?? slice.captions)
      }
    }.allowsHitTesting(false)
  }
}

private struct PreviewScrollSurface: NSViewRepresentable {
  let zoom: (Double) -> Void

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) { view.zoom = zoom }

  final class Surface: NSView {
    var zoom: ((Double) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, let window = self.window, event.window === window,
          window.attachedSheet == nil, NSApp.modalWindow == nil, !self.isHiddenOrHasHiddenAncestor,
          self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil)),
          event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        else { return event }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.deltaY * 0.12
        self.zoom?(exp(bound(delta, -0.4, 0.4)))
        return nil
      }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

struct Preview: View {
  @ObservedObject var e: Editor
  private let zoomRange = 0.25...4.0
  @State private var zoom = 1.0
  @GestureState private var pinch = 1.0
  @State private var pan = CGSize.zero
  @GestureState private var panGesture = CGSize.zero
  @State private var hand = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        SectionName(name: L("画布"))
        ProjectColorPicker(title: L("画布背景"), hex: e.p.background) { color in
          e.change { $0.backgroundColor = color }
        }.labelsHidden().fixedSize().help(L("画布背景颜色")).accessibilityLabel(L("画布背景颜色"))
        Spacer()
        Picker(
          L("比例"), selection: Binding(get: { e.p.canvas }, set: { v in e.change { $0.canvas = v } })
        ) { ForEach(Canvas.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
          .fixedSize()
        Picker(
          L("预览精度"),
          selection: Binding(
            get: { e.preview },
            set: {
              e.preview = $0
              e.rebuild()
            })
        ) {
          Text(L("360p 预览")).tag(360)
          Text(L("540p 预览")).tag(540)
          Text(L("720p 预览")).tag(720)
          Text(L("1080p 预览")).tag(1080)
        }.labelsHidden().fixedSize()
      }.padding(.horizontal, 14).frame(height: 40)
      GeometryReader { geo in
        let shape = e.p.canvas.size(540)
        let factor = min(
          max(1, geo.size.width - 32) / shape.width, max(1, geo.size.height - 24) / shape.height)
        let displayZoom = bound(zoom * pinch, zoomRange.lowerBound, zoomRange.upperBound)
        let w = shape.width * factor * displayZoom
        let h = shape.height * factor * displayZoom
        let canvasSize = CGSize(width: w, height: h)
        let visibleCanvas = CGRect(
          x: (w - geo.size.width) / 2 - pan.width - panGesture.width,
          y: (h - geo.size.height) / 2 - pan.height - panGesture.height,
          width: geo.size.width, height: geo.size.height)
        let drawing = e.pathDrawingID
        let colorPick = e.backgroundColorPick
        let regionTool = e.regionTool
        ZStack {
          UI.deep
          ZStack {
            PlayerSurface(player: e.player, background: e.p.background).allowsHitTesting(false)
            ScrubPreviewOverlay(preview: e.scrubPreview)
            LiveCanvasOverlay(preview: e.liveCanvas)
            if let composition = e.previewComposition {
              CaptionCanvasPreview(composition: composition, transport: e.transport, liveCanvas: e.liveCanvas)
            }
          }.frame(width: w, height: h).background(Color(cgColor: ink(e.p.background)))
            .overlay {
              if !hand && !e.p.clips.isEmpty {
                CanvasPickSurface(editor: e, visible: visibleCanvas)
              }
            }
            .overlay {
              let selection = e.selectedIDs.count == 1 ? e.clip : nil
              if selection != nil || drawing != nil || colorPick != nil || regionTool != nil {
                CanvasControls(
                  e: e, t: e.transport, size: canvasSize, hand: hand,
                  selection: selection, mediaSize: selection?.asset.flatMap { e.mediaSizes[$0] },
                  cropID: e.cropID, captionStyle: e.p.captionStyle,
                  drawing: drawing, colorPick: colorPick, regionTool: regionTool
                ).frame(width: w, height: h)
              }
            }
            .coordinateSpace(name: "canvas")
            .position(
              x: geo.size.width / 2 + pan.width + panGesture.width,
              y: geo.size.height / 2 + pan.height + panGesture.height)
          if e.p.clips.isEmpty && drawing == nil && colorPick == nil && regionTool == nil && !hand {
            EmptyWorkspaceMenu(e: e, recent: e.recentProjects)
              .padding(.horizontal, 14).padding(.vertical, 6)
          }
          if hand && drawing == nil && colorPick == nil && regionTool == nil {
            Color.white.opacity(0.001).contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 0).updating($panGesture) { value, state, _ in
                  state = value.translation
                }.onEnded { value in
                  pan.width += value.translation.width
                  pan.height += value.translation.height
                })
          }
        }.frame(width: geo.size.width, height: geo.size.height)
          .clipped()
          .background {
            PreviewScrollSurface { factor in adjustZoom(by: factor) }
              .accessibilityHidden(true)
          }
          .contentShape(.interaction, Rectangle())
          .simultaneousGesture(
          TapGesture().onEnded { if !e.p.clips.isEmpty { finishWorkspaceTextEditing() } }
        ).simultaneousGesture(
          MagnificationGesture().updating($pinch) { value, state, _ in
            state = value
          }.onEnded { value in adjustZoom(by: value) })
      }
      HStack(spacing: 6) {
        Tool(symbol: hand ? "hand.raised.fill" : "hand.raised", label: L("拖动画布视图")) {
          hand.toggle()
        }.foregroundStyle(hand && e.pathDrawingID == nil && e.backgroundColorPick == nil && e.regionTool == nil
          ? UI.accent : UI.muted)
          .disabled(e.pathDrawingID != nil || e.backgroundColorPick != nil || e.regionTool != nil)
        Slider(value: $zoom, in: zoomRange)
          .controlSize(.small).frame(width: 88).accessibilityLabel(L("预览缩放"))
        Text("\(Int((bound(zoom * pinch, zoomRange.lowerBound, zoomRange.upperBound) * 100).rounded()))%")
          .font(.system(size: 11, design: .monospaced)).frame(width: 34, alignment: .trailing)
        Button(L("适应")) {
          zoom = 1
          pan = .zero
          hand = false
        }.buttonStyle(QuietButton())
        Spacer()
        if let pick = e.backgroundColorPick {
          Text(pick.image == nil ? L("正在准备取色画面…") : L("点击要去除的背景颜色"))
            .font(.caption).foregroundStyle(UI.mint).lineLimit(1)
          Button(L("取消"), action: e.cancelBackgroundColorPick).buttonStyle(QuietButton())
        } else if e.pathDrawingID != nil {
          Text(L("拖动画出素材中心的路径")).font(.caption).foregroundStyle(UI.mint).lineLimit(1)
          Button(L("取消"), action: e.cancelPathDrawing).buttonStyle(QuietButton())
        } else if e.selectedIDs.count == 1 && e.cropID == e.selected && e.cropID != nil {
          Button(L("完成裁剪")) { e.cropID = nil }.controlSize(.small)
        }
      }.padding(.horizontal, 12).frame(height: 31).background(UI.deep)
      TransportBar(t: e.transport, e: e, duration: e.timelineDuration)
    }.background(UI.panel)
  }

  private func adjustZoom(by factor: Double) {
    let next = bound(zoom * factor, zoomRange.lowerBound, zoomRange.upperBound)
    if next != zoom { zoom = next }
  }
}
private struct CanvasControls: View {
  let e: Editor
  @ObservedObject var t: Transport
  let size: CGSize
  let hand: Bool
  // Project edits can leave the playhead unchanged. Pass their values so
  // SwiftUI refreshes the handles even when Transport has nothing to publish.
  let selection: Clip?
  let mediaSize: CGSize?
  let cropID: UUID?
  let captionStyle: CaptionStyle?
  let drawing: UUID?
  let colorPick: BackgroundColorPick?
  let regionTool: Kind?
  @State private var draft: Clip?
  @State private var move: CanvasMove?
  @State private var xGuide: CanvasMove.Guide?
  @State private var yGuide: CanvasMove.Guide?

  var body: some View {
    let w = size.width
    let h = size.height
    let selectedRegion = selection.flatMap { c in
      c.kind.isRegion && c.start <= t.frame && t.frame < c.end ? c : nil
    }
    if let colorPick {
      if let image = colorPick.image {
        UI.deep
        Image(decorative: image, scale: 1).resizable().allowsHitTesting(false)
        BackgroundColorPickSurface(pick: e.useBackgroundSample)
          .frame(width: w, height: h)
          .accessibilityLabel(L("在画布中吸管取色"))
      }
    } else if let id = drawing {
      MotionPathDrawingSurface { stroke, canvas in e.finishPathDrawing(for: id, stroke: stroke, canvas: canvas) }
        .frame(width: w, height: h).id(id)
        .accessibilityLabel(L("绘制运动路径"))
    } else if regionTool != nil || (!hand && selectedRegion != nil) {
      RegionControls(e: e, c: selectedRegion, size: size)
    } else if !hand, !t.playing, let c = selection, c.kind == .video,
      let source = mediaSize,
      c.start <= t.frame, t.frame < c.end
    {
      MediaHandles(
        editor: e, clip: c, canvas: CGSize(width: w, height: h),
        aspect: source.width / source.height, frame: t.frame, cropping: cropID == c.id
      )
      .id(c.id)
    } else if !hand, !t.playing, let c = selection, !c.kind.isMedia,
      c.start <= t.frame,
      t.frame < c.end
    {
      let object = CanvasObject(clip: draft?.id == c.id ? draft ?? c : c, frame: t.frame, canvas: size,
                                mediaSize: nil, style: captionStyle)
      Path(object.path)
      .applying(object.transform)
      .stroke(UI.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      .contentShape(Path(object.path).applying(object.transform))
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas")).onChanged { v in
          if move == nil {
            move = CanvasMove(item: object, canvas: size, neighbors: e.canvasObjects(at: t.frame, size: size))
          }
          guard let result = move?.translated(by: v.translation) else { return }
          draft = result.clip
          xGuide = result.x
          yGuide = result.y
          e.previewCanvas(result.clip)
        }.onEnded { v in
          if let result = move?.translated(by: v.translation) { e.commitCanvas(result.clip) }
          clearGuides()
        })
      .onDisappear {
        if e.liveCanvas.activeID == c.id { e.liveCanvas.clear() }
        clearGuides()
      }
      CanvasGuides(x: xGuide, y: yGuide, canvas: size, pixelsPerPoint: e.p.canvas.size(e.preview).width / w)
    }
    if drawing == nil, colorPick == nil, !hand, !t.playing, cropID == nil, regionTool == nil,
      let clip = selection, (clip.start..<clip.end).contains(t.frame),
      let path = clip.motionPath
    {
      MotionPathGuide(path: path, clip: clip, canvas: size)
    }
  }

  private func clearGuides() {
    draft = nil
    move = nil
    xGuide = nil
    yGuide = nil
  }
}

struct Library: View {
  let e: Editor
  @ObservedObject var updates: PanelUpdates
  @State private var assetFrames = [UUID: CGRect]()
  private let marqueeSpace = "libraryMarquee"
  private var blank: some View {
    MarqueeBlank(selection: e.libraryMarquee) { e.pickMarquee([], modifiers: [], inLibrary: true) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(L("素材")).font(.headline)
        if !e.libraryIDs.isEmpty {
          Button(L("插入所选（\(e.libraryIDs.count)）")) {
            let ids = Set(e.libraryIDs)
            e.insertAssets(e.p.assets.filter { ids.contains($0.id) }, at: e.transport.frame)
          }.controlSize(.small)
        }
        Spacer()
        Tool(symbol: "plus", label: L("导入素材"), act: e.importPanel)
      }.padding(.horizontal, 14).frame(height: 40)
      ImageEnhancementProgress(enhancement: e.imageEnhancement)
      if e.p.assets.isEmpty {
        Button(action: e.importPanel) {
          HStack {
            Image(systemName: "folder.badge.plus")
            Text(L("添加本地文件"))
            Spacer()
          }.padding(12).background(UI.well, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).padding(.horizontal, 10)
      } else {
        GeometryReader { viewport in
          let rowsHeight = 44 * CGFloat(e.p.assets.count)
          let footerHeight = max(16, viewport.size.height - rowsHeight)
          ScrollView {
            HStack(alignment: .top, spacing: 0) {
              blank.frame(width: 10, height: rowsHeight + footerHeight)
              VStack(spacing: 0) {
                ForEach(e.p.assets) { media in
                  assetRow(media).frame(height: 38)
                    .background(MarqueeTarget(id: media.id, space: marqueeSpace))
                  blank.frame(height: 6)
                }
                blank.frame(height: footerHeight)
              }
              blank.frame(width: 10, height: rowsHeight + footerHeight)
            }.fixedSize(horizontal: false, vertical: true)
          }.overlay {
            MarqueeOverlay(selection: e.libraryMarquee) { box, flags in
              let hits = e.p.assets.compactMap { asset in
                assetFrames[asset.id]?.intersects(box) == true ? asset.id : nil
              }
              e.pickMarquee(hits, modifiers: flags, inLibrary: true)
            }.allowsHitTesting(false)
          }.coordinateSpace(name: marqueeSpace)
            .onPreferenceChange(MarqueeBounds<UUID>.self) { assetFrames = $0 }
        }
      }
    }
  }
  private func assetRow(_ m: Media) -> some View {
    HStack(spacing: 5) {
      HStack(spacing: 8) {
        ZStack {
          RoundedRectangle(cornerRadius: 4).fill(UI.deep)
          if let im = e.thumbnails[m.id] {
            Image(nsImage: im).resizable().scaledToFill()
          } else {
            Image(systemName: m.isStill ? "photo" : m.video ? "film" : "waveform")
              .foregroundStyle(UI.color(m.video ? .video : .audio))
          }
        }.frame(width: 50, height: 32).clipped().cornerRadius(4)
        VStack(alignment: .leading, spacing: 2) {
          Text(m.name).lineLimit(1)
          HStack(spacing: 5) {
            Text(tc(m.frames)).monospacedDigit()
            if m.video && m.audio {
              Image(systemName: "speaker.wave.2").help(L("含音频")).accessibilityLabel(L("含音频"))
            }
          }.font(.caption).foregroundStyle(UI.muted)
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .onTapGesture { e.pickAsset(m.id, modifiers: NSEvent.modifierFlags) }
      if m.isStill {
        Tool(symbol: "sparkles", label: L("RealPLKSR 高清化")) { e.enhanceImage(m) }
      }
      Tool(symbol: "plus.circle", label: L("在播放头插入")) { e.append(m, at: e.transport.frame) }
    }.padding(3).background(
      e.libraryIDs.contains(m.id) ? UI.accent.opacity(0.25) : .clear,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contextMenu {
      Button(L("在播放头插入")) { e.append(m, at: e.transport.frame) }
      if m.isStill { Button(L("RealPLKSR 高清化")) { e.enhanceImage(m) } }
      if m.soundID == nil { Button(L("重新定位文件…")) { e.relink(m) } }
    }.help(m.path)
  }
}

private struct ImageEnhancementProgress: View {
  @ObservedObject var enhancement: ImageEnhancement

  var body: some View {
    if let progress = enhancement.progress {
      HStack(spacing: 8) {
        Text(L("正在高清化图片")).font(.caption).foregroundStyle(UI.muted).lineLimit(1)
        ProgressView(value: progress)
          .accessibilityLabel(L("正在高清化图片"))
        Tool(symbol: "xmark.circle", label: L("取消高清化")) { enhancement.cancel() }
      }.padding(.horizontal, 14).padding(.bottom, 8)
    }
  }
}
private struct HeaderCommand: View {
  let symbol: String
  let label: String
  let action: () -> Void
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 29, height: 30)
        .foregroundStyle(hovered && enabled ? .white : enabled ? UI.muted : UI.muted.opacity(0.44))
        .background(
          hovered && enabled ? UI.accent.opacity(0.16) : .clear,
          in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
    .help(label)
    .accessibilityLabel(label)
  }
}

struct Workspace: View {
  @ObservedObject var e: Editor
  let recordScreen: () -> Void
  @State private var over = false
  @State private var showsExportFormats = false
  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 1) {
        HStack(spacing: 10) {
          SwiftUI.Canvas { context, size in
            context.withCGContext { graphics in
              BrandMark.draw(in: CGRect(origin: .zero, size: size), context: graphics)
            }
          }.frame(width: 27, height: 27).accessibilityHidden(true)
          Text(AppLanguage.appName).font(.system(size: 19, weight: .bold))
          Divider().frame(height: 17)
          let name = e.url?.deletingPathExtension().lastPathComponent ?? L("未命名工程")
          HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.middle).help(name)
            if e.dirty {
              Circle().fill(UI.buttonTint).frame(width: 4, height: 4)
                .help(L("有未保存的更改")).accessibilityLabel(L("有未保存的更改"))
            }
          }.frame(maxWidth: 230, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
          NightCityBanner(transport: e.transport, exporting: e.progress != nil)
            .frame(maxWidth: .infinity).frame(height: 48)
            .allowsHitTesting(false).accessibilityHidden(true)
          HeaderCommand(symbol: "arrow.uturn.backward", label: L("撤销（⌘Z）"), action: e.undo).disabled(!e.canUndo)
          HeaderCommand(symbol: "arrow.uturn.forward", label: L("重做（⇧⌘Z）"), action: e.redo).disabled(!e.canRedo)
          HeaderCommand(symbol: "square.and.arrow.down", label: L("保存工程（⌘S）")) { e.save() }
          Divider().frame(height: 17)
          HeaderCommand(symbol: "record.circle", label: L("录制屏幕…"), action: recordScreen)
          if let v = e.progress {
            ProgressView(value: v).frame(width: 68)
            Text("\(Int(v*100))%").monospacedDigit()
            Button(L("取消"), action: e.cancelExport).buttonStyle(QuietButton())
          } else {
            Picker(L("导出分辨率"), selection: $e.exportShort) {
              Text("1080p").tag(1080)
              Text("720p").tag(720)
            }.labelsHidden().fixedSize()
            Button {
              showsExportFormats.toggle()
            } label: {
              HStack(spacing: 7) {
                Text(L("导出"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
              }.frame(minWidth: 64)
            }.buttonStyle(PrimaryButton()).disabled(e.p.duration == 0)
              .accessibilityLabel(L("导出")).help(L("选择导出格式"))
          }
        }.padding(.horizontal, 16).frame(height: 48).background(UI.panel)
        HStack(spacing: 1) {
          ToolShelf(e: e).frame(width: (geo.size.width < 1080 ? 236 : 274)
            + (AppLanguage.current == .english ? 24 : 0))
          Preview(e: e).frame(maxWidth: .infinity)
          InspectorHost(editor: e).frame(width: geo.size.width < 1080 ? 206 : 235)
        }.frame(maxHeight: .infinity)
        Timeline(e: e, waveforms: e.waveforms).frame(height: bound(geo.size.height * 0.35, 215, 360))
        EditorStatus(state: e.previewStatus)
      }.background(UI.deep).foregroundStyle(Color.white).preferredColorScheme(.dark)
        .coordinateSpace(name: DropBandKey.coordinateSpace)
        .overlay {
          if over {
            RoundedRectangle(cornerRadius: 7).strokeBorder(UI.accent, lineWidth: 3)
              .allowsHitTesting(false)
          }
        }
        .overlay {
          if showsExportFormats {
            ZStack(alignment: .topTrailing) {
              Button { showsExportFormats = false } label: {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
              }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityHidden(true)
              ExportFormatMenu(editor: e) { showsExportFormats = false }
                .padding(.top, 47).padding(.trailing, 16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          }
        }
        .onChange(of: e.progress != nil || e.p.duration == 0) { unavailable in
          if unavailable { showsExportFormats = false }
        }
        .onPreferenceChange(DropBandKey.self) { e.dropBands = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $over) { providers in
          let group = DispatchGroup()
          let lock = NSLock()
          var loaded = [Int: URL]()
          for (idx, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
              item, _ in
              let u =
                (item as? URL)
                ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
              if let u {
                lock.lock()
                loaded[idx] = u
                lock.unlock()
              }
              group.leave()
            }
          }
          group.notify(queue: .main) {
            let urls = loaded.sorted { $0.key < $1.key }.map(\.value)
            if urls.count == 1, urls[0].pathExtension == "framecut" {
              e.open(urls[0])
            } else {
              e.importURLs(urls)
            }
          }
          return true
        }
        .alert(
          AppLanguage.appName,
          isPresented: Binding(get: { e.error != nil }, set: { if !$0 { e.error = nil } })
        ) {
          Button(L("好")) { e.error = nil }
        } message: {
          Text(e.error ?? "")
        }
    }
  }
}

private struct EditorStatus: View {
  @ObservedObject var state: PreviewStatus
  var body: some View {
    HStack {
      Circle().fill(state.busy ? UI.accent : UI.color(.audio)).frame(width: 6, height: 6)
      Text(state.message).lineLimit(1)
      Spacer()
      Text("30 fps").monospacedDigit()
    }.font(.caption).foregroundStyle(UI.muted).padding(.horizontal, 12).frame(height: 23)
      .background(UI.panel)
  }
}
