import Foundation
import TickerCore

/// Every number the user reads, and nothing else: no colour, no sentences
/// (R129), no AppKit. Sentences live in `ErrorText`; colour lives in
/// `ColorScheme`.
enum Formatting {
    /// Spec §7's per-symbol dead state. Two em-dashes, not one: a single `—`
    /// next to a symbol reads as a hyphenated name, and `–` is already the
    /// `.flat` direction glyph.
    static let deadPlaceholder = "——"

    /// Price, with the locale's own separators (R128).
    ///
    /// Non-finite input renders as the dead placeholder rather than "∞": this
    /// is the last function before the menu bar, and the one thing spec §8.2
    /// forbids everywhere is a plausible-but-wrong number reaching the user.
    static func price(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return deadPlaceholder }
        return formatter(locale: locale, fractionDigits: fractionDigits(for: value))
            .string(from: value as NSNumber) ?? deadPlaceholder
    }

    /// The absolute change. The caller prefixes `Direction.glyph`, which is
    /// what carries the sign (R127).
    static func delta(_ change: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let change, change.isFinite else { return "" }
        let magnitude = abs(change)
        // Fixed at two decimals, like `percent` below: unlike `price`, a delta's
        // own magnitude says nothing about the instrument's scale (a $0.42 move
        // on a $232 stock and a $0.42 move on a $0.43 token are both "0.42"),
        // so the sub-$1 four-decimal rule that `price` needs does not apply here.
        return formatter(locale: locale, fractionDigits: 2)
            .string(from: magnitude as NSNumber) ?? ""
    }

    /// The absolute percentage, with its sign carried by the same glyph. Always
    /// two decimals — a percentage's useful range does not vary with the price's
    /// magnitude the way the price itself does.
    static func percent(_ changePercent: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let changePercent, changePercent.isFinite else { return "" }
        guard let text = formatter(locale: locale, fractionDigits: 2)
            .string(from: abs(changePercent) as NSNumber) else { return "" }
        return text + "%"
    }

    /// The change, as both the strip segment and the dropdown row render it:
    /// the direction glyph carrying the sign (R127), then the absolute delta,
    /// then the absolute percentage in brackets.
    ///
    /// Empty when the quote has neither a delta nor a percentage — the caller
    /// then shows the price alone, rather than a bare glyph or an empty pair
    /// of brackets.
    static func change(_ quote: Quote, locale: Locale = .autoupdatingCurrent) -> String {
        let delta = Self.delta(quote.change, locale: locale)
        let percent = Self.percent(quote.changePercent, locale: locale)
        guard !delta.isEmpty || !percent.isEmpty else { return "" }

        var text = quote.direction.glyph + delta
        if !percent.isEmpty {
            text += text.isEmpty ? "(\(percent))" : " (\(percent))"
        }
        return text
    }

    /// Two decimals normally; four under 1.0, where two would round most of the
    /// number away (a $0.0431 token, an FX cross). The threshold is on the
    /// magnitude, so it is the same either side of zero.
    private static func fractionDigits(for value: Double) -> Int {
        abs(value) >= 1 ? 2 : 4
    }

    /// A fresh `NumberFormatter` per call. They are not cheap, but this runs
    /// once per segment per *data change* — a handful of times a minute at
    /// most, never per frame (the strip is pre-rendered, spec §5.1) — and a
    /// cached one would have to be keyed on locale and digit count and made
    /// thread-safe to save nothing measurable.
    private static func formatter(locale: Locale, fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f
    }
}
