import Testing
@testable import Squiggle

@Test func modesDecodeFromSettings() {
    #expect(MotionMode(setting: "scroll") == .scroll)
    #expect(MotionMode(setting: "step") == .step)
    // R120's vocabulary is two words. Anything else is a file that was
    // hand-edited or written by a future version, and the default is the
    // safe answer in both cases.
    #expect(MotionMode(setting: "Step") == .scroll)
    #expect(MotionMode(setting: "") == .scroll)
    #expect(MotionMode(setting: "marquee") == .scroll)
}

@Test func reduceMotionOffHonoursTheSetting() {
    #expect(MotionPolicy.effective(requested: .scroll, reduceMotion: false) == .scroll)
    #expect(MotionPolicy.effective(requested: .step, reduceMotion: false) == .step)
}

// Spec §5.1: forced, not defaulted. The stored setting is not consulted.
@Test func reduceMotionForcesStep() {
    #expect(MotionPolicy.effective(requested: .scroll, reduceMotion: true) == .step)
    #expect(MotionPolicy.effective(requested: .step, reduceMotion: true) == .step)
}

@Test func contentThatFitsIsOnePage() {
    let offsets = MotionPolicy.pageOffsets(contentWidth: 150, visibleWidth: 260)
    #expect(offsets == [0])
}

@Test func pagesAreWholeWindows() {
    #expect(MotionPolicy.pageOffsets(contentWidth: 520, visibleWidth: 260) == [0, -260])
    #expect(MotionPolicy.pageOffsets(contentWidth: 521, visibleWidth: 260) == [0, -260, -520])
}

// A zero width reaches here only from a settings file someone edited, but
// `520 / 0` is `.infinity` and `Int(.infinity)` traps, so the guard is
// cheaper than the crash report.
@Test func aZeroWindowIsOnePage() {
    #expect(MotionPolicy.pageOffsets(contentWidth: 520, visibleWidth: 0) == [0])
    #expect(MotionPolicy.pageOffsets(contentWidth: 520, visibleWidth: -260) == [0])
}

// Core Animation's contract for `.discrete` is not the same as for the
// interpolating modes: a discrete keyframe animation wants ONE MORE key
// time than it has values, because each value occupies the span between
// consecutive times rather than sitting on one. Getting this wrong does
// not raise — the animation silently plays at the wrong pace.
@Test func pageKeyTimesBracketEachPage() {
    #expect(MotionPolicy.pageKeyTimes(pageCount: 1) == [0, 1])
    #expect(MotionPolicy.pageKeyTimes(pageCount: 2) == [0, 0.5, 1])
    #expect(MotionPolicy.pageKeyTimes(pageCount: 4) == [0, 0.25, 0.5, 0.75, 1])
}

@Test func pageKeyTimesMatchTheOffsets() {
    let offsets = MotionPolicy.pageOffsets(contentWidth: 800, visibleWidth: 260)
    let times = MotionPolicy.pageKeyTimes(pageCount: offsets.count)
    #expect(times.count == offsets.count + 1)
}

@Test func fadeHasOneDipPerPage() {
    let frames = MotionPolicy.fadeKeyframes(pageCount: 3)
    #expect(frames.values.count == frames.keyTimes.count)
    // Three per page — invisible at the switch, up, held — plus the final
    // dip that the repeat wraps onto the first.
    #expect(frames.values.count == 10)
    #expect(frames.values.first == 0)
    #expect(frames.values.last == 0)
    #expect(frames.keyTimes.first == 0)
    #expect(frames.keyTimes.last == 1)
}

// Core Animation requires key times to be non-decreasing and in 0...1. It
// does not check; it silently renders something else.
@Test func keyTimesStrictlyIncrease() {
    for pages in 1...12 {
        let frames = MotionPolicy.fadeKeyframes(pageCount: pages)
        let ascending = zip(frames.keyTimes, frames.keyTimes.dropFirst())
        let isSorted = ascending.allSatisfy { $0 < $1 }
        #expect(isSorted, "pageCount \(pages)")
        let inRange = frames.keyTimes.allSatisfy { $0 >= 0 && $0 <= 1 }
        #expect(inRange, "pageCount \(pages)")
        let opacities = frames.values.allSatisfy { $0 >= 0 && $0 <= 1 }
        #expect(opacities, "pageCount \(pages)")
    }
}

@Test func onePageIsWellFormed() {
    let frames = MotionPolicy.fadeKeyframes(pageCount: 1)
    #expect(frames.values.count == 4)
    #expect(frames.keyTimes.last == 1)
}

// Nothing calls it with zero, but `0` pages divides by zero building the
// key times, and a NaN key time is a layer that never appears.
@Test func zeroPagesIsOnePage() {
    let frames = MotionPolicy.fadeKeyframes(pageCount: 0)
    let finite = frames.keyTimes.allSatisfy { $0.isFinite }
    #expect(finite)
    #expect(frames.keyTimes.last == 1)
}
