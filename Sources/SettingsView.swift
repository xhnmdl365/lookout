// Settings: integrations, AI triage, the naming rule and text sizes.
import SwiftUI
import AppKit

// Settings: which outside tools are set up, the optional session-naming rule, and text sizes
// (one row per kind of text, each with − / + and a sample drawn at the chosen size).
struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject private var sizes = TextSizes.shared
    @State private var ruleInstalled = NamingRule.installed
    @State private var showRule = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading("Integrations")
                if store.integrations.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
                } else {
                    Card(items: store.integrations) { integrationRow($0) }
                }
                Text("Settings of your own, like tool paths or your GitHub org, go in config.json in the app's data folder.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.top, 6)

                heading("AI triage")
                triageCard

                heading("Session naming")
                namingCard

                heading("Text size")
                Card(items: TextRole.allCases) { role in row(role) }
                Button("Reset to defaults") { sizes.reset() }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    .disabled(sizes.isDefault)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .padding(.bottom, 8)
            .overlayScrollers()
        }
        .onAppear { store.checkIntegrations(); ruleInstalled = NamingRule.installed }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func integrationRow(_ i: Integration) -> some View {
        let color: Color = switch i.state {
        case .ready: Palette.done
        case .signedOut: Palette.needsYou
        case .missing: Palette.idle
        }
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(i.name).font(.system(size: 12, weight: .semibold))
                    Text(i.detail).font(.system(size: 11)).foregroundStyle(color)
                }
                Text(i.purpose).font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let fix = i.fix {
                    Text(fix).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // Off by default: Triage spends the user's Claude plan, so it's theirs to turn on.
    private var triageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $store.triageEnabled) {
                Text("Show the Triage button").font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch).controlSize(.small).tint(Palette.claude)
            Text("Triage asks Claude for a one-line verdict on each task in Active, and closes ones with hard evidence. Each run uses your Claude plan, about 10k tokens for a dozen tasks. Off, its verdicts and suggestions are hidden too.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard()
    }

    // The rule lives in the user's own ~/.claude/CLAUDE.md, added or removed only from here.
    private var namingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Have Claude name a session reviewing a teammate's PR \"Team code review: …\", so it's recognised at once. Without it, review sessions are still found from what the session did.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if ruleInstalled {
                    Label("Added to ~/.claude/CLAUDE.md", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.done)
                    Spacer()
                    Button("Remove") { NamingRule.remove(); ruleInstalled = NamingRule.installed }
                } else {
                    Button("Add to ~/.claude/CLAUDE.md") { NamingRule.install(); ruleInstalled = NamingRule.installed }
                        .foregroundStyle(Palette.claude)
                    Spacer()
                }
                Button(showRule ? "Hide rule" : "Show rule") { withAnimation(Motion.change) { showRule.toggle() } }
            }
            .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
            if showRule {
                Text(NamingRule.text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .transition(.opacity)
            }
        }
        .settingsCard()
    }

    private func row(_ role: TextRole) -> some View {
        let size = sizes.size(role)
        let style: AnyShapeStyle = switch role {
        case .count: AnyShapeStyle(Palette.active)
        case .meta: AnyShapeStyle(.tertiary)
        case .detail: AnyShapeStyle(.secondary)
        default: AnyShapeStyle(.primary)
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.label).font(.system(size: 12, weight: .semibold))
                    Text(role.hint).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "minus", help: "Smaller", tint: Palette.claude) { sizes.step(role, by: -0.5) }
                    .disabled(size <= role.base + TextSizes.range.lowerBound)
                Text(String(format: "%g", size))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(size == role.base ? .secondary : .primary)
                    .frame(width: 30)
                IconButton(symbol: "plus", help: "Larger", tint: Palette.claude) { sizes.step(role, by: 0.5) }
                    .disabled(size >= role.base + TextSizes.range.upperBound)
            }
            Text(role.sample)
                .font(.system(size: size, weight: [.title, .header, .count].contains(role) ? .bold : .regular))
                .foregroundStyle(style)
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

private extension View {
    // A settings section's card: a padded, rounded panel.
    func settingsCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
            .padding(.horizontal, 10)
    }
}
