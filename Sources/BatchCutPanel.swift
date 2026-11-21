import SwiftUI

final class BatchCutDraft: ObservableObject {
  let project: Project
  let clips: [Clip]
  let hasPosition: Bool
  let hasScale: Bool
  @Published var settings = BatchCutSettings() {
    didSet { if oldValue != settings { refresh() } }
  }
  @Published private(set) var plan: BatchCutPlan?
  @Published var message: String?
  @Published var step = BatchAdjustment(scale: 0)

  init(project: Project, clips: [Clip]) {
    self.project = project
    self.clips = clips
    hasPosition = clips.contains { $0.kind.supportsBatchPosition }
    hasScale = clips.contains { $0.kind.supportsBatchScale }
    refresh()
  }
  private func refresh() {
    do {
      plan = try BatchCutPlan(clips: clips, settings: settings)
      message = nil
    } catch {
      plan = nil
      message = error.localizedDescription
    }
  }
  func field(_ id: Int, _ key: WritableKeyPath<BatchAdjustment, Double>) -> Binding<Double> {
    Binding(
      get: {
        guard let parts = self.plan?.parts, parts.indices.contains(id) else { return 0 }
        return parts[id].adjustments[keyPath: key]
      },
      set: { value in
        guard var plan = self.plan, plan.parts.indices.contains(id) else { return }
        plan.parts[id].adjustments[keyPath: key] = value
        self.plan = plan
        self.message = nil
      })
  }
  func fill() {
    guard var plan else { return }
    for index in plan.parts.indices {
      let part = plan.parts[index]
      let kind = part.original.kind
      let n = Double(part.ordinal)
      plan.parts[index].adjustments = BatchAdjustment(
        time: n * step.time, x: kind.supportsBatchPosition ? n * step.x : 0,
        y: kind.supportsBatchPosition ? n * step.y : 0, scale: kind.supportsBatchScale ? 100 + n * step.scale : 100)
    }
    self.plan = plan
    message = nil
  }
}

