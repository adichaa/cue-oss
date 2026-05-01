import AppKit
import Foundation

// Force unbuffered stdout so print() output appears immediately in redirected logs.
setbuf(stdout, nil)
setbuf(stderr, nil)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    fputs("[cue] app launched\n", stderr)
    app.run()
}
