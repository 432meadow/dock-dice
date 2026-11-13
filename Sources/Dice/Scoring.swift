// Hot Hand scoring: pure functions, no AppKit/SceneKit (no imports at all), so the launch
// self-check below is the test suite. Folk push-your-luck scoring for five ordinary dice:
//   - each 1 scores 100, each 5 scores 50;
//   - three or more of a face in one throw score face x 100 (1s: 1000), doubled for each die
//     beyond three (four 4s = 800, five 4s = 1600);
//   - only the dice thrown this time count together; a throw with nothing scoring is a bust;
//   - when all five dice have been kept, all five come back and the turn carries on;
//   - the special (gold) die's 1 face is wild: it takes whichever value scores most, i.e. it
//     joins a pair to make a set or extends a set, and otherwise counts as a 1 (100).

enum HandScoring {
    static let diceCount = 5

    struct Throw: Equatable {
        /// Total points for the throw (0 = bust).
        let points: Int
        /// Indices (into the thrown faces) of every scoring die. These are kept.
        let scoring: [Int]
        /// Scoring dice that are loose 1s or 5s (not part of a set): the only ones a player
        /// may hand back before the next throw.
        let loose: [Int]
        /// Human-readable parts, e.g. ["three 3s 300", "1 100"].
        let parts: [String]
        /// The value the wild took (nil if no wild in the throw).
        var wildAs: Int? = nil
        var bust: Bool { points == 0 }
    }

    /// Value of a set of `count` (>= 3) dice showing `face`.
    static func setValue(face: Int, count: Int) -> Int {
        precondition(count >= 3)
        let base = face == 1 ? 1000 : face * 100
        return base << (count - 3)
    }

    static func singleValue(_ face: Int) -> Int {
        face == 1 ? 100 : (face == 5 ? 50 : 0)
    }

    private static let countWords = [3: "three", 4: "four", 5: "five"]

    /// Score one throw. `faces` are the values of the dice thrown this time (1...5 dice);
    /// `wild` is the index of a die showing the wild face, if any. The wild takes the value
    /// 1...6 that scores most (ties go to the lower value, so a lone wild is a 1).
    static func score(_ faces: [Int], wild: Int?) -> Throw {
        guard let w = wild else { return score(faces) }
        var best: Throw?
        for v in 1...6 {
            var f = faces
            f[w] = v
            let t = score(f)
            if best == nil || t.points > best!.points { best = t; best!.wildAs = v }
        }
        var t = best!
        t = Throw(points: t.points, scoring: t.scoring, loose: t.loose,
                  parts: t.parts.map { $0 } + ["wild as \(t.wildAs!)"], wildAs: t.wildAs)
        return t
    }

    /// Score one throw with no wild.
    static func score(_ faces: [Int]) -> Throw {
        var byFace: [Int: [Int]] = [:]
        for (i, f) in faces.enumerated() { byFace[f, default: []].append(i) }
        var points = 0
        var scoring: [Int] = []
        var loose: [Int] = []
        var parts: [String] = []
        for face in 1...6 {
            guard let idx = byFace[face] else { continue }
            if idx.count >= 3 {
                let v = setValue(face: face, count: idx.count)
                points += v
                scoring += idx
                parts.append("\(countWords[idx.count] ?? "\(idx.count)") \(face)s \(v)")
            } else if singleValue(face) > 0 {
                points += singleValue(face) * idx.count
                scoring += idx
                loose += idx
                parts.append(idx.count == 1 ? "\(face) \(singleValue(face))" : "\(idx.count)x\(face) \(singleValue(face) * idx.count)")
            }
        }
        return Throw(points: points, scoring: scoring.sorted(), loose: loose.sorted(), parts: parts)
    }

    /// May the player hand back this kept die (by its index in the throw)? Only a loose 1 or 5,
    /// and never the last die kept from that throw.
    static func canRelease(_ index: Int, from t: Throw, stillKept: Int) -> Bool {
        t.loose.contains(index) && stillKept > 1
    }

    /// After keeping, are all five dice kept (so all five come back)?
    static func isHotHand(keptTotal: Int) -> Bool { keptTotal >= diceCount }

    // MARK: Self-check (run at launch with DICE_DEBUG; there is no XCTest here)

