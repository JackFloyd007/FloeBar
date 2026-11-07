#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Runtime-only, opt-in menu-bar assertion. Never enters whole-device assessment.
NS_SWIFT_UI_ACTOR
@interface FBPrivateLease : NSObject
+ (BOOL)isAvailable;
// All completion paths, including refusals and late callbacks, run on main.
- (void)activate:(NSArray<NSString *> *)allowed completion:(NS_SWIFT_UI_ACTOR void (^)(BOOL))completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
