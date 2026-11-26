// Build with WatchSession.m and AutoWatch.m, without the hardware backend or app entry point.
#import "WatchSession.h"
#import "SidecarDevice.h"
#import "AutoWatch.h"

// The test binary has no implementation capable of talking to the system's Sidecar service.
NSErrorDomain const SCDeviceErrorDomain = @"SidecarDevice";
@implementation SCDeviceController
- (NSArray *)connectedDevices:(NSError **)error { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (NSArray *)availableDevices:(NSError **)error { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (void)setConnected:(BOOL)connected deviceID:(NSString *)identifier completion:(void (^)(NSError *))reply {
    [self doesNotRecognizeSelector:_cmd];
}
@end

static NSError *mockError(void) {
    return [NSError errorWithDomain:@"SessionTest" code:1 userInfo:nil];
}

static SCDeviceRow *device(NSString *identifier) {
    // Both iPads have the same display name. Their identifiers distinguish them.
    return @{@"id":identifier, @"name":@"iPad"};
}

@interface SimulatedDevices : SCDeviceController
@property (strong) NSMutableArray<SCDeviceRow *> *online;
@property (strong) NSMutableArray<NSString *> *events;
@property BOOL failDisconnect;
@property BOOL timeout;
@property BOOL holdChange;
@property (copy) void (^finishChange)(void);
@end

@implementation SimulatedDevices
- (NSArray *)connectedDevices:(NSError **)error { return self.online.copy; }
- (NSArray *)availableDevices:(NSError **)error { return @[device(@"B"), device(@"A")]; }
- (void)setConnected:(BOOL)connected deviceID:(NSString *)identifier completion:(void (^)(NSError *))reply {
    [self.events addObject:[NSString stringWithFormat:@"%@:%@", connected ? @"on" : @"off", identifier]];
    void (^finish)(void) = ^{
        if (!connected && self.timeout) {
            reply([NSError errorWithDomain:SCDeviceErrorDomain code:SCDeviceErrorTransitionTimedOut userInfo:nil]);
            return;
        }
        if (!connected && self.failDisconnect) { reply(mockError()); return; }
        if (connected) [self.online addObject:device(identifier)];
        else [self.online removeObject:device(identifier)];
        reply(nil);
    };
    if (self.holdChange) self.finishChange = finish;
    else finish();
}
@end

// Preferences are serialized through a property list when simulating a new process.
// Even a failed test therefore leaves no data in the user's preferences domains.
@interface TestDefaults : NSUserDefaults
@property (strong) NSMutableDictionary *values;
@end
@implementation TestDefaults
- (instancetype)init {
    if ((self = [super initWithSuiteName:@"WatchSessionTests.InMemory"])) _values = [NSMutableDictionary dictionary];
    return self;
}
- (NSDictionary *)dictionaryForKey:(NSString *)key { return self.values[key]; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (NSInteger)integerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { self.values[key] = @(value); }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (BOOL)synchronize { return YES; }
@end

@interface SimulatedPlayer : NSObject
@property (getter=isTerminated) BOOL terminated;
@end
@implementation SimulatedPlayer
@end

@interface Fixture : NSObject
@property (strong) SimulatedDevices *devices;
@property (strong) SimulatedPlayer *player;
@property (strong) WatchSession *session;
@property (strong) TestDefaults *defaults;
@property (strong) AutoWatch *monitor;
@property BOOL failLaunch;
- (instancetype)initWithOnline:(NSArray *)online;
- (WatchSession *)sessionWithDefaults:(TestDefaults *)defaults;
- (void)resetMonitor;
- (void)observeNetflix:(AWPlaybackState)netflix tv:(AWPlaybackState)tv time:(NSTimeInterval)time;
@end

@implementation Fixture
- (instancetype)initWithOnline:(NSArray *)online {
    if ((self = [super init])) {
        _devices = [SimulatedDevices new];
        _devices.online = online.mutableCopy;
        _devices.events = [NSMutableArray array];
        _player = [SimulatedPlayer new];
        _defaults = [TestDefaults new];
        _session = [self sessionWithDefaults:_defaults];
        [self resetMonitor];
    }
    return self;
}
- (void)resetMonitor {
    __weak Fixture *weak = self;
    self.monitor = [[AutoWatch alloc] initWithDefaults:self.defaults disconnect:^{
        [weak.session start:@"automatic"];
    } restore:^{
        [weak.session restore];
    }];
}
- (void)observeNetflix:(AWPlaybackState)netflix tv:(AWPlaybackState)tv time:(NSTimeInterval)time {
    [self.monitor updateNetflix:netflix appleTV:tv pending:self.session.pending
                      automatic:self.session.automatic busy:self.session.busy at:time];
}
- (WatchSession *)sessionWithDefaults:(TestDefaults *)defaults {
    __weak Fixture *weakSelf = self;
    return [[WatchSession alloc] initWithDevices:self.devices defaults:defaults openPlayer:^(NSString *service, void (^reply)(NSRunningApplication *, NSError *)) {
        Fixture *fixture = weakSelf;
        [fixture.devices.events addObject:[@"open:" stringByAppendingString:service]];
        if (fixture.failLaunch) reply(nil, mockError());
        else reply((NSRunningApplication *)(id)fixture.player, nil);
    }];
}
@end

#define CHECK(...) do { if (!(__VA_ARGS__)) [NSException raise:@"TestFailure" format:@"line %d: %s", __LINE__, #__VA_ARGS__]; } while (0)

static void testNoSidecar(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[]];
    [f.session start:@"netflix"];
    [f.session restore];
    CHECK(!f.session.busy && !f.session.pending);
    CHECK([f.devices.events isEqual:@[@"open:netflix"]]);
}

static void testStartAndRestore(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    f.devices.holdChange = YES;
    [f.session start:@"netflix"];
    CHECK(f.session.busy && f.devices.finishChange);
    CHECK([f.devices.events isEqual:@[@"off:A"]]);
    f.devices.holdChange = NO;
    f.devices.finishChange();
    f.devices.finishChange = nil;
    CHECK(f.session.pending && !f.session.busy && !f.devices.online.count);
    [f.session restore];
    [f.session restore]; // Already restored. A repeated click must be harmless.
    CHECK([f.devices.events isEqual:@[@"off:A", @"open:netflix", @"on:A"]]);
    CHECK([f.devices.online isEqual:@[device(@"A")]] && !f.session.pending);
}

static void testDisconnectFailure(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    f.devices.failDisconnect = YES;
    [f.session start:@"netflix"];
    CHECK([f.devices.events isEqual:@[@"off:A"]]);
    CHECK([f.devices.online isEqual:@[device(@"A")]] && !f.session.busy && !f.session.pending);
}

static void testOtherDevice(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    [f.session start:@"only"];
    [f.devices.online addObject:device(@"B")];
    [f.session restore];
    CHECK([f.devices.events isEqual:@[@"off:A"]]);
    CHECK([f.devices.online isEqual:@[device(@"B")]] && f.session.pending && !f.session.busy);
}

static void testDelayedDisconnect(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    f.devices.timeout = YES;
    [f.session start:@"tv"];
    CHECK(f.session.pending && !f.session.busy);
    [f.devices.online removeAllObjects]; // Device finally disconnected after the deadline.
    [f.session restore];
    CHECK([f.devices.events isEqual:@[@"off:A", @"on:A"]] && !f.session.pending);
}

static void testRelaunch(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    [f.session start:@"only"];
    NSData *stored = [NSPropertyListSerialization dataWithPropertyList:f.defaults.values format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    CHECK(stored);
    f.session = nil;
    f.defaults = [TestDefaults new];
    f.defaults.values = [NSPropertyListSerialization propertyListWithData:stored options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL];
    f.session = [f sessionWithDefaults:f.defaults];
    CHECK(f.session.pending);
    [f.session restore];
    CHECK([f.devices.events isEqual:@[@"off:A", @"on:A"]]);
    CHECK([f.devices.online isEqual:@[device(@"A")]] && !f.session.pending);
}

static void testLaunchFailure(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    f.failLaunch = YES;
    [f.session start:@"tv"];
    CHECK([f.devices.events isEqual:@[@"off:A", @"open:tv", @"on:A"]]);
    CHECK([f.devices.online isEqual:@[device(@"A")]] && !f.session.pending && !f.session.busy);
}

static void testTVQuit(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    [f.session start:@"tv"];
    [f.session playerTerminated:(NSRunningApplication *)(id)[SimulatedPlayer new]];
    CHECK(f.session.pending && !f.devices.online.count);
    [f.session playerTerminated:(NSRunningApplication *)(id)f.player];
    CHECK([f.devices.events isEqual:@[@"off:A", @"open:tv", @"on:A"]]);
    CHECK(!f.session.pending);
}

static void testMonitorOpensBeforeDisconnect(void) {
    for (NSString *service in @[@"tv", @"netflix"]) {
        BOOL isTV = [service isEqualToString:@"tv"];
        Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
        [f.session openWithoutDisconnect:service];
        NSString *open = [@"open:" stringByAppendingString:service];
        [f observeNetflix:AWIdle tv:AWIdle time:1];
        CHECK([f.devices.events isEqual:@[open]]);
        CHECK(!f.session.pending && [f.devices.online isEqual:@[device(@"A")]]);

        [f observeNetflix:isTV ? AWIdle : AWPlaying tv:isTV ? AWPlaying : AWIdle time:2];
        CHECK(f.session.pending && f.session.automatic && !f.session.busy);
        CHECK([f.devices.events isEqual:@[open, @"off:A"]]);
        [f observeNetflix:isTV ? AWIdle : AWPaused tv:isTV ? AWPaused : AWIdle time:12];
        [f observeNetflix:AWIdle tv:AWIdle time:14];
        CHECK(f.session.pending && !f.player.terminated);
        [f observeNetflix:AWIdle tv:AWIdle time:19];
        CHECK([f.devices.events isEqual:@[open, @"off:A", @"on:A"]]);
        CHECK(!f.session.pending && !f.session.automatic && !f.player.terminated);
    }
}

static void testAutomaticRecordAfterRelaunch(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[device(@"A")]];
    [f observeNetflix:AWPlaying tv:AWUnknown time:1];
    CHECK(f.session.automatic);
    NSDictionary *record = f.defaults.values.copy;
    f.defaults = [TestDefaults new];
    [f.defaults.values addEntriesFromDictionary:record];
    f.session = [f sessionWithDefaults:f.defaults];
    [f resetMonitor];
    [f observeNetflix:AWPaused tv:AWUnknown time:8];
    CHECK(f.session.automatic && f.session.pending);
    [f observeNetflix:AWIdle tv:AWUnknown time:12];
    [f observeNetflix:AWIdle tv:AWUnknown time:17];
    CHECK(!f.session.pending && [f.devices.events isEqual:@[@"off:A", @"on:A"]]);
}

static void testLegacyRestoration(void) {
    Fixture *f = [[Fixture alloc] initWithOnline:@[]];
    // Version 1 persisted only id and name before there was an ownership marker.
    [f.defaults setObject:device(@"A") forKey:@"SidecarToRestore"];
    f.session = [f sessionWithDefaults:f.defaults];
    [f resetMonitor];
    CHECK(f.session.pending && !f.session.automatic);
    [f observeNetflix:AWPlaying tv:AWIdle time:0];
    [f observeNetflix:AWIdle tv:AWIdle time:1];
    [f observeNetflix:AWIdle tv:AWIdle time:10];
    CHECK(f.devices.events.count == 0 && f.session.pending);
    [f.session restore];
    CHECK(!f.session.pending && [f.devices.events isEqual:@[@"on:A"]]);
}

int main(void) {
    @autoreleasepool {
        struct { const char *name; void (*run)(void); } tests[] = {
            {"no Sidecar", testNoSidecar}, {"start and restore", testStartAndRestore},
            {"disconnect failure", testDisconnectFailure}, {"different iPad active", testOtherDevice},
            {"delayed disconnect", testDelayedDisconnect},
            {"relaunch", testRelaunch}, {"launch failure rollback", testLaunchFailure}, {"Apple TV quit", testTVQuit},
            {"open and exit player without quitting", testMonitorOpensBeforeDisconnect},
            {"automatic record across relaunch", testAutomaticRecordAfterRelaunch},
            {"restore legacy record manually", testLegacyRestoration},
        };
        int failures = 0;
        for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
            @try { tests[i].run(); fprintf(stdout, "PASS %s\n", tests[i].name); }
            @catch (NSException *exception) {
                fprintf(stderr, "FAIL %s: %s\n", tests[i].name, exception.reason.UTF8String);
                failures++;
            }
        }
        return failures ? 1 : 0;
    }
}
