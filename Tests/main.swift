import AppKit
import CoreText
import Foundation

let spoken = "主动表示要暂缓上市，但Anthropic仍在考虑审核进度。接下来会不会冲冲冲，什么时候确认1.25万亿美元的估值。"
let speech = spoken.enumerated().map { index, character in
  let start = Double(index) * 0.18
  return RecognizedSpeech(start: start, end: start + 0.17, text: String(character))
}
let adjustedSpeech = speech.reduce(into: [RecognizedSpeech]()) { result, segment in
  // Real recognition returns Latin names and decimals as whole tokens.
  if let previous = result.last,
    previous.text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }),
    segment.text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
  {
    result[result.count - 1] = RecognizedSpeech(
      start: previous.start, end: segment.end, text: previous.text + segment.text)
  } else {
    result.append(segment)
  }
}
let generated = CaptionSegmentation.captions(
  adjustedSpeech, offset: 120, duration: 420, language: "zh-CN", terms: ["Anthropic"])
precondition(generated.first?.start == 120 && generated.last!.end <= 540)
precondition(generated.map(\.text).joined() == spoken)
precondition(generated.contains { $0.text.contains("Anthropic") })
precondition(generated.contains { $0.text.contains("1.25万亿美元") })
precondition(generated.contains { $0.text.contains("什么时候") })
precondition(generated.contains { $0.text.contains("冲冲冲") })
precondition(generated.allSatisfy {
  $0.text.first.map { !"，。！？；、".contains($0) } == true
})
let cutText = generated.map(\.text).joined(separator: "|")
precondition(!cutText.contains("考|虑") && !cutText.contains("审|核") && !cutText.contains("上|市"))
precondition(zip(generated, generated.dropFirst()).allSatisfy { $0.end <= $1.start })
let paused = CaptionSegmentation.captions(
  [RecognizedSpeech(start: 0, end: 0.95, text: "第一段"),
   RecognizedSpeech(start: 3, end: 4, text: "第二段"),
   RecognizedSpeech(start: 4, end: 4.1, text: "。")],
  offset: 210, duration: 180, language: "zh-CN")
precondition(paused.map(\.text) == ["第一段", "第二段。"] && paused.map(\.start) == [210, 300])
print("Passed caption segmentation, vocabulary, punctuation, pause and timeline alignment checks.")

