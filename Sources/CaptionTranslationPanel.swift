import SwiftUI
#if canImport(Translation)
  import Translation
#endif

struct CaptionTranslationPanel: View {
  private enum Engine { case checking, script, system, unavailable }

  let lines: [SubtitleTranslationLine]
  let close: () -> Void
  let apply: (CaptionTranslationMode, [UUID: String]) -> Bool
  @State private var source: CaptionLanguage
  @State private var target: CaptionLanguage
  @State private var mode = CaptionTranslationMode.bilingual
  @State private var engine = Engine.checking
  @State private var checkedPair: SubtitleTranslationPair?
  @State private var job: UUID?
  @State private var translated: [String]?
  @State private var finished = 0
  @State private var previewIndex = 0
  @State private var error: String?

  init(
    lines: [SubtitleTranslationLine], source: CaptionLanguage,
    close: @escaping () -> Void, apply: @escaping (CaptionTranslationMode, [UUID: String]) -> Bool
  ) {
    self.lines = lines
    self.close = close
    self.apply = apply
    _source = State(initialValue: source)
    _target = State(initialValue: source == .english ? .mandarin : .english)
  }

  private var pair: SubtitleTranslationPair { .init(source: source, target: target) }
  private var canStart: Bool { checkedPair == pair && (engine == .script || engine == .system) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center) {
        Text(L("翻译 \(lines.count) 条字幕")).font(.system(size: 18, weight: .semibold))
        Spacer()
        Label(L("本机翻译"), systemImage: "lock")
          .font(.caption.weight(.medium)).foregroundStyle(UI.mint)
      }
      HStack(alignment: .bottom, spacing: 14) {
        languagePicker(L("原字幕语言"), selected: source) { choice in
          if target == choice { target = source }
          source = choice
        }
        Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
          .foregroundStyle(UI.muted).frame(height: 27).accessibilityHidden(true)
        languagePicker(L("翻译成"), selected: target) { choice in
          if source == choice { source = target }
          target = choice
        }
      }.disabled(job != nil)
      PanelSegments(title: L("字幕模式"), options: CaptionTranslationMode.allCases,
        selection: $mode, tint: UI.mint) { $0.title }
      preview
      footer
    }
    .padding(18).frame(width: 478, height: 392).background(UI.panel)
    .background { nativeTranslation }
    .task(id: pair) { await chooseEngine(for: pair) }
  }

  private func languagePicker(
    _ title: String, selected: CaptionLanguage, choose: @escaping (CaptionLanguage) -> Void
  ) -> some View {
    let options = CaptionLanguage.allCases
    return VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(UI.muted)
      MenuField(title: title, choices: options.map(\.translationLabel),
        selectedIndex: options.firstIndex(of: selected) ?? 0) { index in
        choose(options[index])
      }.frame(maxWidth: .infinity).frame(height: 27)
    }
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(tc(lines[previewIndex].start)).font(.system(.caption, design: .monospaced))
          .foregroundStyle(UI.muted)
        Spacer()
        if translated != nil && lines.count > 1 {
          Button { previewIndex -= 1 } label: {
            Image(systemName: "chevron.left").frame(width: 20, height: 18)
          }.disabled(previewIndex == 0).accessibilityLabel(L("上一条"))
          Text("\(previewIndex + 1) / \(lines.count)").monospacedDigit()
          Button { previewIndex += 1 } label: {
            Image(systemName: "chevron.right").frame(width: 20, height: 18)
          }.disabled(previewIndex + 1 >= lines.count).accessibilityLabel(L("下一条"))
        }
      }.buttonStyle(.borderless).font(.caption).foregroundStyle(UI.muted)
      Spacer(minLength: 1)
      if mode == .bilingual || translated == nil {
        Text(lines[previewIndex].text).font(.system(size: 14, weight: .semibold))
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .center)
          .foregroundStyle(.white)
      }
      if let translated {
        Text(translated[previewIndex]).font(.system(size: 14, weight: .semibold))
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .center)
          .foregroundStyle(UI.mint)
      } else if job != nil {
        VStack(spacing: 4) {
          ProgressView(value: Double(finished), total: Double(lines.count)).controlSize(.small)
          Text(L("已翻译 \(finished) / \(lines.count) 条")).font(.caption.monospacedDigit())
        }.frame(maxWidth: 208).frame(maxWidth: .infinity)
      }
      Spacer(minLength: 1)
    }.padding(11).frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(UI.deep, in: RoundedRectangle(cornerRadius: 9))
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(error ?? guidance).font(.caption)
        .foregroundStyle(error == nil ? UI.muted : UI.coral)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(L("取消"), action: close).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        if let translated {
          Button(L("应用译文")) { applyTranslation(translated) }
            .buttonStyle(PrimaryButton(tint: UI.mint)).keyboardShortcut(.defaultAction)
        } else {
          Button(L("开始翻译"), action: start).buttonStyle(PrimaryButton(tint: UI.mint))
            .keyboardShortcut(.defaultAction).disabled(job != nil || !canStart)
        }
      }
    }
  }

  private var guidance: String {
    if translated != nil {
      return mode == .bilingual ? L("原文在上，译文在下，共用时间码和样式。")
        : L("应用后会替换字幕文字，可一次撤销。")
    }
    if job != nil && finished == 0 && engine == .system { return L("正在准备本机翻译…") }
    switch engine {
    case .checking: return L("正在检查本机支持的语言…")
    case .script: return L("简繁转换在本机完成。")
    case .system: return L("在本机翻译。首次使用可能需要下载语言模型。")
    case .unavailable: return L("这台 Mac 无法自动翻译这组语言。可以在字幕片段的属性中填写译文。")
    }
  }

  @ViewBuilder private var nativeTranslation: some View {
    #if canImport(Translation)
      if #available(macOS 15, *), engine == .system, let job {
        NativeCaptionTranslation(pair: pair) { session in
          await translate(with: session, pair: pair, id: job)
        }.id(job)
      }
    #endif
  }

  @MainActor private func chooseEngine(for pair: SubtitleTranslationPair) async {
    translated = nil
    error = nil
    previewIndex = 0
    engine = .checking
    checkedPair = pair
    if pair.isChineseScriptConversion { engine = .script; return }
    #if canImport(Translation)
      if #available(macOS 15, *) {
        let available = LanguageAvailability()
        if pair.source == .cantonese || pair.target == .cantonese {
          let languages = await available.supportedLanguages
          guard !Task.isCancelled else { return }
          guard languages.contains(where: { $0.languageCode?.identifier == "yue" }) else {
            engine = .unavailable
            return
          }
        }
        let status = await available.status(from: pair.appleSource, to: pair.appleTarget)
        guard !Task.isCancelled else { return }
        if status == .supported || status == .installed { engine = .system; return }
      }
    #endif
    engine = .unavailable
  }

  private func start() {
    guard canStart, job == nil else { return }
    error = nil
    if engine == .script {
      do { translated = try SubtitleTranslator.convertScript(lines.map(\.text), pair: pair) }
      catch { self.error = error.localizedDescription }
    } else {
      finished = 0
      job = UUID()
    }
  }

  private func applyTranslation(_ result: [String]) {
    do {
      if !apply(mode, try SubtitleTranslationLine.replacements(for: lines, translated: result)) {
        error = L("字幕已更改，请关闭窗口后重新翻译。")
      }
    } catch { self.error = error.localizedDescription }
  }

  #if canImport(Translation)
    @available(macOS 15, *)
    @MainActor private func translate(
      with session: TranslationSession, pair: SubtitleTranslationPair, id: UUID
    ) async {
      guard job == id else { return }
      defer { if job == id { job = nil } }
      do {
        let source = try pair.source == .traditional
          ? SubtitleTranslator.convertScript(
              lines.map(\.text), pair: .init(source: .traditional, target: .mandarin))
          : lines.map(\.text)
        var outputs = [UUID: String]()
        for start in stride(from: 0, to: lines.count, by: 48) {
          try Task.checkCancellation()
          let batch = (start..<min(start + 48, lines.count)).map {
            TranslationSession.Request(sourceText: source[$0], clientIdentifier: lines[$0].id.uuidString)
          }
          for response in try await session.translations(from: batch) {
            if let key = response.clientIdentifier.flatMap(UUID.init(uuidString:)) {
              outputs[key] = response.targetText
            }
          }
          guard job == id, !Task.isCancelled else { return }
          finished = outputs.count
        }
        var result = lines.map { outputs[$0.id] ?? "" }
        if pair.target == .traditional {
          result = try SubtitleTranslator.convertScript(result, pair: .init(source: .mandarin, target: .traditional))
        }
        _ = try SubtitleTranslationLine.replacements(for: lines, translated: result)
        translated = result
      } catch {
        if job == id, !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  #endif
}

#if canImport(Translation)
  @available(macOS 15, *)
  private extension SubtitleTranslationPair {
    var appleSource: Locale.Language { appleLanguage(source) }
    var appleTarget: Locale.Language { appleLanguage(target) }

    private func appleLanguage(_ language: CaptionLanguage) -> Locale.Language {
      switch language {
      case .traditional: return .init(identifier: CaptionLanguage.mandarin.translationCode)
      case .cantonese: return .init(identifier: "yue-Hant-HK")
      default: return .init(identifier: language.translationCode)
      }
    }
  }

  @available(macOS 15, *)
  private struct NativeCaptionTranslation: View {
    let pair: SubtitleTranslationPair
    let translate: (TranslationSession) async -> Void

    var body: some View {
      Color.clear.translationTask(source: pair.appleSource, target: pair.appleTarget, action: translate)
    }
  }
#endif
