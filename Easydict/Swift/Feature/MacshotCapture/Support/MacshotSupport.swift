import AppKit

/// Localization shim for the ported macshot capture UI.
///
/// macshot resolves copy through `L(_:)` at runtime; its string keys are
/// already human-readable English, so the shim returns them verbatim.
func L(_ key: String) -> String {
    key
}

// MARK: - CaptureSound

/// Shutter/copy feedback sound for the capture flow.
///
/// Replaces macshot's `AppDelegate.captureSound` so the ported overlay does
/// not depend on the host app delegate.
enum CaptureSound {
    static let sound: NSSound? = {
        guard let url = URL(string: "/System/Library/Sounds/Pop.aiff") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()
}
