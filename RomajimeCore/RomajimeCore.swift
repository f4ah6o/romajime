import Foundation

public struct ConversionContext: Equatable, Sendable {
    public var timestamp: Date
    public var os: String
    public var appName: String?
    public var processID: Int?
    public var windowTitle: String?

    public init(
        timestamp: Date = Date(),
        os: String = "macos",
        appName: String? = nil,
        processID: Int? = nil,
        windowTitle: String? = nil
    ) {
        self.timestamp = timestamp
        self.os = os
        self.appName = appName
        self.processID = processID
        self.windowTitle = windowTitle
    }
}

public struct ConversionRequest: Equatable, Sendable {
    public var raw: String
    public var memory: String
    public var context: ConversionContext
    public var kanaCandidate: String?

    public init(raw: String, memory: String = "", context: ConversionContext = ConversionContext(), kanaCandidate: String? = nil) {
        self.raw = raw
        self.memory = memory
        self.context = context
        self.kanaCandidate = kanaCandidate
    }
}

public struct ConversionCandidate: Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var label: String
    public var confidence: Double

    public init(id: String, text: String, label: String, confidence: Double) {
        self.id = id
        self.text = text
        self.label = label
        self.confidence = confidence
    }
}

public struct ConversionResult: Equatable, Sendable {
    public var converted: String
    public var refined: String
    public var confidence: Double
    public var candidates: [ConversionCandidate]

    public init(converted: String, refined: String, confidence: Double, candidates: [ConversionCandidate]) {
        self.converted = converted
        self.refined = refined
        self.confidence = confidence
        self.candidates = candidates
    }
}

public protocol ConversionBackend: Sendable {
    func convert(_ request: ConversionRequest) throws -> ConversionResult
}

public struct KanjiConversionRequest: Equatable, Sendable {
    public var raw: String
    public var kana: String
    public var memory: String

    public init(raw: String, kana: String, memory: String = "") {
        self.raw = raw
        self.kana = kana
        self.memory = memory
    }
}

public protocol KanjiConversionBackend: Sendable {
    func convertToKanji(_ request: KanjiConversionRequest) async throws -> String
    func prewarm()
}

public extension KanjiConversionBackend {
    func prewarm() {}
}

public enum KanjiPromptBuilder {
    public static func prompt(for request: KanjiConversionRequest) -> String {
        var sections: [String] = []
        sections.append("""
        You convert a Japanese draft typed in romaji into natural written Japanese.
        Use kanji where a fluent writer would. Output ONLY the converted Japanese text — no explanations, no quotes.

        Rules:
        - Do not answer, summarize, or extend the draft. Convert it only.
        - Preserve embedded English words, numbers, spaces, and line breaks exactly as written.
        """)
        let memory = request.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty {
            sections.append("""
            Prefer the terminology below when a source term appears.

            Terminology:
            \(memory)
            """)
        }
        sections.append("""
        Romaji draft:
        \(request.raw)

        Kana reading:
        \(request.kana)

        Converted Japanese:
        """)
        return sections.joined(separator: "\n\n")
    }
}

public struct IdleConversionPolicy: Equatable, Sendable {
    public var baseDelay: TimeInterval
    public var fastTypingDelay: TimeInterval
    public var fastTypingThreshold: TimeInterval
    public var sentenceBoundaryDelay: TimeInterval
    public var maxComposingDelay: TimeInterval

    public init(
        baseDelay: TimeInterval = 1.2,
        fastTypingDelay: TimeInterval = 1.8,
        fastTypingThreshold: TimeInterval = 0.18,
        sentenceBoundaryDelay: TimeInterval = 0.45,
        maxComposingDelay: TimeInterval = 8.0
    ) {
        self.baseDelay = baseDelay
        self.fastTypingDelay = fastTypingDelay
        self.fastTypingThreshold = fastTypingThreshold
        self.sentenceBoundaryDelay = sentenceBoundaryDelay
        self.maxComposingDelay = maxComposingDelay
    }

