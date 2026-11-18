import AVFoundation
import AudioToolbox

/// A PCM copy at a transposed sample rate. AVFoundation stretches that copy to
/// the authored timeline duration with its pitch-preserving spectral algorithm.
final class PitchedAudio {
  let url: URL
  let readable: AVURLAsset
  private init(completedFile: URL) {
    url = completedFile
    readable = AVURLAsset(url: completedFile)
  }
  deinit { try? FileManager.default.removeItem(at: url) }
  private static let cache: NSCache<NSString, PitchedAudio> = {
    let c = NSCache<NSString, PitchedAudio>()
    c.totalCostLimit = 160 * 1024 * 1024
    return c
  }()
  static func make(
    _ asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, semitones: Double,
    cancelled: () -> Bool
  ) throws -> PitchedAudio {
    let props = try asset.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let key =
      "\(asset.url.standardizedFileURL.path)|\(props.fileSize ?? 0)|\(props.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(track.trackID)|\(range.start.seconds.bitPattern)|\(range.duration.seconds.bitPattern)|\(semitones.bitPattern)"
      as NSString
    if let hit = cache.object(forKey: key) { return hit }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      "framecut-" + UUID().uuidString + ".caf")
    var transferred = false
    defer { if !transferred { try? FileManager.default.removeItem(at: destination) } }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range
    guard let description = track.formatDescriptions.first,
      let original = CMAudioFormatDescriptionGetStreamBasicDescription(
        description as! CMFormatDescription)?.pointee
    else {
      throw EditError.message("无法读取音频格式。")
    }
    let rawPCM =
      original.mFormatID == kAudioFormatLinearPCM && original.mBytesPerFrame > 0
      && (original.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    let settings: [String: Any] = [
      AVSampleRateKey: original.mSampleRate, AVNumberOfChannelsKey: Int(original.mChannelsPerFrame),
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: rawPCM ? nil : settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw EditError.message("无法读取变调音频。") }
    reader.add(output)
    guard reader.startReading() else {
      throw EditError.message("无法启动音频解码。" + (reader.error?.localizedDescription ?? ""))
    }
    var file: AudioFileID?
    var position: Int64 = 0
    defer { if let file { AudioFileClose(file) } }
    while let sample = output.copyNextSampleBuffer() {
      if cancelled() {
        reader.cancelReading()
        throw EditError.message("音频处理已取消。")
      }
      guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
      try autoreleasepool {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
          var format = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
          let block = CMSampleBufferGetDataBuffer(sample), format.mBytesPerFrame > 0
        else { throw EditError.message("不支持该音频格式。") }
        let hz = format.mSampleRate
        if file == nil {
          format.mSampleRate *= pow(2, semitones / 12)
          guard
            AudioFileCreateWithURL(
              destination as CFURL, kAudioFileCAFType, &format, .eraseFile, &file) == noErr
          else { throw EditError.message("无法创建变调音频缓存。") }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let bpf = Int(format.mBytesPerFrame)
        let sampleCount = CMBlockBufferGetDataLength(block) / bpf
        let offset = bound(Int(((range.start.seconds - pts) * hz).rounded()), 0, sampleCount)
        let end = bound(Int(((range.end.seconds - pts) * hz).rounded()), offset, sampleCount)
        let byteCount = (end - offset) * bpf
        guard byteCount > 0, let file else { return }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard
          CMBlockBufferCopyDataBytes(
            block, atOffset: offset * bpf, dataLength: byteCount, destination: &bytes) == noErr
        else { throw EditError.message("读取音频样本失败。") }
        var count = UInt32(byteCount)
        guard AudioFileWriteBytes(file, false, position, &count, bytes) == noErr,
          Int(count) == byteCount
        else { throw EditError.message("写入变调音频失败。") }
        position += Int64(count)
      }
    }
    guard reader.status == .completed, position > 0 else {
      throw EditError.message("未能解码所选范围的音频样本。" + (reader.error?.localizedDescription ?? ""))
    }
    if let outputFile = file {
      AudioFileClose(outputFile)
      file = nil
    }
    let result = PitchedAudio(completedFile: destination)
    transferred = true
    cache.setObject(result, forKey: key, cost: Int(position))
    return result
  }
}