// Pixel comparisons are exact before video compression.
let size = CGSize(width: 240, height: 160)
let base = bitmap(240, 160)!
for y in 0..<16 {
  for x in 0..<24 {
    let color = CGColor(
      srgbRed: CGFloat(x % 5 + 1) / 6, green: CGFloat(y % 7 + 1) / 8, blue: 0.4, alpha: 1)
    base.setFillColor(color)
    base.fill(CGRect(x: x * 10, y: y * 10, width: 10, height: 10))
  }
}
let image = base.makeImage()!
let video = Clip(kind: .video, start: 0, length: 120)
func render(_ effects: [Clip]) -> [UInt8] {
  let g = bitmap(240, 160)!
  FramePainter(Project(), size).paint(g, frame: 12, active: [video] + effects) { _ in
    Picture(image: image)
  }
  return Array(
    UnsafeBufferPointer(start: g.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
let reference = render([])
var lens = Clip.annotation(.zoom, at: 0)
lens.setRegion(CGRect(x: 0.5, y: 0.25, width: 0.4, height: 0.5))
lens.scale = 2
var spot = Clip.annotation(.highlight, at: 0)
spot.setRegion(lens.region)
spot.opacity = 0.64
let magnified = render([lens])
let highlighted = render([spot])
var changed = 0
for y in 0..<160 {
  for x in 0..<240 {
    let i = (y * 240 + x) * 4
    let inside = (120..<216).contains(x) && (40..<120).contains(y)
    for c in 0..<3 {
      if inside {
        precondition(
          reference[i + c] == highlighted[i + c], "Spotlight affected the selected region")
        if reference[i + c] != magnified[i + c] { changed += 1 }
      } else {
        precondition(reference[i + c] == magnified[i + c], "Magnification escaped its region")
        precondition(
          abs(Double(highlighted[i + c]) - Double(reference[i + c]) * 0.36) <= 1.5,
          "Incorrect outside darkness")
      }
    }
  }
}
precondition(changed > 2000)
for (x, y) in [(130, 52), (200, 98), (155, 67)] {
  let sourceX = Int(168.0 + (Double(x) + 0.5 - 168.0) / 2)
  let sourceY = Int(80.0 + (Double(y) + 0.5 - 80.0) / 2)
  for c in 0..<3 {
    precondition(
      abs(Int(magnified[(y * 240 + x) * 4 + c]) - Int(reference[(sourceY * 240 + sourceX) * 4 + c]))
        < 3, "Wrong magnification center")
  }
}
var p = Project()
let a = Clip(kind: .video, start: 0, length: 60)
let b = Clip(kind: .video, start: 60, length: 90)
let c = Clip(kind: .video, start: 150, length: 60)
let leftCaption = Clip.annotation(.caption, at: 57)
let rightCaption = Clip.annotation(.caption, at: 155)
p.clips = [a, b, c, leftCaption, rightCaption]
let authored = p.clips.map { [$0.start, $0.length, $0.offset] }
let authoredDuration = p.duration
try p.setTransition(b.id, frames: 15)
precondition(
  p.clips.map { [$0.start, $0.length, $0.offset] } == authored && p.duration == authoredDuration)
precondition(
  p.joins.first?.range == 53..<68 && p.videoVisibility[a.id] == 0..<68
    && p.videoVisibility[b.id] == 53..<150)
try p.setTransition(b.id, frames: 30)
precondition(
  p.clips.map { [$0.start, $0.length, $0.offset] } == authored && p.duration == authoredDuration)
precondition(p.joins.first?.range == 45..<75 && p.joins.first?.frame == 60)
try p.setTransition(b.id, frames: 0)
precondition(p.clips.map(\.start) == [0, 60, 150, 57, 155])
precondition(p.joins.allSatisfy { !$0.active })
p.deleteInterval(20, 30)
precondition(p.duration == 235)
let srt = try SRT.parse("1\r\n00:00:01,000 --> 00:00:02,100\r\n第一行\r\n第二行\r\n")
let decoded = try SRT.parse(SRT.write(srt))
precondition(decoded.first?.text == "第一行\n第二行" && decoded.first?.length == 33)
print(
  "Passed region containment, sample mapping, spotlight brightness, transition timing, ripple and SRT checks."
)
var roundLens = lens
roundLens.regionShape = .circle
roundLens.borderColor = "#FF0000"
let circle = render([roundLens])
func rgbAt(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
  let i = (y * 240 + x) * 4
  return [bytes[i + 2], bytes[i + 1], bytes[i]]
}
precondition(
  rgbAt(circle, 130, 42) == rgbAt(reference, 130, 42), "Circle corners must stay outside the lens")
let ring = rgbAt(circle, 168, 40)
precondition(ring[0] > 235 && ring[1] < 20 && ring[2] < 20, "Border must use chosen color")
roundLens.borderColor = nil
let white = rgbAt(render([roundLens]), 168, 40)
precondition(white.min()! > 230, "Default lens border must be white")
var roundLight = spot
roundLight.regionShape = .circle
let exposed = render([roundLight])
precondition(rgbAt(exposed, 168, 80) == rgbAt(reference, 168, 80))
precondition(rgbAt(exposed, 132, 44)[0] < rgbAt(reference, 132, 44)[0])
let sr = RegionShape.square.fit(lens.region, in: size)
precondition(abs(sr.width * size.width - sr.height * size.height) < 0.001)
precondition(SlidePhase(0.2).travel == 0 && SlidePhase(0.2).blur > 0.8)
precondition(SlidePhase(0.55).travel > 0.28 && SlidePhase(0.55).travel < 0.6)
precondition(SlidePhase(0.55).overlap > 0.4)
precondition(SlidePhase(1).travel == 1 && SlidePhase(1).blur == 0)
let out = Clip(kind: .video, start: 0, length: 70)
var inc = Clip(kind: .video, start: 40, length: 90)
inc.from = out.id
inc.blend = 30
let red = bitmap(240, 160)!
red.setFillColor(ink("#E00000"))
red.fill(CGRect(origin: .zero, size: size))
let redFrame = red.makeImage()!
var note = Clip.annotation(.rectangle, at: 0)
note.length = 70
note.x = 0.45
note.y = 0.33
note.w = 0.5
note.h = 0.22
note.color = "#FFFFFF"
func slide(_ f: Int, _ active: [Clip]) -> [UInt8] {
  let ctx = bitmap(240, 160)!
  FramePainter(Project(), size).paint(ctx, frame: f, active: active) { id in
    Picture(image: id == inc.id ? redFrame : image)
  }
  return Array(
    UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
let original = slide(40, [out, note])
let first = slide(40, [out, inc, note])
let early = slide(46, [out, inc, note])
let middle = slide(56, [out, inc, note])
let final = slide(69, [out, inc, note])
precondition(first == original)
precondition(
  early != original && rgbAt(early, 48, 50) != rgbAt(original, 48, 50),
  "The outline must blur before travel")
precondition(rgbAt(middle, 226, 75)[0] > 210 && rgbAt(middle, 16, 75) != rgbAt(middle, 226, 75))
let seamColors = [85, 100, 115, 130, 145, 160].map { rgbAt(middle, $0, 120)[0] }
precondition(Set(seamColors).count >= 5, "Moving shots should feather over a broad band")
precondition([16, 88, 125, 170, 226].allSatisfy { middle[(120 * 240 + $0) * 4 + 3] == 255 })
precondition(rgbAt(final, 16, 75) == rgbAt(final, 220, 75) && rgbAt(final, 16, 75)[0] > 210)
print("Passed circle/square geometry, lens border colors and full-frame blur-before-slide checks.")

var ramp = lens
ramp.start = 20
ramp.length = 31
ramp.zoomInFrames = 6
ramp.zoomOutFrames = 12
precondition(ramp.zoomAmount(at: 20) == 0 && ramp.zoomAmount(at: 50) == 0)
precondition(ramp.zoomAmount(at: 23) == 0.5 && ramp.zoomAmount(at: 44) == 0.5)
precondition(ramp.zoomAmount(at: 26) == 1 && ramp.zoomAmount(at: 38) == 1)
func sampleLens(_ effect: Clip, _ frame: Int) -> Data {
  let ctx = bitmap(240, 160)!
  FramePainter(Project(), size).paint(ctx, frame: frame, active: [video, effect]) { _ in
    Picture(image: image)
  }
  return Data(bytes: ctx.data!, count: 240 * 160 * 4)
}
precondition(sampleLens(ramp, 20) == Data(reference) && sampleLens(ramp, 50) == Data(reference))
precondition(sampleLens(ramp, 23) == sampleLens(ramp, 44))
precondition(sampleLens(ramp, 26) == Data(magnified))
ramp.zoomInFrames = 0
precondition(ramp.zoomAmount(at: 20) == 1 && ramp.zoomAmount(at: 50) == 0)
ramp.zoomOutFrames = 0
precondition(ramp.zoomAmount(at: 50) == 1)
for short in 1...7 {
  ramp.zoomInFrames = 9
  ramp.zoomOutFrames = 18
  ramp.length = short
  let values = (0..<short).map { ramp.zoomAmount(at: 20 + $0) }
  precondition(values.first == 0 && values.last == 0)
  if short >= 3 { precondition(values.max() == 1) }
}
ramp.zoomInFrames = nil
ramp.zoomOutFrames = nil
ramp.length = 61
precondition(ramp.entryFrames == 9 && ramp.exitFrames == 9)
let stored = try JSONEncoder().encode(ramp)
let restoredLens = try JSONDecoder().decode(Clip.self, from: stored)
precondition(restoredLens.entryFrames == 9)
print(
  "Passed zoom timing, asymmetric ramps, zero length ramps, short clips, project defaults and endpoint pixels."
)

var motionClip = Clip.annotation(.arrow, at: 5)
motionClip.motion = .slide
motionClip.motionFrames = 13
precondition(motionClip.entranceFrames == 13)
precondition(motionClip.motionOffset(at: 5, size: size).x == -size.width)
motionClip.setSlide(8)
motionClip.motion = .shake
precondition(motionClip.motionOffset(at: 36, size: size) == .zero)
motionClip.motionContinuous = true
let displacement = motionClip.motionOffset(at: 36, size: size)
precondition(abs(displacement.x) + abs(displacement.y) > 0.1)
motionClip.setSlide(0)
precondition(motionClip.motion == .shake && motionClip.motionContinuous == true)

var styledProject = Project()
var style = CaptionStyle()
style.font = "Helvetica Neue"
style.background = "#FF0000"
style.backgroundOpacity = 1
style.outlineWidth = 2
style.border = .solid
style.borderColor = "#00FF00"
style.borderWidth = 10
styledProject.captionStyle = style
let cue = Clip.annotation(.caption, at: 0)
styledProject.clips = [cue, Clip.annotation(.caption, at: 90)]
let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(styledProject))
precondition(restored == styledProject && restored.captionStyle == style)
let legacy = try JSONDecoder().decode(
  Project.self, from: Data("{\"version\":1,\"canvas\":\"16∶9\",\"assets\":[],\"clips\":[]}".utf8))
precondition(legacy.captionStyle == nil)
func subtitlePixels(_ cue: Clip, _ style: CaptionStyle) -> [UInt8] {
  let im = artwork(cue, size: CGSize(width: 1920, height: 1080), style: style)!
  let g = bitmap(im.width, im.height)!
  g.draw(im, in: CGRect(x: 0, y: 0, width: im.width, height: im.height))
  return Array(
    UnsafeBufferPointer(
      start: g.data!.assumingMemoryBound(to: UInt8.self), count: im.width * im.height * 4))
}
let solid = subtitlePixels(cue, style)
precondition(
  stride(from: 0, to: solid.count, by: 4).contains { solid[$0 + 1] > 200 && solid[$0 + 2] < 30 })
precondition(
  stride(from: 0, to: solid.count, by: 4).contains { solid[$0 + 2] > 200 && solid[$0 + 1] < 30 })
style.border = .dashed
precondition(subtitlePixels(cue, style) != solid)
print(
  "Passed global caption styling, border rendering, project persistence, legacy entrance and sustained animation checks."
)

var edit = Project()
let firstVideo = Clip(kind: .video, start: 0, length: 60)
var secondVideo = Clip(kind: .video, start: 48, length: 60)
secondVideo.from = firstVideo.id
secondVideo.blend = 12
let overlayVideo = Clip(kind: .video, start: 30, length: 70)
let thirdVideo = Clip(kind: .video, start: 108, length: 36)
edit.clips = [firstVideo, overlayVideo, secondVideo, thirdVideo]
let joins = edit.joins
precondition(joins.count == 2 && joins[0].active && !joins[1].active && joins[0].frame == 54)
let lanes = edit.videoLanes(joins)
precondition(
  lanes.count == 2 && lanes[0].map(\.id) == [firstVideo.id, secondVideo.id, thirdVideo.id]
    && lanes[1].map(\.id) == [overlayVideo.id])
print("Passed connected transition lanes and unrelated overlapping video layout.")

let legacyTimes = edit.clips.map { [$0.start, $0.length, $0.offset] }
try edit.setTransition(secondVideo.id, frames: 0)
precondition(edit.clips.map { [$0.start, $0.length, $0.offset] } == legacyTimes)
precondition(edit.joins[0].frame == 54 && !edit.joins[0].active)
precondition(
  edit.videoVisibility[firstVideo.id] == 0..<54 && edit.videoVisibility[secondVideo.id] == 54..<108)
try edit.setTransition(secondVideo.id, frames: 18)
precondition(
  edit.joins[0].range == 45..<63
    && edit.clips.map { [$0.start, $0.length, $0.offset] } == legacyTimes)
print("Passed fixed cut timing, resizing/removal, visual handles and legacy overlap anchor checks.")

var rateProject = Project()
let rateAsset = Media(path: "/test.mov", frames: 301, video: true, audio: true)
rateProject.assets = [rateAsset]
var timed = Clip(kind: .video, asset: rateAsset.id, start: 7, length: 147, offset: 5)
try timed.retime(1.75)
precondition(timed.length == 84 && timed.sourceIn == 5 && timed.sourceEnd == 152)
try timed.retime(0.25)
precondition(timed.length == 588 && timed.start == 7)
try timed.retime(1)
precondition(timed.length == 147 && timed.sourceEnd == 152)
try timed.retime(1.37)
timed.pitchSemitones = 7
rateProject.clips = [timed]
let sourceSplit = timed.sourceFrame(at: 33)
let rightID = rateProject.cut(timed.id, at: 33)!
let afterCut = rateProject.clips
precondition(afterCut[1].id == rightID && abs(afterCut[1].sourceIn - sourceSplit) < 1e-8)
precondition(abs(afterCut[0].sourceEnd - afterCut[1].sourceIn) < 1e-8)
precondition(afterCut[1].rate == 1.37 && afterCut[1].pitch == 7 && afterCut[1].sourceEnd == 152)
let rateCheck = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(rateProject))
  .checked()
precondition(rateCheck == rateProject)
rateProject.deleteInterval(20, 40)
_ = try rateProject.checked()
precondition(rateProject.clips.last!.sourceEnd == 152)
for invalid in [0.0, 0.20, 4.1, .infinity] {
  do {
    try timed.retime(invalid)
    preconditionFailure("Invalid speed accepted")
  } catch {}
}
print(
  "Passed retiming, fractional source splits, independent pitch, ripple and project round trip.")

var countdown = TimerSettings(
  direction: .custom, format: .decimal, initialSeconds: 10,
  speed: -1.5, prefix: "T ", suffix: " s")
precondition(countdown.display(frames: 60) == "T 7.0 s")
precondition(countdown.display(frames: 600) == "T 0.0 s")
countdown.direction = .down
precondition(countdown.display(frames: 1) == "T 10.0 s")
precondition(countdown.display(frames: 60) == "T 8.0 s")
countdown.direction = .up
precondition(countdown.display(frames: 60) == "T 12.0 s")
var timedArt = Clip.annotation(.timer, at: 0)
timedArt.timerSettings = countdown
timedArt.textAppearance?.outline = VisualBorder(style: .solid, width: 10, color: "#FF3500")
var footage = Clip(kind: .video, start: 0, length: 180)
var sample = Project()
let still = Media(path: "/sample.png", frames: 150, video: true, audio: false, still: true)
footage.asset = still.id
footage.angle = 90
footage.visualScale = 0.5
footage.sourceCrop = SourceCrop(left: 0.25, top: 0, right: 0.25, bottom: 0)
footage.visualBorder = VisualBorder(style: .dashed, width: 10, color: "#FFFF00")
sample.assets = [still]
sample.clips = [footage, timedArt]
sample.backgroundColor = "#21513E"
let newTimer = sample.cut(timedArt.id, at: 60)!
precondition(
  sample.clips.first { $0.id == newTimer }?.displayedText(at: 90)
    == timedArt.displayedText(at: 90))
let roundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(sample)).checked()
precondition(roundTrip == sample)
let geometry = VisualGeometry(clip: footage, canvas: size, aspect: 1.5)
precondition(
  geometry.full.width == 120 && geometry.visible.width == 60 && geometry.visible.height == 80)
func paintFixture(_ clips: [Clip], at frame: Int) -> [UInt8] {
  let context = bitmap(240, 160)!
  FramePainter(sample, size).paint(context, frame: frame, active: clips) { _ in
    Picture(image: image)
  }
  return Array(
    UnsafeBufferPointer(
      start: context.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
let boxOnly = paintFixture([footage], at: 0)
precondition(Array(boxOnly[0..<4]) == [62, 81, 33, 255])
precondition(Array(boxOnly[(80 * 240 + 120) * 4..<(80 * 240 + 120) * 4 + 3]) != [62, 81, 33])
var fixedText = timedArt
fixedText.kind = .text
fixedText.text = "AA 12"
fixedText.textAppearance?.outline.width = 20
var noOutline = fixedText
noOutline.textAppearance?.outline.style = .none
precondition(paintFixture([fixedText], at: 0) != paintFixture([noOutline], at: 0))
var dashed = fixedText
dashed.textAppearance?.outline.style = .dashed
precondition(paintFixture([fixedText], at: 0) != paintFixture([dashed], at: 0))
precondition(paintFixture([timedArt], at: 0) != paintFixture([timedArt], at: 60))
for look: FootageFilter in [.camera, .vhs, .neon, .prism] {
  var filtered = footage
  filtered.footageFilter = look
  precondition(paintFixture([filtered], at: 0) != boxOnly, "Filter \(look) did not affect pixels")
  var migrated = filtered
  migrated.filters = filtered.filters
  precondition(paintFixture([filtered], at: 0) == paintFixture([migrated], at: 0))
  filtered.filterAmount = 0
  precondition(paintFixture([filtered], at: 0) == boxOnly)
}
var layered = footage
layered.filters = [ClipFilter(look: .vhs, amount: 0.65), ClipFilter(look: .neon, amount: 0.85)]
var reordered = layered
reordered.filters.reverse()
precondition(paintFixture([layered], at: 0) != paintFixture([reordered], at: 0))
var bypassed = layered
bypassed.filters = bypassed.filters.map { ClipFilter(look: $0.look, amount: 0) }
precondition(paintFixture([bypassed], at: 0) == boxOnly)
let layeredRoundTrip = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(layered))
precondition(layeredRoundTrip.filters == layered.filters && layeredRoundTrip.footageFilter == nil)
let keySize = CGSize(width: 192, height: 108)
let keySource = bitmap(Int(keySize.width), Int(keySize.height))!
keySource.setFillColor(ink("#22BB55"))
keySource.fill(CGRect(origin: .zero, size: keySize))
keySource.setFillColor(ink("#AC323E"))
keySource.fill(CGRect(x: 80, y: 36, width: 32, height: 36))
keySource.setFillColor(ink("#16774D"))
keySource.fill(CGRect(x: 55, y: 42, width: 15, height: 24))
let screen = keySource.makeImage()!
func keyPixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
  let g = bitmap(1, 1)!
  g.draw(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!,
         in: CGRect(x: 0, y: 0, width: 1, height: 1))
  let pixel = g.data!.assumingMemoryBound(to: UInt8.self)
  return [pixel[2], pixel[1], pixel[0], pixel[3]]
}
let narrowKey = BackgroundKey.image(screen, sensitivity: 0.1, strength: 1)
let wideKey = BackgroundKey.image(screen, sensitivity: 0.9, strength: 1)
let fadingKey = BackgroundKey.image(screen, sensitivity: 0.9, strength: 0.5)
precondition(keyPixel(narrowKey, 10, 10) == [0, 0, 0, 0])
precondition(keyPixel(narrowKey, 90, 54) == [172, 50, 62, 255])
precondition(keyPixel(narrowKey, 60, 54).last == 255 && keyPixel(wideKey, 60, 54).last == 0)
precondition((126...129).contains(keyPixel(fadingKey, 10, 10)[3]))
precondition(BackgroundKey.image(screen, sensitivity: 0.5, strength: 0) === screen)

let variedScene = bitmap(Int(keySize.width), Int(keySize.height))!
for (index, color) in ["#D13C30", "#2268AE", "#E8D94C", "#121212"].enumerated() {
  variedScene.setFillColor(ink(color))
  variedScene.fill(CGRect(x: (index % 2) * 96, y: (index / 2) * 54, width: 96, height: 54))
}
let variedImage = variedScene.makeImage()!
precondition(BackgroundKey.image(variedImage, sensitivity: 0.9, strength: 1) === variedImage)

var keyProject = Project()
keyProject.backgroundColor = "#294C87"
let keyMedia = Media(path: "/Color-Key.png", frames: 120, video: true, audio: false, still: true)
var keyClip = Clip(kind: .video, asset: keyMedia.id, start: 0, length: 60)
keyClip.filters = [ClipFilter(look: .backgroundKey, keySensitivity: 0.9), ClipFilter(look: .vhs, amount: 0.65)]
keyProject.assets = [keyMedia]
keyProject.clips = [keyClip]
let storedKey = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(keyProject)).checked()
precondition(storedKey == keyProject && storedKey.clips[0].filters[0].sensitivity == 0.9)
let keyedCanvas = bitmap(Int(keySize.width), Int(keySize.height))!
FramePainter(keyProject, keySize).paint(keyedCanvas, frame: 20, active: [keyClip]) { _ in Picture(image: screen, still: true) }
let keyedImage = keyedCanvas.makeImage()!
precondition(keyPixel(keyedImage, 10, 10) == [41, 76, 135, 255])
precondition(keyPixel(keyedImage, 90, 54) != [41, 76, 135, 255])

if let folder = ProcessInfo.processInfo.environment["MAOMI_KEY_QA"] {
  let directory = URL(fileURLWithPath: folder)
  let source = directory.appendingPathComponent("Color-Key.png")
  try NSBitmapImageRep(cgImage: screen).representation(using: .png, properties: [:])!.write(to: source)
  try NSBitmapImageRep(cgImage: keyedImage).representation(using: .png, properties: [:])!
    .write(to: directory.appendingPathComponent("Keyed-Result.png"))
  keyProject.assets[0].path = source.path
  try keyProject.write(to: directory.appendingPathComponent("BackgroundKey.framecut"))
}
print("Passed automatic border color selection, adjustable key sensitivity, fades, clean alpha stacking and filter persistence.")
print("Passed ordered filter rendering, legacy pixel parity, zero intensity and persistence.")
print(
  "Passed still persistence, crop/rotation and background pixels, glyph outlines, timer phase and four filters."
)

var twoScenes = Project()
let outgoingVideo = Clip(kind: .video, start: 0, length: 60)
let enteringVideo = Clip(kind: .video, start: 60, length: 60)
twoScenes.clips = [outgoingVideo, enteringVideo]
let alternate = bitmap(240, 160)!
alternate.setFillColor(ink("#57B7C9"))
alternate.fill(CGRect(origin: .zero, size: size))
let alternateImage = alternate.makeImage()!
func transitionPixels(_ p: Project, frame: Int, parts: [Clip]) -> [UInt8] {
  let context = bitmap(240, 160)!
  FramePainter(p, size).paint(context, frame: frame, active: parts) { id in
    Picture(image: id == outgoingVideo.id ? image : alternateImage)
  }
  return Array(
    UnsafeBufferPointer(
      start: context.data!.assumingMemoryBound(to: UInt8.self),
      count: 240 * 160 * 4))
}
var intermediates = [[UInt8]]()
for look in TransitionLook.allCases {
  try twoScenes.setTransition(enteringVideo.id, frames: 15, style: look)
  let join = twoScenes.joins[0]
  precondition(join.frame == 60 && twoScenes.duration == 120 && join.after.transitionStyle == look)
  precondition(
    transitionPixels(twoScenes, frame: join.range.lowerBound, parts: twoScenes.clips)
      == transitionPixels(twoScenes, frame: join.range.lowerBound, parts: [outgoingVideo]))
  precondition(
    transitionPixels(twoScenes, frame: join.range.upperBound - 1, parts: twoScenes.clips)
      == transitionPixels(twoScenes, frame: join.range.upperBound - 1, parts: [enteringVideo]))
  intermediates.append(transitionPixels(twoScenes, frame: 60, parts: twoScenes.clips))
  try twoScenes.setTransition(enteringVideo.id, frames: 9)
  precondition(twoScenes.joins[0].after.transitionStyle == look)
}
precondition(Set(intermediates).count == TransitionLook.allCases.count)
let restoredLook = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(twoScenes))
precondition(restoredLook.joins[0].after.transitionStyle == .shake)
print(
  "Passed nine distinct transition renders, endpoint pixels, duration edits and look persistence.")

// Both clip ends use the full range of previews without changing the authored clip timing.
var trimProject = Project()
trimProject.backgroundColor = "#268074"
let edgeClip = Clip(kind: .video, start: 10, length: 60)
trimProject.clips = [edgeClip]
let headEdge = EdgeTarget(clipID: edgeClip.id, end: .head)
let tailEdge = EdgeTarget(clipID: edgeClip.id, end: .tail)
try trimProject.setEdgeEffect(headEdge, frames: 15, style: .dissolve)
try trimProject.setEdgeEffect(tailEdge, frames: 15, style: .comparison)
let renderedHead = transitionPixels(trimProject, frame: 10, parts: trimProject.clips)
precondition(renderedHead == transitionPixels(trimProject, frame: 10, parts: []))
let renderedHeadEnd = transitionPixels(trimProject, frame: 24, parts: trimProject.clips)
precondition(renderedHeadEnd == transitionPixels(trimProject, frame: 24, parts: [edgeClip]))
precondition(
  transitionPixels(trimProject, frame: 69, parts: trimProject.clips)
    == transitionPixels(trimProject, frame: 69, parts: []))
let rightEdgeID = trimProject.cut(edgeClip.id, at: 30)!
let rightEdge = trimProject.clips.first { $0.id == rightEdgeID }!
precondition(trimProject.clips[0].startEffect != nil && trimProject.clips[0].endEffect == nil)
precondition(rightEdge.startEffect == nil && rightEdge.endEffect != nil)

var longTimeline = Project()
let rawAsset = Media(path: "/recording.mov", frames: 21690, video: true, audio: true)
longTimeline.assets = [rawAsset]
var recording = Clip(kind: .video, asset: rawAsset.id, start: 100, length: 18000)
recording.setSource(50.4, 21650.4)
recording.speed = 1.2
recording.pitchSemitones = 2.5
recording.startEffect = ClipEdgeEffect(style: .dissolve, frames: 12)
recording.endEffect = ClipEdgeEffect(style: .fire, frames: 16)
longTimeline.clips = [recording]
var cut = try BatchCutPlan(clips: longTimeline.clips, settings: BatchCutSettings())
precondition(cut.parts.count == 600 && cut.remainders.isEmpty)
for i in cut.parts.indices {
  cut.parts[i].adjustments.time = Double(i) * 0.1
  cut.parts[i].adjustments.scale = 100 + Double(i) * 0.5
  cut.parts[i].adjustments.x = Double(i) * 0.01
}
let batch = try longTimeline.applying(cut)
precondition(batch.project.clips.count == 600 && Set(batch.selected).count == 600)
let part = batch.project.clips[22]
precondition(part.start == 826 && part.length == 30 && abs(part.displayScale - 1.11) < 0.001)
precondition(abs(part.sourceIn - (50.4 + Double(22 * 36))) < 1e-7 && part.pitch == 2.5)
precondition(batch.project.clips[0].startEffect?.style == .dissolve)
precondition(batch.project.clips.last?.endEffect?.style == .fire)
precondition(batch.project.clips.dropFirst().allSatisfy { $0.startEffect == nil })
let limited = try BatchCutPlan(clips: [recording], settings: BatchCutSettings(limit: 10))
var halfStep = limited
halfStep.parts[3].adjustments.time = 0.15 * 3
let roundedBatch = try longTimeline.applying(halfStep)
precondition(roundedBatch.project.clips[3].start == 204)
let limitedBatch = try longTimeline.applying(limited)
precondition(limitedBatch.selected.count == 10 && limitedBatch.project.clips.count == 11)
precondition(limitedBatch.project.clips.last?.length == 17700)
var uneven = recording
uneven.length = 103
let equalCuts = try BatchCutPlan(clips: [uneven], settings: BatchCutSettings(mode: .count))
precondition(equalCuts.parts.count == 10 && equalCuts.parts.map(\.range.count).reduce(0, +) == 103)
precondition(equalCuts.parts.contains { $0.range.count == 11 })
var bad = limited
bad.parts[1].adjustments.time = -100
do {
  _ = try longTimeline.applying(bad)
  preconditionFailure("Invalid timeline move accepted")
} catch {}
print(
  "Passed both clip ends, retimed source partitions, 600 cuts, capped and equal divisions, per-part shifts and rejection."
)

let batchAudio = Media(path: "/tmp/framecut-split.wav", frames: 180, video: false, audio: true)
let batchAudioClip = Clip(kind: .audio, asset: batchAudio.id, start: 15, length: 90)
var batchTitle = Clip.annotation(.text, at: 15)
batchTitle.textAppearance = TextAppearance(size: 80, fixedSize: true)
var batchTimer = Clip.annotation(.timer, at: 15)
batchTimer.length = 90
let batchCaption = Clip.annotation(.caption, at: 15)
var batchMixed = Project()
batchMixed.assets = [batchAudio]
batchMixed.clips = [
  batchAudioClip, batchTitle, batchTimer, batchCaption, Clip.annotation(.highlight, at: 15),
  Clip.annotation(.zoom, at: 15), Clip.annotation(.ellipse, at: 15),
]
batchMixed.group([batchCaption.id, batchAudioClip.id])
var mixedPlan = try BatchCutPlan(
  clips: batchMixed.clips, settings: BatchCutSettings(mode: .count, count: 2))
for i in mixedPlan.parts.indices where mixedPlan.parts[i].ordinal == 1 {
  mixedPlan.parts[i].adjustments = BatchAdjustment(time: 0.5, x: 10, y: 5, scale: 125)
}
let mixedOutput = try batchMixed.applying(mixedPlan)
precondition(mixedOutput.selected.count == batchMixed.clips.count * 2)
let audioPart = mixedOutput.project.clips[1]
precondition(audioPart.kind == .audio && audioPart.start == 75 && audioPart.offset == 45 && audioPart.x == 0.5)
let titlePart = mixedOutput.project.clips[3]
precondition(titlePart.kind == .text && titlePart.start == 75 && titlePart.x == 0.6)
precondition(titlePart.w == batchTitle.w * 1.25 && titlePart.textAppearance?.size == 100)
precondition(mixedOutput.project.clips[5].timerPhase == 45)
let captionPart = mixedOutput.project.clips[7]
precondition(captionPart.kind == .caption && captionPart.w == batchCaption.w && captionPart.x == 0.6)
precondition(mixedOutput.project.expandingGroups([captionPart.id]).count == 4)
precondition(mixedOutput.project.clips[11].scale == batchMixed.clips[5].scale)
print("Passed batch splitting and per-part edits for mixed audio, text, captions, timers, shapes and regions.")

var placements = Project()
let clipA = Clip(kind: .video, start: 0, length: 60)
let clipB = Clip(kind: .video, start: 60, length: 60)
let isolated = Clip(kind: .video, start: 150, length: 42)
placements.clips = [clipA, clipB, isolated]
func placedAt(_ point: Double) -> [TransitionTarget] {
  TransitionTarget.at(x: point, first: 0, per: 2, clips: placements.clips, joins: placements.joins)
}
let seam = TransitionTarget.join(clipB.id)
let head = TransitionTarget.edge(EdgeTarget(clipID: isolated.id, end: .head))
let tail = TransitionTarget.edge(EdgeTarget(clipID: isolated.id, end: .tail))
precondition(placedAt(121) == [seam] && placedAt(133) == [seam])
precondition(placedAt(138) == [.edge(EdgeTarget(clipID: clipB.id, end: .head))])
precondition(placedAt(299).isEmpty && placedAt(260).isEmpty)
precondition(placedAt(308) == [head])
precondition(placedAt(342) == [head, tail])
precondition(placedAt(376) == [tail])
let lengthBefore = placements.duration
try placements.placeTransition(.fire, on: placedAt(342))
precondition(placements.transitionEffect(head)?.style == .fire)
precondition(placements.transitionEffect(tail)?.frames == 15)
try placements.placeTransition(.comparison, on: placedAt(121))
try placements.updateTransition(seam, frames: 27)
precondition(placements.transitionEffect(seam)?.frames == 27)
try placements.placeTransition(.dissolve, on: [seam])
precondition(placements.transitionEffect(seam) == ClipEdgeEffect(style: .dissolve, frames: 27))
let incomingHead = TransitionTarget.edge(EdgeTarget(clipID: clipB.id, end: .head))
try placements.placeTransition(.glitch, on: [incomingHead])
precondition(placements.transitionEffect(seam) == nil)
precondition(placements.transitionEffect(incomingHead)?.style == .glitch)
try placements.placeTransition(.warp, on: [seam])
precondition(placements.transitionEffect(incomingHead) == nil)
try placements.updateTransition(seam, frames: 0)
precondition(placements.transitionEffect(seam) == nil && placements.duration == lengthBefore)
precondition(placements.clips.map(\.start) == [0, 60, 150])
precondition(placements.clips.map(\.length) == [60, 60, 42])
let tiny = Clip(kind: .video, start: 0, length: 4)
var shortTransition = Project()
shortTransition.clips = [tiny]
try shortTransition.placeTransition(.dissolve, on: TransitionTarget.ends(of: tiny))
precondition(shortTransition.clips[0].startEffect?.frames == 2)
precondition(shortTransition.clips[0].endEffect?.frames == 2)
print("Passed direct transition placement, fixed timing, resizing, replacement and short clips.")

var groups = Project()
let groupText = Clip.annotation(.text, at: 0)
let groupTimer = Clip.annotation(.timer, at: 30)
let otherArt = Clip.annotation(.rectangle, at: 180)
groups.clips = [groupText, groupTimer, otherArt]
groups.group([groupText.id, groupTimer.id])
let savedGroup = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(groups)).checked()
precondition(savedGroup == groups && groups.clips[0].groupID != nil && groups.clips[2].groupID == nil)
precondition(groups.expandingGroups([groupTimer.id]) == [groupText.id, groupTimer.id])
let groupPart = groups.cut(groupTimer.id, at: 60)!
precondition(Set(groups.expandingGroups([groupText.id])) == [groupText.id, groupTimer.id, groupPart])
groups.group([groupText.id, otherArt.id])
precondition(groups.expandingGroups([otherArt.id]).count == 4)
groups.ungroup([groupPart])
precondition(groups.clips.allSatisfy { $0.groupID == nil })
groups = savedGroup
groups.clips.removeAll { $0.id == groupTimer.id }
groups.clearSingletonGroups()
precondition(groups.clips.allSatisfy { $0.groupID == nil })

