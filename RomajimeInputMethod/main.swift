import AppKit

let application = NSApplication.shared
let delegate = InputMethodApplicationDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
