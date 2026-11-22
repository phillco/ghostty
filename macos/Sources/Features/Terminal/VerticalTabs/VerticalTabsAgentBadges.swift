import SwiftUI

/// The sidebar's `agentd` indicators: a status mark before the title and a
/// note/child-job badge after it. All static: no animation, so a busy agent
/// costs WindowServer nothing between refreshes.
enum VerticalTabsAgentBadges {
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.0)
    static let working = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let unread = Color(red: 0.2, green: 0.55, blue: 1.0)
    static let done = Color(red: 0.3, green: 0.78, blue: 0.4)

    /// How much of a badge a row has room for.
    enum Detail: Equatable {
        case none
        /// The kind glyph only.
        case glyph
        /// Glyph plus progress and job count.
        case full
    }

    /// The tooltip's status line, nil for idle and plain shells.
    static func statusText(_ row: VerticalTabRow) -> String? {
        switch row.status {
        case .awaiting?:
            return row.awaitingKind.isEmpty ? "Awaiting you" : "Awaiting \(row.awaitingKind)"
        case .working?: return "Working"
        case .unread?: return "Unread reply"
        case .idle?, nil: return nil
        }
    }

    /// The leading-gutter dot: amber awaiting, orange working, blue unread.
    struct StatusDot: View {
        let status: VerticalTabs.Agent.Display
        let metrics: VerticalTabsMetrics

        var body: some View {
            let size = Self.diameter(status: status, metrics: metrics)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .accessibilityLabel(status == .awaiting ? "Awaiting" : status == .working ? "Working" : "Unread")
        }

        /// In proportion to the secondary text, but never wider than the
        /// leading padding it sits in, whatever the two font sizes.
        static func diameter(status: VerticalTabs.Agent.Display, metrics: VerticalTabsMetrics) -> CGFloat {
            let wanted = (metrics.secondarySize * (status == .working ? 0.42 : 0.52)).rounded()
            return max(2, min(wanted, metrics.rowPadding - 2))
        }

        private var color: Color {
            switch status {
            case .awaiting: return amber
            case .working: return working
            case .unread: return unread
            case .idle: return .clear
            }
        }
    }

    /// Takes the platform glyph's place while a session waits on you.
    struct AwaitingMark: View {
        let awaitingKind: String

        var body: some View {
            Image(systemName: awaitingKind == "question" ? "questionmark.circle.fill" : "exclamationmark.circle.fill")
                .fontWeight(.semibold)
                .foregroundStyle(amber)
        }
    }

    /// A note's state glyph, with its progress and the active job count.
    struct BadgeView: View {
        let badge: VerticalTabs.Agent.Badge
        let detail: Detail
        let metrics: VerticalTabsMetrics

        var body: some View {
            let size = metrics.secondarySize
            HStack(spacing: max(2, (size * 0.25).rounded())) {
                if let icon = badge.icon {
                    Text(icon).font(.system(size: size - 1))
                } else if let glyph {
                    Image(systemName: glyph.name)
                        .font(.system(size: size - 1, weight: .semibold))
                        .foregroundStyle(glyph.color)
                }
                if detail == .full || (glyph == nil && badge.icon == nil), let text = badge.text {
                    Text(text)
                        .font(.system(size: size, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, detail == .full && badge.text != nil ? metrics.pillHorizontalPadding : 0)
            .padding(.vertical, metrics.pillVerticalPadding)
            .background(
                Capsule().fill(Color.primary.opacity(detail == .full && badge.text != nil ? 0.08 : 0))
            )
            .fixedSize()
        }

        private var glyph: (name: String, color: Color)? {
            switch badge.kind {
            case .attention?: return ("exclamationmark.triangle.fill", amber)
            case .done?: return ("checkmark", done)
            case .waiting?: return ("hourglass", Color.secondary)
            case .active?, nil: return nil
            }
        }
    }
}