var headline = Clip.annotation(.text, at: 0)
headline.text = "H"
var headlineStyle = TextAppearance(size: 240, fixedSize: true, shadow: TextShadow(enabled: false))
headline.textAppearance = headlineStyle
func textPixels(_ clip: Clip) -> [UInt8] {
  let g = bitmap(240, 160)!
  FramePainter(Project(), size).paint(g, frame: 0, active: [clip]) { _ in nil }
  return Array(UnsafeBufferPointer(start: g.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
func whiteRows(_ pixels: [UInt8]) -> Int {
  (0..<160).filter { y in (0..<240).contains { x in pixels[(y * 240 + x) * 4] > 235 } }.count
}
let normalRows = whiteRows(textPixels(headline))
headlineStyle.size = 720
headline.textAppearance = headlineStyle
let large = textPixels(headline)
precondition(normalRows > 15 && whiteRows(large) > 2 * normalRows, "Large text shrank into its old box")
headlineStyle.shadow = TextShadow(color: "#FF0000", opacity: 1, blur: 0, x: 235, y: 85)
headline.textAppearance = headlineStyle
let shadowed = textPixels(headline)
let shadowDots = (0..<240 * 160).filter {
  shadowed[$0 * 4 + 2] > 200 && shadowed[$0 * 4] < 20
}
precondition(!shadowDots.isEmpty && shadowDots.map { $0 % 240 }.max()! > 170)
headlineStyle.shadow?.enabled = false
headline.textAppearance = headlineStyle
precondition(textPixels(headline) == large)
headlineStyle.size = 1e25
headline.textAppearance = headlineStyle
groups.clips = [headline]
let giantProject = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(groups)).checked()
precondition(giantProject == groups)
precondition(textPixels(headline).count == 240 * 160 * 4)
print("Passed group persistence and splitting, fixed large text, and custom shadow pixels.")

var joinedGroup = twoScenes
let internalCut = TransitionTarget.join(enteringVideo.id)
try joinedGroup.updateTransition(internalCut, frames: 19, style: .slide)
let seamBefore = joinedGroup.transitionEffect(internalCut)
let beforeGrouping = (51..<70).map { transitionPixels(joinedGroup, frame: $0, parts: joinedGroup.clips) }
joinedGroup.group([outgoingVideo.id, enteringVideo.id])
let afterGrouping = (51..<70).map { transitionPixels(joinedGroup, frame: $0, parts: joinedGroup.clips) }
precondition(beforeGrouping == afterGrouping, "Grouping must not change the existing transition pixels")
let headOfGroup = TransitionTarget.edge(EdgeTarget(clipID: outgoingVideo.id, end: .head))
let tailOfGroup = TransitionTarget.edge(EdgeTarget(clipID: enteringVideo.id, end: .tail))
let cardTargets = TransitionTarget.cardTargets(for: joinedGroup.clips)
precondition(cardTargets == [headOfGroup, tailOfGroup])
try joinedGroup.placeTransition(.dissolve, on: cardTargets)
precondition(joinedGroup.transitionEffect(internalCut) == seamBefore)
precondition(joinedGroup.transitionEffect(headOfGroup)?.style == .dissolve)
precondition(joinedGroup.transitionEffect(tailOfGroup)?.style == .dissolve)
let internalPixels = transitionPixels(joinedGroup, frame: 60, parts: joinedGroup.clips)
for i in joinedGroup.clips.indices { joinedGroup.clips[i].start += 23 }
precondition(joinedGroup.joins.first?.frame == 83 && joinedGroup.transitionEffect(internalCut) == seamBefore)
precondition(transitionPixels(joinedGroup, frame: 83, parts: joinedGroup.clips) == internalPixels)
try joinedGroup.placeTransition(.flip, on: [internalCut])
precondition(joinedGroup.transitionEffect(internalCut) == ClipEdgeEffect(style: .flip, frames: 19))
precondition(joinedGroup.transitionEffect(headOfGroup)?.style == .dissolve)
precondition(joinedGroup.transitionEffect(tailOfGroup)?.style == .dissolve)
print("Passed grouped transition pixels, outer-edge application, movement and direct seam replacement.")

var layeredSeam = twoScenes
let cutFrame = 60
let outgoingGroup = UUID(), incomingGroup = UUID()
layeredSeam.clips[0].groupID = outgoingGroup
layeredSeam.clips[1].groupID = incomingGroup
var upperBefore = Clip.annotation(.rectangle, at: 0)
upperBefore.length = cutFrame
upperBefore.groupID = outgoingGroup
upperBefore.color = "#FFFFFF"
var upperAfter = Clip.annotation(.ellipse, at: cutFrame)
upperAfter.length = 60
upperAfter.groupID = incomingGroup
upperAfter.color = "#FFE046"
layeredSeam.clips += [upperBefore, upperAfter]
try layeredSeam.updateTransition(internalCut, frames: 24, style: .glitch)
let seamShot = layeredSeam.joins[0]
let beforeScene = bitmap(240, 160)!, afterScene = bitmap(240, 160)!
let painter = FramePainter(layeredSeam, size)
painter.paint(beforeScene, frame: cutFrame - 1, active: [seamShot.before, upperBefore]) { _ in Picture(image: image) }
painter.paint(afterScene, frame: cutFrame, active: [seamShot.after, upperAfter]) { _ in Picture(image: alternateImage) }
let beforePixels = beforeScene.makeImage()!, afterPixels = afterScene.makeImage()!
for frame in seamShot.range.dropFirst().dropLast() {
  let expected = bitmap(240, 160)!, scratch = bitmap(240, 160)!
  let progress = Double(frame - seamShot.range.lowerBound) / Double(seamShot.range.count - 1)
  TransitionEffects.draw(.glitch, before: beforePixels, after: afterPixels, progress: progress,
    in: expected, scratch: scratch, canvas: CGRect(origin: .zero, size: size))
  let visible = layeredSeam.clips.filter { clip in
    (layeredSeam.videoVisibility[clip.id] ?? (clip.start..<clip.end)).contains(frame)
  }
  let actual = transitionPixels(layeredSeam, frame: frame, parts: visible)
  let reference = Array(UnsafeBufferPointer(start: expected.data!.assumingMemoryBound(to: UInt8.self), count: actual.count))
  precondition(actual == reference, "Grouped layers and their media differ at transition frame \(frame)")
}

var endProject = Project()
var lowerAtEnd = outgoingVideo
lowerAtEnd.groupID = outgoingGroup
lowerAtEnd.endEffect = ClipEdgeEffect(style: .dissolve, frames: 24)
var upperIndependent = upperBefore
upperIndependent.id = UUID()
upperIndependent.groupID = nil
upperIndependent.x = 0.20
endProject.clips = [lowerAtEnd, upperBefore, upperIndependent]
let endPixels = transitionPixels(endProject, frame: cutFrame - 1, parts: endProject.clips)
precondition(endPixels == transitionPixels(endProject, frame: cutFrame - 1, parts: [upperIndependent]))
var lowerAtStart = lowerAtEnd
lowerAtStart.endEffect = nil
lowerAtStart.startEffect = ClipEdgeEffect(style: .dissolve, frames: 24)
endProject.clips[0] = lowerAtStart
let startPixels = transitionPixels(endProject, frame: 0, parts: endProject.clips)
precondition(startPixels == transitionPixels(endProject, frame: 0, parts: [upperIndependent]))

let dragSnap = TimelineSnap(anchors: [20, 45], targets: [0, 58, 89, 58], limits: -20...100)
precondition(dragSnap.placement(for: 11.5, per: 2).shift == 13)
precondition(dragSnap.placement(for: 11.5, per: 2).guide == 58)
precondition(dragSnap.placement(for: 20, per: 2).guide == nil)
precondition(dragSnap.placement(for: -50, per: 2).shift == -20)
let trimSnap = TimelineSnap(anchors: [40], targets: [43, 44, 45], limits: -5...3)
precondition(trimSnap.placement(for: 5.5, per: 2).guide == 43)
let groupedSnap = TimelineSnap(anchors: [40, 65, 20, 95], targets: [105], limits: -20...100)
precondition(groupedSnap.placement(for: 9, per: 2).guide == 105)
print("Passed grouped upper/lower transition frames and move and trim alignment.")

let clipboardMedia = Media(path: "/tmp/framecut-clipboard.mp4", frames: 180, video: true, audio: true)
var clipboardSource = Project()
clipboardSource.assets = [clipboardMedia]
var copyA = Clip(kind: .video, asset: clipboardMedia.id, start: 10, length: 40)
copyA.x = -0.25
copyA.volume = 0.55
copyA.pitchSemitones = -3
copyA.filters = [ClipFilter(look: .neon), ClipFilter(look: .prism, amount: 0.5)]
copyA.startEffect = ClipEdgeEffect(style: .dissolve, frames: 10)
let copyB = Clip(kind: .video, asset: clipboardMedia.id, start: 50, length: 40, offset: 11)
let copyLabel = Clip.annotation(.text, at: 20)
clipboardSource.clips = [copyA, copyB, copyLabel]
clipboardSource.group([copyA.id, copyB.id, copyLabel.id])
try clipboardSource.setTransition(copyB.id, frames: 15, style: .glitch)
let payload = TimelineClipboard(project: clipboardSource, selection: [copyLabel.id])
let clipboard = try JSONDecoder().decode(TimelineClipboard.self, from: JSONEncoder().encode(payload))
var pasteTarget = clipboardSource
let newIDs = try clipboard.paste(into: &pasteTarget, at: 150)
let pasted = Array(pasteTarget.clips.suffix(3))
precondition(newIDs == pasted.map(\.id) && Set(newIDs).isDisjoint(with: [copyA.id, copyB.id, copyLabel.id]))
precondition(pasteTarget.assets == clipboardSource.assets && pasted.map(\.start) == [150, 190, 160])
precondition(pasteTarget.expandingGroups([newIDs[0]]).count == 3 && pasted[0].groupID != clipboardSource.clips[0].groupID)
precondition(pasted[1].from == newIDs[0] && pasted[1].offset == 11 && pasted[1].transitionStyle == .glitch)
precondition(pasted[0].startEffect == copyA.startEffect)
let validPaste = try pasteTarget.checked()
precondition(validPaste == pasteTarget)
do {
  _ = try clipboard.paste(into: &pasteTarget, at: maxFrames - 10)
  preconditionFailure("A paste outside the timeline was accepted")
} catch { precondition(pasteTarget == validPaste) }
clipboardSource.ungroup([copyA.id])
let singleClip = TimelineClipboard(project: clipboardSource, selection: [copyB.id])
var newDocument = Project()
_ = try singleClip.paste(into: &newDocument, at: 0)
precondition(newDocument.assets == [clipboardMedia] && newDocument.clips[0].from == nil)

var propertyReceiver = clipboardSource.clips[1]
let propertyIdentity = propertyReceiver
propertyReceiver.applyProperties(from: clipboardSource.clips[0], sharedAudio: true)
precondition(propertyReceiver.x == copyA.x && propertyReceiver.volume == copyA.volume)
precondition(propertyReceiver.pitch == copyA.pitch && propertyReceiver.filters == copyA.filters)
precondition(propertyReceiver.id == propertyIdentity.id && propertyReceiver.asset == propertyIdentity.asset)
precondition(propertyReceiver.start == propertyIdentity.start && propertyReceiver.sourceIn == propertyIdentity.sourceIn)
precondition(propertyReceiver.length == propertyIdentity.length && propertyReceiver.from == propertyIdentity.from)
precondition(propertyReceiver.startEffect == propertyIdentity.startEffect && propertyReceiver.blend == propertyIdentity.blend)
var titleSource = copyLabel
titleSource.textAppearance = TextAppearance(size: 640, shadow: TextShadow(color: "#FF0000"))
var titleTarget = Clip.annotation(.text, at: 92)
titleTarget.text = "Different title"
titleTarget.applyProperties(from: titleSource)
precondition(titleTarget.text == "Different title" && titleTarget.textAppearance == titleSource.textAppearance)
let existingTextAppearance = titleTarget.textAppearance
titleTarget.applyProperties(from: copyA)
precondition(titleTarget.x == 0 && titleTarget.opacity == copyA.opacity && titleTarget.textAppearance == existingTextAppearance)
var audioReceiver = Clip(kind: .audio, asset: clipboardMedia.id, start: 15, length: 25)
precondition(audioReceiver.acceptsProperties(from: copyA, sharedAudio: true))
precondition(!audioReceiver.acceptsProperties(from: titleSource, sharedAudio: false))
audioReceiver.applyProperties(from: copyA, sharedAudio: true)
precondition(audioReceiver.volume == copyA.volume && audioReceiver.pitch == copyA.pitch && audioReceiver.start == 15)

var layers = Project()
var overlapVideo = enteringVideo
overlapVideo.start = 0
layers.clips = [outgoingVideo, overlapVideo, leftCaption]
layers.moveTrack("video0", to: "text0")
precondition(layers.timelineTracks(joins: layers.joins).map(\.id).prefix(3) == ["caption0", "video0", "text0"])
let lowerVideoOnTop = transitionPixels(layers, frame: 0, parts: [outgoingVideo, overlapVideo])
precondition(lowerVideoOnTop == transitionPixels(layers, frame: 0, parts: [outgoingVideo]))
layers.moveTrack("video0", to: "video1")
let upperVideoOnTop = transitionPixels(layers, frame: 0, parts: [outgoingVideo, overlapVideo])
precondition(upperVideoOnTop == transitionPixels(layers, frame: 0, parts: [overlapVideo]))
let layerOrder = layers.trackOrder
layers.moveTrack("caption0", to: "video1")
layers.moveTrack("video1", to: "caption0")
precondition(layers.trackOrder == layerOrder && layers.timelineTracks(joins: layers.joins)[0].pinned)
let layerRoundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(layers))
precondition(layerRoundTrip.trackOrder == layerOrder)
var fullDim = Clip.annotation(.highlight, at: 0)
fullDim.setRegion(CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
fullDim.opacity = 1
var captionOnTop = Clip.annotation(.caption, at: 0)
captionOnTop.text = "Always above"
layers.clips = [outgoingVideo, fullDim, captionOnTop]
layers.moveTrack("text0", to: "zoom0")
let captionWithEffect = transitionPixels(layers, frame: 0, parts: layers.clips)
let withoutCaption = transitionPixels(layers, frame: 0, parts: [outgoingVideo, fullDim])
precondition(captionWithEffect != withoutCaption)
print("Passed clipboard remapping, property application, track order persistence and caption stacking.")

func effectFrame(_ effect: Clip?, frame: Int) -> [UInt8] {
  let canvas = bitmap(240, 160)!
  FramePainter(Project(), size).paint(canvas, frame: frame, active: [video] + (effect.map { [$0] } ?? [])) {
    _ in Picture(image: image)
  }
  return Array(UnsafeBufferPointer(
    start: canvas.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
var fadingSpot = spot
fadingSpot.highlightFadeIn = true
fadingSpot.highlightFadeOut = true
precondition(effectFrame(fadingSpot, frame: 0) == reference)
precondition(effectFrame(fadingSpot, frame: fadingSpot.end - 1) == reference)
precondition(effectFrame(fadingSpot, frame: 9) == highlighted)
let dim = effectFrame(fadingSpot, frame: 4)
precondition((highlighted[0]..<reference[0]).contains(dim[0]))
fadingSpot.highlightFadeIn = false
precondition(effectFrame(fadingSpot, frame: 0) == highlighted)

var wideLens = lens
wideLens.lensBorderWidth = 48
wideLens.borderColor = "#FF00FF"
let wideLensPixels = effectFrame(wideLens, frame: 12)
var borderlessLens = wideLens
borderlessLens.lensBorderWidth = 0
let borderless = effectFrame(borderlessLens, frame: 12)
precondition(wideLensPixels != borderless)
let lensCenter = (80 * 240 + 170) * 4
precondition(wideLensPixels[lensCenter..<lensCenter + 4] == borderless[lensCenter..<lensCenter + 4])

for kind in [Kind.text, .timer, .rectangle, .ellipse, .arrow] {
  var art = Clip.annotation(kind, at: 0)
  art.text = "MEOW"
  art.color = "#FABAB5"
  art.w = 0.60
  art.h = 0.25
  let appearances = ReliefStyle.allCases.map { style -> [UInt8] in
    art.reliefStyle = style
    return textPixels(art)
  }
  precondition(Set(appearances).count == ReliefStyle.allCases.count)
}
var fixedRelief = Clip.annotation(.text, at: 0)
fixedRelief.text = "Aa猫"
fixedRelief.textAppearance = TextAppearance(size: 290, fixedSize: true)
let flatRelief = textPixels(fixedRelief)
fixedRelief.reliefStyle = .chrome
precondition(textPixels(fixedRelief) != flatRelief)
var annotations = Project()
annotations.clips = [fadingSpot, wideLens, fixedRelief]
let reopenedAnnotations = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(annotations)).checked()
precondition(reopenedAnnotations == annotations)
print("Passed spotlight fades, variable zoom border, and distinct 3D annotation renders.")

func animatedPixels(_ clip: Clip, at frame: Int) -> [UInt8] {
  let g = bitmap(240, 160)!
  FramePainter(Project(), size).paint(g, frame: frame, active: [clip]) { _ in nil }
  return Array(UnsafeBufferPointer(
    start: g.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
func paintedDots(_ pixels: [UInt8]) -> Set<Int> {
  Set((0..<240 * 160).filter { index in
    pixels[index * 4] > 20 || pixels[index * 4 + 1] > 20 || pixels[index * 4 + 2] > 20
  })
}
var animatedTitle = Clip.annotation(.text, at: 0)
animatedTitle.text = "ABCD"
animatedTitle.textAppearance = TextAppearance(size: 270, fixedSize: true, shadow: TextShadow(enabled: false))
animatedTitle.textAnimation = TextAnimation(characters: true)
let firstLetter = animatedPixels(animatedTitle, at: 3)
let halfTitle = animatedPixels(animatedTitle, at: 6)
let entireTitle = animatedPixels(animatedTitle, at: 12)
precondition(paintedDots(animatedPixels(animatedTitle, at: 0)).isEmpty)
precondition(!paintedDots(firstLetter).isEmpty)
precondition(paintedDots(firstLetter).isStrictSubset(of: paintedDots(halfTitle)))
precondition(paintedDots(halfTitle).isStrictSubset(of: paintedDots(entireTitle)))
precondition(animatedPixels(animatedTitle, at: animatedTitle.end - 1 - 3) == firstLetter)
precondition(paintedDots(animatedPixels(animatedTitle, at: animatedTitle.end - 1)).isEmpty)

animatedTitle.text = "A👩‍🔬汉B"
let beforeEmoji = animatedPixels(animatedTitle, at: 3)
let afterEmoji = animatedPixels(animatedTitle, at: 6)
precondition(paintedDots(beforeEmoji).isStrictSubset(of: paintedDots(afterEmoji)))
precondition(animatedPixels(animatedTitle, at: 5) == beforeEmoji)

animatedTitle.text = "Underlined\nTitle"
animatedTitle.textAppearance = nil
animatedTitle.h = 0.38
animatedTitle.textAnimation = TextAnimation(underline: true)
let unlined = paintedDots(animatedPixels(animatedTitle, at: 0))
let growing = paintedDots(animatedPixels(animatedTitle, at: 6))
let underlined = paintedDots(animatedPixels(animatedTitle, at: 12))
precondition(!unlined.isEmpty && unlined.isStrictSubset(of: growing))
precondition(growing.isStrictSubset(of: underlined))
precondition(animatedPixels(animatedTitle, at: animatedTitle.end - 1 - 6)
  == animatedPixels(animatedTitle, at: 6))
let animatedCopy = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(animatedTitle))
precondition(animatedCopy == animatedTitle)
precondition(BuiltInSound.woosh.frames == 12 && BuiltInSound.legacyWoosh.frames == 24)
precondition(BuiltInSound.library.filter { $0.name == "WOOSH" } == [.woosh])
print("Passed grapheme-by-grapheme animation, stable text layout, animated underlines and WOOSH compatibility.")

var fadingFilter = ClipFilter(look: .edgeBlur, amount: 0.8, fadeInFrames: 10, fadeOutFrames: 8)
precondition(video.filterIntensity(fadingFilter, at: video.start) == 0)
precondition(abs(video.filterIntensity(fadingFilter, at: video.start + 5) - 0.4) < 0.0001)
precondition(video.filterIntensity(fadingFilter, at: video.start + 10) == 0.8)
precondition(video.filterIntensity(fadingFilter, at: video.end - 1) == 0)
let checker = bitmap(240, 160)!
for y in stride(from: 0, to: 160, by: 4) {
  for x in stride(from: 0, to: 240, by: 4) {
    checker.setFillColor(ink((x / 4 + y / 4).isMultiple(of: 2) ? "#FFFFFF" : "#000000"))
    checker.fill(CGRect(x: x, y: y, width: 4, height: 4))
  }
}
let grid = checker.makeImage()!
var filteredImage = video
fadingFilter.amount = 1
filteredImage.filters = [fadingFilter]
let photoPainter = FramePainter(Project(), size)
func photoPixels(_ frame: Int) -> [UInt8] {
  let g = bitmap(240, 160)!
  photoPainter.paint(g, frame: frame, active: [filteredImage]) { _ in Picture(image: grid, still: true) }
  return Array(UnsafeBufferPointer(
    start: g.data!.assumingMemoryBound(to: UInt8.self), count: 240 * 160 * 4))
}
let sharpGrid = photoPixels(0)
let softEdge = photoPixels(20)
let halfBlur = photoPixels(5)
let edgePixel = (4 * 240 + 4) * 4
let middlePixel = (81 * 240 + 121) * 4
precondition(abs(Int(sharpGrid[middlePixel]) - Int(softEdge[middlePixel])) < 3)
precondition(abs(Int(sharpGrid[edgePixel]) - Int(softEdge[edgePixel])) > 30)
precondition(sharpGrid != halfBlur && softEdge != halfBlur)
precondition(photoPixels(filteredImage.end - 1) == sharpGrid)
precondition(photoPixels(20) == softEdge)
let storedFilter = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(filteredImage))
precondition(storedFilter.filters == [fadingFilter])
print("Passed per-filter easing, defocus center and edge pixels, and still-image cache behavior.")

func shapePixels(_ clip: Clip) -> (width: Int, height: Int, bytes: [UInt8]) {
  let image = artwork(clip, size: CGSize(width: 768, height: 432))!
  let canvas = bitmap(image.width, image.height)!
  canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return (image.width, image.height, Array(UnsafeBufferPointer(
    start: canvas.data!.assumingMemoryBound(to: UInt8.self), count: canvas.bytesPerRow * canvas.height)))
}
func centerAlpha(_ clip: Clip) -> UInt8 {
  let (w, h, pixels) = shapePixels(clip)
  return pixels[(h / 2 * w + w / 2) * 4 + 3]
}
func coveredPixels(_ clip: Clip) -> Int {
  let (_, _, pixels) = shapePixels(clip)
  return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 180 }.count
}
for kind in [Kind.rectangle, .ellipse] {
  var shape = Clip.annotation(kind, at: 0)
  precondition(centerAlpha(shape) == 0)
  shape.shapeAppearance = nil
  precondition(centerAlpha(shape) == 0)
  shape.reliefStyle = .chrome
  precondition(centerAlpha(shape) == 255, "Legacy 3D shapes stay filled")
  shape.shapeAppearance = ShapeAppearance(fill: .hollow, outlineWidth: 14)
  precondition(centerAlpha(shape) == 0 && coveredPixels(shape) > 0)
  shape.shapeAppearance?.edge = .rough
  precondition(centerAlpha(shape) == 0, "Rough 3D outlines remain hollow")
  shape.reliefStyle = nil
  let thin = coveredPixels(shape)
  shape.shapeAppearance?.outlineWidth = 34
  precondition(coveredPixels(shape) > thin)
  let texturedOutline = shapePixels(shape).bytes
  shape.shapeAppearance?.edge = .smooth
  precondition(shapePixels(shape).bytes != texturedOutline)
  shape.shapeAppearance = ShapeAppearance(fill: .solid, edge: .rough, roughness: 0.90)
  precondition(centerAlpha(shape) == 255)
  let texturedFill = shapePixels(shape).bytes
  precondition(shapePixels(shape).bytes == texturedFill, "Rough shape edges must be stable")
  shape.shapeAppearance?.roughness = 0
  precondition(shapePixels(shape).bytes != texturedFill)
  let savedShape = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(shape))
  precondition(savedShape == shape)
  var otherShape = Clip.annotation(kind == .ellipse ? .rectangle : .ellipse, at: 60)
  otherShape.applyProperties(from: shape)
  precondition(otherShape.shapeAppearance == shape.shapeAppearance && centerAlpha(otherShape) == 255)
}
print("Passed hollow and solid shapes, adjustable rough edges, 3D outlines, and appearance persistence.")

let csv = try ChartCSV(name: "含引号.csv", text: "\u{feff}分类,横轴,数值\r\n\"甲,\"\"乙\"\"\",10,25%\r\n\"第二\n行\",20,-5\r\n丙,abc,9\r\n丁,40,NaN")
precondition(csv.columns(header: true) == ["分类", "横轴", "数值"])
let pieRows = csv.points(for: .pie, header: true, x: 0, y: 2)
let scatterRows = csv.points(for: .scatter, header: true, x: 1, y: 2)
precondition(pieRows.points.map(\.y) == [0.25, 9] && pieRows.points[0].label == "甲,\"乙\"" && pieRows.skipped == 2)
precondition(scatterRows.points.map(\.x) == [10, 20] && scatterRows.points.map(\.y) == [0.25, -5])
precondition(csv.rows[2][0] == "第二\n行")
precondition((try? ChartCSV(name: "bad.csv", text: "x,y\n\"unclosed,1")) == nil)
let semicolonCSV = try ChartCSV(name: "semicolon.csv", text: "Type;Value\r\nA;3\r\nB;7")
let tabCSV = try ChartCSV(name: "tab.tsv", text: "A\t3\nB\t7")
precondition(semicolonCSV.points(for: .bar, header: true, x: 0, y: 1).points.map(\.y) == [3, 7])
precondition(tabCSV.points(for: .line, header: false, x: 0, y: 1).points.map(\.label) == ["A", "B"])

let graphicsSize = CGSize(width: 640, height: 360)
func graphicsPixels(_ clip: Clip, frame: Int, painter: FramePainter) -> [UInt8] {
  let g = bitmap(Int(graphicsSize.width), Int(graphicsSize.height))!
  painter.paint(g, frame: frame, active: [clip]) { _ in nil }
  return Array(UnsafeBufferPointer(
    start: g.data!.assumingMemoryBound(to: UInt8.self), count: g.bytesPerRow * g.height))
}
var renderedCharts = [[UInt8]]()
var fixture = Project()
for kind in ChartKind.allCases {
  var chart = Clip.annotation(.chart, at: fixture.clips.count * 30)
  chart.length = 30
  let data = csv.points(for: kind, header: true, x: kind == .scatter ? 1 : 0, y: 2)
  let subtitle = kind == .scatter ? "Samples" : "Category"
  chart.chart = ChartSpec(kind: kind, title: kind.title, xTitle: subtitle, yTitle: "Value",
                         points: data.points, entryFrames: 16)
  if kind == .pie {
    chart.chart?.points = [ChartPoint(label: "All", y: 1)]
  }
  fixture.clips.append(chart)
  let painter = FramePainter(fixture, graphicsSize)
  let start = graphicsPixels(chart, frame: chart.start, painter: painter)
  let middle = graphicsPixels(chart, frame: chart.start + 8, painter: painter)
  let finished = graphicsPixels(chart, frame: chart.start + 16, painter: painter)
  precondition(start != middle && middle != finished && start != finished, kind.rawValue)
  precondition(finished == graphicsPixels(chart, frame: chart.end - 1, painter: painter))
  precondition(!renderedCharts.contains(finished))
  renderedCharts.append(finished)
}
let scorePoints: [ChartPoint] = [-100.0, 0, 20, 20, 70].map { ChartPoint(label: String($0), y: $0) }
let ranked = ChartPalette(scorePoints, mode: .rank, high: "#F5CB66", low: "#4431C4")
let absolute = ChartPalette(scorePoints, mode: .magnitude, high: "#F5CB66", low: "#4431C4")
precondition(ranked.slots == [0, 11, 21, 21, 32])
precondition(absolute.slots == [32, 0, 6, 6, 22])
var styled = fixture.clips[1]
styled.chart?.points = scorePoints
styled.chartAppearance = ChartAppearance(theme: .light, font: "Courier", fontScale: 1.1, showsValues: true,
                                         colorMode: .rank, lowColor: "#4431C4", markSize: 1.2)
styled.color = "#C85636"
let stylePainter = FramePainter(Project(), graphicsSize)
let rankingPixels = graphicsPixels(styled, frame: styled.end - 1, painter: stylePainter)
styled.chartAppearance?.colorMode = .magnitude
let absolutePixels = graphicsPixels(styled, frame: styled.end - 1, painter: stylePainter)
precondition(rankingPixels != absolutePixels)
fixture.clips[1] = styled
styled.chartAppearance?.showsValues = false
let noValues = graphicsPixels(styled, frame: styled.end - 1, painter: stylePainter)
precondition(noValues != absolutePixels)
styled.chartAppearance?.showsLabels = false
styled.chartAppearance?.showsGrid = false
styled.chartAppearance?.showsTitle = false
styled.chartAppearance?.theme = .transparent
let noLabels = graphicsPixels(styled, frame: styled.end - 1, painter: stylePainter)
precondition(noLabels != noValues)
var ringChart = fixture.clips[0]
ringChart.chartAppearance = ChartAppearance(pieHole: 0.52)
precondition(graphicsPixels(ringChart, frame: ringChart.end - 1, painter: stylePainter) != renderedCharts[0])
fixture.clips[0] = ringChart
var otherChart = fixture.clips[2]
let otherData = otherChart.chart?.points
otherChart.applyProperties(from: styled)
precondition(otherChart.chart?.points == otherData && otherChart.chartAppearance == styled.chartAppearance)
var splitTitle = Clip.annotation(.text, at: 120)
splitTitle.length = 30
splitTitle.text = "MMM"
splitTitle.w = 0.90
splitTitle.h = 0.45
splitTitle.textAppearance = TextAppearance(size: 180, fixedSize: true, shadow: TextShadow(enabled: false),
                                           duotone: TextDuotone(firstColor: "#FF8000"))
let splitColors = FramePainter(Project(), graphicsSize)
func colorCount(_ bytes: [UInt8], red: UInt8, green: UInt8, blue: UInt8, inHalf: Int? = nil) -> Int {
  stride(from: 0, to: bytes.count, by: 4).filter { i in
    let half = i / 4 / Int(graphicsSize.width) < Int(graphicsSize.height) / 2 ? 0 : 1
    return (inHalf == nil || inHalf == half) && bytes[i] == blue && bytes[i+1] == green && bytes[i+2] == red
  }.count
}
let upperOrange = graphicsPixels(splitTitle, frame: splitTitle.start, painter: splitColors)
precondition(colorCount(upperOrange, red: 255, green: 128, blue: 0, inHalf: 0) > 50)
precondition(colorCount(upperOrange, red: 255, green: 255, blue: 255, inHalf: 1) > 50)
splitTitle.textAppearance?.duotone?.angle = 90
precondition(graphicsPixels(splitTitle, frame: splitTitle.start, painter: splitColors) != upperOrange)
splitTitle.textAppearance?.duotone?.position = 0
let allWhite = graphicsPixels(splitTitle, frame: splitTitle.start, painter: splitColors)
precondition(colorCount(allWhite, red: 255, green: 128, blue: 0) == 0)
splitTitle.textAppearance?.duotone?.position = 1
let allOrange = graphicsPixels(splitTitle, frame: splitTitle.start, painter: splitColors)
precondition(colorCount(allOrange, red: 255, green: 128, blue: 0) > 50)
splitTitle.textAppearance?.duotone?.position = 0.50
splitTitle.textAppearance?.duotone?.angle = 0
splitTitle.textAppearance?.fixedSize = false
splitTitle.textAnimation = TextAnimation(characters: true, entryFrames: 12, exitFrames: 0)
let letters = graphicsPixels(splitTitle, frame: splitTitle.start + 8, painter: splitColors)
precondition(colorCount(letters, red: 255, green: 128, blue: 0) > 50)
precondition(colorCount(letters, red: 255, green: 255, blue: 255) > 50)
let staticWrapped = shapePixels(splitTitle).bytes
precondition(colorCount(staticWrapped, red: 255, green: 128, blue: 0) > 50)
fixture.clips.append(splitTitle)
let chartRoundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(fixture)).checked()
precondition(chartRoundTrip.clips == fixture.clips && chartRoundTrip.assets.isEmpty)
if let path = ProcessInfo.processInfo.environment["MAOMI_CHART_QA_FIXTURE"] {
  try fixture.write(to: URL(fileURLWithPath: path))
}
print("Passed CSV parsing, chart animations, styling and value-based coloring, two-tone text, and portable project storage.")

let fontMenu = NSPopUpButton(frame: .zero, pullsDown: false)
let fontMenuCoordinator = MenuField.Coordinator()
var fontListLoads = 0
var pickedFont: Int?
fontMenuCoordinator.loadChoices = {
  fontListLoads += 1
  return ["System", "Courier"]
}
fontMenuCoordinator.currentTitle = "Courier"
fontMenuCoordinator.select = { pickedFont = $0 }
fontMenuCoordinator.setTitles(["Courier"], on: fontMenu)
precondition(fontListLoads == 0 && fontMenu.titleOfSelectedItem == "Courier")
let willShowFonts = Notification(name: NSPopUpButton.willPopUpNotification, object: fontMenu)
fontMenuCoordinator.willPopUp(willShowFonts)
fontMenuCoordinator.willPopUp(willShowFonts)
precondition(fontListLoads == 1 && fontMenu.indexOfSelectedItem == 1)
fontMenu.selectItem(at: 0)
fontMenuCoordinator.picked(fontMenu)
precondition(pickedFont == 0)
print("Passed lazy chart font menu initialization, selection, and reuse.")

let editedChart = try fixture.clips[1].chart!.replacingData(
  from: "分类,数据\n\"深圳, 上海\",32\n华北,-8")
precondition(editedChart.points.map(\.label) == ["深圳, 上海", "华北"])
precondition(editedChart.points.map(\.y) == [32, -8] && editedChart.yTitle == "数据")
let blankHeaders = fixture.clips[0].chart!
var blankChart = blankHeaders
blankChart.xTitle = ""
blankChart.yTitle = ""
let reloadedChart = try blankChart.replacingData(from: blankChart.editableCSV)
precondition(reloadedChart == blankChart)
precondition((try? blankChart.replacingData(from: "X,Y\n甲,4\n乙,-3")) == nil)
let editedScatter = try fixture.clips[3].chart!.replacingData(from: "X,Y\n-7,8\n120,-4")
precondition(editedScatter.points.compactMap(\.x) == [-7, 120])
let editSource = ChartSpec(kind: .line, title: "营收", xTitle: "地区", yTitle: "亿元", points: [
  ChartPoint(label: "华北", y: 100), ChartPoint(label: "华南", y: 200),
], entryFrames: 12, marker: ChartMarker(row: 1, title: "关键节点"))
let headlessEdit = try editSource.replacingData(from: "华北,150\n华南,210", header: false)
precondition(headlessEdit.points.map(\.label) == ["华北", "华南"])
precondition(headlessEdit.xTitle == "地区" && headlessEdit.yTitle == "亿元")
let reorderedEdit = try editSource.replacingData(from: "华南,210\n华北,150", header: false)
precondition(reorderedEdit.marker == ChartMarker(row: 0, title: "关键节点"))
let deletedPoint = try editSource.replacingData(from: "华北,150\n华西,250", header: false)
precondition(deletedPoint.marker == nil)
let ambiguousPoint = try editSource.replacingData(from: "华南,210\n华南,250", header: false)
precondition(ambiguousPoint.marker == nil)
let quotedEdit = try editSource.replacingData(from: "\"东部, \"\"海外\"\"\n业务\",123", header: false)
precondition(quotedEdit.points[0].label == "东部, \"海外\"\n业务")
let blankLabelEdit = try editSource.replacingData(from: ",150\n华南,210", header: false)
precondition(blankLabelEdit.points[0].label.isEmpty)
precondition((try? editSource.replacingData(from: "东部,海外,150", header: false)) == nil)
precondition((try? editSource.replacingData(from: "地区,金额\n华北,150", header: false)) == nil)
let labeledScatter = ChartSpec(kind: .scatter, title: "广告效果", xTitle: "预算", yTitle: "转化",
                              points: [ChartPoint(label: "基准,测试", x: 3, y: 7)], marker: ChartMarker(row: 0))
let scatterRoundTrip = try labeledScatter.replacingData(from: labeledScatter.editableRows, header: false)
precondition(scatterRoundTrip == labeledScatter)
let movedPoint = try labeledScatter.replacingData(from: "4,8,\"基准,测试\"", header: false)
precondition(movedPoint.points[0].label == "基准,测试" && movedPoint.marker?.row == 0)
let panelMarker = editSource.updatingData(with: ChartSpec(kind: .line, title: "新标题", points: reorderedEdit.points))
precondition(panelMarker.marker == reorderedEdit.marker && panelMarker.entryFrames == editSource.entryFrames)
print("Passed headerless data editing, separate axis titles, scatter labels, quoted labels, and marker remapping.")

var moving = Clip(kind: .video, start: 10, length: 90)
moving.motion = .shake
let sampleFrame = moving.start + 2
let baseShake = moving.motionOffset(at: sampleFrame, size: graphicsSize)
moving.shakeAmplitude = 0.036
let stronger = moving.motionOffset(at: sampleFrame, size: graphicsSize)
precondition(abs(stronger.x - baseShake.x * 2) < 1e-9 && abs(stronger.y - baseShake.y * 2) < 1e-9)
moving.shakeFrequency = 3
precondition(moving.motionOffset(at: sampleFrame, size: graphicsSize) != stronger)
moving.shakeAmplitude = 0
precondition(moving.motionOffset(at: sampleFrame, size: graphicsSize) == .zero)

moving.motion = .pullOut
moving.motionZoom = 1.4
let display = graphicsSize.width / graphicsSize.height
func assertCovered(_ clip: Clip, _ geometry: VisualGeometry, at frame: Int) {
  let placement = clip.placement(at: frame, canvas: graphicsSize, geometry: geometry)
  precondition(placement.anchorsToCanvas)
  let corners = [CGPoint.zero, CGPoint(x: graphicsSize.width, y: 0),
    CGPoint(x: 0, y: graphicsSize.height), CGPoint(x: graphicsSize.width, y: graphicsSize.height)]
  for p in corners {
    let local = CGPoint(x: (p.x - placement.center.x) / placement.scale,
                        y: (p.y - placement.center.y) / placement.scale)
      .applying(CGAffineTransform(rotationAngle: -clip.angle * .pi / 180))
    precondition(geometry.visible.insetBy(dx: -1e-7, dy: -1e-7).contains(local))
  }
}
let fitting = VisualGeometry(clip: moving, canvas: graphicsSize, aspect: display)
precondition(abs(moving.placement(at: moving.start, canvas: graphicsSize, geometry: fitting).scale - 1.4) < 1e-9)
precondition(moving.placement(at: moving.end - 1, canvas: graphicsSize, geometry: fitting).scale == 1)
for f in moving.start..<moving.end { assertCovered(moving, fitting, at: f) }
moving.visualScale = 3.8
moving.angle = 33
moving.x = 0.68
moving.y = 0.35
moving.sourceCrop = SourceCrop(left: 0.11, top: 0.1, right: 0.07, bottom: 0.13)
let rotated = VisualGeometry(clip: moving, canvas: graphicsSize, aspect: display)
for f in moving.start..<moving.end { assertCovered(moving, rotated, at: f) }
precondition(moving.placement(at: moving.end - 1, canvas: graphicsSize, geometry: rotated).scale < 1)
let animatedGeometry = moving
moving.motionContinuous = true
let loopStart = moving.placement(at: moving.start, canvas: graphicsSize, geometry: rotated)
let loopReturn = moving.placement(at: moving.start + moving.motionFrames, canvas: graphicsSize, geometry: rotated)
precondition(abs(loopStart.scale - loopReturn.scale) < 1e-9)
let small = VisualGeometry(clip: Clip(kind: .video, start: 0, length: 90, visualScale: 0.4),
                          canvas: graphicsSize, aspect: display)
precondition(!moving.placement(at: moving.start, canvas: graphicsSize, geometry: small).anchorsToCanvas)
moving.motion = .pushIn
moving.motionContinuous = false
precondition(moving.placement(at: moving.start, canvas: graphicsSize).scale == 1)
precondition(abs(moving.placement(at: moving.end - 1, canvas: graphicsSize).scale - 1.4) < 1e-9)
let persistedMotion = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(animatedGeometry))
precondition(persistedMotion == animatedGeometry)
print("Passed chart data editor round trips, configurable shake, zoom endpoints, and crop/rotation edge coverage.")

let hostAsset = Media(path: "/host.mov", frames: 240, video: true, audio: true)
let backdropAsset = Media(path: "/backdrop.mov", frames: 240, video: true, audio: false)
let host = Clip(kind: .video, asset: hostAsset.id, start: 0, length: 120)
let backdropClip = Clip(kind: .video, asset: backdropAsset.id, start: 24, length: 60)
var quickProject = Project()
quickProject.assets = [hostAsset, backdropAsset]
quickProject.clips = [host, backdropClip]
let overlayID = quickProject.applyPictureInset(to: host.id, over: backdropClip.id)!
let hostPieces = quickProject.clips.filter { $0.asset == hostAsset.id }
precondition(quickProject.duration == 120 && hostPieces.map(\.length) == [24, 60, 36])
precondition(hostPieces.map(\.sourceIn) == [0, 24, 84] && hostPieces.allSatisfy { $0.volume == host.volume })
precondition(hostPieces.filter { $0.pictureInset != nil }.map(\.id) == [overlayID])
let insetClip = hostPieces[1]
precondition(quickProject.timelineTracks(joins: quickProject.joins)[1].clips.map(\.id) == [overlayID])
precondition(quickProject.joins.allSatisfy { $0.before.id != overlayID && $0.after.id != overlayID })
var restoredInset = insetClip
restoredInset.removePictureInset()
precondition(restoredInset.x == host.x && restoredInset.y == host.y && restoredInset.visualBorder == host.visualBorder)
let circleGeometry = VisualGeometry(clip: insetClip, canvas: graphicsSize, aspect: display)
precondition(circleGeometry.visible.width == circleGeometry.visible.height)
precondition(circleGeometry.full.width > circleGeometry.visible.width)

func solidShot(_ color: String) -> CGImage {
  let g = bitmap(640, 360)!
  g.setFillColor(ink(color))
  g.fill(CGRect(origin: .zero, size: graphicsSize))
  return g.makeImage()!
}
let faceShot = solidShot("#CE5C6C")
let sceneShot = solidShot("#18384A")
func quickFrame(_ project: Project, active: [Clip], at frame: Int, size: CGSize = graphicsSize) -> CGContext {
  let g = bitmap(Int(size.width), Int(size.height))!
  FramePainter(project, size).paint(g, frame: frame, active: active) { id in
    if id == backdropClip.id { return Picture(image: sceneShot) }
    return id == insetClip.id ? Picture(image: faceShot) : nil
  }
  return g
}
func quickPixel(_ g: CGContext, x: Int, y: Int) -> [UInt8] {
  let bytes = g.data!.assumingMemoryBound(to: UInt8.self)
  let i = y * g.bytesPerRow + 4 * x
  return [bytes[i + 2], bytes[i + 1], bytes[i]]
}
let pathStroke = [
  CGPoint(x: 96, y: 96), CGPoint(x: 100, y: 96), CGPoint(x: 106, y: 96),
  CGPoint(x: 140, y: 99), CGPoint(x: 265, y: 134), CGPoint(x: 364, y: 175),
  CGPoint(x: 433, y: 253), CGPoint(x: 544, y: 270),
]
let route = MotionPath(stroke: pathStroke, in: graphicsSize)!
precondition(route.valid && route.at(0) == .zero && route.at(1) == CGPoint(x: 0.7, y: 174.0 / 360))
precondition(MotionPath(stroke: Array(repeating: .zero, count: 20), in: graphicsSize) == nil)
let linePath = MotionPath(stroke: [CGPoint(x: 11, y: 5), CGPoint(x: 15, y: 5),
                                   CGPoint(x: 16, y: 5), CGPoint(x: 511, y: 5)], in: graphicsSize)!
precondition(abs(linePath.at(0.5).x - 250.0 / 640) < 1e-9)
let loopPath = MotionPath(stroke: [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), .zero],
                          in: graphicsSize)!