    public func delay(afterKeystrokeInterval interval: TimeInterval?) -> TimeInterval {
        guard let interval else {
            return baseDelay
        }
        return interval < fastTypingThreshold ? fastTypingDelay : baseDelay
    }

    public func delay(for buffer: String, afterKeystrokeInterval interval: TimeInterval?) -> TimeInterval {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return baseDelay
        }
        if isSentenceBoundary(buffer: buffer, trimmed: trimmed) {
            return sentenceBoundaryDelay
        }
        return delay(afterKeystrokeInterval: interval)
    }

    public func shouldConvert(buffer: String, elapsed: TimeInterval?) -> Bool {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if let elapsed, elapsed >= maxComposingDelay {
            return true
        }
        if isProbablyIncompleteRomaji(trimmed) {
            return false
        }
        if isSentenceBoundary(buffer: buffer, trimmed: trimmed) {
            return true
        }
        return trimmed.count >= 80
    }

    public func shouldAskIntelligence(buffer: String, elapsed: TimeInterval?) -> Bool {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !shouldConvert(buffer: buffer, elapsed: elapsed) else {
            return false
        }
        return trimmed.count >= 24 && !isProbablyIncompleteRomaji(trimmed)
    }

    private func isSentenceBoundary(buffer: String, trimmed: String) -> Bool {
        guard let last = trimmed.last else {
            return false
        }
        return ".。!?！？".contains(last) || buffer.hasSuffix("\n")
    }

    private func isProbablyIncompleteRomaji(_ text: String) -> Bool {
        let tail = text.split { $0.isWhitespace }.last.map(String.init) ?? text
        guard let last = tail.last?.lowercased().first else {
            return false
        }
        return tail.count <= 3 && "bcdfghjklmnpqrstvwxyz".contains(last)
    }
}

public struct RomajimeConfig: Codable, Equatable, Sendable {
    public var keyBindings: KeyBindings
    public var timing: Timing
    public var learning: LearningConfig

    public init(keyBindings: KeyBindings = KeyBindings(), timing: Timing = Timing(), learning: LearningConfig = LearningConfig()) {
        self.keyBindings = keyBindings
        self.timing = timing
        self.learning = learning
    }

    private enum CodingKeys: String, CodingKey {
        case keyBindings
        case timing
        case learning
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.keyBindings = try values.decodeIfPresent(KeyBindings.self, forKey: .keyBindings) ?? KeyBindings()
        self.timing = try values.decodeIfPresent(Timing.self, forKey: .timing) ?? Timing()
        self.learning = try values.decodeIfPresent(LearningConfig.self, forKey: .learning) ?? LearningConfig()
    }
}

// Opt-in local learning: nothing is logged unless the user sets
// {"learning": {"enabled": true}} in config.json.
public struct LearningConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxLogEntries: Int

    public init(enabled: Bool = false, maxLogEntries: Int = 20000) {
        self.enabled = enabled
        self.maxLogEntries = maxLogEntries
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxLogEntries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.maxLogEntries = try values.decodeIfPresent(Int.self, forKey: .maxLogEntries) ?? 20000
    }
}

public struct KeyBindings: Codable, Equatable, Sendable {
    public var bufferSpace: KeyStroke
    public var newlineCommit: [KeyStroke]
    public var ignoredCommit: [KeyStroke]
    public var deleteBackward: KeyStroke
    public var convertOrJump: KeyStroke
    public var jumpConfirm: KeyStroke
    public var jumpCancel: KeyStroke

    public init(
        bufferSpace: KeyStroke = KeyStroke(keyCode: 49),
        newlineCommit: [KeyStroke] = [KeyStroke(keyCode: 36), KeyStroke(keyCode: 76)],
        ignoredCommit: [KeyStroke] = [],
        deleteBackward: KeyStroke = KeyStroke(keyCode: 51),
        convertOrJump: KeyStroke = KeyStroke(keyCode: 53),
        jumpConfirm: KeyStroke = KeyStroke(keyCode: 49),
        jumpCancel: KeyStroke = KeyStroke(keyCode: 53)
    ) {
        self.bufferSpace = bufferSpace
        self.newlineCommit = newlineCommit
        self.ignoredCommit = ignoredCommit
        self.deleteBackward = deleteBackward
        self.convertOrJump = convertOrJump
        self.jumpConfirm = jumpConfirm
        self.jumpCancel = jumpCancel
    }

