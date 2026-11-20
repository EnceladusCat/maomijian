import AppKit
import CoreText

struct EditorialParagraph {
  let lines: [CTLine]
  let lineHeight: CGFloat
  let ascent: CGFloat
  let truncated: Bool
  var height: CGFloat { CGFloat(lines.count) * lineHeight }

  init(_ text: String, font: NSFont, color: CGColor, width: CGFloat, maxLines: Int) {
    lineHeight = Self.spacing(font)
    ascent = font.ascender
    let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    guard !text.isEmpty, width > 0, maxLines > 0 else {
      lines = []
      truncated = !text.isEmpty
      return
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: NSColor(cgColor: color) ?? .white,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    var position = 0
    var result = [CTLine]()
    let source = text as NSString
    while position < attributed.length && result.count < maxLines {
      let suggested = CTTypesetterSuggestLineBreak(typesetter, position, Double(width))
      let count = suggested > 0 ? suggested : source.rangeOfComposedCharacterSequence(at: position).length
      let range = CFRange(location: position, length: count)
      position += count
      if result.count == maxLines - 1 && position < attributed.length {
        let last = attributed.attributedSubstring(from: NSRange(location: range.location, length: range.length))
        let ellipsis = NSAttributedString(string: "…", attributes: attributes)
        let ending = NSMutableAttributedString(attributedString: last)
        while let char = ending.string.last, char.isWhitespace {
          ending.deleteCharacters(in: NSRange(location: ending.length - String(char).utf16.count,
                                             length: String(char).utf16.count))
        }
        ending.append(ellipsis)
        let line = CTLineCreateWithAttributedString(ending)
        if CTLineGetTypographicBounds(line, nil, nil, nil) <= width {
          result.append(line)
        } else {
          let token = CTLineCreateWithAttributedString(ellipsis)
          result.append(CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? token)
        }
      } else {
        result.append(CTTypesetterCreateLine(typesetter, range))
      }
    }
    lines = result
    truncated = position < attributed.length
  }

  static func spacing(_ font: NSFont) -> CGFloat {
    ceil((font.ascender - font.descender + font.leading) * 1.08)
  }

  func draw(in box: CGRect, context g: CGContext) {
    guard !lines.isEmpty, box.width > 0, box.height > 0 else { return }
    g.saveGState()
    g.clip(to: box)
    g.textMatrix = .identity
    let baseline = box.maxY - ascent - (lineHeight - ascent) * 0.17
    for (i, line) in lines.enumerated() {
      g.textPosition = CGPoint(x: box.minX, y: baseline - CGFloat(i) * lineHeight)
      CTLineDraw(line, g)
    }
    g.restoreGState()
  }
}

enum EditorialCardsPaint {
  static func draw(_ spec: EditorialSpec, title: String, accent: String, in canvas: CGRect,
                   progress: Double, context g: CGContext) {
    let style = spec.cardsAppearance ?? EditorialCardsAppearance()
    let horizontal = style.layout.isHorizontal(in: canvas)
    let wide = canvas.width >= canvas.height
    let size: CGSize
    if horizontal { size = CGSize(width: 720, height: 360) }
    else { size = wide ? CGSize(width: 720, height: 466) : CGSize(width: 430, height: 610) }
    let s = min(canvas.width / size.width, canvas.height / size.height)
    g.saveGState()
    g.translateBy(x: canvas.midX - size.width * s / 2, y: canvas.midY - size.height * s / 2)
    g.scaleBy(x: s, y: s)
    let leading = size.width * 0.055
    let available = size.width - 2 * leading
    let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let top = size.height - (hasTitle ? 66 : 28)
    let bottom = 31.0
    if hasTitle {
      let titleBox = CGRect(x: leading, y: top + 9, width: available, height: 34)
      EditorialParagraph(title, font: .systemFont(ofSize: 25, weight: .heavy),
                         color: ink("#F4F7FD", min(1, progress * 2.1)),
                         width: available, maxLines: 1).draw(in: titleBox, context: g)
    }
    let height = horizontal ? top - bottom : (top - bottom - 2 * style.gap) / 3
    let width = horizontal ? (available - 2 * style.gap) / 3 : available
    for (index, card) in spec.cards.enumerated() {
      let reveal = style.reveal(for: index, at: progress)
      guard reveal > 0 else { continue }
      let offset = (1 - reveal) * (1 - reveal) * 14
      let x = horizontal ? leading + Double(index) * (width + style.gap) : leading
      let y = horizontal ? bottom : top - height - Double(index) * (height + style.gap)
      let rect = CGRect(x: x, y: y - offset, width: width, height: height)
      let tone = card.accent ?? (index == 0 ? accent : EditorialCard.accents[index])
      drawCard(card, in: rect, accent: tone, background: card.background ?? EditorialCard.backgrounds[index],
               style: style, featured: style.featured == index, horizontal: horizontal, reveal: reveal, context: g)
    }
    g.restoreGState()
  }

