#import "TVPlayback.h"
#import "TVSignals.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/CoreAudio.h>

static NSAppleEventDescriptor *PlayerStateProperty(void) {
    NSAppleEventDescriptor *spec = NSAppleEventDescriptor.recordDescriptor;
    [spec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:cProperty] forKeyword:keyAEDesiredClass];
    [spec setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:formPropertyID] forKeyword:keyAEKeyForm];
    [spec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'pPlS'] forKeyword:keyAEKeyData];
    [spec setDescriptor:NSAppleEventDescriptor.nullDescriptor forKeyword:keyAEContainer];
    return [spec coerceToDescriptorType:typeObjectSpecifier];
}

// Read only 'player state' or 'count video windows' as declared in TV's scripting dictionary.
// Addressing the running PID avoids launching TV in the race between lookup and delivery.
static NSAppleEventDescriptor *ReadTV(NSAppleEventDescriptor *address, AEEventID verb, NSError **error) {
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kAECoreSuite
        eventID:verb targetDescriptor:address returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (verb == kAEGetData) {
        [event setParamDescriptor:PlayerStateProperty() forKeyword:keyDirectObject];
    } else {
        [event setParamDescriptor:NSAppleEventDescriptor.nullDescriptor forKeyword:keyDirectObject];
        [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'cNPW'] forKeyword:keyAEObjectClass];
    }
    NSAppleEventDescriptor *reply = [event sendEventWithOptions:NSAppleEventSendWaitForReply |
        NSAppleEventSendNeverInteract timeout:2.0 error:error];
    SInt32 code = [reply paramDescriptorForKeyword:keyErrorNumber].int32Value;
    if (code) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:code userInfo:nil];
        return nil;
    }
    return [reply paramDescriptorForKeyword:keyDirectObject];
}

static NSString *TVReadIssue(NSError *error) {
    if (error.code == errAEEventNotPermitted || error.code == errAEEventWouldRequireUserConsent)
        return @"请在「系统设置 → 隐私与安全性 → 自动化」允许随航观影助手访问 Apple TV。";
    return @"Apple TV 暂未返回播放状态，助手会继续重试。";
}

// A video window plus audio output from this PID can corroborate streaming playback
// when TV's library-oriented player state remains stopped. Never reads audio samples.
static BOOL TVOutputsAudio(pid_t pid) {
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID process = kAudioObjectUnknown;
    UInt32 size = sizeof(process);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(pid), &pid, &size,
        &process) != noErr || process == kAudioObjectUnknown) return NO;
    property.mSelector = kAudioProcessPropertyIsRunningOutput;
    UInt32 running = 0;
    size = sizeof(running);
    return AudioObjectGetPropertyData(process, &property, 0, NULL, &size, &running) == noErr && running != 0;
}

@interface TVPlayback ()
@property pid_t pid;
@property BOOL playedWithoutVideoWindow;
@property BOOL usedWindowAndAudio;
@property (strong) TVStreamTracker *stream;
@end

@implementation TVPlayback
- (AWPlaybackState)stateWithDetail:(NSString **)detail {
    if (detail) *detail = nil;
    NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TV"].firstObject;
    pid_t pid = app.processIdentifier;
    if (pid != self.pid) {
        self.pid = pid;
        self.playedWithoutVideoWindow = NO;
        self.usedWindowAndAudio = NO;
        self.stream = [TVStreamTracker new];
    }
    if (!app || app.terminated || pid <= 0) return AWIdle;
    BOOL active = NO;
    BOOL readable = TVReadPlaybackAssertion(pid, &active);
    NSArray *visible = TVVisibleWindows(pid);
    NSNumber *streamState = [self.stream sampleAssertion:active readable:readable
                                          visibleWindows:visible appActive:app.active at:NSProcessInfo.processInfo.systemUptime];
    if (streamState) return streamState.integerValue;

    NSAppleEventDescriptor *address = [NSAppleEventDescriptor descriptorWithProcessIdentifier:pid];
    OSStatus permission = AEDeterminePermissionToAutomateTarget(address.aeDesc, kAECoreSuite, kAEGetData, false);
    if (permission != noErr) {
        if (readable && visible && !active && visible.count < 2) return AWIdle;
        if (detail) *detail = @"正在等待 Apple TV 的影片播放信号。";
        return AWUnknown;
    }
    NSError *error = nil;
    NSAppleEventDescriptor *rawState = ReadTV(address, kAEGetData, &error);
    if (!rawState) {
        if (app.terminated) return AWIdle;
        if (detail) *detail = TVReadIssue(error);
        return AWUnknown;
    }
    OSType state = rawState.descriptorType == typeType ? rawState.typeCodeValue : rawState.enumCodeValue;
    NSError *windowError = nil;
    NSAppleEventDescriptor *windows = [ReadTV(address, kAECountElements, &windowError) coerceToDescriptorType:typeSInt32];
    BOOL hasVideoWindow = windows.int32Value > 0;
    switch (state) {
        case 'kPSP':  // playing
        case 'kPSF':  // fast forwarding
        case 'kPSR':  // rewinding
            self.playedWithoutVideoWindow = !hasVideoWindow;
            return AWPlaying;
        case 'kPSp':  // paused
            if (hasVideoWindow || self.playedWithoutVideoWindow) return AWPaused;
            if (windows) {
                self.usedWindowAndAudio = NO;
                return AWIdle;
            }
            break;
        case 'kPSS':  // stopped
            self.playedWithoutVideoWindow = NO;
            if (!windows) break;
            if (hasVideoWindow && TVOutputsAudio(pid)) {
                self.usedWindowAndAudio = YES;
                return AWPlaying;
            }
            if (hasVideoWindow && self.usedWindowAndAudio) return AWPaused;
            self.usedWindowAndAudio = NO;
            return AWIdle;
    }
    if (detail) *detail = TVReadIssue(windowError);
    return AWUnknown;
}
@end
