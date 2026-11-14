// Offline "Describe the sound" interpreter: a deterministic word → knob-delta
// mapper (no key, no network). Port of src/ai/localMix.ts — same vocabulary,
// regexes, directions, intensities and analysis-aware scaling.

import Foundation

public struct MixSuggestion: Sendable, Equatable {
    public var values: KnobValues
    public var songGain: Double?
    public var drumGain: Double?
    public var explanation: String

    public init(values: KnobValues, songGain: Double? = nil, drumGain: Double? = nil, explanation: String) {
        self.values = values
        self.songGain = songGain
        self.drumGain = drumGain
        self.explanation = explanation
    }
}

public struct LocalMixInput: Sendable {
    public var prompt: String
    public var values: KnobValues
    public var songGain: Double
    public var drumGain: Double
    public var analysis: MixAnalysis?

    public init(prompt: String, values: KnobValues, songGain: Double, drumGain: Double, analysis: MixAnalysis? = nil) {
        self.prompt = prompt
        self.values = values
        self.songGain = songGain
        self.drumGain = drumGain
        self.analysis = analysis
    }
}

public struct LocalMixResult: Sendable, Equatable {
    public var suggestion: MixSuggestion
    /// Concept ids that fired, in prompt order ("-" prefix when negated).
    public var matched: [String]

    public var values: KnobValues { suggestion.values }
    public var songGain: Double? { suggestion.songGain }
    public var drumGain: Double? { suggestion.drumGain }
    public var explanation: String { suggestion.explanation }
}

private struct Scale: Sendable {
    var k: Double
    var note: String?
    init(_ k: Double, _ note: String? = nil) {
        self.k = k
        self.note = note
    }
}

private typealias Delta = [(String, Double)]

private struct Concept: Sendable {
    enum Op: Sendable { case natural, reset }
    let id: String
    let more: String
    let less: String
    let patterns: [JSRegex]
    let delta: @Sendable (MixAnalysis?) -> Delta
    var problem = false
    var op: Op?
    var scale: (@Sendable (MixAnalysis, Double) -> Scale)?
}

private func words(_ ws: String...) -> JSRegex { JSRegex("\\b(?:\(ws.joined(separator: "|")))\\b") }

private func concept(
    _ id: String, _ more: String, _ less: String, _ patterns: [JSRegex], _ delta: Delta, problem: Bool = false,
    op: Concept.Op? = nil, scale: (@Sendable (MixAnalysis, Double) -> Scale)? = nil
) -> Concept {
    Concept(id: id, more: more, less: less, patterns: patterns, delta: { _ in delta }, problem: problem, op: op, scale: scale)
}

// MARK: analysis-aware scaling helpers

private func db10(_ dbs: Double...) -> Double { 10 * log10(dbs.reduce(0) { $0 + pow(10, $1 / 10) }) }
private func lowShare(_ d: AudioDescriptors) -> Double { db10(d.bands.sub, d.bands.low) }

/// `x` is a measurement; `hi`/`lo` where it counts as already a lot / very
/// little of the quality being added (sign = +1) or removed (sign = −1).
private func along(_ x: Double, _ lo: Double, _ hi: Double, _ sign: Double, hiNote: String, loNote: String) -> Scale {
    if sign > 0 {
        if x >= hi { return Scale(0.5, hiNote) }
        if x <= lo { return Scale(1.3, loNote) }
    } else {
        if x <= lo { return Scale(0.5, loNote) }
        if x >= hi { return Scale(1.3, hiNote) }
    }
    return Scale(1)
}

private func brightScale(_ a: MixAnalysis, _ s: Double) -> Scale {
    along(a.drums.centroidHz, 1800, 4500, s, hiNote: "the take is already bright", loNote: "the take is dull")
}
private func airScale(_ a: MixAnalysis, _ s: Double) -> Scale {
    along(a.drums.bands.air, -26, -12, s, hiNote: "plenty of top end already", loNote: "little top end to start with")
}
private func lowScale(_ a: MixAnalysis, _ s: Double) -> Scale {
    along(lowShare(a.drums), -12, -4, s, hiNote: "lots of low end", loNote: "the low end is already lean")
}
private func lowMidScale(_ a: MixAnalysis, _ s: Double) -> Scale {
    along(a.drums.bands.lowMid, -14, -6, s, hiNote: "heavy low-mids", loNote: "low-mids are already clean")
}
private func ringScale(_ a: MixAnalysis, _ s: Double) -> Scale {
    along(a.drums.decayMs, 90, 250, s, hiNote: "hits ring out long", loNote: "hits are already short")
}
private func crestScale(_ a: MixAnalysis, _ s: Double) -> Scale {
    along(a.drums.crestDb, 12, 20, s, hiNote: "the take is very dynamic", loNote: "the take is already squashed")
}
private func noiseScale(_ a: MixAnalysis, _ dir: Double) -> Scale {
    along(a.drums.rmsDb - a.drums.noiseFloorDb, 25, 45, -dir, hiNote: "the background is already quiet", loNote: "there is an audible noise floor")
}

