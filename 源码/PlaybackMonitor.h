#import <Foundation/Foundation.h>
#import "AutoWatch.h"

typedef void (^PlaybackSample)(AWPlaybackState netflix, AWPlaybackState tv,
                               NSString *netflixDetail, NSString *tvDetail);

@interface PlaybackMonitor : NSObject
- (instancetype)initWithHandler:(PlaybackSample)handler;
- (void)startWithBrowser:(NSString *)bundleID;
- (void)stop;
@end
