import SwiftUI

struct CaptionWorkflowPanel: View {
  let editor: Editor
  let captions: [Clip]
  private enum Page: String, CaseIterable { case issues = "问题清单", transcript = "文稿粗剪" }
  @State private var page = Page.issues
  @State private var rows = [TranscriptRow]()
  @State private var marked = Set<TranscriptRow.ID>()
  @State private var candidatesOnly = false
  @State private var focused: UUID?
  @State private var issue: CaptionIssue?
  @State private var original = ""
  @State private var translation = ""
  @State private var glossary = ""
  @State private var pending: TranscriptEdit?
  @State private var confirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PanelSegments(title: L("字幕校对与粗剪"), options: Page.allCases, selection: $page, tint: UI.mint) {
        LKey($0.rawValue)
      }
      if page == .transcript {
        transcriptControls
      } else {
        issueControls
      }
      LazyVStack(spacing: 2) {
        ForEach(visibleRows) { row in rowView(row) }
      }
    }
    .onChange(of: captions, initial: true) { _, captions in
      rows = TranscriptRow.rows(captions)
      marked.formIntersection(rows.map(\.id))
      if let focused, !captions.contains(where: { $0.id == focused }) { self.focused = nil }
    }
    .onChange(of: editor.p.captionGlossary, initial: true) { _, value in glossary = value ?? "" }
    .confirmationDialog(L("应用文稿剪辑？"), isPresented: $confirm, titleVisibility: .visible) {
      if let pending {
        Button(pending == .cut ? L("剪掉选中区间") : L("只保留选中区间"), role: .destructive) {
          let selected = rows.filter { marked.contains($0.id) }.map(\.span)
          editor.editTranscript(selected, action: pending)
          marked.removeAll()
        }
      }
      Button(L("取消"), role: .cancel) {}
    } message: {
      Text(L("本次操作会同步剪辑所有轨道，可一次撤销。"))
    }
  }

  private var visibleRows: [TranscriptRow] {
    if page == .transcript {
      return candidatesOnly ? rows.filter {
        $0.caption == nil || $0.issues.contains(.repeatLine) || $0.issues.contains(.filler)
      } : rows
    }
    return rows.filter { row in issue.map(row.issues.contains) ?? !row.issues.isEmpty }
  }

  private var issueControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker(L("问题类型"), selection: $issue) {
          Text(L("全部问题")).tag(nil as CaptionIssue?)
          ForEach(CaptionIssue.allCases, id: \.self) { item in Text(item.title).tag(Optional(item)) }
        }.labelsHidden().accessibilityLabel(L("问题类型"))
        Spacer(minLength: 2)
        Text(L("\(visibleRows.count) 条")).font(.caption.monospacedDigit()).foregroundStyle(UI.muted)
      }
      if visibleRows.isEmpty {
        Text(L("没有发现这类问题")).foregroundStyle(UI.muted).font(.caption)
      }
      DisclosureGroup(L("术语纠正和配音读法")) {
        VStack(alignment: .leading, spacing: 6) {
          Text(L("每行一条。例如「英伟达公司 → 英伟达」纠正正文，「NVDA = 英伟达」只改读法。"))
            .font(.caption).foregroundStyle(UI.muted)
          TextEditor(text: $glossary).font(.system(.caption, design: .monospaced))
            .frame(height: 56).accessibilityLabel(L("编辑术语"))
          HStack {
            Button(L("保存术语")) { saveGlossary(apply: false) }.buttonStyle(QuietButton())
            Button(L("应用到现有字幕")) { saveGlossary(apply: true) }.buttonStyle(QuietButton())
          }
        }.padding(.top, 5)
      }.disclosureGroupStyle(SettingsDisclosureStyle())
    }
  }

  private var transcriptControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L("按字幕句选择时间。字幕间隔和疑似口误可先试听。"))
        .font(.caption).foregroundStyle(UI.muted)
      Toggle(L("只看字幕间隔和疑似口误"), isOn: $candidatesOnly).font(.caption).toggleStyle(.checkbox)
      HStack {
        Button(L("试听选区")) {
          let selected = rows.filter { marked.contains($0.id) }
          if let first = selected.first, let end = selected.map(\.span.upperBound).max() {
            editor.previewRange(first.span.lowerBound..<end)
          }
        }.buttonStyle(QuietButton()).disabled(marked.isEmpty)
        Menu(L("剪辑选区")) {
          Button(L("剪掉选中区间"), role: .destructive) { pending = .cut; confirm = true }
          Button(L("只保留选中区间")) { pending = .keep; confirm = true }
        }.disabled(marked.isEmpty)
        Spacer(minLength: 0)
        if !marked.isEmpty {
          Tool(symbol: "xmark", label: L("清除文稿选择"), size: 22) { marked.removeAll() }
        }
      }
    }
  }

  private func rowView(_ row: TranscriptRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      rowSummary(row)
      if page == .issues, let cue = row.caption, focused == cue.id { cueEditor(cue) }
    }
  }

  private func rowSummary(_ row: TranscriptRow) -> some View {
    HStack(alignment: .top, spacing: 5) {
      if page == .transcript {
        Toggle(L("选择这段文稿"), isOn: Binding(
          get: { marked.contains(row.id) },
          set: { if $0 { marked.insert(row.id) } else { marked.remove(row.id) } }
        )).labelsHidden().toggleStyle(.checkbox).padding(.top, 5)
      }
      Button {
        if let cue = row.caption {
          focused = cue.id
          original = cue.text
          translation = cue.captionTranslation ?? ""
          editor.selected = cue.id
        }
        editor.seek(row.span.lowerBound)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(tc(row.span.lowerBound)).font(.caption.monospacedDigit()).foregroundStyle(UI.mint)
          Text(row.caption?.text ?? L("字幕间隔")).font(.system(size: 12))
            .lineLimit(3).foregroundStyle(.white)
          if !row.issues.isEmpty {
            Text(row.issues.map(\.title).joined(separator: " · "))
              .font(.caption2).foregroundStyle(UI.buttonTint).lineLimit(2)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if let cue = row.caption, editor.timelineLayout.nextCaption[cue.id] != nil {
        Tool(symbol: "arrow.merge", label: L("合并下一句"), size: 22) {
          let editing = focused == cue.id
          editor.mergeCaptionWithNext(cue.id, body: editing ? original : nil,
                                      translation: editing ? translation : nil)
          if editing { focused = nil }
        }
      }
      Tool(symbol: "play.circle", label: page == .issues ? L("试听前后文") : L("试听这段"), size: 22) {
        let margin = page == .issues ? fps : 0
        let start = max(0, row.span.lowerBound - margin)
        let end = min(editor.timelineDuration, row.span.upperBound + margin)
        if start < end { editor.previewRange(start..<end) }
      }
    }.padding(6)
      .background((marked.contains(row.id) || (focused != nil && row.caption?.id == focused)) ? UI.well : .clear,
                  in: RoundedRectangle(cornerRadius: 5))
  }

  private func cueEditor(_ cue: Clip) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField(L("字幕文本"), text: $original, axis: .vertical).lineLimit(1...3)
      TextField(L("译文"), text: $translation, axis: .vertical).lineLimit(1...3)
      Button(L("保存这条字幕")) {
        editor.edit(cue.id) {
          $0.text = original.trimmingCharacters(in: .whitespacesAndNewlines)
          let line = translation.trimmingCharacters(in: .whitespacesAndNewlines)
          $0.captionTranslation = line.isEmpty ? nil : line
        }
        focused = nil
      }.buttonStyle(QuietButton())
        .disabled(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }.padding(6).background(UI.deep, in: RoundedRectangle(cornerRadius: 6))
  }

  private func saveGlossary(apply: Bool) {
    let text = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
    let vocabulary = CaptionGlossary(text)
    editor.change { project in
      project.captionGlossary = text.isEmpty ? nil : text
      if apply {
        for index in project.clips.indices where project.clips[index].kind == .caption {
          project.clips[index].text = vocabulary.correct(project.clips[index].text)
        }
      }
    }
  }
}
