import Accessibility
import Charts
import MeshChatCore
import SwiftUI

/// A repeater's last 3 hours: packets it passed on that reached you, in 10-minute steps.
struct ActivitySection: View {
    let activity: [Int]

    private static let minutes = Int(RepeaterAnalysis.activityBucket / 60)

    var body: some View {
        let total = activity.reduce(0, +), peak = activity.max() ?? 0
        let n = activity.count, m = Self.minutes
        Section {
            if total == 0 {
                Text("Nothing passed on in the last 3 hours.").foregroundStyle(.secondary)
            } else {
                Chart(Array(activity.enumerated()), id: \.offset) { i, count in
                    // minutes before now, as negative numbers so now is on the right; a 2 pt gap between bars
                    RectangleMark(xStart: .value("From", Double(-(n - i) * m) + 0.6), xEnd: .value("To", Double(-(n - 1 - i) * m) - 0.6),
                                  yStart: .value("None", 0), yEnd: .value("Packets", count))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                }
                .chartXScale(domain: Double(-n * m)...0)
                .chartXAxis {
                    AxisMarks(values: stride(from: -n * m, through: 0, by: 60).map(Double.init)) { v in
                        let d = v.as(Double.self) ?? 0
                        AxisGridLine()
                        // the ends anchored inwards, so "3 h ago" and "now" aren't dropped at the edges
                        AxisValueLabel(anchor: d == 0 ? .topTrailing : d == Double(-n * m) ? .topLeading : .top) {
                            Text(d == 0 ? String(localized: "now") : d == Double(-n * m) ? String(localized: "\(Int(-d) / 60) h ago") : "\(Int(-d) / 60) h")
                        }
                    }
                }
                .chartYScale(domain: 0...max(4, peak))
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Packets passed on per 10 minutes over the last 3 hours")
                .accessibilityValue([total == 1 ? String(localized: "1 packet") : String(localized: "\(total) packets"),
                                     String(localized: "busiest \(peak) in 10 minutes")].joined(separator: ", "))
            }
        } header: {
            Text("Last 3 hours")
        } footer: {
            Text("Packets it passed on that reached you, in 10-minute steps.")
        }
    }
}

/// How strongly a repeater reaches your radio, as the web app shows it: each packet heard straight
/// from it and a running median through them, over bands for the signal levels at the radio's
/// spreading factor; then the latest against the decode limit, and whether it hears you.
struct SignalSection: View {
    let chart: SignalChartModel
    /// packets heard straight from it in the period (the chart shows the newest 500)
    let heard: Int
    let days: Int
    let heardYou: Int
    let heardYouLast: Date?
    let direct: Bool

    var body: some View {
        Section {
            if !chart.points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(heardLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SignalChartView(chart: chart)
                }
            }
        } header: {
            Text("Signal at your radio")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let r = chart.reading { Text(r) }
                if let h = SignalChartModel.hearsYou(count: heardYou, last: heardYouLast, direct: direct) { Text(h) }
                if chart.spreadingFactor == nil, !chart.points.isEmpty { Text("Connect your radio to see signal levels for its settings.") }
            }
        }
    }

    /// "12 packets heard straight from it, last 7 days"
    private var heardLine: String {
        let count = heard == 1 ? String(localized: "1 packet heard straight from it") : String(localized: "\(heard) packets heard straight from it")
        let period = days == 1 ? String(localized: "last 24 hours") : String(localized: "last \(days) days")
        return "\(count), \(period)"
    }
}

/// The chart itself. It owns the selection, so dragging redraws only this.
struct SignalChartView: View {
    let chart: SignalChartModel
    @State private var picked: Date?

    private static let height: CGFloat = 200

