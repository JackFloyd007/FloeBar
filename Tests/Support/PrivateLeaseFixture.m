#import "PrivateLeaseFixture.h"

// Link-time replacement for the private bridge: never loads a system assertion.
@interface FBPrivateLease ()
@property (copy) void (^testCompletion)(BOOL);
@property NSUInteger testInvalidations;
@end

static NSMutableArray<FBPrivateLease *> *testLeases;

@implementation FBPrivateLease
+ (BOOL)isAvailable { return YES; }
- (void)activate:(NSArray<NSString *> *)allowed completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Activation must run on main");
    if (!testLeases) { testLeases = [NSMutableArray array]; }
    [testLeases addObject:self];
    self.testCompletion = completion;
}
- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"Invalidation must run on main");
    self.testInvalidations += 1;
}
@end

void FBTestCompleteLease(NSUInteger index, BOOL success) {
    FBPrivateLease *lease = testLeases[index];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSCAssert(NSThread.isMainThread, @"Completion must run on main");
        lease.testCompletion(success);
    });
}
NSUInteger FBTestLeaseCount(void) { return testLeases.count; }
NSUInteger FBTestInvalidations(NSUInteger index) { return testLeases[index].testInvalidations; }
