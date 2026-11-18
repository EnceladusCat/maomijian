import AVFoundation
import SwiftUI

private final class SoundAudition: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published var active: BuiltInSound?
  private var player: AVAudioPlayer?
  private var request = UUID()

  func stop() {
    request = UUID()
    player?.stop()
    player = nil
    active = nil
  }
  func toggle(_ sound: BuiltInSound, failure: @escaping (String) -> Void) {
    let wasPlaying = active == sound
    stop()
    guard !wasPlaying, let url = sound.url else { return }
    let token = request
    active = sound
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { () throws -> AVAudioPlayer in
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay() else { throw EditError.message("无法准备试听音效。") }
        return player
      }
      DispatchQueue.main.async {
        guard token == self.request else { return }
        do {
          let candidate = try result.get()
          self.player = candidate
          candidate.delegate = self
          guard candidate.play() else { throw EditError.message("无法播放音效。") }
        } catch {
          self.stop()
          failure(error.localizedDescription)
        }
      }
    }
  }
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if player === self.player { stop() }
  }
}
struct SoundPanel: View {
  let e: Editor
  let shelf: ShelfState
  @StateObject private var audition = SoundAudition()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 7) {
        ForEach(BuiltInSound.allCases, id: \.self) { sound in
          HStack(spacing: 7) {
            Tool(
              symbol: audition.active == sound ? "stop.fill" : "play.fill",
              label: "试听 " + sound.rawValue
            ) { audition.toggle(sound) { e.error = $0 } }
            VStack(alignment: .leading, spacing: 2) {
              Text(sound.rawValue).font(.system(size: 12, weight: .semibold))
              Text(sound.title).font(.caption).foregroundStyle(UI.muted)
            }
            Spacer()
            Tool(symbol: "plus.circle", label: "在播放头插入 " + sound.rawValue) { e.insertSound(sound) }
          }.padding(.horizontal, 6).padding(.vertical, 4)
            .background(UI.well, in: RoundedRectangle(cornerRadius: 5))
        }
      }.padding(10)
    }.onReceive(shelf.tabs) { if $0 != .sounds { audition.stop() } }
      .onDisappear { audition.stop() }
  }
}
