import SwiftUI

struct CachePanel: View {
  let close: () -> Void
  @State private var bytes: Int64?
  @State private var busy = false
  @State private var message = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("磁盘缓存")).font(.system(size: 15, weight: .semibold))
        Spacer()
        if let bytes {
          let formatted = bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
          Text(formatted)
            .font(.system(size: 21, weight: .semibold, design: .rounded))
            .foregroundStyle(UI.buttonTint)
            .accessibilityLabel(L("当前占用")).accessibilityValue(formatted)
        }
      }
      Text(L("这里显示毛咪剪的临时媒体文件。播放或处理中使用的文件会在用完后回收。"))
        .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
      if busy {
        ProgressView().controlSize(.small).accessibilityLabel(L("正在检查缓存"))
      } else if !message.isEmpty {
        Text(message).font(.caption).foregroundStyle(UI.muted)
      }
      HStack {
        Spacer()
        Button(L("完成"), action: close).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(L("清理缓存")) { refresh(clean: true) }
          .buttonStyle(PrimaryButton()).disabled(busy)
      }
    }.padding(18).frame(width: 360, alignment: .leading)
      .background(UI.panel).foregroundStyle(.white).preferredColorScheme(.dark)
      .onAppear { refresh(clean: false) }
  }

  private func refresh(clean: Bool) {
    guard !busy else { return }
    busy = true
    message = ""
    DispatchQueue.global(qos: .utility).async {
      let result = Result { () -> (Int64, Int64) in
        let scratch = MediaScratch.shared
        let before = try scratch.bytesInUse()
        if clean {
          PitchedAudio.clearCache()
          try scratch.cleanAbandoned()
          let after = try scratch.bytesInUse()
          return (after, max(0, before - after))
        }
        return (before, 0)
      }
      DispatchQueue.main.async {
        busy = false
        switch result {
        case .success(let (usage, freed)):
          bytes = usage
          if clean {
            message = freed == 0 ? L("当前没有可清理的缓存。")
              : L("已释放 ") + ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
          }
        case .failure:
          message = L("无法读取缓存目录，请稍后重试。")
        }
      }
    }
  }
}
