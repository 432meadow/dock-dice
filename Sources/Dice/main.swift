import AppKit

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// Regular app: it needs its Dock icon. No main window is ever created.
app.setActivationPolicy(.regular)
app.run()