// MARK: vocabulary

private let concepts: [Concept] = [
    // whole-state operations
    concept("reset", "reset to flat", "reset to flat",
            [words("reset", "start over", "from scratch", "bypass", "unprocessed", "no processing", "no effects", "clean slate")], [], op: .reset),
    concept("natural", "more natural", "more processed",
            [words("natural", "naturally", "transparent", "realistic", "honest", "organic")], [("naturalness", 0.3)], op: .natural),

    // eras / genres
    concept("90s-rock", "90s rock", "less 90s rock",
            [JSRegex("\\b(?:90s|1990s) (?:rock|grunge|alt|alternative)\\b"), words("grunge")],
            [("punch", 0.35), ("attack", 0.25), ("kick_presence", 0.2), ("dynamic_range", 0.3), ("depth", 0.15), ("boxiness", 0.2), ("sustain", 0.15)]),
    concept("80s", "80s", "less 80s", [words("80s", "1980s", "gated reverb", "gated")],
            [("depth", 0.5), ("punch", 0.3), ("brightness", 0.2), ("width", 0.25), ("sustain", 0.3), ("dynamic_range", 0.25)]),
    concept("70s", "70s", "less 70s", [words("70s", "1970s", "seventies", "60s", "1960s", "sixties", "motown", "soul")],
            [("warmth", 0.35), ("brightness", -0.25), ("air", -0.2), ("sustain", 0.3), ("depth", -0.3), ("roominess", 0.15), ("detail", 0.2)]),
    concept("vintage", "vintage", "less vintage",
            [words("vintage", "old school", "oldschool", "retro", "classic", "analog", "analogue", "tape", "vinyl", "old")],
            [("warmth", 0.35), ("brightness", -0.25), ("air", -0.2), ("depth", 0.2), ("detail", 0.2)]),
    concept("lofi", "lo-fi", "less lo-fi",
            [words("lofi", "lo fi", "crushed", "dirty", "gritty", "grimy", "distorted", "saturated", "trashy", "garage")],
            [("warmth", 0.6), ("brightness", -0.35), ("air", -0.4), ("high_pass_rumble", 0.35), ("presence", 0.2), ("naturalness", 0.3)]),
    concept("modern", "modern / polished", "less polished",
            [words("modern", "polished", "hifi", "hi fi", "produced", "pro", "professional", "radio", "pop", "slick", "studio"),
             JSRegex("\\bclean(?:er)?\\b(?! up)")],
            [("attack", 0.2), ("air", 0.2), ("punch", 0.2), ("consistency", 0.2), ("boxiness", 0.15), ("high_pass_rumble", 0.15), ("naturalness", 0.4)]),
    concept("metal", "metal", "less metal", [words("metal", "heavy", "djent", "hardcore")],
            [("attack", 0.4), ("punch", 0.3), ("consistency", 0.4), ("dynamic_range", 0.4), ("boxiness", 0.3), ("kick_presence", 0.3), ("sustain", 0.2), ("naturalness", 0.5)]),
    concept("jazz", "jazz", "less jazz", [words("jazz", "jazzy", "brushes", "acoustic", "folk")],
            [("depth", 0.3), ("warmth", 0.2), ("detail", 0.3), ("punch", -0.2), ("dynamic_range", -0.3), ("consistency", -0.2)]),
    concept("hiphop", "hip-hop", "less hip-hop", [words("hip hop", "hiphop", "boom bap", "boombap", "rap", "trap")],
            [("kick_presence", 0.4), ("punch", 0.3), ("warmth", 0.3), ("sustain", 0.2), ("snare_body", 0.2)]),
    concept("funk", "funk", "less funk", [words("funk", "funky", "disco")],
            [("sustain", 0.35), ("depth", -0.3), ("punch", 0.3), ("attack", 0.2), ("detail", 0.3)]),
    concept("punk", "punk", "less punk", [words("punk")],
            [("attack", 0.3), ("brightness", 0.2), ("dynamic_range", 0.35), ("depth", 0.15), ("warmth", 0.2)]),
    concept("phone", "phone / telephone sound", "less phone-like",
            [words("phone", "telephone", "walkie talkie", "megaphone", "am radio", "transistor")],
            [("high_pass_rumble", 0.6), ("fullness", -0.3), ("kick_presence", -0.35), ("air", -0.4), ("presence", 0.3), ("dynamic_range", 0.3)]),
    concept("rock", "rock", "less rock", [words("rock", "rocky", "indie")],
            [("punch", 0.25), ("kick_presence", 0.15), ("snare_body", 0.15), ("depth", 0.15), ("dynamic_range", 0.2)]),

    // tone
    concept("warm", "warmer", "less warm", [words("warm", "warmer", "warmth", "cozy", "round", "rounder", "rounded")],
            [("warmth", 0.35), ("fullness", 0.2), ("brightness", -0.15), ("harshness", 0.2)]),
    concept("dark", "darker", "less dark", [words("dark", "darker", "darken", "dull", "duller", "muffled", "mellow", "mellower")],
            [("brightness", -0.35), ("air", -0.25), ("harshness", 0.2)], scale: { a, d in brightScale(a, -d) }),
    concept("bright", "brighter", "less bright", [words("bright", "brighter", "brighten", "brightness", "sizzle", "sizzly", "shiny", "shinier")],
            [("brightness", 0.35), ("air", 0.25), ("attack", 0.15)], scale: { a, d in brightScale(a, d) }),
    concept("air", "more air", "less air",
            [words("air", "airy", "airier", "open", "sparkle", "sparkly", "shimmer", "top end", "highs", "treble")],
            [("air", 0.4), ("brightness", 0.1)], scale: { a, d in airScale(a, d) }),
    concept("harsh", "more bite", "less harsh",
            [words("harsh", "harshness", "brittle", "piercing", "shrill", "tinny", "fizzy", "ice pick", "abrasive")],
            [("harshness", -0.35), ("presence", 0.15)], problem: true, scale: { a, d in brightScale(a, d) }),
    concept("bite", "more bite", "less bite",
            [words("bite", "biting", "aggressive", "edge", "edgy", "edgier", "sharp", "sharper", "attitude")],
            [("harshness", -0.3), ("presence", 0.25), ("attack", 0.15)], scale: { a, d in brightScale(a, d) }),
    concept("crisp", "crisper", "less crisp",
            [words("crisp", "crisper", "crispy", "snappy", "snappier", "snap", "defined", "definition", "articulate", "clicky", "click", "stick")],
            [("attack", 0.35), ("detail", 0.2), ("air", 0.1)]),
    concept("soft", "softer", "less soft", [words("soft", "softer", "gentle", "gentler", "smooth", "smoother", "silky", "easy")],
            [("attack", -0.25), ("harshness", 0.25), ("brightness", -0.1), ("punch", -0.15)]),

    // low end / body
    concept("boomy", "boomier", "less boomy",
            [words("boomy", "boom", "boomier", "boominess", "bass heavy", "bassy", "rumble", "rumbly", "woofy", "tubby", "flabby")],
            [("kick_presence", 0.35), ("high_pass_rumble", -0.25)], problem: true, scale: { a, d in lowScale(a, d) }),
    concept("muddy", "muddier", "less muddy", [words("mud", "muddy", "muddier", "murky", "murk", "cloudy", "congested", "mush", "mushy")],
            [("boxiness", -0.35), ("snare_body", 0.15), ("high_pass_rumble", -0.1)], problem: true, scale: { a, d in lowMidScale(a, d) }),
    concept("boxy", "boxier", "less boxy",
            [words("boxy", "boxier", "boxiness", "box", "cardboard", "hollow", "honky", "honk", "papery", "nasal")],
            [("boxiness", -0.4), ("resonance", -0.2)], problem: true, scale: { a, d in lowMidScale(a, d) }),
    concept("thin", "thinner", "less thin", [words("thin", "thinner", "weak", "weedy", "wimpy", "lightweight", "puny")],
            [("fullness", -0.3), ("snare_body", -0.25), ("kick_presence", -0.2)], problem: true, scale: { a, d in lowScale(a, -d) }),
    concept("full", "fuller", "less full",
            [words("full", "fuller", "fullness", "thick", "thicker", "beefy", "beefier", "meaty", "meatier", "body", "weight", "weighty", "heft", "chunky")],
            [("fullness", 0.35), ("snare_body", 0.25), ("kick_presence", 0.15)], scale: { a, d in lowScale(a, d) }),
    concept("big", "bigger", "smaller",
            [words("big", "bigger", "huge", "massive", "epic", "fat", "fatter", "larger", "giant", "arena", "stadium", "cinematic")],
            [("fullness", 0.3), ("kick_presence", 0.25), ("depth", 0.25), ("width", 0.25), ("punch", 0.15)]),

    // dynamics
    concept("punchy", "punchier", "less punchy",
            [words("punch", "punchy", "punchier", "impact", "hard hitting", "hit harder", "slam", "slamming", "thump", "thumpy", "knock")],
            [("punch", 0.4), ("attack", 0.2), ("kick_presence", 0.15)], scale: { a, d in crestScale(a, d) }),
    concept("compressed", "more compressed", "less compressed",
            [words("compressed", "compression", "compress", "squashed", "squash", "smashed", "squeezed", "crushed", "loud", "loudness", "dense", "glued", "glue")],
            [("dynamic_range", 0.4), ("consistency", 0.25), ("punch", 0.15), ("naturalness", 0.5)], scale: { a, d in crestScale(a, -d) }),
    concept("dynamic", "more dynamic", "less dynamic", [words("dynamic", "dynamics", "uncompressed", "breathing", "breathe")],
            [("dynamic_range", -0.4), ("consistency", -0.25), ("detail", 0.15)], scale: { a, d in crestScale(a, d) }),
    concept("even", "more even", "less even",
            [words("more even", "evener", "evened out", "consistent", "steady", "controlled", "uneven", "inconsistent")],
            [("consistency", 0.4), ("dynamic_range", 0.15)]),
    concept("detail", "more detail", "less detail", [words("ghost notes", "ghost", "detail", "detailed", "nuance", "nuanced", "articulation")],
            [("detail", 0.4)]),
    concept("pumping", "more pumping", "less pumping", [words("pumping", "pumpy", "pump", "breathy")], [("pumping", -0.4)], problem: true),

    // room / space
    concept("dry", "drier", "less dry",
            [words("dry", "drier", "dryer", "dead", "deader", "close", "closer", "intimate", "in your face", "upfront", "up front")],
            [("roominess", 0.25), ("depth", -0.4), ("sustain", 0.2)], scale: { a, d in ringScale(a, -d) }),
    concept("tight", "tighter", "looser", [words("tight", "tighter", "focused", "short", "shorter", "choked")],
            [("sustain", 0.35), ("roominess", 0.1), ("boxiness", 0.15), ("high_pass_rumble", 0.15), ("punch", 0.15)], scale: { a, d in ringScale(a, -d) }),
    concept("roomy", "more room", "less room",
            [words("room", "roomy", "roomier", "roominess", "ambient", "ambience", "ambiance", "spacious", "space", "reverb", "reverby", "verb",
                   "live", "distant", "further back", "echo", "wet", "wetter", "hall", "loose", "looser")],
            [("depth", 0.4), ("roominess", -0.25), ("sustain", -0.25)], scale: { a, d in ringScale(a, d) }),
    concept("ringy", "more ring", "less ring",
            [words("ring", "ringy", "ringing", "rings", "resonant", "resonance", "resonances", "boingy", "overtones", "sustain", "tails")],
            [("resonance", -0.4), ("sustain", -0.2)], problem: true, scale: { a, d in ringScale(a, d) }),
    concept("wide", "wider", "narrower", [words("wide", "wider", "width", "stereo", "spread")], [("width", 0.4)]),
    concept("narrow", "narrower", "wider", [words("narrow", "narrower", "mono")], [("width", -0.4)]),

    // clean-up / fit
    concept("noisy", "noisier", "less noise", [words("noise", "noisy", "hiss", "hissy", "hum", "buzz", "background", "bleed")],
            [("denoise", -0.3)], problem: true, scale: { a, d in noiseScale(a, d) }),
    concept("clipping", "more clipping", "less clipping", [words("clipping", "clipped", "clip", "distortion", "crackle", "crackly")],
            [("clipping", -0.5), ("naturalness", -0.3)], problem: true),
    concept("present", "more present", "further back",
            [words("cut through", "cuts through", "present", "presence", "forward", "in front", "stand out", "pop out", "audible")],
            [("presence", 0.35), ("attack", 0.15), ("depth", -0.2)],
            scale: { a, d in
                guard let song = a.song, d >= 0 else { return Scale(1) }
                return song.bands.presence > a.drums.bands.presence + 3 ? Scale(1.3, "the song is busy in the presence range") : Scale(1)
            }),
    Concept(
        id: "fit", more: "matched to the song", less: "matched to the song",
        patterns: [
            JSRegex("\\b(?:fit|fits|match|matches|blend|blends|sit|sits|glue|gel|belong)\\b.*\\b(?:song|mix|track|record|band|music)\\b"),
            words("sit in the mix", "blend in", "fit in"),
        ],
        delta: { a in
            guard let a, let song = a.song else { return [("naturalness", 0.2), ("presence", 0.1)] }
            let ratio = song.centroidHz / Swift.max(1, a.drums.centroidHz)
            let tilt = ratio > 1.3 ? 0.25 : ratio < 0.77 ? -0.25 : 0
            let roomGap = song.decayMs - a.drums.decayMs
            return [
                ("brightness", tilt), ("air", tilt * 0.6), ("depth", roomGap > 80 ? 0.25 : 0), ("roominess", roomGap < -80 ? 0.2 : 0),
                ("consistency", 0.15),
            ]
        }),
    concept("kick", "more kick", "less kick", [words("kick", "kicks", "bass drum", "low end", "bottom", "bottom end", "lows", "bass")],
            [("kick_presence", 0.4), ("fullness", 0.1)], scale: { a, d in lowScale(a, d) }),
    concept("snare", "more snare", "less snare", [words("snare", "snares", "crack", "backbeat", "mids")], [("snare_body", 0.35), ("attack", 0.1)]),
    concept("cymbals", "more cymbals", "softer cymbals",
            [words("cymbal", "cymbals", "hats", "hi hat", "hi hats", "hihat", "hihats", "crash", "ride", "overheads", "wash")],
            [("air", 0.3), ("brightness", 0.1), ("harshness", -0.15)]),
]

