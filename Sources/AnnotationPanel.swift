import SwiftUI

struct AnnotationPanel: View {
  let e: Editor
  @ObservedObject var updates: PanelUpdates
  private let tools: [Kind] = [.text, .timer, .arrow, .rectangle, .ellipse, .highlight, .zoom, .caption]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 9) {
        SectionName(name: L("添加到播放头"))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 6) {
          ForEach(tools, id: \.self) { kind in
            AnnotationTile(kind: kind, active: e.regionTool == kind) { e.add(kind) }
          }
        }
        let source = e.audioVisualizationSource
        Divider()
        HStack {
          Label(L("音频可视化"), systemImage: Kind.audioVisual.icon)
            .font(.system(size: 12, weight: .semibold))
          Spacer(minLength: 4)
        }.foregroundStyle(UI.mint)
        if let source {
          Text(e.p.name(source)).font(.caption).lineLimit(1).foregroundStyle(UI.muted)
        } else {
          Text(L("选择音频或带音频的视频")).font(.caption).foregroundStyle(UI.muted)
        }
        HStack(spacing: 6) {
          ForEach(AudioVisualStyle.allCases, id: \.self) { style in
            Button { e.addAudioVisualization(style) } label: {
              Label(style.title, systemImage: style == .area ? "waveform.path" : "chart.bar.fill")
                .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 25)
            }.buttonStyle(QuietButton()).disabled(source == nil)
          }
        }
        Button(action: e.subtitleImport) {
          Label(L("导入 SRT"), systemImage: "square.and.arrow.down")
            .frame(maxWidth: .infinity)
        }.buttonStyle(QuietButton())
      }.padding(11)
    }
  }
}

private struct AnnotationTile: View {
  let kind: Kind
  let active: Bool
  let add: () -> Void
  @State private var hovering = false
  private var tip: String {
    kind.isRegion ? L("在预览区拖出\(kind.title)范围") : L("在播放头添加\(kind.title)")
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10)
    VStack(spacing: 4) {
      AnnotationSwatch(kind: kind)
      Text(kind.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
    }
    .foregroundStyle(active || hovering ? .white : UI.muted)
    .padding(4).frame(maxWidth: .infinity)
    .background(active ? UI.accent.opacity(0.19) : .white.opacity(hovering ? 0.08 : 0.025), in: shape)
    .accessibilityHidden(true)
    .overlay {
      AnnotationAction(label: kind.title, tip: tip, selected: active, add: add)
    }
    .onHover { hovering = $0 }
  }
}

private struct AnnotationAction: NSViewRepresentable {
  let label: String
  let tip: String
  let selected: Bool
  let add: () -> Void

  func makeNSView(context: Context) -> TileButton {
    let button = TileButton(frame: .zero)
    button.title = ""
    button.isBordered = false
    button.isTransparent = true
    button.setButtonType(.momentaryChange)
    button.focusRingType = .exterior
    button.target = button
    button.action = #selector(TileButton.activate)
    return button
  }

  func updateNSView(_ button: TileButton, context: Context) {
    button.setAccessibilityLabel(label)
    button.setAccessibilityValue(selected ? L("已选") : nil)
    button.toolTip = tip
    button.add = add
  }

  final class TileButton: NSButton {
    var add: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
    @objc func activate() { add?() }
  }
}

private struct AnnotationSwatch: View {
  let kind: Kind

  private var tint: Color {
    switch kind {
    case .timer, .highlight: return UI.buttonTint
    case .rectangle, .ellipse: return UI.mint
    case .zoom, .caption: return UI.accent
    default: return UI.coral
    }
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6).fill(tint)
      mark.foregroundStyle(UI.deep)
    }.frame(height: 32)
  }

  @ViewBuilder private var mark: some View {
    switch kind {
    case .text:
      Text("Aa").font(.system(size: 20, weight: .semibold, design: .rounded))
    case .timer:
      Text("00:24").font(.system(size: 15, weight: .semibold, design: .monospaced))
    case .arrow:
      Image(systemName: "arrow.up.right").font(.system(size: 17, weight: .bold))
    case .rectangle:
      Rectangle().strokeBorder(lineWidth: 2).frame(width: 25, height: 15)
    case .ellipse:
      Ellipse().strokeBorder(lineWidth: 2).frame(width: 25, height: 15)
    case .highlight:
      RoundedRectangle(cornerRadius: 4)
        .fill(UI.deep.opacity(0.70))
        .frame(width: 36, height: 21)
        .overlay { RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 19, height: 9) }
    case .zoom:
      ZStack {
        Rectangle().strokeBorder(lineWidth: 1).frame(width: 23, height: 14).offset(x: -5, y: 3)
        Rectangle().fill(tint)
          .overlay { Rectangle().strokeBorder(UI.deep, lineWidth: 2) }
          .frame(width: 23, height: 14).offset(x: 5, y: -3)
      }
    default:
      Text(AppLanguage.current == .english ? "CC" : "字幕")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(UI.deep, in: RoundedRectangle(cornerRadius: 3))
    }
  }
}
