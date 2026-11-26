#import "PlaybackMonitor.h"
#import "NetflixPlayback.h"
#import "TVPlayback.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// A first-time privacy prompt belongs to the signed helper, not a subprocess.
// Polling itself stays noninteractive. A user changing an existing grant takes
// effect on the next poll because the detectors still send a fresh read event.
static void RequestAccessIfNeeded(NSString *bundleID, NSMutableSet<NSString *> *requested) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].firstObject;
    if (!app || app.terminated || [requested containsObject:bundleID]) return;
    NSAppleEventDescriptor *address = [NSAppleEventDescriptor descriptorWithProcessIdentifier:app.processIdentifier];
    OSStatus state = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, false);
    if (state == errAEEventWouldRequireUserConsent)
        state = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, true);
    if (state == noErr || state == errAEEventNotPermitted) [requested addObject:bundleID];
}

// Each target gets its own serial queue. A browser permission dialog must not
// block TV sampling, and an unanswered request must not accumulate more requests.
@interface PlaybackMonitor () {
    dispatch_queue_t _browserQueue, _tvQueue;
    BOOL _browserBusy, _tvBusy;
    NSUInteger _generation;
    AWPlaybackState _netflix, _tv;
    NSTimeInterval _browserRead, _tvRead;
    NSMutableSet<NSString *> *_browserAccess;
}
@property (copy) PlaybackSample handler;
@property (copy) NSString *browserID, *netflixDetail, *tvDetail;
@property (strong) NetflixPlayback *web;
@property (strong) TVPlayback *television;
@property (strong) NSTimer *timer;
@end

@implementation PlaybackMonitor
- (instancetype)initWithHandler:(PlaybackSample)handler {
    if ((self = [super init])) {
        _handler = [handler copy];
        _browserAccess = [NSMutableSet set];
        _browserQueue = dispatch_queue_create("local.neo.watch.netflix", DISPATCH_QUEUE_SERIAL);
        _tvQueue = dispatch_queue_create("local.neo.watch.tv", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)stop {
    _generation++;
    [self.timer invalidate];
    self.timer = nil;
    self.browserID = nil;
}
- (void)startWithBrowser:(NSString *)bundleID {
    [self stop];
    self.browserID = bundleID;
    self.web = [NetflixPlayback new];
    self.television = [TVPlayback new];
    _netflix = _tv = AWUnknown;
    _browserRead = _tvRead = 0;
    self.netflixDetail = self.tvDetail = nil;
    __weak PlaybackMonitor *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *tick) { [weakSelf poll]; }];
    self.timer.tolerance = 0.2;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self poll];
}
- (void)emit {
    if (!self.browserID) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // If an event is stuck, its last known idle state is no longer evidence of an exit.
    self.handler(now - _browserRead > 5 ? AWUnknown : _netflix,
                 now - _tvRead > 5 ? AWUnknown : _tv, self.netflixDetail, self.tvDetail);
}
- (void)poll {
    [self emit];
    NSUInteger generation = _generation;
    if (!_browserBusy) {
        _browserBusy = YES;
        NSString *browserID = self.browserID;
        NetflixPlayback *detector = self.web;
        dispatch_async(_browserQueue, ^{
            RequestAccessIfNeeded(browserID, self->_browserAccess);
            NSString *detail = nil;
            AWPlaybackState state = [detector stateForBrowser:browserID detail:&detail];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_browserBusy = NO;
                if (generation != self->_generation) return;
                self->_netflix = state;
                self->_browserRead = NSProcessInfo.processInfo.systemUptime;
                self.netflixDetail = detail;
                [self emit];
            });
        });
    }
    if (!_tvBusy) {
        _tvBusy = YES;
        TVPlayback *detector = self.television;
        dispatch_async(_tvQueue, ^{
            // TV streaming can be observed without Apple Events permission.
            NSString *detail = nil;
            AWPlaybackState state = [detector stateWithDetail:&detail];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_tvBusy = NO;
                if (generation != self->_generation) return;
                self->_tv = state;
                self->_tvRead = NSProcessInfo.processInfo.systemUptime;
                self.tvDetail = detail;
                [self emit];
            });
        });
    }
}
@end
