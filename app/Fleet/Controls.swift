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

/// A small capsule with the model family ("OPUS"), coloured per family, so a
/// costly model stands out in the sidebar. Nothing when there is no snapshot.
struct ModelTag: View {
    let session: Session
    var body: some View {
        if let f = session.modelFamily {
            Text(f).font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(session.modelColor)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(session.modelColor.opacity(0.16)))
                .help(session.model ?? "")
        }
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

// MARK: - Brand marks
//
// SF Symbols has no logos. These are the official marks as SVG path data
// (24x24 viewBox) from Simple Icons (simpleicons.org, CC0), drawn by a small
// path parser: lines and cubic curves are all these two need.
enum Brand {
    static let github = "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
    static let claude = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
}

/// An SVG path (M/m L/l H/h V/v C/c S/s Z/z, with implicit repeats and the
/// compact number syntax "-.5-.25") in a 24x24 box, scaled to fit the rect.
struct SVGShape: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
        let s = rect.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        let tokens = SVGShape.tokenize(d)
        var i = 0, cmd: Character = "M"
        func num() -> CGFloat { defer { i += 1 }; return i < tokens.count ? (CGFloat(Double(tokens[i]) ?? 0)) : 0 }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            switch cmd.uppercased() {
            case "M":
                let x = num(), y = num()
                cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                start = cur; p.move(to: pt(cur.x, cur.y)); lastCtrl = nil
                cmd = rel ? "l" : "L"                       // further pairs are lines
            case "L":
                let x = num(), y = num()
                cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                p.addLine(to: pt(cur.x, cur.y)); lastCtrl = nil
            case "H":
                let x = num(); cur.x = rel ? cur.x + x : x
                p.addLine(to: pt(cur.x, cur.y)); lastCtrl = nil
            case "V":
                let y = num(); cur.y = rel ? cur.y + y : y
                p.addLine(to: pt(cur.x, cur.y)); lastCtrl = nil
            case "C":
                let x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num()
                let o = rel ? cur : .zero
                let c1 = CGPoint(x: o.x + x1, y: o.y + y1), c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                cur = CGPoint(x: o.x + x, y: o.y + y)
                p.addCurve(to: pt(cur.x, cur.y), control1: pt(c1.x, c1.y), control2: pt(c2.x, c2.y)); lastCtrl = c2
            case "S":
                let x2 = num(), y2 = num(), x = num(), y = num()
                let o = rel ? cur : .zero
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                cur = CGPoint(x: o.x + x, y: o.y + y)
                p.addCurve(to: pt(cur.x, cur.y), control1: pt(c1.x, c1.y), control2: pt(c2.x, c2.y)); lastCtrl = c2
            case "Z":
                p.closeSubpath(); cur = start; lastCtrl = nil
            default:
                i += 1
            }
        }
        return p
    }
    /// Letters and numbers as separate tokens; "-.5-.25" is two numbers.
    static func tokenize(_ d: String) -> [String] {
        var out: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in d {
            if ch.isLetter { flush(); out.append(String(ch)) }
            else if ch == "-" { flush(); cur = "-" }
            else if ch == "." && cur.contains(".") { flush(); cur = "." }
            else if ch == " " || ch == "," { flush() }
            else { cur.append(ch) }
        }
        flush()
        return out
    }
}
