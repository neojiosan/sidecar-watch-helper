#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Completion runs on the main queue. Netflix opens in the selected browser.
void OpenWatchPlayer(NSString *service, NSString *browserID, void (^completion)(NSRunningApplication * _Nullable, NSError * _Nullable));

NS_ASSUME_NONNULL_END
