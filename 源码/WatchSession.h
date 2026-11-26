#import <AppKit/AppKit.h>
@class SCDeviceController;
typedef void (^PlayerOpener)(NSString *, void (^)(NSRunningApplication *, NSError *));

@interface WatchSession : NSObject
- (instancetype)initWithDevices:(SCDeviceController *)devices defaults:(NSUserDefaults *)defaults openPlayer:(PlayerOpener)openPlayer;
@property (readonly) BOOL pending;
@property (readonly) BOOL automatic;
@property (readonly) BOOL busy;
@property (readonly, copy) NSString *status;
@property (copy) void (^onChange)(void);
- (void)start:(NSString *)service;
- (void)openWithoutDisconnect:(NSString *)service;
- (void)useManualRecovery;
- (void)restore;
- (void)forget;
- (void)playerTerminated:(NSRunningApplication *)app;
@end
