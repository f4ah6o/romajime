import AppKit
import InputMethodKit
import RomajimeCore

final class InputMethodApplicationDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = IMKServer(name: "Romajime_1_Connection", bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

@objc(RomajimeInputController)
public final class RomajimeInputController: IMKInputController {
    private var state = CompositionState()
    private let backend = RuleBasedConversionBackend()
    private let memoryStore = MemoryStore()
    private let idleConversionPolicy = IdleConversionPolicy()
    private var idleTimer: Timer?
    private var lastInputAt: Date?

    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else {
            return false
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
        convertAndCommit(client: sender)
    }

    public override func candidates(_ sender: Any!) -> [Any]! {
        state.candidates.map(\.text)
    }

    private func handleCommand(_ event: NSEvent, client sender: Any!) -> Bool {
        switch event.keyCode {
        case 49:
            guard state.isComposing else {
                return false
            }
            state.append(" ")
            updateMarkedText(client: sender)
            scheduleIdleConversion(client: sender)
            return true
        case 36, 76:
            guard state.isComposing else {
                return false
            }
            return true
        case 51:
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
        case 53:
            guard state.isComposing else {
                return false
            }
            convertAndCommit(client: sender)
            return true
        default:
            return false
        }
    }

    private func convertAndCommit(client sender: Any!) {
        cancelIdleConversion()
        let request = ConversionRequest(raw: state.buffer, memory: memoryStore.loadMemory(), kanaCandidate: nil)
        let result = (try? backend.convert(request)) ?? ConversionResult(converted: state.buffer, refined: state.buffer, confidence: 0, candidates: [])
        commit(result.candidates.first?.text ?? state.buffer, client: sender)
    }

    private func scheduleIdleConversion(client sender: Any!) {
        cancelIdleConversion()
        guard state.isComposing, !state.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let now = Date()
        let interval = lastInputAt.map { now.timeIntervalSince($0) }
        lastInputAt = now
        let delay = idleConversionPolicy.delay(afterKeystrokeInterval: interval)
        let client = sender as AnyObject
        idleTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(idleTimerFired(_:)), userInfo: client, repeats: false)
    }

    @objc private func idleTimerFired(_ timer: Timer) {
        guard let client = timer.userInfo else {
            return
        }
        convertAndCommit(client: client)
    }

    private func cancelIdleConversion() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func updateMarkedText(client sender: Any!) {
        let text = state.buffer
        inputClient(sender)?.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
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
    }
}

private final class MemoryStore {
    func loadMemory() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Romajime/memory.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "mtg -> ミーティング\ntodo -> TODO\n"
    }
}
