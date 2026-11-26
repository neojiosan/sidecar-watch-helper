#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSDictionary<NSString *, NSString *> SCDeviceRow;
FOUNDATION_EXPORT NSErrorDomain const SCDeviceErrorDomain;
typedef NS_ERROR_ENUM(SCDeviceErrorDomain, SCDeviceErrorCode) {
    SCDeviceErrorUnavailable = 1,
    SCDeviceErrorTransitionTimedOut = 2
};

// Each row contains "id" (a persistent device identifier) and "name".
// A nil list means the state is unknown. An empty list is a successful query.
@interface SCDeviceController : NSObject
- (nullable NSArray<SCDeviceRow *> *)connectedDevices:(NSError **)error;
- (nullable NSArray<SCDeviceRow *> *)availableDevices:(NSError **)error;

// The completion runs on the main queue after observing the target state or an error.
- (void)setConnected:(BOOL)connected
            deviceID:(NSString *)deviceID
          completion:(void (^)(NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
