import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class OpticalPermissionController: ObservableObject {
    private static let hasRequestedKey = "hasRequestedOpticalScreenCaptureAccess"

    @Published private(set) var state: OpticalCapturePermissionState

    private let defaults: UserDefaults
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let openSettings: () -> Void

    init(
        defaults: UserDefaults = .standard,
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        openSettings: @escaping () -> Void = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    ) {
        self.defaults = defaults
        self.preflight = preflight
        self.request = request
        self.openSettings = openSettings
        if preflight() {
            state = .authorized
        } else if defaults.bool(forKey: Self.hasRequestedKey) {
            state = .denied
        } else {
            state = .notRequested
        }
    }

    func refresh() {
        if preflight() {
            state = .authorized
        } else if defaults.bool(forKey: Self.hasRequestedKey) {
            state = .denied
        } else {
            state = .notRequested
        }
    }

    /// The only entry point that may present the macOS Screen Recording prompt.
    /// Call this from an explicit user action; never from launch or panel reveal.
    func requestAccess() {
        defaults.set(true, forKey: Self.hasRequestedKey)
        state = request() ? .authorized : .denied
    }

    func openSystemSettings() {
        openSettings()
    }
}
