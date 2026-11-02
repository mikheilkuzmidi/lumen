import SwiftUI

/// Host-supplied appearance for the assistant surfaces shared by Studio and an editor.
public struct AssistantStyle {
    public var panel: Color
    public var raised: Color
    public var line: Color
    public var primary: Color
    public var secondary: Color
    public var accent: Color
    public var danger: Color
    public var radius: CGFloat

    public init(panel: Color = Color(.sRGB, white: 0.086, opacity: 1),
                raised: Color = Color(.sRGB, white: 0.114, opacity: 1),
                line: Color = Color(.sRGB, white: 0.17, opacity: 1),
                primary: Color = Color(.sRGB, white: 0.91, opacity: 1),
                secondary: Color = Color(.sRGB, white: 0.61, opacity: 1),
                accent: Color = Color(red: 0.949, green: 0.333, blue: 0.165),
                danger: Color = Color(red: 0.925, green: 0.282, blue: 0.408), radius: CGFloat = LumenRadii.panel) {
        self.panel = panel; self.raised = raised; self.line = line
        self.primary = primary; self.secondary = secondary; self.accent = accent
        self.danger = danger; self.radius = radius
    }
}

/// A compact, keyboard-accessible status anchored immediately above the instruction field.
public struct AssistantDock<Prompt: View>: View {
    public var title: String
    public var detail: String
    public var busy: Bool
    public var progress: Double?
    public var reviewShown: Bool
    public var style: AssistantStyle
    public var toggleReview: () -> Void
    @ViewBuilder public var prompt: () -> Prompt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, detail: String = "", busy: Bool = false, progress: Double? = nil,
                reviewShown: Bool = false, style: AssistantStyle = AssistantStyle(),
                toggleReview: @escaping () -> Void, @ViewBuilder prompt: @escaping () -> Prompt) {
        self.title = title; self.detail = detail; self.busy = busy; self.progress = progress
        self.reviewShown = reviewShown; self.style = style; self.toggleReview = toggleReview; self.prompt = prompt
    }

    public var body: some View {
        VStack(spacing: 8) {
            Button(action: toggleReview) {
                HStack(spacing: 10) {
                    if busy { ProgressView().controlSize(.mini).tint(style.accent) }
                    else { Image(systemName: "list.bullet.rectangle").foregroundStyle(style.accent) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(style.primary)
                        if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(style.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 8)
                    Text(reviewShown ? "Hide details" : "Review").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.secondary)
                    Image(systemName: reviewShown ? "sidebar.right" : "sidebar.right").font(.system(size: 12))
                        .foregroundStyle(style.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(style.raised, in: RoundedRectangle(cornerRadius: style.radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: style.radius, style: .continuous).strokeBorder(style.line) }
                .overlay(alignment: .bottomLeading) {
                    if let progress {
                        GeometryReader { geometry in
                            Capsule().fill(style.accent).frame(width: geometry.size.width * min(1, max(0, progress)), height: 2)
                        }.frame(height: 2).padding(.horizontal, style.radius)
                    }
                }
            }
            .buttonStyle(.plain).accessibilityIdentifier("assistantDockReview")
            .accessibilityLabel(title + (detail.isEmpty ? "" : ", " + detail))
            prompt()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: title)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: reviewShown)
    }
}
