import SwiftUI

struct CaptionReview: View {
  @State private var lines: [Clip]
  @State private var find = ""
  @State private var replacement = ""
  @State private var feedback = ""
  let seek: (Int) -> Void
  let cancel: () -> Void
  let apply: ([Clip]) -> Void

  init(
    captions: [Clip], seek: @escaping (Int) -> Void, cancel: @escaping () -> Void,
    apply: @escaping ([Clip]) -> Void
  ) {
    _lines = State(initialValue: captions.sorted { $0.start < $1.start })
    self.seek = seek
    self.cancel = cancel
    self.apply = apply
  }

  private var bilingual: Bool { lines.contains { $0.captionTranslation != nil } }

  private var matches: [Int] {
    lines.indices.filter { find.isEmpty || lines[$0].text.range(of: find, options: .caseInsensitive) != nil }
  }

  private func replaceAll() {
    guard !find.isEmpty else { return }
    let found = matches
    var count = 0
    for index in found {
      let text = lines[index].text.replacingOccurrences(of: find, with: replacement, options: .caseInsensitive)
      guard text != lines[index].text else { continue }
      lines[index].text = text
      count += 1
    }
    feedback = L("已修改 \(count) 条字幕")
    find = ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        TextField(L("查找字幕"), text: $find)
        TextField(L("替换为"), text: $replacement)
        Button(L("全部替换"), action: replaceAll).disabled(find.isEmpty || matches.isEmpty)
          .buttonStyle(QuietButton())
      }
      HStack {
        Text(L("\(matches.count) / \(lines.count) 条字幕")).foregroundStyle(UI.muted)
        Spacer()
        if !feedback.isEmpty { Text(feedback).foregroundStyle(UI.accent) }
      }.font(.caption)
      List {
        ForEach(matches, id: \.self) { index in
          HStack(alignment: .top, spacing: 12) {
            let frame = lines[index].start
            Button(stamp(frame)) { seek(frame) }
              .buttonStyle(.borderless).font(.system(.body, design: .monospaced))
              .foregroundStyle(UI.accent).help(L("跳到这条字幕"))
            VStack(alignment: .leading, spacing: 4) {
              TextField(L("字幕文本"), text: $lines[index].text, axis: .vertical)
                .lineLimit(1...4)
              if bilingual {
                TextField(L("译文"), text: Binding(
                  get: { lines[index].captionTranslation ?? "" },
                  set: { lines[index].captionTranslation = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ), axis: .vertical).lineLimit(1...4)
              }
            }
          }.padding(.vertical, 2)
        }
      }.scrollContentBackground(.hidden).background(UI.deep)
      HStack {
        Spacer()
        Button(L("取消"), action: cancel).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(L("应用校对")) {
          guard !lines.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            feedback = L("请补全空白字幕后再应用")
            return
          }
          apply(lines)
        }.buttonStyle(PrimaryButton(tint: UI.mint)).keyboardShortcut(.defaultAction)
      }
    }.padding(16).frame(width: 680, height: 476).background(UI.panel)
  }

  private func stamp(_ frame: Int) -> String {
    String(format: "%02d:%02d:%02d", frame / (fps * 60), frame / fps % 60, frame % fps)
  }
}
