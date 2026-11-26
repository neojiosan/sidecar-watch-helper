#import <Foundation/Foundation.h>
#import "AutoWatch.h"

// Reports the CoreMedia display assertion held by this TV PID. On an unreadable
// snapshot, returns NO. A successful snapshot without the assertion sets active=NO.
BOOL TVReadPlaybackAssertion(pid_t pid, BOOL *active);

// Visible window numbers for this process only. No window titles or pixels.
NSArray<NSNumber *> *TVVisibleWindows(pid_t pid);

@interface TVStreamTracker : NSObject
// nil delegates to TV's scripting dictionary (for example, library media).
- (NSNumber *)sampleAssertion:(BOOL)active readable:(BOOL)readable
               visibleWindows:(NSArray<NSNumber *> *)windows appActive:(BOOL)appActive at:(NSTimeInterval)now;
@end
