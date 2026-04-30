import SwiftUI
import Charts

// MARK: - Poster / hero surfaces

/// Frosted branded panel for high-contrast “poster” screenshots.
struct PosterGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = Theme.CornerRadius.large
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(Theme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Theme.primaryAccent.opacity(0.65), Theme.textPrimary.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
            }
    }
}

struct PosterHeroHeader: View {
    let kicker: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(kicker.uppercased())
                .font(Theme.Typography.exo2SemiBold(size: 11))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Text(title.uppercased())
                .font(Theme.Typography.drukTitle)
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.85)
                .lineLimit(2)
            Text(subtitle)
                .font(Theme.Typography.exo2Headline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PosterCaptionPill: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typography.exo2Caption)
            .fontWeight(.semibold)
            .foregroundStyle(Theme.textPrimary.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Theme.surfaceElevated)
                    .overlay {
                        Capsule().stroke(Theme.primaryAccent.opacity(0.35), lineWidth: 1)
                    }
            )
    }
}

// MARK: - VESC-aligned telemetry tiles (demo / bridge UI; wire to BLE later)

struct VESCStyleTelemetryDashboard: View {
    let rpm: Double
    let dutyFraction: Double
    let volts: Double
    let motorAmps: Double
    let batteryAmps: Double
    let mosTempC: Double
    let motorTempC: Double
    /// When false, show muted placeholder typography (still readable on posters).
    let isLive: Bool

    private var dutyPercent: Double { dutyFraction * 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Motor stack")
                    .font(Theme.Typography.exo2SemiBold(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                PosterCaptionPill(text: "VESC-aligned")
                Spacer()
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Theme.Spacing.sm),
                    GridItem(.flexible(), spacing: Theme.Spacing.sm)
                ],
                spacing: Theme.Spacing.sm
            ) {
                metricTile(title: "eRPM", value: fmtInt(rpm), unit: "")
                metricTile(title: "Duty", value: fmt1(dutyPercent), unit: "%")
                metricTile(title: "Vbat", value: volts.isNaN ? "—" : fmt1(volts), unit: volts.isNaN ? "" : "V")
                metricTile(title: "I mot", value: fmt1(motorAmps), unit: "A")
                metricTile(title: "I in", value: fmt1(batteryAmps), unit: "A")
                metricTile(title: "Thermal", value: thermalLine, unit: "")
            }
        }
        .padding(.top, Theme.Spacing.xs)
        .opacity(isLive ? 1 : 0.55)
    }

    private var thermalLine: String {
        if mosTempC.isNaN && motorTempC.isNaN { return "—" }
        let m = mosTempC.isNaN ? "—" : fmt0(mosTempC)
        let mc = motorTempC.isNaN ? "—" : fmt0(motorTempC)
        return "MOSFET \(m)° · motor \(mc)°"
    }

    private func metricTile(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.Typography.exo2Caption)
                .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.Typography.exo2MetricMedium)
                    .foregroundStyle(isLive ? Theme.textPrimary : Theme.textSecondary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(Theme.Typography.exo2Caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func fmt0(_ x: Double) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: x), number: .decimal)
        return n
    }

    private func fmt1(_ x: Double) -> String {
        if x.isNaN || x.isInfinite { return "—" }
        return String(format: "%.1f", x)
    }

    private func fmtInt(_ x: Double) -> String {
        if x.isNaN || x.isInfinite { return "—" }
        return String(format: "%.0f", x)
    }
}

/// Convenience for animated demo waveform while the real serial bridge is disconnected.
enum MockVESCWave {
    static func sample(at t: TimeInterval) -> (
        rpm: Double,
        dutyFraction: Double,
        vb: Double,
        imotor: Double,
        iin: Double,
        tmos: Double,
        tmotor: Double
    ) {
        let s = sin(t * 2.1)
        let c = cos(t * 1.35)
        return (
            rpm: 800 + s * 400 + c * 120,
            dutyFraction: min(1, max(-1, (0.08 + (s + 1) / 7 * (0.42 + c * 0.05)))),
            vb: 48.8 + sin(t * 0.8) * 0.35,
            imotor: 10 + s * 8 + abs(c) * 2,
            iin: 6 + cos(t * 2) * 7,
            tmos: 37 + sin(t * 0.55) * 8,
            tmotor: 41 + cos(t * 0.72) * 10
        )
    }
}

