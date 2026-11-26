// Link this executable with TVSignals.m and AutoWatch.m. All observations are
// synthetic, including the legacy TV scripting reply "stopped, zero video windows".
#import "TVSignals.h"
#import "AutoWatch.h"
#include <stdio.h>

#define REQUIRE(condition) do { if (!(condition)) [NSException raise:@"TestFailure" \
    format:@"%s, line %d: %s", __func__, __LINE__, #condition]; } while (0)

static NSArray<NSNumber *> *Library(void) { return @[@47]; }
static NSArray<NSNumber *> *Movie(void) { return @[@33301, @47]; }

static NSNumber *Sample(TVStreamTracker *tracker, NSTimeInterval now, BOOL assertion,
                        NSArray<NSNumber *> *windows) {
    return [tracker sampleAssertion:assertion readable:YES visibleWindows:windows appActive:YES at:now];
}

static AWPlaybackState WithStoppedScript(NSNumber *override) {
    return override ? (AWPlaybackState)override.integerValue : AWIdle;
}

static void ConfirmMovie(TVStreamTracker *tracker, NSTimeInterval start) {
    REQUIRE(WithStoppedScript(Sample(tracker, start, YES, Movie())) != AWPlaying);
    REQUIRE([Sample(tracker, start + 3, YES, Movie()) isEqual:@(AWPlaying)]);
}

static void MovieLifecycle(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    REQUIRE(Sample(tracker, 0, NO, Library()) == nil);
    ConfirmMovie(tracker, 1);
    REQUIRE([Sample(tracker, 5, NO, Movie()) isEqual:@(AWPaused)]);
    Sample(tracker, 6, YES, Movie());
    REQUIRE([Sample(tracker, 9, YES, Movie()) isEqual:@(AWPlaying)]);
    // CoreMedia can briefly retain the display assertion after the movie window closes.
    Sample(tracker, 10, YES, Library());
    REQUIRE(WithStoppedScript(Sample(tracker, 12, NO, Library())) == AWIdle);
    // Reusing the library window for a later preview must not revive the last film.
    Sample(tracker, 13, YES, Library());
    REQUIRE(WithStoppedScript(Sample(tracker, 16, YES, Library())) != AWPlaying);
}

static void StartDuringPlayback(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    ConfirmMovie(tracker, 0);
    REQUIRE([Sample(tracker, 4, NO, Movie()) isEqual:@(AWPaused)]);
    REQUIRE(WithStoppedScript(Sample(tracker, 5, NO, Library())) == AWIdle);
}

static void LibraryPreview(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    REQUIRE(Sample(tracker, 0, NO, Library()) == nil);
    REQUIRE(WithStoppedScript(Sample(tracker, 1, YES, Library())) != AWPlaying);
    REQUIRE(WithStoppedScript(Sample(tracker, 5, YES, Library())) != AWPlaying);
    REQUIRE(WithStoppedScript(Sample(tracker, 7, NO, Library())) == AWIdle);
    ConfirmMovie(tracker, 8);
}

static void LoadedFirstFrame(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    Sample(tracker, 0, NO, Library());
    REQUIRE(WithStoppedScript(Sample(tracker, 1, YES, Movie())) != AWPlaying);
    REQUIRE(WithStoppedScript(Sample(tracker, 3, YES, Movie())) != AWPlaying);
    REQUIRE(WithStoppedScript(Sample(tracker, 3.1, NO, Movie())) != AWPlaying);
    // Short assertions separated by a definite off sample cannot add up.
    ConfirmMovie(tracker, 5);
}

static void MissingWindowSnapshot(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    Sample(tracker, 0, NO, Library());
    ConfirmMovie(tracker, 1);
    // The legacy script reports stopped throughout streaming. Falling through
    // to it here would turn a read failure into a false exit.
    REQUIRE(WithStoppedScript(Sample(tracker, 5, NO, nil)) != AWIdle);
    REQUIRE(WithStoppedScript(Sample(tracker, 12, NO, nil)) != AWIdle);
    REQUIRE([Sample(tracker, 13, NO, Movie()) isEqual:@(AWPaused)]);
    REQUIRE(WithStoppedScript(Sample(tracker, 20, NO, Library())) == AWIdle);
}

