#import "AutoWatch.h"

// Query on a serial background queue. A closed browser is never launched.
@interface NetflixPlayback : NSObject
- (AWPlaybackState)stateForBrowser:(NSString *)bundleID detail:(NSString **)detail;
@end