// MARK: prompt parsing

private let lessRe = JSRegex(
    "\\b(?:less|fewer|reduce|reduced|lower|cut(?! through)|tame|remove|kill|lose|no|without|not|isn't|isnt|don't|dont|minus|too|dial back|dial down|back off|get rid of|fix|clean up|turn down|pull back|decrease|eliminate|avoid|stop)\\b")
private let moreRe = JSRegex(
    "\\b(?:more|add|extra|boost|increase|bring out|bring up|push|enhance|make it|give it|plus|turn up|emphasize|emphasise|accentuate|lots of|tons of|heaps of|lacks|lacking|missing|needs|need|want|wants)\\b")
private let intensityRes: [(JSRegex, Double)] = [
    (JSRegex("\\b(?:a (?:tiny|wee) bit|a hair|barely|tiny bit|just a touch|ever so slightly)\\b"), 0.3),
    (JSRegex("\\b(?:a bit|a little|a touch|slightly|subtly|somewhat|kinda|kind of|a tad|tad|gently|mildly|not too|little)\\b"), 0.5),
    (JSRegex("\\b(?:way|much|a lot|lots|really|very|super|seriously|heaps|tons|far|properly|so much|significantly)\\b"), 1.7),
    (JSRegex("\\b(?:extremely|massively|insanely|hugely|crazy|ridiculously|maximum|max|totally|completely|all the way)\\b"), 2.2),
]
private let gainStrong = JSRegex(
    "\\b(?:louder|quieter|too loud|too quiet|too soft|buried|drowned out|volume|level|turn(?: \\w+){0,3} (?:up|down)|(?:up|down) in the mix)\\b")
