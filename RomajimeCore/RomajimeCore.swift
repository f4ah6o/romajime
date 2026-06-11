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

public struct IdleConversionPolicy: Equatable, Sendable {
    public var baseDelay: TimeInterval
    public var fastTypingDelay: TimeInterval
    public var fastTypingThreshold: TimeInterval

    public init(baseDelay: TimeInterval = 1.2, fastTypingDelay: TimeInterval = 1.8, fastTypingThreshold: TimeInterval = 0.18) {
        self.baseDelay = baseDelay
        self.fastTypingDelay = fastTypingDelay
        self.fastTypingThreshold = fastTypingThreshold
    }

    public func delay(afterKeystrokeInterval interval: TimeInterval?) -> TimeInterval {
        guard let interval else {
            return baseDelay
        }
        return interval < fastTypingThreshold ? fastTypingDelay : baseDelay
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
        input.split { $0.isWhitespace }.joined(separator: " ")
    }

    public static func acceptsRomajiCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar) && scalar.isASCII || acceptedPunctuation.contains(character)
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

    public static let `default` = RomajiDictionary(table: DefaultRomajiTable.values)

    public init(table: [String: String]) {
        self.table = table
    }

    public func convert(_ input: String) -> String {
        var output = ""
        var run = ""

        for character in input {
            if isRomajiScalar(character) {
                run.append(character)
                continue
            }

            if !run.isEmpty {
                output += convertRun(run)
                run.removeAll()
            }
            output.append(character)
        }

        if !run.isEmpty {
            output += convertRun(run)
        }

        return output
    }

    private func convertRun(_ run: String) -> String {
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
        "ja": "じゃ", "ju": "じゅ", "jo": "じょ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ"
    ]
}