    private enum CodingKeys: String, CodingKey {
        case bufferSpace
        case newlineCommit
        case ignoredCommit
        case deleteBackward
        case convertOrJump
        case jumpConfirm
        case jumpCancel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.bufferSpace = try values.decodeIfPresent(KeyStroke.self, forKey: .bufferSpace) ?? KeyStroke(keyCode: 49)
        if let newlineCommit = try values.decodeIfPresent([KeyStroke].self, forKey: .newlineCommit) {
            self.newlineCommit = newlineCommit
        } else if values.contains(.ignoredCommit) {
            self.newlineCommit = []
        } else {
            self.newlineCommit = [KeyStroke(keyCode: 36), KeyStroke(keyCode: 76)]
        }
        self.ignoredCommit = try values.decodeIfPresent([KeyStroke].self, forKey: .ignoredCommit) ?? []
        self.deleteBackward = try values.decodeIfPresent(KeyStroke.self, forKey: .deleteBackward) ?? KeyStroke(keyCode: 51)
        self.convertOrJump = try values.decodeIfPresent(KeyStroke.self, forKey: .convertOrJump) ?? KeyStroke(keyCode: 53)
        self.jumpConfirm = try values.decodeIfPresent(KeyStroke.self, forKey: .jumpConfirm) ?? KeyStroke(keyCode: 49)
        self.jumpCancel = try values.decodeIfPresent(KeyStroke.self, forKey: .jumpCancel) ?? KeyStroke(keyCode: 53)
    }
}

public struct KeyStroke: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var requiredModifiers: UInt?

    public init(keyCode: UInt16, requiredModifiers: UInt? = nil) {
        self.keyCode = keyCode
        self.requiredModifiers = requiredModifiers
    }
}

public struct Timing: Codable, Equatable, Sendable {
    public var idleBaseDelay: TimeInterval
    public var idleFastTypingDelay: TimeInterval
    public var idleFastTypingThreshold: TimeInterval
    public var idleSentenceBoundaryDelay: TimeInterval
    public var maxComposingDelay: TimeInterval
    public var localIntelligenceEnabled: Bool
    public var localIntelligenceTimeout: TimeInterval
    public var kanjiConversionEnabled: Bool
    public var kanjiConversionTimeout: TimeInterval
    public var jumpModeTimeout: TimeInterval

