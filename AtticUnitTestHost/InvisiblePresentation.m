// This file is linked ONLY into AtticUnitTestHost. Install before AppKit's
// launch and XCTest injection, so even framework-created/harness windows use
// the same boundary. CI/explicit visible runs install no replacements.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "AtticUnitTestHost-Swift.h"

static void FreezeWindowClass(Class cls);
static void Place(NSWindow *window);
static void MaterializeOffscreen(NSWindow *window);

// Typed initializer-family methods preserve ARC's consumed-self/+1 return
// convention. Generic IMP blocks are deliberately not used for initializers.
@interface NSWindow (FGInvisibleInitialization)
- (instancetype)fg_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)deferred __attribute__((objc_method_family(init)));
- (instancetype)fg_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)deferred screen:(NSScreen *)screen __attribute__((objc_method_family(init)));
@end
@implementation NSWindow (FGInvisibleInitialization)
- (instancetype)fg_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)deferred {
    FreezeWindowClass(object_getClass(self));
    // AppKit can recenter a titled window internally, bypassing setFrame.
    // Keep its backing deferred until that initialization has finished and
    // its final logical frame is safe, then honor eager callers.
    self = [self fg_initWithContentRect:[AtticTestPresentationPolicy offscreenFrame:rect] styleMask:style backing:backing defer:YES];
    FreezeWindowClass(object_getClass(self));
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    Place(self);
    if (!deferred) MaterializeOffscreen(self);
    return self;
}
- (instancetype)fg_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)deferred screen:(NSScreen *)screen {
    FreezeWindowClass(object_getClass(self));
    self = [self fg_initWithContentRect:[AtticTestPresentationPolicy offscreenFrame:rect] styleMask:style backing:backing defer:YES screen:screen];
    FreezeWindowClass(object_getClass(self));
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    Place(self);
    if (!deferred) MaterializeOffscreen(self);
    return self;
}
@end

