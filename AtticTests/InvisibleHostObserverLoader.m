#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

// +load registers the observer before test selection. Inspect after teardown,
// immediately before the public XCTestRun.stop transition: didFinish is too
// late to record an issue on that test (XCTest rejects stopped-run failures).
@interface AtticInvisibleHostObserverLoader : NSObject
@end
@implementation AtticInvisibleHostObserverLoader
+ (void)load {
    Class observer = NSClassFromString(@"AtticInvisibleHostObserver");
    NSCAssert(observer, @"Invisible-host canary was not linked");
    NSNumber *enabled = [observer performSelector:NSSelectorFromString(@"install")];
    if (!enabled.boolValue) return;
    SEL selector = @selector(stop);
    Method method = class_getInstanceMethod(XCTestCaseRun.class, selector);
    IMP original = method_getImplementation(method);
    class_addMethod(XCTestCaseRun.class, selector, original, method_getTypeEncoding(method));
    id block = ^(XCTestCaseRun *run) {
        if ([run.test isKindOfClass:XCTestCase.class]) {
            [observer performSelector:NSSelectorFromString(@"inspect:") withObject:run.test];
        }
        ((void (*)(id, SEL))original)(run, selector);
    };
    method_setImplementation(class_getInstanceMethod(XCTestCaseRun.class, selector), imp_implementationWithBlock(block));
}
@end
