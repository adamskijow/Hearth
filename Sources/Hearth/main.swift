// SPDX-License-Identifier: MIT

import AppKit

// Hearth is a background menubar agent (LSUIElement). Bring up the shared
// application first so the status bar is available, then install the delegate
// and run as an accessory (no Dock icon, no main window).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
