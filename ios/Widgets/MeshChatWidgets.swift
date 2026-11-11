import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MeshChatWidgets: WidgetBundle {
    var body: some Widget {
        RadioLiveActivity()
    }
}

typealias Status = RadioActivityAttributes.ContentState

/// The radio's status, always in view: lock screen (and the always-on display), Dynamic Island, StandBy.
struct RadioLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RadioActivityAttributes.self) { context in
            LockScreenStatus(context: context)
                // dark glass: the lock screen draws text light, whatever the wallpaper
                .activityBackgroundTint(Color.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
        } dynamicIsland: { context in
            let s = context.state, a = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            LinkIcon(link: s.link)
                            Text(a.radio).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        Text(a.transport).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        UnreadCapsule(unread: s.unread, mention: s.msg?.mention == true)
                        if let mv = s.batteryMv { Battery(mv: mv).font(.caption2) }
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if s.link == .offline {
                            OfflineLine(since: s.since)
                        } else {
                            HStack(spacing: 10) {
                                if let rate = s.rate { Sparkline(rate: rate).frame(width: 60, height: 14) }
                                if let n = s.repeaters {
                                    HStack(spacing: 4) { Image(systemName: "arrow.triangle.branch"); Text("\(n) rpt").monospacedDigit() }.font(.caption2)
                                }
                                Spacer(minLength: 0)
                                if let snr = s.snr { SignalBars(snr: snr, level: s.level ?? 0).font(.caption2) }
                            }
                            .foregroundStyle(.secondary)
                        }
                        MessageRow(state: s, gutter: 0)
                    }
                    .padding(.horizontal, 6)   // clear of the island's rounded corners
                }
            } compactLeading: {
                LinkIcon(link: s.link)
            } compactTrailing: {
                if s.unread > 0 {
                    HStack(spacing: 1) {
                        if s.msg?.mention == true { Image(systemName: "at").font(.caption2) }
                        Text("\(s.unread)").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.tint)
                } else if let level = s.level {
                    Image(systemName: "cellularbars", variableValue: Double(level) / 3)
                } else {
                    Image(systemName: "checkmark").font(.caption2)
                }
            } minimal: {
                if s.unread > 0 {
                    Text("\(s.unread)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.tint)
                } else if s.link == .offline || s.rptQuiet == true {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    LinkIcon(link: s.link)
                }
            }
            .keylineTint(.green)
        }
    }
}

// MARK: the lock screen

/// The lock screen's grid: graphics (icons, the sparkline) on the left edge; all text of rows 1 and 3
/// one icon slot in; one trailing column, right-aligned, shared by the battery and unread count, the
/// signal and the message's time.
enum Grid {
    /// the icon slot left of the text
    static let icon: CGFloat = 22, gap: CGFloat = 8
    static var text: CGFloat { icon + gap }
    /// the side columns of the mesh row, and the time slot
    static let side: CGFloat = 92
}

/// Three rows, about 150 pt: who you're connected to (and the battery, and what waits); the mesh at a
/// glance (packets over the hour, repeaters heard, signal); the newest unread message.
///
/// ```
/// ((•))  meshcore.local                   ▮▮▯ 3.95 V
///        WiFi · connected 2 hours ago          @ 3
/// ▁▂▁▄▆▃▁▁▂▅▃▂  ⑂ 4 repeaters           ▂▄▆ +7 dB
/// 60 pkts/h · 20:41  Olsztyn Jura RPT          good
///   @    Ania in Public               4 minutes ago
///        Anyone hearing the new repeater on the hill?…
/// ```
struct LockScreenStatus: View {
    let context: ActivityViewContext<RadioActivityAttributes>
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let s = context.state, a = context.attributes
        let stale = context.isStale || s.link == .paused
        VStack(alignment: .leading, spacing: 8) {
            // 1: the radio
            HStack(alignment: .firstTextBaseline, spacing: Grid.gap) {
                LinkIcon(link: s.link).font(.body).frame(width: Grid.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.radio).font(.headline).lineLimit(1)
                    subtitle(s, a, stale: stale).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    if let mv = s.batteryMv { Battery(mv: mv).font(.caption).foregroundStyle(.secondary) }
                    UnreadCapsule(unread: s.unread, mention: s.msg?.mention == true)
                }
                .layoutPriority(1)
            }
            // 2: the mesh
            if s.link == .offline {
                OfflineLine(since: s.since)
            } else {
                MeshStrip(state: s)
                    .opacity(s.link == .connecting || stale ? 0.5 : 1)
            }
            // 3: the newest message, or how your last went
            MessageRow(state: s)
                .opacity(s.link == .connecting ? 0.5 : 1)
        }
        .padding(12)
        .tint(dimmed ? .primary : .accentColor)
    }

    @ViewBuilder private func subtitle(_ s: Status, _ a: RadioActivityAttributes, stale: Bool) -> some View {
        switch s.link {
        case .connected where stale:
            if let at = s.heardAt { Text("\(a.transport) · as of \(at.formatted(date: .omitted, time: .shortened))") }
            else { Text("\(a.transport) · open MeshChat to update") }
        case .connected:
            if let since = s.since { HStack(spacing: 3) { Text("\(a.transport) · connected"); Ago(date: since, alignment: .leading) } }
            else { Text("\(a.transport) · connected") }
        case .paused:
            Text("Paused in the background · \(a.radio) keeps messages")
        case .connecting:
            Text("Connecting over \(a.transport)…")
        case .offline:
            Text("\(a.transport) · not connected")
        }
    }
}

