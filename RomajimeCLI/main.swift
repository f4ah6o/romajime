// RomajimeCore sources are compiled directly into this target (see
// project.yml), so no `import RomajimeCore` is needed.
import Foundation

let usage = """
usage: romajime-cli [options] [text]
       romajime-cli learn [--dry-run] [--dir <path>] [--corpus <tsv>]

Converts a romaji draft to Japanese using the same pipeline as the
Romajime input method. Reads from stdin when no text argument is given,
so multi-line input can be piped in as-is.

options:
  --kana-only       Rule-based kana conversion only (fast, deterministic)
  --reverse         Reverse mode: written Japanese -> typed romaji (for eval corpora)
  --memory <file>   Terminology memory file (default: ~/Library/Application Support/Romajime/memory.md)
  --no-memory       Disable terminology memory
  --timeout <sec>   Kanji conversion timeout in seconds (default: 5)
  --json            Emit kana/kanji/candidates as JSON
  --no-user-lexicon Ignore learned lexicon files (pure built-in engine)
  -h, --help        Show this help

learn: mine recurring English terms the engine mangles and append them to
english_terms.txt; also propose phrase rewrites (memory.md candidates,
written to memory_proposals.txt for review — never applied automatically).
Sources: the opt-in commit log (log.jsonl), or with --corpus an eval
corpus.tsv of romaji<TAB>kana<TAB>original lines (i.e. romaji-ized prompt
history). --dry-run only reports; --dir overrides
~/Library/Application Support/Romajime.
"""

func runLearn(_ arguments: [String]) -> Never {
    var dryRun = false
    var directory = UserLexicon.defaultDirectory
    var corpusPath: String?
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--dry-run":
            dryRun = true
        case "--dir":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("error: --dir requires a path\n".utf8))
                exit(2)
            }
            directory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
        case "--corpus":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("error: --corpus requires a tsv path\n".utf8))
                exit(2)
            }
            corpusPath = arguments[index]
        default:
            FileHandle.standardError.write(Data("error: unknown learn option \(arguments[index])\n".utf8))
            exit(2)
        }
        index += 1
    }
    var entries: [LearningLogEntry] = []
    let report: LearningMiner.Report
    if let corpusPath {
        let url = URL(fileURLWithPath: (corpusPath as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            FileHandle.standardError.write(Data("error: cannot read corpus \(corpusPath)\n".utf8))
            exit(2)
        }
        entries = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 3 else {
                return nil
            }
            return LearningLogEntry(raw: String(parts[0]), committed: String(parts[2]))
        }
        report = LearningMiner.runLearningPass(entries: entries, directory: directory, dryRun: dryRun)
    } else {
        entries = ConversionLogger.readEntries(from: directory)
        report = LearningMiner.runLearningPass(entries: entries, directory: directory, dryRun: dryRun)
    }
    print("entries scanned: \(report.entriesScanned)")
    if report.addedEnglishTerms.isEmpty {
        print("no new english terms (need \(LearningMiner.minimumOccurrences())+ occurrences)")
    } else {
        let verb = dryRun ? "would add" : "added"
        print("\(verb) to \(UserLexicon.englishTermsFile): \(report.addedEnglishTerms.joined(separator: ", "))")
    }
    let nearMisses = report.candidateCounts.filter { $0.value < LearningMiner.minimumOccurrences() }
    if !nearMisses.isEmpty {
        print("seen once (not yet learned): \(nearMisses.keys.sorted().joined(separator: ", "))")
    }

    // Phrase proposals are mined against the post-learning lexicon so words
    // just added to english_terms.txt are reflected.
    let lexicon = UserLexicon.load(from: directory)
    let memoryURL = directory.appendingPathComponent("memory.md")
    let memory = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
    let phrases = LearningMiner.minePhraseRewrites(entries: entries, lexicon: lexicon, existingMemory: memory)
    if phrases.isEmpty {
        print("no phrase rewrite proposals")
    } else {
        print("\nphrase rewrite proposals (review, then copy lines you trust into memory.md):")
        for phrase in phrases.prefix(30) {
            print("  \(phrase.from) -> \(phrase.to)    # \(phrase.count)x  e.g. \(phrase.example.prefix(40))")
        }
        if !dryRun {
            let proposalsURL = directory.appendingPathComponent("memory_proposals.txt")
            var output = "# memory.md candidates mined from your own text. Reviewed lines can be\n"
            output += "# copied verbatim (the part before '#') into memory.md. Regenerated each run.\n"
            for phrase in phrases {
                output += "\(phrase.from) -> \(phrase.to)    # \(phrase.count)x  e.g. \(phrase.example.prefix(60))\n"
            }
            try? output.write(to: proposalsURL, atomically: true, encoding: .utf8)
            print("written: \(proposalsURL.path) (\(phrases.count) proposals)")
        }
    }
    exit(0)
}