precondition(loopPath.at(0) == loopPath.at(1) && loopPath.at(0.5) != .zero)

var pathClip = Clip.annotation(.rectangle, at: 0)
pathClip.color = "#FAD271"
pathClip.shapeAppearance = ShapeAppearance(fill: .solid)
pathClip.w = 0.11
pathClip.h = 0.13
pathClip.length = 61
pathClip.x = 96.0 / 640
pathClip.y = 96.0 / 360
pathClip.motion = .path
pathClip.motionPath = route
var pathProject = Project()
pathProject.clips = [pathClip]
let movingFrames = [0, 15, 30, 45, 60]
for frame in movingFrames {
  let position = pathClip.placement(at: frame, canvas: graphicsSize).center
  let output = quickFrame(pathProject, active: [pathClip], at: frame)
  precondition(quickPixel(output, x: Int(position.x), y: Int(position.y)) == [250, 210, 113])
  let portrait = pathClip.placement(at: frame, canvas: CGSize(width: 360, height: 640)).center
  precondition(abs(position.x / 640 - portrait.x / 360) < 1e-9)
  precondition(abs(position.y / 360 - portrait.y / 640) < 1e-9)
}
var copiedRoute = backdropClip
copiedRoute.start = 0
copiedRoute.length = 61
copiedRoute.visualScale = 0.2
copiedRoute.applyProperties(from: pathClip)
let videoAtEnd = quickFrame(pathProject, active: [copiedRoute], at: 60)
precondition(copiedRoute.motionPath == pathClip.motionPath)
let videoCenter = copiedRoute.placement(at: 60, canvas: graphicsSize).center
precondition(hypot(videoCenter.x - 544, videoCenter.y - 270) < 1e-9)
precondition(quickPixel(videoAtEnd, x: 544, y: 270) == [24, 56, 74])
precondition(quickPixel(videoAtEnd, x: 96, y: 96) == [0, 0, 0])
var cutPathProject = pathProject
precondition(cutPathProject.cut(pathClip.id, at: 29) != nil)
for frame in 0..<pathClip.length {
  let piece = cutPathProject.clips.first { ($0.start..<$0.end).contains(frame) }!
  let original = pathClip.placement(at: frame, canvas: graphicsSize).center
  let sliced = piece.placement(at: frame, canvas: graphicsSize).center
  precondition(hypot(sliced.x - original.x, sliced.y - original.y) < 1e-9)
}
let restoredPath = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(cutPathProject)).checked()
precondition(restoredPath == cutPathProject)
if let folder = ProcessInfo.processInfo.environment["MAOMI_PATH_QA"] {
  let directory = URL(fileURLWithPath: folder)
  try pathProject.write(to: directory.appendingPathComponent("MotionPath.framecut"))
  var drawProject = pathProject
  drawProject.clips[0].motion = .none
  drawProject.clips[0].motionPath = nil
  try drawProject.write(to: directory.appendingPathComponent("DrawPath.framecut"))
}
print("Passed freehand paths, endpoint and loop handling, constant speed, frame pixels, property copies, split continuity and project round trip.")