    public init(
        idleBaseDelay: TimeInterval = 1.2,
        idleFastTypingDelay: TimeInterval = 1.8,
        idleFastTypingThreshold: TimeInterval = 0.18,
        idleSentenceBoundaryDelay: TimeInterval = 0.45,
        maxComposingDelay: TimeInterval = 8.0,
        localIntelligenceEnabled: Bool = true,
        localIntelligenceTimeout: TimeInterval = 0.3,
        kanjiConversionEnabled: Bool = true,
        kanjiConversionTimeout: TimeInterval = 2.0,
        jumpModeTimeout: TimeInterval = 3.0
    ) {
        self.idleBaseDelay = idleBaseDelay
        self.idleFastTypingDelay = idleFastTypingDelay
        self.idleFastTypingThreshold = idleFastTypingThreshold
        self.idleSentenceBoundaryDelay = idleSentenceBoundaryDelay
        self.maxComposingDelay = maxComposingDelay
        self.localIntelligenceEnabled = localIntelligenceEnabled
        self.localIntelligenceTimeout = localIntelligenceTimeout
        self.kanjiConversionEnabled = kanjiConversionEnabled
        self.kanjiConversionTimeout = kanjiConversionTimeout
        self.jumpModeTimeout = jumpModeTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case idleBaseDelay
        case idleFastTypingDelay
        case idleFastTypingThreshold
        case idleSentenceBoundaryDelay
        case maxComposingDelay
        case localIntelligenceEnabled
        case localIntelligenceTimeout
        case kanjiConversionEnabled
        case kanjiConversionTimeout
        case jumpModeTimeout
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.idleBaseDelay = try values.decodeIfPresent(TimeInterval.self, forKey: .idleBaseDelay) ?? 1.2
        self.idleFastTypingDelay = try values.decodeIfPresent(TimeInterval.self, forKey: .idleFastTypingDelay) ?? 1.8
        self.idleFastTypingThreshold = try values.decodeIfPresent(TimeInterval.self, forKey: .idleFastTypingThreshold) ?? 0.18
        self.idleSentenceBoundaryDelay = try values.decodeIfPresent(TimeInterval.self, forKey: .idleSentenceBoundaryDelay) ?? 0.45
        self.maxComposingDelay = try values.decodeIfPresent(TimeInterval.self, forKey: .maxComposingDelay) ?? 8.0
        self.localIntelligenceEnabled = try values.decodeIfPresent(Bool.self, forKey: .localIntelligenceEnabled) ?? true
        self.localIntelligenceTimeout = try values.decodeIfPresent(TimeInterval.self, forKey: .localIntelligenceTimeout) ?? 0.3
        self.kanjiConversionEnabled = try values.decodeIfPresent(Bool.self, forKey: .kanjiConversionEnabled) ?? true
        self.kanjiConversionTimeout = try values.decodeIfPresent(TimeInterval.self, forKey: .kanjiConversionTimeout) ?? 2.0
        self.jumpModeTimeout = try values.decodeIfPresent(TimeInterval.self, forKey: .jumpModeTimeout) ?? 3.0
    }
}

public struct JumpTarget: Equatable, Sendable {
    public var label: String
    public var text: String
    public var range: NSRange

    public init(label: String, text: String, range: NSRange) {
        self.label = label
        self.text = text
        self.range = range
    }
}

public enum JumpLabelGenerator {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    public static func label(for index: Int) -> String {
        precondition(index >= 0)
        if index < alphabet.count {
            return String(alphabet[index])
        }

        let adjusted = index - alphabet.count
        let first = alphabet[adjusted / alphabet.count]
        let second = alphabet[adjusted % alphabet.count]
        return String([first, second])
    }

    public static func numericLabel(for index: Int) -> String {
        precondition(index >= 0)
        return String(index + 1)
    }

    public static func labels(for index: Int) -> [String] {
        [label(for: index), numericLabel(for: index)]
    }
}

public enum TextUnitScanner {
    private static let hardSeparators = CharacterSet.newlines
        .union(CharacterSet(charactersIn: "。、，．！？!?;；:：.,"))

    public static func jumpTargets(in text: String, baseLocation: Int = 0) -> [JumpTarget] {
        var targets: [JumpTarget] = []
        var current = ""
        var currentStart: Int?
        var utf16Offset = 0

        func finishRun(at endOffset: Int) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = currentStart, !trimmed.isEmpty else {
                current.removeAll()
                currentStart = nil
                return
            }
            let leadingWhitespace = current.prefix { $0.isWhitespace }.map { String($0).utf16.count }.reduce(0, +)
            let label = JumpLabelGenerator.label(for: targets.count)
            targets.append(.init(label: label, text: trimmed, range: NSRange(location: baseLocation + start + leadingWhitespace, length: trimmed.utf16.count)))
            current.removeAll()
            currentStart = nil
        }

        for character in text {
            let length = String(character).utf16.count
            if currentStart == nil {
                currentStart = utf16Offset
            }
            current.append(character)
            if isHardSeparator(character) {
                finishRun(at: utf16Offset + length)
            }
            utf16Offset += length
        }
        finishRun(at: utf16Offset)
        return targets
    }

    private static func isHardSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { hardSeparators.contains($0) }
    }
}

