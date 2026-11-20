import SwiftUI

final class ExportOptions: ObservableObject {
  @Published var settings: ExportSettings {
    didSet {
      if oldValue != settings {
        cancelSample()
        sampledBytes = nil
        sampleError = false
      }
    }
  }
  @Published private(set) var sampledBytes: Int64?
  @Published private(set) var sampling = false
  @Published private(set) var sampleError = false
  private var job: ExportJob?
  let project: Project
  init(settings: ExportSettings, project: Project) {
    self.settings = settings
    self.project = project
  }
  func cancelSample() {
    job?.cancel()
    job = nil
    if sampling { sampling = false }
  }

  func sample() {
    if sampling {
      cancelSample()
      return
    }
    let task = ExportJob()
    job = task
    sampling = true
    sampleError = false
    let project = project
    let settings = settings
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = Result { try task.sampleSize(project, settings: settings) }
      DispatchQueue.main.async {
        guard let self, self.job === task else { return }
        self.job = nil
        self.sampling = false
        switch result {
        case .success(let bytes): self.sampledBytes = bytes
        case .failure: self.sampleError = true
        }
      }
    }
  }
}
struct ExportSettingsView: View {
  @ObservedObject var options: ExportOptions
  let cancel: () -> Void
  let proceed: () -> Void
  var body: some View {
    let settings = options.settings
    let project = options.project
    let bitrateEstimate = settings.screenCompression ? nil : settings.estimatedBytes(for: project)
    let estimated = options.sampledBytes ?? bitrateEstimate
    let displayed = estimated.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    VStack(alignment: .leading, spacing: 9) {
      Text(L("导出 MP4")).font(.headline).padding(.bottom, 5)
      HStack(spacing: 14) {
        Picker(
          L("分辨率"),
          selection: Binding(
            get: { settings.short },
            set: {
              options.settings.short = $0
              options.settings.customMbps = nil
            })
        ) {
          ForEach([720, 1080], id: \.self) { Text(String($0) + "p").tag($0) }
        }.fixedSize()
        Picker(
          L("编码"),
          selection: Binding(
            get: { settings.codec },
            set: {
              var updated = settings
              updated.codec = $0
              updated.customMbps = nil
              if !ExportQuality.available(for: $0).contains(updated.quality) {
                updated.quality = .balanced
              }
              options.settings = updated
            })
        ) {
          ForEach(ExportCodec.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
        }.fixedSize()
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 5) {
        SectionName(name: L("压缩档位"))
        PanelSegments(
          title: L("压缩档位"), options: ExportQuality.available(for: settings.codec),
          selection: Binding(
            get: { settings.quality },
            set: {
              options.settings.quality = $0
              options.settings.customMbps = nil
            }),
          tint: UI.buttonTint
        ) { LKey($0.rawValue) }
      }
      if settings.screenCompression {
        Text(L("适合文档、表格和软件演示。高动态画面可能比均衡档更大。"))
          .font(.caption).foregroundStyle(UI.muted)
      } else {
        NumberRow(
          label: L("目标视频码率"), value: settings.videoMbps(canvas: project.canvas),
          range: ExportSettings.bitrateRange, unit: "Mbps", precision: 1
        ) {
          options.settings.customMbps = $0
        }
      }
      Divider()
      HStack {
        Text(options.sampledBytes == nil ? L("预计文件大小") : L("抽样预计大小"))
        Spacer()
        if options.sampling { ProgressView().controlSize(.small) }
        if options.sampledBytes == nil {
          Button(options.sampling ? L("停止抽样") : L("抽样估算"), action: options.sample)
            .controlSize(.small)
        }
        Text(displayed ?? L("待抽样"))
          .font(.system(size: 16, weight: .semibold, design: .monospaced))
          .foregroundStyle(UI.accent).accessibilityLabel(L("预计大小"))
          .accessibilityValue(displayed ?? L("待抽样"))
      }
      Text(estimateNote(settings: settings))
        .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
      Divider().padding(.top, 3)
      HStack {
        Spacer()
        Button(L("取消"), action: cancel).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(L("选择保存位置…"), action: proceed).buttonStyle(PrimaryButton())
          .keyboardShortcut(.defaultAction)
      }
    }.padding(16).frame(width: 466).background(UI.panel)
      .foregroundStyle(.white).preferredColorScheme(.dark)
  }

  private func estimateNote(settings: ExportSettings) -> String {
    if options.sampleError {
      return settings.screenCompression ? L("无法完成抽样，请重试或切换压缩档位。") : L("无法完成抽样，当前显示码率估算。")
    }
    if options.sampledBytes == nil {
      return settings.screenCompression
        ? L("有损压缩。抽样可比较本档与其他档位的预计大小。")
        : L("按目标码率估算。简单画面通常更小，抽样可纳入画面复杂度。")
    }
    return options.project.duration <= settings.fullSampleLimit
      ? L("这次试编码覆盖了整段。")
      : L("依据时间线上的三段试编码推算，实际大小随画面变化。")
  }
}
