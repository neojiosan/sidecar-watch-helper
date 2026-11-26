#import "WatchPlayer.h"

typedef NS_ENUM(NSInteger, WatchPlayerError) {
    WatchPlayerErrorUnknownService = 1,
    WatchPlayerErrorTVNotFound,
    WatchPlayerErrorNoApplication
};

static NSError *PlayerError(WatchPlayerError code, NSString *message) {
    return [NSError errorWithDomain:@"WatchPlayer" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

void OpenWatchPlayer(NSString *service, NSString *browserID, void (^completion)(NSRunningApplication *, NSError *)) {
    void (^finish)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, error);
            } else if (app) {
                completion(app, nil);
            } else {
                completion(nil, PlayerError(WatchPlayerErrorNoApplication, @"macOS 未返回打开播放器的应用。"));
            }
        });
    };

    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    if ([service isEqualToString:@"netflix"]) {
        NSURL *url = [NSURL URLWithString:@"https://www.netflix.com/browse"];
        NSURL *browser = [workspace URLForApplicationWithBundleIdentifier:browserID];
        if (browser) {
            [workspace openURLs:@[url] withApplicationAtURL:browser configuration:configuration completionHandler:finish];
        } else {
            finish(nil, PlayerError(WatchPlayerErrorNoApplication, @"找不到所选的 Netflix 浏览器，请在助手中选择已安装的浏览器。"));
        }
    } else if ([service isEqualToString:@"tv"]) {
        NSURL *url = [workspace URLForApplicationWithBundleIdentifier:@"com.apple.TV"];
        if (url) {
            [workspace openApplicationAtURL:url configuration:configuration completionHandler:finish];
        } else {
            finish(nil, PlayerError(WatchPlayerErrorTVNotFound, @"这台 Mac 上没有找到 Apple TV 应用。"));
        }
    } else {
        finish(nil, PlayerError(WatchPlayerErrorUnknownService, @"无法识别选择的播放服务。"));
    }
}