let pipFrame = quickFrame(quickProject, active: [insetClip, backdropClip], at: 40)
let px = Int(insetClip.x * graphicsSize.width)
let py = Int(insetClip.y * graphicsSize.height)
precondition(quickPixel(pipFrame, x: px, y: py) == [206, 92, 108])
precondition(quickPixel(pipFrame, x: px + 36, y: py - 36) == [24, 56, 74])
precondition(quickPixel(pipFrame, x: 400, y: 180) == [24, 56, 74])

let signedSeries = [-7.0, 0, 4, -2, 8].enumerated().map { ChartPoint(label: String($0.offset), y: $0.element) }
let signPalette = ChartPalette(signedSeries, mode: .sign, high: "#85AEFF", low: "#F18CA7")
precondition(signPalette.slots == [1, 0, 0, 1, 0])
var dataStory = Clip.annotation(.chart, at: 0)
dataStory.chart = ChartSpec(kind: .line, title: "Key inflection", points: signedSeries)
let plainPlot = graphicsPixels(dataStory, frame: 30, painter: FramePainter(Project(), graphicsSize))
dataStory.applyDataStoryStyle()
dataStory.chart?.marker = ChartMarker(row: 4, title: "Release")
precondition(dataStory.chart?.points == signedSeries && dataStory.chartAppearance?.areaFill == true)
precondition(plainPlot != graphicsPixels(dataStory, frame: 30, painter: FramePainter(Project(), graphicsSize)))
let revisedPlot = try dataStory.chart!.replacingData(from: "Date,Value\nDay 1,2")
precondition(revisedPlot.marker == nil && revisedPlot.valid)