struct BatchCutPanel: View {
  @ObservedObject var draft: BatchCutDraft
  @State private var stepDisclosure = false
  let cancel: () -> Void
  let apply: (BatchCutPlan) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L("批量切割")).font(.title2.weight(.semibold))
        Spacer()
        Text(L("已选 \(draft.clips.count) 个片段")).font(.callout).foregroundStyle(UI.muted)
      }
      VStack(alignment: .leading, spacing: 6) {
        SectionName(name: L("切割方式"))
        HStack(spacing: 16) {
          PanelSegments(
            title: L("切割方式"), options: BatchCutMode.allCases, selection: $draft.settings.mode
          ) { LKey($0.rawValue) }.frame(width: 205)
          if draft.settings.mode == .interval {
            NumberRow(
              label: L("间隔"), value: draft.settings.interval, range: 1 / 30...86_400,
              unit: L("秒"), precision: 2
            ) { draft.settings.interval = $0 }.frame(width: 141)
            NumberRow(
              label: L("单个片段最多切出"), value: Double(draft.settings.limit),
              range: 0...Double(BatchCutPlan.partLimit), unit: L("份")
            ) {
              draft.settings.limit = Int($0.rounded())
            }.frame(width: 225)
            Text(L("0 表示切到末尾")).font(.caption).foregroundStyle(UI.muted)
          } else {
            NumberRow(
              label: L("每段均分"), value: Double(draft.settings.count),
              range: 2...Double(BatchCutPlan.partLimit), unit: L("份")
            ) {
              draft.settings.count = Int($0.rounded())
            }.frame(width: 183)
          }
          Spacer(minLength: 0)
        }
      }

      DisclosureGroup(L("按份递增"), isExpanded: $stepDisclosure) {
        HStack(spacing: 14) {
          stepField(L("后移"), \.time, unit: L("秒"), range: -3600...3600)
          if draft.hasPosition {
            stepField(L("水平偏移"), \.x, unit: "%", range: -100...100)
            stepField(L("垂直偏移"), \.y, unit: "%", range: -100...100)
          }
          if draft.hasScale {
            stepField(L("缩放增量"), \.scale, unit: "%", range: -100...100)
          }
          Button(L("填入各份"), action: draft.fill).buttonStyle(QuietButton()).disabled(draft.plan == nil)
        }.padding(.top, 7)
        Text(L("第一份从原值开始，后续各份按序号累加。填入后仍可单独修改。"))
          .font(.caption).foregroundStyle(UI.muted).padding(.top, 5)
      }.disclosureGroupStyle(SettingsDisclosureStyle())
        .padding(10).background(UI.well, in: RoundedRectangle(cornerRadius: 6))

      if let plan = draft.plan {
        partsTable(plan.parts)
      } else {
        Spacer(minLength: 100)
      }

      HStack {
        if let message = draft.message {
          Text(message).foregroundStyle(.orange).lineLimit(2).accessibilityLabel(message)
        } else if let plan = draft.plan {
          let tail = plan.remainders.isEmpty ? "" : L("，另保留 \(plan.remainders.count) 个余段")
          Text(L("共 \(plan.parts.count) 份") + tail).foregroundStyle(UI.muted)
        }
        Spacer()
        Button(L("取消"), action: cancel).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(L("应用切割")) {
          NSApp.keyWindow?.makeFirstResponder(nil)
          if let plan = draft.plan { apply(plan) }
        }.buttonStyle(PrimaryButton()).disabled(draft.plan == nil)
      }
    }.padding(16).frame(minWidth: 836, minHeight: 482)
      .background(UI.panel).foregroundStyle(.white).preferredColorScheme(.dark)
  }

  private func stepField(
    _ label: String, _ key: WritableKeyPath<BatchAdjustment, Double>,
    unit: String, range: ClosedRange<Double>
  ) -> some View {
    NumberRow(
      label: label, value: draft.step[keyPath: key], range: range, unit: unit,
      precision: 2
    ) { draft.step[keyPath: key] = $0 }
  }

  private func partsTable(_ parts: [BatchPart]) -> some View {
    Table(parts) {
      TableColumn(L("片段与份数")) { part in
        Label(draft.project.name(part.original) + "  #" + String(part.ordinal + 1),
              systemImage: part.original.kind.icon).lineLimit(1)
      }.width(min: 115, ideal: 168)
      TableColumn(L("起点")) { part in Text(tc(part.range.lowerBound)).monospacedDigit() }
        .width(73)
      TableColumn(L("时长")) { part in Text(tc(part.range.count)).monospacedDigit() }
        .width(65)
      TableColumn(L("位移 (秒)")) { part in cell(part, \.time, label: L("时间位移")) }.width(93)
      TableColumn("X (%)") { part in
        cell(part, \.x, label: L("水平偏移"), available: part.original.kind.supportsBatchPosition)
      }
      .width(94)
      TableColumn("Y (%)") { part in
        cell(part, \.y, label: L("垂直偏移"), available: part.original.kind.supportsBatchPosition)
      }
      .width(94)
      TableColumn(L("缩放 (%)")) { part in
        cell(part, \.scale, label: L("相对缩放"), available: part.original.kind.supportsBatchScale)
      }
      .width(94)
    }.tableStyle(.inset).alternatingRowBackgrounds(.disabled).frame(minHeight: 180)
  }
  @ViewBuilder private func cell(
    _ part: BatchPart, _ key: WritableKeyPath<BatchAdjustment, Double>, label: String,
    available: Bool = true
  ) -> some View {
    if available {
      TextField(
        label, value: draft.field(part.id, key),
        format: .number.grouping(.never).precision(.fractionLength(0...3))
      )
      .labelsHidden().multilineTextAlignment(.trailing).font(.system(size: 11, design: .monospaced))
      .accessibilityLabel(L("第 \(part.ordinal + 1) 份 ") + label)
    } else {
      Text("—").foregroundStyle(UI.muted).frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}
