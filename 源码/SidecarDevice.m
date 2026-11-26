#import "SidecarDevice.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// SidecarCore is part of macOS. Its interfaces are private and may change.
// Check the methods before sending messages and accept only iPad hardware IDs.
@protocol SCDisplayManagerAPI <NSObject>
+ (instancetype)sharedManager;
- (NSArray *)connectedDevices;
- (NSArray *)devices;
- (void)connectToDevice:(id)device completion:(void (^)(NSError *))reply;
- (void)disconnectFromDevice:(id)device completion:(void (^)(NSError *))reply;
@end

@protocol SCHardwareAPI <NSObject>
- (id)model;
- (id)identifier;
- (id)name;
@end

NSErrorDomain const SCDeviceErrorDomain = @"SidecarDevice";

static NSError *SCError(NSString *message) {
    return [NSError errorWithDomain:SCDeviceErrorDomain code:SCDeviceErrorUnavailable
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id SCFail(NSError **error, NSString *message) {
    if (error) *error = SCError(message);
    return nil;
}

static BOOL SCIsGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char result[16] = {};
    method_getReturnType(method, result, sizeof(result));
    return result[0] == '@';
}

static BOOL SCIsChangeMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    char result[16] = {}, device[16] = {}, block[16] = {};
    method_getReturnType(method, result, sizeof(result));
    method_getArgumentType(method, 2, device, sizeof(device));
    method_getArgumentType(method, 3, block, sizeof(block));
    return result[0] == 'v' && device[0] == '@' && strcmp(block, "@?") == 0;
}

@interface SCDeviceController ()
@property (strong) id<SCDisplayManagerAPI> manager;
@property (assign) BOOL changing;
@end

@implementation SCDeviceController
- (instancetype)init {
    if ((self = [super init])) {
        static void *framework;
        static dispatch_once_t load;
        dispatch_once(&load, ^{
            framework = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",
                               RTLD_LAZY | RTLD_LOCAL);
        });
        if (!framework) return self;
        Class<SCDisplayManagerAPI> cls = (Class)NSClassFromString(@"SidecarDisplayManager");
        if (!SCIsGetter(class_getClassMethod(cls, @selector(sharedManager))) ||
            !SCIsGetter(class_getInstanceMethod(cls, @selector(devices))) ||
            !SCIsGetter(class_getInstanceMethod(cls, @selector(connectedDevices))) ||
            !SCIsChangeMethod(class_getInstanceMethod(cls, @selector(connectToDevice:completion:))) ||
            !SCIsChangeMethod(class_getInstanceMethod(cls, @selector(disconnectFromDevice:completion:))))
            return self;
        _manager = [cls sharedManager];
    }
    return self;
}

// Map stable IDs to native device objects. If a getter fails, propagate the unknown
// state. In particular, a failed query must never be interpreted as a disconnection.
- (NSDictionary<NSString *, id<SCHardwareAPI>> *)deviceMap:(BOOL)connected
                                                    error:(NSError **)error {
    if (!self.manager)
        return SCFail(error, @"当前 macOS 的随航接口不兼容。请在系统的“屏幕镜像”菜单中切换 iPad。");
    id list = connected ? self.manager.connectedDevices : self.manager.devices;
    if (![list isKindOfClass:NSArray.class])
        return SCFail(error, @"系统未返回随航设备状态，请稍后重试。");
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id<SCHardwareAPI> device in list) {
        Class cls = object_getClass(device);
        if (!SCIsGetter(class_getInstanceMethod(cls, @selector(model))))
            return SCFail(error, @"无法确认随航设备的型号。");
        id model = device.model;
        if (![model isKindOfClass:NSString.class] || ![model length])
            return SCFail(error, @"系统尚未提供随航设备型号，请稍后重试。");
        if (![model hasPrefix:@"iPad"]) continue;
        if (!SCIsGetter(class_getInstanceMethod(cls, @selector(identifier))) ||
            !SCIsGetter(class_getInstanceMethod(cls, @selector(name))))
            return SCFail(error, @"无法读取此 iPad 的标识。");
        id ident = device.identifier;
        NSString *key = [ident isKindOfClass:NSUUID.class] ? [ident UUIDString] : ident;
        if (![key isKindOfClass:NSString.class] || key.length == 0 || result[key])
            return SCFail(error, @"无法唯一识别此 iPad，请在系统的“屏幕镜像”菜单中查看。");
        result[key] = device;
    }
    return result;
}

