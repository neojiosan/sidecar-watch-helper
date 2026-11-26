#import <AppKit/AppKit.h>
#import "WatchSession.h"
#import "WatchPlayer.h"
#import "SidecarDevice.h"
#import "PlaybackMonitor.h"

static NSString *const ChromeID = @"com.google.Chrome";
static NSString *const BrowserKey = @"NetflixBrowser";
static NSString *const EnabledKey = @"AutomaticPlaybackSwitching";

static NSString *StateLabel(AWPlaybackState state) {
    switch (state) {
        case AWPlaying: return @"正在播放";
        case AWPaused: return @"已暂停";
        case AWIdle: return @"待播放";
        default: return @"正在检测";
    }
}

@interface Assistant : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) WatchSession *session;
@property (strong) NSWindow *window;
@property (strong) NSStatusItem *item;
@property (strong) NSTextField *message;
@property (strong) NSButton *netflix, *tv, *only, *restore, *forgetButton;
@property (strong) NSMenuItem *menuNetflix, *menuTV, *menuOnly, *menuRestore;
@property (strong) AutoWatch *automation;
@property (strong) PlaybackMonitor *monitor;
@property (strong) NSButton *autoToggle;
@property (strong) NSPopUpButton *browser;
@property (strong) NSTextField *signals;
@end

