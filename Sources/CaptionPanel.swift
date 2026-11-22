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
  @ObservedObject var automatic: AutomaticCaptions
  private enum Page: String, CaseIterable {
    case generate = "生成", review = "校对", voiceover = "配音", style = "样式"

    var icon: String {
      switch self {
      case .generate: return "waveform"
      case .review: return "text.badge.checkmark"
      case .voiceover: return "waveform.and.mic"
      case .style: return "text.alignleft"
      }
    }
    var tint: Color {
      switch self {
      case .generate: return UI.buttonTint
      case .review: return UI.mint
      case .voiceover: return UI.accent
      case .style: return UI.coral
      }
    }
  }

  @State private var page = Page.generate
  @State private var showAdvanced = false
  @State private var showTemplateName = false
  @State private var showFont = true
  @State private var showBox = false
  @State private var name = ""
  @State private var feedback = ""
  @State private var language = AppLanguage.current == .english ? CaptionLanguage.english : .mandarin
  @State private var selection = false
  @State private var replacing = false
  @State private var terms = ""
  static let families = NSFontManager.shared.availableFontFamilies.sorted {
    $0.localizedStandardCompare($1) == .orderedAscending
  }
  private var style: CaptionStyle { e.p.captionStyle ?? CaptionStyle() }
  private func saveTerms() {
    let text = terms.trimmingCharacters(in: .whitespacesAndNewlines)
    e.change { $0.captionTerms = text.isEmpty ? nil : text }
  }
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
  private var captions: [Clip] {
    e.p.clips.filter { $0.kind == .caption }.sorted { $0.start < $1.start }
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(L("字幕")).font(.system(size: 15, weight: .semibold))
          Spacer()
          if !captions.isEmpty {
            Text(L("\(captions.count) 条")).font(.caption.monospacedDigit()).foregroundStyle(UI.color(.caption))
          }
        }
        HStack(spacing: 6) {
          ForEach(Page.allCases, id: \.self) { tab in
            let selected = page == tab
            Button { page = tab } label: {
              VStack(spacing: 5) {
                Image(systemName: tab.icon)
                  .font(.system(size: 15, weight: .semibold))
                  .foregroundStyle(selected ? UI.deep : tab.tint)
                  .frame(maxWidth: .infinity).frame(height: 31)
                  .background(
                    selected ? tab.tint : tab.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8)
                  )
                  .accessibilityHidden(true)
                Text(LKey(tab.rawValue)).font(.system(size: 11, weight: selected ? .semibold : .medium))
                  .foregroundStyle(selected ? tab.tint : UI.muted)
              }
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(LKey(tab.rawValue))
              .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
      }.padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 11)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          switch page {
          case .generate: generator
          case .review: review
          case .voiceover:
            CaptionVoiceoverPanel(editor: e, voiceover: e.captionVoiceover,
                                 audition: e.captionVoiceover.audition, captions: captions)
          case .style: styling
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.onAppear { terms = e.p.captionTerms ?? "" }
      .onChange(of: e.p.captionTerms) { _, value in terms = value ?? "" }
  }

  @ViewBuilder private var generator: some View {
    if AutomaticCaptions.available {
      choice(L("语言"), value: language.label) {
        ForEach(CaptionLanguage.allCases, id: \.self) { option in
          Button { language = option } label: {
            if language == option { Label(option.label, systemImage: "checkmark") }
            else { Text(option.label) }
          }
        }
      }
      choice(L("音频"), value: selection ? L("所选片段") : L("时间线混音")) {
        Button(L("时间线混音")) { selection = false }
        Button(L("所选片段")) { selection = true }
      }
      if let stage = automatic.stage {
        HStack(alignment: .top, spacing: 6) {
          CaptionGenerationProgress(stage: stage)
          Spacer(minLength: 2)
          Button(L("停止"), action: automatic.cancel).buttonStyle(QuietButton())
        }
      } else {
        Button {
          saveTerms()
          e.generateCaptions(language: language, selection: selection, replacing: replacing)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "waveform")
              .frame(width: 23, height: 23)
              .background(UI.deep.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
              .accessibilityHidden(true)
            Text(L("生成自动字幕"))
            Spacer(minLength: 0)
          }.frame(minHeight: 40)
        }.buttonStyle(PrimaryButton())
          .disabled(selection ? e.captionAudioSelection == nil : !e.canExportAudio)
      }
      DisclosureGroup(L("识别选项"), isExpanded: $showAdvanced) {
        VStack(alignment: .leading, spacing: 7) {
          TextField(L("项目术语，逗号分隔"), text: $terms).onSubmit(saveTerms)
          Button(L("保存术语"), action: saveTerms).buttonStyle(QuietButton())
            .disabled(terms == (e.p.captionTerms ?? ""))
          if e.canExportSubtitles { Toggle(L("替换已有字幕"), isOn: $replacing) }
          Text(L("在本机识别。首次可能下载语言模型。"))
            .font(.caption).foregroundStyle(UI.muted)
        }.padding(.vertical, 6)
      }.disclosureGroupStyle(SettingsDisclosureStyle()).font(.system(size: 12))
      Divider()
    } else {
      Text(L("自动字幕需要 macOS 26 或更新版本。"))
        .font(.caption).foregroundStyle(UI.muted)
    }
    HStack(spacing: 3) {
      Button { e.add(.caption) } label: { Label(L("添加字幕"), systemImage: "plus") }
      Button(action: e.subtitleImport) { Label(L("导入 SRT"), systemImage: "arrow.down.to.line") }
    }.buttonStyle(QuietButton())
  }

  private func choice<Items: View>(
    _ name: String, value: String, @ViewBuilder items: () -> Items
  ) -> some View {
    HStack(spacing: 6) {
      Text(name).font(.caption).foregroundStyle(UI.muted)
      Spacer(minLength: 1)
      Menu(content: items) {
        HStack(spacing: 4) {
          Text(value).lineLimit(1)
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            .foregroundStyle(UI.muted)
        }.font(.system(size: 11, weight: .medium))
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(name).accessibilityValue(value)
    }.frame(minHeight: 24)
  }

  @ViewBuilder private var review: some View {
    if captions.isEmpty {
      Text(L("生成字幕或导入 SRT 后可以在这里校对。"))
        .font(.caption).foregroundStyle(UI.muted)
      Button(L("去生成")) { page = .generate }.buttonStyle(QuietButton())
    } else {
      Button(action: e.reviewSubtitles) {
        Label(L("批量校对…"), systemImage: "text.badge.checkmark")
          .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
      }.buttonStyle(PrimaryButton(tint: UI.mint))
      Button { e.translateSubtitles(from: language) } label: {
        Label(L("翻译字幕…"), systemImage: "translate")
          .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
      }.buttonStyle(QuietButton())
        .disabled(!captions.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      CaptionWorkflowPanel(editor: e, captions: captions)
    }
  }

  @ViewBuilder private var styling: some View {
    CaptionSwatch(style: style)
    choice(L("模板"), value: L("应用模板")) {
      Button(L("默认字幕")) {
        e.change { $0.captionStyle = CaptionStyle() }
        feedback = L("已应用默认字幕")
      }
      ForEach(templates.entries) { item in
        Button(item.name) {
          e.change { $0.captionStyle = item.style }
          feedback = L("已应用「\(item.name)」")
        }
      }
    }
    DisclosureGroup(L("保存为模板"), isExpanded: $showTemplateName) {
      HStack(spacing: 6) {
        TextField(L("模板名称"), text: $name)
        Button(L("保存")) {
          if templates.save(name, style: style) {
            feedback = L("已保存「\(name)」")
            name = ""
            showTemplateName = false
          } else {
            feedback = L("已有同名模板，请换个名称。")
          }
        }.buttonStyle(QuietButton()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityLabel(L("保存字幕模板"))
      }.padding(.vertical, 6)
    }.disclosureGroupStyle(SettingsDisclosureStyle())
    if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(UI.accent) }
    Divider()
    DisclosureGroup(L("字体与描边"), isExpanded: $showFont) {
      VStack(alignment: .leading, spacing: 8) {
        let fonts = [""] + Self.families
        MenuField(
          title: L("字体"), choices: [L("系统字体")] + Self.families,
          selectedIndex: fonts.firstIndex(of: style.font) ?? 0
        ) {
          bind(\.font).wrappedValue = fonts[$0]
        }.frame(height: 21)
        Toggle(L("粗体"), isOn: bind(\.bold))
        number(L("字号"), \.fontSize, 12...180)
        color(L("文字颜色"), \.foreground)
        number(L("描边宽度"), \.outlineWidth, 0...16)
        if style.outlineWidth > 0 { color(L("描边颜色"), \.outline) }
      }.padding(.vertical, 6)
    }.disclosureGroupStyle(SettingsDisclosureStyle())
    Divider()
    DisclosureGroup(L("背景与边框"), isExpanded: $showBox) {
      VStack(alignment: .leading, spacing: 8) {
        color(L("背景颜色"), \.background)
        number(L("背景不透明度"), \.backgroundOpacity, 0...100, "%", factor: 100)
        number(L("圆角"), \.radius, 0...60)
        Picker(L("边框"), selection: bind(\.border)) {
          ForEach(CaptionBorder.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
        }
        if style.border != .none {
          color(L("边框颜色"), \.borderColor)
          number(L("边框宽度"), \.borderWidth, 1...16)
        }
      }.padding(.vertical, 6)
    }.disclosureGroupStyle(SettingsDisclosureStyle())
  }
}
private struct CaptionSwatch: View {
  let style: CaptionStyle
  var body: some View {
    let image: CGImage? = {
      var clip = Clip.annotation(.caption, at: 0)
      clip.text = L("字幕预览")
      clip.w = 0.31
      clip.h = 0.11
      return artwork(clip, size: CGSize(width: 960, height: 540), style: style)
    }()
    ZStack {
      RoundedRectangle(cornerRadius: 4).fill(UI.deep)
      if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(5) }
    }.frame(height: 48).accessibilityLabel(L("字幕样式预览"))
  }
}

private struct CaptionGenerationProgress: View {
  let stage: AutomaticCaptions.Stage

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(stage.label).font(.caption.weight(.semibold))
      switch stage {
      case .recognizing(let progress):
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
          let value = progress.snapshot()
          ProgressView(value: value.fraction).controlSize(.small)
          Text(remainingLabel(value.remainingSeconds, fraction: value.fraction))
            .font(.caption.monospacedDigit()).foregroundStyle(UI.muted)
        }
      case .preparingAudio(let progress):
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
          ProgressView(value: progress.snapshot().fraction).controlSize(.small)
        }
      case .preparingModel, .arranging:
        ProgressView().controlSize(.small)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func remainingLabel(_ seconds: Int?, fraction: Double) -> String {
    if fraction >= 0.995 { return L("即将完成") }
    guard let seconds else { return L("正在估计剩余时间…") }
    let rounded = seconds >= 15 ? ((seconds + 4) / 5) * 5 : seconds
    let duration = Duration.seconds(rounded).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        .locale(Locale(identifier: AppLanguage.current.rawValue)))
    return L("预计还需 \(duration)")
  }
}
