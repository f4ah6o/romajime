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
}
