import AppKit
import Combine
import SwiftUI

/// The toolbar scene uses a handful of tiny pixel layers. Core Animation moves
/// them independently of the editor, and playback and export freeze the scene.
struct NightCityBanner: NSViewRepresentable {
  let transport: Transport
  let exporting: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> Surface { Surface(transport: transport) }

  func updateNSView(_ view: Surface, context: Context) {
    view.setMotionAllowed(!exporting && !reduceMotion)
  }

  final class Surface: NSView {
    private let skyline = CALayer()
    private let train = CALayer()
    private let cityMask = CAGradientLayer()
    private let edgeMask = CAGradientLayer()
    private var observations = Set<AnyCancellable>()
    private var windowObservations = Set<AnyCancellable>()
    private var motionAllowed = false
    private var moving = false
    private var playing = false

    init(transport: Transport) {
      super.init(frame: .zero)
      wantsLayer = true
      layer?.masksToBounds = true
      layer?.mask = edgeMask
      layer?.addSublayer(skyline)
      configureFade(edgeMask)
      configureFade(cityMask)
      skyline.mask = cityMask

      let city = NightCityArt.shared
      let background = pixelLayer(city.background, in: NightCityArt.bounds)
      skyline.addSublayer(background)
      skyline.addSublayer(train)
      train.addSublayer(pixelLayer(city.train, in: CGRect(x: 0, y: 0, width: 39, height: 5)))
      skyline.addSublayer(pixelLayer(city.foreground, in: NightCityArt.bounds))

      for (index, light) in city.lights.enumerated() {
        let bulb = pixelLayer(light.image, in: light.rect)
        skyline.addSublayer(bulb)
        let glimmer = CAKeyframeAnimation(keyPath: "opacity")
        glimmer.values = [0.22, 0.22, 0.88, 0.88, 0.22]
        glimmer.keyTimes = [0, 0.48, 0.54, 0.71, 1]
        glimmer.duration = 4.5 + Double(index) * 1.1
        glimmer.timeOffset = Double(index) * 1.7
        glimmer.repeatCount = .infinity
        glimmer.calculationMode = .discrete
        bulb.opacity = 0.40
        bulb.add(glimmer, forKey: "glimmer")
      }
      addTrainMotion()
      skyline.speed = 0

      transport.$playing.removeDuplicates().sink { [weak self] value in
        self?.playing = value
        self?.updateMotion()
      }.store(in: &observations)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      windowObservations.removeAll()
      if let window {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
          NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
            self?.updateMotion()
          }.store(in: &windowObservations)
        }
      }
      updateMotion()
    }

    override func layout() {
      super.layout()
      let size = NightCityArt.bounds.size
      let backing = window?.backingScaleFactor ?? 2
      let pixel = max(1 / backing, floor(bounds.height / size.height * backing) / backing)
      let artWidth = size.width * pixel
      let artHeight = size.height * pixel
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      skyline.anchorPoint = .zero
      skyline.bounds = NightCityArt.bounds
      skyline.position = CGPoint(
        x: ((bounds.width - artWidth) / 2 * backing).rounded(.down) / backing,
        y: ((bounds.height - artHeight) / 2 * backing).rounded(.down) / backing)
      skyline.setAffineTransform(CGAffineTransform(scaleX: pixel, y: pixel))
      cityMask.frame = NightCityArt.bounds
      edgeMask.frame = bounds
      let fade = min(0.23, 22 / max(1, bounds.width))
      edgeMask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
      CATransaction.commit()
      updateMotion()
    }

    func setMotionAllowed(_ value: Bool) {
      motionAllowed = value
      updateMotion()
    }

    private func updateMotion() {
      let run = motionAllowed && !playing && bounds.width >= 95
        && window?.isKeyWindow == true && window?.isMiniaturized == false
      guard run != moving else { return }
      moving = run
      if run {
        let pausedAt = skyline.timeOffset
        skyline.speed = 1
        skyline.timeOffset = 0
        skyline.beginTime = 0
        skyline.beginTime = skyline.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
      } else {
        skyline.timeOffset = skyline.convertTime(CACurrentMediaTime(), from: nil)
        skyline.speed = 0
      }
    }

    private func configureFade(_ gradient: CAGradientLayer) {
      gradient.startPoint = CGPoint(x: 0, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
      gradient.colors = [NSColor.clear.cgColor, NSColor.white.cgColor,
                         NSColor.white.cgColor, NSColor.clear.cgColor]
      gradient.locations = [0, 0.12, 0.88, 1]
    }

    private func pixelLayer(_ image: CGImage?, in rect: CGRect) -> CALayer {
      let layer = CALayer()
      layer.contents = image
      layer.frame = rect
      layer.magnificationFilter = .nearest
      layer.minificationFilter = .nearest
      return layer
    }

    private func addTrainMotion() {
      train.anchorPoint = .zero
      train.bounds = CGRect(x: 0, y: 0, width: 39, height: 5)
      train.position = CGPoint(x: -44, y: 4)
      let travel = CAKeyframeAnimation(keyPath: "position.x")
      // Two pixels per frame recalls low-resolution game animation.
      travel.values = Array(stride(from: -44, through: 390, by: 2)) + Array(repeating: 390, count: 56)
      travel.calculationMode = .discrete
      travel.duration = 19
      travel.repeatCount = .infinity
      // A train initially peeks out at the left even before the first cycle.
      travel.timeOffset = 3.7
      train.add(travel, forKey: "rail")
    }
  }
}

