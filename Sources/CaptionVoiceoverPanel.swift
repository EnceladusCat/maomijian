import SwiftUI
import UniformTypeIdentifiers

struct CaptionVoiceoverPanel: View {
  let editor: Editor
  @ObservedObject var voiceover: CaptionVoiceover
  @ObservedObject var audition: SoundAudition
  let captions: [Clip]
  @State private var selectedOnly = false
  @State private var source = VoiceoverText.original
  @AppStorage("editor.audio8.voice") private var voiceID = ""
  @State private var showProfileEditor = false
  @State private var profileName = ""
  @State private var transcript = ""
  @State private var recording: URL?
  @State private var confirmRemove = false
  private var voice: VoiceoverProfile? {
    voiceover.profiles.first { $0.id.uuidString == voiceID }
  }
  private static let modelLicense = URL(string: "https://huggingface.co/Edge0/audio8-TTS-0.1B-ONNX-INT8/blob/4b04c49d6fd8155257e4aa8972df203af97173ba/LICENSE")!

  var body: some View {
    panel
      .onChange(of: source) { _, newSource in
        if newSource != .instant { audition.stop() }
      }
      .onReceive(editor.shelf.tabs) { if $0 != .captions { audition.stop() } }
      .onDisappear { audition.stop() }
  }