var quickGraphics = Project()
let backdropPixel: [UInt8] = [24, 56, 74]
var renderedStill = [CGImage]()
for (index, template) in EditorialStyle.allCases.enumerated() {
  var clip = template.clip(at: index * 120)
  clip.editorial?.subtitle = "An editable subtitle"
  if template == .metric {
    clip.editorial?.value = 72.5
    clip.editorial?.decimals = 1
    precondition(clip.editorial?.number(0) == "0.0%" && clip.editorial?.number(1) == "72.5%")
  }
  let first = quickFrame(quickGraphics, active: [backdropClip, clip], at: clip.start)
  let rest = quickFrame(quickGraphics, active: [backdropClip, clip], at: clip.start + 35)
  precondition(quickPixel(first, x: 20, y: 20) == backdropPixel)
  precondition(quickPixel(rest, x: 20, y: 20) != backdropPixel)
  renderedStill.append(rest.makeImage()!)
  quickGraphics.clips.append(clip)
}
dataStory.start = 360
quickGraphics.clips.append(dataStory)
let reopenedQuick = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(quickGraphics)).checked()
precondition(reopenedQuick == quickGraphics)
let reopenedInset = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(quickProject)).checked()
precondition(quickProject == reopenedInset)
let cardCopy = "续约率提升，订阅和服务收入都在增长。\nProfit margins also improved."
let paragraph = EditorialParagraph(cardCopy, font: .systemFont(ofSize: 16), color: ink("#FFFFFF"),
                                   width: 171, maxLines: 8)