private struct NightCityArt {
  static let bounds = CGRect(x: 0, y: 0, width: 360, height: 32)
  static let shared = NightCityArt()
  let background: CGImage?
  let foreground: CGImage?
  let train: CGImage?
  let lights: [(image: CGImage?, rect: CGRect)]

  private struct Building {
    let x: Int
    let width: Int
    let roof: Int
    let tone: UInt32

    init(_ x: Int, _ width: Int, _ roof: Int, _ tone: UInt32) {
      self.x = x
      self.width = width
      self.roof = roof
      self.tone = tone
    }
  }

  init() {
    let width = Int(Self.bounds.width)
    let height = Int(Self.bounds.height)
    let silhouettes: [Building] = [
      .init(17, 20, 21, 0x292d47), .init(38, 19, 18, 0x292f4d), .init(61, 14, 15, 0x303656),
      .init(76, 21, 19, 0x2d3350), .init(97, 11, 12, 0x303653), .init(112, 27, 17, 0x37365a),
      .init(141, 19, 12, 0x343956), .init(161, 23, 15, 0x3a3d5b), .init(186, 21, 19, 0x30354c),
      .init(208, 18, 14, 0x373958), .init(225, 19, 18, 0x313652), .init(249, 14, 11, 0x33395a),
      .init(263, 23, 16, 0x393453), .init(289, 21, 13, 0x292f4b), .init(312, 17, 20, 0x2d3047),
      .init(334, 19, 22, 0x2a2e43)
    ]
    let facades: [Building] = [
      .init(45, 22, 20, 0x252b4b), .init(70, 16, 14, 0x353858), .init(87, 12, 17, 0x282e4e),
      .init(102, 27, 19, 0x2a3052), .init(134, 21, 14, 0x343756), .init(153, 15, 18, 0x262e4c),
      .init(174, 15, 15, 0x363953), .init(188, 23, 19, 0x2c3351), .init(215, 15, 16, 0x303655),
      .init(234, 13, 12, 0x2c3353), .init(246, 17, 17, 0x313755), .init(268, 20, 14, 0x303659),
      .init(292, 16, 19, 0x303550), .init(311, 24, 21, 0x292e46)
    ]
    background = Self.raster(width, height) { g in
      Self.rect(g, 0, 0, width, height, 0x202638)
      Self.rect(g, 0, 8, width, 24, 0x252a42)
      Self.rect(g, 0, 16, width, 16, 0x302e49)
      Self.rect(g, 32, 14, 56, 1, 0x34334f)
      Self.rect(g, 219, 11, 34, 1, 0x2d354f)
      Self.rect(g, 235, 12, 50, 1, 0x303652)
      Self.rect(g, 305, 16, 45, 1, 0x35354d)
      for (x, y) in [(43, 5), (69, 8), (115, 3), (128, 9), (154, 5), (190, 9), (221, 4),
                     (242, 7), (256, 4), (310, 6), (332, 10)] {
        Self.rect(g, x, y, 1, 1, 0x61698e)
      }
      // An asymmetric stepped moon, partially lit along the left edge.
      Self.rect(g, 281, 4, 5, 1, 0x938cbd)
      Self.rect(g, 280, 5, 7, 6, 0xa79dd2)
      Self.rect(g, 279, 6, 9, 4, 0xb2a6d9)
      Self.rect(g, 281, 11, 5, 1, 0x7f7aaf)
      Self.rect(g, 284, 5, 3, 1, 0x6d6c99)
      Self.rect(g, 285, 6, 3, 3, 0x6d6c99)
      Self.rect(g, 286, 9, 1, 2, 0x8e86bc)
      Self.rect(g, 281, 9, 2, 1, 0x958aba)

      for b in silhouettes { Self.rect(g, b.x, b.roof, b.width, 28 - b.roof, b.tone) }
      for b in facades { Self.facade(g, b) }

      // The taller central tower has three inset setbacks and a mast.
      Self.rect(g, 166, 2, 1, 5, 0x7d84aa)
      Self.rect(g, 164, 6, 5, 2, 0x697aa3)
      Self.rect(g, 162, 8, 9, 4, 0x485677)
      Self.rect(g, 160, 12, 13, 5, 0x3e4b70)
      Self.rect(g, 158, 17, 17, 11, 0x363e62)
      for (y, x, w) in [(9, 163, 7), (13, 161, 11), (17, 159, 15), (21, 159, 15)] {
        Self.rect(g, x, y, w, 1, 0x6c7798)
        Self.rect(g, x + 1, y + 1, 2, 1, 0x8cb4c5)
      }
      Self.rect(g, 233, 10, 14, 1, 0x444d73)
      Self.rect(g, 234, 12, 2, 13, 0x54577e)
      Self.rect(g, 239, 14, 5, 1, 0xa88aaa)
      Self.rect(g, 211, 22, 8, 2, 0x675686)
      Self.rect(g, 212, 22, 6, 1, 0xaa7bba)
      Self.rect(g, 115, 18, 7, 2, 0x41647a)
      Self.rect(g, 116, 18, 5, 1, 0x79aebb)
      Self.rect(g, 75, 12, 1, 3, 0x8181a4)

      Self.rect(g, 0, 28, width, 4, 0x1e2436)
      Self.rect(g, 0, 28, width, 1, 0x5a5372)
      Self.rect(g, 0, 30, width, 1, 0x33324b)
      for x in stride(from: 12, to: width, by: 16) {
        Self.rect(g, x, 29, 2, 3, 0x474863)
      }
    }
    foreground = Self.raster(width, height) { g in
      for b in [Building(25, 14, 25, 0x25283c), Building(91, 21, 24, 0x232b42),
                Building(184, 19, 24, 0x252c44), Building(259, 13, 25, 0x262b40),
                Building(327, 17, 26, 0x272b3e)] {
        Self.rect(g, b.x, b.roof, b.width, height - b.roof, b.tone)
        Self.rect(g, b.x, b.roof, b.width, 1, 0x494a69)
        Self.rect(g, b.x + 3, b.roof + 2, 2, 1, 0x8e7d8c)
      }
      // Silhouette of a rooftop cat and a curled tail above the passing train.
      for (x, y, w) in [(196, 19, 1), (200, 19, 1), (196, 20, 5),
                        (197, 21, 4), (194, 22, 6), (193, 23, 7), (192, 22, 1)] {
        Self.rect(g, x, y, w, 1, 0x1b2237)
      }
      Self.rect(g, 200, 20, 1, 1, 0xbaa0cd)
    }
    train = Self.raster(39, 5) { g in
      Self.rect(g, 1, 1, 37, 3, 0x78799b)
      Self.rect(g, 2, 0, 34, 1, 0x9594b3)
      Self.rect(g, 0, 3, 39, 1, 0x595b81)
      Self.rect(g, 2, 4, 35, 1, 0x424563)
      for x in [3, 8, 13, 22, 27, 32] {
        Self.rect(g, x, 1, 3, 2, 0xeac292)
        Self.rect(g, x, 1, 3, 1, 0xb1939c)
      }
      Self.rect(g, 18, 1, 2, 3, 0x393f62)
      Self.rect(g, 37, 3, 2, 1, 0xf6d9a9)
    }
    lights = [(166, 1, 1, 0xd7a0b5), (75, 19, 2, 0xf2c48e),
              (151, 19, 2, 0xdbc7a8), (237, 19, 2, 0x8ed0d0), (279, 19, 2, 0xdca5c9)]
      .map { (x, y, w, color) in
        (Self.raster(w, 1) { Self.rect($0, 0, 0, w, 1, color) },
         CGRect(x: x, y: height - y - 1, width: w, height: 1))
      }
  }

