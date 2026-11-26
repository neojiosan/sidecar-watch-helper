#import <AppKit/AppKit.h>
#include <stdio.h>

static NSColor *Color(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

static NSBezierPath *Rounded(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat radius) {
    return [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, w, h)
                                          xRadius:radius yRadius:radius];
}

static NSData *IconPNG(NSInteger pixels) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:(CGFloat)pixels / 1024];
    [scale concat];

    NSColor *violet = Color(.35, .25, .77);
    NSColor *navy = Color(.08, .12, .32);
    NSColor *mint = Color(.50, .96, .88);
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:violet endingColor:navy];
    [gradient drawInBezierPath:Rounded(100, 100, 824, 824, 179) angle:-55];

    [NSColor.whiteColor set];
    NSBezierPath *monitor = Rounded(219, 389, 552, 342, 36);
    monitor.lineWidth = 33;
    [monitor stroke];
    [Rounded(445, 331, 46, 65, 10) fill];
    [Rounded(357, 317, 220, 29, 14) fill];

    NSBezierPath *play = [NSBezierPath bezierPath];
    [play moveToPoint:NSMakePoint(430, 494)];
    [play lineToPoint:NSMakePoint(430, 629)];
    [play lineToPoint:NSMakePoint(544, 561)];
    [play closePath];
    [play fill];

    NSBezierPath *ipad = Rounded(595, 273, 202, 288, 30);
    [navy setFill];
    [ipad fill];
    [mint set];
    ipad.lineWidth = 27;
    [ipad stroke];
    [Rounded(663, 296, 66, 11, 5.5) fill];
    [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

// Each ICNS element stores a 4-byte type and a big-endian size, header included.
static void AppendElement(NSMutableData *output, const char *type, NSData *contents) {
    uint32_t length = CFSwapInt32HostToBig((uint32_t)contents.length + 8);
    [output appendBytes:type length:4];
    [output appendBytes:&length length:sizeof(length)];
    [output appendData:contents];
}

static BOOL CreateIcon(NSString *path) {
    const struct { const char *type; NSInteger pixels; } entries[] = {
        {"icp4", 16}, {"icp5", 32}, {"ic07", 128}, {"ic08", 256}, {"ic09", 512},
        {"ic11", 32}, {"ic12", 64}, {"ic13", 256}, {"ic14", 512}, {"ic10", 1024}
    };
    NSMutableData *payload = [NSMutableData data];
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        NSData *image = IconPNG(entries[i].pixels);
        if (!image) return NO;
        AppendElement(payload, entries[i].type, image);
    }
    NSMutableData *icon = [NSMutableData data];
    AppendElement(icon, "icns", payload);
    return [icon writeToFile:path atomically:YES];
}

static BOOL Install(NSString *source, NSString *destination) {
    for (NSRunningApplication *app in [NSRunningApplication
             runningApplicationsWithBundleIdentifier:@"local.neo.WatchWithSidecar"]) {
        if ([app.bundleURL.URLByResolvingSymlinksInPath.path isEqualToString:
                destination.stringByResolvingSymlinksInPath]) {
            fprintf(stderr, "请先退出正在运行的随航观影助手，再重新构建。\n");
            return NO;
        }
    }
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:destination];
    unsigned int flag = exists ? RENAME_SWAP : RENAME_EXCL;
    if (renamex_np(source.fileSystemRepresentation, destination.fileSystemRepresentation, flag)) {
        perror("安装随航观影助手失败");
        return NO;
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2) return CreateIcon(@(argv[1])) ? 0 : 1;
        if (argc == 4 && strcmp(argv[1], "install") == 0) {
            return Install(@(argv[2]), @(argv[3])) ? 0 : 1;
        }
        return 2;
    }
}