/// Packets over the hour, repeaters heard directly (or your repeater gone quiet), the signal lately.
struct MeshStrip: View {
    let state: Status

    var body: some View { strip(state, labels: true) }

    /// `92 | flexible | 92`: the packets column on the left edge, the repeaters in the middle, the
    /// signal right-aligned under the battery and unread count. Labels align as their values do.
    private func strip(_ s: Status, labels: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            cell(width: Grid.side) {
                if let rate = s.rate { Sparkline(rate: rate).frame(width: Grid.side, height: 18) } else { Text("—").font(.subheadline) }
            } label: {
                if labels {
                    HStack(spacing: 3) {
                        Text("\(s.perHour ?? 0) pkts/h")
                        if let at = s.heardAt { Text("· \(at.formatted(date: .omitted, time: .shortened))") }
                    }
                }
            }
            cell {
                if s.rptQuiet == true, let name = s.rptName {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(name) quiet").lineLimit(1).truncationMode(.middle)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(s.repeaters == 1 ? "1 repeater" : "\(s.repeaters ?? 0) repeaters").monospacedDigit().lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .minimumScaleFactor(0.85)
                }
            } label: {
                if labels, let name = s.rptName {
                    Text(name).lineLimit(1)
                } else if labels {
                    Text("heard directly, 30 min")
                }
            }
            cell(width: Grid.side, align: .trailing) {
                if let snr = s.snr { SignalBars(snr: snr, level: s.level ?? 0).font(.subheadline.weight(.semibold)) }
                else { Text("no signal").font(.subheadline).foregroundStyle(.secondary) }
            } label: {
                if labels, let level = s.level {
                    Text([String(localized: "below the floor"), String(localized: "weak"), String(localized: "marginal"), String(localized: "good")][max(0, min(3, level))])
                }
            }
        }
    }

    /// A value over its label; a fixed `width` for the side columns, else it takes what's left.
    private func cell<V: View, L: View>(width: CGFloat? = nil, align: HorizontalAlignment = .leading,
                                        @ViewBuilder _ value: () -> V, @ViewBuilder label: () -> L) -> some View {
        VStack(alignment: align, spacing: 2) {
            value().frame(height: 20, alignment: Alignment(horizontal: align, vertical: .center))   // labels on one baseline
            label().font(.caption2).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
        .frame(width: width, alignment: Alignment(horizontal: align, vertical: .top))
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// The newest unread message (who, where, when, the text), or else how your last message went. The kind
/// glyph sits in the icon slot (`gutter`), so sender and text start where row 1's text does; the time
/// ends at the trailing column's edge. The Dynamic Island has no room for a slot: `gutter: 0`.
struct MessageRow: View {
    let state: Status
    var gutter: CGFloat = Grid.icon

    var body: some View {
        let spacing = gutter > 0 ? Grid.gap : 4
        if let m = state.msg {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: spacing) {
                    Image(systemName: m.mention ? "at" : m.kind == .direct ? "person.fill" : m.kind == .room ? "person.3.fill" : "number")
                        .font(.caption).foregroundStyle(.tint)
                        .frame(width: gutter > 0 ? gutter : nil)
                        .accessibilityLabel(m.mention ? "Mention" : m.kind == .direct ? "Direct message" : m.kind == .room ? "Room" : "Channel")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(m.from).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let place = m.place { Text("in \(place)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Ago(date: m.at).font(.caption).foregroundStyle(.secondary)
                }
                if let t = m.text {
                    Text(t).font(.subheadline).lineLimit(2).padding(.leading, gutter > 0 ? Grid.text : 0)
                }
            }
        } else if let sent = state.sent {
            HStack(alignment: .firstTextBaseline, spacing: spacing) {
                Image(systemName: sent.ok == true ? "checkmark.circle.fill" : sent.ok == false ? "exclamationmark.circle.fill" : "clock")
                    .foregroundStyle(sent.ok == true ? Color.green : sent.ok == false ? .orange : .secondary)
                    .frame(width: gutter > 0 ? gutter : nil)
                Text("Your last message: \(sent.status)").font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                Ago(date: sent.at).font(.caption).foregroundStyle(.secondary)
            }
        }
        // nothing unread and nothing sent lately: no row at all (the card gets shorter)
    }
}

// MARK: pieces

struct LinkIcon: View {
    let link: Status.Link

    var body: some View {
        switch link {
        case .connected: Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green).accessibilityLabel("Connected")
        case .connecting: Image(systemName: "hourglass").foregroundStyle(.secondary).accessibilityLabel("Connecting")
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.orange).accessibilityLabel("Paused")
        case .offline: Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary).accessibilityLabel("Not connected")
        }
    }
}

