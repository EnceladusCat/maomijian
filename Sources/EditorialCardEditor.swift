import SwiftUI

struct EditorialCardEditor: View {
  let spec: EditorialSpec
  let title: String
  let accent: String
  let aspect: CGFloat
  let background: String
  let cancel: () -> Void
  let chooseImage: (@escaping (URL?) -> Void) -> Void
  let apply: ([EditorialCard]) -> Void
  @State private var cards: [EditorialCard]
  @State private var active = 0
  @State private var loading = false
  @State private var imageError = false

  init(spec: EditorialSpec, title: String, accent: String, aspect: CGFloat, background: String,
       cancel: @escaping () -> Void, chooseImage: @escaping (@escaping (URL?) -> Void) -> Void,
       apply: @escaping ([EditorialCard]) -> Void) {
    self.spec = spec
    self.title = title
    self.accent = accent
    self.aspect = aspect
    self.background = background
    self.cancel = cancel
    self.chooseImage = chooseImage
    self.apply = apply
    _cards = State(initialValue: spec.cards)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 20) {
        controls.frame(minWidth: 270, idealWidth: 320, maxWidth: 340)
        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack {
        Spacer()
        Button(L("取消"), action: cancel).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(L("应用卡片")) { apply(cards) }.buttonStyle(PrimaryButton(tint: UI.mint)).disabled(loading)
      }
    }
    .padding(18).background(UI.panel).foregroundStyle(.white).preferredColorScheme(.dark)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 9) {
      PanelSegments(title: L("选择卡片"), options: Array(cards.indices), selection: $active, tint: UI.mint) {
        L("卡片 \($0 + 1)")
      }
      SectionName(name: L("卡片标题"))
      TextField(L("卡片标题"), text: $cards[active].title, prompt: Text(L("可留空")))
        .textFieldStyle(.roundedBorder)
      SectionName(name: L("说明"))
      TextEditor(text: $cards[active].detail)
        .font(.body).scrollContentBackground(.hidden)
        .padding(7).frame(minHeight: 110)
        .background(UI.deep, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(L("卡片说明"))
        .id(active)
      HStack {
        SectionName(name: L("卡片图标"))
        Spacer()
        let options = EditorialCardIcon.allCases
        MenuField(title: L("卡片图标"), choices: options.map(\.title),
                  selectedIndex: options.firstIndex(of: cards[active].icon ?? .none) ?? 0) { index in
          cards[active].icon = options[index]
        }.frame(width: 124, height: 23)
      }
      HStack(spacing: 12) {
        ProjectColorPicker(title: L("卡片底色"), hex: cards[active].background ?? EditorialCard.backgrounds[active]) {
          cards[active].background = $0
        }
        ProjectColorPicker(title: L("强调色"), hex: cards[active].accent ?? (active == 0 ? accent : EditorialCard.accents[active])) {
          cards[active].accent = $0
        }
      }
      HStack {
        let hasPicture = cards[active].picture != nil
        Button(action: pickPicture) {
          Label(hasPicture ? L("更换配图…") : L("添加配图…"), systemImage: "photo")
        }.buttonStyle(QuietButton()).disabled(loading)
        if hasPicture {
          Button(L("移除配图")) { cards[active].picture = nil }.buttonStyle(QuietButton()).disabled(loading)
        }
        if loading { ProgressView().controlSize(.small) }
      }
      if imageError { Text(L("无法读取这张图片。")).font(.caption).foregroundStyle(UI.coral) }
    }.onChange(of: active) { _, _ in imageError = false }
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionName(name: L("版式预览"))
      SwiftUI.Canvas { context, size in
        let w = min(size.width, size.height * aspect), h = w / aspect
        let bounds = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        var draft = spec
        draft.cards = cards
        context.withCGContext { g in
          g.saveGState()
          g.translateBy(x: 0, y: size.height)
          g.scaleBy(x: 1, y: -1)
          g.setFillColor(ink(background))
          g.fill(bounds)
          EditorialPaint.draw(draft, title: title, accent: accent, in: bounds, progress: 1, context: g)
          g.restoreGState()
        }
      }
      .padding(10).background(UI.deep, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityLabel(L("卡片画面预览"))
      Text(L("说明会自动换行，超出卡片的部分在画面中以省略号显示。"))
        .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func pickPicture() {
    let index = active
    imageError = false
    chooseImage { url in
      guard let url else { return }
      loading = true
      DispatchQueue.global(qos: .userInitiated).async {
        let data = EditorialCardImages.prepare(url)
        DispatchQueue.main.async {
          loading = false
          if let data { cards[index].picture = data }
          else if active == index { imageError = true }
        }
      }
    }
  }
}