- (NSArray<SCDeviceRow *> *)rowsForConnected:(BOOL)connected error:(NSError **)error {
    NSDictionary *map = [self deviceMap:connected error:error];
    if (!map) return nil;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:map.count];
    for (NSString *key in [map.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id<SCHardwareAPI> device = map[key];
        id name = device.name;
        NSString *label = [name isKindOfClass:NSString.class] && [name length] ? name : @"iPad";
        [rows addObject:@{@"id": key, @"name": label}];
    }
    return rows;
}

- (NSArray<SCDeviceRow *> *)connectedDevices:(NSError **)error {
    return [self rowsForConnected:YES error:error];
}

- (NSArray<SCDeviceRow *> *)availableDevices:(NSError **)error {
    return [self rowsForConnected:NO error:error];
}

- (void)setConnected:(BOOL)connected deviceID:(NSString *)deviceID
          completion:(void (^)(NSError *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.changing) {
            completion(SCError(@"正在切换随航，请稍后再试。"));
            return;
        }
        if (!deviceID.length) {
            completion(SCError(@"缺少要切换的 iPad 标识。"));
            return;
        }
        NSError *error = nil;
        NSDictionary *active = [self deviceMap:YES error:&error];
        if (!active) { completion(error); return; }
        id target = active[deviceID];
        if ((target != nil) == connected) { completion(nil); return; }
        if (connected) {
            // Never displace a newer session that the user started separately,
            // even if the other destination is a non-iPad Sidecar device.
            id sessions = self.manager.connectedDevices;
            if (![sessions isKindOfClass:NSArray.class] || [sessions count] != 0) {
                completion(SCError(@"系统还有其他随航连接，暂未恢复这台 iPad。"));
                return;
            }
            NSDictionary *nearby = [self deviceMap:NO error:&error];
            if (!nearby) { completion(error); return; }
            target = nearby[deviceID];
            if (!target) {
                completion(SCError(@"系统暂时找不到原来的 iPad。请确认 iPad 在附近并已解锁，再试一次。"));
                return;
            }
        }
        self.changing = YES;
        __block BOOL finished = NO;
        __block NSTimer *timer = nil;
        __block NSError *replyError = nil;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 25;
        void (^verify)(void) = ^{
            if (finished) return;
            NSError *readError = nil;
            NSDictionary *current = [self deviceMap:YES error:&readError];
            BOOL reached = current && ((current[deviceID] != nil) == connected);
            if (!reached && !replyError && NSProcessInfo.processInfo.systemUptime < deadline) return;
            finished = YES;
            [timer invalidate];
            timer = nil;
            self.changing = NO;
            NSError *failure = replyError;
            if (!reached && !failure) {
                NSMutableDictionary *detail = [@{NSLocalizedDescriptionKey: @"系统未能在 25 秒内确认随航状态，请稍后重试。"} mutableCopy];
                if (readError) detail[NSUnderlyingErrorKey] = readError;
                failure = [NSError errorWithDomain:SCDeviceErrorDomain code:SCDeviceErrorTransitionTimedOut userInfo:detail];
            }
            completion(reached ? nil : failure);
        };
        timer = [NSTimer timerWithTimeInterval:0.4 repeats:YES block:^(NSTimer * __unused tick) { verify(); }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        void (^reply)(NSError *) = ^(NSError *problem) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (finished) return;
                replyError = problem;
                verify();
            });
        };
        if (connected) [self.manager connectToDevice:target completion:reply];
        else [self.manager disconnectFromDevice:target completion:reply];
    });
}
@end
