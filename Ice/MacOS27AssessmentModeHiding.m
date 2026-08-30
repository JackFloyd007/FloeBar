//
// Runtime-only bridge to macOS 27's private MenuBarClientCore assessment API.
// Derived from Thaw's GPLv3 macOS 27 compatibility implementation.
//

#import "MacOS27AssessmentModeHiding.h"
#import <dlfcn.h>

@interface MBAssessmentModeConfiguration : NSObject
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
                  allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
@end

@interface MBAssessmentModeAssertion : NSObject
- (void)activateWithConfiguration:(id)configuration
                completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
- (void)invalidate;
@end

static const char *IceMenuBarClientCorePath =
    "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";

static BOOL IceEnsureMenuBarClientCoreLoaded(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded = NO;
    dispatch_once(&onceToken, ^{
        loaded = dlopen(IceMenuBarClientCorePath, RTLD_NOW) != NULL;
        if (!loaded) {
            NSLog(@"[IceAssessmentModeHiding] failed to load MenuBarClientCore: %s", dlerror());
        }
    });
    return loaded;
}

BOOL IceAssessmentModeHidingAvailable(void) {
    return IceEnsureMenuBarClientCoreLoaded() &&
           NSClassFromString(@"MBAssessmentModeConfiguration") != nil &&
           NSClassFromString(@"MBAssessmentModeAssertion") != nil;
}

void *IceAssessmentModeHidingActivate(NSArray<NSString *> *allowedBundleIdentifiers,
                                      NSArray<NSNumber *> *allowedSystemItems,
                                      void (^_Nullable onFailure)(void)) {
    if (!IceAssessmentModeHidingAvailable()) {
        return NULL;
    }

    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");

    @try {
        MBAssessmentModeConfiguration *configuration =
            [[configurationClass alloc] initWithAllowedSystemItems:(allowedSystemItems ?: @[])
                                          allowedBundleIdentifiers:(allowedBundleIdentifiers ?: @[])];
        MBAssessmentModeAssertion *assertion = [[assertionClass alloc] init];
        if (!configuration || !assertion) {
            return NULL;
        }

        void (^failureCopy)(void) = onFailure ? [onFailure copy] : nil;
        [assertion activateWithConfiguration:configuration
                           completionHandler:^(NSError *_Nullable error) {
            if (error) {
                NSLog(@"[IceAssessmentModeHiding] activation failed: %@", error);
                if (failureCopy) {
                    dispatch_async(dispatch_get_main_queue(), failureCopy);
                }
            }
        }];
        return (void *)CFBridgingRetain(assertion);
    } @catch (NSException *exception) {
        NSLog(@"[IceAssessmentModeHiding] activation threw: %@", exception);
        return NULL;
    }
}

void IceAssessmentModeHidingInvalidate(void *handle) {
    if (!handle) {
        return;
    }
    MBAssessmentModeAssertion *assertion = (MBAssessmentModeAssertion *)CFBridgingRelease(handle);
    @try {
        [assertion invalidate];
    } @catch (NSException *exception) {
        NSLog(@"[IceAssessmentModeHiding] invalidate threw: %@", exception);
    }
}
