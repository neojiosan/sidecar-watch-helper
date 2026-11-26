#import "NetflixPlayback.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// These event codes come from Safari.sdef and Chrome's scripting.sdef.
typedef NSAppleEventDescriptor AEValue;
static AEValue *Specifier(OSType type, AEValue *container, OSType form, AEValue *key) {
    AEValue *record = [AEValue recordDescriptor];
    [record setDescriptor:[AEValue descriptorWithTypeCode:type] forKeyword:keyAEDesiredClass];
    [record setDescriptor:container forKeyword:keyAEContainer];
    [record setDescriptor:[AEValue descriptorWithEnumCode:form] forKeyword:keyAEKeyForm];
    [record setDescriptor:key forKeyword:keyAEKeyData];
    return [record coerceToDescriptorType:typeObjectSpecifier];
}

static AEValue *Comparison(AEValue *property, OSType comparison, NSString *text) {
    AEValue *record = [AEValue recordDescriptor];
    [record setDescriptor:[AEValue descriptorWithEnumCode:comparison] forKeyword:keyAECompOperator];
    [record setDescriptor:property forKeyword:keyAEObject1];
    [record setDescriptor:[AEValue descriptorWithString:text] forKeyword:keyAEObject2];
    return [record coerceToDescriptorType:typeCompDescriptor];
}

static AEValue *Combined(OSType operation, AEValue *left, AEValue *right) {
    AEValue *terms = [AEValue listDescriptor];
    [terms insertDescriptor:left atIndex:1];
    [terms insertDescriptor:right atIndex:2];
    AEValue *record = [AEValue recordDescriptor];
    [record setDescriptor:[AEValue descriptorWithEnumCode:operation] forKeyword:keyAELogicalOperator];
    [record setDescriptor:terms forKeyword:keyAELogicalTerms];
    return [record coerceToDescriptorType:typeLogicalDescriptor];
}

static AEValue *NetflixTabs(BOOL safari) {
    OSType all = kAEAll;
    AEValue *ordinal = [AEValue descriptorWithDescriptorType:typeAbsoluteOrdinal bytes:&all length:sizeof(all)];
    AEValue *windows = Specifier('cwin', [AEValue nullDescriptor], formAbsolutePosition, ordinal);
    AEValue *examined = [AEValue descriptorWithDescriptorType:typeObjectBeingExamined bytes:NULL length:0];
    AEValue *url = Specifier(typeProperty, examined, formPropertyID, [AEValue descriptorWithTypeCode:safari ? 'pURL' : 'URL ']);
    // Filter inside the browser. Only matching tab handles cross the process boundary.
    AEValue *hosts = Combined(kAEOR, Comparison(url, kAEBeginsWith, @"https://www.netflix.com/"),
                              Comparison(url, kAEBeginsWith, @"https://netflix.com/"));
    AEValue *watch = Combined(kAEAND, hosts, Comparison(url, kAEContains, @"/watch/"));
    return Specifier(safari ? 'bTab' : 'CrTb', windows, formTest, watch);
}

static BOOL CollectTabs(AEValue *value, NSMutableArray<AEValue *> *output) {
    if (value.descriptorType == typeObjectSpecifier) {
        [output addObject:value];
        return YES;
    }
    if (value.descriptorType != typeAEList) return NO;
    for (NSInteger i = 1; i <= value.numberOfItems; i++)
        if (!CollectTabs([value descriptorAtIndex:i], output)) return NO;
    return YES;
}

// Safari tab references may be indexed, so check the origin and film path again in
// the page before accessing any media element. Return a word, never page content.
static NSString *const PageProbe =
    @"(() => {"
    " if (location.protocol !== 'https:' || !['www.netflix.com','netflix.com'].includes(location.hostname) ||"
    "     !/^\\/(?:[a-z]{2,3}(?:-[a-z0-9]+)*\\/)?watch\\/\\d+(?:\\/|$)/i.test(location.pathname)) return 'idle';"
    " const videos = Array.from(document.querySelectorAll('video')).filter(v => !v.ended && !v.error);"
    " if (videos.some(v => !v.paused && (v.readyState >= 2 || v.played.length > 0))) return 'playing';"
    " if (videos.some(v => v.played.length > 0)) return 'paused';"
    " return 'idle';"
    "})()";