public enum LineJumpScanner {
    public static func jumpTargets(in text: String, baseLocation: Int = 0) -> [JumpTarget] {
        var targets: [JumpTarget] = []
        var utf16Offset = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineText = String(line)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let leadingWhitespace = lineText.prefix { $0.isWhitespace }.map { String($0).utf16.count }.reduce(0, +)
                let label = JumpLabelGenerator.label(for: targets.count)
                targets.append(.init(label: label, text: trimmed, range: NSRange(location: baseLocation + utf16Offset + leadingWhitespace, length: trimmed.utf16.count)))
            }
            utf16Offset += lineText.utf16.count + 1
        }
        return targets
    }
}

public final class RuleBasedConversionBackend: ConversionBackend, @unchecked Sendable {
    private let dictionary: RomajiDictionary

    public init(dictionary: RomajiDictionary = .default) {
        self.dictionary = dictionary
    }

    public func convert(_ request: ConversionRequest) throws -> ConversionResult {
        let normalized = CompositionNormalizer.normalizeWhitespace(request.raw)
        let protected = MemoryTermRewriter.apply(memory: request.memory, to: normalized)
        let kana = dictionary.convert(protected)
        let memoryApplied = MemoryTermRewriter.apply(memory: request.memory, to: kana)
        let candidates = CandidateGenerator.candidates(raw: normalized, kana: kana, memoryApplied: memoryApplied)
        let first = candidates.first?.text ?? normalized
        return ConversionResult(converted: first, refined: first, confidence: candidates.first?.confidence ?? 0, candidates: candidates)
    }
}

public struct CompositionState: Equatable, Sendable {
    public private(set) var buffer: String = ""
    public private(set) var candidates: [ConversionCandidate] = []
    public private(set) var selectedCandidateIndex: Int = 0

    public var isComposing: Bool {
        !buffer.isEmpty
    }

    public var selectedCandidate: ConversionCandidate? {
        guard candidates.indices.contains(selectedCandidateIndex) else {
            return nil
        }
        return candidates[selectedCandidateIndex]
    }

    public init() {}

    public mutating func append(_ character: Character) {
        buffer.append(character)
        candidates.removeAll()
        selectedCandidateIndex = 0
    }

    public mutating func deleteBackward() {
        guard !buffer.isEmpty else {
            return
        }
        buffer.removeLast()
        candidates.removeAll()
        selectedCandidateIndex = 0
    }

    public mutating func setCandidates(_ newCandidates: [ConversionCandidate]) {
        candidates = newCandidates
        selectedCandidateIndex = 0
    }

    public mutating func selectNextCandidate() {
        guard !candidates.isEmpty else {
            return
        }
        selectedCandidateIndex = (selectedCandidateIndex + 1) % candidates.count
    }

    public mutating func clear() {
        buffer.removeAll()
        candidates.removeAll()
        selectedCandidateIndex = 0
    }
}

public enum CompositionNormalizer {
    private static let acceptedPunctuation: Set<Character> = [" ", ".", ",", "?", "!", "'", "-", ":", ";", "(", ")", "[", "]", "\""]

    public static func normalizeWhitespace(_ input: String) -> String {
        input.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split { $0.isWhitespace }.joined(separator: " ") }
            .joined(separator: "\n")
    }

    // Bufferable only while already composing — never starts a composition,
    // so a bare "/" or digit outside a draft still reaches the app directly.
    private static let composingOnlyCharacters: Set<Character> = [
        "/", "$", "_", "@", "#", "`", "&", "=", "+", "~",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
    ]

    public static func acceptsRomajiCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar) && scalar.isASCII || acceptedPunctuation.contains(character)
    }

    public static func acceptsComposingCharacter(_ character: Character) -> Bool {
        acceptsRomajiCharacter(character) || composingOnlyCharacters.contains(character)
    }
}

