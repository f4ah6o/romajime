import XCTest
@testable import RomajimeCore

final class RomajimeCoreTests: XCTestCase {
    func testRomajiToKana() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "kyou mtg de todo", memory: "mtg -> ミーティング\ntodo -> TODO\n"))
        XCTAssertEqual(result.candidates.first?.text, "きょう ミーティング で TODO")
    }

    func testCompositionStateCanStillHoldCandidatesForFutureBackends() {
        var state = CompositionState()
        state.append("k")
        state.append("a")
        state.setCandidates([
            .init(id: "kana", text: "か", label: "Kana", confidence: 0.7),
            .init(id: "raw", text: "ka", label: "Raw", confidence: 0.1)
        ])
        XCTAssertEqual(state.selectedCandidate?.text, "か")
        state.selectNextCandidate()
        XCTAssertEqual(state.selectedCandidate?.text, "ka")
        state.selectNextCandidate()
        XCTAssertEqual(state.selectedCandidate?.text, "か")
    }

    func testSpaceCanBeBufferedForLongFormInput() throws {
        XCTAssertTrue(CompositionNormalizer.acceptsRomajiCharacter(" "))
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "tadahitasura type sitainoto. typo ya hennkann kannjinorennsouwoyamete"))
        XCTAssertEqual(result.candidates.first?.text, "ただひたすら type したいのと. typo や へんかん かんじのれんそうをやめて")
    }

    func testBackspaceClearsCandidates() {
        var state = CompositionState()
        state.append("t")
        state.append("o")
        state.setCandidates([.init(id: "kana", text: "と", label: "Kana", confidence: 0.7)])
        state.deleteBackward()
        XCTAssertEqual(state.buffer, "t")
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testWhitespaceNormalizationPreservesNewlines() {
        XCTAssertEqual(CompositionNormalizer.normalizeWhitespace("  kyou   mtg\tde\nhanasita todo  "), "kyou mtg de\nhanasita todo")
        XCTAssertEqual(CompositionNormalizer.normalizeWhitespace("a\n\nb"), "a\n\nb")
    }

    func testConversionPreservesNewlines() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "kyou ha kaigi\nashita ha yasumi"))
        XCTAssertEqual(result.candidates.first?.text, "きょう は かいぎ\nあした は やすみ")
    }

    func testReverseTransliteratorProducesTypedRomaji() {
        XCTAssertEqual(ReverseTransliterator.romaji("今日は会議"), "kyou ha kaigi")
        XCTAssertEqual(ReverseTransliterator.kana("今日は会議"), "きょう は かいぎ")
    }

    func testReverseTransliteratorPreservesNewlinesAndAscii() {
        let romaji = ReverseTransliterator.romaji("変換を改善\nTODO を確認")
        XCTAssertEqual(romaji, "henkan wo kaizen\nTODO wo kakunin")
    }

    func testReverseTransliteratorNormalizesMacrons() {
        XCTAssertFalse(ReverseTransliterator.romaji("改善ループ").contains("ū"))
    }

    func testReverseTransliteratorMergesGeminates() {
        // CFStringTokenizer reads なった as "na~tsu"+"ta"; a typist writes "natta".
        XCTAssertEqual(ReverseTransliterator.romaji("なったらしい"), "natta rashii")
        XCTAssertEqual(ReverseTransliterator.kana("なったらしい"), "なった らしい")
    }

    func testExtendedKatakanaRomaji() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "fairu wo chekku shite itchi wo kakunin"))
        XCTAssertEqual(result.candidates.first?.text, "ふぁいる を ちぇっく して いっち を かくにん")
    }

    func testSmallTsuFallbackEntries() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "axtu sorejya xyaxyuxyo"))
        XCTAssertEqual(result.candidates.first?.text, "あっ それじゃ ゃゅょ")
    }

    func testEnglishTermsStayAscii() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "fixture wo runtime de token to issue ni tsuika"))
        XCTAssertEqual(result.candidates.first?.text, "fixture を runtime で token と issue に ついか")
    }

    func testRomajiCollidingWithEnglishStillConverts() throws {
        // made/demo/node read as English but are far more common as romaji.
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "asa made demo node sore"))
        XCTAssertEqual(result.candidates.first?.text, "あさ まで でも ので それ")
    }

    func testLiteralPrefixesProtectRuns() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "/sukina komando to $home hensuu wo sonomama"))
        XCTAssertEqual(result.candidates.first?.text, "/sukina こまんど と $home へんすう を そのまま")
        let inlineCode = try backend.convert(.init(raw: "kore ha `kana` to _kana desu"))
        XCTAssertEqual(inlineCode.candidates.first?.text, "これ は `kana` と _kana です")
    }

    func testComposingOnlyCharactersNeverStartComposition() {
        for character in ["/", "$", "3"].compactMap(\.first) {
            XCTAssertFalse(CompositionNormalizer.acceptsRomajiCharacter(character))
            XCTAssertTrue(CompositionNormalizer.acceptsComposingCharacter(character))
        }
        XCTAssertTrue(CompositionNormalizer.acceptsComposingCharacter("a"))
    }

    func testMixedCaseWordTailStaysAscii() throws {
        let backend = RuleBasedConversionBackend()
        let result = try backend.convert(.init(raw: "Renovate ga yoi"))
        XCTAssertEqual(result.candidates.first?.text, "Renovate が よい")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RomajimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testUserLexiconLoadsTermsAndEntries() throws {
        let dir = try makeTempDirectory()
        try "# comment\nkibana\nVite\n".write(to: dir.appendingPathComponent(UserLexicon.englishTermsFile), atomically: true, encoding: .utf8)
        try "# comment\nwyi\tうぃ\n".write(to: dir.appendingPathComponent(UserLexicon.romajiEntriesFile), atomically: true, encoding: .utf8)
        let lexicon = UserLexicon.load(from: dir)
        XCTAssertEqual(lexicon.englishTerms, ["kibana", "vite"])
        XCTAssertEqual(lexicon.romajiEntries, ["wyi": "うぃ"])

        let backend = RuleBasedConversionBackend(dictionary: .withLexicon(lexicon))
        let result = try backend.convert(.init(raw: "kibana de kakunin"))
        XCTAssertEqual(result.candidates.first?.text, "kibana で かくにん")
    }

    func testConversionLoggerAppendsTrimsAndProtects() throws {
        let dir = try makeTempDirectory()
        let logger = ConversionLogger(directory: dir, maxEntries: 4)
        for index in 0..<6 {
            logger.append(raw: "raw\(index)", committed: "確定\(index)")
        }
        let entries = ConversionLogger.readEntries(from: dir)
        // 5th append exceeds maxEntries(4) and trims to the newest 2; the 6th appends on top.
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.raw), ["raw3", "raw4", "raw5"])
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(ConversionLogger.logFile).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLearningMinerLearnsEnglishTermsButRespectsBlocklist() throws {
        let dir = try makeTempDirectory()
        let logger = ConversionLogger(directory: dir)
        // "kibana" parses as romaji (きばな) but the user keeps it ASCII.
        logger.append(raw: "kibana de mita", committed: "kibana で 見た")
        logger.append(raw: "kibana wo hiraku", committed: "kibana を 開く")
        // "made" appears verbatim too, but is blocklisted (まで).
        logger.append(raw: "asa made matsu", committed: "朝 made 待つ")
        logger.append(raw: "yoru made matsu", committed: "夜 made 待つ")
        // Raw-fallback commits (no conversion happened) must be ignored entirely.
        logger.append(raw: "henkan sippai reigai", committed: "henkan sippai reigai")
        logger.append(raw: "henkan sippai reigai", committed: "henkan sippai reigai")

        let report = LearningMiner.runLearningPass(directory: dir)
        XCTAssertEqual(report.addedEnglishTerms, ["kibana"])

        let lexicon = UserLexicon.load(from: dir)
        XCTAssertTrue(lexicon.englishTerms.contains("kibana"))
        XCTAssertFalse(lexicon.englishTerms.contains("made"))

        // Second pass: kibana is now protected, so nothing new is learned.
        let second = LearningMiner.runLearningPass(directory: dir)
        XCTAssertEqual(second.addedEnglishTerms, [])
    }

    func testLearningAutoRunnerHonorsInterval() throws {
        let dir = try makeTempDirectory()
        XCTAssertNotNil(LearningAutoRunner.runIfDue(directory: dir, interval: 3600))
        XCTAssertNil(LearningAutoRunner.runIfDue(directory: dir, interval: 3600))
        XCTAssertNotNil(LearningAutoRunner.runIfDue(directory: dir, interval: 3600, now: Date().addingTimeInterval(7200)))
    }

    func testLearningConfigDefaultsToOptOut() throws {
        XCTAssertFalse(RomajimeConfig().learning.enabled)
        let decoded = try JSONDecoder().decode(RomajimeConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.learning.enabled)
        let enabled = try JSONDecoder().decode(RomajimeConfig.self, from: Data(#"{"learning":{"enabled":true}}"#.utf8))
        XCTAssertTrue(enabled.learning.enabled)
    }

    func testMergingKanjiRejectsCandidateThatDropsNewlines() {
        let candidates = [ConversionCandidate(id: "kana", text: "きょう は かいぎ\nあした は やすみ", label: "Kana", confidence: 0.7)]
        let merged = CandidateGenerator.mergingKanji("今日は会議 明日は休み", into: candidates)
        XCTAssertEqual(merged.first?.id, "kana")
        let preserved = CandidateGenerator.mergingKanji("今日は会議\n明日は休み", into: candidates)
        XCTAssertEqual(preserved.first?.id, "kanji")
        XCTAssertEqual(preserved.first?.text, "今日は会議\n明日は休み")
    }

    func testIdleConversionPolicyExtendsDelayWhileTypingFast() {
        let policy = IdleConversionPolicy(baseDelay: 1.2, fastTypingDelay: 1.8, fastTypingThreshold: 0.18)
        XCTAssertEqual(policy.delay(afterKeystrokeInterval: nil), 1.2)
        XCTAssertEqual(policy.delay(afterKeystrokeInterval: 0.4), 1.2)
        XCTAssertEqual(policy.delay(afterKeystrokeInterval: 0.08), 1.8)
    }

    func testIdleConversionPolicyUsesSentenceBoundaryDelay() {
        let policy = IdleConversionPolicy(baseDelay: 1.2, sentenceBoundaryDelay: 0.45)
        XCTAssertEqual(policy.delay(for: "koreha yameru.", afterKeystrokeInterval: 0.4), 0.45)
        XCTAssertEqual(policy.delay(for: "koreha yameru\n", afterKeystrokeInterval: 0.4), 0.45)
        XCTAssertTrue(policy.shouldConvert(buffer: "koreha yameru.", elapsed: 1.0))
        XCTAssertFalse(policy.shouldConvert(buffer: "k", elapsed: 1.0))
        XCTAssertTrue(policy.shouldConvert(buffer: "koreha mada kaiteiru", elapsed: 9.0))
    }

    func testJumpLabelsContinueFromZToAA() {
        XCTAssertEqual(JumpLabelGenerator.label(for: 0), "a")
        XCTAssertEqual(JumpLabelGenerator.label(for: 25), "z")
        XCTAssertEqual(JumpLabelGenerator.label(for: 26), "aa")
        XCTAssertEqual(JumpLabelGenerator.label(for: 27), "ab")
    }

    func testJumpLabelsAlsoExposeNumericAliases() {
        XCTAssertEqual(JumpLabelGenerator.numericLabel(for: 0), "1")
        XCTAssertEqual(JumpLabelGenerator.numericLabel(for: 9), "10")
        XCTAssertEqual(JumpLabelGenerator.labels(for: 26), ["aa", "27"])
    }

    func testConfigCodableKeepsDefaultKeyBindings() throws {
        let config = RomajimeConfig()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RomajimeConfig.self, from: data)
        XCTAssertEqual(decoded.keyBindings.bufferSpace, KeyStroke(keyCode: 49))
        XCTAssertEqual(decoded.keyBindings.newlineCommit, [KeyStroke(keyCode: 36), KeyStroke(keyCode: 76)])
        XCTAssertEqual(decoded.keyBindings.ignoredCommit, [])
        XCTAssertEqual(decoded.keyBindings.deleteBackward, KeyStroke(keyCode: 51))
        XCTAssertEqual(decoded.keyBindings.convertOrJump, KeyStroke(keyCode: 53))
        XCTAssertEqual(decoded.keyBindings.jumpConfirm, KeyStroke(keyCode: 49))
        XCTAssertEqual(decoded.keyBindings.jumpCancel, KeyStroke(keyCode: 53))
    }

    func testConfigDecodesLegacyKeyBindings() throws {
        let data = """
        {
          "keyBindings": {
            "bufferSpace": { "keyCode": 49 },
            "ignoredCommit": [{ "keyCode": 36 }, { "keyCode": 76 }],
            "deleteBackward": { "keyCode": 51 },
            "convertOrJump": { "keyCode": 53 },
            "jumpConfirm": { "keyCode": 49 },
            "jumpCancel": { "keyCode": 53 }
          },
          "timing": {
            "idleBaseDelay": 1.2,
            "idleFastTypingDelay": 1.8,
            "idleFastTypingThreshold": 0.18,
            "jumpModeTimeout": 3.0
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RomajimeConfig.self, from: data)
        XCTAssertEqual(decoded.keyBindings.newlineCommit, [])
        XCTAssertEqual(decoded.keyBindings.ignoredCommit, [KeyStroke(keyCode: 36), KeyStroke(keyCode: 76)])
        XCTAssertEqual(decoded.timing.idleSentenceBoundaryDelay, 0.45)
        XCTAssertTrue(decoded.timing.localIntelligenceEnabled)
    }

    func testKanjiPromptIncludesRawKanaAndMemory() {
        let prompt = KanjiPromptBuilder.prompt(for: .init(raw: "kyou ha\nkaigi", kana: "きょう は\nかいぎ", memory: "mtg -> ミーティング"))
        XCTAssertTrue(prompt.contains("kyou ha\nkaigi"))
        XCTAssertTrue(prompt.contains("きょう は\nかいぎ"))
        XCTAssertTrue(prompt.contains("mtg -> ミーティング"))
        XCTAssertTrue(prompt.contains("Terminology:"))
    }

    func testKanjiPromptOmitsEmptyMemorySection() {
        let prompt = KanjiPromptBuilder.prompt(for: .init(raw: "kyou", kana: "きょう", memory: "  \n"))
        XCTAssertFalse(prompt.contains("Terminology:"))
    }

    func testMergingKanjiPrependsHighestConfidenceCandidate() {
        let base = CandidateGenerator.candidates(raw: "kyou", kana: "きょう")
        let merged = CandidateGenerator.mergingKanji("今日", into: base)
        XCTAssertEqual(merged.first?.id, "kanji")
        XCTAssertEqual(merged.first?.text, "今日")
        XCTAssertEqual(merged.first?.confidence, 0.9)
        XCTAssertEqual(merged.count, base.count + 1)
    }

    func testMergingKanjiAppliesMemoryRewriteToModelOutput() {
        let base = CandidateGenerator.candidates(raw: "kyou mtg", kana: "きょう mtg")
        let merged = CandidateGenerator.mergingKanji("今日 mtg", into: base, memory: "mtg -> ミーティング")
        XCTAssertEqual(merged.first?.text, "今日 ミーティング")
    }

    func testMergingNilOrEmptyKanjiKeepsRuleBasedCandidates() {
        let base = CandidateGenerator.candidates(raw: "kyou", kana: "きょう")
        XCTAssertEqual(CandidateGenerator.mergingKanji(nil, into: base), base)
        XCTAssertEqual(CandidateGenerator.mergingKanji("  \n", into: base), base)
    }

    func testMergingKanjiDedupesWhenEqualToKana() {
        let base = CandidateGenerator.candidates(raw: "kyou", kana: "きょう")
        XCTAssertEqual(CandidateGenerator.mergingKanji("きょう", into: base), base)
    }

    func testMergingKanjiRejectsRunawayOutput() {
        let base = CandidateGenerator.candidates(raw: "kyou", kana: "きょう")
        let runaway = String(repeating: "今日は会議です。", count: 5)
        XCTAssertEqual(CandidateGenerator.mergingKanji(runaway, into: base), base)
    }

    func testFakeKanjiBackendFlow() async throws {
        struct FakeKanjiBackend: KanjiConversionBackend {
            var result: Result<String, Error>
            func convertToKanji(_ request: KanjiConversionRequest) async throws -> String {
                try result.get()
            }
        }

        let base = CandidateGenerator.candidates(raw: "kyouhakaigi", kana: "きょうはかいぎ")
        let request = KanjiConversionRequest(raw: "kyouhakaigi", kana: "きょうはかいぎ")

        let success = FakeKanjiBackend(result: .success("今日は会議"))
        let kanji = try await success.convertToKanji(request)
        XCTAssertEqual(CandidateGenerator.mergingKanji(kanji, into: base).first?.text, "今日は会議")

        struct FakeError: Error {}
        let failure = FakeKanjiBackend(result: .failure(FakeError()))
        let fallback = try? await failure.convertToKanji(request)
        XCTAssertEqual(CandidateGenerator.mergingKanji(fallback, into: base).first?.text, "きょうはかいぎ")
    }

    func testTimingDecodesMissingKanjiConversionKeys() throws {
        let data = """
        { "idleBaseDelay": 1.2 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Timing.self, from: data)
        XCTAssertTrue(decoded.kanjiConversionEnabled)
        XCTAssertEqual(decoded.kanjiConversionTimeout, 2.0)
    }

    func testTextUnitScannerUsesPhraseBoundariesNotWhitespace() {
        let targets = TextUnitScanner.jumpTargets(in: "koreha yameru. motto chobun\n  もっと 長文。", baseLocation: 10)
        XCTAssertEqual(targets.map(\.label), ["a", "b", "c"])
        XCTAssertEqual(targets.map(\.text), ["koreha yameru.", "motto chobun", "もっと 長文。"])
        XCTAssertEqual(targets.first?.range, NSRange(location: 10, length: 14))
        XCTAssertEqual(targets.last?.range.location, 40)
    }

    func testLineJumpScannerUsesLineBoundaries() {
        let targets = LineJumpScanner.jumpTargets(in: "koreha yameru\n\nもっと 長文", baseLocation: 10)
        XCTAssertEqual(targets.map(\.label), ["a", "b"])
        XCTAssertEqual(targets.map(\.text), ["koreha yameru", "もっと 長文"])
        XCTAssertEqual(targets.first?.range, NSRange(location: 10, length: 13))
        XCTAssertEqual(targets.last?.range.location, 25)
    }
}
