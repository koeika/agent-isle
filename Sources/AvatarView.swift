import SwiftUI

struct AgentAvatar: View {
    @ObservedObject var preferences: AppPreferences
    var color: Color = .mint
    var statusColor: Color? = nil
    var active = false
    var celebrate = false
    var body: some View {
        AvatarPreview(style: preferences.value.avatarStyle, customLogo: preferences.value.customLogo, color: color, statusColor: statusColor, active: active, celebrate: celebrate)
    }
}

struct AvatarPreview: View {
    let style: String
    var customLogo = ""
    var color: Color = .mint
    var statusColor: Color? = nil
    var active = false
    var celebrate = false
    var body: some View {
        Group {
            if style == "custom", let image = AvatarAssets.image(customLogo) {
                TimelineView(.animation(minimumInterval: 0.18, paused: !active && !celebrate)) { timeline in
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(3)
                        .offset(y: active || celebrate ? sin(timeline.date.timeIntervalSince1970 * 5) * 1.5 : 0)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.6), lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) { Circle().fill(statusColor ?? color).frame(width: 6, height: 6).overlay(Circle().stroke(Color.black, lineWidth: 1)) }
                }
            } else { PixelBuddy(color: color, active: active, celebrate: celebrate, style: AvatarStyle(rawValue: style) ?? .robot) }
        }.frame(width: 40, height: 38).accessibilityLabel(style == "custom" ? "自定义 Logo" : (AvatarStyle(rawValue: style) ?? .robot).title)
    }
}
