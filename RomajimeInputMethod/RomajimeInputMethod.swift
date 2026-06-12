import AppKit
import FoundationModels
import InputMethodKit
import RomajimeCore

final class InputMethodApplicationDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = IMKServer(name: "Romajime_1_Connection", bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

@objc(RomajimeInputController)
public final class RomajimeInputController: IMKInputController, @unchecked Sendable {
    private var state = CompositionState()
    private let backend = RuleBasedConversionBackend()
    private let memoryStore = MemoryStore()
    private let configStore = ConfigStore()
    private lazy var config = configStore.load()
    private lazy var idleConversionPolicy = IdleConversionPolicy(
        baseDelay: config.timing.idleBaseDelay,
        fastTypingDelay: config.timing.idleFastTypingDelay,
        fastTypingThreshold: config.timing.idleFastTypingThreshold,
        sentenceBoundaryDelay: config.timing.idleSentenceBoundaryDelay,
        maxComposingDelay: config.timing.maxComposingDelay
    )
    private var idleTimer: Timer?
    private var lastInputAt: Date?
    private var compositionStartedAt: Date?
    private var readinessRequestID = 0
    private var readinessClient: Any?
    private var commitRequestID = 0
    private var pendingCommitClient: Any?
    var kanjiBackend: any KanjiConversionBackend = FoundationModelsKanjiBackend()
    private var jumpTargets: [JumpTarget] = []
    private var jumpLabelBuffer = ""
    private var jumpModeTimer: Timer?

    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        if handleJumpMode(event, client: sender) {
            return true
        }

        if handleCommand(event, client: sender) {
            return true
        }

        guard let characters = event.charactersIgnoringModifiers, characters.count == 1, let character = characters.first else {
            return false
        }

        guard CompositionNormalizer.acceptsRomajiCharacter(character) else {
            return false
        }

        state.append(character)
        updateMarkedText(client: sender)
        scheduleIdleConversion(client: sender)
        return true
    }

    public override func commitComposition(_ sender: Any!) {
        // The OS expects the composition resolved synchronously here (focus
        // loss, input-source switch), so skip the async kanji pass.
        convertAndCommit(client: sender, allowAsync: false)
    }

    public override func candidates(_ sender: Any!) -> [Any]! {
        state.candidates.map(\.text)
    }

    private func handleCommand(_ event: NSEvent, client sender: Any!) -> Bool {
        if event.matches(config.keyBindings.bufferSpace) {
            guard state.isComposing else {
                return false
            }
            state.append(" ")
            updateMarkedText(client: sender)
            scheduleIdleConversion(client: sender)
            return true
        }

        if config.keyBindings.newlineCommit.contains(where: event.matches(_:)) {
            guard state.isComposing else {
                return false
            }
            state.append("\n")
            updateMarkedText(client: sender)
            scheduleIdleConversion(client: sender)
            return true
        }

        if config.keyBindings.ignoredCommit.contains(where: event.matches(_:)) {
            guard state.isComposing else {
                return false
            }
            return true
        }

        if event.matches(config.keyBindings.deleteBackward) {
            guard state.isComposing else {
                return false
            }
            state.deleteBackward()
            if state.isComposing {
                updateMarkedText(client: sender)
                scheduleIdleConversion(client: sender)
            } else {
                cancelIdleConversion()
                clearMarkedText(client: sender)
            }
            return true
        }

        if event.matches(config.keyBindings.convertOrJump) {
            if state.isComposing {
                convertAndCommit(client: sender)
            } else {
                enterJumpMode(client: sender)
            }
            return true
        }

        return false
    }

    private func convertAndCommit(client sender: Any!, allowAsync: Bool = true) {
        cancelIdleConversion()
        let buffer = state.buffer
        guard !buffer.isEmpty else {
            return
        }
        let memory = memoryStore.loadMemory()
        let request = ConversionRequest(raw: buffer, memory: memory, kanaCandidate: nil)
        let result = (try? backend.convert(request)) ?? ConversionResult(converted: buffer, refined: buffer, confidence: 0, candidates: [])
        let kanaText = result.candidates.first?.text ?? buffer

        commitRequestID += 1
        let requestID = commitRequestID

        guard allowAsync, config.timing.kanjiConversionEnabled else {
            commit(kanaText, client: sender)
            return
        }

        let kanjiRequest = KanjiConversionRequest(raw: buffer, kana: kanaText, memory: memory)
        let timeout = config.timing.kanjiConversionTimeout
        pendingCommitClient = sender
        let kanjiBackend = kanjiBackend
        let baseCandidates = result.candidates
        Task { [weak self] in
            let kanji = await KanjiConversionRunner.run(backend: kanjiBackend, request: kanjiRequest, timeout: timeout)
            await MainActor.run {
                self?.finishKanjiCommit(requestID: requestID, buffer: buffer, baseCandidates: baseCandidates, kanaText: kanaText, kanji: kanji, memory: memory)
            }
        }
    }

    private func finishKanjiCommit(requestID: Int, buffer: String, baseCandidates: [ConversionCandidate], kanaText: String, kanji: String?, memory: String) {
        guard commitRequestID == requestID, state.buffer == buffer, let client = pendingCommitClient else {
            return
        }
        pendingCommitClient = nil
        let merged = CandidateGenerator.mergingKanji(kanji, into: baseCandidates, memory: memory)
        commit(merged.first?.text ?? kanaText, client: client)
    }

    private func scheduleIdleConversion(client sender: Any!) {
        cancelIdleConversion()
        guard state.isComposing, !state.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let now = Date()
        if compositionStartedAt == nil {
            compositionStartedAt = now
            if config.timing.kanjiConversionEnabled {
                kanjiBackend.prewarm()
            }
        }
        let interval = lastInputAt.map { now.timeIntervalSince($0) }
        lastInputAt = now
        let delay = idleConversionPolicy.delay(for: state.buffer, afterKeystrokeInterval: interval)
        let client = sender as AnyObject
        idleTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(idleTimerFired(_:)), userInfo: client, repeats: false)
    }

    @objc private func idleTimerFired(_ timer: Timer) {
        guard let client = timer.userInfo else {
            return
        }
        let buffer = state.buffer
        let elapsed = compositionStartedAt.map { Date().timeIntervalSince($0) }
        if idleConversionPolicy.shouldConvert(buffer: buffer, elapsed: elapsed) {
            convertAndCommit(client: client)
            return
        }

        guard config.timing.localIntelligenceEnabled, idleConversionPolicy.shouldAskIntelligence(buffer: buffer, elapsed: elapsed) else {
            scheduleIdleConversion(client: client)
            return
        }

        readinessRequestID += 1
        let requestID = readinessRequestID
        readinessClient = client
        let timeout = config.timing.localIntelligenceTimeout
        Task { [weak self] in
            let shouldConvert = await LocalIntelligenceReadinessAdvisor.shouldConvert(buffer: buffer, timeout: timeout)
            await MainActor.run {
                self?.finishIntelligenceReadiness(requestID: requestID, buffer: buffer, shouldConvert: shouldConvert)
            }
        }
    }

    private func finishIntelligenceReadiness(requestID: Int, buffer: String, shouldConvert: Bool) {
        guard readinessRequestID == requestID, state.buffer == buffer, let client = readinessClient else {
            return
        }
        readinessClient = nil
        if shouldConvert {
            convertAndCommit(client: client)
        } else {
            scheduleIdleConversion(client: client)
        }
    }

    private func cancelIdleConversion() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private var isJumpModeActive: Bool {
        !jumpTargets.isEmpty
    }

    private func handleJumpMode(_ event: NSEvent, client sender: Any!) -> Bool {
        guard isJumpModeActive else {
            return false
        }

        if event.matches(config.keyBindings.jumpCancel) {
            exitJumpMode()
            return true
        }

        if event.matches(config.keyBindings.jumpConfirm) {
            if let target = jumpTarget(matching: jumpLabelBuffer) {
                jump(to: target, client: sender)
            } else {
                NSSound.beep()
            }
            exitJumpMode()
            return true
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1, let character = characters.first, character.isASCII, character.isLetter || character.isNumber else {
            exitJumpMode()
            return false
        }

        jumpLabelBuffer.append(character)
        if hasJumpTarget(withPrefix: jumpLabelBuffer) {
            scheduleJumpModeTimeout()
            return true
        }

        exitJumpMode()
        return true
    }

    private func jumpTarget(matching label: String) -> JumpTarget? {
        for (index, target) in jumpTargets.enumerated() where JumpLabelGenerator.labels(for: index).contains(label) {
            return target
        }
        return nil
    }

    private func hasJumpTarget(withPrefix prefix: String) -> Bool {
        jumpTargets.indices.contains { index in
            JumpLabelGenerator.labels(for: index).contains { $0.hasPrefix(prefix) }
        }
    }

    private func enterJumpMode(client sender: Any!) {
        guard let client = inputClient(sender) else {
            return
        }
        let selection = client.selectedRange()
        let context = surroundingText(around: selection.location, client: client)
        jumpTargets = TextUnitScanner.jumpTargets(in: context.text, baseLocation: context.range.location)
        jumpLabelBuffer.removeAll()
        if jumpTargets.isEmpty {
            NSSound.beep()
        } else {
            scheduleJumpModeTimeout()
        }
    }

    private func exitJumpMode() {
        cancelJumpModeTimeout()
        jumpTargets.removeAll()
        jumpLabelBuffer.removeAll()
    }

    @objc private func jumpModeTimerFired(_ timer: Timer) {
        exitJumpMode()
    }

    private func scheduleJumpModeTimeout() {
        cancelJumpModeTimeout()
        jumpModeTimer = Timer.scheduledTimer(timeInterval: config.timing.jumpModeTimeout, target: self, selector: #selector(jumpModeTimerFired(_:)), userInfo: nil, repeats: false)
    }

    private func cancelJumpModeTimeout() {
        jumpModeTimer?.invalidate()
        jumpModeTimer = nil
    }

    private func jump(to target: JumpTarget, client sender: Any!) {
        guard let client = inputClient(sender) else {
            return
        }
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: target.range.location, length: 0))
    }

    private func surroundingText(around location: Int, client: any IMKTextInput) -> (text: String, range: NSRange) {
        let beforeLength = min(location, 1000)
        let beforeRange = NSRange(location: location - beforeLength, length: beforeLength)
        let beforeText = client.attributedSubstring(from: beforeRange)?.string ?? ""
        let afterText = attributedSubstringAfter(location: location, client: client)
        let text = beforeText + afterText
        return (text, NSRange(location: beforeRange.location, length: text.utf16.count))
    }

    private func attributedSubstringAfter(location: Int, client: any IMKTextInput) -> String {
        for length in stride(from: 1000, through: 1, by: -100) {
            if let text = client.attributedSubstring(from: NSRange(location: location, length: length))?.string {
                return text
            }
        }
        return ""
    }

    private func updateMarkedText(client sender: Any!) {
        let text = state.buffer
        guard let client = inputClient(sender) else {
            return
        }
        let attributed = NSAttributedString(string: text, attributes: markedTextAttributes(length: text.utf16.count))
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func markedTextAttributes(length: Int) -> [NSAttributedString.Key: Any] {
        let range = NSRange(location: 0, length: length)
        if let attributes = mark(forStyle: kTSMHiliteSelectedRawText, at: range) as? [NSAttributedString.Key: Any] {
            return attributes
        }
        return [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0]
    }

    private func clearMarkedText(client sender: Any!) {
        inputClient(sender)?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func inputClient(_ sender: Any!) -> (any IMKTextInput)? {
        sender as? any IMKTextInput
    }

    private func commit(_ text: String, client sender: Any!) {
        guard !text.isEmpty else {
            return
        }
        inputClient(sender)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        state.clear()
        lastInputAt = nil
        compositionStartedAt = nil
        readinessRequestID += 1
        readinessClient = nil
        commitRequestID += 1
    }
}

private enum LocalIntelligenceReadinessAdvisor {
    static func shouldConvert(buffer: String, timeout: TimeInterval) async -> Bool {
        guard #available(macOS 26.0, *) else {
            return false
        }
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await askFoundationModel(buffer: buffer)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @available(macOS 26.0, *)
    private static func askFoundationModel(buffer: String) async -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return false
        }
        let session = LanguageModelSession(model: model)
        let prompt = """
        You decide whether a romaji draft should be converted to Japanese now.
        Answer exactly CONVERT or WAIT.
        CONVERT when the thought looks complete enough to review in Japanese.
        WAIT when the user is likely still in the middle of a word or phrase.

        Draft:
        \(buffer)
        """
        guard let response = try? await session.respond(to: prompt) else {
            return false
        }
        return response.content.uppercased().contains("CONVERT")
    }
}

private final class MemoryStore {
    func loadMemory() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Romajime/memory.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "mtg -> ミーティング\ntodo -> TODO\n"
    }
}

private final class ConfigStore {
    func load() -> RomajimeConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return RomajimeConfig()
        }
        return (try? JSONDecoder().decode(RomajimeConfig.self, from: data)) ?? RomajimeConfig()
    }

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Romajime/config.json")
    }
}

private extension NSEvent {
    func matches(_ stroke: KeyStroke) -> Bool {
        guard keyCode == stroke.keyCode else {
            return false
        }
        guard let requiredModifiers = stroke.requiredModifiers else {
            return true
        }
        let relevantFlags = modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        return relevantFlags == requiredModifiers
    }
}
