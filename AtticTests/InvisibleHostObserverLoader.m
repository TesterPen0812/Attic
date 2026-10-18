#import <Foundation/Foundation.h>

// +load runs when XCTest loads the bundle, before any test case is selected.
// No test superclass or individual fixture needs to remember registration.
@interface AtticInvisibleHostObserverLoader : NSObject
@end
@implementation AtticInvisibleHostObserverLoader
+ (void)load {
    Class observer = NSClassFromString(@"AtticInvisibleHostObserver");
    NSCAssert(observer, @"Invisible-host canary was not linked");
    [observer performSelector:NSSelectorFromString(@"install")];
}
@end
