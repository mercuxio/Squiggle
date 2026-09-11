import AppKit

// `LSUIElement` in the Info.plist is what makes the *bundle* an agent, and
// this line is what makes the *process* one. They are not redundant: during
// development the app is launched by `swift run`, which has no bundle and no
// plist, and without this a dock icon and a menu bar menu appear for a program
// whose entire UI is supposed to be one status item.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Held in a `let` for the process's lifetime: `NSApplication.delegate` is a
// weak reference, so a delegate assigned from a temporary is deallocated
// before `run()` ever calls it.
let delegate = AppDelegate()
app.delegate = delegate

app.run()