@implementation Assistant
- (NSMenuItem *)add:(NSString *)title to:(NSMenu *)menu action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{EnabledKey:@YES, BrowserKey:ChromeID}];
    self.session = [[WatchSession alloc] initWithDevices:[SCDeviceController new]
                                                defaults:defaults
                                              openPlayer:^(NSString *service, void (^finished)(NSRunningApplication *, NSError *)) {
        OpenWatchPlayer(service, [defaults stringForKey:BrowserKey], finished);
    }];
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    appItem.submenu = appMenu;
    [self add:@"显示观影助手" to:appMenu action:@selector(showWindow:)];
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [self add:@"退出随航观影助手" to:appMenu action:@selector(quit:)];
    quit.keyEquivalent = @"q";
    NSApp.mainMenu = main;
    [self buildWindow];
    [self buildStatusMenu];
    __weak Assistant *weakSelf = self;
    self.automation = [[AutoWatch alloc] initWithDefaults:defaults
        disconnect:^{ [weakSelf.session start:@"automatic"]; }
        restore:^{ [weakSelf.session restore]; }];
    self.monitor = [[PlaybackMonitor alloc] initWithHandler:^(AWPlaybackState netflix, AWPlaybackState tv, NSString *webDetail, NSString *tvDetail) {
        [weakSelf receivedNetflix:netflix tv:tv webDetail:webDetail tvDetail:tvDetail];
    }];
    self.session.onChange = ^{ [weakSelf update]; };
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(terminated:)
        name:NSWorkspaceDidTerminateApplicationNotification object:nil];
    [self update];
    [self showWindow:nil];
    [self configureMonitor];
}
- (void)buildStatusMenu {
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"play.rectangle" accessibilityDescription:@"随航观影助手"];
    symbol.template = YES;
    self.item.button.image = symbol;
    if (!symbol) self.item.button.title = @"▶";
    self.item.button.toolTip = @"随航观影助手";
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    self.menuRestore = [self add:@"恢复随航" to:menu action:@selector(restore:)];
    self.menuNetflix = [self add:@"观看 Netflix" to:menu action:@selector(netflix:)];
    self.menuTV = [self add:@"观看 Apple TV" to:menu action:@selector(tv:)];
    self.menuOnly = [self add:@"只断开随航" to:menu action:@selector(only:)];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:@"显示观影助手" to:menu action:@selector(showWindow:)];
    [self add:@"退出助手" to:menu action:@selector(quit:)];
    self.item.menu = menu;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)rect {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = rect;
    [self.window.contentView addSubview:button];
    return button;
}
- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,490,366)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"随航观影助手";
    self.window.releasedWhenClosed = NO;
    [self.window center];
    NSTextField *heading = [NSTextField labelWithString:@"在 Mac 上观看"];
    heading.font = [NSFont systemFontOfSize:23 weight:NSFontWeightSemibold];
    heading.frame = NSMakeRect(24,314,438,33);
    [self.window.contentView addSubview:heading];
    self.message = [NSTextField wrappingLabelWithString:@""];
    self.message.font = [NSFont systemFontOfSize:13];
    self.message.textColor = NSColor.secondaryLabelColor;
    self.message.frame = NSMakeRect(25,107,439,57);
    self.message.selectable = YES;
    [self.window.contentView addSubview:self.message];
    self.autoToggle = [NSButton checkboxWithTitle:@"按播放状态自动切换随航" target:self action:@selector(toggleAutomatic:)];
    self.autoToggle.frame = NSMakeRect(24,272,228,32);
    [self.window.contentView addSubview:self.autoToggle];
    NSTextField *browserLabel = [NSTextField labelWithString:@"Netflix 浏览器"];
    browserLabel.frame = NSMakeRect(254,279,88,19);
    [self.window.contentView addSubview:browserLabel];
    self.browser = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(342,270,124,32) pullsDown:NO];
    [self.browser addItemsWithTitles:@[@"Google Chrome", @"Safari"]];
    [self.browser itemAtIndex:0].representedObject = ChromeID;
    [self.browser itemAtIndex:1].representedObject = @"com.apple.Safari";
    self.browser.target = self;
    self.browser.action = @selector(changeBrowser:);
    [self.browser selectItemAtIndex:[[NSUserDefaults.standardUserDefaults stringForKey:BrowserKey] isEqualToString:@"com.apple.Safari"] ? 1 : 0];
    [self.window.contentView addSubview:self.browser];
    self.signals = [NSTextField wrappingLabelWithString:@""];
    self.signals.frame = NSMakeRect(25,177,439,85);
    self.signals.font = [NSFont systemFontOfSize:13];
    self.signals.selectable = YES;
    [self.window.contentView addSubview:self.signals];
    self.netflix = [self button:@"观看 Netflix" action:@selector(netflix:) frame:NSMakeRect(20,71,138,37)];
    self.tv = [self button:@"观看 Apple TV" action:@selector(tv:) frame:NSMakeRect(159,71,139,37)];
    self.only = [self button:@"只断开随航" action:@selector(only:) frame:NSMakeRect(300,71,139,37)];
    self.restore = [self button:@"恢复随航" action:@selector(restore:) frame:NSMakeRect(20,71,155,37)];
    self.restore.bezelColor = NSColor.controlAccentColor;
    self.forgetButton = [self button:@"清除这次记录…" action:@selector(forget:) frame:NSMakeRect(184,71,147,37)];
    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;
    separator.frame = NSMakeRect(24,55,442,1);
    [self.window.contentView addSubview:separator];
    NSButton *settings = [self button:@"显示器设置…" action:@selector(settings:) frame:NSMakeRect(21,10,116,33)];
    settings.bezelStyle = NSBezelStyleInline;
    NSButton *help = [self button:@"首次设置…" action:@selector(setup:) frame:NSMakeRect(355,10,112,33)];
    help.bezelStyle = NSBezelStyleInline;
}
- (void)update {
    BOOL pending = self.session.pending, busy = self.session.busy;
    self.message.stringValue = self.session.status;
    self.item.button.toolTip = self.session.status;
    for (NSButton *button in @[self.netflix,self.tv,self.only]) {
        button.hidden = pending; button.enabled = !busy && !pending;
    }
    for (NSButton *button in @[self.restore,self.forgetButton]) {
        button.hidden = !pending; button.enabled = !busy && pending;
    }
    for (NSMenuItem *item in @[self.menuNetflix,self.menuTV,self.menuOnly])
        item.enabled = !busy && !pending;
    self.menuRestore.enabled = !busy && pending;
    self.autoToggle.state = [NSUserDefaults.standardUserDefaults boolForKey:EnabledKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoToggle.enabled = !busy;
    self.browser.enabled = !busy && !self.session.automatic;
}
- (void)configureMonitor {
    if ([NSUserDefaults.standardUserDefaults boolForKey:EnabledKey]) {
        [self.monitor startWithBrowser:[NSUserDefaults.standardUserDefaults stringForKey:BrowserKey]];
    } else {
        [self.monitor stop];
        self.signals.stringValue = @"自动切换已关闭。下方按钮可以手动断开和恢复随航。";
    }
}
- (void)receivedNetflix:(AWPlaybackState)netflix tv:(AWPlaybackState)tv webDetail:(NSString *)webDetail tvDetail:(NSString *)tvDetail {
    NSString *text = [NSString stringWithFormat:@"Netflix · %@     Apple TV · %@", StateLabel(netflix), StateLabel(tv)];
    if (webDetail.length) text = [text stringByAppendingFormat:@"\n%@", webDetail];
    if (tvDetail.length) text = [text stringByAppendingFormat:@"\n%@", tvDetail];
    if (![self.signals.stringValue isEqualToString:text]) self.signals.stringValue = text;
    [self.automation updateNetflix:netflix appleTV:tv pending:self.session.pending automatic:self.session.automatic
                             busy:self.session.busy at:NSProcessInfo.processInfo.systemUptime];
}
- (void)toggleAutomatic:(NSButton *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:EnabledKey];
    if (!enabled) [self.session useManualRecovery];
    [self configureMonitor];
    [self update];
}
- (void)changeBrowser:(id)sender {
    [NSUserDefaults.standardUserDefaults setObject:self.browser.selectedItem.representedObject forKey:BrowserKey];
    [self configureMonitor];
}
- (void)openService:(NSString *)service {
    [self showWindow:nil];
    if ([NSUserDefaults.standardUserDefaults boolForKey:EnabledKey]) [self.session openWithoutDisconnect:service];
    else [self.session start:service];
}
- (void)netflix:(id)sender { [self openService:@"netflix"]; }
- (void)tv:(id)sender { [self openService:@"tv"]; }
- (void)only:(id)sender { [self showWindow:nil]; [self.session start:@"only"]; }
- (void)restore:(id)sender { [self showWindow:nil]; [self.automation userOverrodeSession]; [self.session restore]; }
- (void)forget:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"清除这次重连记录？";
    alert.informativeText = @"之后可以从 Mac 的「屏幕镜像」菜单手动连接 iPad。";
    [alert addButtonWithTitle:@"保留记录"];
    [alert addButtonWithTitle:@"清除记录"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertSecondButtonReturn) {
            [self.automation userOverrodeSession];
            [self.session forget];
        }
    }];
}
- (void)setup:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"首次设置自动切换";
    NSString *step = [[NSUserDefaults.standardUserDefaults stringForKey:BrowserKey] isEqualToString:ChromeID]
        ? @"在 Chrome 顶部菜单「显示 → 开发者」勾选「允许来自 Apple 事件的 JavaScript」。"
        : @"在 Safari「设置 → 高级」显示网页开发者功能，再到「设置 → 开发者」勾选「允许来自 Apple 事件的 JavaScript」。";
    alert.informativeText = [NSString stringWithFormat:@"%@\n\n首次打开所选浏览器时，在 macOS 的自动化提示中点「允许」。助手会自动检测 Apple TV 的剧集播放。可关闭助手窗口，保留菜单栏图标即可。", step];
    [alert addButtonWithTitle:@"好"];
    [alert addButtonWithTitle:@"打开自动化设置"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse answer) {
        if (answer == NSAlertSecondButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"]];
        }
    }];
}
- (void)settings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Displays-Settings.extension"]];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.session.busy) { NSBeep(); return NSTerminateCancel; }
    return NSTerminateNow;
}
- (void)terminated:(NSNotification *)note {
    BOOL pending = self.session.pending;
    [self.session playerTerminated:note.userInfo[NSWorkspaceApplicationKey]];
    if (pending && self.session.busy) [self showWindow:nil];
}
- (void)showWindow:(id)sender {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    [self showWindow:nil];
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) Assistant *assistant = [Assistant new];
        app.delegate = assistant;
        [app run];
    }
    return 0;
}
