import SwiftUI

/// Content stays opaque; the system owns glass navigation and control surfaces.
struct TracyListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .modifier(ReadableScrollEdge())
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
            Text(value).monospacedDigit().foregroundStyle(.primary)
        } label: {
            Label { Text(title) } icon: { MetricIcon(symbol: symbol) }
        }
        .padding(.vertical, 3)
    }
}

struct ActionRow: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            MetricIcon(symbol: symbol, tint: Color("AccentColor"))
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
