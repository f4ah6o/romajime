import Foundation

// Local-only learning: the IME logs (romaji, committed text) pairs when the
// user opts in, and a mining pass turns systematic mismatches into entries
// in plain-text lexicon files the engine loads at conversion time. Nothing
// ever leaves the machine, and every learned artifact is human-readable.

public struct UserLexicon: Equatable, Sendable {
    public var englishTerms: Set<String>
    public var romajiEntries: [String: String]

    public static let englishTermsFile = "english_terms.txt"
    public static let romajiEntriesFile = "user_romaji.tsv"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Romajime")
    }

    public init(englishTerms: Set<String> = [], romajiEntries: [String: String] = [:]) {
        self.englishTerms = englishTerms
        self.romajiEntries = romajiEntries
    }

    public static func load(from directory: URL = defaultDirectory) -> UserLexicon {
        var lexicon = UserLexicon()
        if let text = try? String(contentsOf: directory.appendingPathComponent(englishTermsFile), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let term = line.trimmingCharacters(in: .whitespaces).lowercased()
                if !term.isEmpty, !term.hasPrefix("#") {
                    lexicon.englishTerms.insert(term)
                }
            }
        }
        if let text = try? String(contentsOf: directory.appendingPathComponent(romajiEntriesFile), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard !line.hasPrefix("#") else {
                    continue
                }
                let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                    lexicon.romajiEntries[parts[0].lowercased()] = parts[1]
                }
            }
        }
        return lexicon
    }
}

public struct LearningLogEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var raw: String
    public var committed: String

    public init(timestamp: Date = Date(), raw: String, committed: String) {
        self.timestamp = timestamp
        self.raw = raw
        self.committed = committed
    }
}

// Appends commit pairs to log.jsonl. The file is created owner-only (0600),
// holds no app or window context, and is trimmed so it cannot grow without
// bound. Logging is opt-in via config (learning.enabled).
public final class ConversionLogger: @unchecked Sendable {
    public static let logFile = "log.jsonl"

    private let directory: URL
    private let maxEntries: Int
    private let encoder: JSONEncoder

    public init(directory: URL = UserLexicon.defaultDirectory, maxEntries: Int = 20000) {
        self.directory = directory
        self.maxEntries = maxEntries
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    private var logURL: URL {
        directory.appendingPathComponent(Self.logFile)
    }

    public func append(raw: String, committed: String) {
        guard !raw.isEmpty, !committed.isEmpty else {
            return
        }
        guard let data = try? encoder.encode(LearningLogEntry(raw: raw, committed: committed)) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(
                    atPath: logURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
        } catch {
            return
        }
        trimIfNeeded()
    }

    public static func readEntries(from directory: URL = UserLexicon.defaultDirectory) -> [LearningLogEntry] {
        let url = directory.appendingPathComponent(logFile)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(LearningLogEntry.self, from: Data(line.utf8))
        }
    }

    private func trimIfNeeded() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxEntries else {
            return
        }
        let kept = lines.suffix(maxEntries / 2).joined(separator: "\n") + "\n"
        try? kept.write(to: logURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }
}

public enum LearningMiner {
    public struct Report: Equatable, Sendable {
        public var entriesScanned: Int
        public var addedEnglishTerms: [String]
        public var candidateCounts: [String: Int]

        public init(entriesScanned: Int = 0, addedEnglishTerms: [String] = [], candidateCounts: [String: Int] = [:]) {
            self.entriesScanned = entriesScanned
            self.addedEnglishTerms = addedEnglishTerms
            self.candidateCounts = candidateCounts
        }
    }

    // Romaji words a Japanese typist plausibly means as Japanese; never
    // learned as English terms no matter how often they appear verbatim.
    static let romajiCollisionBlocklist: Set<String> = [
        "made", "demo", "node", "sore", "kana", "mono", "mama", "site", "date",
        "sake", "mine", "name", "kite", "hate", "none", "dame", "mata", "dare",
        "doko", "koko", "soko", "kore", "are", "ore", "kimi", "uchi", "mado",
        "kado", "hako", "kami", "yome", "sato", "moto", "seki", "hone", "mura"
    ]