    var body: some View {
        let selected = picked.flatMap { chart.nearest(to: $0) }
        let spanDays = chart.domain.upperBound.timeIntervalSince(chart.domain.lowerBound) > 20 * 3600
        Chart {
            // the signal levels, behind everything (fair left plain, so the four read apart)
            ForEach(chart.bands, id: \.level) { b in
                RectangleMark(yStart: .value("From", b.from), yEnd: .value("To", b.to))
                    .foregroundStyle(SignalPalette.band(b.level))
            }
            // where decoding stops at this spreading factor
            if let floor = chart.floor {
                RuleMark(y: .value("Decode limit", floor))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(Array(chart.points.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("Time", p.date), y: .value("SNR", p.snr))
                    .symbolSize(36)
                    .foregroundStyle(SignalPalette.signal.opacity(0.45))
            }
            ForEach(Array(chart.points.enumerated()), id: \.offset) { i, p in
                LineMark(x: .value("Time", p.date), y: .value("SNR", chart.trend[i]), series: .value("Series", "median"))
                    .foregroundStyle(SignalPalette.signal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            // the median now, at the line's end
            if let last = chart.points.last, let t = chart.trend.last {
                PointMark(x: .value("Time", last.date), y: .value("SNR", t))
                    .symbolSize(1)
                    .foregroundStyle(.clear)
                    .annotation(position: .trailing, spacing: 6, overflowResolution: .init(x: .disabled, y: .fit(to: .plot))) {
                        Text("\(SignalChartModel.db(t)) dB").font(.caption.weight(.medium)).monospacedDigit()
                    }
            }
            // each band named at its top left, over the dots
            ForEach(chart.bands.filter { ($0.to - $0.from) / (chart.hi - chart.lo) * (Self.height - 25) >= 14 }, id: \.level) { b in
                RectangleMark(yStart: .value("From", b.from), yEnd: .value("To", b.to))
                    .foregroundStyle(.clear)
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                        Text(bandName(b.level))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .background(SignalPalette.labelBacking, in: .rect(cornerRadius: 3))
                            .padding(3)
                    }
            }
            if let i = selected {
                let p = chart.points[i]
                RuleMark(x: .value("Time", p.date))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .annotation(position: .overlay, alignment: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(p)
                    }
                PointMark(x: .value("Time", p.date), y: .value("SNR", p.snr))
                    .symbolSize(90)
                    .foregroundStyle(SignalPalette.signal)
            }
        }
        .chartYScale(domain: chart.lo...chart.hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: chart.ticks) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(SignalChartModel.db(d)) } }
            }
        }
        .chartXScale(domain: chart.domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(spanDays ? d.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : d.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
        }
        .chartXSelection(value: $picked)
        .padding(.trailing, 46)
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.accessibilitySummary)
        .accessibilityChartDescriptor(SignalChartDescriptor(chart: chart))
    }

    private func bandName(_ level: SignalLevel) -> String {
        guard level == .below, let floor = chart.floor, let sf = chart.spreadingFactor else { return level.name }
        return String(localized: "below the decode limit (\(SignalChartModel.db(floor)) dB at SF\(sf))")
    }

    private func tooltip(_ p: RepeaterAnalysis.SignalPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(SignalChartModel.db(p.snr)) dB").font(.subheadline.weight(.semibold))
                + Text(" SNR" + (chart.level(p.snr).map { " · \($0.name)" } ?? "")).foregroundStyle(.secondary)
            Text("\(p.rssi) dBm · \(p.type) · \(p.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }
}

/// The audio graph and VoiceOver's chart details: SNR over time, each packet with its level.
private struct SignalChartDescriptor: AXChartDescriptorRepresentable {
    let chart: SignalChartModel

    func makeChartDescriptor() -> AXChartDescriptor {
        let from = chart.domain.lowerBound.timeIntervalSince1970, to = chart.domain.upperBound.timeIntervalSince1970
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Time"), range: from...max(to, from + 1), gridlinePositions: []) { v in
            Date(timeIntervalSince1970: v).formatted(date: .abbreviated, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(title: "SNR", range: chart.lo...chart.hi, gridlinePositions: chart.ticks) { v in
            "\(SignalChartModel.db(v)) dB"
        }
        let series = AXDataSeriesDescriptor(name: String(localized: "Packets heard straight from it"), isContinuous: false, dataPoints: chart.points.map { p in
            AXDataPoint(x: p.date.timeIntervalSince1970, y: p.snr, additionalValues: [], label: chart.level(p.snr)?.name ?? p.type)
        })
        return AXChartDescriptor(title: String(localized: "Signal at your radio"), summary: chart.accessibilitySummary, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}

/// The web app's signal colours, light and dark.
enum SignalPalette {
    static let signal = adaptive(light: (5, 150, 105, 1), dark: (18, 168, 116, 1))

    static func band(_ level: SignalLevel) -> Color {
        switch level {
        case .below: adaptive(light: (239, 68, 68, 0.11), dark: (239, 68, 68, 0.16))
        case .marginal: adaptive(light: (245, 158, 11, 0.13), dark: (245, 158, 11, 0.15))
        case .fair: .clear
        case .good: adaptive(light: (16, 185, 129, 0.08), dark: (16, 185, 129, 0.11))
        }
    }

    /// behind a band's name: the list cell's own colour, so the words stay readable over the dots
    static var labelBacking: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7)
        #else
        Color(nsColor: .controlBackgroundColor).opacity(0.7)
        #endif
    }

    private static func adaptive(light l: (Double, Double, Double, Double), dark d: (Double, Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3)
        })
        #else
        Color(red: l.0 / 255, green: l.1 / 255, blue: l.2 / 255, opacity: l.3)
        #endif
    }
}

extension AppModel {
    /// The radio's spreading factor, or the last one known while it isn't connected; nil if never
    /// known (signal levels depend on it, so it isn't guessed).
    var knownSpreadingFactor: Int? {
        if let sf = me?.radio.spreadingFactor {
            if UserDefaults.standard.integer(forKey: "lastSpreadingFactor") != sf { UserDefaults.standard.set(sf, forKey: "lastSpreadingFactor") }
            return sf
        }
        let sf = UserDefaults.standard.integer(forKey: "lastSpreadingFactor")
        return sf > 0 ? sf : nil
    }
}
