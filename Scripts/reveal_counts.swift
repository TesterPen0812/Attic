// Diagnostic overlay only; never linked into a normal application build.
import ObjectiveC
import QuartzCore
import SwiftUI

@MainActor
enum RevealCounts {
    private static var active = false
    private static var installed = false
    private static var calls: [String: Int] = [:]
    private static var hooks: [String] = []
    private static var selectors: [String] = []
    private static var before: [String: Any] = [:]
    private static var ordering: [String: Int] = [:]

    static func install() {
        guard !installed,
              ProcessInfo.processInfo.environment["ATTIC_REVEAL_COUNTS"] == "1",
              Bundle.main.bundleIdentifier == "com.taha.Attic.preview.phasex" else { return }
        installed = true
        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else { return }
        defer { free(unsafeBitCast(classes, to: UnsafeMutableRawPointer.self)) }
        let raw = unsafeBitCast(classes, to: UnsafeRawPointer.self)
            .assumingMemoryBound(to: UnsafeRawPointer.self)
        for index in 0..<Int(count) {
            // Some registered Objective-C root classes do not implement
            // NSObject.class. Reading AnyClass through the autoreleasing
            // pointer invokes a Swift dynamic cast on those classes.
            let cls: AnyClass = unsafeBitCast(raw[index], to: AnyClass.self)
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &methodCount) else { continue }
            defer { free(methods) }
            for n in 0..<Int(methodCount) {
                let method = methods[n]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                let className = String(cString: class_getName(cls))
                let interesting = (className.contains("Hosting") && name.lowercased().contains("environment"))
                    || (className.contains("Appearance") && name.lowercased().contains("apply"))
                    || name == "viewDidChangeEffectiveAppearance" || (className.contains("Transaction") && name == "commit")
                guard interesting else { continue }
                let signature = String(cString: method_getTypeEncoding(method)!)
                selectors.append(className + "." + name + " " + signature)
                guard method_getNumberOfArguments(method) == 2,
                      signature.hasPrefix("v") else { continue }
                let original = unsafeBitCast(method_getImplementation(method),
                    to: (@convention(c) (AnyObject, Selector) -> Void).self)
                let key = className + "." + name
                let block: @convention(block) (AnyObject) -> Void = { object in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { if active { calls[key, default: 0] += 1 } }
                    }
                    original(object, selector)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                hooks.append(key)
            }
        }
        // Explicit Core Animation transaction commits, including AppKit's
        // ordering transaction. Implicit C++ commits are not this selector.
        if let cls = object_getClass(CATransaction.self),
           let method = class_getInstanceMethod(cls, NSSelectorFromString("commit")) {
            let selector = method_getName(method)
            let original = unsafeBitCast(method_getImplementation(method),
                to: (@convention(c) (AnyObject, Selector) -> Void).self)
            let block: @convention(block) (AnyObject) -> Void = { object in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { if active { calls["CATransaction.commit", default: 0] += 1 } }
                }
                original(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            hooks.append("CATransaction.commit")
        }
        // Public AppKit drawing-appearance scope. Private apply functions
        // absent from the Objective-C runtime are explicitly unobservable.
        let selector = NSSelectorFromString("performAsCurrentDrawingAppearance:")
        if let method = class_getInstanceMethod(NSAppearance.self, selector) {
            let original = unsafeBitCast(method_getImplementation(method),
                to: (@convention(c) (AnyObject, Selector, AnyObject) -> Void).self)
            let block: @convention(block) (AnyObject, AnyObject) -> Void = { object, action in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { if active { calls["NSAppearance.performAsCurrentDrawingAppearance", default: 0] += 1 } }
                }
                original(object, selector, action)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            hooks.append("NSAppearance.performAsCurrentDrawingAppearance")
        }
    }

    static func record(_ name: String) {
        if active { calls[name, default: 0] += 1 }
    }

    static func begin(_ panel: NSWindow) {
        guard installed else { return }
        before = hierarchy(panel)
        calls = [:]
        ordering = [:]
        active = true
    }

    @inline(never) static func beginOrder() {
        guard installed else { return }
        ordering = calls
    }

    @inline(never) static func endOrder() {
        guard installed else { return }
        ordering = calls.mapValues { $0 } .reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value - ordering[entry.key, default: 0]
        }
    }

    static func end(_ panel: NSWindow) {
        guard installed else { return }
        active = false
        guard let root = PerformanceProbe.validatedRoot(environment: ProcessInfo.processInfo.environment) else { return }
        let record: [String: Any] = ["before": before, "after": hierarchy(panel),
            "calls": calls, "ordering_calls": ordering, "hooks": hooks.sorted(), "available_selectors": selectors.sorted(),
            "limitations": ["Objective-C counters cover main-thread ordering only. Swift-only updateEnvironment and private NSAppearance.apply are not Objective-C selectors.",
                             "Implicit Core Animation C++ commits are not CATransaction.commit calls."]]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("reveal-counts.json"))
        }
    }

    private static func hierarchy(_ panel: NSWindow) -> [String: Any] {
        var views: [NSView] = []
        func visit(_ view: NSView) { views.append(view); for child in view.subviews { visit(child) } }
        if let content = panel.contentView { visit(content) }
        let roots = views.filter { view in
            var cls: AnyClass? = type(of: view)
            while let current = cls {
                if String(cString: class_getName(current)).contains("NSHostingView") { return true }
                cls = class_getSuperclass(current)
            }
            return false
        }
        var loop: Set<ObjectIdentifier> = []
        var next = panel.initialFirstResponder ?? panel.contentView
        while let view = next, loop.insert(ObjectIdentifier(view)).inserted { next = view.nextKeyView }
        return ["views": views.count, "hosting_roots": roots.count,
                "root_types": roots.map { String(reflecting: type(of: $0)) }.sorted(),
                "layer_backed_views": views.filter(\.wantsLayer).count,
                "key_loop_views": loop.count,
                "accepts_first_responder_views": views.filter(\.acceptsFirstResponder).count,
                "panel_is_key": panel.isKeyWindow,
                "app_key_is_panel": NSApp.keyWindow === panel,
                "view_tree": views.map { view in
                    ["type": String(reflecting: type(of: view)), "frame": NSStringFromRect(view.frame),
                     "parent": view.superview.map { String(reflecting: type(of: $0)) } ?? "",
                     "layer_backed": view.wantsLayer, "hidden": view.isHidden] as [String: Any]
                },
                "view_types": Dictionary(views.map { (String(reflecting: type(of: $0)), 1) }, uniquingKeysWith: +)]
    }
}
