import SwiftUI

final class CaptionTemplates: ObservableObject {
  static let shared = CaptionTemplates()
  private let defaults: UserDefaults
  private let key = "caption.style.presets.v1"
  @Published private(set) var entries: [CaptionPreset]
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    entries =
      defaults.data(forKey: key).flatMap {
        try? JSONDecoder().decode([CaptionPreset].self, from: $0)
      }?.filter { $0.style.valid } ?? []
  }
  @discardableResult func save(_ name: String, style: CaptionStyle) -> Bool {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, style.valid, !entries.contains(where: { $0.name == clean }) else {
      return false
    }
    let next = entries + [CaptionPreset(name: clean, style: style)]
    guard let data = try? JSONEncoder().encode(next) else { return false }
    defaults.set(data, forKey: key)
    entries = next
    return true
  }
}

struct CaptionPanel: View {
  let e: Editor
  @ObservedObject var updates: PanelUpdates
  @ObservedObject var templates = CaptionTemplates.shared
  @State private var name = ""
  @State private var feedback = ""
  static let families = NSFontManager.shared.availableFontFamilies.sorted {
    $0.localizedStandardCompare($1) == .orderedAscending
  }
  private var style: CaptionStyle { e.p.captionStyle ?? CaptionStyle() }
  private func bind<T>(_ key: WritableKeyPath<CaptionStyle, T>) -> Binding<T> {
    Binding(
      get: { style[keyPath: key] },
      set: { value in
        e.change { project in
          var next = project.captionStyle ?? CaptionStyle()
          next[keyPath: key] = value
          project.captionStyle = next
        }
        feedback = ""
      })
  }
  private func color(_ label: String, _ key: WritableKeyPath<CaptionStyle, String>) -> some View {
    ColorPicker(
      label,
      selection: Binding(
        get: { Color(cgColor: ink(style[keyPath: key])) },
        set: { color in
          guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
          bind(key).wrappedValue = String(
            format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }), supportsOpacity: false)
  }
  private func number(
    _ label: String, _ key: WritableKeyPath<CaptionStyle, Double>, _ range: ClosedRange<Double>,
    _ unit: String = "px", factor: Double = 1
  ) -> some View {
    NumberRow(label: label, value: style[keyPath: key] * factor, range: range, unit: unit) {
      bind(key).wrappedValue = $0 / factor
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 9) {
        Text("全局字幕样式").font(.headline)
        HStack {
          Button("添加字幕") { e.add(.caption) }
          Button("导入 SRT", action: e.subtitleImport)
        }
        Text("应用于本工程的全部字幕").font(.caption).foregroundStyle(UI.muted)
        CaptionSwatch(style: style)
        SectionName(name: "模板")
        Menu("应用模板") {
          Button("默认字幕") {
            e.change { $0.captionStyle = CaptionStyle() }
            feedback = "已应用默认字幕"
          }
          ForEach(templates.entries) { item in
            Button(item.name) {
              e.change { $0.captionStyle = item.style }
              feedback = "已应用「" + item.name + "」"
            }
          }
        }
        HStack {
          TextField("模板名称", text: $name).accessibilityLabel("模板名称")
          Button("保存") {
            if templates.save(name, style: style) {
              feedback = "已保存「" + name + "」"
              name = ""
            } else {
              feedback = "已有同名模板，请换个名称。"
            }
          }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("保存字幕模板")
        }
        if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(UI.accent) }
        Divider()
        SectionName(name: "字体")
        let fonts = [""] + Self.families
        MenuField(
          title: "字体", choices: ["系统字体"] + Self.families,
          selectedIndex: fonts.firstIndex(of: style.font) ?? 0
        ) {
          bind(\.font).wrappedValue = fonts[$0]
        }.frame(height: 21)
        Toggle("粗体", isOn: bind(\.bold))
        number("字号", \.fontSize, 12...180)
        color("文字颜色", \.foreground)
        number("文字描边", \.outlineWidth, 0...16)
        if style.outlineWidth > 0 { color("描边颜色", \.outline) }
        Divider()
        SectionName(name: "背景与边框")
        color("背景颜色", \.background)
        number("背景不透明度", \.backgroundOpacity, 0...100, "%", factor: 100)
        number("圆角", \.radius, 0...60)
        Picker("边框", selection: bind(\.border)) {
          ForEach(CaptionBorder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        if style.border != .none {
          color("边框颜色", \.borderColor)
          number("边框宽度", \.borderWidth, 1...16)
        }
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
private struct CaptionSwatch: View {
  let style: CaptionStyle
  var body: some View {
    let image: CGImage? = {
      var clip = Clip.annotation(.caption, at: 0)
      clip.text = "字幕预览"
      clip.w = 0.31
      clip.h = 0.11
      return artwork(clip, size: CGSize(width: 960, height: 540), style: style)
    }()
    ZStack {
      RoundedRectangle(cornerRadius: 4).fill(UI.deep)
      if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(5) }
    }.frame(height: 48).accessibilityLabel("字幕样式预览")
  }
}