public enum CandidateGenerator {
    public static func candidates(raw: String, kana: String, memoryApplied: String? = nil) -> [ConversionCandidate] {
        var values: [ConversionCandidate] = []
        if !kana.isEmpty {
            values.append(.init(id: "kana", text: kana, label: "Kana", confidence: 0.7))
        }
        if let memoryApplied, !memoryApplied.isEmpty, memoryApplied != kana {
            values.append(.init(id: "memory", text: memoryApplied, label: "Memory", confidence: 0.75))
        }
        if !raw.isEmpty, raw != kana {
            values.append(.init(id: "raw", text: raw, label: "Raw", confidence: 0.1))
        }
        return values
    }

    public static func mergingKanji(_ kanji: String?, into candidates: [ConversionCandidate], memory: String = "") -> [ConversionCandidate] {
        guard let kanji else {
            return candidates
        }
        let trimmed = kanji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return candidates
        }
        let kanaText = candidates.first(where: { $0.id == "kana" })?.text ?? ""
        if !kanaText.isEmpty, trimmed.count > kanaText.count * 3 {
            return candidates
        }
        if kanaText.contains("\n"), !trimmed.contains("\n") {
            return candidates
        }
        let rewritten = MemoryTermRewriter.apply(memory: memory, to: trimmed)
        if rewritten == kanaText {
            return candidates
        }
        return [.init(id: "kanji", text: rewritten, label: "Kanji", confidence: 0.9)] + candidates
    }
}

public enum MemoryTermRewriter {
    public static func apply(memory: String, to text: String) -> String {
        var output = text
        for line in memory.split(separator: "\n") {
            let parts = line.split(separator: "->", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                continue
            }
            output = output.replacingOccurrences(of: parts[0], with: parts[1])
        }
        return output
    }
}

public struct RomajiDictionary: Sendable {
    private let table: [String: String]
    private let extraEnglishTerms: Set<String>

    public static let `default` = RomajiDictionary(table: DefaultRomajiTable.values)

    public init(table: [String: String], englishTerms: Set<String> = []) {
        self.table = table
        self.extraEnglishTerms = Set(englishTerms.map { $0.lowercased() })
    }

    // Built-in table plus the user's learned lexicon: user romaji entries win
    // over defaults, and learned English terms extend EnglishTermGuard.
    public static func withLexicon(_ lexicon: UserLexicon) -> RomajiDictionary {
        RomajiDictionary(
            table: DefaultRomajiTable.values.merging(lexicon.romajiEntries) { _, user in user },
            englishTerms: lexicon.englishTerms
        )
    }

    // Characters that mark the following run as literal text: slash commands
    // (/clear), shell variables ($home), identifiers (_name, @user, #tag),
    // inline code (`kana`), and option-like sequences.
    private static let literalPrefixes: Set<Character> = ["/", "$", "_", "@", "#", "`", "&", "=", "+", "~"]

    public func convert(_ input: String) -> String {
        var output = ""
        var run = ""
        var runIsLiteral = false

        for character in input {
            if isRomajiScalar(character) {
                run.append(character)
                continue
            }

            if !run.isEmpty {
                output += runIsLiteral ? run : convertRun(run)
                run.removeAll()
            }
            output.append(character)
            // A run glued to a preceding letter or digit is the tail of a
            // mixed word ("Renovate" → "R" + "enovate", "v1up"), not romaji;
            // a literal prefix (/, $, …) protects the run the same way.
            runIsLiteral = (character.isASCII && (character.isLetter || character.isNumber))
                || Self.literalPrefixes.contains(character)
        }

        if !run.isEmpty {
            output += runIsLiteral ? run : convertRun(run)
        }

        return output
    }

