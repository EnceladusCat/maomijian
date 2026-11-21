import SwiftUI

private enum HUD {
  static let glass = Color(red: 0.086, green: 0.107, blue: 0.163)
  static let rim = Color(red: 0.30, green: 0.36, blue: 0.50)
}

/// The clipped corner echoes the pixel skyline and keeps the active controls easy to scan.
private struct ConsoleFrame: Shape {
  func path(in rect: CGRect) -> Path {
    let cut = min(9, min(rect.width, rect.height) / 3)
    return Path { p in
      p.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
      p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
      p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
      p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
      p.closeSubpath()
    }
  }
}

struct EmptyWorkspaceMenu: View {
  let e: Editor
  @ObservedObject var recent: RecentProjects

  var body: some View {
    ViewThatFits(in: .vertical) {
      menu(compact: false)
      menu(compact: true)
    }
    .frame(maxWidth: 318)
  }

  private func menu(compact: Bool) -> some View {
    let frame = ConsoleFrame()
    return VStack(alignment: .leading, spacing: compact ? 7 : 12) {
      if !compact {
        HStack(spacing: 9) {
          Image(systemName: "film.stack")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(UI.accent)
            .frame(width: 35, height: 35)
            .background(UI.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(L("开始剪辑")).font(.system(size: 15, weight: .semibold))
            Text(L("也可以把文件拖到窗口中")).font(.caption).foregroundStyle(UI.muted)
          }
        }
      }
      Button(action: e.importPanel) {
        HStack(spacing: 7) {
          Label(L("导入素材"), systemImage: "plus")
            .lineLimit(1)
          Spacer(minLength: 3)
          KeyHint(text: "⌘I", tint: UI.deep)
        }
      }.buttonStyle(PrimaryButton(tint: UI.mint))

      HStack(spacing: 6) {
        Button(action: e.open) {
          Label(L("打开工程…"), systemImage: "folder")
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(QuietButton())
        if !recent.urls.isEmpty {
          Menu {
            ForEach(recent.urls, id: \.self) { url in
              Button(recent.title(for: url)) { e.open(url) }
            }
          } label: {
            Label(L("最近使用"), systemImage: "clock")
          }.menuStyle(.borderlessButton).fixedSize()
        } else {
          KeyHint(text: "⌘O", tint: UI.muted)
        }
      }
    }
    .padding(compact ? 10 : 15)
    .background(HUD.glass, in: frame)
    .overlay { frame.stroke(HUD.rim, lineWidth: 1).padding(0.5).allowsHitTesting(false) }
    .overlay(alignment: .topTrailing) {
      Capsule().fill(UI.accent.opacity(0.68)).frame(width: 28, height: 1)
        .padding(.trailing, 12).allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

private struct KeyHint: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
      .lineLimit(1).padding(.horizontal, 4).padding(.vertical, 2)
      .foregroundStyle(tint)
      .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
      .overlay {
        RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.30))
          .allowsHitTesting(false)
      }.accessibilityHidden(true)
  }
}

struct TransportBar: View {
  @ObservedObject var t: Transport
  let e: Editor
  let duration: Int

  private var fraction: Double {
    duration > 0 ? bound(Double(t.frame) / Double(duration), 0, 1) : 0
  }

  var body: some View {
    HStack(spacing: 9) {
      VStack(alignment: .leading, spacing: 4) {
        ViewThatFits(in: .horizontal) {
          clock(showLength: true)
          clock(showLength: false)
        }
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(HUD.rim.opacity(0.35))
            Capsule().fill(t.playing ? UI.mint : UI.accent)
              .frame(width: geo.size.width * fraction)
          }
        }.frame(height: 2).accessibilityHidden(true)
      }
      .frame(maxWidth: 210, alignment: .leading).layoutPriority(1)
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        HUDButton(symbol: "backward.end.fill", label: L("回到开头"), tint: UI.muted, action: { e.seek(0) })
        HUDButton(
          symbol: t.playing ? "pause.fill" : "play.fill", label: L("播放 / 暂停（空格）"),
          tint: UI.mint, prominent: true, action: e.play
        )
        HUDButton(
          symbol: "forward.end.fill", label: L("跳到结尾"), tint: UI.muted,
          action: { e.seek(duration) }
        )
      }.disabled(duration == 0)
      ViewThatFits(in: .horizontal) {
        KeyHint(text: L("空格"), tint: UI.muted)
        Color.clear.frame(width: 0, height: 0)
      }
    }
    .padding(.horizontal, 12).frame(height: 38)
    .background(HUD.glass, in: ConsoleFrame())
    .overlay {
      ConsoleFrame().stroke(HUD.rim.opacity(0.70), lineWidth: 1)
        .padding(0.5).allowsHitTesting(false)
    }
    .padding(.horizontal, 10).frame(height: 46)
  }

  private func clock(showLength: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Text(tc(t.frame))
        .font(.system(size: 14, weight: .semibold, design: .monospaced))
        .foregroundStyle(t.playing ? UI.mint : .white)
      if showLength {
        Text("/ " + tc(duration)).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(UI.muted)
      }
    }.fixedSize(horizontal: true, vertical: false)
  }
}

private struct HUDButton: View {
  let symbol: String
  let label: String
  let tint: Color
  var prominent = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: prominent ? 13 : 11, weight: .semibold))
        .frame(width: prominent ? 37 : 30, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(ConsoleKey(tint: tint, prominent: prominent))
    .accessibilityLabel(label).help(label)
  }
}

private struct ConsoleKey: ButtonStyle {
  let tint: Color
  let prominent: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let shape = RoundedRectangle(cornerRadius: 6)
    return configuration.label
      .foregroundStyle(prominent ? UI.deep : tint)
      .background(
        tint.opacity(prominent ? (pressed ? 0.72 : 1) : (pressed ? 0.25 : hovered ? 0.16 : 0.08)),
        in: shape
      )
      .overlay { shape.strokeBorder(tint.opacity(hovered ? 0.6 : 0.20)).allowsHitTesting(false) }
      .opacity(enabled ? 1 : 0.38)
      .offset(y: pressed && !reduceMotion ? 1 : 0)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)
      .onHover { hovered = $0 }
  }
}
