import Carbon
import Foundation

// Lists every input source TIS knows about (including disabled ones).

guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
    print("no list")
    exit(1)
}

print("total: \(list.count)")
for source in list {
    guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
    let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String

    var category = ""
    if let catPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) {
        category = Unmanaged<CFString>.fromOpaque(catPtr).takeUnretainedValue() as String
    }

    var type = ""
    if let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
        type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
    }

    print("\(id) [\(category) / \(type)]")
}