static AEValue *Event(AEValue *process, OSType eventClass, OSType eventID) {
    return [AEValue appleEventWithEventClass:eventClass eventID:eventID targetDescriptor:process
                                     returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
}

static AEValue *ReadReply(AEValue *event, NSInteger *code) {
    NSError *error = nil;
    AEValue *reply = [event sendEventWithOptions:NSAppleEventSendWaitForReply | NSAppleEventSendNeverInteract
                                         timeout:2.0 error:&error];
    NSInteger status = [reply paramDescriptorForKeyword:keyErrorNumber].int32Value;
    *code = status ?: error.code;
    return status || error ? nil : [reply paramDescriptorForKeyword:keyDirectObject];
}

static NSString *Problem(BOOL safari, NSInteger code, BOOL page) {
    NSString *name = safari ? @"Safari" : @"Google Chrome";
    if (code == errAEEventNotPermitted || code == errAEEventWouldRequireUserConsent || code == procNotFound)
        return [NSString stringWithFormat:@"请在「系统设置 → 隐私与安全性 → 自动化」中允许随航观影助手访问 %@。", name];
    if (code == errAETimeout || code == errAENoSuchObject)
        return [NSString stringWithFormat:@"%@ 正在切换标签或暂时无响应。", name];
    if (page) return safari ?
        @"请在 Safari 设置的「高级」中显示网页开发者功能，再在「开发者」中启用「允许来自 Apple 事件的 JavaScript」。" :
        @"请在 Chrome 菜单「显示 → 开发者」中勾选「允许来自 Apple 事件的 JavaScript」。";
    return [NSString stringWithFormat:@"暂时无法读取 %@ 的播放状态（%ld）。", name, (long)code];
}

static AWPlaybackState StateForProcess(NSRunningApplication *app, BOOL safari, NSString **detail) {
    AEValue *pid = [AEValue descriptorWithProcessIdentifier:app.processIdentifier];
    AEValue *get = Event(pid, kAECoreSuite, kAEGetData);
    [get setParamDescriptor:NetflixTabs(safari) forKeyword:keyDirectObject];
    NSInteger error = 0;
    AEValue *reply = ReadReply(get, &error);
    NSMutableArray<AEValue *> *tabs = [NSMutableArray array];
    if (!reply || !CollectTabs(reply, tabs)) {
        if (app.terminated) return AWIdle;
        if (detail) *detail = Problem(safari, error, NO);
        return AWUnknown;
    }
    AWPlaybackState result = AWIdle;
    for (AEValue *tab in tabs) {
        AEValue *probe = Event(pid, safari ? 'sfri' : 'CrSu', safari ? 'dojs' : 'ExJa');
        [probe setParamDescriptor:tab forKeyword:safari ? 'dcnm' : keyDirectObject];
        [probe setParamDescriptor:[AEValue descriptorWithString:PageProbe] forKeyword:safari ? keyDirectObject : 'JvSc'];
        NSString *media = ReadReply(probe, &error).stringValue;
        if ([media isEqualToString:@"playing"]) return AWPlaying;
        if ([media isEqualToString:@"paused"]) {
            if (result != AWUnknown) result = AWPaused;
        } else if (![media isEqualToString:@"idle"]) {
            if (app.terminated) return AWIdle;
            if (detail) *detail = Problem(safari, error, YES);
            // If the browser rejects scripts, all of its tabs have the same setting.
            if (error && error != errAENoSuchObject) return AWUnknown;
            result = AWUnknown;
        }
    }
    return result;
}

@implementation NetflixPlayback
- (AWPlaybackState)stateForBrowser:(NSString *)bundleID detail:(NSString **)detail {
    if (detail) *detail = nil;
    BOOL safari = [bundleID isEqualToString:@"com.apple.Safari"];
    if (!safari && ![bundleID isEqualToString:@"com.google.Chrome"]) {
        if (detail) *detail = @"请选择 Google Chrome 或 Safari。";
        return AWUnknown;
    }
    AWPlaybackState state = AWIdle;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
        if (app.terminated) continue;
        AWPlaybackState sample = StateForProcess(app, safari, detail);
        if (sample == AWPlaying) return sample;
        if (sample == AWUnknown || (sample == AWPaused && state == AWIdle)) state = sample;
    }
    return state;
}
@end
