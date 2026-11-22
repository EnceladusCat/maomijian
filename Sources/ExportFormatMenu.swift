import SwiftUI

struct ExportFormatMenu: View {
  let editor: Editor
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: 4) {
      format(L("导出视频（MP4）…"), icon: "film") { editor.export() }
      format(L("导出当前帧（PNG）…"), icon: "photo") { editor.exportFrame() }
      Divider().padding(.vertical, 2)
      format(L("仅导出音频（M4A）…"), icon: "waveform") { editor.audioExport() }
        .disabled(!editor.canExportAudio)
      format(L("仅导出字幕（SRT）…"), icon: "captions.bubble") { editor.subtitleExport() }
        .disabled(!editor.canExportSubtitles)
      format(L("导出音频和字幕…"), icon: "square.stack") { editor.audioAndSubtitleExport() }
        .disabled(!editor.canExportAudio || !editor.canExportSubtitles)
    }.padding(8).frame(width: 208)
      .background(UI.deep, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(UI.muted.opacity(0.35))
          .allowsHitTesting(false)
      }
      .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
      .accessibilityElement(children: .contain)
  }

  private func format(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button {
      dismiss()
      action()
    } label: {
      Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(QuietButton())
  }
}