static void MissingAssertionSnapshot(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    Sample(tracker, 0, NO, Library());
    ConfirmMovie(tracker, 1);
    NSNumber *unknown = [tracker sampleAssertion:NO readable:NO visibleWindows:Movie() appActive:YES at:5];
    REQUIRE(WithStoppedScript(unknown) != AWIdle);
    Sample(tracker, 6, YES, Movie());
    REQUIRE([Sample(tracker, 9, YES, Movie()) isEqual:@(AWPlaying)]);
}

// Keep the production coordinator's state in memory. Only the display-control
// callbacks are replaced. No real preferences, device, process or playback changes.
@interface StreamTestDefaults : NSUserDefaults
@property (strong) NSMutableDictionary *store;
@end
@implementation StreamTestDefaults
- (instancetype)init {
    if ((self = [super init])) _store = [NSMutableDictionary dictionary];
    return self;
}
- (NSInteger)integerForKey:(NSString *)key { return [self.store[key] integerValue]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { self.store[key] = @(value); }
- (id)objectForKey:(NSString *)key { return self.store[key]; }
- (void)removeObjectForKey:(NSString *)key { [self.store removeObjectForKey:key]; }
@end

static void DebouncedRestore(void) {
    TVStreamTracker *tracker = [TVStreamTracker new];
    __block NSUInteger disconnects = 0, restores = 0;
    __block BOOL pending = NO;
    AutoWatch *watch = [[AutoWatch alloc] initWithDefaults:[StreamTestDefaults new] disconnect:^{
        disconnects++;
        pending = YES;
    } restore:^{
        restores++;
        pending = NO;
    }];
    void (^observe)(NSTimeInterval, BOOL, NSArray<NSNumber *> *, AWPlaybackState) =
        ^(NSTimeInterval now, BOOL assertion, NSArray<NSNumber *> *windows, AWPlaybackState netflix) {
            AWPlaybackState tv = WithStoppedScript(Sample(tracker, now, assertion, windows));
            [watch updateNetflix:netflix appleTV:tv pending:pending automatic:pending busy:NO at:now];
        };
    observe(0, NO, Library(), AWIdle);
    observe(1, YES, Library(), AWIdle);
    REQUIRE(disconnects == 0);
    observe(2, YES, Movie(), AWIdle);
    observe(3.9, YES, Movie(), AWIdle);
    observe(4.1, NO, Movie(), AWIdle);
    REQUIRE(disconnects == 0);
    observe(5, YES, Movie(), AWIdle);
    observe(8, YES, Movie(), AWIdle);
    REQUIRE(disconnects == 1);
    observe(9, NO, Movie(), AWIdle);
    observe(20, NO, Movie(), AWIdle);
    observe(21, NO, nil, AWIdle);
    observe(30, NO, nil, AWIdle);
    REQUIRE(pending && disconnects == 1 && restores == 0);
    observe(31, YES, Movie(), AWIdle);
    observe(32, YES, Library(), AWIdle);
    observe(32.1, NO, Library(), AWIdle);
    observe(36.9, NO, Library(), AWIdle);
    REQUIRE(pending && restores == 0);
    observe(37.2, NO, Library(), AWIdle);
    REQUIRE(!pending && disconnects == 1 && restores == 1);
    // A second episode overlaps Netflix. Both participants must finish.
    observe(40, YES, Movie(), AWPlaying);
    observe(43, YES, Movie(), AWPlaying);
    observe(44, NO, Library(), AWPlaying);
    observe(47, NO, Library(), AWPaused);
    REQUIRE(pending && disconnects == 2 && restores == 1);
    observe(48, NO, Library(), AWIdle);
    observe(54, NO, Library(), AWIdle);
    REQUIRE(!pending && disconnects == 2 && restores == 2);
}

int main(void) {
    @autoreleasepool {
        struct { const char *name; void (*run)(void); } tests[] = {
            {"streaming, pause, resume, exit", MovieLifecycle}, {"start during playback", StartDuringPlayback},
            {"library preview", LibraryPreview}, {"single frame without play", LoadedFirstFrame}, {"unreadable windows", MissingWindowSnapshot},
            {"unreadable assertion", MissingAssertionSnapshot}, {"five-second exit and overlapping Netflix", DebouncedRestore}
        };
        int failures = 0;
        for (size_t i = 0; i < sizeof(tests)/sizeof(*tests); ++i) {
            @try {
                tests[i].run();
                printf("PASS %s\n", tests[i].name);
            } @catch (NSException *error) {
                fprintf(stderr, "FAIL %s: %s\n", tests[i].name, error.reason.UTF8String);
                failures++;
            }
        }
        return failures ? 1 : 0;
    }
}
