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
        return true
    }

    public override func commitComposition(_ sender: Any!) {
        commitCurrentText(client: sender)
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
            convertOrCycle(client: sender)
            return true
        case 36, 76:
            guard state.isComposing else {
                return false
            }
            commitCurrentText(client: sender)
            return true
        case 51:
            guard state.isComposing else {
                return false
            }
            state.deleteBackward()
            if state.isComposing {
                updateMarkedText(client: sender)
            } else {
                clearMarkedText(client: sender)
            }
            return true
        case 53:
            guard state.isComposing else {
                return false
            }
            state.clear()
            clearMarkedText(client: sender)
            return true
        default:
            return false
        }
    }

    private func convertOrCycle(client sender: Any!) {
        if state.candidates.isEmpty {
            let request = ConversionRequest(raw: state.buffer, memory: memoryStore.loadMemory(), kanaCandidate: nil)
            let result = (try? backend.convert(request)) ?? ConversionResult(converted: state.buffer, refined: state.buffer, confidence: 0, candidates: [])
            state.setCandidates(result.candidates)
        } else {
            state.selectNextCandidate()
        }
        updateMarkedText(client: sender)
    }

    private func commitCurrentText(client sender: Any!) {
        let text = state.selectedCandidate?.text ?? state.buffer
        guard !text.isEmpty else {
            return
        }
        inputClient(sender)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        state.clear()
    }

    private func updateMarkedText(client sender: Any!) {
        let text = state.selectedCandidate?.text ?? state.buffer
        inputClient(sender)?.setMarkedText(text, selectionRange: NSRange(location: text.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func clearMarkedText(client sender: Any!) {
        inputClient(sender)?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func inputClient(_ sender: Any!) -> (any IMKTextInput)? {
        sender as? any IMKTextInput
    }
}

private final class MemoryStore {
    func loadMemory() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Romajime/memory.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "mtg -> ミーティング\ntodo -> TODO\n"
    }
}