precondition(paragraph.lines.count >= 4 && !paragraph.truncated)
precondition(paragraph.lines.allSatisfy { CTLineGetTypographicBounds($0, nil, nil, nil) <= 173 })
let hardBreak = EditorialParagraph("First\r\nSecond", font: .systemFont(ofSize: 16), color: ink("#FFFFFF"),
                                   width: 220, maxLines: 2)
precondition(hardBreak.lines.count == 2 && !hardBreak.truncated)
let overflow = EditorialParagraph("First\nSecond\nThird", font: .systemFont(ofSize: 16), color: ink("#FFFFFF"),
                                  width: 172, maxLines: 2)
precondition(overflow.truncated && CTLineGetGlyphCount(overflow.lines[1]) > 1)

var richCards = quickGraphics.clips[2]
richCards.text = "一季度经营指标"
richCards.editorial?.cardsAppearance = EditorialCardsAppearance(featured: 1, stagger: 0.3, reverse: true)
richCards.editorial?.cards[0] = EditorialCard(title: "订阅收入", detail: cardCopy, icon: .trend)
richCards.editorial?.cards[1] = EditorialCard(title: "经营利润", detail: "毛利改善 4 个百分点。\n销售费用继续回落。",
                                             icon: EditorialCardIcon.none, background: "#F6DDC8", accent: "#9F342A")
richCards.editorial?.cards[2] = EditorialCard(title: "下季看点", detail: "新市场进入验证期。\n留意服务上线节奏。",
                                             icon: .target)
let cardPicture = NSBitmapImageRep(cgImage: sceneShot).representation(using: .png, properties: [:])!
richCards.editorial?.cards[2].picture = cardPicture
precondition(EditorialCardImages.photo(cardPicture)?.width == 640)
precondition(EditorialCardImages.symbol("target", tint: "#F4AEBB") != nil)
var blankCards = richCards
blankCards.editorial?.cards[0].detail = ""
for size in [graphicsSize, CGSize(width: 360, height: 640)] {
  let actual = quickFrame(quickGraphics, active: [richCards], at: 285, size: size).makeImage()!
  let blank = quickFrame(quickGraphics, active: [blankCards], at: 285, size: size).makeImage()!
  precondition(actual.dataProvider!.data as Data? != blank.dataProvider!.data as Data?)
}

var richMetric = quickGraphics.clips[1]
richMetric.text = "净增用户"
richMetric.editorial?.subtitle = "年度汇总"
richMetric.editorial?.metricAppearance = EditorialMetricAppearance(
  start: 1_750, counting: .linear, groupsDigits: true, showsPlus: true, font: "Avenir Next", unitSize: 0.55)
richMetric.editorial?.suffix = " 万人"
richMetric.editorial?.decimals = 1
richMetric.editorial?.value = -750
richMetric.editorial?.exitFrames = 18
let resolvedMetric = richMetric.editorial!
precondition(resolvedMetric.number(0) == "+1,750.0 万人")
precondition(resolvedMetric.number(0.5) == "+500.0 万人")
precondition(resolvedMetric.number(1) == "-750.0 万人")
precondition(resolvedMetric.exitOpacity(frame: richMetric.end - 1, clip: richMetric) == 0)
precondition(resolvedMetric.exitOpacity(frame: richMetric.end - 10, clip: richMetric) == 0.5)
let metricExit = quickFrame(quickGraphics, active: [backdropClip, richMetric], at: richMetric.end - 1)
precondition(quickPixel(metricExit, x: 20, y: 20) == backdropPixel)
var shortMetric = richMetric
shortMetric.length = 4
precondition(resolvedMetric.progress(frame: shortMetric.end - 2, clip: shortMetric) == 1)
precondition(resolvedMetric.exitOpacity(frame: shortMetric.end - 2, clip: shortMetric) == 1)

var editorialProject = quickGraphics
editorialProject.clips[1] = richMetric
editorialProject.clips[2] = richCards
let reopenedEditorial = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editorialProject)).checked()
precondition(reopenedEditorial == editorialProject)
print("Passed multilingual card wrapping, paragraph breaks, photos, portrait and landscape composition, counter formats and exit timing.")

