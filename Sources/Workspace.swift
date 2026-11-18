import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum UI {
  static let panel = Color(red: 0.145, green: 0.165, blue: 0.206),
    deep = Color(red: 0.097, green: 0.112, blue: 0.145)
  static let well = Color(red: 0.185, green: 0.208, blue: 0.26),
    accent = Color(red: 0.67, green: 0.65, blue: 1)
  static let muted = Color(red: 0.70, green: 0.74, blue: 0.81)
  static func color(_ k: Kind) -> Color {
    switch k {
    case .video: return Color(red: 0.48, green: 0.68, blue: 0.92)
    case .audio: return Color(red: 0.45, green: 0.80, blue: 0.72)
    case .caption: return Color(red: 0.98, green: 0.77, blue: 0.48)
    case .zoom: return Color(red: 0.78, green: 0.60, blue: 0.92)
    default: return Color(red: 0.95, green: 0.65, blue: 0.68)
    }
  }
}
struct PrimaryButton: ButtonStyle {
  @Environment(\.isEnabled) var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
      .foregroundStyle(UI.deep).background(
        UI.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 5)
      )
      .opacity(enabled ? 1 : 0.45)
  }
}
struct Tool: View {
  let symbol: String, label: String, act: () -> Void
  var body: some View {
    Button(action: act) {
      Image(systemName: symbol).frame(width: 25, height: 25).contentShape(Rectangle())
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
struct TransportBar: View {
  @ObservedObject var t: Transport
  let e: Editor
  var body: some View {
    HStack(spacing: 8) {
      Text(tc(t.frame)).font(.system(size: 14, weight: .medium, design: .monospaced))
      Text("/ " + tc(e.p.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(
        UI.muted)
      Spacer()
      Tool(symbol: "backward.end.fill", label: "回到开头") { e.seek(0) }
      Tool(symbol: t.playing ? "pause.fill" : "play.fill", label: "播放 / 暂停（空格）") { e.play() }
      Tool(symbol: "forward.end.fill", label: "跳到结尾") { e.seek(e.p.duration) }
    }.padding(.horizontal, 16).frame(height: 40)
  }
}
struct Preview: View {
  @ObservedObject var e: Editor
  @ObservedObject var t: Transport
  @State private var delta = CGSize.zero
  @State private var zoom = 1.0
  @GestureState private var pinch = 1.0
  @State private var pan = CGSize.zero
  @GestureState private var panGesture = CGSize.zero
  @State private var hand = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        SectionName(name: "画布")
        ProjectColorPicker(title: "画布背景", hex: e.p.background) { color in
          e.change { $0.backgroundColor = color }
        }.labelsHidden().fixedSize().help("画布背景颜色").accessibilityLabel("画布背景颜色")
        Spacer()
        Picker(
          "比例", selection: Binding(get: { e.p.canvas }, set: { v in e.change { $0.canvas = v } })
        ) { ForEach(Canvas.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
          .fixedSize()
        Picker(
          "预览精度",
          selection: Binding(
            get: { e.preview },
            set: {
              e.preview = $0
              e.rebuild()
            })
        ) {
          Text("360p 预览").tag(360)
          Text("540p 预览").tag(540)
          Text("720p 预览").tag(720)
          Text("1080p 预览").tag(1080)
        }.labelsHidden().fixedSize()
      }.padding(.horizontal, 14).frame(height: 40)
      GeometryReader { geo in
        let shape = e.p.canvas.size(540)
        let factor = min(
          max(1, geo.size.width - 32) / shape.width, max(1, geo.size.height - 24) / shape.height)
        let displayZoom = bound(zoom * pinch, 0.25, 4)
        let w = shape.width * factor * displayZoom
        let h = shape.height * factor * displayZoom
        ZStack {
          UI.deep
          ZStack {
            PlayerSurface(player: e.player, background: e.p.background).allowsHitTesting(false)
            LiveCanvasOverlay(preview: e.liveCanvas)
            if e.p.clips.isEmpty {
              VStack(spacing: 13) {
                Image(systemName: "film.stack").font(.system(size: 32, weight: .light))
                  .foregroundStyle(UI.muted)
                Button("导入素材", action: e.importPanel).buttonStyle(PrimaryButton())
                Text("也可以把文件拖到窗口中").font(.caption).foregroundStyle(UI.muted)
              }
            }
            let selectedRegion = (e.selectedIDs.count == 1 ? e.clip : nil).flatMap { c in
              c.kind.isRegion && c.start <= t.frame && t.frame < c.end ? c : nil
            }
            if !hand && (e.regionTool != nil || selectedRegion != nil) {
              RegionControls(e: e, c: selectedRegion, size: CGSize(width: w, height: h))
            } else if !hand, !t.playing, e.selectedIDs.count == 1, let c = e.clip, c.kind == .video,
              let id = c.asset, let source = e.mediaSizes[id],
              c.start <= t.frame, t.frame < c.end
            {
              MediaHandles(
                editor: e, clip: c, canvas: CGSize(width: w, height: h),
                aspect: source.width / source.height, frame: t.frame, cropping: e.cropID == c.id
              )
              .id(c.id)
            } else if !hand, e.selectedIDs.count == 1, let c = e.clip, !c.kind.isMedia,
              c.start <= t.frame,
              t.frame < c.end
            {
              let ww = w * c.w
              let hh = h * c.h
              RoundedRectangle(cornerRadius: 2).strokeBorder(
                UI.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])
              )
              .background(Color.white.opacity(0.002)).frame(width: ww, height: hh).rotationEffect(
                .degrees(c.angle)
              )
              .position(x: c.x * w + delta.width, y: c.y * h + delta.height)
              .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas")).onChanged { v in
                  delta = v.translation
                  var draft = c
                  draft.x = bound(c.x + v.translation.width / w, 0, 1)
                  draft.y = bound(c.y + v.translation.height / h, 0, 1)
                  e.previewCanvas(draft)
                }.onEnded { v in
                  var draft = c
                  draft.x = bound(c.x + v.translation.width / w, 0, 1)
                  draft.y = bound(c.y + v.translation.height / h, 0, 1)
                  e.commitCanvas(draft)
                  delta = .zero
                })
              .onDisappear {
                if e.liveCanvas.activeID == c.id { e.liveCanvas.clear() }
                delta = .zero
              }
            }
          }.frame(width: w, height: h).background(Color(cgColor: ink(e.p.background)))
            .coordinateSpace(name: "canvas")
            .position(
              x: geo.size.width / 2 + pan.width + panGesture.width,
              y: geo.size.height / 2 + pan.height + panGesture.height)
          if hand {
            Color.white.opacity(0.001).contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 0).updating($panGesture) { value, state, _ in
                  state = value.translation
                }.onEnded { value in
                  pan.width += value.translation.width
                  pan.height += value.translation.height
                })
          }
        }.clipped().simultaneousGesture(
          MagnificationGesture().updating($pinch) { value, state, _ in
            state = value
          }.onEnded { value in zoom = bound(zoom * value, 0.25, 4) })
      }
      HStack(spacing: 6) {
        Tool(symbol: hand ? "hand.raised.fill" : "hand.raised", label: "拖动画布视图") {
          hand.toggle()
        }.foregroundStyle(hand ? UI.accent : UI.muted)
        Slider(value: $zoom, in: 0.25...4)
          .controlSize(.small).frame(width: 88).accessibilityLabel("预览缩放")
        Text("\(Int((bound(zoom * pinch, 0.25, 4) * 100).rounded()))%")
          .font(.system(size: 11, design: .monospaced)).frame(width: 34, alignment: .trailing)
        Button("适应") {
          zoom = 1
          pan = .zero
          hand = false
        }.controlSize(.small)
        Spacer()
        if e.selectedIDs.count == 1 && e.cropID == e.selected && e.cropID != nil {
          Button("完成裁剪") { e.cropID = nil }.controlSize(.small)
        }
      }.padding(.horizontal, 12).frame(height: 31).background(UI.deep)
      TransportBar(t: t, e: e)
    }.background(UI.panel)
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
        Text("素材").font(.headline)
        if !e.libraryIDs.isEmpty {
          Button("插入所选（\(e.libraryIDs.count)）") {
            let ids = Set(e.libraryIDs)
            e.insertAssets(e.p.assets.filter { ids.contains($0.id) }, at: e.transport.frame)
          }.controlSize(.small)
        }
        Spacer()
        Tool(symbol: "plus", label: "导入素材", act: e.importPanel)
      }.padding(.horizontal, 14).frame(height: 40)
      if e.p.assets.isEmpty {
        Button(action: e.importPanel) {
          HStack {
            Image(systemName: "folder.badge.plus")
            Text("添加本地文件")
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
          Text(tc(m.frames)).font(.caption.monospacedDigit()).foregroundStyle(UI.muted)
        }
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .onTapGesture { e.pickAsset(m.id, modifiers: NSEvent.modifierFlags) }
      Tool(symbol: "plus.circle", label: "在播放头插入") { e.append(m, at: e.transport.frame) }
    }.padding(3).background(
      e.libraryIDs.contains(m.id) ? UI.accent.opacity(0.25) : .clear,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contextMenu {
      Button("在播放头插入") { e.append(m, at: e.transport.frame) }
      if m.soundID == nil { Button("重新定位文件…") { e.relink(m) } }
    }.help(m.path)
  }
}
struct AnnotationPanel: View {
  let e: Editor
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("添加到播放头").font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.muted).padding(
        .horizontal, 14
      ).padding(.vertical, 10)
      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6
      ) {
        ForEach(
          [Kind.text, .timer, .arrow, .rectangle, .ellipse, .highlight, .zoom, .caption], id: \.self
        ) { k in
          Button {
            e.add(k)
          } label: {
            HStack(spacing: 7) {
              Image(systemName: k.icon).foregroundStyle(UI.color(k)).frame(width: 17)
              Text(k.title).lineLimit(1).minimumScaleFactor(0.76)
              Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(height: 28).background(
              UI.well, in: RoundedRectangle(cornerRadius: 4)
            ).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        Button {
          e.subtitleImport()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "square.and.arrow.down")
            Text("SRT")
          }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help("导入 SRT 字幕")
      }.padding(.horizontal, 10).padding(.bottom, 12)
    }.background(UI.panel)
  }
}
struct Workspace: View {
  @ObservedObject var e: Editor
  @State private var over = false
  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 1) {
        HStack(spacing: 10) {
          Image(systemName: "square.3.layers.3d.down.right").font(
            .system(size: 22, weight: .semibold)
          ).foregroundStyle(UI.accent)
          Text("毛咪剪").font(.system(size: 19, weight: .bold))
          Divider().frame(height: 17)
          Text(
            (e.url?.deletingPathExtension().lastPathComponent ?? "未命名工程") + (e.dirty ? " •" : "")
          ).lineLimit(1)
          Spacer()
          Tool(symbol: "arrow.uturn.backward", label: "撤销（⌘Z）", act: e.undo).disabled(!e.canUndo)
          Tool(symbol: "arrow.uturn.forward", label: "重做（⇧⌘Z）", act: e.redo).disabled(!e.canRedo)
          Tool(symbol: "square.and.arrow.down", label: "保存工程（⌘S）") { e.save() }
          Divider().frame(height: 17)
          if let v = e.progress {
            ProgressView(value: v).frame(width: 68)
            Text("\(Int(v*100))%").monospacedDigit()
            Button("取消", action: e.cancelExport)
          } else {
            Picker("导出分辨率", selection: $e.exportShort) {
              Text("1080p").tag(1080)
              Text("720p").tag(720)
            }.labelsHidden().fixedSize()
            Button(action: e.export) {
              Label("导出 MP4", systemImage: "square.and.arrow.up").fontWeight(.semibold)
            }.buttonStyle(PrimaryButton()).disabled(e.p.duration == 0)
          }
        }.padding(.horizontal, 16).frame(height: 48).background(UI.panel)
        HStack(spacing: 1) {
          ToolShelf(e: e).frame(width: geo.size.width < 1080 ? 236 : 274)
          Preview(e: e, t: e.transport).frame(maxWidth: .infinity)
          InspectorHost(editor: e).frame(width: geo.size.width < 1080 ? 206 : 235)
        }.frame(maxHeight: .infinity)
        Timeline(e: e).frame(height: bound(geo.size.height * 0.35, 215, 360))
        EditorStatus(state: e.previewStatus)
      }.background(UI.deep).foregroundStyle(Color.white).preferredColorScheme(.dark)
        .overlay {
          if over {
            RoundedRectangle(cornerRadius: 7).strokeBorder(UI.accent, lineWidth: 3)
              .allowsHitTesting(false)
          }
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
          "毛咪剪", isPresented: Binding(get: { e.error != nil }, set: { if !$0 { e.error = nil } })
        ) {
          Button("好") { e.error = nil }
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
