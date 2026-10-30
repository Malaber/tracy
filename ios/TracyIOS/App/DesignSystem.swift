import SwiftUI

/// Content stays opaque; the system owns glass navigation and control surfaces.
struct TracyListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .labelStyle(.titleAndIcon)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))

    }
}

struct MetricIcon: View {
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.10), in: Circle())
            .accessibilityHidden(true)
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        LabeledContent {
            Text(value).monospacedDigit().foregroundStyle(Color.primary)
        } label: {
            Label { Text(title).foregroundStyle(Color.primary) } icon: { MetricIcon(symbol: symbol) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct ActionRow: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            MetricIcon(symbol: symbol, tint: Color("AccentColor"))
            Text(title).foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Keep the editor's commit action visible in Duo's vertical toolbar.
extension ToolbarItemPlacement {
    static var editorConfirmation: ToolbarItemPlacement {
        if #available(iOS 27.0, *) { .topBarPinnedTrailing } else { .confirmationAction }
    }
}
