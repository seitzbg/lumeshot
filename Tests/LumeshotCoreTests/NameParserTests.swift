import Foundation
import Testing
@testable import LumeshotCore

// Deterministic RNG for tests.
struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func fixedContext(increment: Int = 0) -> NameContext {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    // 2026-07-10 09:05:03.042 UTC
    let comps = DateComponents(calendar: cal, timeZone: cal.timeZone,
                               year: 2026, month: 7, day: 10,
                               hour: 9, minute: 5, second: 3, nanosecond: 42_000_000)
    return NameContext(date: comps.date!, width: 2560, height: 1440,
                       processName: "Safari", increment: increment, calendar: cal)
}

@Suite struct NameParserTests {
    @Test func dateTokensZeroPad() {
        let out = NameParser.render("%y-%mo-%d_%h-%mi-%s.%ms", context: fixedContext())
        #expect(out == "2026-07-10_09-05-03.042")
    }

    @Test func dimensionAndProcessTokens() {
        let out = NameParser.render("%pn_%widthx%height", context: fixedContext())
        #expect(out == "Safari_2560x1440")
    }

    @Test func missingContextValuesRenderEmpty() {
        let ctx = NameContext(date: fixedContext().date, width: nil, height: nil,
                              processName: nil, increment: 0,
                              calendar: fixedContext().calendar)
        #expect(NameParser.render("%pn|%width|%height", context: ctx) == "||")
    }

    @Test func incrementToken() {
        #expect(NameParser.render("shot_%i", context: fixedContext(increment: 7)) == "shot_7")
    }

    @Test func randomTokensAreDeterministicWithSeededRNG() {
        var rng1 = LCG(state: 42)
        var rng2 = LCG(state: 42)
        let a = NameParser.render("%rn%rn%ra%ra", context: fixedContext(), rng: &rng1)
        let b = NameParser.render("%rn%rn%ra%ra", context: fixedContext(), rng: &rng2)
        #expect(a == b)
        #expect(a.count == 4)
        #expect(a.prefix(2).allSatisfy { "0123456789".contains($0) })
    }

    @Test func unknownTokensPassThrough() {
        #expect(NameParser.render("a%zzb", context: fixedContext()) == "a%zzb")
    }

    @Test func processNameIsSanitized() {
        var ctx = fixedContext()
        ctx.processName = "My/App: Beta"
        #expect(NameParser.render("%pn", context: ctx) == "My-App- Beta")
    }
}
