import SwiftUI

/// A normal Text in production, with intrinsic-height diagnostics only in UI tests.
/// Measures the same string/font at its allocated width without a line limit, so
/// truncated or vertically compressed text needs more height than its rendered box.
struct LayoutCheckedText: View {
    let value: String
    let key: String
    #if DEBUG
        @State private var rendered = CGSize.zero
        @State private var intrinsic = CGSize.zero
    #endif

    init(_ value: String, key: String) {
        self.value = value
        self.key = key
    }

    var body: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-layout-checks") {
                Text(value)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onAppear { rendered = proxy.size }
                                .onChange(of: proxy.size) { _, size in rendered = size }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if rendered.width > 0 {
                            Text(value).lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: rendered.width)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.onAppear { intrinsic = proxy.size }
                                            .onChange(of: proxy.size) { _, size in intrinsic = size }
                                    }
                                }
                                .hidden().accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(value)
                    .accessibilityIdentifier("layout.\(key)")
                    .accessibilityValue(layoutState)
            } else {
                Text(value)
            }
        #else
            Text(value)
        #endif
    }

    #if DEBUG
        private var layoutState: String {
            guard rendered.width > 0, rendered.height > 0, intrinsic.height > 0 else { return "pending" }
            // Allow half a point for pixel rounding, not a whole line of truncation.
            if intrinsic.height <= rendered.height + 0.5 { return "fits" }
            return "clipped: rendered=\(rendered), required=\(intrinsic)"
        }
    #endif
}
