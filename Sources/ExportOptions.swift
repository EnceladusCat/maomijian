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
    let estimated = options.sampledBytes ?? settings.estimatedBytes(for: project)
    let displayed = ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
    VStack(alignment: .leading, spacing: 9) {
      Text("导出 MP4").font(.headline).padding(.bottom, 5)
      HStack(spacing: 14) {
        Picker(
          "分辨率",
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
          "编码",
          selection: Binding(
            get: { settings.codec },
            set: {
              options.settings.codec = $0
              options.settings.customMbps = nil
            })
        ) {
          ForEach(ExportCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.fixedSize()
        Spacer(minLength: 0)
      }
      Picker(
        "压缩档位",
        selection: Binding(
          get: { settings.quality },
          set: {
            options.settings.quality = $0
            options.settings.customMbps = nil
          })
      ) {
        ForEach(ExportQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented)
      NumberRow(
        label: "目标视频码率", value: settings.videoMbps(canvas: project.canvas),
        range: ExportSettings.bitrateRange, unit: "Mbps", precision: 1
      ) {
        options.settings.customMbps = $0
      }
      Divider()
      HStack {
        Text(options.sampledBytes == nil ? "预计文件大小" : "抽样预计大小")
        Spacer()
        if options.sampling { ProgressView().controlSize(.small) }
        if options.sampledBytes == nil {
          Button(options.sampling ? "停止抽样" : "抽样估算", action: options.sample)
            .controlSize(.small)
        }
        Text(displayed)
          .font(.system(size: 16, weight: .semibold, design: .monospaced))
          .foregroundStyle(UI.accent).accessibilityLabel("预计大小").accessibilityValue(displayed)
      }
      Text(
        options.sampleError
          ? "无法完成抽样，当前显示码率估算。"
          : options.sampledBytes == nil
            ? "按目标码率估算。简单画面通常更小，抽样可纳入画面复杂度。"
            : project.duration <= 8 * fps
              ? "这次试编码覆盖了整段。"
              : "依据时间线上的三段试编码推算，实际大小随画面变化。"
      )
      .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
      Divider().padding(.top, 3)
      HStack {
        Spacer()
        Button("取消", action: cancel).keyboardShortcut(.cancelAction)
        Button("选择保存位置…", action: proceed).keyboardShortcut(.defaultAction)
      }
    }.padding(16).frame(width: 466).background(UI.panel)
      .foregroundStyle(.white).preferredColorScheme(.dark)
  }
}