var revealClip = EditorialStyle.metric.clip(at: 0)
revealClip.text = "数据中心收入占比"
revealClip.editorial?.subtitle = "2026 Q3"
revealClip.length = 60
var revealStyle = MetricReveal(clipLength: revealClip.length)
revealStyle.mode = .comparison
revealStyle.offsetFrames = 18
revealStyle.durationFrames = 6
revealClip.editorial?.metricReveal = revealStyle
revealClip.editorial?.metricAppearance = EditorialMetricAppearance(start: 38, counting: .linear, unitSize: 0.57)
let revealSpec = revealClip.editorial!
let waiting = revealSpec.progress(frame: 17, clip: revealClip)
let onset = revealSpec.progress(frame: 18, clip: revealClip)
let midway = revealSpec.progress(frame: 20, clip: revealClip)
let settled = revealSpec.progress(frame: 23, clip: revealClip)
precondition(waiting == 0 && onset > 0 && midway == 0.5 && settled == 1)
precondition(revealSpec.number(waiting) == "38%" && revealSpec.number(onset) == "40%")
precondition(revealSpec.number(midway) == "44%" && revealSpec.number(settled) == "50%")
let rising = revealStyle.bar(from: 38, to: 50, showing: revealSpec.metricValue(midway))
precondition(rising.accent == 0.38...0.44)
let falling = revealStyle.bar(from: 50, to: 38, showing: 44)
precondition(falling.accent == 0.44...0.50)
let signed = revealStyle.bar(from: 35, to: -125, showing: -45)
precondition(signed.lower == -125 && signed.upper == 125 && signed.zero == 0.5 && signed.accent == 0.32...0.64)

var shareClip = revealClip
shareClip.editorial?.metricReveal?.mode = .share
let shareSpec = shareClip.editorial!
precondition(shareSpec.metricStart == 0 && shareSpec.number(midway) == "25%")
var instant = revealStyle
instant.durationFrames = 0
precondition(instant.progress(at: 17) == 0 && instant.progress(at: 18) == 1)

var revealProject = Project()
revealProject.clips = [revealClip]
let revealPainter = FramePainter(revealProject, graphicsSize)
func revealFrame(_ frame: Int) -> CGContext {
  let g = bitmap(Int(graphicsSize.width), Int(graphicsSize.height))!
  revealPainter.paint(g, frame: frame, active: [revealClip]) { _ in nil }
  return g
}
let mutedBaseline: [UInt8] = [104, 119, 137], mutedTrack: [UInt8] = [53, 65, 81], bright: [UInt8] = [189, 232, 209]
for frame in [17, 20, 23, 17] {
  let image = revealFrame(frame)
  precondition(quickPixel(image, x: 150, y: 208) == mutedBaseline)
  precondition(quickPixel(image, x: 280, y: 208) == (frame >= 20 ? bright : mutedTrack))
  precondition(quickPixel(image, x: 312, y: 208) == (frame >= 23 ? bright : mutedTrack))
  precondition(quickPixel(image, x: 370, y: 208) == mutedTrack)
}

var slicedReveals = revealProject
precondition(slicedReveals.cut(revealClip.id, at: 20) != nil)
for frame in 0..<revealClip.length {
  let piece = slicedReveals.clips.first { ($0.start..<$0.end).contains(frame) }!
  precondition(revealSpec.progress(frame: frame, clip: revealClip) == piece.editorial?.progress(frame: frame, clip: piece))
}
var metricSwitch = Project()
let classic = quickGraphics.clips[1]
metricSwitch.clips = [classic]
precondition(metricSwitch.useQuickMetricStyle(reveal: true, selected: classic.id, at: classic.start + 23) == classic.id)
precondition(metricSwitch.clips.count == 1 && metricSwitch.clips[0].start == classic.start)
precondition(metricSwitch.clips[0].text == classic.text && metricSwitch.clips[0].editorial?.value == classic.editorial?.value)
metricSwitch.clips[0].editorial?.metricReveal?.offsetFrames = 23
precondition(metricSwitch.useQuickMetricStyle(reveal: false, selected: nil, at: classic.start + 23) == classic.id)
precondition(metricSwitch.clips[0].editorial?.activeMetricReveal == nil)
precondition(metricSwitch.useQuickMetricStyle(reveal: true, selected: nil, at: classic.start + 23) == classic.id)
precondition(metricSwitch.clips.count == 1 && metricSwitch.clips[0].editorial?.activeMetricReveal?.offsetFrames == 23)
let earlier = metricSwitch.useQuickMetricStyle(reveal: true, selected: nil, at: classic.start - 8)
precondition(earlier != classic.id && metricSwitch.clips.last?.end == classic.start)

let reopenedReveal = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(slicedReveals)).checked()
precondition(reopenedReveal == slicedReveals && reopenedQuick.clips[1].editorial?.activeMetricReveal == nil)
print("Passed reveal cue, instant switch, shared counting, signed comparisons, accent pixels, clip splits and project round trip.")

if let path = ProcessInfo.processInfo.environment["MAOMI_QUICK_QA"] {
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try quickGraphics.write(to: folder.appendingPathComponent("QuickEdit.framecut"))
  try editorialProject.write(to: folder.appendingPathComponent("Editorial.framecut"))
  try revealProject.write(to: folder.appendingPathComponent("NumberReveal.framecut"))
  let revealShots = [
    ("reveal-before", revealClip, 17, graphicsSize),
    ("reveal-comparison", revealClip, 23, graphicsSize),
    ("reveal-portrait", shareClip, 23, CGSize(width: 360, height: 640)),
  ]
  for (name, clip, frame, size) in revealShots {
    let image = quickFrame(revealProject, active: [clip], at: frame, size: size).makeImage()!
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
      .write(to: folder.appendingPathComponent(name + ".png"))
  }

  let editorialShots = [
    ("editorial-wide", richCards, graphicsSize),
    ("editorial-portrait", richCards, CGSize(width: 360, height: 640)),
    ("editorial-counter", richMetric, graphicsSize),
  ]
  for (name, clip, size) in editorialShots {
    let image = quickFrame(editorialProject, active: [clip], at: clip.start + 45, size: size).makeImage()!
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
      .write(to: folder.appendingPathComponent("\(name).png"))
  }
  renderedStill.append(pipFrame.makeImage()!)
  renderedStill.append(quickFrame(quickGraphics, active: [dataStory], at: 400).makeImage()!)
  renderedStill.append(quickFrame(quickGraphics, active: [quickGraphics.clips[2]], at: 275,
                                  size: CGSize(width: 360, height: 640)).makeImage()!)
  for (index, shot) in renderedStill.enumerated() {
    try NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:])!
      .write(to: folder.appendingPathComponent("quick-\(index).png"))
  }
}
print("Passed overlap-only picture-in-picture, masks and track depth, chart styling and position markers, quick graphics and project round-trip.")

let voiceAsset = Media(path: "/voice.wav", frames: 270, video: false, audio: true)
let silentAsset = Media(path: "/silent.mov", frames: 120, video: true, audio: false)
let narration = Clip(kind: .audio, asset: voiceAsset.id, start: 21, length: 90, offset: 15)
let silentVideo = Clip(kind: .video, asset: silentAsset.id, start: 0, length: 50)
var audioProject = Project()
audioProject.assets = [voiceAsset, silentAsset]
audioProject.clips = [narration, silentVideo]
precondition(audioProject.addAudioVisualization(for: silentVideo.id, style: .area) == nil)
let visualID = audioProject.addAudioVisualization(for: narration.id, style: .area)!
let mediaRightID = audioProject.cut(narration.id, at: 51)!
let firstSound = audioProject.clips.first { $0.id == narration.id }!
let secondSound = audioProject.clips.first { $0.id == mediaRightID }!
precondition(firstSound.audioFamily == secondSound.audioFamily && secondSound.sourceIn == 45)
audioProject.clips[audioProject.clips.firstIndex(where: { $0.id == mediaRightID })!].start += 12
audioProject.syncAudioVisualizations()
let visualization = audioProject.clips.first { $0.id == visualID }!
precondition(visualization.length == 102 && visualization.start == narration.start)

let measuredWave = AudioWaveform(frames: voiceAsset.frames, peaks: (0..<voiceAsset.frames).map {
  $0 >= 45 && $0 < 61 ? 224 : ($0 >= 20 && $0 < 36 ? 40 : 0)
})
let track = AudioSignalTrack([
  AudioSignal(clip: firstSound, wave: measuredWave),
  AudioSignal(clip: audioProject.clips.first { $0.id == mediaRightID }!, wave: measuredWave),
])
let visualSettings = visualization.audioVisualization!
let lowWave = track.levels(at: 33, style: visualSettings)
let highWave = track.levels(at: 73, style: visualSettings)
precondition(lowWave.max()! > 0 && lowWave.max()! < 0.3 && highWave.max()! == 1)
precondition(highWave.last! > 0 && track.levels(at: 14, style: visualSettings).allSatisfy { $0 == 0 })
let beforeSlow = AudioSignal(clip: narration, wave: measuredWave)
var retimedNarration = narration
try retimedNarration.retime(2)
let afterFast = AudioSignal(clip: retimedNarration, wave: measuredWave)
precondition(beforeSlow.level(from: 52, to: 53) == afterFast.level(from: 36, to: 37))
retimedNarration.volume = 0
precondition(AudioSignal(clip: retimedNarration, wave: measuredWave).level(from: 36, to: 37) == 0)

let visualsPainter = FramePainter(audioProject, graphicsSize, audioSignals: [narration.id: track])
let areaPainting = graphicsPixels(visualization, frame: 73, painter: visualsPainter)
var barsVisualization = visualization
barsVisualization.audioVisualization?.style = .bars
precondition(areaPainting != graphicsPixels(barsVisualization, frame: 73, painter: visualsPainter))
precondition(areaPainting != graphicsPixels(visualization, frame: 33, painter: visualsPainter))
let audioRoundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(audioProject)).checked()
precondition(audioRoundTrip == audioProject)
let copiedTimeline = TimelineClipboard(project: audioProject, selection: [narration.id, mediaRightID, visualID])
var targetAudio = Project()
let insertedAudio = try copiedTimeline.paste(into: &targetAudio, at: 8)
let pastedSound = targetAudio.clips.filter { $0.kind == .audio }
let pastedVisual = targetAudio.clips.first { $0.kind == .audioVisual }!
precondition(insertedAudio.count == 3 && pastedSound.count == 2)
precondition(pastedSound.allSatisfy { $0.audioFamily == pastedVisual.audioVisualization?.source })
precondition(pastedVisual.audioVisualization?.source != narration.id && pastedVisual.start == 8)
targetAudio.clips.removeAll { $0.kind.isMedia }
targetAudio.syncAudioVisualizations()
precondition(targetAudio.clips[0].audioVisualization?.source == nil)
print("Passed audio-only eligibility, source offsets and speed, mute, cut and move timing, waveform styles, clipboard and persistence.")

if let root = ProcessInfo.processInfo.environment["MAOMI_AUDIO_VIS_QA"] {
  let folder = URL(fileURLWithPath: root, isDirectory: true)
  let input = try inspect(folder.appendingPathComponent("Pulse.wav"))
  let videoInput = try inspect(folder.appendingPathComponent("Pulse.mp4"))
  let silentInput = try inspect(folder.appendingPathComponent("Silent.mp4"))
  precondition(input.audio && !input.video && videoInput.audio && videoInput.video && !silentInput.audio)
  let pcm = AudioWaveform.cached(input) { false }.wave!
  let aac = AudioWaveform.cached(videoInput) { false }.wave!
  precondition(AudioWaveform.cached(input) { false }.wave === pcm)
  for source in [pcm, aac] {
    precondition(source.peak(from: 4, to: 10) < 0.03)
    precondition((0.1...0.25).contains(source.peak(from: 24, to: 39)))
    precondition(source.peak(from: 76, to: 100) > 0.6)
  }
  var realProject = Project()
  realProject.backgroundColor = "#151D2B"
  realProject.assets = [input, videoInput, silentInput]
  let audioOnly = Clip(kind: .audio, asset: input.id, start: 0, length: input.frames)
  let voiced = Clip(kind: .video, asset: videoInput.id, start: input.frames, length: videoInput.frames)
  let silent = Clip(kind: .video, asset: silentInput.id,
                    start: input.frames + videoInput.frames, length: silentInput.frames)
  realProject.clips = [audioOnly, voiced, silent]
  _ = realProject.addAudioVisualization(for: audioOnly.id, style: .area)
  _ = realProject.addAudioVisualization(for: voiced.id, style: .bars)
  precondition(realProject.addAudioVisualization(for: silent.id, style: .bars) == nil)
  let signals = audioSignals(in: realProject) { false }
  let painter = FramePainter(realProject, graphicsSize, audioSignals: signals)
  precondition(signals.count == 2)
  for (index, clip) in realProject.clips.filter({ $0.kind == .audioVisual }).enumerated() {
    let frame = clip.start + 94
    let g = bitmap(640, 360)!
    painter.paint(g, frame: frame, active: [clip]) { _ in nil }
    try NSBitmapImageRep(cgImage: g.makeImage()!).representation(using: .png, properties: [:])!
      .write(to: folder.appendingPathComponent("Visual-\(index).png"))
  }
  try realProject.write(to: folder.appendingPathComponent("Audio Visualizers.framecut"))
  print("Passed PCM and AAC decoding, silent video eligibility, decoded waveform timing and cache reuse.")
}
