import SwiftUI

final class BatchCutDraft: ObservableObject {
  let project: Project
  let clips: [Clip]
  let hasVideo: Bool
  @Published var settings = BatchCutSettings() {
    didSet { if oldValue != settings { refresh() } }
  }
  @Published private(set) var plan: BatchCutPlan?
  @Published var message: String?
  @Published var step = BatchAdjustment(scale: 0)

  init(project: Project, clips: [Clip]) {
    self.project = project
    self.clips = clips
    hasVideo = clips.contains { $0.kind == .video }
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
      let n = Double(plan.parts[index].ordinal)
      plan.parts[index].adjustments = BatchAdjustment(
        time: n * step.time, x: n * step.x, y: n * step.y, scale: 100 + n * step.scale)
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
        Text("批量切割").font(.title2.weight(.semibold))
        Spacer()
        Text("已选 \(draft.clips.count) 个素材").font(.callout).foregroundStyle(UI.muted)
      }
      HStack(spacing: 16) {
        Picker("切割方式", selection: $draft.settings.mode) {
          ForEach(BatchCutMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).frame(width: 205)
        if draft.settings.mode == .interval {
          NumberRow(
            label: "间隔", value: draft.settings.interval, range: 1 / 30...86_400,
            unit: "秒", precision: 2
          ) { draft.settings.interval = $0 }.frame(width: 141)
          NumberRow(
            label: "每个素材最多切出", value: Double(draft.settings.limit),
            range: 0...Double(BatchCutPlan.partLimit), unit: "份"
          ) {
            draft.settings.limit = Int($0.rounded())
          }.frame(width: 206)
          Text("0 表示切到末尾").font(.caption).foregroundStyle(UI.muted)
        } else {
          NumberRow(
            label: "每个素材均分", value: Double(draft.settings.count),
            range: 2...Double(BatchCutPlan.partLimit), unit: "份"
          ) {
            draft.settings.count = Int($0.rounded())
          }.frame(width: 162)
        }
        Spacer(minLength: 0)
      }

      DisclosureGroup("按份递增", isExpanded: $stepDisclosure) {
        HStack(spacing: 14) {
          stepField("后移", \.time, unit: "秒", range: -3600...3600)
          if draft.hasVideo {
            stepField("水平偏移", \.x, unit: "%", range: -100...100)
            stepField("垂直偏移", \.y, unit: "%", range: -100...100)
            stepField("缩放增量", \.scale, unit: "%", range: -100...100)
          }
          Button("填入各份", action: draft.fill).disabled(draft.plan == nil)
        }.padding(.top, 7)
        Text("第一份从原值开始，后续各份按序号累加。填入后仍可单独修改。")
          .font(.caption).foregroundStyle(UI.muted).padding(.top, 5)
      }.padding(10).background(UI.well, in: RoundedRectangle(cornerRadius: 6))

      if let plan = draft.plan {
        partsTable(plan.parts)
      } else {
        Spacer(minLength: 100)
      }

      HStack {
        if let message = draft.message {
          Text(message).foregroundStyle(.orange).lineLimit(2).accessibilityLabel(message)
        } else if let plan = draft.plan {
          let tail = plan.remainders.isEmpty ? "" : "，另保留 \(plan.remainders.count) 个余段"
          Text("共 \(plan.parts.count) 份" + tail).foregroundStyle(UI.muted)
        }
        Spacer()
        Button("取消", action: cancel).keyboardShortcut(.cancelAction)
        Button("应用切割") {
          NSApp.keyWindow?.makeFirstResponder(nil)
          if let plan = draft.plan { apply(plan) }
        }.buttonStyle(PrimaryButton()).disabled(draft.plan == nil)
      }
    }.frame(minWidth: 820, minHeight: 450).padding(16)
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
      TableColumn("素材与份数") { part in
        Text(draft.project.name(part.original) + "  #" + String(part.ordinal + 1)).lineLimit(1)
      }.width(min: 115, ideal: 168)
      TableColumn("原始起点") { part in Text(tc(part.range.lowerBound)).monospacedDigit() }
        .width(73)
      TableColumn("时长") { part in Text(tc(part.range.count)).monospacedDigit() }
        .width(65)
      TableColumn("时间位移 (秒)") { part in cell(part, \.time, label: "时间位移") }.width(93)
      TableColumn("水平偏移 (%)") { part in
        cell(part, \.x, label: "水平偏移").disabled(part.original.kind != .video)
      }
      .width(94)
      TableColumn("垂直偏移 (%)") { part in
        cell(part, \.y, label: "垂直偏移").disabled(part.original.kind != .video)
      }
      .width(94)
      TableColumn("相对缩放 (%)") { part in
        cell(part, \.scale, label: "相对缩放").disabled(part.original.kind != .video)
      }
      .width(94)
    }.tableStyle(.inset).frame(minHeight: 180)
  }
  private func cell(
    _ part: BatchPart, _ key: WritableKeyPath<BatchAdjustment, Double>, label: String
  ) -> some View {
    TextField(
      label, value: draft.field(part.id, key),
      format: .number.grouping(.never).precision(.fractionLength(0...3))
    )
    .labelsHidden().multilineTextAlignment(.trailing).font(.system(size: 11, design: .monospaced))
    .accessibilityLabel("第 \(part.ordinal + 1) 份 " + label)
  }
}
