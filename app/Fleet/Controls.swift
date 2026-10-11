import SwiftUI

struct BranchText: View {
    let session: Session
    var body: some View {
        HStack(spacing: 4) {
            Text(session.branch)
            if session.dirty { Text("*").foregroundStyle(.red).help("uncommitted changes") }
            if session.ahead > 0 { Text("↑\(session.ahead)").foregroundStyle(.secondary).help("ahead of upstream") }
            if session.behind > 0 { Text("↓\(session.behind)").foregroundStyle(.secondary).help("behind upstream") }
            if session.upstream.isEmpty && session.name != "main" { Text("no upstream").foregroundStyle(.secondary) }
        }
    }
}

struct StateDot: View {
    let session: Session
    var body: some View {
        Circle().fill(session.dotColor).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.black.opacity(0.08)))
            .help(session.badge)
    }
}

/// The project's app icon (`fleet icon`), else its initials on its own
/// colour, both rounded like an app icon, with the state dot on its corner.
struct ProjectIcon: View {
    @EnvironmentObject var model: FleetModel
    let session: Session
    var size: CGFloat = 28
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image = model.icons[session.projectKey] {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                shape.fill(session.projectColor.gradient)
                    .overlay(Text(session.projectInitials)
                        .font(.system(size: size * (session.projectInitials.count > 1 ? 0.4 : 0.5), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            StateDot(session: session)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                .offset(x: 3, y: 3)
        }
        .task(id: session.projectKey) { model.loadIcon(for: session) }
    }
}

/// Icon above a short caption, both centred: the narrow shape that keeps a
/// row of action buttons on one line in a small window.
struct StackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 5) {
            configuration.icon.font(.title2).frame(height: 24)   // glyph heights differ; keep the captions level
            configuration.title.font(.caption.weight(.semibold))
        }
    }
}

/// One look for every action control: filled colour, stacked label, a shared
/// minimum width so short captions do not make narrower buttons. Used for
/// plain buttons and for the GitHub menu, so they match exactly.
struct FilledStyle: ButtonStyle {
    static let minWidth: CGFloat = 78
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(StackedLabelStyle())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minWidth: Self.minWidth)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(configuration.isPressed ? 0.75 : 1)))
            .opacity(enabled ? 1 : 0.5)
    }
}

/// A coloured action button, with an SF Symbol or a brand mark (SVG path).
struct ActionButton: View {
    let title: String
    var system: String = ""
    var brand: String? = nil
    let tint: Color
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if let d = brand {
                Label { Text(title) } icon: { SVGShape(d: d).fill(.white).frame(width: 22, height: 22) }
            } else {
                Label(title, systemImage: system)
            }
        }
        .buttonStyle(FilledStyle(tint: tint)).help(help)
    }
}
