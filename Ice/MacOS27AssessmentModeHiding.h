// Runtime-only bridge to macOS 27's private MenuBarClientCore assessment API.
// Derived from Thaw's GPLv3 macOS 27 compatibility implementation.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL IceAssessmentModeHidingAvailable(void);

void *_Nullable IceAssessmentModeHidingActivate(
    NSArray<NSString *> *allowedBundleIdentifiers,
    NSArray<NSNumber *> *allowedSystemItems,
    void (^_Nullable onFailure)(void));

void IceAssessmentModeHidingInvalidate(void *_Nullable handle);

NS_ASSUME_NONNULL_END
