// Build with AutoWatch.m and Foundation. These tests do not access any device or browser.
#import "AutoWatch.h"
#import <stdio.h>

@interface MemoryPreferences : NSUserDefaults
@property (strong) NSMutableDictionary *values;
@end
@implementation MemoryPreferences
- (instancetype)init {
    if ((self = [super init])) _values = [NSMutableDictionary dictionary];
    return self;
}
- (NSInteger)integerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { self.values[key] = @(value); }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
@end

@interface WatchFixture : NSObject
@property (strong) MemoryPreferences *defaults;
@property (strong) AutoWatch *watch;
@property NSUInteger disconnects, restores;
@property BOOL connected, pending, automatic, busy, failRestore;
- (void)relaunch;
- (void)play:(AWPlaybackState)netflix tv:(AWPlaybackState)tv at:(NSTimeInterval)now;
@end

@implementation WatchFixture
- (instancetype)init {
    if ((self = [super init])) {
        _defaults = [MemoryPreferences new];
        _connected = YES;
        [self relaunch];
    }
    return self;
}
- (void)relaunch {
    __weak WatchFixture *weak = self;
    self.watch = [[AutoWatch alloc] initWithDefaults:self.defaults disconnect:^{
        WatchFixture *f = weak;
        f.disconnects++;
        if (f.connected) {
            f.connected = NO;
            f.pending = f.automatic = YES;
        }
    } restore:^{
        WatchFixture *f = weak;
        f.restores++;
        if (!f.failRestore) {
            f.connected = YES;
            f.pending = f.automatic = NO;
        }
    }];
}
- (void)play:(AWPlaybackState)n tv:(AWPlaybackState)t at:(NSTimeInterval)now {
    [self.watch updateNetflix:n appleTV:t pending:self.pending automatic:self.automatic busy:self.busy at:now];
}
@end

#define ASSERT(x) do { if (!(x)) [NSException raise:@"Assertion" format:@"line %i %s", __LINE__, #x]; } while (0)

static void idleAndPaused(void) {
    WatchFixture *f = [WatchFixture new];
    [f play:AWIdle tv:AWUnknown at:0];
    [f play:AWPaused tv:AWPaused at:10];
    ASSERT(!f.disconnects && !f.restores && f.connected);
}

static void combinedPlayback(void) {
    WatchFixture *f = [WatchFixture new];
    [f play:AWPlaying tv:AWIdle at:0];
    [f play:AWPaused tv:AWPlaying at:2];
    [f play:AWIdle tv:AWPaused at:5];
    [f play:AWIdle tv:AWPaused at:11];
    [f play:AWUnknown tv:AWIdle at:12];
    [f play:AWUnknown tv:AWPlaying at:14];
    [f play:AWUnknown tv:AWIdle at:17];
    [f play:AWUnknown tv:AWIdle at:21];
    ASSERT(f.disconnects == 1 && f.restores == 0);
    [f play:AWUnknown tv:AWIdle at:22];
    ASSERT(f.restores == 1 && f.connected);
}

static void outage(void) {
    WatchFixture *f = [WatchFixture new];
    [f play:AWUnknown tv:AWPlaying at:0];
    [f play:AWUnknown tv:AWIdle at:2];
    [f play:AWUnknown tv:AWUnknown at:6];
    [f play:AWUnknown tv:AWUnknown at:200];
    ASSERT(f.restores == 0);
    [f play:AWUnknown tv:AWIdle at:201];
    [f play:AWUnknown tv:AWIdle at:206];
    ASSERT(f.restores == 1);
}

static void initiallyDisconnected(void) {
    WatchFixture *f = [WatchFixture new];
    f.connected = NO;
    [f play:AWPlaying tv:AWIdle at:1];
    [f play:AWPlaying tv:AWIdle at:7];
    [f play:AWIdle tv:AWIdle at:8];
    [f play:AWIdle tv:AWIdle at:15];
    ASSERT(!f.connected && !f.pending && f.disconnects == 1 && !f.restores);
}

