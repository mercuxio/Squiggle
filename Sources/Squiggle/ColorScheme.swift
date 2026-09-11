import AppKit
import TickerCore

/// Spec §5.3's three schemes. The same shape as `MotionMode` (Task 9): a
/// lenient `init` from the stored string, because `Settings` keeps these as
/// `String` so that `TickerCore` never has to know what a colour is.
enum ColorScheme: Equatable, Sendable {
    case monochrome
    case classic
    case accessible

    /// Anything unrecognised is Monochrome — the default (R119) and the
    /// accessible answer, so an unreadable setting degrades toward safety
    /// rather than toward a red/green strip somebody cannot read.
    init(setting: String) {
        switch setting {
        case "classic": self = .classic
        case "accessible": self = .accessible
        default: self = .monochrome
        }
    }
}

/// Resolves a `ColorRole` to an `NSColor`. Pure, and deliberately so: every
/// rule spec §5.3 and §7 state about colour is decided here, with no status
/// item, no appearance and no clock in reach.
///
/// What is *not* here is the appearance resolution. `NSColor` is a recipe
/// rather than a colour — it becomes pixels only when something asks for its
/// `cgColor` under a particular appearance — and which appearance to ask under
/// is `StatusItemController`'s business, because the answer is the menu bar's
/// and not the app's.
enum ColorPolicy {
    /// Spec §5.3: `accessibilityDisplayShouldDifferentiateWithoutColor` forces
    /// Monochrome. The user has said, at the system level, that colour must
    /// not be the thing carrying meaning; the glyph already carries it.
    static func effective(requested: ColorScheme,
                          differentiateWithoutColor: Bool) -> ColorScheme {
        differentiateWithoutColor ? .monochrome : requested
    }

    static func color(for role: ColorRole, scheme: ColorScheme, isStale: Bool) -> NSColor {
        // R142 and spec §7: the whole strip dims, deltas included. Checked
        // before the scheme rather than after, because "stale" is a statement
        // about all of it and a green number inside a grey strip would read as
        // the one live thing on the row.
        guard !isStale else { return .tertiaryLabelColor }

        // Exhaustive, no `default:` — a third role must fail the build here.
        switch role {
        case .label:
            // Spec §5.3: colour applies to the delta and percentage only. The
            // symbol is the anchor the eye lands on and must not move in the
            // colour space.
            return .labelColor

        case .direction(let direction):
            switch scheme {
            case .monochrome:
                return .labelColor
            case .classic:
                return Self.pair(direction, up: .systemGreen, down: .systemRed)
            case .accessible:
                // R141: the blue/orange axis, which survives both deuteranopia
                // and protanopia — from the system palette, so both
                // appearances and Increase Contrast keep working.
                return Self.pair(direction, up: .systemBlue, down: .systemOrange)
            }
        }
    }

    /// Spec §5.3: "`.flat` and `.unknown` are never coloured." Written once
    /// here rather than twice in the switch above, so the two schemes cannot
    /// drift on the question of what an uneventful day looks like.
    private static func pair(_ direction: Direction,
                             up: NSColor, down: NSColor) -> NSColor {
        switch direction {
        case .up: return up
        case .down: return down
        case .flat, .unknown: return .labelColor
        }
    }
}
