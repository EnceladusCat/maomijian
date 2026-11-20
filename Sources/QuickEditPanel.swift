import SwiftUI

struct QuickEditPanel: View {
  let editor: Editor
  @ObservedObject var updates: PanelUpdates
  private var selection: Clip? { editor.selectedIDs.count == 1 ? editor.clip : nil }

  var body: some View {
    ScrollView {
      VStack(spacing: 7) {
        let inset = editor.pictureInsetSelection
        let active = selection?.pictureInset != nil
        let insetDetail = active ? L("已启用") : inset?.backdrop != nil ? L("仅重叠段，最后选口播")
          : inset != nil ? L("放到左下角") : L("选一个素材或两段叠片")
        item(.inset, L("口播画中画"), detail: insetDetail, enabled: inset != nil) {
          editor.enablePictureInset()
        }
        item(.story, L("数据讲解"), detail: selection?.kind == .chart ? L("套用到选中图表") : L("添加示例图表")) {
          editor.applyDataStory()
        }
        item(.chapter, EditorialStyle.chapter.title, detail: L("压暗底片，标题入场")) { editor.addEditorial(.chapter) }
        let switchesMetric = selection?.editorial?.style == .metric
        item(.metric, EditorialStyle.metric.title,
             detail: switchesMetric ? L("切回经典数字样式") : L("自定义起止值和计数节奏"),
             appliesToSelection: switchesMetric) { editor.useQuickMetricStyle(reveal: false) }
        item(.reveal, L("数字揭晓"),
             detail: switchesMetric ? L("将所选数字改成揭晓样式") : L("数字与比例条一起亮起"),
             appliesToSelection: switchesMetric) { editor.useQuickMetricStyle(reveal: true) }
        item(.cards, EditorialStyle.cards.title, detail: L("逐卡编辑说明和配图")) { editor.addEditorial(.cards) }
      }.padding(10)
    }
  }

  private func item(_ preview: QuickPreview.Style, _ title: String, detail: String, enabled: Bool = true,
                    appliesToSelection: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        QuickPreview(style: preview).frame(width: 53, height: 34).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 12, weight: .semibold))
          Text(detail).font(.system(size: 10)).foregroundStyle(UI.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: appliesToSelection ? "arrow.left.arrow.right" : "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.mint)
          .accessibilityHidden(true)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(QuietButton()).disabled(!enabled)
  }
}

private struct QuickPreview: View {
  enum Style { case inset, story, chapter, metric, reveal, cards }
  let style: Style

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5).fill(UI.deep)
      switch style {
      case .inset:
        VStack(alignment: .trailing, spacing: 3) {
          Capsule().fill(UI.muted.opacity(0.4)).frame(width: 24, height: 3)
          Capsule().fill(UI.muted.opacity(0.25)).frame(width: 15, height: 3)
        }.offset(x: 5, y: -5)
        Image(systemName: "person.crop.circle.fill")
          .font(.system(size: 14)).foregroundStyle(UI.mint).offset(x: -12, y: 7)
      case .story:
        Image(systemName: "chart.line.uptrend.xyaxis")
          .font(.system(size: 20, weight: .semibold)).foregroundStyle(UI.accent)
      case .chapter:
        VStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 29, height: 4)
          Capsule().fill(UI.buttonTint).frame(width: 11, height: 1.5)
          Capsule().fill(UI.muted.opacity(0.65)).frame(width: 18, height: 2)
        }
      case .metric:
        Text("50%").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(UI.mint)
      case .reveal:
        VStack(alignment: .leading, spacing: 2) {
          Text("50%").font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(UI.mint)
          ZStack(alignment: .leading) {
            Capsule().fill(UI.muted.opacity(0.32))
            Capsule().fill(UI.mint).frame(width: 15)
          }.frame(width: 30, height: 2)
        }
      case .cards:
        HStack(spacing: 2) {
          ForEach(Array([UI.mint, UI.accent, UI.coral].enumerated()), id: \.offset) { _, color in
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 10, height: 16)
          }
        }
      }
    }
  }
}
