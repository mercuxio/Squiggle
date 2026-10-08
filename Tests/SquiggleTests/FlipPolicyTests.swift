import Testing
@testable import Squiggle

// Everything `FlipPolicy` returns is a fraction of one cycle, so these tests
// convert back by hand where a reader would want seconds: a 0.0375 key time
// against a four-second cycle is the 0.15s half-turn the policy promises.

@Test func theCycleIsTwoSecondsPerCard() {
    #expect(FlipPolicy.cycleSeconds(cardCount: 1) == 2)
    #expect(FlipPolicy.cycleSeconds(cardCount: 3) == 6)
    #expect(FlipPolicy.cycleSeconds(cardCount: 10) == 20)
}

// Spec §5.2: a zero duration renders a frozen layer, and a frozen bar reads
// as a crash. An empty deck is reachable — the watchlist mid-removal.
@Test func anEmptyDeckStillNamesAFiniteCycle() {
    #expect(FlipPolicy.cycleSeconds(cardCount: 0) == 2)
    #expect(FlipPolicy.cycleSeconds(cardCount: -3) == 2)
}

@Test func oneCardHasNothingToFlipTo() {
    #expect(!FlipPolicy.animates(cardCount: 0))
    #expect(!FlipPolicy.animates(cardCount: 1))
    #expect(FlipPolicy.animates(cardCount: 2))
}

// Face-on through the dwell, edge-on at both ends of the slot: the turn is
// centred on the boundary between two cards, which is what keeps the
// outgoing and incoming halves from overlapping.
@Test func aCardIsFaceOnThroughItsOwnSlotAndEdgeOnAtItsEnds() {
    let frames = FlipPolicy.rotation(index: 0, count: 2)
    // Four seconds of cycle, a 0.6s turn, so each half-turn is 0.075 of it.
    #expect(frames.keyTimes == [0, 0.075, 0.425, 0.5, 1])
    #expect(frames.values == [FlipPolicy.quarterTurn, 0, 0,
                              -FlipPolicy.quarterTurn, -FlipPolicy.quarterTurn])
}

// The card at the seam is the one that would flicker: two values sharing a
// key time is a discontinuity Core Animation may resolve either way.
@Test func theCardsAtTheCycleBoundaryOmitTheirDuplicateFrame() {
    let first = FlipPolicy.rotation(index: 0, count: 3)
    #expect(first.keyTimes.first == 0)
    #expect(first.keyTimes.count == Set(first.keyTimes).count)

    let last = FlipPolicy.rotation(index: 2, count: 3)
    #expect(last.keyTimes.last == 1)
    #expect(last.keyTimes.count == Set(last.keyTimes).count)
}

@Test func everyCardsKeyTimesRunForwardsAcrossExactlyOneCycle() {
    for count in 1...6 {
        for index in 0..<count {
            for frames in [FlipPolicy.rotation(index: index, count: count),
                           FlipPolicy.fade(index: index, count: count)] {
                #expect(frames.values.count == frames.keyTimes.count,
                        "interpolated keyframes need equal counts: \(count)/\(index)")
                #expect(frames.keyTimes == frames.keyTimes.sorted(),
                        "key times run backwards: \(frames.keyTimes)")
                #expect(frames.keyTimes.first == 0)
                #expect(frames.keyTimes.last == 1)
            }
        }
    }
}

// The discrete contract: N values held across N+1 boundaries. Getting this
// wrong is silent — Core Animation drops the animation rather than complain.
@Test func visibilityIsDiscreteAndSoNeedsOneMoreKeyTimeThanValue() {
    for count in 1...6 {
        for index in 0..<count {
            let frames = FlipPolicy.visibility(index: index, count: count)
            #expect(frames.keyTimes.count == frames.values.count + 1,
                    "discrete keyframes need N+1 key times: \(count)/\(index)")
            #expect(frames.keyTimes.first == 0)
            #expect(frames.keyTimes.last == 1)
        }
    }
}

// Exactly one card on screen at a time, so a twenty-symbol deck does not
// stack twenty layers of text on one another.
@Test func onlyOneCardIsVisibleAtATime() {
    #expect(FlipPolicy.visibility(index: 0, count: 1)
        == FlipPolicy.Keyframes(values: [1], keyTimes: [0, 1]))
    #expect(FlipPolicy.visibility(index: 0, count: 3)
        == FlipPolicy.Keyframes(values: [1, 0], keyTimes: [0, 1.0 / 3, 1]))
    #expect(FlipPolicy.visibility(index: 1, count: 3)
        == FlipPolicy.Keyframes(values: [0, 1, 0], keyTimes: [0, 1.0 / 3, 2.0 / 3, 1]))
    #expect(FlipPolicy.visibility(index: 2, count: 3)
        == FlipPolicy.Keyframes(values: [0, 1], keyTimes: [0, 2.0 / 3, 1]))
}

// Reduce Motion keeps the two-second cadence and drops the rotation. The dip
// borrows `MotionPolicy.fadeSeconds` so Step's fade and Flip's fade are one
// vocabulary rather than two numbers that happen to be close.
@Test func theReduceMotionFadeDipsThroughTransparentOnTheSameCadence() {
    let frames = FlipPolicy.fade(index: 1, count: 2)
    let half = (MotionPolicy.fadeSeconds / 2) / FlipPolicy.cycleSeconds(cardCount: 2)
    #expect(frames.values == [0, 0, 1, 1, 0])
    #expect(frames.keyTimes == [0, 0.5, 0.5 + half, 1 - half, 1])
}
