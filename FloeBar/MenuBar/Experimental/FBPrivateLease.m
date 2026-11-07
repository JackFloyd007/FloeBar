#import "FBPrivateLease.h"
#import <dlfcn.h>
@interface NSObject (FBMenuBarAssertionAPI)
- (id)initWithAllowedSystemItems:(NSArray *)items allowedBundleIdentifiers:(NSArray *)bundles;
- (void)activateWithConfiguration:(id)config completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end
@implementation FBPrivateLease {
    id _assertion;
    BOOL _cancelled;
}
+ (BOOL)isAvailable {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL); });
    return handle && [NSClassFromString(@"MBAssessmentModeConfiguration") instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)] &&
        [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)] &&
        [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:@selector(invalidate)];
}
- (void)activate:(NSArray<NSString *> *)allowed completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Main queue required");
    if (_cancelled || _assertion || !self.class.isAvailable) { completion(NO); return; }
    @try {
        id config = [[NSClassFromString(@"MBAssessmentModeConfiguration") alloc] initWithAllowedSystemItems:@[@0,@1,@2,@3,@4,@5,@6,@7,@8] allowedBundleIdentifiers:allowed];
        _assertion = [NSClassFromString(@"MBAssessmentModeAssertion") new];
        if (!config || !_assertion) { [self invalidate]; completion(NO); return; }
        // Retain this exact lease until completion; a late success must release it again.
        [_assertion activateWithConfiguration:config completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL success = !error && !self->_cancelled;
                if (!success) { [self invalidate]; }
                completion(success);
            });
        }];
    } @catch (NSException *exception) { [self invalidate]; completion(NO); }
}
- (void)invalidate {
    _cancelled = YES;
    @try { [_assertion invalidate]; } @catch (NSException *exception) { NSLog(@"FloeBar experimental release failed: %@", exception.name); }
}
- (void)dealloc { [self invalidate]; }
@end