// MARK: - Multi-phase drill “load ladder” for posters

extension DrillPhase {
    /// Rough scalar for charting phase-to-phase variability (poster visualization only).
    fileprivate var posterIntensity01: Double {
        if drillType == .forceDrill {
            switch forceType {
            case .constant:
                if liveVariation {
                    let mn = constantForceN ?? 0
                    let mx = constantForceMaxN ?? mn
                    let mid = (mn + mx) / 2
                    return Double(min(450.0, max(25.0, mid)))
                }
                return Double(constantForceN ?? 40)
            case .percentile:
                let p = forcePercentOfBaseline ?? 85
                let px = forcePercentOfBaselineMax ?? (p + 5)
                if liveVariation { return Double((px + p) / 2) }
                return Double(max(55, min(155, p)))
            }
        }
        // Speed: map distance or duration hint to bar height — visual only.
        if let dv = durationValue {
            switch durationUnit ?? .meters {
            case .seconds: return dv * 4
            case .meters, .yards:
                let m = durationUnit == .yards ? dv * 0.9144 : dv
                return m * 5
            }
        }
        if let dm = distanceMeters { return dm * 8 }
        if let tt = targetTimeSeconds { return tt * 18 }
        return 72
    }
}

struct DrillPhasesPosterTimeline: View {
    let phases: [DrillPhase]

    private struct Row: Identifiable {
        let id: UUID
        let index: Int
        let intensity: Double
        let subtitle: String
    }

    private var rows: [Row] {
        let pts = phases.map(\.posterIntensity01)
        let denom = pts.max() ?? 1
        return zip(phases.indices, phases).map { i, phase in
            Row(
                id: phase.id,
                index: i + 1,
                intensity: (pts[i] / max(denom, 1)),
                subtitle: subtitle(for: phase)
            )
        }
    }

    private func subtitle(for p: DrillPhase) -> String {
        if p.drillType == .forceDrill {
            switch p.forceType {
            case .constant:
                if p.liveVariation {
                    return String(format: "Force %.0f–%.0f N", p.constantForceN ?? 0, p.constantForceMaxN ?? 0)
                }
                return String(format: "Force %.0f N", p.constantForceN ?? 0)
            case .percentile:
                if p.liveVariation {
                    return String(
                        format: "Baseline %.0f–%.0f %%",
                        p.forcePercentOfBaseline ?? 0,
                        p.forcePercentOfBaselineMax ?? 0
                    )
                }
                return String(format: "Baseline %.0f %%", p.forcePercentOfBaseline ?? 0)
            }
        }
        switch p.drillType {
        case .speedDrill:
            if let dm = p.distanceMeters {
                return String(format: "%.1f m", dm)
            }
            return String(describing: p.drillType)
        default:
            return p.drillType.rawValue.uppercased()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("phase load ladder")
                    .font(Theme.Typography.exo2SemiBold(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                PosterCaptionPill(text: drillStyle)
                Spacer()
            }

            Chart(rows) { row in
                BarMark(
                    xStart: .value("start", Double(row.index) - 0.42),
                    xEnd: .value("end", Double(row.index) + 0.42),
                    y: .value("load", row.intensity),
                    height: .ratio(0.88)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.secondaryAccent.opacity(0.95), Theme.deepBlue.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .annotation(position: .top, spacing: 4) {
                    Text("P\(row.index)")
                        .font(Theme.Typography.exo2Caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .chartXScale(domain: 0.45 ... Double(rows.count + 1) + 0.45)
            .chartYScale(domain: 0 ... 1.06)
            .chartPlotStyle { plot in plot.background(Color.clear) }
            .chartXAxis {
                AxisMarks(values: .stride(by: 1)) { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(d == 0 ? "low" : (d == 1 ? "high" : "mid"))
                                .font(Theme.Typography.exo2Caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .frame(height: min(200, 48 + CGFloat(rows.count) * 22))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text("Phase \(row.index)")
                            .font(Theme.Typography.exo2Caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 68, alignment: .leading)
                        Text(row.subtitle)
                            .font(Theme.Typography.exo2Caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var drillStyle: String {
        if phases.contains(where: { $0.drillType == .forceDrill }) { return "force / torque" }
        return "speed"
    }
}
