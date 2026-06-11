import Carbon
import Foundation

// Romajime input-source setup tool.
//
// Subcommands:
//   refresh  — delete the per-user input source cache, then immediately force a
//              rescan in-process so the rebuilt cache includes ~/Library/Input Methods.
//              (The deletion and the rescan must happen in one process: if another —
//              possibly sandboxed — process rebuilds the cache first, user-installed
//              input methods are silently dropped from it.)
//   status   — report whether the input source is registered/enabled.
//
// Note: do NOT call TISRegisterInputSource or TISEnableInputSource here. On
// macOS 26 both write back an input source store that drops user-installed
// bundles for other processes, undoing the refresh. Enabling is the user's
// job via System Settings → Keyboard → Input Sources.

let bundleID = "com.f12o.inputmethod.Romajime"
let modeSourceID = "com.f12o.inputmethod.Romajime.Japanese"

func userCacheDir() -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
    guard len > 0 else { return NSTemporaryDirectory() }
    return String(cString: buf)
}

func deleteIntlDataCache() {
    let dir = userCacheDir()
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("com.apple.IntlDataCache") {
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        print("deleted cache: \(name)")
    }
}

func romajimeSources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
}

func sourceID(_ source: TISInputSource) -> String {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func reportStatus() -> Bool {
    let sources = romajimeSources()
    if sources.isEmpty {
        print("NOT FOUND: \(bundleID)")
        return false
    }
    for source in sources {
        print("\(sourceID(source)) enabled=\(boolProperty(source, kTISPropertyInputSourceIsEnabled)) selectable=\(boolProperty(source, kTISPropertyInputSourceIsSelectCapable))")
    }
    return true
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"

switch command {
case "refresh":
    deleteIntlDataCache()
    // Touching TIS immediately after deletion forces this (unsandboxed) process
    // to rebuild the cache with the full directory scan.
    _ = TISCreateInputSourceList(nil, true)?.takeRetainedValue()
    exit(reportStatus() ? 0 : 1)
case "status":
    exit(reportStatus() ? 0 : 1)
default:
    print("usage: imesetup [refresh|status]")
    exit(64)
}
