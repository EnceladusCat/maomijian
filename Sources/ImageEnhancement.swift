import Combine
import CoreGraphics
import Foundation

final class ImageEnhancement: ObservableObject {
  struct Output {
    let file: MediaScratch.File
    let width: Int
    let height: Int

    func prepare(_ source: Media, in root: URL = ImageEnhancement.outputFolder) throws -> Prepared {
      let files = FileManager.default
      let id = UUID()
      let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
      let prefix = String(decoding: source.name.utf8.prefix(192), as: UTF8.self)
      let url = folder.appendingPathComponent(prefix + " · " + L("高清") + ".png")
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      do {
        try files.moveItem(at: file.url, to: url)
        let prepared = try autoreleasepool {
          guard let preview = StillImages.image(url, limit: StillImages.previewLimit),
            let thumbnail = StillImages.thumbnail(from: preview)
          else { throw EditError.message(L("无法读取图片「\(url.lastPathComponent)」。")) }
          let media = Media(id: id, path: url.path, frames: source.frames, video: true, audio: false, still: true)
          return Prepared(media: media, width: width, height: height, thumbnail: thumbnail)
        }
        try Task.checkCancellation()
        return prepared
      } catch {
        try? files.removeItem(at: folder)
        throw error
      }
    }
  }

  struct Prepared {
    let media: Media
    let width: Int
    let height: Int
    let thumbnail: CGImage

    func discard() {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: media.path).deletingLastPathComponent())
    }
  }

  private static var outputFolder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.framecut.editor")
      .appendingPathComponent("EnhancedImages")
  }

  @Published private(set) var progress: Double?
  private var job: Task<Void, Never>?

  func start(_ media: Media, completion: @escaping (Result<Prepared, Error>) -> Bool) {
    guard job == nil else { return }
    progress = 0
    job = Task.detached(priority: .utility) { [weak self] in
      let result: Result<Prepared, Error>
      do {
        let output = try await Self.enhance(URL(fileURLWithPath: media.path)) { value in
          await MainActor.run {
            guard let self, self.job?.isCancelled == false, self.progress != value else { return }
            self.progress = value
          }
        }
        try Task.checkCancellation()
        result = .success(try output.prepare(media))
      } catch {
        result = .failure(error)
      }
      let adopted = await MainActor.run {
        guard let self else { return false }
        let cancelled = self.job?.isCancelled == true
        self.job = nil
        self.progress = nil
        return !cancelled && completion(result)
      }
      if !adopted, case .success(let prepared) = result { prepared.discard() }
    }
  }

  func cancel() { job?.cancel() }

  static func enhance(
    _ url: URL, resources: URL? = Bundle.main.resourceURL, scratch: MediaScratch = .shared,
    report: (Double) async -> Void
  ) async throws -> Output {
    let files = FileManager.default
    guard let resources else { throw unavailable }
    let python = resources.appendingPathComponent("Audio8/python/bin/python3")
    let worker = resources.appendingPathComponent("RealPLKSR")
    let model = worker.appendingPathComponent("model_x4.onnx")
    let script = worker.appendingPathComponent("upscale.py")
    guard files.isExecutableFile(atPath: python.path), files.fileExists(atPath: model.path),
      files.fileExists(atPath: script.path) else { throw unavailable }
    guard let source = StillImages.dimensions(url) else {
      throw EditError.message(L("无法读取图片「\(url.lastPathComponent)」。"))
    }
    let long = max(source.width, source.height)
    let scale = min(4, 8192 / long, sqrt(48_000_000 / (source.width * source.height)))
    guard scale > 1 else {
      throw EditError.message(L("原图已经达到高清化上限（长边 8192 像素或 4800 万像素）。"))
    }
    let width = max(Int(source.width), Int(source.width * scale))
    let height = max(Int(source.height), Int(source.height * scale))
    guard width > Int(source.width) || height > Int(source.height) else {
      throw EditError.message(L("原图已经达到高清化上限（长边 8192 像素或 4800 万像素）。"))
    }
    let limit = max(1, (max(width, height) + 3) / 4)
    guard let image = StillImages.image(url, limit: limit), let context = bitmap(image.width, image.height) else {
      throw EditError.message(L("无法读取图片「\(url.lastPathComponent)」。"))
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let normalized = context.makeImage() else {
      throw EditError.message(L("无法读取图片「\(url.lastPathComponent)」。"))
    }
    let input = try scratch.make(.png)
    let output = try scratch.make(.png)
    let tiles = try scratch.make(.json)
    defer { withExtendedLifetime((input, tiles)) {} }
    try StillImages.writePNG(normalized, to: input.url)
    let status = try await LocalInference.run(python, arguments: [
      "-IB", script.path, model.path, input.url.path, output.url.path, tiles.url.path,
      String(width), String(height),
    ], scratch: scratch, label: "RealPLKSR") {
      if let text = try? String(contentsOf: tiles.url, encoding: .utf8), let fraction = Double(text),
        (0...1).contains(fraction) { await report(fraction * 0.95) }
    }
    guard status == 0, StillImages.dimensions(output.url) == CGSize(width: width, height: height) else {
      throw EditError.message(L("RealPLKSR 高清化失败。请尝试重新导入图片。"))
    }
    return Output(file: output, width: width, height: height)
  }

  private static var unavailable: EditError {
    .message(L("当前版本缺少 RealPLKSR 模型或运行环境。请使用完整的 Apple 芯片版毛咪剪。"))
  }
}
