#if canImport(SwiftUI)
import SwiftUI
import VerificationThroughput

/// The console: pick a change set, watch the plan, the cost and the admission
/// decision move together.
///
/// The three panels are deliberately on one screen. Every team that has this
/// problem has the three numbers in three different places — the shard config
/// in a YAML file, the runner spend in a billing dashboard, the merge-queue
/// wait in somebody's head — and that is exactly why nobody notices that
/// raising the shard count made the pipeline slower *and* more expensive.
@MainActor
public struct VerificationConsoleView: View {

    @State private var model: VerificationConsoleModel

    public init(workspace: VerificationWorkspace) {
        _model = State(wrappedValue: VerificationConsoleModel(workspace: workspace))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headline
                    scenarioPicker
                    controls
                    headlineNumbers
                    shardPanel
                    curvePanel
                    contractPanel
                    admissionPanel
                    footnote
                }
                .padding(18)
            }
            .navigationTitle("Verification Throughput")
        }
    }

    // MARK: - Sections

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents write the PRs. The simulator boots one at a time.")
                .font(.headline)
            Text("Every shard pays boot + signing + warm-up before its first assertion, so the makespan curve has a floor — and past it, another runner makes the run slower and dearer at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scenarioPicker: some View {
        card("Change set") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Scenario", selection: $model.selectedScenarioID) {
                    ForEach(model.workspace.scenarios) { scenario in
                        Text(scenario.title).tag(scenario.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let scenario = model.selectedScenario {
                    Text(scenario.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(scenario.changedPaths.isEmpty ? "(no files)" : scenario.changedPaths.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var controls: some View {
        card("Policy") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Tier", selection: $model.tier) {
                    ForEach(VerificationTier.allCases, id: \.self) { tier in
                        Text(tier.description.capitalized).tag(tier)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Job class", selection: $model.jobClass) {
                    ForEach(JobClass.allCases, id: \.self) { jobClass in
                        Text(jobClass.description).tag(jobClass)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Choose shard count from the curve", isOn: $model.usesOptimalShardCount)
                    .font(.subheadline)

                if !model.usesOptimalShardCount {
                    Stepper(
                        "Shards: \(model.manualShardCount)",
                        value: $model.manualShardCount,
                        in: 1...model.shardCountCeiling
                    )
                    .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Budget already consumed this hour: \(model.budgetPressurePercent)%")
                        .font(.subheadline)
                    Slider(
                        value: Binding(
                            get: { Double(model.budgetPressurePercent) },
                            // Routed through the package's own total conversion:
                            // `Int(someDouble)` traps on NaN, and a Slider bound
                            // to a degenerate range can hand you one.
                            set: { model.budgetPressurePercent = Int.saturating(from: $0) }
                        ),
                        in: 0...100
                    )
                }
            }
        }
    }

    private var headlineNumbers: some View {
        HStack(spacing: 12) {
            metric("Makespan", DurationFormat.short(model.plan.makespan), .primary)
            metric("Shards", "\(model.plan.shardCount)", .primary)
            metric("Cost", RunnerCostModel.formatted(model.plan.projectedCost), .primary)
        }
    }

    private var shardPanel: some View {
        card("Shard packing") {
            VStack(alignment: .leading, spacing: 10) {
                if model.plan.shardPlan.shards.isEmpty {
                    Text("This change set reaches no test bundle. Nothing to run — and that is a decision the planner is willing to defend, because every changed path was attributed to a target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let scale = max(1, model.plan.makespan)
                    ForEach(model.plan.shardPlan.shards, id: \.index) { shard in
                        shardRow(shard, scale: scale)
                    }
                    Divider()
                    labelledRow(
                        "Idle spread between shards",
                        DurationFormat.short(model.plan.shardPlan.imbalance)
                    )
                    labelledRow(
                        "Whole suite, one shard",
                        DurationFormat.short(model.plan.fullSuiteSerialMakespan)
                    )
                    labelledRow(
                        "One shard per bundle",
                        DurationFormat.short(model.plan.maximallyParallelMakespan)
                    )
                }
            }
        }
    }

    private func shardRow(_ shard: Shard, scale: Milliseconds) -> some View {
        let fixed = model.plan.shardPlan.fixedCostPerShard
        let total = SaturatingMath.add(fixed, shard.work)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Shard \(shard.index + 1)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(DurationFormat.short(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let width = max(0, geometry.size.width)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.75))
                        .frame(width: barWidth(fixed, of: scale, in: width))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: barWidth(shard.work, of: scale, in: width))
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            Text(shard.targets.map(\.rawValue).joined(separator: ", "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var curvePanel: some View {
        card("Makespan by shard count") {
            VStack(alignment: .leading, spacing: 8) {
                if model.plan.shardCountCurve.isEmpty {
                    Text("No bundles selected, so there is no curve to draw.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let peak = max(1, model.plan.shardCountCurve.map(\.makespan).max() ?? 1)
                    let best = model.plan.shardCountCurve.min { $0.makespan < $1.makespan }?.shardCount
                    ForEach(model.plan.shardCountCurve, id: \.shardCount) { sample in
                        HStack(spacing: 8) {
                            Text("\(sample.shardCount)×")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 26, alignment: .trailing)
                            GeometryReader { geometry in
                                Rectangle()
                                    .fill(sample.shardCount == best
                                          ? Color.green.opacity(0.85)
                                          : Color.secondary.opacity(0.35))
                                    .frame(width: barWidth(sample.makespan, of: peak, in: max(0, geometry.size.width)))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .frame(height: 12)
                            Text(DurationFormat.short(sample.makespan))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                        }
                    }
                    Text("Green is the floor. Every bar to its right is a runner you paid for that made the run slower.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var contractPanel: some View {
        card("Agent test contract") {
            VStack(alignment: .leading, spacing: 8) {
                let report = model.plan.contractReport
                HStack(spacing: 12) {
                    metric("Blocking", "\(report.blockingViolations.count)", report.blockingViolations.isEmpty ? .green : .red)
                    metric("Advisory", "\(report.advisoryViolations.count)", .secondary)
                    metric("Pinned", "\(report.shardUnsafeTargets.count)", .orange)
                }
                if report.violations.isEmpty {
                    Text("Every declared test is shardable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(report.violations.prefix(6).enumerated()), id: \.offset) { entry in
                        violationRow(entry.element)
                    }
                    if report.violations.count > 6 {
                        Text("+ \(report.violations.count - 6) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Blocking bundles are pinned onto one shard, not dropped. Refusing to run them would be the worse failure.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func violationRow(_ violation: ContractViolation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(violation.severity == .blocking ? Color.red : Color.orange)
                .frame(width: 6, height: 6)
            Text(violation.testIdentifier)
                .font(.system(.caption2, design: .monospaced))
            Text(violation.hazard.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var admissionPanel: some View {
        card("Admission") {
            VStack(alignment: .leading, spacing: 8) {
                switch model.admission {
                case .admitted(let tier, let reserved, _):
                    decisionRow(
                        "Admitted at \(tier.description)",
                        DurationFormat.short(reserved) + " of runner time reserved",
                        .green
                    )
                case .degraded(let tier, let from, let reserved, _):
                    decisionRow(
                        "Degraded \(from.description) → \(tier.description)",
                        DurationFormat.short(reserved) + " reserved — partial signal now beats full signal later",
                        .orange
                    )
                case .deferred(let retryAfter, _):
                    decisionRow(
                        "Deferred",
                        "retry in \(DurationFormat.short(retryAfter)); aging promotes this job on each deferral so it cannot wait forever",
                        .red
                    )
                }
                Divider()
                labelledRow("Smoke", DurationFormat.short(model.tieredCost.smoke))
                labelledRow("Impacted", DurationFormat.short(model.tieredCost.impacted))
                labelledRow("Full", DurationFormat.short(model.tieredCost.full))
            }
        }
    }

    private var footnote: some View {
        Text("Durations and runner rates are illustrative fixtures owned by this demo app, not measurements of any real repository.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Building blocks

    private func barWidth(_ value: Milliseconds, of scale: Milliseconds, in width: CGFloat) -> CGFloat {
        guard scale > 0, value > 0, width > 0 else { return 0 }
        let ratio = Double(min(value, scale)) / Double(scale)
        guard ratio.isFinite else { return 0 }
        return max(0, min(width, width * CGFloat(ratio)))
    }

    private func metric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func labelledRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func decisionRow(_ title: String, _ detail: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
