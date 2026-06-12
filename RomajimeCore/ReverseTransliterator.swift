import Foundation

// Turns written Japanese back into the romaji a user would have typed,
// using CFStringTokenizer's morphological Latin transcription (ja_JP).
// Used to generate eval corpora from real prompt history and to align
// engine output with original text for phrase mining; the kana side
// intentionally avoids RomajiDictionary so eval ground truth stays
// independent of the engine under test.
public enum ReverseTransliterator {
    public struct AlignedToken: Equatable, Sendable {
        public var text: String
        public var romaji: String?
        public var kana: String?
        public var utf16Offset: Int
        public var utf16Length: Int

        public init(text: String, romaji: String?, kana: String?, utf16Offset: Int, utf16Length: Int) {
            self.text = text
            self.romaji = romaji
            self.kana = kana
            self.utf16Offset = utf16Offset
            self.utf16Length = utf16Length
        }
    }

    public static func romaji(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                alignedTokens(in: String(line))
                    .map { $0.romaji ?? $0.text }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    public static func kana(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                alignedTokens(in: String(line))
                    .map { $0.kana ?? $0.text }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    // Tokens of a single line with typed-style romaji, kana reading, and the
    // token's position in the original line (for substring extraction).
    public static func alignedTokens(in line: String) -> [AlignedToken] {
        resolveGeminates(tokens(in: line)).map { token in
            AlignedToken(
                text: token.text,
                romaji: token.reading,
                kana: token.reading.flatMap(kanaFromReading),
                utf16Offset: token.utf16Offset,
                utf16Length: token.utf16Length
            )
        }
    }

    private static func kanaFromReading(_ reading: String) -> String? {
        var reading = reading
        var suffix = ""
        if reading.hasSuffix("xtu") {
            reading.removeLast(3)
            suffix = "っ"
        }
        guard let kana = reading.applyingTransform(.latinToHiragana, reverse: false) else {
            return nil
        }
        return kana + suffix
    }

    private struct Token {
        var text: String
        var reading: String?
        var utf16Offset: Int
        var utf16Length: Int
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
                    token.utf16Length = next!.utf16Offset + next!.utf16Length - token.utf16Offset
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
            let leading = text.prefix { $0.isWhitespace }.utf16.count
            let reading = (CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String)
                .map(normalizeMacrons)
            let token = Token(
                text: trimmed,
                reading: nil,
                utf16Offset: tokenRange.location + leading,
                utf16Length: trimmed.utf16.count
            )
            // Tokens with no Japanese reading (ASCII words, punctuation) pass through as-is.
            if let reading, reading.rangeOfCharacter(from: .letters) != nil, containsJapanese(trimmed) {
                var withReading = token
                withReading.reading = reading
                result.append(withReading)
            } else {
                result.append(token)
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