    static func selfCheck() -> (ok: Bool, lines: [String]) {
        struct Case { let name: String; let faces: [Int]; let points: Int; let scoringCount: Int; let loose: Int }
        let cases: [Case] = [
            Case(name: "single 1", faces: [1, 2, 3, 4, 6], points: 100, scoringCount: 1, loose: 1),
            Case(name: "single 5", faces: [5, 2, 3, 4, 6], points: 50, scoringCount: 1, loose: 1),
            Case(name: "1 and 5", faces: [1, 5, 2, 3, 6], points: 150, scoringCount: 2, loose: 2),
            Case(name: "two 1s two 5s", faces: [1, 1, 5, 5, 3], points: 300, scoringCount: 4, loose: 4),
            Case(name: "three 3s", faces: [3, 3, 3, 2, 4], points: 300, scoringCount: 3, loose: 0),
            Case(name: "three 1s", faces: [1, 1, 1, 2, 3], points: 1000, scoringCount: 3, loose: 0),
            Case(name: "three 6s + 1 + 5", faces: [6, 6, 6, 1, 5], points: 750, scoringCount: 5, loose: 2),
            Case(name: "three 5s + 1", faces: [5, 5, 5, 1, 2], points: 600, scoringCount: 4, loose: 1),
            Case(name: "four 4s", faces: [4, 4, 4, 4, 2], points: 800, scoringCount: 4, loose: 0),
            Case(name: "four 2s + 5", faces: [2, 2, 2, 2, 5], points: 450, scoringCount: 5, loose: 1),
            Case(name: "five 4s", faces: [4, 4, 4, 4, 4], points: 1600, scoringCount: 5, loose: 0),
            Case(name: "five 1s", faces: [1, 1, 1, 1, 1], points: 4000, scoringCount: 5, loose: 0),
            Case(name: "three 2s, pair of 3s", faces: [2, 2, 2, 3, 3], points: 200, scoringCount: 3, loose: 0),
            Case(name: "bust", faces: [2, 3, 4, 6, 2], points: 0, scoringCount: 0, loose: 0),
            Case(name: "bust (pairs only)", faces: [2, 2, 3, 3, 6], points: 0, scoringCount: 0, loose: 0),
            Case(name: "two dice: 5 5", faces: [5, 5], points: 100, scoringCount: 2, loose: 2),
            Case(name: "one die: bust", faces: [3], points: 0, scoringCount: 0, loose: 0),
            Case(name: "three dice: three 1s", faces: [1, 1, 1], points: 1000, scoringCount: 3, loose: 0),
            Case(name: "hot hand: three 1s + two 5s", faces: [1, 5, 1, 5, 1], points: 1100, scoringCount: 5, loose: 2),
        ]
        var ok = true
        var lines: [String] = []
        for c in cases {
            let t = score(c.faces)
            let pass = t.points == c.points && t.scoring.count == c.scoringCount && t.loose.count == c.loose
            if !pass { ok = false }
            let hot = isHotHand(keptTotal: t.scoring.count) ? " HOT HAND" : ""
            lines.append("\(pass ? "ok  " : "FAIL") \(c.name) \(c.faces) -> \(t.points) [\(t.parts.joined(separator: ", "))] scoring \(t.scoring.count) loose \(t.loose.count)\(hot)"
                         + (pass ? "" : " (expected \(c.points) / \(c.scoringCount) / \(c.loose))"))
        }
        // Wild cases: index 0 is the special die showing its wild face (its own value ignored).
        struct WildCase { let name: String; let faces: [Int]; let points: Int; let wildAs: Int; let scoringCount: Int }
        let wildCases: [WildCase] = [
            WildCase(name: "wild alone (one die)", faces: [1], points: 100, wildAs: 1, scoringCount: 1),
            WildCase(name: "wild, nothing else scoring", faces: [1, 2, 3, 4, 6], points: 100, wildAs: 1, scoringCount: 1),
            WildCase(name: "wild + pair of 4s", faces: [1, 4, 4, 2, 3], points: 400, wildAs: 4, scoringCount: 3),
            WildCase(name: "wild + pair of 1s", faces: [1, 1, 1, 2, 3], points: 1000, wildAs: 1, scoringCount: 3),
            WildCase(name: "wild + pair of 5s + 1", faces: [1, 5, 5, 1, 2], points: 600, wildAs: 5, scoringCount: 4),
            WildCase(name: "wild + two pairs (2s, 6s)", faces: [1, 2, 2, 6, 6], points: 600, wildAs: 6, scoringCount: 3),
            WildCase(name: "wild extends three 3s", faces: [1, 3, 3, 3, 2], points: 600, wildAs: 3, scoringCount: 4),
            WildCase(name: "wild extends four 4s", faces: [1, 4, 4, 4, 4], points: 1600, wildAs: 4, scoringCount: 5),
            WildCase(name: "wild + loose 1 and 5", faces: [1, 1, 5, 2, 3], points: 250, wildAs: 1, scoringCount: 3),
        ]
        for c in wildCases {
            let t = score(c.faces, wild: 0)
            let pass = t.points == c.points && t.wildAs == c.wildAs && t.scoring.count == c.scoringCount
            if !pass { ok = false }
            lines.append("\(pass ? "ok  " : "FAIL") \(c.name) [W\(c.faces.dropFirst().map { ",\($0)" }.joined())] -> \(t.points) [\(t.parts.joined(separator: ", "))] scoring \(t.scoring.count)"
                         + (pass ? "" : " (expected \(c.points), wild as \(c.wildAs), scoring \(c.scoringCount))"))
        }
        // Hand-back rule.
        let t = score([1, 5, 2, 3, 6])
        let r1 = canRelease(1, from: t, stillKept: 2)      // the 5, with the 1 still kept
        let r2 = canRelease(0, from: t, stillKept: 1)      // last kept die of that throw
        let t2 = score([3, 3, 3, 5, 2])
        let r3 = canRelease(0, from: t2, stillKept: 4)     // a 3 from the set
        let rulesOK = r1 && !r2 && !r3
        if !rulesOK { ok = false }
        lines.append("\(rulesOK ? "ok  " : "FAIL") hand-back: loose 5 with another kept -> \(r1); last kept die -> \(r2); die from a set -> \(r3)")
        let hotOK = isHotHand(keptTotal: 5) && !isHotHand(keptTotal: 4)
        if !hotOK { ok = false }
        lines.append("\(hotOK ? "ok  " : "FAIL") hot hand at 5 kept -> \(isHotHand(keptTotal: 5)); at 4 -> \(isHotHand(keptTotal: 4))")
        return (ok, lines)
    }
}