  @ViewBuilder private var panel: some View {
    let selected = Set(editor.selectedIDs)
    let candidates = selectedOnly ? captions.filter { selected.contains($0.id) } : captions
    let count = source == .instant ? 0 : candidates.lazy.filter { !source.text(in: $0).isEmpty }.count
    if CaptionVoiceover.available {
      VStack(alignment: .leading, spacing: 5) {
        Text("Audio8-TTS 0.1B · INT8")
          .font(.system(size: 12, weight: .semibold))
        Text(L("默认音色，适合中英文。首次自动下载约 443 MB，之后可离线生成。"))
          .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
        Link(L("Audio8 模型许可"), destination: Self.modelLicense).font(.caption)
      }
      Divider()
      VStack(alignment: .leading, spacing: 7) {
        Picker(L("音色"), selection: $voiceID) {
          Text(L("默认音色")).tag("")
          ForEach(voiceover.profiles) { profile in
            Text(profile.name).tag(profile.id.uuidString)
          }
        }
        Picker(L("朗读内容"), selection: $source) {
          ForEach(VoiceoverText.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
        }
        if source != .instant {
          Picker(L("范围"), selection: $selectedOnly) {
            Text(L("全部字幕")).tag(false)
            Text(L("所选字幕")).tag(true)
          }
        }
      }.font(.caption).disabled(voiceover.stage != nil)
      if source == .instant {
        TextField(L("输入要朗读的文字"), text: $voiceover.instantText, axis: .vertical)
          .lineLimit(4...10)
          .font(.system(size: 12))
          .disabled(voiceover.stage != nil)
      }
      if let stage = voiceover.stage {
        VStack(alignment: .leading, spacing: 5) {
          switch stage {
          case .preparing:
            Text(L("正在准备本地配音…"))
            ProgressView()
          case .downloading(let fraction):
            Text(L("正在下载模型 \(Int(fraction * 100))%"))
            ProgressView(value: fraction).controlSize(.small)
          case .registering:
            Text(L("正在建立自定义音色…"))
            ProgressView().controlSize(.small)
          case .synthesizing(let done, let total):
            Text(L("正在配音 \(done)/\(total)"))
            ProgressView(value: Double(done), total: Double(total)).controlSize(.small)
          case .exporting(let format):
            Text(L("正在导出 \(format.rawValue.uppercased())…"))
            ProgressView().controlSize(.small)
          }
          Button(L("停止"), action: voiceover.cancel).buttonStyle(QuietButton())
        }.font(.caption)
      } else {
        if source == .instant {
          instantActions
        } else {
          Button {
            editor.generateVoiceover(from: candidates, source: source, voice: voice)
          } label: {
            Label(L("生成配音"), systemImage: "waveform")
              .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
          }.buttonStyle(PrimaryButton(tint: UI.accent)).disabled(count == 0)
          Text(count == 0 ? L("这组选项没有可朗读的字幕。") : L("将从字幕起点添加 \(count) 段音频。"))
            .font(.caption).foregroundStyle(UI.muted)
        }
        if !voiceover.notice.isEmpty {
          Text(voiceover.notice).font(.caption).foregroundStyle(UI.muted)
            .textSelection(.enabled)
        }
        Divider()
        profileEditor
      }
    } else {
      Text(L("Audio8 配音需要带本地运行组件的 Apple 芯片版毛咪剪。"))
        .font(.caption).foregroundStyle(UI.muted)
    }
  }

  @ViewBuilder private var instantActions: some View {
    let text = voiceover.instantText.trimmingCharacters(in: .whitespacesAndNewlines)
    let glossary = CaptionGlossary(editor.p.captionGlossary)
    Button {
      voiceover.generateText(voice: voice, glossary: glossary)
    } label: {
      Label(L("生成配音"), systemImage: "waveform")
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }.buttonStyle(PrimaryButton(tint: UI.accent)).disabled(text.isEmpty)

    if let result = voiceover.instant {
      let playing = audition.active == result.file.url
      HStack(spacing: 6) {
        Button(action: editor.auditionVoiceover) {
          Label(playing ? L("停止试听") : L("试听"), systemImage: playing ? "stop.fill" : "play.fill")
        }.buttonStyle(QuietButton())
        Spacer(minLength: 2)
        Menu {
          Button(L("M4A（较小）…")) { editor.exportVoiceover(.m4a) }
          Button(L("WAV…")) { editor.exportVoiceover(.wav) }
        } label: {
          Label(L("导出"), systemImage: "arrow.down.to.line")
        }.fixedSize()
      }
      Text(Duration.seconds(Double(result.frames) / Double(fps)).formatted(.time(pattern: .minuteSecond)))
        .font(.caption.monospacedDigit()).foregroundStyle(UI.muted)
      if glossary.read(text) != result.text || voice?.id != result.voiceID {
        Text(L("当前试听和导出使用上一次生成的音频。"))
          .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var profileEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      DisclosureGroup(L("自定义音色"), isExpanded: $showProfileEditor) {
        VStack(alignment: .leading, spacing: 7) {
          Text(L("导入 0.5–30 秒的清晰人声，填写录音原话。首次建立音色会另下载约 415 MB。"))
            .foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
          TextField(L("音色名称"), text: $profileName)
          Button(action: chooseRecording) {
            Label(L("选择参考录音…"), systemImage: "waveform")
          }.buttonStyle(QuietButton())
          if let recording {
            Text(recording.lastPathComponent).lineLimit(1).truncationMode(.middle)
              .foregroundStyle(UI.muted)
          }
          TextField(L("录音里的原话"), text: $transcript, axis: .vertical).lineLimit(2...5)
          Button(L("保存并使用")) {
            guard let recording else { return }
            voiceover.register(name: profileName, transcript: transcript, recording: recording) { profile in
              voiceID = profile.id.uuidString
              profileName = ""
              transcript = ""
              self.recording = nil
              showProfileEditor = false
            }
          }.buttonStyle(QuietButton())
            .disabled(recording == nil || profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.vertical, 6)
      }.disclosureGroupStyle(SettingsDisclosureStyle())
      if let voice {
        Button(L("移除当前音色…")) { confirmRemove = true }.buttonStyle(QuietButton())
          .confirmationDialog(L("移除「\(voice.name)」？"), isPresented: $confirmRemove) {
            Button(L("移除音色"), role: .destructive) {
              voiceover.remove(voice)
              voiceID = ""
            }
          }
      }
    }.font(.caption)
  }

  private func chooseRecording() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK { recording = panel.url }
  }

}
