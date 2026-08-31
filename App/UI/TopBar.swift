import SwiftUI

struct TopBar: View {
    @EnvironmentObject private var session: AmpSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("xzyqrn")
                        .font(AmpTheme.display(22, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(AmpTheme.text)
                    Text("AMP")
                        .font(AmpTheme.display(22, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(AmpTheme.accent)
                }
                Text(session.status)
                    .font(AmpTheme.mono(11))
                    .foregroundStyle(AmpTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            DeviceChip(title: "In", value: session.inputLabel)
                .frame(maxWidth: 180, alignment: .leading)
            DeviceChip(title: "Out", value: session.outputLabel)
                .frame(maxWidth: 180, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "est. %.1f ms", session.latencyMs))
                    .font(AmpTheme.mono(12, weight: .semibold))
                    .foregroundStyle(AmpTheme.text)
                Text(String(format: "%.0f Hz · %d", session.hardwareSampleRate, session.hardwareBuffer))
                    .font(AmpTheme.mono(10))
                    .foregroundStyle(AmpTheme.faint)
            }
            .frame(minWidth: 92, alignment: .trailing)

            PowerButton(isOn: session.isRunning, action: session.togglePower)

            LEDToggle(isOn: $session.bypass, title: session.bypass ? "Bypass" : "Live") {
                session.pushAllParams()
            }

            Menu {
                Button("Practice Lab") { openWindow(id: "practice") }
                Button("Bass Method") { openWindow(id: "bass-method") }
                Button("Bass Tabs") { openWindow(id: "tabs") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.house")
                    Text("STUDIO")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(AmpTheme.label(10))
                .tracking(1.2)
                .foregroundStyle(AmpTheme.text)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(AmpTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AmpTheme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open Practice Lab, lessons, or bass tabs")

            SettingsLink {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AmpTheme.text)
                    .frame(width: 28, height: 28)
                    .background(AmpTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AmpTheme.line, lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            }
            .buttonStyle(.plain)
            .help("Input, output, buffer size")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(AmpTheme.bg.opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AmpTheme.line).frame(height: 1)
        }
    }
}

private struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn ? AmpTheme.accent : AmpTheme.inset)
                    .frame(width: 9, height: 9)
                    .shadow(color: isOn ? AmpTheme.accent.opacity(0.9) : .clear, radius: 7)
                Text(isOn ? "ON" : "POWER")
                    .font(AmpTheme.label(11))
                    .tracking(1.6)
                    .foregroundStyle(isOn ? AmpTheme.bg : AmpTheme.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isOn ? AmpTheme.accent : AmpTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? AmpTheme.accent : AmpTheme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isOn)
    }
}