static void Replace(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    NSCAssert(method, @"Missing AppKit presentation boundary: %@", NSStringFromSelector(selector));
    class_addMethod(cls, selector, method_getImplementation(method), method_getTypeEncoding(method));
    method_setImplementation(class_getInstanceMethod(cls, selector), imp_implementationWithBlock(block));
}
static void ReplaceIfPresent(Class cls, NSString *name, id block) {
    SEL selector = NSSelectorFromString(name);
    if (class_getInstanceMethod(cls, selector)) Replace(cls, selector, block);
}
static char frozenClassKey;
static void FreezeWindowClass(Class cls) {
    if (!cls || cls == NSWindow.class || [objc_getAssociatedObject(cls, &frozenClassKey) boolValue]) return;
    objc_setAssociatedObject(cls, &frozenClassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A synthetic isKeyWindow override can cause responder setup itself to
    // steal WindowServer keyboard focus without a makeKeyWindow call.
    for (NSString *name in @[@"canBecomeKeyWindow", @"canBecomeMainWindow", @"isKeyWindow", @"isMainWindow"]) {
        SEL selector = NSSelectorFromString(name);
        if (class_getMethodImplementation(cls, selector) != class_getMethodImplementation(NSWindow.class, selector)) {
            Replace(cls, selector, ^BOOL(NSWindow *window) { return NO; });
        }
    }
    for (NSString *name in @[@"makeKeyWindow", @"becomeKeyWindow", @"makeMainWindow", @"becomeMainWindow"]) {
        SEL selector = NSSelectorFromString(name);
        if (class_getMethodImplementation(cls, selector) != class_getMethodImplementation(NSWindow.class, selector)) {
            Replace(cls, selector, ^(NSWindow *window) {});
        }
    }
}
static void Place(NSWindow *window) {
    NSRect frame = [AtticTestPresentationPolicy offscreenFrame:window.frame];
    if (!NSEqualRects(frame, window.frame)) [window setFrame:frame display:NO];
}

static void Order(NSWindow *window, void (^action)(void)) {
    Place(window);
    action();
}

static void MaterializeOffscreen(NSWindow *window) {
    // AppKit creates a deferred backing only when ordered. The host's
    // ordering/frame boundaries keep both transitions off every display;
    // leave eager callers with a real window number and the original hidden state.
    [window orderWindow:NSWindowAbove relativeTo:0];
    [window orderOut:nil];
}

void AtticInstallInvisiblePresentation(void) {
    if (!AtticTestPresentationPolicy.isInvisible) return;
    // AppKit/SwiftUI can allocate a backing window before the first order
    // call, including zero-sized placeholders. Protect initialization and
    // hidden frame updates as well as explicit presentation.
    method_exchangeImplementations(class_getInstanceMethod(NSWindow.class, @selector(initWithContentRect:styleMask:backing:defer:)),
                                   class_getInstanceMethod(NSWindow.class, @selector(fg_initWithContentRect:styleMask:backing:defer:)));
    method_exchangeImplementations(class_getInstanceMethod(NSWindow.class, @selector(initWithContentRect:styleMask:backing:defer:screen:)),
                                   class_getInstanceMethod(NSWindow.class, @selector(fg_initWithContentRect:styleMask:backing:defer:screen:)));
    SEL order = @selector(orderWindow:relativeTo:);
    IMP originalOrder = class_getMethodImplementation(NSWindow.class, order);
    Replace(NSWindow.class, order, ^(NSWindow *window, NSWindowOrderingMode mode, NSInteger relative) {
        if (mode == NSWindowOut) {
            ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))originalOrder)(window, order, mode, relative);
        } else {
            Order(window, ^{ ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))originalOrder)(window, order, mode, relative); });
        }
    });
    IMP originalFront = class_getMethodImplementation(NSWindow.class, @selector(orderFront:));
    for (NSString *name in @[@"orderFront:", @"orderBack:", @"makeKeyAndOrderFront:"]) {
        SEL selector = NSSelectorFromString(name);
        // makeKeyAndOrderFront deliberately orders without requesting key.
        IMP implementation = originalFront;
        if (![name isEqualToString:@"makeKeyAndOrderFront:"]) implementation = class_getMethodImplementation(NSWindow.class, selector);
        Replace(NSWindow.class, selector, ^(NSWindow *window, id sender) {
            Order(window, ^{ ((void (*)(id, SEL, id))implementation)(window, selector, sender); });
        });
    }
    SEL regardless = @selector(orderFrontRegardless);
    IMP originalRegardless = class_getMethodImplementation(NSWindow.class, regardless);
    Replace(NSWindow.class, regardless, ^(NSWindow *window) {
        Order(window, ^{ ((void (*)(id, SEL))originalRegardless)(window, regardless); });
    });
    SEL frame = @selector(setFrame:display:);
    IMP originalFrame = class_getMethodImplementation(NSWindow.class, frame);
    Replace(NSWindow.class, frame, ^(NSWindow *window, NSRect requested, BOOL display) {
        ((void (*)(id, SEL, NSRect, BOOL))originalFrame)(window, frame,
            [AtticTestPresentationPolicy offscreenFrame:requested], display);
    });
    SEL animated = @selector(setFrame:display:animate:);
    IMP originalAnimated = class_getMethodImplementation(NSWindow.class, animated);
    Replace(NSWindow.class, animated, ^(NSWindow *window, NSRect requested, BOOL display, BOOL animate) {
        ((void (*)(id, SEL, NSRect, BOOL, BOOL))originalAnimated)(window, animated,
            [AtticTestPresentationPolicy offscreenFrame:requested], display, animate);
    });
    for (NSString *name in @[@"setFrameOrigin:", @"setFrameTopLeftPoint:"]) {
        SEL selector = NSSelectorFromString(name);
        IMP implementation = class_getMethodImplementation(NSWindow.class, selector);
        Replace(NSWindow.class, selector, ^(NSWindow *window, NSPoint point) {
            NSRect requested = window.frame;
                requested.origin = point;
                if ([name isEqualToString:@"setFrameTopLeftPoint:"]) requested.origin.y -= requested.size.height;
                NSRect safe = [AtticTestPresentationPolicy offscreenFrame:requested];
                point = safe.origin;
                if ([name isEqualToString:@"setFrameTopLeftPoint:"]) point.y += safe.size.height;
            ((void (*)(id, SEL, NSPoint))implementation)(window, selector, point);
        });
    }
    SEL child = @selector(addChildWindow:ordered:);
    IMP originalChild = class_getMethodImplementation(NSWindow.class, child);
    Replace(NSWindow.class, child, ^(NSWindow *window, NSWindow *childWindow, NSWindowOrderingMode mode) {
        Order(childWindow, ^{ ((void (*)(id, SEL, id, NSWindowOrderingMode))originalChild)(window, child, childWindow, mode); });
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
    // Native popup cells track their menus without NSMenu's popUp entry
    // points. Cover both programmatic clicks and direct attachment.
    for (NSString *name in @[@"performClickWithFrame:inView:", @"attachPopUpWithFrame:inView:"]) {
        Replace(NSPopUpButtonCell.class, NSSelectorFromString(name), ^(NSPopUpButtonCell *cell, NSRect frame, NSView *view) {});
    }
    Replace(object_getClass(NSMenu.class), @selector(popUpContextMenu:withEvent:forView:), ^(id cls, NSMenu *menu, NSEvent *event, NSView *view) {});
    Replace(object_getClass(NSMenu.class), @selector(popUpContextMenu:withEvent:forView:withFont:), ^(id cls, NSMenu *menu, NSEvent *event, NSView *view, NSFont *font) {});
    // SwiftUI/AX native menu buttons bypass NSMenu's public popUp methods.
    // These host-only entry points were inspected on macOS 26.4 and 27;
    // optional variants are absent on some OS versions. No app links this.
    ReplaceIfPresent(NSMenu.class, @"popUpMenuPositioningItem:atLocation:inView:appearance:", ^BOOL(NSMenu *menu, id item, NSPoint point, id view, id appearance) { return NO; });
    for (NSString *name in @[@"_popUpMenuWithEvent:forView:", @"_popUpMenuWithContext:forView:"]) {
        ReplaceIfPresent(NSMenu.class, name, ^(NSMenu *menu, id event, id view) {});
    }
    ReplaceIfPresent(NSMenu.class, @"_popUpMenuRelativeToRect:inView:preferredEdge:", ^BOOL(NSMenu *menu, NSRect rect, id view, NSUInteger edge) { return NO; });
    ReplaceIfPresent(NSMenu.class, @"_popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:", ^(NSMenu *menu, NSRect rect, id view, CGFloat width, NSUInteger flags, id provider) {});
    ReplaceIfPresent(NSMenu.class, @"_popUpMenuPositioningItem:atLocation:inView:completionBlock:", ^(NSMenu *menu, id item, NSPoint point, id view, id completion) {});
    for (NSString *name in @[@"_popUpContextMenu:withContext:forView:", @"_popUpContextMenu:withEvent:forView:"]) {
        ReplaceIfPresent(NSMenu.class, name, ^(NSMenu *menu, id contextMenu, id event, id view) {});
    }
    for (NSString *name in @[@"_popUpContextMenu:withContext:forView:withFont:", @"_popUpContextMenu:withEvent:forView:withFont:"]) {
        ReplaceIfPresent(NSMenu.class, name, ^(NSMenu *menu, id contextMenu, id event, id view, id font) {});
    }
    for (NSString *name in @[@"_popUpContextMenu:withContext:forView:withFont:completionBlock:", @"_popUpContextMenu:withEvent:forView:withFont:completionBlock:"]) {
        ReplaceIfPresent(NSMenu.class, name, ^(NSMenu *menu, id contextMenu, id event, id view, id font, id completion) {});
    }
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
