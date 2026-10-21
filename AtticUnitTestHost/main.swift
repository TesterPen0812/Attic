import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
AtticInstallInvisiblePresentation()
// The CI wrapper sets the keyboard mode before launching this process.
// AXEnhancedUserInterface is process-local; no local developer setting changes.
if ProcessInfo.processInfo.environment["ATTIC_CI_INPUT_MODES"] == "1" {
    let expected = ProcessInfo.processInfo.environment["ATTIC_CI_KEYBOARD_MODE"]
    guard expected == "0" || expected == "3",
          application.isFullKeyboardAccessEnabled == (expected == "3") else {
        print("::error::Test host keyboard mode did not match the CI request: \(String(describing: expected))")
        exit(1)
    }
    let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    application.accessibilitySetValue(false, forAttribute: attribute)
    guard application.accessibilityAttributeValue(attribute) as? Bool == false else {
        print("::error::Test host could not establish AXEnhancedUserInterface=0")
        exit(1)
    }
    print("CI_INPUT_MODES host keyboard=\(expected!) nativeFKA=\(application.isFullKeyboardAccessEnabled) AXEnhancedUserInterface=0")
}
application.run()
