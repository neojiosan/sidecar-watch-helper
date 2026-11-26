#import "WatchSession.h"
#import "SidecarDevice.h"

static NSString *const SessionKey = @"SidecarToRestore";

@interface WatchSession ()
@property (strong) SCDeviceController *devices;
@property (strong) NSUserDefaults *defaults;
@property (copy) PlayerOpener openPlayer;
@property (readwrite) BOOL busy;
@property (readwrite, copy) NSString *status;
@property (strong) NSRunningApplication *player;
@end

@implementation WatchSession
- (instancetype)initWithDevices:(SCDeviceController *)devices defaults:(NSUserDefaults *)defaults openPlayer:(PlayerOpener)openPlayer {
    if ((self = [super init])) {
        _devices = devices;
        _defaults = defaults;
        _openPlayer = [openPlayer copy];
        NSDictionary *record = [self record];
        _status = record ? [NSString stringWithFormat:@"上次观影的设备是「%@」。看完后可以恢复随航。", record[@"name"]]
                         : @"可以直接在播放器里选片，也可以从这里打开播放器。";
    }
    return self;
}
- (NSDictionary *)record {
    NSDictionary *record = [self.defaults dictionaryForKey:SessionKey];
    for (NSString *key in @[@"id", @"name"]) {
        if (![record[key] isKindOfClass:NSString.class] || ![record[key] length]) return nil;
    }
    return record;
}
- (BOOL)pending { return self.record != nil; }
- (BOOL)automatic { return [self.record[@"auto"] boolValue]; }
- (void)useManualRecovery {
    if (!self.automatic || self.busy) return;
    NSMutableDictionary *record = self.record.mutableCopy;
    record[@"auto"] = @NO;
    [self.defaults setObject:record forKey:SessionKey];
    [self.defaults synchronize];
    [self show:@"自动切换已关闭，看完请点「恢复随航」。" busy:NO];
}
- (void)show:(NSString *)text busy:(BOOL)busy {
    self.busy = busy;
    self.status = text;
    if (self.onChange) self.onChange();
}
- (void)clearRecord {
    self.player = nil;
    [self.defaults removeObjectForKey:SessionKey];
    [self.defaults synchronize];
}
- (void)start:(NSString *)service {
    if (self.busy || self.pending) return;
    BOOL automatic = [service isEqualToString:@"automatic"];
    BOOL only = automatic || [service isEqualToString:@"only"];
    NSError *error = nil;
    NSArray *active = [self.devices connectedDevices:&error];
    if (!active) {
        [self show:error.localizedDescription ?: @"无法读取随航状态。请检查显示器设置。" busy:NO];
        return;
    }
    if (active.count > 1) {
        [self show:@"检测到多台随航设备。请先在显示器设置中选定要使用的 iPad。" busy:NO];
        return;
    }
    NSDictionary *target = active.firstObject;
    if (!target) {
        if (only) [self show:@"当前没有连接随航，可以直接在 Mac 上播放。" busy:NO];
        else [self launch:service];
        return;
    }
    [self.defaults setObject:@{@"id":target[@"id"], @"name":target[@"name"], @"auto":@(automatic)} forKey:SessionKey];
    if (![self.defaults synchronize]) {
        [self clearRecord];
        [self show:@"无法保存用于重连的 iPad 信息。请再试一次。" busy:NO];
        return;
    }
    [self show:[NSString stringWithFormat:@"正在断开「%@」的随航…", target[@"name"]] busy:YES];
    __weak WatchSession *weakSession = self;
    [self.devices setConnected:NO deviceID:target[@"id"] completion:^(NSError *disconnectError) {
        WatchSession *self = weakSession;
        if (!self) return;
        if (disconnectError) {
            NSArray *now = [self.devices connectedDevices:NULL];
            BOOL timedOut = [disconnectError.domain isEqualToString:SCDeviceErrorDomain] &&
                            disconnectError.code == SCDeviceErrorTransitionTimedOut;
            if (!timedOut && [[now valueForKey:@"id"] containsObject:target[@"id"]]) [self clearRecord];
            [self show:[NSString stringWithFormat:@"未能确认随航已断开。%@", disconnectError.localizedDescription] busy:NO];
        } else if (only) {
            [self show:automatic ? @"随航已断开。退出播放后会自动连回这台 iPad。"
                                 : @"随航已手动断开。看完后点「恢复随航」。" busy:NO];
        } else {
            [self launch:service];
        }
    }];
}
- (void)openWithoutDisconnect:(NSString *)service {
    if (self.busy || self.pending) return;
    NSString *name = [service isEqualToString:@"tv"] ? @"Apple TV" : @"Netflix";
    [self show:[NSString stringWithFormat:@"正在打开 %@…", name] busy:YES];
    self.openPlayer(service, ^(NSRunningApplication *app, NSError *error) {
        NSString *status = app && !error
            ? [NSString stringWithFormat:@"已打开 %@，开始播放后会自动切换随航。", name]
            : (error.localizedDescription ?: @"播放器未能打开。");
        [self show:status busy:NO];
    });
}
- (void)launch:(NSString *)service {
    BOOL tv = [service isEqualToString:@"tv"];
    [self show:tv ? @"正在打开 Apple TV…" : @"正在打开 Netflix…" busy:YES];
    self.openPlayer(service, ^(NSRunningApplication *app, NSError *error) {
        if (error || !app) {
            NSString *reason = [NSString stringWithFormat:@"播放器未能打开。%@", error.localizedDescription ?: @""];
            if (self.pending) [self restoreWithPrefix:reason];
            else [self show:reason busy:NO];
            return;
        }
        if (!self.pending) {
            [self show:@"播放器已打开。开始观影时没有连接随航。" busy:NO];
            return;
        }
        if (tv) {
            self.player = app;
            [self show:@"用 ⌘Q 退出 Apple TV 时会自动恢复随航，也可以点「恢复随航」。" busy:NO];
            if (app.terminated) [self playerTerminated:app];
        } else {
            [self show:@"看完 Netflix，点菜单栏的观影图标，选择「恢复随航」。" busy:NO];
        }
    });
}
- (void)playerTerminated:(NSRunningApplication *)app {
    if (self.player && [app isEqual:self.player] && self.pending && !self.busy) [self restore];
}
- (void)restore {
    if (self.busy || !self.pending) return;
    [self restoreWithPrefix:@""];
}
- (void)restoreWithPrefix:(NSString *)prefix {
    NSDictionary *record = self.record;
    self.player = nil;
    NSString *name = record[@"name"];
    NSString *identifier = record[@"id"];
    NSError *error = nil;
    NSArray *active = [self.devices connectedDevices:&error];
    if (!active) {
        [self show:[prefix stringByAppendingString:error.localizedDescription ?: @"无法读取随航状态，请重试。"] busy:NO];
        return;
    }
    NSString *done = [prefix stringByAppendingFormat:@"已恢复「%@」的随航。", name];
    if ([[active valueForKey:@"id"] containsObject:identifier]) {
        [self clearRecord];
        [self show:done busy:NO];
        return;
    }
    if (active.count > 0) {
        [self show:[prefix stringByAppendingFormat:@"当前已连接另一台 iPad。请在显示器设置中确认后，再恢复「%@」。", name] busy:NO];
        return;
    }
    [self show:[prefix stringByAppendingFormat:@"正在恢复「%@」的随航…", name] busy:YES];
    __weak WatchSession *weakSession = self;
    [self.devices setConnected:YES deviceID:identifier completion:^(NSError *connectError) {
        WatchSession *self = weakSession;
        if (!self) return;
        if (connectError) {
            [self show:[prefix stringByAppendingFormat:@"未能恢复「%@」。%@ 可以稍后重试。", name, connectError.localizedDescription] busy:NO];
        } else {
            [self clearRecord];
            [self show:done busy:NO];
        }
    }];
}
- (void)forget {
    if (self.busy || !self.pending) return;
    [self clearRecord];
    [self show:@"已清除这次重连记录。" busy:NO];
}
@end
