//
// Runtime-only bridge to macOS 27's private MenuBarClientCore assessment API.
// Derived from Thaw's GPLv3 macOS 27 compatibility implementation.
//

#import "MacOS27AssessmentModeHiding.h"
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>

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
                                      void (^_Nullable onActivated)(void),
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

        void (^activatedCopy)(void) = onActivated ? [onActivated copy] : nil;
        void (^failureCopy)(void) = onFailure ? [onFailure copy] : nil;
        [assertion activateWithConfiguration:configuration
                           completionHandler:^(NSError *_Nullable error) {
            if (error) {
                NSLog(@"[IceAssessmentModeHiding] activation failed: %@", error);
                if (failureCopy) {
                    dispatch_async(dispatch_get_main_queue(), failureCopy);
                }
            } else if (activatedCopy) {
                // Always defer success until after the bridge returned its
                // retained assertion handle to Swift.
                dispatch_async(dispatch_get_main_queue(), activatedCopy);
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

typedef int32_t (*IceWindowServerConnectionFunction)(void);
typedef CGError (*IceWindowServerUpdateFunction)(int32_t connectionID);

typedef struct {
    int32_t connectionID;
    IceWindowServerUpdateFunction reenable;
} IceScreenUpdateSuspension;

void *IceScreenUpdateSuspensionBegin(void) {
    static void *skyLightHandle;
    static IceWindowServerConnectionFunction mainConnection;
    static IceWindowServerUpdateFunction disableUpdate;
    static IceWindowServerUpdateFunction reenableUpdate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW | RTLD_LOCAL
        );
        if (!skyLightHandle) {
            return;
        }
        mainConnection = (IceWindowServerConnectionFunction)dlsym(
            skyLightHandle,
            "CGSMainConnectionID"
        );
        disableUpdate = (IceWindowServerUpdateFunction)dlsym(
            skyLightHandle,
            "SLSDisableUpdate"
        );
        reenableUpdate = (IceWindowServerUpdateFunction)dlsym(
            skyLightHandle,
            "SLSReenableUpdate"
        );
    });

    if (!mainConnection || !disableUpdate || !reenableUpdate) {
        return NULL;
    }

    int32_t connectionID = mainConnection();
    if (connectionID == 0 || disableUpdate(connectionID) != kCGErrorSuccess) {
        return NULL;
    }

    IceScreenUpdateSuspension *suspension = calloc(1, sizeof(*suspension));
    if (!suspension) {
        reenableUpdate(connectionID);
        return NULL;
    }
    suspension->connectionID = connectionID;
    suspension->reenable = reenableUpdate;
    return suspension;
}

void IceScreenUpdateSuspensionEnd(void *handle) {
    if (!handle) {
        return;
    }
    IceScreenUpdateSuspension *suspension = handle;
    suspension->reenable(suspension->connectionID);
    free(suspension);
}
