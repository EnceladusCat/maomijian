import AppKit
import Foundation

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
  filtered.filterAmount = 0
  precondition(paintFixture([filtered], at: 0) == boxOnly)
}
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
