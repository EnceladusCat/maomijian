import AVFoundation
import SwiftUI

final class SoundAudition: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published private(set) var active: URL?
  private var player: AVAudioPlayer?
  private var request = UUID()

  func stop() {
    guard active != nil else { return }
    request = UUID()
    player?.stop()
    player = nil
    active = nil
  }
  func toggle(_ url: URL, failure: @escaping (String) -> Void) {
    let wasPlaying = active == url
    stop()
    guard !wasPlaying else { return }
    let token = request
    active = url
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { () throws -> AVAudioPlayer in
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay() else { throw EditError.message(L("无法准备试听。")) }
        return player
      }
      DispatchQueue.main.async {
        guard token == self.request else { return }
        do {
          let candidate = try result.get()
          self.player = candidate
          candidate.delegate = self
          guard candidate.play() else { throw EditError.message(L("无法播放试听音频。")) }
        } catch {
          self.stop()
          failure(error.localizedDescription)
        }
      }
    }
  }
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    DispatchQueue.main.async {
      if player === self.player { self.stop() }
    }
  }
}
struct SoundPanel: View {
  let e: Editor
  let shelf: ShelfState
  @StateObject private var audition = SoundAudition()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 7) {
        ForEach(BuiltInSound.library, id: \.self) { sound in
          let url = sound.url
          HStack(spacing: 7) {
            Tool(
              symbol: audition.active != nil && audition.active == url ? "stop.fill" : "play.fill",
              label: L("试听 ") + sound.name
            ) {
              if let url { audition.toggle(url) { e.error = $0 } }
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(sound.name).font(.system(size: 12, weight: .semibold))
              Text(sound.title).font(.caption).foregroundStyle(UI.muted)
            }
            Spacer()
            Tool(symbol: "plus.circle", label: L("在播放头插入 ") + sound.name) { e.insertSound(sound) }
          }.padding(.horizontal, 6).padding(.vertical, 4)
            .background(UI.well, in: RoundedRectangle(cornerRadius: 5))
        }
      }.padding(10)
    }.onReceive(shelf.tabs) { if $0 != .sounds { audition.stop() } }
      .onDisappear { audition.stop() }
  }
}