struct CLIOptions {
    var kanaOnly = false
    var reverse = false
    var noUserLexicon = false
    var memoryPath: String?
    var noMemory = false
    var timeout: TimeInterval = 5
    var json = false
    var text: String?
}

func parseOptions(_ arguments: [String]) -> CLIOptions {
    var options = CLIOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--kana-only":
            options.kanaOnly = true
        case "--reverse":
            options.reverse = true
        case "--no-user-lexicon":
            options.noUserLexicon = true
        case "--memory":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("error: --memory requires a file path\n".utf8))
                exit(2)
            }
            options.memoryPath = arguments[index]
        case "--no-memory":
            options.noMemory = true
        case "--timeout":
            index += 1
            guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("error: --timeout requires a positive number\n".utf8))
                exit(2)
            }
            options.timeout = value
        case "--json":
            options.json = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            if argument.hasPrefix("-") {
                FileHandle.standardError.write(Data("error: unknown option \(argument)\n\(usage)\n".utf8))
                exit(2)
            }
            options.text = options.text.map { $0 + " " + argument } ?? argument
        }
        index += 1
    }
    return options
}

func loadMemory(_ options: CLIOptions) -> String {
    guard !options.noMemory else {
        return ""
    }
    let url: URL
    if let path = options.memoryPath {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Romajime/memory.md")
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func readInput(_ options: CLIOptions) -> String {
    if let text = options.text {
        return text
    }
    guard let data = try? FileHandle.standardInput.readToEnd(), let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    // Strip only the final newline a shell pipe appends; keep interior ones.
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
if rawArguments.first == "learn" {
    runLearn(Array(rawArguments.dropFirst()))
}

let options = parseOptions(rawArguments)
let input = readInput(options)
guard !input.isEmpty else {
    FileHandle.standardError.write(Data("error: no input text\n\(usage)\n".utf8))
    exit(2)
}

if options.reverse {
    let romaji = ReverseTransliterator.romaji(input)
    if options.json {
        let payload: [String: Any] = [
            "input": input,
            "romaji": romaji,
            "kana": ReverseTransliterator.kana(input)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        print(romaji)
    }
    exit(0)
}

let memory = loadMemory(options)
let backend = options.noUserLexicon
    ? RuleBasedConversionBackend()
    : RuleBasedConversionBackend(dictionary: .withLexicon(UserLexicon.load()))
let result = (try? backend.convert(.init(raw: input, memory: memory)))
    ?? ConversionResult(converted: input, refined: input, confidence: 0, candidates: [])
let kanaText = result.candidates.first?.text ?? input

var kanji: String?
if !options.kanaOnly {
    let request = KanjiConversionRequest(raw: input, kana: kanaText, memory: memory)
    kanji = await KanjiConversionRunner.run(backend: FoundationModelsKanjiBackend(), request: request, timeout: options.timeout)
}

let merged = CandidateGenerator.mergingKanji(kanji, into: result.candidates, memory: memory)
let output = merged.first?.text ?? kanaText

if options.json {
    var payload: [String: Any] = [
        "input": input,
        "kana": kanaText,
        "output": output,
        "candidates": merged.map { ["id": $0.id, "text": $0.text, "label": $0.label, "confidence": $0.confidence] }
    ]
    payload["kanji"] = kanji
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    print(output)
}