    public static func minimumOccurrences(_ count: Int = 2) -> Int { count }

    // Words the user typed in romaji AND kept as ASCII in the committed text,
    // but that the current engine would convert to kana. Each is an English
    // term the engine keeps getting wrong.
    public static func mineEnglishTerms(
        entries: [LearningLogEntry],
        lexicon: UserLexicon,
        minimumCount: Int = 2
    ) -> (terms: [String], counts: [String: Int]) {
        let dictionary = RomajiDictionary.withLexicon(lexicon)
        var counts: [String: Int] = [:]
        for entry in entries {
            // A commit with no Japanese, or one containing the raw buffer
            // verbatim, is a conversion fallback — every romaji word would
            // look "kept as ASCII" and be mislearned.
            guard containsJapanese(entry.committed), !entry.committed.contains(entry.raw) else {
                continue
            }
            let committedWords = asciiWords(in: entry.committed)
            guard !committedWords.isEmpty else {
                continue
            }
            for word in Set(asciiWords(in: entry.raw)) {
                guard word.count >= 3,
                      !romajiCollisionBlocklist.contains(word),
                      committedWords.contains(word) else {
                    continue
                }
                // Only learn words the engine currently mangles.
                let converted = dictionary.convert(word)
                guard converted != word else {
                    continue
                }
                counts[word, default: 0] += 1
            }
        }
        let terms = counts
            .filter { $0.value >= minimumCount }
            .keys
            .sorted()
        return (terms, counts)
    }

    public static func runLearningPass(
        directory: URL = UserLexicon.defaultDirectory,
        dryRun: Bool = false
    ) -> Report {
        runLearningPass(entries: ConversionLogger.readEntries(from: directory), directory: directory, dryRun: dryRun)
    }

    // Entries can come from the IME commit log or from an offline corpus of
    // (typed romaji, written Japanese) pairs — e.g. romaji-ized prompt
    // history. Both feed the same lexicon files.
    public static func runLearningPass(
        entries: [LearningLogEntry],
        directory: URL = UserLexicon.defaultDirectory,
        dryRun: Bool = false
    ) -> Report {
        let lexicon = UserLexicon.load(from: directory)
        let (terms, counts) = mineEnglishTerms(entries: entries, lexicon: lexicon)
        if !terms.isEmpty, !dryRun {
            appendEnglishTerms(terms, in: directory)
        }
        return Report(entriesScanned: entries.count, addedEnglishTerms: terms, candidateCounts: counts)
    }

    private static func appendEnglishTerms(_ terms: [String], in directory: URL) {
        let url = directory.appendingPathComponent(UserLexicon.englishTermsFile)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var output = existing
        if output.isEmpty {
            output = "# Words learned from your own typing — kept as ASCII, never converted to kana.\n# One word per line; delete a line to unlearn it.\n"
        } else if !output.hasSuffix("\n") {
            output += "\n"
        }
        output += terms.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func asciiWords(in text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        for character in text + " " {
            if character.isASCII, character.isLetter {
                current.append(Character(character.lowercased()))
            } else {
                if !current.isEmpty {
                    words.insert(current)
                    current = ""
                }
            }
        }
        return words
    }
}

// Runs the mining pass at most once per interval, tracked via a stamp file,
// so the IME can trigger it opportunistically without a scheduler.
public enum LearningAutoRunner {
    static let stampFile = "last_learn"

    public static func runIfDue(
        directory: URL = UserLexicon.defaultDirectory,
        interval: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) -> LearningMiner.Report? {
        let stampURL = directory.appendingPathComponent(stampFile)
        if let text = try? String(contentsOf: stampURL, encoding: .utf8),
           let last = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           now.timeIntervalSince(last) < interval {
            return nil
        }
        let report = LearningMiner.runLearningPass(directory: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? ISO8601DateFormatter().string(from: now).write(to: stampURL, atomically: true, encoding: .utf8)
        return report
    }
}