    private func convertRun(_ run: String) -> String {
        if EnglishTermGuard.isLikelyEnglish(run) || extraEnglishTerms.contains(run.lowercased()) {
            return run
        }
        let converted = convertConvertibleRun(run)
        if converted.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) {
            return run
        }
        return converted
    }

    private func convertConvertibleRun(_ input: String) -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let rest = String(input[index...]).lowercased()
            if let matched = longestMatch(in: rest) {
                output += matched.kana
                index = input.index(index, offsetBy: matched.romaji.count)
                continue
            }

            if isDoubleConsonantStart(rest) {
                output += "っ"
                index = input.index(after: index)
                continue
            }

            if rest.hasPrefix("n") {
                let next = input.index(after: index)
                if next == input.endIndex || shouldCommitN(before: input[next]) {
                    output += "ん"
                    index = next
                    continue
                }
            }

            output.append(character)
            index = input.index(after: index)
        }
        return output
    }

    private func longestMatch(in text: String) -> (romaji: String, kana: String)? {
        let maxLength = min(4, text.count)
        for length in stride(from: maxLength, through: 1, by: -1) {
            let prefix = String(text.prefix(length))
            if let kana = table[prefix] {
                return (prefix, kana)
            }
        }
        return nil
    }

    private func isRomajiScalar(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || $0 == "'" || $0 == "-") }
    }

    private func isDoubleConsonantStart(_ text: String) -> Bool {
        guard text.count >= 2 else {
            return false
        }
        let first = text[text.startIndex]
        let second = text[text.index(after: text.startIndex)]
        return first == second && !"aeioun".contains(first)
    }

    private func shouldCommitN(before character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, scalar.isASCII else {
            return true
        }
        return !"aiueoyn".contains(Character(character.lowercased()))
    }
}

// Common English/dev words that also happen to parse as valid romaji
// (e.g. "fixture" → ふぃっれ, "token" → とけん) stay ASCII. The list is
// curated: words a Japanese typist plausibly uses AS romaji (made, demo,
// node, site, kana, mono…) must NOT appear here.
enum EnglishTermGuard {
    static func isLikelyEnglish(_ run: String) -> Bool {
        words.contains(run.lowercased())
    }

    private static let words: Set<String> = [
        "abi", "additive", "envelope", "idea", "message", "origin", "rename",
        "size", "validation",
        "api", "audio", "base", "baseline", "batch", "branch", "build", "cache",
        "claude", "client", "code", "codex", "commit", "data", "debug", "deploy",
        "diff", "docker", "done", "error", "file", "fixture", "freeze", "gemini",
        "hidden", "hono", "html", "image", "index", "inference", "issue", "json",
        "linux", "live", "liveview", "macos", "main", "merge", "model", "module",
        "moonbit", "native", "push", "python", "query", "react", "reason",
        "rebase", "render", "repo", "resume", "retention", "retry", "route",
        "rule", "runtime", "rust", "schema", "scope", "server", "shape", "source",
        "state", "swift", "table", "tauri", "test", "thread", "timeline", "token",
        "ubuntu", "value", "video", "view", "web"
    ]
}

private enum DefaultRomajiTable {
    static let values: [String: String] = [
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "sa": "さ", "shi": "し", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "ta": "た", "chi": "ち", "ti": "ち", "tsu": "つ", "tu": "つ", "te": "て", "to": "と",
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "ha": "は", "hi": "ひ", "fu": "ふ", "hu": "ふ", "he": "へ", "ho": "ほ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "ya": "や", "yu": "ゆ", "yo": "よ",
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "wa": "わ", "wo": "を", "nn": "ん", "n'": "ん",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "za": "ざ", "ji": "じ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
        "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
        "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
        "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        "ja": "じゃ", "ju": "じゅ", "jo": "じょ", "je": "じぇ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
        "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
        "wi": "うぃ", "we": "うぇ",
        "che": "ちぇ", "she": "しぇ",
        "dzu": "づ", "dzi": "ぢ",
        "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
        "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
        "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
        "tchi": "っち", "tcha": "っちゃ", "tchu": "っちゅ", "tcho": "っちょ",
        "thi": "てぃ", "dhi": "でぃ", "twu": "とぅ", "dwu": "どぅ",
        "fyu": "ふゅ", "vyu": "ゔゅ", "wyi": "ゐ", "wye": "ゑ",
        "xtu": "っ", "ltu": "っ", "xtsu": "っ", "ltsu": "っ",
        "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
        "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
        "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ",
        "lya": "ゃ", "lyu": "ゅ", "lyo": "ょ"
    ]
}