private let gainWeak = JSRegex("\\b(?:raise|lower|boost|reduce|more|less|up|down|higher|bring(?: \\w+){0,3} (?:up|down))\\b")
private let gainUp = JSRegex(
    "\\b(?:louder|too quiet|too soft|buried|drowned out|turn(?: \\w+){0,3} up|up in the mix|raise|boost|more|higher|bring(?: \\w+){0,3} up)\\b")
private let gainDown = JSRegex("\\b(?:quieter|too loud|turn(?: \\w+){0,3} down|down in the mix|lower|less|reduce|bring(?: \\w+){0,3} down)\\b")
private let songWords = JSRegex("\\b(?:song|music|track|backing|band|instrumental|the rest|guitars?|vocals?)\\b")
private let drumWords = JSRegex("\\b(?:drums?|kit|drumming|take|recording|my playing)\\b")
private let enoughRe = JSRegex("\\benough\\b")
private let loudRe = JSRegex("\\bloud\\b")
private let clauseSplit = JSRegex("[,;.!?\\n]+|\\b(?:and|but|while|plus|yet|though|although|also|then|whereas)\\b")
private let gainStep = 0.15
private let maxTotalDelta = 0.8

private let normalizers: [(JSRegex, String)] = [
    (JSRegex("[’‘`]"), "'"),
    (JSRegex("\\b(\\d0)'s\\b"), "$1s"),
    (JSRegex("\\bnineties\\b"), "90s"),
    (JSRegex("\\beighties\\b"), "80s"),
    (JSRegex("\\bseventies\\b"), "70s"),
    (JSRegex("\\bsixties\\b"), "60s"),
    (JSRegex("\\b'(\\d0)s\\b"), "$1s"),
    (JSRegex("(\\w)-(\\w)"), "$1 $2"), // lo-fi → lo fi, hi-hat → hi hat
    (JSRegex("&"), " and "),
    (JSRegex("\\s+"), " "),
]

