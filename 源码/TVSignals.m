#import "TVSignals.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <CoreGraphics/CoreGraphics.h>

static BOOL IsTVMediaAssertionName(NSString *name) {
    static NSString *const prefix = @"com.apple.coremedia.iq.ca.client-";
    if (![name hasPrefix:prefix] || name.length == prefix.length) return NO;
    for (NSUInteger i = prefix.length; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

BOOL TVReadPlaybackAssertion(pid_t pid, BOOL *active) {
    if (!active) return NO;
    *active = NO;
    if (pid <= 0) return NO;
    CFDictionaryRef byProcess = NULL;
    IOReturn status = IOPMCopyAssertionsByProcess(&byProcess);
    NSDictionary *snapshot = CFBridgingRelease(byProcess);
    if (status != kIOReturnSuccess || ![snapshot isKindOfClass:NSDictionary.class]) return NO;
    NSArray *entries = snapshot[@(pid)];
    if (!entries) return YES;
    if (![entries isKindOfClass:NSArray.class]) return NO;

    BOOL readable = YES;
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) { readable = NO; continue; }
        NSString *type = entry[(__bridge NSString *)kIOPMAssertionTypeKey];
        if (![type isKindOfClass:NSString.class]) { readable = NO; continue; }
        if (![type isEqualToString:(__bridge NSString *)kIOPMAssertPreventUserIdleDisplaySleep]) continue;
        NSString *name = entry[(__bridge NSString *)kIOPMAssertionNameKey];
        if (![name isKindOfClass:NSString.class]) { readable = NO; continue; }
        if (!IsTVMediaAssertionName(name)) continue;
        NSNumber *level = entry[(__bridge NSString *)kIOPMAssertionLevelKey];
        if (![level isKindOfClass:NSNumber.class]) { readable = NO; continue; }
        if (level.unsignedIntValue == kIOPMAssertionLevelOn) {
            *active = YES;
            return YES;
        }
    }
    return readable;
}

NSArray<NSNumber *> *TVVisibleWindows(pid_t pid) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    if (!windows) return nil;
    NSMutableArray *numbers = [NSMutableArray array];
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid || [window[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds)) continue;
        if (bounds.size.width < 120 || bounds.size.height < 80 || [window[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        NSNumber *number = window[(id)kCGWindowNumber];
        if (number) [numbers addObject:number];
    }
    return numbers;
}

@implementation TVStreamTracker {
    NSNumber *_libraryWindow, *_playerWindow;
    BOOL _stream;
    BOOL _confirming;
    NSTimeInterval _firstAssertion;
}

- (NSNumber *)sampleAssertion:(BOOL)active readable:(BOOL)readable
               visibleWindows:(NSArray<NSNumber *> *)windows appActive:(BOOL)appActive at:(NSTimeInterval)now {
    if (!active || !readable) _confirming = NO;
    if (!readable) return _stream ? @(AWUnknown) : nil;
    BOOL onlyLibrary = windows.count == 1 && [_libraryWindow isEqual:windows.firstObject];
    if (active) {
        // An inline preview in a previously identified library window isn't an episode.
        if (!_stream && onlyLibrary) { _confirming = NO; return nil; }
        // CoreMedia can hold this assertion for ~2 s when only the first frame is loaded.
        if (!_stream && !_confirming) {
            _firstAssertion = now;
            _confirming = YES;
        }
        if (!_stream && now - _firstAssertion < 2.5) return nil;
        _stream = YES;
        if ((windows.count > 1 || _libraryWindow) && (!_playerWindow || ![windows containsObject:_playerWindow])) {
            NSNumber *candidate = nil;
            for (NSNumber *window in windows) {
                if ([window isEqual:_libraryWindow]) continue;
                // If we started mid-film, the temporary player is newer than the library.
                if (!candidate || window.unsignedIntValue > candidate.unsignedIntValue) candidate = window;
            }
            if (candidate) _playerWindow = candidate;
        }
        return @(AWPlaying);
    }
    if (_stream) {
        if (!windows) return @(AWUnknown);
        if (_playerWindow && [windows containsObject:_playerWindow]) return @(AWPaused);
        if (!windows.count && !appActive) return @(AWUnknown); // Hidden or on another Space.
        BOOL closedPlayer = _playerWindow != nil;
        _stream = NO;
        _playerWindow = nil;
        if (windows.count == 1) _libraryWindow = windows.firstObject;
        // For a single-window session that never yielded a distinct player ID,
        // give the native script state a chance to identify a paused player.
        return closedPlayer ? @(AWIdle) : nil;
    }
    if (!_libraryWindow && windows.count == 1) _libraryWindow = windows.firstObject;
    return nil;
}
@end
