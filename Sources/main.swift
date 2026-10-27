import AppKit

// AppKit lifecycle: the app is a menu bar agent, so it owns its status item,
// panel and settings window directly instead of going through SwiftUI scenes.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
