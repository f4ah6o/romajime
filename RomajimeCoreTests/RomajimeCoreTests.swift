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

    func testWhitespaceNormalization() {
        XCTAssertEqual(CompositionNormalizer.normalizeWhitespace("  kyou   mtg\tde\nhanasita todo  "), "kyou mtg de hanasita todo")
    }

    func testIdleConversionPolicyExtendsDelayWhileTypingFast() {
        let policy = IdleConversionPolicy(baseDelay: 1.2, fastTypingDelay: 1.8, fastTypingThreshold: 0.18)
        XCTAssertEqual(policy.delay(afterKeystrokeInterval: nil), 1.2)
        XCTAssertEqual(policy.delay(afterKeystrokeInterval: 0.4), 1.2)
        XCTAssertEqual(policy.delay(afterKeystrokeInterval: 0.08), 1.8)
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