/// "3 unread" in a capsule (with @ when the newest mentions you), or a quiet "all read".
struct UnreadCapsule: View {
    let unread: Int
    let mention: Bool

    var body: some View {
        if unread > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: mention ? "at" : "bubble.left.fill").imageScale(.small)
                Text("\(unread)").monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.tint.opacity(0.18), in: .capsule)
            .foregroundStyle(.tint)
            .accessibilityLabel(unread == 1
                                ? (mention ? String(localized: "1 unread conversation, mentions you") : String(localized: "1 unread conversation"))
                                : (mention ? String(localized: "\(unread) unread conversations, mentions you") : String(localized: "\(unread) unread conversations")))
        } else {
            Text("All read").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Volts and a battery symbol (no percentage: it depends on the battery).
struct Battery: View {
    let mv: Int

    var body: some View {
        let v = Double(mv) / 1000
        let symbol = v >= 4.0 ? "battery.100" : v >= 3.8 ? "battery.75" : v >= 3.6 ? "battery.50" : v >= 3.4 ? "battery.25" : "battery.0"
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(String(format: "%.2f V", v)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Signal bars filled by how far above the decode floor, and the dB.
struct SignalBars: View {
    let snr: Int
    let level: Int

    var body: some View {
        let name = [String(localized: "below the floor"), String(localized: "weak"), String(localized: "marginal"), String(localized: "good")][max(0, min(3, level))]
        HStack(spacing: 3) {
            Image(systemName: "cellularbars", variableValue: Double(level) / 3)
            Text("\(snr > 0 ? "+" : "")\(snr) dB").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(snr) decibels, \(name)")
    }
}

/// Packets per 5 minutes over the hour, as 12 small bars (the newest on the right).
struct Sparkline: View {
    let rate: [UInt8]
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let top = Double(max(rate.max() ?? 0, 4))
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(rate.enumerated()), id: \.offset) { _, n in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(dimmed || n == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                        .frame(height: max(2, g.size.height * Double(n) / top))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement()
        .accessibilityLabel("\(rate.reduce(0) { $0 + Int($1) }) packets in the last hour")
    }
}

struct OfflineLine: View {
    let since: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Grid.gap) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").frame(width: Grid.icon)
            if let since { Text("Not connected since \(since.formatted(date: .omitted, time: .shortened)) · open MeshChat to reconnect") }
            else { Text("Not connected · open MeshChat to reconnect") }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
}

/// "4 minutes ago" (iOS 18 and later: whole minutes or hours, ticking by itself), or the older relative
/// text, in a fixed slot the width of the side columns.
struct Ago: View {
    let date: Date
    var alignment: Alignment = .trailing

    var body: some View {
        // text that updates itself takes all the width it's offered: a fixed slot keeps the rest of the row
        Group {
            if #available(iOS 18.0, *) {
                Text(.currentDate, format: .reference(to: date, allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
            } else {
                Text(date, style: .relative)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // self-updating text fills its slot and draws from the leading edge: align the text itself
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        .frame(width: Grid.side, alignment: alignment)
    }
}
