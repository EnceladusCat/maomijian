import AppKit

enum EditingChecks {
  static func run() throws {
    let e = Editor()
    let first = Clip.annotation(.arrow, at: 10)
    let second = Clip.annotation(.text, at: 20)
    let third = Clip.annotation(.caption, at: 30)
    let ids = [first.id, second.id, third.id]
    e.change { $0.clips = [first, second, third] }
    e.pickClip(first.id, lane: ids, modifiers: [])
    e.pickClip(third.id, lane: ids, modifiers: [.shift])
    precondition(e.selectedIDs == ids)
    e.pickClip(second.id, lane: ids, modifiers: [.command])
    precondition(e.selectedIDs == [first.id, third.id])
    e.pickMarquee([second.id], modifiers: [.shift], inLibrary: false)
    precondition(e.selectedIDs == [first.id, third.id, second.id])
    e.pickMarquee([second.id], modifiers: [.command], inLibrary: false)
    precondition(e.selectedIDs == [first.id, third.id])
    e.pickMarquee([], modifiers: [], inLibrary: false)
    precondition(e.selectedIDs.isEmpty)
    e.pickMarquee([first.id, third.id], modifiers: [], inLibrary: false)
    e.move(first, by: -80, edge: 0)
    precondition(e.p.clips.map(\.start) == [0, 20, 20])
    e.undo()
    precondition(e.p.clips.map(\.start) == [10, 20, 30])
    e.seek(33)
    e.split()
    precondition(e.p.clips.count == 5 && e.selectedIDs.count == 2)
    e.remove()
    precondition(e.p.clips.count == 3)
    e.undo()
    e.undo()
    e.selectAllItems()
    e.remove()
    precondition(e.p.clips.isEmpty)

    let sounds = Editor()
    for fx in BuiltInSound.allCases { sounds.insertSound(fx) }
    sounds.insertSound(.meow)
    precondition(sounds.p.assets.count == 6 && sounds.p.clips.count == 7)
    let assets = sounds.p.assets
    sounds.pickAsset(assets[1].id, modifiers: [])
    sounds.pickAsset(assets[3].id, modifiers: [.shift])
    precondition(sounds.libraryIDs == Array(assets[1...3]).map(\.id))
    sounds.pickMarquee([assets[0].id, assets[2].id], modifiers: [.command], inLibrary: true)
    precondition(sounds.libraryIDs == [assets[1].id, assets[3].id, assets[0].id])
    sounds.pickMarquee(Array(assets[1...3]).map(\.id), modifiers: [], inLibrary: true)
    precondition(sounds.libraryFocus && sounds.libraryIDs == Array(assets[1...3]).map(\.id))
    sounds.insertAssets(Array(assets[1...3]), at: 120)
    let inserted = sounds.selectedClips
    precondition(inserted.count == 3 && inserted.map(\.start) == [120, 153, 182])
    let idsToEdit = Set(inserted.map(\.id))
    let original = sounds.p
    sounds.adjustMedia(idsToEdit, rate: 2, pitch: 7)
    precondition(sounds.selectedClips.allSatisfy { $0.rate == 2 && $0.pitch == 7 })
    precondition(
      sounds.p.clips.filter { !idsToEdit.contains($0.id) }.allSatisfy {
        $0.rate == 1 && $0.pitch == 0
      })
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".framecut")
    defer { try? FileManager.default.removeItem(at: file) }
    try sounds.p.write(to: file)
    let reopened = try Project.read(from: file)
    precondition(reopened == sounds.p)
    sounds.undo()
    precondition(original == sounds.p)
  }
}