  private static func facade(_ g: CGContext, _ b: Building) {
    rect(g, b.x, b.roof, b.width, 28 - b.roof, b.tone)
    rect(g, b.x + 1, b.roof - 1, max(2, b.width - 3), 1, 0x414a6a)
    rect(g, b.x + b.width - 3, b.roof, 3, 28 - b.roof, 0x252d48)
    let windows: [UInt32] = [0x4c5474, 0x9d829c, 0xd5a677, 0x6ba0ad, 0x56668a, 0x69728b]
    for y in stride(from: b.roof + 3, to: 27, by: 3) {
      for x in stride(from: b.x + 2, to: b.x + b.width - 4, by: 4) {
        let index = (b.x + (x - b.x) * 3 + y * 5) % windows.count
        rect(g, x, y, 2, 1, windows[index])
      }
    }
  }

  private static func raster(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> CGImage? {
    guard let g = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    g.translateBy(x: 0, y: CGFloat(height))
    g.scaleBy(x: 1, y: -1)
    g.setShouldAntialias(false)
    g.clear(CGRect(x: 0, y: 0, width: width, height: height))
    draw(g)
    return g.makeImage()
  }

  private static func rect(_ g: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ rgb: UInt32) {
    g.setFillColor(
      red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255, alpha: 1)
    g.fill(CGRect(x: x, y: y, width: w, height: h))
  }
}
