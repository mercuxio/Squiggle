import Foundation

/// The arithmetic behind Flip: one card at a time, each replaced by the next
/// with a turn about the horizontal axis.
///
/// Pure statics for the same reason `StripRenderer`'s are: whether Core
/// Animation rotates a layer to the angle it was told is not this project's
/// problem, but whether a five-symbol deck takes ten seconds to come round,
/// and whether card three is face-on while cards one and two are hidden, is.
///
/// Every function here answers in *fractions of one cycle*, never in seconds,
/// because that is the vocabulary `CAKeyframeAnimation.keyTimes` speaks. The
/// cycle those fractions are of is `cycleSeconds`.
enum FlipPolicy {
    /// The user's figure: a stock is readable for two seconds before it turns.
    static let dwellSeconds: Double = 2
    /// How long the turn itself takes — half of it spent on the card leaving,
    /// half on the card arriving, so only one of the two is ever mid-flip.
    ///
    /// 0.6s, twice the 0.3 it started at: at the shorter duration the turn
    /// read as a blink rather than as a card turning over, which is the whole
    /// point of the mode. Still comfortably under `dwellSeconds`, so a card
    /// is face-on for most of its own slot.
    static let flipSeconds: Double = 0.6
    /// A quarter turn is edge-on, which is where a card vanishes and where
    /// the next one comes from.
    static let quarterTurn: Double = .pi / 2
    /// `CATransform3D.m34`, applied to the *container* so every card shares
    /// one vanishing point. Without it the rotation is an orthographic
    /// squash — the card gets shorter and never looks like it turned.
    ///
    /// 400 points is roughly twenty menu bars away: near enough that the far
    /// edge visibly recedes, far enough that a 260pt-wide card does not
    /// splay.
    static let perspective: Double = -1.0 / 400

    /// Values with the key times they land on, in cycle fractions.
    struct Keyframes: Equatable {
        let values: [Double]
        let keyTimes: [Double]
    }

    /// One full pass through the deck. Floored at one card so a deck that is
    /// empty — an empty watchlist, mid-removal — still names a finite
    /// duration; Core Animation renders a frozen layer for a zero one, and
    /// spec §5.2 says a frozen bar reads as a crash.
    static func cycleSeconds(cardCount: Int) -> Double {
        dwellSeconds * Double(max(1, cardCount))
    }

    /// Whether the deck turns at all. A single stock has nothing to flip to,
    /// and a one-card cycle animating to itself would be two seconds of
    /// pointless rotation — the same rule `StripRenderer.fits` applies to a
    /// strip that does not need to scroll.
    static func animates(cardCount: Int) -> Bool {
        cardCount > 1
    }

    /// The angle, in radians, of card `index` across one cycle: edge-on
    /// before its turn, face-on through its dwell, edge-on the other way
    /// after it.
    ///
    /// The first and last cards omit the frame they would otherwise share
    /// with the cycle boundary — a repeated key time is a discontinuity Core
    /// Animation is entitled to resolve either way, and the card at the seam
    /// is the one that would visibly flicker.
    static func rotation(index: Int, count: Int) -> Keyframes {
        let (slotStart, slotEnd, half) = slot(index: index, count: count,
                                              transitionSeconds: flipSeconds)
        var values: [Double] = []
        var keyTimes: [Double] = []

        if slotStart > 0 {
            values.append(quarterTurn)
            keyTimes.append(0)
        }
        values.append(contentsOf: [quarterTurn, 0, 0, -quarterTurn])
        keyTimes.append(contentsOf: [slotStart, slotStart + half, slotEnd - half, slotEnd])
        if slotEnd < 1 {
            values.append(-quarterTurn)
            keyTimes.append(1)
        }
        return Keyframes(values: values, keyTimes: keyTimes)
    }

    /// Which card is on screen, as a discrete opacity timeline: exactly one
    /// card is visible at any moment, so a deck of twenty does not stack
    /// twenty layers of text on top of each other.
    ///
    /// Discrete, so `values.count + 1 == keyTimes.count` — each value holds
    /// for the span between consecutive times, the same contract
    /// `MotionPolicy.pageKeyTimes` exists to keep callers from getting wrong.
    static func visibility(index: Int, count: Int) -> Keyframes {
        let cards = max(1, count)
        let slotStart = Double(index) / Double(cards)
        let slotEnd = Double(index + 1) / Double(cards)

        // A one-card deck is simply always visible.
        if cards == 1 { return Keyframes(values: [1], keyTimes: [0, 1]) }
        if index == 0 { return Keyframes(values: [1, 0], keyTimes: [0, slotEnd, 1]) }
        if index == cards - 1 { return Keyframes(values: [0, 1], keyTimes: [0, slotStart, 1]) }
        return Keyframes(values: [0, 1, 0], keyTimes: [0, slotStart, slotEnd, 1])
    }

    /// Flip's Reduce Motion form: the deck still turns over every two
    /// seconds, but the card dips through transparent instead of rotating.
    ///
    /// Interpolated, not discrete — the dip *is* the animation here — and it
    /// borrows `MotionPolicy.fadeSeconds` rather than naming its own, because
    /// a user who sees Step's fade and Flip's fade in the same menu bar
    /// should be seeing one vocabulary.
    static func fade(index: Int, count: Int) -> Keyframes {
        let (slotStart, slotEnd, half) = slot(index: index, count: count,
                                              transitionSeconds: MotionPolicy.fadeSeconds)
        var values: [Double] = []
        var keyTimes: [Double] = []

        if slotStart > 0 {
            values.append(0)
            keyTimes.append(0)
        }
        values.append(contentsOf: [0, 1, 1, 0])
        keyTimes.append(contentsOf: [slotStart, slotStart + half, slotEnd - half, slotEnd])
        if slotEnd < 1 {
            values.append(0)
            keyTimes.append(1)
        }
        return Keyframes(values: values, keyTimes: keyTimes)
    }

    /// Card `index`'s share of the cycle, and the fraction either end of it
    /// that the transition occupies.
    ///
    /// Half the transition, deliberately: a turn is centred on the boundary
    /// between two slots, the outgoing card spending the first half of it and
    /// the incoming card the second. So each card's own slot is encroached on
    /// by half a transition at each end, and the two neighbours never
    /// overlap.
    ///
    /// The half can never swallow a whole slot: the transition is a fixed
    /// 0.6s against a slot of `dwellSeconds`, so `half` is 0.15 of a slot
    /// however many cards there are.
    private static func slot(index: Int, count: Int,
                             transitionSeconds: Double) -> (start: Double, end: Double,
                                                            half: Double) {
        let cards = max(1, count)
        let cycle = cycleSeconds(cardCount: cards)
        return (Double(index) / Double(cards),
                Double(index + 1) / Double(cards),
                (transitionSeconds / 2) / cycle)
    }
}
