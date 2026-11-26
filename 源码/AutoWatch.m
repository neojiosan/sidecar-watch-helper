#import "AutoWatch.h"

typedef NS_OPTIONS(NSUInteger, AWSource) {
    AWNetflix = 1 << 0,
    AWAppleTV = 1 << 1,
};

static NSString *const AWParticipantsKey = @"AutoWatchPlaybackSources";
static const NSTimeInterval ExitDelay = 5.0;
// After three delayed retries, the pending iPad remains available for manual recovery.
static const NSTimeInterval RetryDelays[] = {15, 45, 120};

@implementation AutoWatch {
    NSUserDefaults *_defaults;
    void (^_disconnect)(void);
    void (^_restore)(void);
    AWSource _sources;
    NSTimeInterval _netflixIdleSince, _tvIdleSince;
    NSTimeInterval _nextRetry;
    NSUInteger _restoreAttempts;
    BOOL _initialized, _attemptedDisconnect, _restoreInFlight;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                      disconnect:(void (^)(void))disconnect
                         restore:(void (^)(void))restore {
    if ((self = [super init])) {
        _defaults = defaults;
        _disconnect = [disconnect copy];
        _restore = [restore copy];
        _netflixIdleSince = _tvIdleSince = -1;
    }
    return self;
}

- (void)rememberSources {
    if (_sources && [_defaults integerForKey:AWParticipantsKey] != (NSInteger)_sources)
        [_defaults setInteger:(NSInteger)_sources forKey:AWParticipantsKey];
}

// Only positive playback recruits a service. Once recruited, pause or a failed
// read keeps it in the session until repeated idle observations confirm exit.
- (void)observe:(AWPlaybackState)state source:(AWSource)source since:(NSTimeInterval *)idleSince
             at:(NSTimeInterval)now {
    if (state == AWPlaying) _sources |= source;
    if (state != AWIdle || !(_sources & source)) {
        *idleSince = -1;
        return;
    }
    if (*idleSince < 0) *idleSince = now;
    else if (now - *idleSince >= ExitDelay) {
        _sources &= ~source;
        *idleSince = -1;
    }
}

- (void)updateNetflix:(AWPlaybackState)netflix
              appleTV:(AWPlaybackState)tv
              pending:(BOOL)pending
            automatic:(BOOL)automatic
                 busy:(BOOL)busy
                   at:(NSTimeInterval)now {
    BOOL ownsRecord = pending && automatic;
    if (!_initialized) {
        _initialized = YES;
        if (ownsRecord) {
            AWSource both = AWNetflix | AWAppleTV;
            _sources = [_defaults integerForKey:AWParticipantsKey] & both;
            if (!_sources) _sources = both; // Missing source hint: require both to be idle.
            _attemptedDisconnect = YES;
        }
    }
    if (_restoreInFlight && !busy) {
        _restoreInFlight = NO;
        // Playback may have restarted while the previous episode was reconnecting.
        if (!pending) _attemptedDisconnect = NO;
    }

    [self observe:netflix source:AWNetflix since:&_netflixIdleSince at:now];
    [self observe:tv source:AWAppleTV since:&_tvIdleSince at:now];

    if (_sources) {
        _restoreAttempts = 0;
        _nextRetry = 0;
        if (pending) {
            if (ownsRecord) [self rememberSources];
            if (!_restoreInFlight) _attemptedDisconnect = YES;
        } else if (!busy && !_attemptedDisconnect && (netflix == AWPlaying || tv == AWPlaying)) {
            _attemptedDisconnect = YES;
            [self rememberSources];
            _disconnect();
        }
        return;
    }

    _attemptedDisconnect = NO;
    if (!ownsRecord) {
        _restoreAttempts = 0;
        _nextRetry = 0;
        if ([_defaults objectForKey:AWParticipantsKey]) [_defaults removeObjectForKey:AWParticipantsKey];
        return;
    }
    NSUInteger retries = sizeof(RetryDelays) / sizeof(*RetryDelays);
    if (busy || _restoreAttempts > retries || now < _nextRetry) return;
    if (_restoreAttempts < retries) _nextRetry = now + RetryDelays[_restoreAttempts];
    _restoreAttempts++;
    _restoreInFlight = YES;
    _restore();
}

- (void)userOverrodeSession {
    // A user's explicit reconnect/forget wins through pauses, background playback
    // and the exit grace period. The next actual viewing session can start afresh.
    if (_sources) _attemptedDisconnect = YES;
    _restoreInFlight = NO;
}
@end
