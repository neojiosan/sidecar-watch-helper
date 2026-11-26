#import "AutoWatch.h"

// Query an existing TV process. Call from a serial background queue.
@interface TVPlayback : NSObject
- (AWPlaybackState)stateWithDetail:(NSString * _Nullable * _Nullable)detail;
@end