private struct Hit {
    let concept: Concept
    let start: Int
    let end: Int
}

public enum LocalMix {
    /// Every concept id the interpreter knows.
    public static let vocabulary: [String] = concepts.map(\.id)

    static func normalize(_ prompt: String) -> String {
        normalizers.reduce(prompt.lowercased()) { s, n in n.0.replaceAll(s, n.1) }
    }

    private static func findConcepts(_ clause: String) -> [Hit] {
        var hits: [Hit] = []
        for c in concepts {
            for re in c.patterns {
                for m in re.all(clause) { hits.append(Hit(concept: c, start: m.index, end: m.end)) }
            }
        }
        // Longest match wins where matches overlap; one hit per concept per clause.
        let sorted = hits.enumerated().sorted { a, b in
            let la = a.element.end - a.element.start, lb = b.element.end - b.element.start
            if la != lb { return la > lb }
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            return a.offset < b.offset
        }.map(\.element)
        var kept: [Hit] = []
        for h in sorted {
            if kept.contains(where: { h.start < $0.end && $0.start < h.end }) { continue }
            if kept.contains(where: { $0.concept.id == h.concept.id }) { continue }
            kept.append(h)
        }
        return kept.enumerated().sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }.map(\.element)
    }

    static func lastMatchBefore(_ re: JSRegex, _ clause: String, _ pos: Int) -> Int {
        var last = -1
        for m in re.all(clause) {
            if m.index >= pos { break }
            last = m.index
        }
        return last
    }

    private static func direction(_ clause: String, _ hit: Hit) -> Double {
        let less = lastMatchBefore(lessRe, clause, hit.start)
        let more = lastMatchBefore(moreRe, clause, hit.start)
        if less < 0 && more < 0 { return hit.concept.problem ? -1 : 1 }
        // "not bright enough": a lack, so add it.
        if less > more && enoughRe.test(clause.jsSlice(hit.end)) { return 1 }
        return less > more ? -1 : 1
    }

    static func intensity(_ clause: String) -> Double {
        for (re, k) in intensityRes where re.test(clause) { return k }
        return 1
    }

    static func intensityWord(_ k: Double) -> String {
        k <= 0.3 ? "a touch " : k < 1 ? "a bit " : k > 2 ? "much much " : k > 1 ? "much " : ""
    }

    private enum GainTarget: String { case songGain, drumGain }

    private static func gainFor(_ clause: String, hasConcepts: Bool) -> (target: GainTarget, dir: Double)? {
        let song = songWords.search(clause)
        let drums = drumWords.search(clause)
        let strong = gainStrong.test(clause)
        // Weak verbs count only with a target and no sound word in the clause.
        if !strong && (hasConcepts || (song < 0 && drums < 0) || !gainWeak.test(clause)) { return nil }
        let up = lastMatchBefore(gainUp, clause, Int.max)
        let down = lastMatchBefore(gainDown, clause, Int.max)
        if up < 0 && down < 0 { return nil }
        let target: GainTarget = song >= 0 && (drums < 0 || song < drums) ? .songGain : .drumGain
        return (target, up > down ? 1 : -1)
    }

    /// Interpret `prompt` against the current mix. Deterministic; no I/O.
    public static func interpret(_ input: LocalMixInput) -> LocalMixResult {
        let analysis = input.analysis
        let text = normalize(input.prompt)
        let clauses = clauseSplit.split(text).map(\.jsTrimmed).filter { !$0.isEmpty }
        let keys = MixKnobs.keys

        var base = Dictionary(uniqueKeysWithValues: keys.map { ($0, MixKnobs.effectiveValue($0, input.values[$0])) })
        var total: [String: Double] = [:]
        var songGain = input.songGain, drumGain = input.drumGain
        var songTouched = false, drumTouched = false
        var matched: [String] = []
        var parts: [String] = []

        for clause in clauses {
            let hits = findConcepts(clause)
            let k = intensity(clause)
            // Gain requests that aren't also sound words ("drums louder").
            let gain = gainFor(clause, hasConcepts: !hits.isEmpty)
            if let gain {
                if gain.target == .songGain {
                    songGain = MixKnobs.clampGain(songGain + gain.dir * gainStep * k)
                    songTouched = true
                } else {
                    drumGain = MixKnobs.clampGain(drumGain + gain.dir * gainStep * k)
                    drumTouched = true
                }
                matched.append("\(gain.dir < 0 ? "-" : "")\(gain.target.rawValue)")
                parts.append("\(intensityWord(k))\(gain.dir > 0 ? "louder" : "quieter") \(gain.target == .songGain ? "song" : "drums")")
            }

            for hit in hits {
                let c = hit.concept
                // "the song is too loud" is a level request, not "less compressed".
                if gain != nil && c.id == "compressed" && loudRe.test(clause.jsSlice(hit.start, hit.end)) { continue }
                let dir = direction(clause, hit)
                matched.append("\(dir < 0 ? "-" : "")\(c.id)")
                if c.op == .reset {
                    base = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0.0) })
                    total.removeAll()
                    parts.append(c.more)
                    continue
                }
                if c.op == .natural && dir < 0 {
                    parts.append(c.less)
                    continue
                }
                if c.op == .natural {
                    let pull = Swift.min(0.8, 0.4 * k)
                    for t in keys { base[t] = base[t]! * (1 - pull) }
                    for t in total.keys { total[t]! *= 1 - pull }
                }
                let s = (c.scale != nil && analysis != nil) ? c.scale!(analysis!, dir) : Scale(1)
                for (t, d) in c.delta(analysis) {
                    total[t] = (total[t] ?? 0) + d * dir * k * s.k
                }
                let note = s.note.map { " (\(s.k < 1 ? "gently" : "more"): \($0))" } ?? ""
                parts.append("\(intensityWord(k))\(dir > 0 ? c.more : c.less)\(note)")
            }
        }

        // Width does nothing on a mono take; say so rather than move a dead knob.
        if let analysis, analysis.drums.stereoWidth == nil, let w = total["width"], w != 0, !w.isNaN {
            total["width"] = nil
            parts.append("(width skipped: the take is mono)")
        }

        var values: KnobValues = [:]
        for t in keys {
            let d = Swift.max(-maxTotalDelta, Swift.min(maxTotalDelta, total[t] ?? 0))
            values[t] = MixKnobs.clampKnob(t, base[t]! + d)
        }

        let explanation = matched.isEmpty
            ? "The offline interpreter didn’t recognise any sound words. Try e.g. “warmer”, “less boomy”, “more room”, “punchy and dry”, “drums louder”."
            : "Offline interpreter: \(parts.joined(separator: ", "))."

        return LocalMixResult(
            suggestion: MixSuggestion(
                values: values, songGain: songTouched ? songGain : nil, drumGain: drumTouched ? drumGain : nil, explanation: explanation),
            matched: matched)
    }
}
