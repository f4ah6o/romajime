import Foundation

// Turns written Japanese back into the romaji a user would have typed,
// using CFStringTokenizer's morphological Latin transcription (ja_JP).
// Used to generate eval corpora from real prompt history; the kana side
// intentionally avoids RomajiDictionary so eval ground truth stays
// independent of the engine under test.
public enum ReverseTransliterator {
    public static func romaji(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { romajiLine(String($0)) }
            .joined(separator: "\n")
    }

    public static func kana(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { kanaLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func romajiLine(_ line: String) -> String {
        resolveGeminates(tokens(in: line))
            .map { $0.reading ?? $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func kanaLine(_ line: String) -> String {
        resolveGeminates(tokens(in: line))
            .map { token in
                guard var reading = token.reading else {
                    return token.text
                }
                var suffix = ""
                if reading.hasSuffix("xtu") {
                    reading.removeLast(3)
                    suffix = "っ"
                }
                guard let kana = reading.applyingTransform(.latinToHiragana, reverse: false) else {
                    return token.text
                }
                return kana + suffix
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private struct Token {
        var text: String
        var reading: String?
    }

    // CFStringTokenizer marks a geminate (small tsu) as "~tsu" in the
    // transcription, e.g. なった → "na~tsu" + "ta". A real typist writes
    // "natta", so merge the geminate into the next token by doubling its
    // leading consonant; a dangling geminate becomes "xtu".
    private static func resolveGeminates(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < tokens.count {
            var token = tokens[index]
            if var reading = token.reading, reading.hasSuffix("~tsu") {
                reading.removeLast(4)
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                if let nextReading = next?.reading, let first = nextReading.first,
                   first.isLetter, !"aeiouny".contains(first) {
                    token.text += next!.text
                    token.reading = reading + String(first) + nextReading
                    index += 1
                } else {
                    token.reading = reading + "xtu"
                }
            } else if let reading = token.reading, reading.contains("~") {
                token.reading = reading.replacingOccurrences(of: "~", with: "")
            }
            result.append(token)
            index += 1
        }
        return result
    }

    private static func tokens(in line: String) -> [Token] {
        let cf = line as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let locale = CFLocaleCreate(nil, CFLocaleIdentifier("ja_JP" as CFString))
        let tokenizer = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWordBoundary, locale)
        var result: [Token] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let text = CFStringCreateWithSubstring(nil, cf, tokenRange) as String? else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                continue
            }
            let reading = (CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String)
                .map(normalizeMacrons)
            // Tokens with no Japanese reading (ASCII words, punctuation) pass through as-is.
            if let reading, reading.rangeOfCharacter(from: .letters) != nil, containsJapanese(trimmed) {
                result.append(Token(text: trimmed, reading: reading))
            } else {
                result.append(Token(text: trimmed, reading: nil))
            }
        }
        return result
    }

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // hiragana + katakana
                || (0x4E00...0x9FFF).contains(scalar.value) // CJK ideographs
                || scalar.value == 0x30FC                   // long-vowel mark
        }
    }

    private static func normalizeMacrons(_ text: String) -> String {
        var output = text
        for (macron, plain) in [("ā", "aa"), ("ī", "ii"), ("ū", "uu"), ("ē", "ee"), ("ō", "ou")] {
            output = output.replacingOccurrences(of: macron, with: plain)
        }
        return output
    }
}