static void manualOverride(void) {
    WatchFixture *f = [WatchFixture new];
    [f play:AWIdle tv:AWPlaying at:1];
    [f.watch userOverrodeSession];
    f.pending = f.automatic = NO;
    f.connected = YES;
    [f play:AWIdle tv:AWPaused at:2];
    [f play:AWIdle tv:AWPlaying at:8];
    ASSERT(f.disconnects == 1 && !f.restores);
    [f play:AWIdle tv:AWIdle at:9];
    [f play:AWIdle tv:AWIdle at:14];
    [f play:AWPlaying tv:AWIdle at:15];
    ASSERT(f.disconnects == 2 && f.pending);
}

static void preserveManualRecord(void) {
    WatchFixture *f = [WatchFixture new];
    f.pending = YES; f.automatic = f.connected = NO;
    [f play:AWPlaying tv:AWIdle at:1];
    [f play:AWIdle tv:AWIdle at:2];
    [f play:AWIdle tv:AWIdle at:7];
    ASSERT(f.pending && !f.disconnects && !f.restores);
}

static void recoverOnRelaunch(void) {
    WatchFixture *f = [WatchFixture new];
    [f play:AWPlaying tv:AWIdle at:5];
    [f relaunch];
    [f play:AWUnknown tv:AWIdle at:6];
    [f play:AWPaused tv:AWIdle at:60];
    [f play:AWIdle tv:AWUnknown at:61];
    [f play:AWIdle tv:AWUnknown at:66];
    ASSERT(f.disconnects == 1 && f.restores == 1 && f.connected);
}

static void boundedRetry(void) {
    WatchFixture *f = [WatchFixture new];
    f.failRestore = YES;
    [f play:AWPlaying tv:AWIdle at:1];
    [f play:AWIdle tv:AWIdle at:2];
    [f play:AWIdle tv:AWIdle at:7];
    [f play:AWIdle tv:AWIdle at:21];
    ASSERT(f.restores == 1 && f.pending);
    [f play:AWIdle tv:AWIdle at:22];
    [f play:AWIdle tv:AWIdle at:67];
    [f play:AWIdle tv:AWIdle at:187];
    [f play:AWIdle tv:AWIdle at:10000];
    ASSERT(f.restores == 4 && f.pending);
}

static void resumeWhileRecovering(void) {
    WatchFixture *f = [WatchFixture new];
    [f play:AWPlaying tv:AWIdle at:1];
    [f play:AWIdle tv:AWIdle at:2];
    [f play:AWIdle tv:AWIdle at:7];
    // Keep the previous connection change in flight while the next film starts.
    f.pending = f.automatic = f.busy = YES;
    [f play:AWIdle tv:AWPlaying at:8];
    f.pending = f.automatic = f.busy = NO;
    [f play:AWIdle tv:AWPlaying at:10];
    ASSERT(f.disconnects == 2 && f.restores == 1 && f.pending);
}

int main(void) {
    @autoreleasepool {
        struct { const char *name; void (*run)(void); } tests[] = {
            {"idle and pause without playback", idleAndPaused}, {"overlapping services and debounce", combinedPlayback},
            {"known and unknown sources", outage}, {"no original iPad", initiallyDisconnected},
            {"manual override", manualOverride}, {"manual recovery ownership", preserveManualRecord},
            {"automatic recovery after relaunch", recoverOnRelaunch}, {"bounded recovery retries", boundedRetry},
            {"new film during restore", resumeWhileRecovering}
        };
        for (size_t i = 0; i < sizeof(tests) / sizeof(*tests); i++) {
            @try { tests[i].run(); printf("PASS %s\n", tests[i].name); }
            @catch (NSException *exception) {
                fprintf(stderr, "FAIL %s: %s\n", tests[i].name, exception.reason.UTF8String);
                return 1;
            }
        }
    }
    return 0;
}