  private static func drawCard(
    _ card: EditorialCard, in rect: CGRect, accent: String, background: String,
    style: EditorialCardsAppearance, featured: Bool, horizontal: Bool, reveal: Double, context g: CGContext
  ) {
    let outline = CGPath(roundedRect: rect, cornerWidth: style.corner, cornerHeight: style.corner, transform: nil)
    g.setFillColor(ink(background, reveal * 0.98))
    g.addPath(outline)
    g.fillPath()
    if featured {
      g.setStrokeColor(ink(accent, reveal))
      g.setLineWidth(1.8)
      g.addPath(outline)
      g.strokePath()
    }
    let inset = 14.0
    var content = rect.insetBy(dx: inset, dy: inset)
    let icon = (card.icon?.symbol).flatMap { EditorialCardImages.symbol($0, tint: accent) }
    if let picture = card.picture.flatMap(EditorialCardImages.photo) {
      if horizontal {
        let h = min(77, content.height * 0.36)
        let media = CGRect(x: content.minX, y: content.maxY - h, width: content.width, height: h)
        drawPicture(picture, in: media, reveal: reveal, context: g)
        if let icon { fitted(icon, in: CGRect(x: media.minX + 5, y: media.maxY - 25, width: 20, height: 20), opacity: reveal, context: g) }
        content.size.height -= h + 10
      } else {
        let w = min(content.width * 0.27, content.height * 1.12)
        let media = CGRect(x: content.minX, y: content.minY, width: w, height: content.height)
        drawPicture(picture, in: media, reveal: reveal, context: g)
        if let icon { fitted(icon, in: CGRect(x: media.minX + 5, y: media.maxY - 25, width: 20, height: 20), opacity: reveal, context: g) }
        content.origin.x += w + 12
        content.size.width -= w + 12
      }
    } else if horizontal {
      if let icon {
        fitted(icon, in: CGRect(x: content.minX, y: content.maxY - 22, width: 22, height: 22),
               opacity: reveal, context: g)
        content.size.height -= 28
      } else {
        g.setFillColor(ink(accent, reveal))
        g.fill(CGRect(x: content.minX, y: content.maxY - 3, width: 23, height: 2.5))
        content.size.height -= 13
      }
    } else if let icon {
      fitted(icon, in: CGRect(x: content.minX, y: content.maxY - 22, width: 22, height: 22),
             opacity: reveal, context: g)
      content.origin.x += 32
      content.size.width -= 32
    } else {
      g.setFillColor(ink(accent, reveal))
      g.fill(CGRect(x: content.minX, y: content.minY, width: 2.5, height: content.height))
      content.origin.x += 12
      content.size.width -= 12
    }
    let light = isLight(background)
    let detailFont = NSFont.systemFont(ofSize: style.detailSize)
    let titleFont = NSFont.systemFont(ofSize: 22, weight: .heavy)
    let detailRoom = card.detail.isEmpty ? 0 : EditorialParagraph.spacing(detailFont) * 2 + 6
    let titleLines = bound(Int((content.height - detailRoom) / EditorialParagraph.spacing(titleFont)), 1, 2)
    let name = EditorialParagraph(card.title, font: titleFont,
                                  color: ink(light ? "#11182A" : "#F2F5FD", reveal),
                                  width: content.width, maxLines: titleLines)
    let heading = CGRect(x: content.minX, y: content.maxY - name.height, width: content.width, height: name.height)
    name.draw(in: heading, context: g)
    content.size.height = max(0, content.height - name.height - (name.lines.isEmpty ? 0 : 6))
    let lineCount = Int(content.height / EditorialParagraph.spacing(detailFont))
    EditorialParagraph(card.detail, font: detailFont, color: ink(light ? "#303C50" : "#D4DDEE", reveal),
                       width: content.width, maxLines: lineCount).draw(in: content, context: g)
  }

  private static func drawPicture(_ image: CGImage, in box: CGRect, reveal: Double, context g: CGContext) {
    let scale = max(box.width / Double(image.width), box.height / Double(image.height))
    let width = Double(image.width) * scale, height = Double(image.height) * scale
    g.saveGState()
    g.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
    g.clip()
    g.setAlpha(reveal)
    g.draw(image, in: CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height))
    g.restoreGState()
  }

  private static func fitted(_ image: CGImage, in box: CGRect, opacity: Double, context g: CGContext) {
    let scale = min(box.width / Double(image.width), box.height / Double(image.height))
    let width = Double(image.width) * scale, height = Double(image.height) * scale
    g.saveGState()
    g.setAlpha(opacity)
    g.draw(image, in: CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height))
    g.restoreGState()
  }

  private static func isLight(_ bg: String) -> Bool {
    guard let rgb = ink(bg).components else { return false }
    let linear = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0.0) { $0 + $1.0 * $1.1 } > 0.34
  }
}
