import SwiftUI
import TickerCore

/// The Settings window's content: a grouped form in the style Sniffcast uses,
/// so the two menu bar apps' settings look like siblings.
///
/// `TickerSettings` is spelled out in full throughout, because SwiftUI
/// has a `Settings` of its own and this is the one file that sees both.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(ErrorText.displayLabel,
                       selection: choice(SettingsForm.display, \.display)) {
                    titles(SettingsForm.display)
                }
                .pickerStyle(.segmented)
                Picker(ErrorText.intervalLabel,
                       selection: choice(SettingsForm.interval, \.refreshIntervalSeconds)) {
                    titles(SettingsForm.interval)
                }
                Text(model.effectiveInterval)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(ErrorText.schemeLabel, selection: choice(SettingsForm.scheme, \.colorScheme)) {
                    titles(SettingsForm.scheme)
                }
                Picker(ErrorText.motionLabel, selection: choice(SettingsForm.motion, \.motionMode)) {
                    titles(SettingsForm.motion)
                }
                .pickerStyle(.segmented)
                // Flip is its own motion, so Scroll and Step have nothing to
                // say while it is on. Disabled rather than hidden: the control
                // keeps its place in the form, and the stored choice is
                // untouched and comes back when the user leaves Flip.
                .disabled(DisplayMode(setting: model.settings.display) == .flip)
                // R143: the decoder's clamps, not numbers typed again here.
                // Sliders are continuous, so the strip previews as the handle
                // moves; the write to disk is coalesced by the controller.
                Slider(value: number(\.maxVisibleWidth), in: TickerSettings.widthRange) {
                    Text(ErrorText.widthLabel)
                }
                Slider(value: number(\.scrollPointsPerSecond), in: TickerSettings.speedRange) {
                    Text(ErrorText.speedLabel)
                }
            }

            Section {
                Toggle(ErrorText.launchAtLoginLabel, isOn: Binding(
                    get: { model.loginState.isOn },
                    set: { model.setLaunchAtLogin($0) }))
                    .disabled(!model.loginState.isEnabled)
                if let note = model.loginNote {
                    // A refusal is news, and red like Sniffcast's; the two
                    // standing states are only explanation.
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(model.loginFailure == nil ? Color.secondary : Color.red)
                }
                if model.loginState.showsSystemSettingsButton {
                    Button(ErrorText.openLoginItems) { model.openLoginItems() }
                }
                // Hidden rather than disabled, unlike the Motion picker
                // above: a greyed-out Motion still tells the user Squiggle
                // can scroll, whereas a greyed-out update check in a build
                // that has no bundle tells them nothing they can act on.
                if model.showsUpdates {
                    Toggle(ErrorText.automaticUpdatesLabel,
                           isOn: $model.checksForUpdatesAutomatically)
                    Button(ErrorText.checkForUpdates) { model.checkForUpdates() }
                }
            }

            Section {
                HStack {
                    if let versionLine = model.versionLine {
                        Text(versionLine).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(ErrorText.pricesCredit, destination: URL(string: ErrorText.yahooFinanceURL)!)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Bindings

    /// A fixed-choice control bound through its row index, so that a stored
    /// value this window does not offer (R119) still selects the fallback's
    /// row rather than nothing.
    private func choice<Value>(_ choice: Choice<Value>,
                               _ keyPath: WritableKeyPath<TickerSettings, Value>) -> Binding<Int> {
        Binding(get: { choice.index(of: model.settings[keyPath: keyPath]) },
                set: { index in model.edit { $0[keyPath: keyPath] = choice.value(at: index) } })
    }

    private func number(_ keyPath: WritableKeyPath<TickerSettings, Double>) -> Binding<Double> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.edit { $0[keyPath: keyPath] = value } })
    }

    private func titles<Value>(_ choice: Choice<Value>) -> some View {
        ForEach(Array(choice.titles.enumerated()), id: \.offset) { index, title in
            Text(title).tag(index)
        }
    }
}
