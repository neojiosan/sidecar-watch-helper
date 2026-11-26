#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AWPlaybackState) {
    AWUnknown = 0,
    AWIdle,
    AWPlaying,
    AWPaused
};

// Feed both observations from the same monitoring pass, on the main queue.
// Disconnect and restore operate through WatchSession, which owns the exact iPad ID.
@interface AutoWatch : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                      disconnect:(void (^)(void))disconnect
                         restore:(void (^)(void))restore;
- (void)updateNetflix:(AWPlaybackState)netflix
              appleTV:(AWPlaybackState)tv
              pending:(BOOL)pending
            automatic:(BOOL)automatic
                 busy:(BOOL)busy
                   at:(NSTimeInterval)now;
- (void)userOverrodeSession;
@end
