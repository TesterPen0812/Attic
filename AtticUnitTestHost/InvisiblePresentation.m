// This file is linked ONLY into AtticUnitTestHost. Install before AppKit's
// launch and XCTest injection, so even framework-created/harness windows use
// the same boundary. CI/explicit visible runs install no replacements.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "AtticUnitTestHost-Swift.h"

static void Replace(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    NSCAssert(method, @"Missing AppKit presentation boundary: %@", NSStringFromSelector(selector));
    class_addMethod(cls, selector, method_getImplementation(method), method_getTypeEncoding(method));
    method_setImplementation(class_getInstanceMethod(cls, selector), imp_implementationWithBlock(block));
}
static void Place(NSWindow *window) {
    NSRect frame = [AtticTestPresentationPolicy offscreenFrame:window.frame];
    if (!NSEqualRects(frame, window.frame)) [window setFrame:frame display:NO];
}

void AtticInstallInvisiblePresentation(void) {
    if (!AtticTestPresentationPolicy.isInvisible) return;
    SEL order = @selector(orderWindow:relativeTo:);
    IMP originalOrder = class_getMethodImplementation(NSWindow.class, order);
    Replace(NSWindow.class, order, ^(NSWindow *window, NSWindowOrderingMode mode, NSInteger relative) {
        if (mode != NSWindowOut) Place(window);
        ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))originalOrder)(window, order, mode, relative);
    });
    for (NSString *name in @[@"orderFront:", @"orderBack:", @"makeKeyAndOrderFront:"]) {
        SEL selector = NSSelectorFromString(name);
        // makeKeyAndOrderFront deliberately orders without requesting key.
        IMP implementation = class_getMethodImplementation(NSWindow.class, @selector(orderFront:));
        if (![name isEqualToString:@"makeKeyAndOrderFront:"]) implementation = class_getMethodImplementation(NSWindow.class, selector);
        Replace(NSWindow.class, selector, ^(NSWindow *window, id sender) {
            Place(window);
            ((void (*)(id, SEL, id))implementation)(window, selector, sender);
        });
    }
    SEL regardless = @selector(orderFrontRegardless);
    IMP originalRegardless = class_getMethodImplementation(NSWindow.class, regardless);
    Replace(NSWindow.class, regardless, ^(NSWindow *window) {
        Place(window);
        ((void (*)(id, SEL))originalRegardless)(window, regardless);
    });
    SEL frame = @selector(setFrame:display:);
    IMP originalFrame = class_getMethodImplementation(NSWindow.class, frame);
    Replace(NSWindow.class, frame, ^(NSWindow *window, NSRect requested, BOOL display) {
        ((void (*)(id, SEL, NSRect, BOOL))originalFrame)(window, frame,
            window.isVisible ? [AtticTestPresentationPolicy offscreenFrame:requested] : requested, display);
    });
    SEL animated = @selector(setFrame:display:animate:);
    IMP originalAnimated = class_getMethodImplementation(NSWindow.class, animated);
    Replace(NSWindow.class, animated, ^(NSWindow *window, NSRect requested, BOOL display, BOOL animate) {
        ((void (*)(id, SEL, NSRect, BOOL, BOOL))originalAnimated)(window, animated,
            window.isVisible ? [AtticTestPresentationPolicy offscreenFrame:requested] : requested, display, animate);
    });
    // Prevent AppKit from pulling off-display titled windows back on display.
    Replace(NSWindow.class, @selector(constrainFrameRect:toScreen:), ^NSRect(NSWindow *window, NSRect rect, NSScreen *screen) { return rect; });
    for (NSString *name in @[@"makeKeyWindow", @"becomeKeyWindow", @"makeMainWindow", @"becomeMainWindow"]) {
        Replace(NSWindow.class, NSSelectorFromString(name), ^(NSWindow *window) {});
    }
    for (Class cls in @[NSWindow.class, NSPanel.class]) {
        Replace(cls, @selector(canBecomeKeyWindow), ^BOOL(NSWindow *window) { return NO; });
        Replace(cls, @selector(canBecomeMainWindow), ^BOOL(NSWindow *window) { return NO; });
    }
    Replace(NSApplication.class, @selector(activate), ^(NSApplication *app) {});
    Replace(NSApplication.class, @selector(activateIgnoringOtherApps:), ^(NSApplication *app, BOOL ignore) {});
    Replace(NSApplication.class, @selector(setActivationPolicy:), ^BOOL(NSApplication *app, NSApplicationActivationPolicy policy) { return policy == NSApplicationActivationPolicyProhibited; });
    Replace(NSApplication.class, @selector(orderFrontCharacterPalette:), ^(NSApplication *app, id sender) {});
    Replace(NSMenu.class, @selector(popUpMenuPositioningItem:atLocation:inView:), ^BOOL(NSMenu *menu, NSMenuItem *item, NSPoint point, NSView *view) { return NO; });
    Replace(object_getClass(NSMenu.class), @selector(popUpContextMenu:withEvent:forView:), ^(id cls, NSMenu *menu, NSEvent *event, NSView *view) {});
    Replace(object_getClass(NSMenu.class), @selector(popUpContextMenu:withEvent:forView:withFont:), ^(id cls, NSMenu *menu, NSEvent *event, NSView *view, NSFont *font) {});
    Replace(NSPopover.class, @selector(showRelativeToRect:ofView:preferredEdge:), ^(NSPopover *popover, NSRect rect, NSView *view, NSRectEdge edge) {});
    // System save/open panels may run in a separate service process. Cancel
    // at the entry point rather than allowing a remote dialog to be created.
    for (Class cls in @[NSSavePanel.class, NSOpenPanel.class, NSAlert.class]) {
        Replace(cls, @selector(runModal), ^NSModalResponse(id panel) { return NSModalResponseCancel; });
        Replace(cls, @selector(beginSheetModalForWindow:completionHandler:), ^(id panel, NSWindow *window, void (^completion)(NSModalResponse)) {
            if (completion) completion(NSModalResponseCancel);
        });
    }
    Replace(NSSavePanel.class, @selector(beginWithCompletionHandler:), ^(id panel, void (^completion)(NSModalResponse)) {
        if (completion) completion(NSModalResponseCancel);
    });
    Replace(NSWindow.class, @selector(beginSheet:completionHandler:), ^(NSWindow *window, NSWindow *sheet, void (^completion)(NSModalResponse)) {
        if (completion) completion(NSModalResponseCancel);
    });
    Replace(NSApplication.class, @selector(runModalForWindow:), ^NSModalResponse(NSApplication *app, NSWindow *window) { return NSModalResponseCancel; });
    NSLog(@"Attic invisible unit-test host: presentation and keyboard acquisition disabled");
}
