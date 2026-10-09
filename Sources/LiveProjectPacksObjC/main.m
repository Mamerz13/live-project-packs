#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Vision/Vision.h>
#import <CommonCrypto/CommonDigest.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "AIExplainer-Swift.h"
#import "LPPAssetHelpers.h"
#import "LPPLiveClipCore.h"
#import "LPPWebParsing.h"

static void LPPLog(NSString *event, NSDictionary *details) {
    if (!event.length) return;
    static dispatch_queue_t logQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("com.local.liveprojectpacks.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(logQueue, ^{
        @autoreleasepool {
            NSMutableDictionary *entry = [@{
                @"time": @([[NSDate date] timeIntervalSince1970]),
                @"event": event
            } mutableCopy];
            if (details.count) [entry addEntriesFromDictionary:details];
            NSError *jsonError = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:&jsonError];
            if (!json || jsonError) return;

            NSURL *logs = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
            logs = [logs URLByAppendingPathComponent:@"Logs" isDirectory:YES];
            NSError *directoryError = nil;
            [NSFileManager.defaultManager createDirectoryAtURL:logs withIntermediateDirectories:YES attributes:nil error:&directoryError];
            if (directoryError) return;
            NSURL *logURL = [logs URLByAppendingPathComponent:@"LiveProjectPacks.log"];
            NSMutableData *line = [json mutableCopy];
            [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            if (![NSFileManager.defaultManager fileExistsAtPath:logURL.path]) {
                [line writeToURL:logURL options:NSDataWritingAtomic error:nil];
                return;
            }
            @try {
                NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
                [handle seekToEndOfFile];
                [handle writeData:line];
                [handle closeFile];
            } @catch (__unused NSException *exception) {
            }
        }
    });
}

// Browsers whose front tab can be read over AppleScript. Firefox is deliberately
// absent - it exposes no scripting dictionary for the current URL.
static NSString *ScriptableBrowserName(void) {
    NSDictionary<NSString *, NSString *> *byBundleID = @{
        @"com.apple.Safari": @"Safari",
        @"com.google.Chrome": @"Google Chrome",
        @"company.thebrowser.Browser": @"Arc",
        @"com.brave.Browser": @"Brave Browser",
        @"com.microsoft.edgemac": @"Microsoft Edge",
        @"com.vivaldi.Vivaldi": @"Vivaldi"
    };
    NSString *frontmost = byBundleID[NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @""];
    if (frontmost) return frontmost;

    NSMutableSet<NSString *> *running = [NSMutableSet set];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *name = byBundleID[app.bundleIdentifier ?: @""];
        if (name) [running addObject:name];
    }
    for (NSString *preferred in @[@"Safari", @"Google Chrome", @"Arc", @"Brave Browser", @"Microsoft Edge", @"Vivaldi"]) {
        if ([running containsObject:preferred]) return preferred;
    }
    return nil;
}

static NSString *FrontTabScriptForBrowser(NSString *browser) {
    NSString *tab = [browser isEqualToString:@"Safari"] ? @"current tab" : @"active tab";
    // NSAppleScript runs on the main thread, and an AppleEvent defaults to a 60s
    // timeout - long enough to look like a hang while the browser is busy or the
    // Automation consent dialog is still waiting. Bound it to 5s instead.
    return [NSString stringWithFormat:
            @"with timeout of 5 seconds\ntell application \"%@\" to get URL of %@ of front window\nend timeout",
            browser, tab];
}

static NSString *WindowTitleForApplication(NSRunningApplication *application) {
    NSString *owner = application.localizedName;
    NSArray *windows = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *window in windows) {
        if (![window[(NSString *)kCGWindowOwnerName] isEqualToString:owner]) continue;
        NSString *name = window[(NSString *)kCGWindowName];
        if (name.length) return name;
    }
    return nil;
}

static NSURL *LinkURLFromHTML(NSString *html) {
    NSString *decoded = DecodedWebText(html);
    NSArray<NSString *> *patterns = @[
        @"<link[^>]+rel=[\"']canonical[\"'][^>]+href=[\"']([^\"']+)[\"']",
        @"<link[^>]+href=[\"']([^\"']+)[\"'][^>]+rel=[\"']canonical[\"']",
        @"data-pin-url=[\"']([^\"']+)[\"']",
        @"<a[^>]+href=[\"']([^\"']+)[\"']"
    ];
    for (NSString *pattern in patterns) {
        NSString *candidate = FirstMatch(decoded, pattern);
        NSURL *url = WebURLFromText(candidate);
        if (url) return url;
    }
    return WebURLFromText(decoded);
}

static NSURL *WebURLFromPropertyList(id value) {
    if ([value isKindOfClass:NSString.class]) return WebURLFromText(value);
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)value) {
            NSURL *url = WebURLFromPropertyList(child);
            if (url) return url;
        }
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        for (NSString *key in @[@"WebResourceURL", @"URL", @"url", @"WebMainResource"]) {
            NSURL *url = WebURLFromPropertyList(dictionary[key]);
            if (url) return url;
        }
        for (id child in dictionary.allValues) {
            NSURL *url = WebURLFromPropertyList(child);
            if (url) return url;
        }
    }
    return nil;
}

static NSURL *PinterestImageURLFromText(NSString *text) {
    NSString *decoded = DecodedWebText(text);
    NSArray<NSString *> *matches = AllMatches(decoded, @"(https?://[^\\s\"'<>]+i\\.pinimg\\.com[^\\s\"'<>]+)");
    if (!matches.count) return nil;

    NSString *best = nil;
    for (NSString *candidate in matches) {
        NSString *clean = CleanURLString(candidate);
        if ([clean containsString:@"/originals/"]) {
            best = clean;
            break;
        }
        if (!best || clean.length > best.length) best = clean;
    }
    return best ? [NSURL URLWithString:best] : nil;
}

static NSURL *ImageURLFromHTML(NSString *html) {
    NSString *decodedHTML = DecodedWebText(html);
    NSURL *pinImage = PinterestImageURLFromText(decodedHTML);
    if (pinImage) return pinImage;

    NSString *url = FirstMatch(decodedHTML, @"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']");
    if (!url) url = FirstMatch(decodedHTML, @"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image[\"']");
    if (!url) url = FirstMatch(decodedHTML, @"<meta[^>]+name=[\"']twitter:image[\"'][^>]+content=[\"']([^\"']+)[\"']");
    if (!url) url = FirstMatch(decodedHTML, @"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:image[\"']");
    if (!url) url = FirstMatch(decodedHTML, @"<img[^>]+data-src=[\"']([^\"']+)[\"']");
    if (!url) url = FirstMatch(decodedHTML, @"<img[^>]+src=[\"']([^\"']+)[\"']");
    if (!url) {
        NSString *srcset = FirstMatch(decodedHTML, @"<img[^>]+srcset=[\"']([^\"']+)[\"']");
        if (srcset.length) {
            NSArray *parts = [srcset componentsSeparatedByString:@","];
            NSString *last = Trimmed(parts.lastObject ?: parts.firstObject);
            url = [last componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject;
        }
    }
    if (!url) url = FirstMatch(decodedHTML, @"background-image:\\s*url\\([\"']?([^\"')]+)");
    if (!url) return nil;
    return [NSURL URLWithString:CleanURLString(DecodedWebText(url))];
}

static NSURL *ResolvedURL(NSURL *url, NSURL *baseURL) {
    if (!url) return nil;
    if (url.scheme.length) return url;
    if (!baseURL) return nil;
    return [NSURL URLWithString:url.relativeString relativeToURL:baseURL].absoluteURL;
}

static NSURL *PreferredOriginURL(NSURL *first, NSURL *second) {
    if (first && !IsLikelySocialImageURL(first)) return first;
    if (second && !IsLikelySocialImageURL(second)) return second;
    return first ?: second;
}

static NSImage *BundledPNG(NSString *name) {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
    NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    return image;
}

static BOOL BundledPNGHasAlpha(NSString *name) {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSBitmapImageRep *representation = data.length ? [NSBitmapImageRep imageRepWithData:data] : nil;
    return representation.hasAlpha;
}

static NSImage *AppIconImage(void) {
    NSImage *image = BundledPNG(@"LiveProjectPacks-icon");
    return image ?: [NSImage imageWithSystemSymbolName:@"tray.full.fill" accessibilityDescription:nil];
}

static NSVisualEffectView *GlassBackdrop(NSRect frame, CGFloat cornerRadius, NSVisualEffectMaterial material) {
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:frame];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.material = material;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = cornerRadius;
    glass.layer.masksToBounds = YES;
    return glass;
}

// A raw SF symbol handed straight to a button's imagePosition:NSImageAbove
// scales up to fill most of the available image area — fine for a lone
// toolbar icon, way too dominant next to a short title in a small chip.
// Baking a small colored badge behind a precisely-sized icon into one
// fixed-canvas image gives full control over both, instead of fighting
// AppKit's automatic image sizing.
static NSImage *ChipBadgeImage(NSString *symbolName, NSColor *badgeColor, CGFloat badgeSize, CGFloat iconPointSize) {
    return [NSImage imageWithSize:NSMakeSize(badgeSize, badgeSize) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:badgeSize * 0.32 yRadius:badgeSize * 0.32];
        [badgeColor setFill];
        [bg fill];

        NSImageSymbolConfiguration *sizeConfig = [NSImageSymbolConfiguration configurationWithPointSize:iconPointSize weight:NSFontWeightSemibold];
        NSImageSymbolConfiguration *colorConfig = [NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]];
        NSImageSymbolConfiguration *combined = [sizeConfig configurationByApplyingConfiguration:colorConfig];
        NSImage *icon = [[NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil] imageWithSymbolConfiguration:combined];
        NSSize iconSize = icon.size;
        NSRect iconRect = NSMakeRect((badgeSize - iconSize.width) / 2, (badgeSize - iconSize.height) / 2, iconSize.width, iconSize.height);
        [icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        return YES;
    }];
}

// "Volt OS" palette — every window is meant to read as an actual screen
// mounted on Volt's body, not a themed dark-mode app. That means warm
// phosphor black (not neutral gray-black), a real metallic brass for the
// physical bezel, and phosphor amber reserved for what you can act on —
// the same "gold = actionable" rule as before, just with more presence.
static NSColor *VoltScreenColor(void) { return [NSColor colorWithCalibratedRed:0.085 green:0.094 blue:0.110 alpha:1]; }
// "Gold" is now a soft slate blue (name kept so call sites don't churn):
// the warm amber palette was tiring on the eyes.
static NSColor *VoltGoldColor(void) { return [NSColor colorWithCalibratedRed:0.50 green:0.64 blue:0.84 alpha:1]; }
static NSColor *VoltAmberColor(void) { return [NSColor colorWithCalibratedRed:0.45 green:0.55 blue:0.70 alpha:1]; }
static NSColor *VoltTealColor(void) { return [NSColor colorWithCalibratedRed:0.44 green:0.62 blue:0.60 alpha:1]; }

// A single idle/hover/pressed contrast ladder for every neutral surface —
// buttons, pills, cards — instead of each one picking its own faint alpha.
// Each step is a clearly bigger jump than the last, so hovering or pressing
// something is unmistakable rather than a barely-there shift.
static NSColor *SurfaceIdleColor(void) { return [NSColor colorWithCalibratedWhite:1 alpha:0.10]; }
static NSColor *SurfaceHoverColor(void) { return [NSColor colorWithCalibratedWhite:1 alpha:0.20]; }
static NSColor *SurfacePressedColor(void) { return [NSColor colorWithCalibratedWhite:1 alpha:0.30]; }
static NSColor *VoltGoldHoverColor(void) { return [VoltGoldColor() blendedColorWithFraction:0.18 ofColor:NSColor.whiteColor]; }
static NSColor *VoltGoldPressedColor(void) { return [VoltGoldColor() blendedColorWithFraction:0.18 ofColor:NSColor.blackColor]; }

// Signature-detail palette: warm amber is the Pack's resting state (kept
// pale/yellow rather than toward VoltGoldColor's deeper orange — "warm
// light through glass," not a traffic-cone glow); purple/blue is reserved
// for when the AI is actually doing something, never used decoratively
// elsewhere; mint marks online/synced/success so it never gets confused
// with the amber "everything is normal" signal.
static NSColor *PackRimAmberColor(void) { return [NSColor colorWithCalibratedRed:0.52 green:0.66 blue:0.86 alpha:1]; }
static NSColor *PackRimAIPurpleColor(void) { return [NSColor colorWithCalibratedRed:0.58 green:0.42 blue:0.95 alpha:1]; }
static NSColor *PackRimAIBlueColor(void) { return [NSColor colorWithCalibratedRed:0.80 green:0.52 blue:0.94 alpha:1]; }
static NSColor *PackMintColor(void) { return [NSColor colorWithCalibratedRed:0.42 green:0.82 blue:0.68 alpha:1]; }

// Every structural line (frame seams, dividers) draws in this instead of
// gold or brass — chrome should describe an edge; the warm tones are
// reserved for the physical bezel and for things you can act on.
static NSColor *VoltLineColor(void) { return [NSColor colorWithCalibratedRed:0.32 green:0.36 blue:0.42 alpha:1]; }

// A glowing streak that continuously travels around a panel's rounded edge
// — a faint full-perimeter hairline underneath, plus one bright dashed
// segment whose lineDashPhase animates continuously, which is what actually
// reads as motion chasing around the border rather than a static ring. The
// panel window is exactly the size of the visible card (no margin for a
// blob to bleed into, unlike the Ask AI panel's glow), so this hugs the
// inside of the border instead of bleeding past it. Pass-through like every
// other decoration here: hitTest always returns nil.
@interface LPPRimGlowOverlay : NSView
@end
@implementation LPPRimGlowOverlay
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

// aiActive switches the streak from its resting amber to a purple/blue
// pair that alternates as it travels (an "iridescent" shimmer rather than a
// flat color swap) and picks up the pace — the product's one recognizable
// tell for "something intelligent is happening" versus "everything's fine."
static LPPRimGlowOverlay *AddRimGlowOverlay(NSView *container, CGFloat cornerRadius, BOOL aiActive) {
    LPPRimGlowOverlay *overlay = [[LPPRimGlowOverlay alloc] initWithFrame:container.bounds];
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.wantsLayer = YES;

    NSColor *restColor = aiActive ? PackRimAIPurpleColor() : PackRimAmberColor();

    CGRect rimRect = CGRectInset(overlay.bounds, 1.5, 1.5);
    CGPathRef path = CGPathCreateWithRoundedRect(rimRect, cornerRadius, cornerRadius, NULL);

    CAShapeLayer *base = [CAShapeLayer layer];
    base.frame = overlay.bounds;
    base.path = path;
    base.fillColor = NSColor.clearColor.CGColor;
    base.strokeColor = [restColor colorWithAlphaComponent:0.2].CGColor;
    base.lineWidth = 1.25;
    [overlay.layer addSublayer:base];

    CGFloat perimeter = 2 * (CGRectGetWidth(rimRect) + CGRectGetHeight(rimRect)) - (8 * cornerRadius) + (2 * M_PI * cornerRadius);
    // A fixed 40-70px streak regardless of window size, not a percentage of
    // the perimeter — a subtle traveling accent, not a growing/shrinking one.
    CGFloat dashLength = MIN(70, MAX(40, perimeter * 0.08));
    CGFloat gapLength = MAX(1, perimeter - dashLength);

    CAShapeLayer *streak = [CAShapeLayer layer];
    streak.frame = overlay.bounds;
    streak.path = path;
    streak.fillColor = NSColor.clearColor.CGColor;
    streak.strokeColor = restColor.CGColor;
    streak.lineWidth = 2;
    streak.lineCap = kCALineCapRound;
    streak.lineDashPattern = @[@(dashLength), @(gapLength)];
    streak.shadowColor = restColor.CGColor;
    streak.shadowRadius = 7;
    streak.shadowOpacity = 1;
    streak.shadowOffset = CGSizeZero;
    [overlay.layer addSublayer:streak];

    CGPathRelease(path);

    if (!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        CABasicAnimation *travel = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
        travel.fromValue = @0;
        travel.toValue = @(-perimeter);
        travel.duration = aiActive ? 2.2 : 7.0;
        travel.repeatCount = HUGE_VALF;
        travel.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [streak addAnimation:travel forKey:@"rimTravel"];

        if (aiActive) {
            CAKeyframeAnimation *shimmer = [CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
            shimmer.values = @[(id)PackRimAIPurpleColor().CGColor, (id)PackRimAIBlueColor().CGColor, (id)PackRimAIPurpleColor().CGColor];
            shimmer.duration = 1.8;
            shimmer.repeatCount = HUGE_VALF;
            shimmer.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [streak addAnimation:shimmer forKey:@"rimShimmer"];
        }
    }

    [container addSubview:overlay];
    return overlay;
}

// Flat dark rounded surface shared by every utility popup — no bezel, seam,
// rivets or scanlines (they ate ~9pt per side and read as clutter next to
// the borderless main shelf and Ask AI panel). kVoltBezelWidth survives only
// as a content inset some panels already lay themselves out against.
static const CGFloat kVoltBezelWidth = 9;

static void ApplyVoltScreenChrome(NSView *content) {
    content.wantsLayer = YES;
    content.layer.backgroundColor = VoltScreenColor().CGColor;
    content.layer.cornerRadius = 16;
    content.layer.masksToBounds = YES;
}

static NSArray<NSPasteboardType> *AcceptedDropTypes(void) {
    static NSArray<NSPasteboardType> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = @[
            NSPasteboardTypeFileURL,
            NSPasteboardTypeURL,
            NSPasteboardTypeHTML,
            NSPasteboardTypeString,
            NSPasteboardTypeTIFF,
            NSPasteboardTypePNG,
            @"public.jpeg",
            @"public.webp",
            @"com.compuserve.gif",
            @"public.heic",
            @"public.avif",
            @"Apple URL pasteboard type",
            @"WebURLsWithTitlesPboardType",
            @"Apple Web Archive pasteboard type",
            @"com.apple.pasteboard.promised-file-content-type",
            @"com.apple.pasteboard.promised-file-url",
            @"NSFilesPromisePboardType"
        ];
    });
    return types;
}

static BOOL PasteboardLooksDroppable(NSPasteboard *pasteboard) {
    if (!pasteboard) return NO;
    if ([pasteboard availableTypeFromArray:AcceptedDropTypes()]) return YES;
    if ([pasteboard stringForType:NSPasteboardTypeString].length) return YES;
    if ([pasteboard stringForType:NSPasteboardTypeURL].length) return YES;
    if ([pasteboard stringForType:@"Apple URL pasteboard type"].length) return YES;
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{}];
    if (urls.count) return YES;
    NSArray<NSImage *> *images = [pasteboard readObjectsForClasses:@[NSImage.class] options:@{}];
    if (images.count) return YES;
    return NO;
}

static NSData *ImageDataFromPasteboard(NSPasteboard *pasteboard, NSString **extension) {
    NSArray<NSDictionary<NSString *, NSString *> *> *formats = @[
        @{@"type": NSPasteboardTypePNG, @"extension": @"png"},
        @{@"type": @"public.jpeg", @"extension": @"jpg"},
        @{@"type": @"public.webp", @"extension": @"webp"},
        @{@"type": @"com.compuserve.gif", @"extension": @"gif"},
        @{@"type": @"public.heic", @"extension": @"heic"},
        @{@"type": @"public.avif", @"extension": @"avif"}
    ];
    for (NSPasteboardItem *item in pasteboard.pasteboardItems ?: @[]) {
        for (NSDictionary *format in formats) {
            NSData *data = [item dataForType:format[@"type"]];
            if (!data.length) continue;
            if (extension) *extension = format[@"extension"];
            return data;
        }
        NSData *tiff = [item dataForType:NSPasteboardTypeTIFF];
        if (tiff.length) {
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (png.length) {
                if (extension) *extension = @"png";
                return png;
            }
        }
    }
    for (NSDictionary *format in formats) {
        NSData *data = [pasteboard dataForType:format[@"type"]];
        if (!data.length) continue;
        if (extension) *extension = format[@"extension"];
        return data;
    }
    NSData *tiff = [pasteboard dataForType:NSPasteboardTypeTIFF];
    NSBitmapImageRep *rep = tiff.length ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png.length && extension) *extension = @"png";
    return png;
}

static BOOL IsSubstantialImageData(NSData *data) {
    NSBitmapImageRep *rep = data.length ? [NSBitmapImageRep imageRepWithData:data] : nil;
    if (!rep) return NO;
    return rep.pixelsWide >= 96 && rep.pixelsHigh >= 48;
}

static NSDragOperation AcceptedDragOperation(id<NSDraggingInfo> sender) {
    NSDragOperation mask = sender.draggingSourceOperationMask;
    if (mask & NSDragOperationCopy) return NSDragOperationCopy;
    if (mask & NSDragOperationLink) return NSDragOperationLink;
    if (mask & NSDragOperationGeneric) return NSDragOperationGeneric;
    if (mask & NSDragOperationMove) return NSDragOperationCopy;
    if (PasteboardLooksDroppable(sender.draggingPasteboard)) return NSDragOperationCopy;
    return NSDragOperationNone;
}

static NSString *RelativeTimeString(id value) {
    NSDate *date = nil;
    if ([value isKindOfClass:NSDate.class]) date = value;
    if ([value isKindOfClass:NSNumber.class]) date = [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    if ([value isKindOfClass:NSString.class] && [(NSString *)value doubleValue] > 0) date = [NSDate dateWithTimeIntervalSince1970:[(NSString *)value doubleValue]];
    if (!date) return @"just now";
    NSTimeInterval elapsed = MAX(0, -date.timeIntervalSinceNow);
    if (elapsed < 60) return @"just now";
    if (elapsed < 3600) return [NSString stringWithFormat:@"%ldm", (long)(elapsed / 60)];
    if (elapsed < 86400) return [NSString stringWithFormat:@"%ldh", (long)(elapsed / 3600)];
    return [NSString stringWithFormat:@"%ldd", (long)(elapsed / 86400)];
}

static NSString *DisplayName(NSString *account);

static NSString *AssetSubtitle(NSDictionary *asset) {
    NSString *kind = asset[@"kind"] ?: @"File";
    NSString *lead = kind;
    NSURL *originURL = AssetOriginURL(asset);
    if (IsLiveClip(asset)) {
        NSDictionary *clip = asset[@"liveClip"];
        if ([clip[@"analysisStatus"] isEqualToString:@"processing"]) return [NSString stringWithFormat:@"Analyzing  ·  %@", RelativeTimeString(asset[@"addedAt"])];
        NSString *mode = [clip[@"mode"] isKindOfClass:NSString.class] ? clip[@"mode"] : @"Keep";
        NSDictionary *source = [clip[@"source"] isKindOfClass:NSDictionary.class] ? clip[@"source"] : @{};
        NSString *app = [source[@"applicationName"] isKindOfClass:NSString.class] ? source[@"applicationName"] : ([clip[@"sourceApplicationName"] isKindOfClass:NSString.class] ? clip[@"sourceApplicationName"] : @"Screen");
        NSString *window = [source[@"windowTitle"] isKindOfClass:NSString.class] ? source[@"windowTitle"] : @"";
        NSString *type = [clip[@"contentType"] isKindOfClass:NSString.class] ? clip[@"contentType"] : @"image";
        NSString *sourceLabel = window.length ? [NSString stringWithFormat:@"%@ · %@", app, window] : app;
        lead = [mode isEqualToString:@"Watch"] ? [NSString stringWithFormat:@"Watching %@", sourceLabel] : sourceLabel;
    }
    if ([kind isEqualToString:@"Link"] && originURL) {
        NSURL *url = originURL;
        lead = url.host.length ? url.host : @"Link";
    }
    NSString *uploader = DisplayName(asset[@"uploader"] ?: @"You");
    return [NSString stringWithFormat:@"%@  ·  %@  ·  %@", lead, uploader, RelativeTimeString(asset[@"addedAt"])];
}

static NSImage *ImmediatePreviewImage(NSDictionary *asset) {
    if (IsLiveClip(asset)) {
        NSString *path = LiveClipImagePath(asset);
        NSImage *image = path.length ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
        if (image) return image;
    }
    NSString *previewPath = asset[@"preview"];
    if (previewPath.length) {
        NSImage *preview = [[NSImage alloc] initWithContentsOfFile:previewPath];
        if (preview) return preview;
    }

    NSString *source = AssetFilePath(asset);
    if (source.length) {
        NSString *kind = asset[@"kind"] ?: @"File";
        if ([kind isEqualToString:@"Image"] || [kind isEqualToString:@"PDF"]) {
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:source];
            if (image) return image;
        }
        return [NSWorkspace.sharedWorkspace iconForFile:source];
    }
    return nil;
}

static NSColor *AvatarColor(NSString *seed) {
    NSArray *colors = @[
        [NSColor colorWithCalibratedRed:0.11 green:0.78 blue:0.42 alpha:1],
        [NSColor colorWithCalibratedRed:0.22 green:0.55 blue:1.0 alpha:1],
        [NSColor colorWithCalibratedRed:0.68 green:0.43 blue:1.0 alpha:1],
        [NSColor colorWithCalibratedRed:1.0 green:0.48 blue:0.35 alpha:1],
        [NSColor colorWithCalibratedRed:1.0 green:0.72 blue:0.22 alpha:1],
    ];
    return colors[seed.hash % colors.count];
}

static NSString *Initials(NSString *email) {
    NSString *name = email.length ? email : @"?";
    NSString *first = [[name substringToIndex:1] uppercaseString];
    NSRange at = [name rangeOfString:@"@"];
    if (at.location != NSNotFound && at.location > 1) return first;
    return first;
}

static NSString *DisplayName(NSString *account) {
    if (!account.length || [account isEqualToString:@"You"]) return @"You";
    NSString *name = [account componentsSeparatedByString:@"@"].firstObject ?: account;
    NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"._-"]];
    NSString *first = parts.firstObject.length ? parts.firstObject : name;
    return first.capitalizedString;
}

static NSString *NormalizedPackName(NSString *input) {
    NSArray<NSString *> *parts = [Trimmed(input ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) [words addObject:part];
    }
    NSString *name = [words componentsJoinedByString:@" "];
    if (name.length <= 64) return name;
    NSRange safeRange = [name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 64)];
    return [name substringWithRange:safeRange];
}

static BOOL PackNameExistsExcept(NSArray<NSDictionary *> *packs, NSString *name, NSDictionary *excludedPack) {
    for (NSDictionary *pack in packs) {
        if (pack == excludedPack) continue;
        NSString *existing = [pack[@"name"] isKindOfClass:NSString.class] ? pack[@"name"] : @"";
        if ([existing caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    }
    return NO;
}

static BOOL PackNameExists(NSArray<NSDictionary *> *packs, NSString *name) {
    return PackNameExistsExcept(packs, name, nil);
}

static NSPoint AssetLocalPoint(NSPoint pointInSuperview, NSRect assetFrame, NSRect assetBounds) {
    return NSMakePoint(
        pointInSuperview.x - NSMinX(assetFrame) + NSMinX(assetBounds),
        pointInSuperview.y - NSMinY(assetFrame) + NSMinY(assetBounds)
    );
}

static NSPoint ClampedPanelOrigin(NSPoint proposed, NSSize panelSize, NSRect visibleFrame) {
    CGFloat minX = NSMinX(visibleFrame);
    CGFloat minY = NSMinY(visibleFrame);
    CGFloat maxX = MAX(minX, NSMaxX(visibleFrame) - panelSize.width);
    CGFloat maxY = MAX(minY, NSMaxY(visibleFrame) - panelSize.height);
    return NSMakePoint(
        MIN(MAX(proposed.x, minX), maxX),
        MIN(MAX(proposed.y, minY), maxY)
    );
}

// "Free roam" panels (Ask AI, Quick Preview) remember wherever the user
// last dragged/resized them to, per Mac (NSUserDefaults, not synced with
// the Pack itself — this is a personal window habit, not Pack data).
static NSString *const kAskAIPanelFrameDefaultsKey = @"LPPAskAIPanelFrame";

static void SaveNamedPanelFrame(NSString *key, NSRect frame) {
    [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(frame) forKey:key];
}

static NSRect SavedNamedPanelFrame(NSString *key) {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return saved.length ? NSRectFromString(saved) : NSZeroRect;
}

static NSScreen *ScreenContainingPoint(NSPoint point) {
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(point, screen.frame)) return screen;
    }
    return nil;
}

static CGDirectDisplayID DisplayIDForScreen(NSScreen *screen) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    return number ? (CGDirectDisplayID)number.unsignedIntValue : CGMainDisplayID();
}

// CGDisplayCreateImage was obsoleted in macOS 15 in favor of ScreenCaptureKit.
// Every caller here expects a synchronous NSImage back (this runs inline
// during a user-initiated capture gesture), so we bridge the async
// SCScreenshotManager call with a semaphore rather than restructuring the
// call sites to be async.
static NSImage *ImageForDisplay(CGDirectDisplayID displayID) {
    CGRect bounds = CGDisplayBounds(displayID);
    __block CGImageRef resultImage = NULL;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [SCScreenshotManager captureImageInRect:bounds completionHandler:^(CGImageRef _Nullable image, NSError * _Nullable error) {
        if (image) resultImage = CGImageRetain(image);
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    if (!resultImage) return nil;
    NSImage *image = [[NSImage alloc] initWithCGImage:resultImage size:NSZeroSize];
    CGImageRelease(resultImage);
    return image;
}

static NSData *PNGDataFromImage(NSImage *image) {
    NSData *tiff = image.TIFFRepresentation;
    NSBitmapImageRep *rep = tiff.length ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSImage *CroppedImageFromScreenImage(NSImage *image, NSRect selection, NSSize viewSize) {
    NSData *tiff = image.TIFFRepresentation;
    NSBitmapImageRep *rep = tiff.length ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    CGImageRef source = rep.CGImage;
    if (!source || NSWidth(selection) < 4 || NSHeight(selection) < 4) return nil;
    CGFloat scaleX = (CGFloat)CGImageGetWidth(source) / MAX(1, viewSize.width);
    CGFloat scaleY = (CGFloat)CGImageGetHeight(source) / MAX(1, viewSize.height);
    CGRect crop = CGRectMake(
        floor(NSMinX(selection) * scaleX),
        floor((viewSize.height - NSMaxY(selection)) * scaleY),
        ceil(NSWidth(selection) * scaleX),
        ceil(NSHeight(selection) * scaleY)
    );
    crop = CGRectIntersection(crop, CGRectMake(0, 0, CGImageGetWidth(source), CGImageGetHeight(source)));
    if (CGRectIsEmpty(crop)) return nil;
    CGImageRef cropped = CGImageCreateWithImageInRect(source, crop);
    if (!cropped) return nil;
    NSImage *result = [[NSImage alloc] initWithCGImage:cropped size:selection.size];
    CGImageRelease(cropped);
    return result;
}

static NSPoint PanelOriginNearTab(NSRect tabFrame, NSSize panelSize, NSRect visibleFrame) {
    CGFloat gap = 12;
    CGFloat spaceRight = NSMaxX(visibleFrame) - NSMaxX(tabFrame);
    CGFloat spaceLeft = NSMinX(tabFrame) - NSMinX(visibleFrame);
    BOOL placeRight = spaceRight >= panelSize.width + gap || spaceRight >= spaceLeft;
    CGFloat x = placeRight ? NSMaxX(tabFrame) + gap : NSMinX(tabFrame) - gap - panelSize.width;
    CGFloat y = NSMaxY(tabFrame) - panelSize.height;
    return ClampedPanelOrigin(NSMakePoint(x, y), panelSize, visibleFrame);
}

static BOOL ShouldAnimateVolt(BOOL userEnabled, BOOL reduceMotion) {
    return userEnabled && !reduceMotion;
}

typedef NS_ENUM(NSInteger, VoltGestureKind) {
    VoltGestureNone = -1,
    VoltGestureHop = 0,
    VoltGestureSquash = 1,
    VoltGestureWobble = 2
};

static const NSTimeInterval VoltGestureDuration = 0.66;

// Volt's idle motion is driven by resizing his frame rather than by a Core Animation
// transform: AppKit owns the transform of a layer-backed view's layer, so a transform
// animation there never reaches the screen.
static NSRect VoltIdleFrame(NSRect rest, NSTimeInterval clock, NSTimeInterval gestureElapsed, NSInteger gestureKind) {
    // The bob and breath periods are deliberately not multiples of each other, so they
    // drift in and out of phase instead of locking into an obvious loop.
    CGFloat bob = sin(clock * (2 * M_PI / 3.4)) * 2.0;
    CGFloat scale = 1.0 + sin(clock * (2 * M_PI / 2.8)) * 0.009;
    CGFloat lift = 0;
    CGFloat drift = 0;

    if (gestureKind != VoltGestureNone && gestureElapsed >= 0 && gestureElapsed < VoltGestureDuration) {
        CGFloat progress = gestureElapsed / VoltGestureDuration;
        CGFloat arc = sin(progress * M_PI);
        if (gestureKind == VoltGestureHop) lift = arc * 9.0;
        else if (gestureKind == VoltGestureSquash) scale -= arc * 0.06;
        else drift = sin(progress * 4 * M_PI) * 2.5 * (1.0 - progress);
    }

    CGFloat width = rest.size.width * scale;
    CGFloat height = rest.size.height * scale;
    return NSMakeRect(
        NSMinX(rest) + (rest.size.width - width) / 2 + drift,
        NSMinY(rest) + (rest.size.height - height) / 2 + bob + lift,
        width,
        height
    );
}

static NSInteger NextSelectionIndex(NSInteger current, NSInteger delta, NSInteger count) {
    if (count <= 0) return NSNotFound;
    if (current == NSNotFound) return delta > 0 ? 0 : count - 1;
    return MIN(MAX(current + delta, 0), count - 1);
}

static NSCache<NSString *, NSImage *> *ThumbnailCache(void) {
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    return cache;
}

static NSString *ThumbnailCacheKey(NSString *path, NSSize size) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSTimeInterval modified = [(NSDate *)attributes[NSFileModificationDate] timeIntervalSince1970];
    unsigned long long bytes = [attributes[NSFileSize] unsignedLongLongValue];
    return [NSString stringWithFormat:@"%@|%.0f|%llu|%.0fx%.0f", path, modified, bytes, size.width, size.height];
}

@class AppController;
@class LiveClipCaptureView;

// A "character" is a small, self-contained specialist that lives in the
// Pack's dock: a face + an optional badge, and one action (tap → its own
// tiny panel). The point is a hard boundary — a character owns its own
// panel UI and only reaches into AppController through its existing public
// methods, so a feature that grows too big becomes its own character
// instead of another method on the god object. ElectroCharacter (below,
// after AppController's @interface, since it calls AppController methods)
// is the first one; Henry/Spotify/Payroll/etc. would each be their own
// small class conforming to this same protocol.
@protocol PackCharacterProvider <NSObject>
- (NSString *)characterIdentifier;
- (NSString *)characterName;
- (NSImage *)characterIcon;
- (NSString *)characterBadgeTextForController:(AppController *)controller;
- (void)characterTappedWithController:(AppController *)controller anchorButton:(NSButton *)anchorButton;
@end

@protocol LiveClipCaptureController <NSObject>
- (void)cancelLiveClipCapture;
- (void)finishLiveClipSelectionFromView:(LiveClipCaptureView *)view mode:(NSString *)mode;
- (BOOL)isRelocatingLiveClipSource;
@end

@protocol FocusPanelController <NSObject>
- (BOOL)handlePanelKeyEvent:(NSEvent *)event;
@end

@interface FocusPanel : NSPanel
@property(nonatomic, weak) id<FocusPanelController> controller;
@end

@implementation FocusPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown && [self.controller handlePanelKeyEvent:event]) return;
    [super sendEvent:event];
}
@end

// movableByWindowBackground is supposed to make a plain NSView background
// draggable for free, but it only fires when the click reaches a totally
// unhandled default mouseDown — easy to end up with nothing in a busy
// header actually being "background" from AppKit's point of view. This is
// the same drag behavior made explicit and guaranteed: drop it under a
// region and any click that lands there (and isn't caught by a button on
// top of it first) starts a real window drag.
@interface LPPPanelDragHandle : NSView
@end
@implementation LPPPanelDragHandle
- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}
@end

// Borderless windows with NSWindowStyleMaskResizable are supposed to get
// automatic edge-drag resizing, but this panel's glow bleeds into a
// transparent margin outside the visible card, so the window's true edge
// sits ~22pt past anything the user can see or would think to grab — from
// the outside that reads as "resize doesn't work" even where it technically
// does. A visible, always-reachable corner grip that resizes the window
// directly removes any dependence on that native behavior working (or
// being discoverable) at all.
@interface LPPResizeGrip : NSView
@property(nonatomic, weak) NSWindow *targetWindow;
@property(nonatomic, copy) void (^onResize)(void);
@end
@implementation LPPResizeGrip {
    NSPoint _dragStartScreenPoint;
    NSRect _dragStartFrame;
}
- (BOOL)isOpaque { return NO; }
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedWhite:1 alpha:0.4] setStroke];
    CGFloat w = NSWidth(self.bounds);
    for (CGFloat offset = 4; offset < w; offset += 5) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        line.lineWidth = 1;
        [line moveToPoint:NSMakePoint(w - offset, 2)];
        [line lineToPoint:NSMakePoint(w - 2, offset)];
        [line stroke];
    }
}
- (void)mouseDown:(NSEvent *)event {
    _dragStartScreenPoint = NSEvent.mouseLocation;
    _dragStartFrame = self.targetWindow.frame;
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.targetWindow) return;
    NSPoint current = NSEvent.mouseLocation;
    CGFloat dx = current.x - _dragStartScreenPoint.x;
    CGFloat dy = current.y - _dragStartScreenPoint.y;
    NSSize minSize = self.targetWindow.minSize;
    CGFloat newWidth = MAX(minSize.width, _dragStartFrame.size.width + dx);
    CGFloat newHeight = MAX(minSize.height, _dragStartFrame.size.height - dy);
    NSRect newFrame = NSMakeRect(_dragStartFrame.origin.x, _dragStartFrame.origin.y + (_dragStartFrame.size.height - newHeight), newWidth, newHeight);
    [self.targetWindow setFrame:newFrame display:YES];
    if (self.onResize) self.onResize();
}
@end

// The app's custom icon buttons (bordered = NO, hand-drawn layer) had a
// single static appearance and no feedback at all on hover or press — you
// couldn't tell a button was interactive until the menu it opened actually
// appeared. This gives every one of them the same three-state ladder
// (idle/hover/pressed) instead of rebuilding that logic per button.
@interface HoverIconButton : NSButton
@property(nonatomic, strong) NSColor *idleBackground;
@property(nonatomic, strong) NSColor *hoverBackground;
@property(nonatomic, strong) NSColor *pressedBackground;
@end

@implementation HoverIconButton {
    NSTrackingArea *_hoverTrackingArea;
    BOOL _hovering;
}
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.bordered = NO;
    }
    return self;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverTrackingArea) [self removeTrackingArea:_hoverTrackingArea];
    _hoverTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_hoverTrackingArea];
}
- (void)applyState {
    NSColor *color = self.idleBackground;
    if (_hovering) color = self.hoverBackground ?: color;
    self.layer.backgroundColor = color.CGColor;
}
- (void)setIdleBackground:(NSColor *)idleBackground {
    _idleBackground = idleBackground;
    [self applyState];
}
- (void)mouseEntered:(NSEvent *)event {
    _hovering = YES;
    [self applyState];
}
- (void)mouseExited:(NSEvent *)event {
    _hovering = NO;
    [self applyState];
}
- (void)mouseDown:(NSEvent *)event {
    self.layer.backgroundColor = (self.pressedBackground ?: self.hoverBackground ?: self.idleBackground).CGColor;
    [super mouseDown:event];
    [self applyState];
}
@end

@interface LiveClipCaptureView : NSView
@property(nonatomic, weak) id<LiveClipCaptureController> controller;
@property(nonatomic) NSScreen *captureScreen;
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic) NSImage *screenImage;
@property(nonatomic) NSPoint dragStart;
@property(nonatomic) NSRect selectionRect;
@property(nonatomic) BOOL selecting;
@property(nonatomic) BOOL actionShown;
@property(nonatomic) NSMutableArray<NSButton *> *actionButtons;
- (instancetype)initWithFrame:(NSRect)frameRect screen:(NSScreen *)screen image:(NSImage *)image displayID:(CGDirectDisplayID)displayID controller:(id<LiveClipCaptureController>)controller;
@end

@implementation LiveClipCaptureView
- (instancetype)initWithFrame:(NSRect)frameRect screen:(NSScreen *)screen image:(NSImage *)image displayID:(CGDirectDisplayID)displayID controller:(id<LiveClipCaptureController>)controller {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.controller = controller;
    self.captureScreen = screen;
    self.displayID = displayID;
    self.screenImage = image;
    self.actionButtons = [NSMutableArray array];
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.blackColor.CGColor;
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kVK_Escape) {
        [self.controller cancelLiveClipCapture];
        return;
    }
    [super keyDown:event];
}
- (void)drawRect:(NSRect)dirtyRect {
    [self.screenImage drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
    [[NSColor colorWithCalibratedWhite:0 alpha:0.42] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    if (NSIsEmptyRect(self.selectionRect)) return;
    [[NSColor colorWithCalibratedWhite:1 alpha:0.92] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:self.selectionRect xRadius:4 yRadius:4];
    border.lineWidth = 1.5;
    [border stroke];
}
- (NSRect)normalizedRectFromPoint:(NSPoint)first toPoint:(NSPoint)second {
    return NSMakeRect(MIN(first.x, second.x), MIN(first.y, second.y), fabs(second.x - first.x), fabs(second.y - first.y));
}
- (void)removeActionButtons {
    for (NSButton *button in self.actionButtons) [button removeFromSuperview];
    [self.actionButtons removeAllObjects];
    self.actionShown = NO;
}
- (NSButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    button.frame = NSMakeRect(x, y, width, 28);
    [self addSubview:button];
    [self.actionButtons addObject:button];
    return button;
}
- (void)showActions {
    [self removeActionButtons];
    if ([self.controller isRelocatingLiveClipSource]) {
        CGFloat x = MIN(MAX(NSMinX(self.selectionRect), 12), NSWidth(self.bounds) - 150);
        CGFloat y = NSMinY(self.selectionRect) - 38;
        if (y < 12) y = NSMaxY(self.selectionRect) + 10;
        y = MIN(MAX(y, 12), NSHeight(self.bounds) - 40);
        [self actionButtonWithTitle:@"Relocate" action:@selector(keep:) x:x y:y width:96];
        [self actionButtonWithTitle:@"×" action:@selector(cancel:) x:x + 104 y:y width:40];
        self.actionShown = YES;
        return;
    }
    CGFloat totalWidth = 252;
    CGFloat x = MIN(MAX(NSMinX(self.selectionRect), 12), NSWidth(self.bounds) - totalWidth - 12);
    CGFloat y = NSMinY(self.selectionRect) - 38;
    if (y < 12) y = NSMaxY(self.selectionRect) + 10;
    y = MIN(MAX(y, 12), NSHeight(self.bounds) - 40);
    [self actionButtonWithTitle:@"Keep" action:@selector(keep:) x:x y:y width:58];
    [self actionButtonWithTitle:@"Extract" action:@selector(extract:) x:x + 64 y:y width:72];
    [self actionButtonWithTitle:@"Watch" action:@selector(watch:) x:x + 142 y:y width:64];
    [self actionButtonWithTitle:@"×" action:@selector(cancel:) x:x + 212 y:y width:40];
    self.actionShown = YES;
}
- (void)mouseDown:(NSEvent *)event {
    [self removeActionButtons];
    self.selecting = YES;
    self.dragStart = [self convertPoint:event.locationInWindow fromView:nil];
    self.selectionRect = NSZeroRect;
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.selecting) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.selectionRect = NSIntersectionRect([self normalizedRectFromPoint:self.dragStart toPoint:point], self.bounds);
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)event {
    if (!self.selecting) return;
    self.selecting = NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.selectionRect = NSIntersectionRect([self normalizedRectFromPoint:self.dragStart toPoint:point], self.bounds);
    if (NSWidth(self.selectionRect) < 8 || NSHeight(self.selectionRect) < 8) {
        [self.controller cancelLiveClipCapture];
        return;
    }
    [self showActions];
    [self.window makeFirstResponder:self];
}
- (void)keep:(id)sender { [self.controller finishLiveClipSelectionFromView:self mode:@"Keep"]; }
- (void)extract:(id)sender { [self.controller finishLiveClipSelectionFromView:self mode:@"Extract"]; }
- (void)watch:(id)sender { [self.controller finishLiveClipSelectionFromView:self mode:@"Watch"]; }
- (void)cancel:(id)sender { [self.controller cancelLiveClipCapture]; }
@end

@interface AssetTile : NSView <NSDraggingSource>
@property NSMutableDictionary *asset;
@property AppController *controller;
@property NSImageView *previewView;
@property NSButton *duplicateButton;
@property NSButton *openButton;
@property BOOL gridMode;
@property BOOL dragStarted;
@property NSPoint mouseDownPoint;
@property BOOL hovered;
@property NSTrackingArea *trackingArea;
- (instancetype)initWithAsset:(NSMutableDictionary *)asset controller:(AppController *)controller gridMode:(BOOL)gridMode;
- (void)refreshInteractionState;
@end

@interface AssetCanvasView : NSView
@property(nonatomic, weak) AppController *controller;
@end

@class CompactTabView;

@interface DropShelfView : NSView <NSDraggingDestination>
@property AppController *controller;
@property NSView *dropOverlay;
@end

@interface MascotDropImageView : NSImageView <NSDraggingDestination>
@property(nonatomic, weak) CompactTabView *dropTarget;
@property(nonatomic) BOOL idleAnimating;
@property(nonatomic, strong) NSTimer *idleTimer;
@property(nonatomic) NSRect restFrame;
@property(nonatomic) NSTimeInterval animationClock;
@property(nonatomic) NSTimeInterval gestureStart;
@property(nonatomic) NSTimeInterval nextGestureAt;
@property(nonatomic) NSInteger gestureKind;
- (void)startIdleAnimation;
- (void)stopIdleAnimation;
- (void)tickIdleAnimation;
- (void)playGesture:(NSInteger)kind;
- (void)playCatchPop;
- (void)playSuccessHop;
@end

@interface CompactTabView : NSView <NSDraggingDestination>
@property(nonatomic) AppController *controller;
@property MascotDropImageView *mascotView;
@property NSImage *idleMascot;
@property NSImage *catchMascot;
@property NSImage *successMascot;
@property BOOL movingWindow;
@property NSPoint movementStartScreenPoint;
@property NSPoint movementStartWindowOrigin;
- (void)refresh;
- (BOOL)voltAnimationsOn;
@end

#pragma mark - Spreadsheet preview parsing
//
// Quick Preview used to fall back to whatever app macOS had registered for
// the file (Numbers/Excel, or a browser for a link) — you never actually saw
// the rows in the Pack itself. These helpers parse CSV/TSV and .xlsx files
// directly (no third-party libraries: .xlsx is a zip of XML, so we shell out
// to the system `unzip` and read the parts with NSXMLParser) so the preview
// panel can render a real, scrollable table instead. Legacy binary .xls and
// Apple's proprietary .numbers format are intentionally out of scope here —
// those still fall back to the existing "Open" behavior below.

static const NSInteger kSpreadsheetPreviewMaxRows = 300;
static const NSInteger kSpreadsheetPreviewMaxCols = 40;

typedef NS_ENUM(NSInteger, LPPSpreadsheetKind) {
    LPPSpreadsheetKindNone,
    LPPSpreadsheetKindCSV,
    LPPSpreadsheetKindTSV,
    LPPSpreadsheetKindXLSX
};

static LPPSpreadsheetKind SpreadsheetKindForPath(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"csv"]) return LPPSpreadsheetKindCSV;
    if ([ext isEqualToString:@"tsv"]) return LPPSpreadsheetKindTSV;
    if ([ext isEqualToString:@"xlsx"] || [ext isEqualToString:@"xlsm"]) return LPPSpreadsheetKindXLSX;
    return LPPSpreadsheetKindNone;
}

static NSArray<NSArray<NSString *> *> *ParseDelimitedFile(NSString *path, unichar delimiter) {
    NSError *readError = nil;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!contents.length) contents = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:&readError];
    if (!contents) return nil;

    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    NSMutableArray<NSString *> *currentRow = [NSMutableArray array];
    NSMutableString *field = [NSMutableString string];
    BOOL inQuotes = NO;
    NSUInteger length = contents.length;
    for (NSUInteger i = 0; i < length && rows.count < (NSUInteger)kSpreadsheetPreviewMaxRows; i++) {
        unichar c = [contents characterAtIndex:i];
        if (inQuotes) {
            if (c == '"') {
                if (i + 1 < length && [contents characterAtIndex:i + 1] == '"') { [field appendString:@"\""]; i++; }
                else inQuotes = NO;
            } else {
                [field appendString:[NSString stringWithCharacters:&c length:1]];
            }
            continue;
        }
        if (c == '"') { inQuotes = YES; continue; }
        if (c == delimiter) {
            if (currentRow.count < (NSUInteger)kSpreadsheetPreviewMaxCols) [currentRow addObject:[field copy]];
            [field setString:@""];
            continue;
        }
        if (c == '\n' || c == '\r') {
            if (c == '\r' && i + 1 < length && [contents characterAtIndex:i + 1] == '\n') i++;
            if (currentRow.count < (NSUInteger)kSpreadsheetPreviewMaxCols) [currentRow addObject:[field copy]];
            [field setString:@""];
            if (currentRow.count > 1 || currentRow.firstObject.length) [rows addObject:currentRow];
            currentRow = [NSMutableArray array];
            continue;
        }
        [field appendString:[NSString stringWithCharacters:&c length:1]];
    }
    if (field.length || currentRow.count) {
        if (currentRow.count < (NSUInteger)kSpreadsheetPreviewMaxCols) [currentRow addObject:[field copy]];
        [rows addObject:currentRow];
    }
    return rows;
}

static NSInteger ColumnIndexForCellRef(NSString *ref) {
    NSInteger index = 0;
    for (NSUInteger i = 0; i < ref.length; i++) {
        unichar c = [ref characterAtIndex:i];
        if (c < 'A' || c > 'Z') break;
        index = index * 26 + (c - 'A' + 1);
    }
    return index - 1;
}

static NSString *ColumnLetterForIndex(NSInteger index) {
    NSMutableString *letters = [NSMutableString string];
    NSInteger n = index;
    do {
        [letters insertString:[NSString stringWithFormat:@"%c", (char)('A' + (n % 26))] atIndex:0];
        n = n / 26 - 1;
    } while (n >= 0);
    return letters;
}

@interface LPPSharedStringsParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *strings;
@end

@implementation LPPSharedStringsParser {
    NSMutableString *_currentText;
    BOOL _capturingText;
}
- (instancetype)init {
    if (self = [super init]) _strings = [NSMutableArray array];
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    if ([elementName isEqualToString:@"si"]) _currentText = [NSMutableString string];
    else if ([elementName isEqualToString:@"t"]) _capturingText = YES;
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (_capturingText && _currentText) [_currentText appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"t"]) _capturingText = NO;
    else if ([elementName isEqualToString:@"si"]) { [self.strings addObject:_currentText ?: @""]; _currentText = nil; }
}
@end

@interface LPPSheetParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSArray<NSString *> *sharedStrings;
@property(nonatomic, strong) NSMutableArray<NSMutableArray<NSString *> *> *rows;
@end

@implementation LPPSheetParser {
    NSMutableArray<NSString *> *_currentRow;
    NSMutableString *_currentValue;
    NSString *_currentCellType;
    NSInteger _currentCellCol;
    BOOL _capturingValue;
}
- (instancetype)init {
    if (self = [super init]) _rows = [NSMutableArray array];
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)ns qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attrs {
    if (self.rows.count >= (NSUInteger)kSpreadsheetPreviewMaxRows) { [parser abortParsing]; return; }
    if ([elementName isEqualToString:@"row"]) {
        _currentRow = [NSMutableArray array];
    } else if ([elementName isEqualToString:@"c"]) {
        _currentCellType = attrs[@"t"] ?: @"n";
        _currentCellCol = ColumnIndexForCellRef(attrs[@"r"] ?: @"");
        _currentValue = nil;
    } else if ([elementName isEqualToString:@"v"] || [elementName isEqualToString:@"t"]) {
        _currentValue = [NSMutableString string];
        _capturingValue = YES;
    }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (_capturingValue && _currentValue) [_currentValue appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)ns qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"v"] || [elementName isEqualToString:@"t"]) {
        _capturingValue = NO;
    } else if ([elementName isEqualToString:@"c"]) {
        if (!_currentRow || _currentCellCol < 0 || _currentCellCol >= kSpreadsheetPreviewMaxCols) { _currentValue = nil; return; }
        NSString *display = _currentValue ?: @"";
        if ([_currentCellType isEqualToString:@"s"]) {
            NSInteger idx = display.integerValue;
            display = (idx >= 0 && idx < (NSInteger)self.sharedStrings.count) ? self.sharedStrings[idx] : @"";
        } else if ([_currentCellType isEqualToString:@"b"]) {
            display = [display isEqualToString:@"1"] ? @"TRUE" : @"FALSE";
        }
        while ((NSInteger)_currentRow.count < _currentCellCol) [_currentRow addObject:@""];
        if ((NSInteger)_currentRow.count == _currentCellCol) [_currentRow addObject:display];
        else [_currentRow replaceObjectAtIndex:_currentCellCol withObject:display];
        _currentValue = nil;
    } else if ([elementName isEqualToString:@"row"]) {
        if (_currentRow) [self.rows addObject:_currentRow];
        _currentRow = nil;
    }
}
@end

// Returns an array of @{ @"name": sheetName, @"rows": rowsArray } or nil on failure (with *errorMessage set).
static NSArray<NSDictionary *> *ParseXLSXFile(NSString *path, NSString **errorMessage) {
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"lpp-xlsx-" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
    [NSFileManager.defaultManager createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSTask *unzip = [[NSTask alloc] init];
    unzip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/unzip"];
    unzip.arguments = @[@"-o", @"-q", path, @"-d", tempDir];
    unzip.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    unzip.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    if (![unzip launchAndReturnError:&launchError]) {
        if (errorMessage) *errorMessage = @"Could not open this file";
        [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
        return nil;
    }
    [unzip waitUntilExit];

    NSString *sharedStringsPath = [tempDir stringByAppendingPathComponent:@"xl/sharedStrings.xml"];
    NSArray<NSString *> *sharedStrings = @[];
    NSData *sharedStringsData = [NSData dataWithContentsOfFile:sharedStringsPath];
    if (sharedStringsData) {
        LPPSharedStringsParser *parser = [[LPPSharedStringsParser alloc] init];
        NSXMLParser *xml = [[NSXMLParser alloc] initWithData:sharedStringsData];
        xml.delegate = parser;
        [xml parse];
        sharedStrings = parser.strings;
    }

    NSString *workbookXML = [NSString stringWithContentsOfFile:[tempDir stringByAppendingPathComponent:@"xl/workbook.xml"] encoding:NSUTF8StringEncoding error:nil];
    NSString *relsXML = [NSString stringWithContentsOfFile:[tempDir stringByAppendingPathComponent:@"xl/_rels/workbook.xml.rels"] encoding:NSUTF8StringEncoding error:nil];
    if (!workbookXML.length) {
        if (errorMessage) *errorMessage = @"This doesn't look like a valid spreadsheet file";
        [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *targetByRelID = [NSMutableDictionary dictionary];
    for (NSString *tag in AllMatches(relsXML ?: @"", @"(<Relationship\\b[^>]*>)")) {
        NSString *relID = FirstMatch(tag, @"Id=\"([^\"]+)\"");
        NSString *target = FirstMatch(tag, @"Target=\"([^\"]+)\"");
        if (relID.length && target.length) targetByRelID[relID] = target;
    }

    NSMutableArray<NSDictionary *> *sheetsInfo = [NSMutableArray array];
    for (NSString *tag in AllMatches(workbookXML, @"(<sheet\\b[^>]*/?>)")) {
        NSString *name = FirstMatch(tag, @"name=\"([^\"]+)\"");
        NSString *relID = FirstMatch(tag, @"r:id=\"([^\"]+)\"");
        NSString *target = relID.length ? targetByRelID[relID] : nil;
        if (!name.length || !target.length) continue;
        [sheetsInfo addObject:@{ @"name": name, @"target": target }];
    }

    NSMutableArray<NSDictionary *> *sheets = [NSMutableArray array];
    for (NSDictionary *info in sheetsInfo) {
        if (sheets.count >= 20) break;
        NSString *target = info[@"target"];
        NSString *sheetPath = [target hasPrefix:@"/"]
            ? [tempDir stringByAppendingPathComponent:target]
            : [tempDir stringByAppendingPathComponent:[@"xl" stringByAppendingPathComponent:target]];
        NSData *sheetData = [NSData dataWithContentsOfFile:sheetPath];
        if (!sheetData) continue;
        LPPSheetParser *sheetParser = [[LPPSheetParser alloc] init];
        sheetParser.sharedStrings = sharedStrings;
        NSXMLParser *xml = [[NSXMLParser alloc] initWithData:sheetData];
        xml.delegate = sheetParser;
        [xml parse];
        [sheets addObject:@{ @"name": info[@"name"], @"rows": sheetParser.rows }];
    }

    [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
    if (!sheets.count) {
        if (errorMessage) *errorMessage = @"No readable sheets found in this file";
        return nil;
    }
    return sheets;
}

// Best-effort text sample for "Explain This" — the on-device model only
// gets an accurate answer if we hand it real content, not just a filename.
static NSString *SpreadsheetTextSample(NSString *filePath) {
    LPPSpreadsheetKind kind = SpreadsheetKindForPath(filePath);
    NSArray<NSDictionary *> *sheets = nil;
    if (kind == LPPSpreadsheetKindXLSX) {
        sheets = ParseXLSXFile(filePath, NULL);
    } else if (kind == LPPSpreadsheetKindCSV || kind == LPPSpreadsheetKindTSV) {
        NSArray<NSArray<NSString *> *> *rows = ParseDelimitedFile(filePath, kind == LPPSpreadsheetKindTSV ? '\t' : ',');
        if (rows.count) sheets = @[ @{ @"name": @"Sheet", @"rows": rows } ];
    }
    if (!sheets.count) return @"";

    NSArray<NSArray<NSString *> *> *rows = sheets.firstObject[@"rows"];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSInteger i = 0; i < MIN((NSInteger)rows.count, 15); i++) {
        [lines addObject:[rows[i] componentsJoinedByString:@", "]];
    }
    NSString *sheetNote = sheets.count > 1 ? [NSString stringWithFormat:@" (showing 1 of %lu sheets)", (unsigned long)sheets.count] : @"";
    return [NSString stringWithFormat:@"Spreadsheet%@, first %lu rows:\n%@", sheetNote, (unsigned long)lines.count, [lines componentsJoinedByString:@"\n"]];
}

static NSString *TextSampleForAsset(NSMutableDictionary *asset) {
    if (IsLiveClip(asset)) {
        NSString *text = CopyableTextForLiveClip(asset);
        return text.length ? text : @"";
    }
    NSString *payload = AssetPayload(asset);
    if (payload.length) return payload;

    NSString *filePath = AssetFilePath(asset);
    if (filePath.length && [NSFileManager.defaultManager fileExistsAtPath:filePath]) {
        if (SpreadsheetKindForPath(filePath) != LPPSpreadsheetKindNone) return SpreadsheetTextSample(filePath);
    }

    NSURL *url = AssetOriginURL(asset);
    if (url) return [NSString stringWithFormat:@"Link: %@", url.absoluteString];

    return @"";
}

static BOOL LooksAutoGeneratedAssetTitle(NSString *title) {
    NSString *trimmed = Trimmed(title ?: @"");
    if (!trimmed.length) return YES;
    NSString *lower = trimmed.lowercaseString;
    if ([lower isEqualToString:@"untitled asset"]) return YES;
    if ([lower hasPrefix:@"screenshot "]) return YES;
    if ([lower hasPrefix:@"screen shot "]) return YES;
    if ([lower hasPrefix:@"pasted-"]) return YES;
    if ([lower hasPrefix:@"image-"]) return YES;
    if ([lower hasPrefix:@"grab-"]) return YES;
    if ([lower hasPrefix:@"uploaded file"]) return YES;
    NSRegularExpression *uuidLike = [NSRegularExpression regularExpressionWithPattern:@"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" options:NSRegularExpressionCaseInsensitive error:nil];
    return [uuidLike numberOfMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)] > 0;
}

static NSString *CleanSuggestedAssetTitle(NSString *raw) {
    NSString *clean = CollapsedWhitespace(raw ?: @"");
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'`“”‘’"]];
    if (!clean.length) return nil;
    NSArray<NSString *> *badPrefixes = @[@"Title:", @"Name:", @"Suggested title:"];
    for (NSString *prefix in badPrefixes) {
        if ([clean rangeOfString:prefix options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            clean = Trimmed([clean substringFromIndex:prefix.length]);
        }
    }
    if (!clean.length) return nil;
    if (clean.length > 72) {
        NSRange safeRange = [clean rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 72)];
        clean = Trimmed([clean substringWithRange:safeRange]);
    }
    return clean.length ? clean : nil;
}

static NSString *PackAIModeForQuestion(NSString *question, NSUInteger selectedCount) {
    NSString *q = (question ?: @"").lowercaseString;
    if ([q containsString:@"contradict"] || [q containsString:@"disagree"] || [q containsString:@"unsupported"] || [q containsString:@"conflict"]) return @"contradictions";
    if ([q containsString:@"compare"] || [q containsString:@"difference"] || [q containsString:@"versus"] || [q containsString:@" vs "]) return @"compare";
    if ([q containsString:@"table"] || [q containsString:@"breakdown"] || [q containsString:@"numbers"] || [q containsString:@"cost"] || [q containsString:@"estimate"]) return @"table";
    if ([q containsString:@"summarize"] || [q containsString:@"summary"] || [q containsString:@"recap"] || [q containsString:@"remind me"]) return @"summarize";
    if ([q containsString:@"next"] || [q containsString:@"plan"] || [q containsString:@"todo"] || [q containsString:@"do next"] || [q containsString:@"action"]) return @"actions";
    if (selectedCount > 1) return @"compare";
    return @"ask";
}

static NSString *PackAIModeLabel(NSString *mode) {
    if ([mode isEqualToString:@"compare"]) return @"compare mode";
    if ([mode isEqualToString:@"contradictions"]) return @"claim check mode";
    if ([mode isEqualToString:@"table"]) return @"table mode";
    if ([mode isEqualToString:@"summarize"]) return @"summary mode";
    if ([mode isEqualToString:@"actions"]) return @"action mode";
    return @"ask mode";
}

static NSString *PackAIModeSymbol(NSString *mode) {
    if ([mode isEqualToString:@"compare"]) return @"arrow.left.arrow.right";
    if ([mode isEqualToString:@"contradictions"]) return @"exclamationmark.triangle";
    if ([mode isEqualToString:@"table"]) return @"tablecells";
    if ([mode isEqualToString:@"summarize"]) return @"text.alignleft";
    if ([mode isEqualToString:@"actions"]) return @"checklist";
    return @"bubble.left.fill";
}

static NSString *PackAIModeInstructions(NSString *mode) {
    if ([mode isEqualToString:@"compare"]) return @"Compare only what the saved context supports. Group the answer by agreement, differences, conflicts, and takeaway. Use a compact table only if it makes the comparison easier.";
    if ([mode isEqualToString:@"contradictions"]) return @"Find unsupported claims, conflicting numbers, missing evidence, and assumptions. Be direct, but do not exaggerate gaps.";
    if ([mode isEqualToString:@"table"]) return @"Extract concrete values, entities, dates, costs, estimates, and source names into a compact table. Put 'unknown' where the context does not say.";
    if ([mode isEqualToString:@"summarize"]) return @"Summarize what matters, why it matters, and what should be remembered later. Keep it short and useful.";
    if ([mode isEqualToString:@"actions"]) return @"Return a short next-step plan. Prioritize 3-5 actions and tie each one to the saved context when possible.";
    return @"Answer naturally from the saved context. Be concise. Cite item titles when useful. Say when the Pack does not contain enough evidence.";
}

static NSString *StripModelThinking(NSString *text) {
    NSMutableString *clean = [NSMutableString stringWithString:text ?: @""];
    NSRegularExpression *thinkingBlock = [NSRegularExpression regularExpressionWithPattern:@"(?is)<think>.*?</think>" options:0 error:nil];
    [thinkingBlock replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    NSRegularExpression *qwenThinkingBlock = [NSRegularExpression regularExpressionWithPattern:@"(?is)^\\s*Thinking\\.\\.\\..*?\\.\\.\\.done thinking\\.\\s*" options:0 error:nil];
    [qwenThinkingBlock replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    NSRegularExpression *qwenThinkingMarker = [NSRegularExpression regularExpressionWithPattern:@"(?im)^\\s*Thinking\\.\\.\\.\\s*" options:0 error:nil];
    [qwenThinkingMarker replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    return Trimmed(clean);
}

// Pack AI uses a local Ollama model. It should feel like a quiet research
// tool, not a chat demo: grounded, concise, and private to this Mac.
// deepseek-r1:8b — similar footprint to the old llama3.1:8b (fast on this
// Mac's 18GB), but reasoning-distilled from R1. qwen3:14b measured ~79s for
// a realistic Pack-context question under normal memory pressure here,
// which left almost no margin under the old 90s timeout.
static NSString *const kLPPOllamaModel = @"deepseek-r1:8b";

// Takes the full conversation so far (system + every prior turn) since
// Ollama's /api/chat is stateless — there's no server-side session, so a
// follow-up question only has context if we resend the whole transcript.
static void CallLocalModel(NSArray<NSDictionary *> *messages, void (^completion)(NSString * _Nullable text, NSString * _Nullable error)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost:11434/api/chat"]];
    request.HTTPMethod = @"POST";
    // Generous on purpose — a slower model or a bigger Pack should degrade
    // to "takes a while" in the UI, never a silent, wrong-looking failure.
    request.timeoutInterval = 240;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"model": kLPPOllamaModel,
        @"stream": @NO,
        @"messages": messages,
        @"options": @{
            @"temperature": @0.2,
            @"top_p": @0.85,
            @"repeat_penalty": @1.08,
            @"num_ctx": @8192
        }
    };
    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, jsonError.localizedDescription); });
        return;
    }

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, @"Local AI is not running. Start Ollama, then ask again.");
                return;
            }
            NSInteger statusCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (statusCode != 200) {
                NSString *message = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode];
                if ([message localizedCaseInsensitiveContainsString:@"not found"] ||
                    [message localizedCaseInsensitiveContainsString:@"pull model"]) {
                    message = [NSString stringWithFormat:@"%@ is not installed yet. Run \"ollama pull %@\", then ask again.", kLPPOllamaModel, kLPPOllamaModel];
                }
                completion(nil, message);
                return;
            }
            id messageContent = [json[@"message"] isKindOfClass:NSDictionary.class] ? json[@"message"][@"content"] : nil;
            NSString *text = [messageContent isKindOfClass:NSString.class] ? messageContent : nil;
            NSString *clean = StripModelThinking(text);
            completion(clean.length ? clean : @"No answer returned.", nil);
        });
    }];
    [task resume];
}

// Bounded, best-effort summary of everything in a Pack for the AI prompt —
// capped per-asset and in total asset count so a large Pack doesn't blow
// past a reasonable prompt size (or cost) on every question.
static NSString *PackContextSummaryForAssets(NSArray<NSMutableDictionary *> *assets);

// Cheap keyword-overlap relevance, no ML needed: this is what actually
// makes "the model understands my Pack" scale past the ~60-asset cap —
// picking the assets that match what's being asked instead of just
// whichever 60 happen to sort first (== most recently added).
static NSSet<NSString *> *TokenizeForRelevance(NSString *text) {
    if (!text.length) return [NSSet set];
    static NSSet<NSString *> *stopwords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stopwords = [NSSet setWithArray:@[
            @"the", @"a", @"an", @"is", @"are", @"was", @"were", @"of", @"to", @"in", @"on",
            @"for", @"and", @"or", @"what", @"which", @"who", @"whom", @"this", @"that",
            @"these", @"those", @"with", @"do", @"does", @"did", @"me", @"my", @"i", @"it",
            @"be", @"has", @"have", @"had", @"about", @"can", @"you", @"your", @"all"
        ]];
    });
    NSMutableSet<NSString *> *tokens = [NSMutableSet set];
    NSCharacterSet *nonAlnum = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    for (NSString *word in [text.lowercaseString componentsSeparatedByCharactersInSet:nonAlnum]) {
        if (word.length >= 3 && ![stopwords containsObject:word]) [tokens addObject:word];
    }
    return tokens;
}

static NSString *PackContextSummary(NSDictionary *pack, NSString *question) {
    NSArray<NSMutableDictionary *> *assets = [pack[@"assets"] isKindOfClass:NSArray.class] ? pack[@"assets"] : @[];
    NSSet<NSString *> *questionTokens = TokenizeForRelevance(question);

    // Small Pack, or nothing to rank against: plain order is already fine.
    if (!questionTokens.count || assets.count <= 60) {
        return PackContextSummaryForAssets(assets);
    }

    NSMutableArray<NSDictionary *> *scored = [NSMutableArray arrayWithCapacity:assets.count];
    for (NSMutableDictionary *asset in assets) {
        NSString *combined = [NSString stringWithFormat:@"%@ %@", asset[@"title"] ?: @"", TextSampleForAsset(asset) ?: @""];
        NSMutableSet<NSString *> *overlap = [TokenizeForRelevance(combined) mutableCopy];
        [overlap intersectSet:questionTokens];
        [scored addObject:@{ @"asset": asset, @"score": @(overlap.count) }];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult byScore = [b[@"score"] compare:a[@"score"]];
        if (byScore != NSOrderedSame) return byScore;
        NSNumber *aTime = [a[@"asset"][@"addedAt"] isKindOfClass:NSNumber.class] ? a[@"asset"][@"addedAt"] : @0;
        NSNumber *bTime = [b[@"asset"][@"addedAt"] isKindOfClass:NSNumber.class] ? b[@"asset"][@"addedAt"] : @0;
        return [bTime compare:aTime];
    }];

    NSMutableArray<NSMutableDictionary *> *ranked = [NSMutableArray arrayWithCapacity:assets.count];
    for (NSDictionary *entry in scored) [ranked addObject:entry[@"asset"]];
    return PackContextSummaryForAssets(ranked);
}

static NSString *PackContextSummaryForAssets(NSArray<NSMutableDictionary *> *assets) {
    NSMutableString *summary = [NSMutableString string];
    NSInteger maxAssets = 60;
    NSInteger included = 0;
    for (NSMutableDictionary *asset in assets) {
        if (included >= maxAssets) break;
        NSString *title = asset[@"title"] ?: @"Untitled";
        NSString *kind = asset[@"kind"] ?: @"File";
        NSString *uploader = asset[@"uploader"] ?: @"Unknown";
        NSString *status = asset[@"status"] ?: @"Reference";
        NSTimeInterval addedAt = [asset[@"addedAt"] isKindOfClass:NSNumber.class] ? [asset[@"addedAt"] doubleValue] : 0;
        NSString *dateStr = addedAt > 0
            ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:addedAt] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]
            : @"unknown date";
        NSString *sample = TextSampleForAsset(asset);
        if (sample.length > 240) sample = [[sample substringToIndex:240] stringByAppendingString:@"…"];
        [summary appendFormat:@"- [%@] \"%@\" — added by %@ on %@, status: %@%@\n", kind, title, uploader, dateStr, status,
            sample.length ? [NSString stringWithFormat:@"\n  content: %@", sample] : @""];
        included++;
    }
    if ((NSInteger)assets.count > maxAssets) {
        [summary appendFormat:@"\n(+ %lu more items not shown)\n", (unsigned long)(assets.count - maxAssets)];
    }
    return summary;
}

// A plain NSTableView's cells don't get the standard text-services context
// menu (Search With Google, Look Up, …) that NSTextView gives you for free —
// LPPSpreadsheetTableView (defined after AppController's @interface, below,
// since it needs to call a method on it) adds the equivalent for spreadsheet
// cells specifically, since looking a value up (e.g. a company name from an
// uploaded sheet) is the whole point of being able to see the data at all.
@interface LPPSpreadsheetTableView : NSTableView
@property(nonatomic, weak) AppController *controller;
@end

@interface AppController : NSObject <NSApplicationDelegate, FocusPanelController, LiveClipCaptureController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>
@property NSPanel *panel;
@property NSPanel *tabPanel;
@property NSStatusItem *statusItem;
@property DropShelfView *rootView;
@property CompactTabView *compactTabView;
@property NSStackView *packStack;
@property NSStackView *assetStack;
@property NSStackView *activityStack;
@property NSSearchField *searchField;
@property NSTextField *quickAddNoteField;
@property NSSegmentedControl *viewSwitch;
@property NSMutableArray<NSMutableDictionary *> *packs;
@property NSMutableArray<NSMutableDictionary *> *activity;
@property NSInteger selectedPackIndex;
@property BOOL boardMode;
@property BOOL loggedIn;
@property BOOL panelPinned;
@property BOOL voltAnimated;
@property NSScrollView *assetScrollView;
@property NSString *assetFilter;
@property NSString *userEmail;
@property NSTextField *emailField;
@property NSTextField *inviteField;
@property NSString *listSignature;
@property NSString *loginError;
@property NSString *searchQuery;
@property BOOL searchActive;
@property NSString *transientNotice;
@property NSMutableOrderedSet<NSString *> *selectedAssetIDs;
@property NSString *selectionAnchorID;
@property NSString *selectionCursorID;
@property NSMutableArray<AssetTile *> *visibleAssetTiles;
@property NSPanel *previewPanel;
@property NSMutableDictionary *previewedAsset;
@property NSURL *previewedQRURL;
@property NSTextView *previewNoteTextView;
@property NSTimer *previewNoteSaveTimer;
@property NSPanel *composeNotePanel;
@property NSTextField *composeNoteTitleField;
@property NSTextView *composeNoteBodyView;
@property NSPanel *explainPanel;
@property NSPanel *askAIPanel;
@property NSTextView *askAIAnswerView;
@property NSTextField *askAIQuestionView;
@property NSMutableArray<NSDictionary *> *askAIMessages;
@property BOOL askAIWaitingForResponse;
@property NSArray<NSString *> *askAIContextAssetIDs;
@property NSString *askAIMode;
@property NSImageView *askAIModeIconView;
@property NSTextField *askAIStatusLabel;
@property NSView *askAIContentView;
@property NSView *askAIRimGlowView;
@property NSTimer *askAIPanelSaveFrameTimer;
@property NSImageView *askAIAvatarView;
@property NSMutableArray<NSString *> *askAIQuickPrompts;
@property NSTimer *askAITypewriterTimer;
@property NSString *askAITypewriterMessageID;
@property NSUInteger askAITypewriterVisibleLength;
@property NSView *askAIEmptyStateView;
@property NSTimer *askAICursorBlinkTimer;
@property BOOL askAICursorBlinkOn;
@property NSArray<id<PackCharacterProvider>> *characters;
@property NSPanel *characterPanel;
@property NSArray<NSDictionary *> *previewSpreadsheetSheets;
@property NSInteger previewSpreadsheetActiveSheet;
@property NSTableView *previewSpreadsheetTable;
@property NSStackView *previewSpreadsheetTabsStack;
@property NSMutableDictionary *undoPack;
@property NSArray<NSDictionary *> *lastDeletedAssetRecords;
@property NSString *undoToken;
@property NSString *undoNotice;
@property NSPopover *membersPopover;
@property EventHotKeyRef hotKeyRef;
@property EventHotKeyRef liveClipHotKeyRef;
@property EventHotKeyRef scoutHotKeyRef;
@property EventHandlerRef eventHandler;
@property NSMutableArray<NSPanel *> *liveClipCapturePanels;
@property NSDictionary *liveClipSourceContext;
@property NSMutableDictionary *relocatingLiveClipAsset;
- (NSMutableDictionary *)addAssetWithTitle:(NSString *)title kind:(NSString *)kind source:(NSString *)source uploader:(NSString *)uploader;
- (NSMutableDictionary *)addAssetWithTitle:(NSString *)title kind:(NSString *)kind filePath:(NSString *)filePath originURL:(NSURL *)originURL uploader:(NSString *)uploader;
- (BOOL)addFromPasteboard:(NSPasteboard *)pasteboard;
- (NSURL *)storeFileInSelectedPack:(NSURL *)url;
- (void)uploadFile:(id)sender;
- (void)paste:(id)sender;
- (void)grabLink:(id)sender;
- (void)savePhotoFromLink:(id)sender;
- (void)savePhotoFromAsset:(NSDictionary *)asset;
- (void)savePhotoFromURL:(NSURL *)url;
- (void)showTransientNotice:(NSString *)notice;
- (void)beginLiveClipCapture:(id)sender;
- (void)cancelLiveClipCapture;
- (void)finishLiveClipSelectionFromView:(LiveClipCaptureView *)view mode:(NSString *)mode;
- (void)viewExtractedTextForSelectedClip:(id)sender;
- (void)copyExtractedTextForSelectedClip:(id)sender;
- (void)copyLiveClipValue:(id)sender;
- (void)copyLiveClipLabelAndValue:(id)sender;
- (void)copyLiveClipImage:(id)sender;
- (void)openSourceForAsset:(NSDictionary *)asset;
- (void)openSourceForSelectedLiveClip:(id)sender;
- (void)checkSelectedLiveClipForChanges:(id)sender;
- (void)refreshSelectedLiveClip:(id)sender;
- (void)relocateSelectedLiveClipSource:(id)sender;
- (void)applyLiveClipRefreshToAsset:(NSMutableDictionary *)asset image:(NSImage *)image relocated:(BOOL)relocated;
- (void)grabVisiblePhoto:(id)sender;
- (void)addWebURL:(NSURL *)url;
- (void)grabCurrentTab:(id)sender;
- (void)loadTitleForAsset:(NSMutableDictionary *)asset fromURL:(NSURL *)url;
- (void)handleDroppedWebURL:(NSURL *)url;
- (void)handleDroppedWebURL:(NSURL *)url originURL:(NSURL *)originURL;
- (BOOL)receivePromisedFilesFromPasteboard:(NSPasteboard *)pasteboard originURL:(NSURL *)originURL;
- (void)downloadImageFromURL:(NSURL *)url title:(NSString *)title;
- (void)downloadImageFromURL:(NSURL *)url title:(NSString *)title originURL:(NSURL *)originURL;
- (void)downloadImageFromURL:(NSURL *)url title:(NSString *)title originURL:(NSURL *)originURL remainingAttempts:(NSInteger)remainingAttempts;
- (void)requestAINameForAsset:(NSMutableDictionary *)asset placeholderTitle:(NSString *)placeholderTitle;
- (void)copyAsset:(NSDictionary *)asset;
- (void)copyLinkForAsset:(NSDictionary *)asset;
- (void)openAsset:(NSDictionary *)asset;
- (void)activateAsset:(NSMutableDictionary *)asset;
- (void)showPreviewForAsset:(NSMutableDictionary *)asset;
- (void)closePreview;
- (void)explainSelectedAsset:(id)sender;
- (void)showExplanationForAsset:(NSMutableDictionary *)asset;
- (void)showAskAIPanel:(id)sender;
- (void)renderAskAIPanelBody;
- (void)askAIPanelFrameDidChange:(NSNotification *)notification;
- (void)persistAskAIPanelFrame;
- (void)refreshAskAIRimGlow;
- (void)submitAskAIQuestion:(id)sender;
- (void)refreshAskAIConversationView;
- (void)askAISuggestionTapped:(NSButton *)sender;
- (void)tickAskAICursorBlink;
- (void)beginTypewriterForLatestAIMessage;
- (void)advanceAITypewriter:(NSTimer *)timer;
- (void)saveLatestAIResultToPack:(id)sender;
- (void)characterDockItemTapped:(NSButton *)sender;
- (NSMutableDictionary *)selectedPack;
- (void)beginScoutCapture:(id)sender;
- (void)saveScoutCapture:(NSString *)text fromApp:(NSRunningApplication *)sourceApp;
- (BOOL)configureSpreadsheetPreviewInContent:(NSView *)content mediaFrame:(NSRect)mediaFrame panelWidth:(CGFloat)panelWidth filePath:(NSString *)filePath;
- (void)selectSpreadsheetTabAtIndex:(NSInteger)index;
- (void)reloadSpreadsheetTableColumns;
- (NSMenu *)spreadsheetCellMenuForText:(NSString *)text;
- (BOOL)isAssetSelected:(NSDictionary *)asset;
- (void)selectAsset:(NSMutableDictionary *)asset modifiers:(NSEventModifierFlags)modifiers;
- (void)prepareAssetForContextMenu:(NSMutableDictionary *)asset;
- (void)clearAssetSelection;
- (NSMenu *)contextMenuForAsset:(NSMutableDictionary *)asset;
- (void)copySelectedAssets;
- (void)moveSelectedAssetsToTrash:(id)sender;
- (void)trashAssets:(NSArray<NSMutableDictionary *> *)assetsToTrash;
- (NSMutableDictionary *)assetInSelectedPackMatchingTitle:(NSString *)title;
- (NSString *)executeAskAIActionsInReply:(NSString *)reply;
- (NSString *)performAskAIActionFromJSON:(NSString *)jsonText;
- (void)undoLastDelete:(id)sender;
- (void)restoreSelectedAssets:(id)sender;
- (void)deletePermanentlySelectedAssets:(id)sender;
- (void)deleteAssetsPermanently:(NSArray<NSMutableDictionary *> *)assetsToDelete fromPack:(NSMutableDictionary *)pack confirm:(BOOL)confirm;
- (void)emptyTrashForCurrentPack:(id)sender;
- (BOOL)isFilePathUsedElsewhere:(NSString *)standardizedPath excluding:(NSMutableDictionary *)excludedAsset;
- (void)openURLWithSystemCommand:(NSURL *)url asset:(NSDictionary *)asset browserPath:(NSString *)browserPath;
- (void)finishOpeningAsset:(NSDictionary *)asset error:(NSError *)error;
- (NSString *)currentPackName;
- (NSUInteger)currentAssetCount;
- (void)showPanel;
- (void)togglePanel;
- (void)hidePanelAfterDrag;
- (void)saveCornerTabPosition;
- (void)showMembers:(id)sender;
- (void)showVoltQuickMenu:(id)sender;
- (void)createPack:(id)sender;
- (void)renameCurrentPack:(id)sender;
- (void)deleteCurrentPack:(id)sender;
- (void)showAddMenu:(id)sender;
- (NSArray<NSMenuItem *> *)addMenuItems;
- (void)showOverflowMenu:(id)sender;
- (void)signOut:(id)sender;
- (void)togglePanelPinned:(id)sender;
- (void)toggleVoltAnimation:(id)sender;
- (void)moveSelectionBy:(NSInteger)delta extend:(BOOL)extend;
- (void)filterChanged:(NSSegmentedControl *)sender;
- (void)loadPreviewForAsset:(NSMutableDictionary *)asset fromURL:(NSURL *)url;
- (NSURL *)storePreviewData:(NSData *)data extension:(NSString *)extension;
- (void)saveState;
- (void)render;
- (NSView *)emptyStateViewForWidth:(CGFloat)width height:(CGFloat)height filtered:(BOOL)filtered;
- (void)scrollAssetIntoView:(NSDictionary *)asset;
@end

@implementation LPPSpreadsheetTableView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:point];
    NSInteger column = [self columnAtPoint:point];
    if (row < 0 || column < 0 || column >= (NSInteger)self.tableColumns.count) return nil;
    id value = [self.dataSource tableView:self objectValueForTableColumn:self.tableColumns[column] row:row];
    NSString *text = [value isKindOfClass:NSString.class] ? value : nil;
    if (!text.length) return nil;
    return [self.controller spreadsheetCellMenuForText:text];
}
@end

// First real character (see PackCharacterProvider above). Organize/cleanup —
// its badge is the real Trash count, and tapping it opens a small panel with
// real actions (Empty Trash, Undo Last Delete) that reuse AppController's
// existing, already-tested trash-lifecycle methods rather than duplicating
// that logic. Placeholder SF Symbol icon for now — real mascot art (like
// Volt's) is a swap-in once there's illustration to match.
@interface ElectroCharacter : NSObject <PackCharacterProvider>
@end

@implementation ElectroCharacter {
    __weak AppController *_activeController;
    __weak NSPanel *_activePanel;
}

- (NSString *)characterIdentifier { return @"electro"; }
- (NSString *)characterName { return @"Electro"; }

- (NSImage *)characterIcon {
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightMedium];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"bolt.fill" accessibilityDescription:@"Electro"];
    image = [image imageWithSymbolConfiguration:config];
    image.template = YES;
    return image;
}

- (NSUInteger)trashCountForController:(AppController *)controller {
    NSDictionary *pack = [controller selectedPack];
    return [pack[@"trash"] isKindOfClass:NSArray.class] ? [(NSArray *)pack[@"trash"] count] : 0;
}

- (NSString *)characterBadgeTextForController:(AppController *)controller {
    NSUInteger trashCount = [self trashCountForController:controller];
    return trashCount > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)trashCount] : nil;
}

- (void)emptyTrashTapped:(id)sender {
    [_activeController emptyTrashForCurrentPack:sender];
    [_activePanel orderOut:nil];
}

- (void)undoDeleteTapped:(id)sender {
    [_activeController undoLastDelete:sender];
    [_activePanel orderOut:nil];
}

- (void)characterTappedWithController:(AppController *)controller anchorButton:(NSButton *)anchorButton {
    NSUInteger trashCount = [self trashCountForController:controller];

    CGFloat width = 300;
    CGFloat height = 190;
    NSScreen *screen = controller.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSPoint origin = NSMakePoint(NSMinX(controller.panel.frame), NSMaxY(controller.panel.frame) + 4);
    origin = ClampedPanelOrigin(origin, NSMakeSize(width, height), visibleFrame);

    FocusPanel *panel = [[FocusPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    panel.controller = controller;
    panel.title = @"Electro";
    panel.floatingPanel = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = VoltScreenColor();
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    ApplyVoltScreenChrome(content);
    panel.contentView = content;

    NSTextField *subtitle = [NSTextField labelWithString:@"Keeping this Pack tidy"];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor colorWithCalibratedWhite:0.65 alpha:1];
    subtitle.frame = NSMakeRect(18, height - 40, width - 36, 18);
    [content addSubview:subtitle];

    NSTextField *stat = [NSTextField wrappingLabelWithString:trashCount > 0
        ? [NSString stringWithFormat:@"%lu item%@ in Trash", (unsigned long)trashCount, trashCount == 1 ? @"" : @"s"]
        : @"Nothing needs cleaning up right now."];
    stat.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    stat.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    stat.frame = NSMakeRect(18, height - 92, width - 36, 44);
    [content addSubview:stat];

    _activeController = controller;
    _activePanel = panel;

    BOOL hasUndo = controller.lastDeletedAssetRecords.count > 0;
    if (hasUndo) {
        NSButton *undoButton = [NSButton buttonWithTitle:@"Undo Last Delete" target:self action:@selector(undoDeleteTapped:)];
        undoButton.bezelStyle = NSBezelStyleTexturedRounded;
        undoButton.frame = NSMakeRect(18, 54, width - 36, 30);
        [content addSubview:undoButton];
    }

    NSButton *emptyButton = [NSButton buttonWithTitle:@"Empty Trash" target:self action:@selector(emptyTrashTapped:)];
    emptyButton.bezelStyle = NSBezelStyleTexturedRounded;
    emptyButton.enabled = trashCount > 0;
    emptyButton.frame = NSMakeRect(18, 18, width - 36, 30);
    [content addSubview:emptyButton];

    controller.characterPanel = panel;
    [panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

@end

// Second character: research capture. Badge is the real count of
// Scout-captured Notes in this Pack (assets tagged "scoutSourceApp" by
// -saveScoutCapture:fromApp:). "Ask AI to Compare" reuses the whole
// "Ask AI about this Pack" panel/pipeline built earlier — it just opens it
// with a comparison-shaped question already typed and sent, since that's
// the actual point of collecting several research snippets in one place.
@interface ScoutCharacter : NSObject <PackCharacterProvider>
@end

@implementation ScoutCharacter {
    __weak AppController *_activeController;
    __weak NSPanel *_activePanel;
}

- (NSString *)characterIdentifier { return @"scout"; }
- (NSString *)characterName { return @"Scout"; }

- (NSImage *)characterIcon {
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightMedium];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"binoculars.fill" accessibilityDescription:@"Scout"];
    image = [image imageWithSymbolConfiguration:config];
    image.template = YES;
    return image;
}

- (NSArray<NSMutableDictionary *> *)capturesForController:(AppController *)controller {
    NSDictionary *pack = [controller selectedPack];
    NSArray<NSMutableDictionary *> *assets = [pack[@"assets"] isKindOfClass:NSArray.class] ? pack[@"assets"] : @[];
    NSMutableArray<NSMutableDictionary *> *captures = [NSMutableArray array];
    for (NSMutableDictionary *asset in assets) {
        if ([asset[@"scoutSourceApp"] isKindOfClass:NSString.class]) [captures addObject:asset];
    }
    return captures;
}

- (NSString *)characterBadgeTextForController:(AppController *)controller {
    NSUInteger count = [self capturesForController:controller].count;
    return count > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : nil;
}

- (void)captureNowTapped:(id)sender {
    AppController *controller = _activeController;
    [_activePanel orderOut:nil];
    [controller beginScoutCapture:sender];
}

- (void)compareTapped:(id)sender {
    AppController *controller = _activeController;
    [_activePanel orderOut:nil];
    [controller showAskAIPanel:sender];
    controller.askAIQuestionView.stringValue = @"Compare the research snippets I've captured and summarize the key differences and any agreement between them.";
    [controller submitAskAIQuestion:sender];
}

- (void)characterTappedWithController:(AppController *)controller anchorButton:(NSButton *)anchorButton {
    NSArray<NSMutableDictionary *> *captures = [self capturesForController:controller];

    CGFloat width = 300;
    CGFloat height = 190;
    NSScreen *screen = controller.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSPoint origin = NSMakePoint(NSMinX(controller.panel.frame), NSMaxY(controller.panel.frame) + 4);
    origin = ClampedPanelOrigin(origin, NSMakeSize(width, height), visibleFrame);

    FocusPanel *panel = [[FocusPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    panel.controller = controller;
    panel.title = @"Scout";
    panel.floatingPanel = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = VoltScreenColor();
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    ApplyVoltScreenChrome(content);
    panel.contentView = content;

    NSTextField *subtitle = [NSTextField labelWithString:@"Research captured with ⌥⇧S"];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor colorWithCalibratedWhite:0.65 alpha:1];
    subtitle.frame = NSMakeRect(18, height - 40, width - 36, 18);
    [content addSubview:subtitle];

    NSTextField *stat = [NSTextField wrappingLabelWithString:captures.count > 0
        ? [NSString stringWithFormat:@"%lu snippet%@ captured in this Pack", (unsigned long)captures.count, captures.count == 1 ? @"" : @"s"]
        : @"No research captured yet. Select text anywhere and press ⌥⇧S."];
    stat.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    stat.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    stat.frame = NSMakeRect(18, height - 92, width - 36, 44);
    [content addSubview:stat];

    _activeController = controller;
    _activePanel = panel;

    NSButton *captureButton = [NSButton buttonWithTitle:@"Capture Current Selection" target:self action:@selector(captureNowTapped:)];
    captureButton.bezelStyle = NSBezelStyleTexturedRounded;
    captureButton.frame = NSMakeRect(18, 54, width - 36, 30);
    [content addSubview:captureButton];

    NSButton *compareButton = [NSButton buttonWithTitle:@"Ask AI to Compare" target:self action:@selector(compareTapped:)];
    compareButton.bezelStyle = NSBezelStyleTexturedRounded;
    compareButton.enabled = captures.count >= 2;
    compareButton.toolTip = captures.count >= 2 ? @"" : @"Capture at least 2 snippets to compare them";
    compareButton.frame = NSMakeRect(18, 18, width - 36, 30);
    [content addSubview:compareButton];

    controller.characterPanel = panel;
    [panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

@end

@implementation AssetTile
- (instancetype)initWithAsset:(NSMutableDictionary *)asset controller:(AppController *)controller gridMode:(BOOL)gridMode {
    self = [super initWithFrame:gridMode ? NSMakeRect(0, 0, 172, 166) : NSMakeRect(0, 0, 354, 68)];
    if (!self) return nil;
    _asset = asset;
    _controller = controller;
    _gridMode = gridMode;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8;
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.14 alpha:0.9].CGColor;
    self.toolTip = asset[@"title"] ?: @"Asset";
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityButtonRole;
    self.accessibilityLabel = asset[@"title"] ?: @"Asset";
    self.accessibilityHelp = @"Click to select. Double-click to open.";

    NSRect previewFrame = gridMode ? NSMakeRect(6, 52, 160, 108) : NSMakeRect(7, 7, 58, 54);
    self.previewView = [[NSImageView alloc] initWithFrame:previewFrame];
    self.previewView.wantsLayer = YES;
    self.previewView.layer.cornerRadius = 6;
    self.previewView.layer.masksToBounds = YES;
    self.previewView.layer.backgroundColor = [MutedKindColor(asset[@"kind"]) colorWithAlphaComponent:0.1].CGColor;
    self.previewView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:self.previewView];

    NSImage *preview = ImmediatePreviewImage(asset);
    if (preview) {
        self.previewView.image = preview;
    } else {
        self.previewView.image = [NSImage imageWithSystemSymbolName:IconForKind(asset[@"kind"]) accessibilityDescription:nil];
        self.previewView.contentTintColor = MutedKindColor(asset[@"kind"]);
        self.previewView.imageScaling = NSImageScaleProportionallyDown;
    }

    NSString *filePath = AssetFilePath(asset);
    NSURL *originURL = AssetOriginURL(asset);
    BOOL isLink = originURL != nil;
    BOOL hasPreviewImage = [asset[@"kind"] isEqualToString:@"Image"] || [asset[@"preview"] length] > 0;
    CGFloat textX = gridMode ? 10 : 76;
    CGFloat textWidth = gridMode ? 148 : (isLink ? 202 : 232);
    NSTextField *title = [NSTextField labelWithString:asset[@"title"] ?: @"Untitled"];
    title.font = [NSFont systemFontOfSize:gridMode ? 12.5 : 13 weight:NSFontWeightSemibold];
    title.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.frame = gridMode ? NSMakeRect(textX, 29, textWidth, 17) : NSMakeRect(textX, 36, textWidth, 18);
    [self addSubview:title];

    if (IsLiveClip(asset)) {
        NSDictionary *clip = asset[@"liveClip"];
        NSDictionary *content = [clip[@"extractedContent"] isKindOfClass:NSDictionary.class] ? clip[@"extractedContent"] : @{};
        NSString *type = clip[@"contentType"];
        NSString *display = nil;
        if ([type isEqualToString:@"labeledValue"]) display = content[@"displayValue"];
        else if ([type isEqualToString:@"number"]) display = content[@"displayValue"];
        else if ([type isEqualToString:@"text"]) display = CollapsedWhitespace(content[@"text"] ?: @"");
        else if ([type isEqualToString:@"url"]) display = content[@"url"];
        if (display.length) {
            NSTextField *structured = [NSTextField labelWithString:display];
            structured.font = [NSFont systemFontOfSize:gridMode ? 11 : 12 weight:NSFontWeightMedium];
            structured.textColor = [NSColor colorWithCalibratedWhite:0.88 alpha:1];
            structured.lineBreakMode = NSLineBreakByTruncatingTail;
            structured.frame = gridMode ? NSMakeRect(textX, 46, textWidth, 16) : NSMakeRect(textX, 52, textWidth, 15);
            [self addSubview:structured];
        }
    }

    NSTextField *meta = [NSTextField labelWithString:AssetSubtitle(asset)];
    meta.textColor = [NSColor colorWithCalibratedWhite:0.62 alpha:1];
    meta.font = [NSFont systemFontOfSize:10.5];
    meta.lineBreakMode = NSLineBreakByTruncatingTail;
    meta.frame = gridMode ? NSMakeRect(textX, 10, textWidth, 15) : NSMakeRect(textX, 16, textWidth, 15);
    [self addSubview:meta];

    if ([asset[@"isNew"] boolValue]) {
        CGFloat dotX = isLink ? 285 : 313;
        NSView *dot = [[NSView alloc] initWithFrame:gridMode ? NSMakeRect(153, 36, 6, 6) : NSMakeRect(dotX, 31, 7, 7)];
        dot.wantsLayer = YES;
        dot.layer.cornerRadius = dot.frame.size.width / 2;
        dot.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.45 green:0.68 blue:0.52 alpha:1].CGColor;
        dot.toolTip = @"New";
        [self addSubview:dot];
    }

    CGFloat actionY = gridMode ? 130 : 21;
    CGFloat copyX = gridMode ? 108 : (isLink ? 298 : 326);
    self.duplicateButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:nil] target:self action:@selector(copyTapped:)];
    self.duplicateButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.duplicateButton.frame = NSMakeRect(copyX, actionY, 26, 26);
    self.duplicateButton.toolTip = hasPreviewImage ? @"Copy image" : (isLink ? @"Copy link" : @"Copy");
    [self addSubview:self.duplicateButton];

    if (isLink) {
        CGFloat openX = gridMode ? 136 : 326;
        self.openButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.up.right" accessibilityDescription:nil] target:self action:@selector(openTapped:)];
        self.openButton.bezelStyle = NSBezelStyleTexturedRounded;
        self.openButton.frame = NSMakeRect(openX, actionY, 26, 26);
        self.openButton.toolTip = @"Open link";
        [self addSubview:self.openButton];
    }

    if (filePath.length) {
        NSString *cacheKey = ThumbnailCacheKey(filePath, previewFrame.size);
        NSImage *cached = [ThumbnailCache() objectForKey:cacheKey];
        if (cached) {
            self.previewView.image = cached;
            self.previewView.contentTintColor = nil;
            self.previewView.imageScaling = NSImageScaleProportionallyUpOrDown;
        } else {
            NSURL *fileURL = [NSURL fileURLWithPath:filePath];
            QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:fileURL size:previewFrame.size scale:NSScreen.mainScreen.backingScaleFactor representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
            __weak AssetTile *weakSelf = self;
            [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:request completionHandler:^(QLThumbnailRepresentation *representation, NSError *error) {
                NSImage *image = representation.NSImage;
                if (!image || error) return;
                [ThumbnailCache() setObject:image forKey:cacheKey];
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.previewView.image = image;
                    weakSelf.previewView.contentTintColor = nil;
                    weakSelf.previewView.imageScaling = NSImageScaleProportionallyUpOrDown;
                });
            }];
        }
    }
    [self refreshInteractionState];
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    [self refreshInteractionState];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self refreshInteractionState];
}

- (void)refreshInteractionState {
    BOOL selected = [self.controller isAssetSelected:self.asset];
    // A flat, saturated gold fill read as a UI-kit "selected" block rather
    // than anything belonging to this surface. A pale warm tint plus a
    // thin amber rim and a soft glow around the card itself reads instead
    // as the card lighting up from within — "illuminated glass," not a
    // colored rectangle stamped on top.
    NSColor *background = selected
        ? [NSColor colorWithCalibratedRed:0.70 green:0.80 blue:0.98 alpha:0.16]
        : [NSColor colorWithCalibratedWhite:0.14 alpha:(self.hovered ? 1 : 0.9)];
    self.layer.backgroundColor = background.CGColor;
    self.layer.borderWidth = selected ? 1 : 0;
    self.layer.borderColor = selected ? [PackRimAmberColor() colorWithAlphaComponent:0.55].CGColor : nil;
    self.layer.shadowColor = PackRimAmberColor().CGColor;
    self.layer.shadowRadius = selected ? 10 : 0;
    self.layer.shadowOpacity = selected ? 0.45 : 0;
    self.layer.shadowOffset = CGSizeZero;
    BOOL hideActions = !selected && !self.hovered;
    self.duplicateButton.hidden = hideActions;
    self.openButton.hidden = hideActions;
    self.accessibilitySelected = selected;
}

- (void)copyTapped:(id)sender {
    [self.controller copyAsset:self.asset];
}

- (void)openTapped:(id)sender {
    [self.controller openAsset:self.asset];
}

- (void)copyLinkTapped:(id)sender {
    [self.controller copyLinkForAsset:self.asset];
}

- (void)savePhotoTapped:(id)sender {
    [self.controller savePhotoFromAsset:self.asset];
}

- (void)mouseDown:(NSEvent *)event {
    self.dragStarted = NO;
    self.mouseDownPoint = [self convertPoint:event.locationInWindow fromView:nil];
    [self.controller selectAsset:self.asset modifiers:event.modifierFlags];
}

- (NSView *)hitTest:(NSPoint)point {
    NSPoint localPoint = AssetLocalPoint(point, self.frame, self.bounds);
    if (!NSPointInRect(localPoint, self.bounds)) return nil;
    if (self.duplicateButton && !self.duplicateButton.hidden && NSPointInRect(localPoint, self.duplicateButton.frame)) return self.duplicateButton;
    if (self.openButton && !self.openButton.hidden && NSPointInRect(localPoint, self.openButton.frame)) return self.openButton;
    return self;
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.dragStarted && event.clickCount >= 2 && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) {
        [self.controller activateAsset:self.asset];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.dragStarted) return;
    NSPoint currentPoint = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat deltaX = currentPoint.x - self.mouseDownPoint.x;
    CGFloat deltaY = currentPoint.y - self.mouseDownPoint.y;
    if (deltaX * deltaX + deltaY * deltaY < 16) return;
    self.dragStarted = YES;
    BOOL usePreview = NSPointInRect(self.mouseDownPoint, self.previewView.frame);
    id<NSPasteboardWriting> writer = AssetDragWriter(self.asset, usePreview);
    if (!writer) return;

    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:writer];
    NSBitmapImageRep *representation = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    [self cacheDisplayInRect:self.bounds toBitmapImageRep:representation];
    NSImage *dragImage = [[NSImage alloc] initWithSize:self.bounds.size];
    [dragImage addRepresentation:representation];
    [dragItem setDraggingFrame:self.bounds contents:dragImage];
    NSDraggingSession *session = [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    if (operation != NSDragOperationNone) [self.controller hidePanelAfterDrag];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    [self.controller prepareAssetForContextMenu:self.asset];
    return [self.controller contextMenuForAsset:self.asset];
}
@end

@implementation AssetCanvasView
- (void)mouseDown:(NSEvent *)event {
    [self.controller clearAssetSelection];
    [super mouseDown:event];
}
@end

@implementation MascotDropImageView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.editable = NO;
        self.allowsCutCopyPaste = NO;
        _restFrame = frameRect;
        _gestureKind = VoltGestureNone;
        [self registerForDraggedTypes:AcceptedDropTypes()];
    }
    return self;
}

- (void)dealloc {
    [_idleTimer invalidate];
}

- (void)setRestFrame:(NSRect)restFrame {
    _restFrame = restFrame;
    if (!self.idleAnimating) self.frame = restFrame;
}

- (void)startIdleAnimation {
    self.idleAnimating = YES;
    if (self.idleTimer) return;
    self.animationClock = 0;
    self.gestureKind = VoltGestureNone;
    self.nextGestureAt = 6.0 + (arc4random_uniform(700) / 100.0);
    __weak MascotDropImageView *weakSelf = self;
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf tickIdleAnimation];
    }];
}

- (void)stopIdleAnimation {
    self.idleAnimating = NO;
    [self.idleTimer invalidate];
    self.idleTimer = nil;
    self.gestureKind = VoltGestureNone;
    self.frame = self.restFrame;
}

- (void)tickIdleAnimation {
    self.animationClock += 1.0 / 30.0;
    if (self.gestureKind != VoltGestureNone && self.animationClock - self.gestureStart >= VoltGestureDuration) {
        self.gestureKind = VoltGestureNone;
    }
    if (self.gestureKind == VoltGestureNone && self.animationClock >= self.nextGestureAt) {
        [self playGesture:(NSInteger)arc4random_uniform(3)];
        self.nextGestureAt = self.animationClock + 6.0 + (arc4random_uniform(700) / 100.0);
    }
    NSTimeInterval elapsed = self.gestureKind == VoltGestureNone ? -1 : self.animationClock - self.gestureStart;
    self.frame = VoltIdleFrame(self.restFrame, self.animationClock, elapsed, self.gestureKind);
}

- (void)playGesture:(NSInteger)kind {
    self.gestureKind = kind;
    self.gestureStart = self.animationClock;
}

- (void)playCatchPop {
    [self playGesture:VoltGestureSquash];
}

- (void)playSuccessHop {
    [self playGesture:VoltGestureHop];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self.dropTarget draggingEntered:sender]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self.dropTarget draggingUpdated:sender]; }
- (void)draggingExited:(id<NSDraggingInfo>)sender { [self.dropTarget draggingExited:sender]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return [self.dropTarget prepareForDragOperation:sender]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { return [self.dropTarget performDragOperation:sender]; }
@end

@implementation DropShelfView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self registerForDraggedTypes:AcceptedDropTypes()];
    }
    return self;
}

- (void)showDropOverlay {
    if (self.dropOverlay) return;
    NSVisualEffectView *overlay = GlassBackdrop(self.bounds, 20, NSVisualEffectMaterialHUDWindow);
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.06 green:0.14 blue:0.11 alpha:0.3].CGColor;
    overlay.layer.borderWidth = 1.5;
    overlay.layer.borderColor = [NSColor colorWithCalibratedRed:0.45 green:0.68 blue:0.52 alpha:0.55].CGColor;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect((self.bounds.size.width - 40) / 2, (self.bounds.size.height - 40) / 2 + 18, 40, 40)];
    icon.image = [NSImage imageWithSystemSymbolName:@"tray.and.arrow.down.fill" accessibilityDescription:nil];
    icon.contentTintColor = [NSColor colorWithCalibratedRed:0.45 green:0.68 blue:0.52 alpha:1];
    [overlay addSubview:icon];

    NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"Drop into %@", self.controller.currentPackName]];
    label.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    label.textColor = NSColor.whiteColor;
    label.alignment = NSTextAlignmentCenter;
    label.frame = NSMakeRect(20, (self.bounds.size.height - 40) / 2 - 20, self.bounds.size.width - 40, 22);
    [overlay addSubview:label];
    [self addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    self.dropOverlay = overlay;
}

- (void)hideDropOverlay {
    [self.dropOverlay removeFromSuperview];
    self.dropOverlay = nil;
}

- (NSView *)hitTest:(NSPoint)point {
    if (self.dropOverlay) return self;
    return [super hitTest:point];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSDragOperation operation = AcceptedDragOperation(sender);
    if (operation != NSDragOperationNone) [self showDropOverlay];
    return operation;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return AcceptedDragOperation(sender); }
- (void)draggingExited:(id<NSDraggingInfo>)sender { [self hideDropOverlay]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return AcceptedDragOperation(sender) != NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    BOOL added = [self.controller addFromPasteboard:sender.draggingPasteboard];
    [self hideDropOverlay];
    return added;
}
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        [self.controller uploadFile:self];
        return;
    }
    [self.controller clearAssetSelection];
    [super mouseDown:event];
}
@end

@implementation CompactTabView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    [self registerForDraggedTypes:AcceptedDropTypes()];

    self.idleMascot = BundledPNG(@"volt-mascot-idle");
    self.catchMascot = BundledPNG(@"volt-mascot-catching");
    self.successMascot = BundledPNG(@"volt-mascot-success");
    self.mascotView = [[MascotDropImageView alloc] initWithFrame:NSMakeRect(16, 13, 71, 66)];
    self.mascotView.dropTarget = self;
    self.mascotView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.mascotView.imageAlignment = NSImageAlignCenter;
    self.mascotView.image = self.idleMascot;
    self.mascotView.toolTip = @"Drag Volt to move. Drop a file to save it.";
    [self addSubview:self.mascotView];
    return self;
}

- (void)setController:(AppController *)controller {
    _controller = controller;
    [self refresh];
}

- (BOOL)voltAnimationsOn {
    if (!self.controller) return NO;
    return ShouldAnimateVolt(self.controller.voltAnimated, NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);
}

- (void)refresh {
    if (!self.controller) return;
    self.mascotView.image = self.idleMascot ?: AppIconImage();
    self.mascotView.restFrame = NSMakeRect(16, 13, 71, 66);
    self.mascotView.toolTip = [NSString stringWithFormat:@"%@. Click to open. Right-click for actions. Drop to save.", self.controller.currentPackName];
    if ([self voltAnimationsOn]) [self.mascotView startIdleAnimation];
    else [self.mascotView stopIdleAnimation];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSDragOperation operation = AcceptedDragOperation(sender);
    if (operation != NSDragOperationNone) {
        self.mascotView.image = self.catchMascot ?: self.idleMascot;
        self.mascotView.restFrame = NSMakeRect(14, 13, 75, 65);
        self.mascotView.toolTip = [NSString stringWithFormat:@"Drop into %@", self.controller.currentPackName];
        if ([self voltAnimationsOn]) [self.mascotView playCatchPop];
    }
    return operation;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return AcceptedDragOperation(sender); }
- (void)draggingExited:(id<NSDraggingInfo>)sender { [self refresh]; }
- (BOOL)wantsPeriodicDraggingUpdates { return YES; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return AcceptedDragOperation(sender) != NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    BOOL added = [self.controller addFromPasteboard:sender.draggingPasteboard];
    if (!added) {
        [self.controller showTransientNotice:@"Could not read that drop"];
        [self refresh];
        return NO;
    }
    self.mascotView.image = self.successMascot ?: self.idleMascot;
    self.mascotView.restFrame = NSMakeRect(16, 13, 71, 66);
    self.mascotView.toolTip = @"Saved";
    if ([self voltAnimationsOn]) [self.mascotView playSuccessHop];
    __weak CompactTabView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf refresh];
    });
    return added;
}

- (NSView *)hitTest:(NSPoint)point {
    if (!NSPointInRect(point, self.bounds)) return nil;
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}

- (void)mouseDown:(NSEvent *)event {
    self.movingWindow = NO;
    self.movementStartScreenPoint = NSEvent.mouseLocation;
    self.movementStartWindowOrigin = self.window.frame.origin;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint currentPoint = NSEvent.mouseLocation;
    CGFloat deltaX = currentPoint.x - self.movementStartScreenPoint.x;
    CGFloat deltaY = currentPoint.y - self.movementStartScreenPoint.y;
    if (!self.movingWindow && deltaX * deltaX + deltaY * deltaY < 16) return;

    self.movingWindow = YES;
    [NSCursor.closedHandCursor set];
    NSPoint proposed = NSMakePoint(
        self.movementStartWindowOrigin.x + deltaX,
        self.movementStartWindowOrigin.y + deltaY
    );
    NSScreen *screen = ScreenContainingPoint(currentPoint) ?: self.window.screen ?: NSScreen.mainScreen;
    if (screen) proposed = ClampedPanelOrigin(proposed, self.window.frame.size, screen.visibleFrame);
    [self.window setFrameOrigin:proposed];
}

- (void)mouseUp:(NSEvent *)event {
    if (self.movingWindow) {
        self.movingWindow = NO;
        [NSCursor.openHandCursor set];
        [self.controller saveCornerTabPosition];
        return;
    }
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self.controller showVoltQuickMenu:self];
        return;
    }
    [self.controller togglePanel];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self.controller showVoltQuickMenu:self];
}
@end

@implementation AppController
// A menu-bar-less accessory app has no main menu at all, and Cmd+C/V/X/A/Z
// in a text field are routed through the Edit menu's key equivalents — so
// with none installed, copy/paste/select-all/undo silently did nothing in
// every text view. The menu is never shown; it just owns the shortcuts.
- (void)installEditMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    appItem.submenu = [[NSMenu alloc] initWithTitle:@"Packs"];
    [mainMenu addItem:appItem];

    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSArray *entries = @[
        @[@"Undo", @"undo:", @"z", @0],
        @[@"Redo", @"redo:", @"z", @(NSEventModifierFlagCommand | NSEventModifierFlagShift)],
        @[@"Cut", @"cut:", @"x", @0],
        @[@"Copy", @"copy:", @"c", @0],
        @[@"Paste", @"paste:", @"v", @0],
        @[@"Select All", @"selectAll:", @"a", @0],
    ];
    for (NSArray *entry in entries) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
        if ([entry[3] unsignedIntegerValue]) item.keyEquivalentModifierMask = [entry[3] unsignedIntegerValue];
        [edit addItem:item];
    }
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    editItem.submenu = edit;
    [mainMenu addItem:editItem];
    NSApp.mainMenu = mainMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    [self installEditMenu];
    NSApp.applicationIconImage = AppIconImage();
    LPPLog(@"app.launch", @{ @"version": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"development" });
    [self seedData];
    [self buildPanel];
    [self buildCornerTab];
    [self buildMenuBar];
    [self registerHotKey];
    [self render];
}

- (void)seedData {
    self.selectedPackIndex = 0;
    self.boardMode = NO;
    self.loggedIn = NO;
    self.voltAnimated = YES;
    self.assetFilter = @"All";
    self.searchQuery = @"";
    self.activity = [NSMutableArray array];
    self.selectedAssetIDs = [NSMutableOrderedSet orderedSet];
    self.visibleAssetTiles = [NSMutableArray array];
    self.characters = @[];
    if (![self loadState]) {
        self.packs = [@[
            [@{@"id": NSUUID.UUID.UUIDString, @"name": @"Case Competition", @"summary": @"", @"teammates": [NSMutableArray array], @"assets": [NSMutableArray array], @"trash": [NSMutableArray array]} mutableCopy]
        ] mutableCopy];
    }
}

- (NSURL *)stateURL {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [support URLByAppendingPathComponent:@"LiveProjectPacks" isDirectory:YES];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) LPPLog(@"state.directory_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
    return [root URLByAppendingPathComponent:@"state.json"];
}

- (BOOL)loadState {
    NSURL *url = [self stateURL];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length) return NO;

    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error || ![value isKindOfClass:NSDictionary.class]) {
        LPPLog(@"state.load_failed", @{ @"error": error.localizedDescription ?: @"invalid state" });
        return NO;
    }
    NSDictionary *state = value;
    NSArray *storedPacks = state[@"packs"];
    if (![storedPacks isKindOfClass:NSArray.class] || !storedPacks.count) return NO;

    NSMutableArray<NSMutableDictionary *> *loadedPacks = [NSMutableArray array];
    for (id rawPack in storedPacks) {
        if (![rawPack isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *pack = [rawPack mutableCopy];
        if (![pack[@"id"] isKindOfClass:NSString.class] || ![pack[@"id"] length]) pack[@"id"] = NSUUID.UUID.UUIDString;
        if (![pack[@"name"] isKindOfClass:NSString.class] || ![pack[@"name"] length]) pack[@"name"] = @"Pack";

        NSArray *rawTeammates = [pack[@"teammates"] isKindOfClass:NSArray.class] ? pack[@"teammates"] : @[];
        NSMutableArray *teammates = [NSMutableArray array];
        for (id teammate in rawTeammates) {
            if ([teammate isKindOfClass:NSString.class] && [teammate length]) [teammates addObject:teammate];
        }
        pack[@"teammates"] = teammates;

        NSArray *rawAssets = [pack[@"assets"] isKindOfClass:NSArray.class] ? pack[@"assets"] : @[];
        NSMutableArray *assets = [NSMutableArray array];
        for (id rawAsset in rawAssets) {
            if (![rawAsset isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *asset = [rawAsset mutableCopy];
            if (![asset[@"id"] isKindOfClass:NSString.class] || ![asset[@"id"] length]) asset[@"id"] = NSUUID.UUID.UUIDString;
            if (![asset[@"title"] isKindOfClass:NSString.class] || ![asset[@"title"] length]) asset[@"title"] = @"Untitled asset";
            if (![asset[@"kind"] isKindOfClass:NSString.class] || ![asset[@"kind"] length]) asset[@"kind"] = @"File";
            if (![asset[@"uploader"] isKindOfClass:NSString.class] || ![asset[@"uploader"] length]) asset[@"uploader"] = @"You";
            if (![asset[@"addedAt"] isKindOfClass:NSNumber.class]) asset[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);

            NSString *filePath = AssetFilePath(asset);
            NSURL *originURL = AssetOriginURL(asset);
            NSString *payload = AssetPayload(asset);
            if (filePath.length) asset[@"filePath"] = filePath;
            if (originURL) asset[@"originURL"] = originURL.absoluteString;
            if (payload.length) asset[@"payload"] = payload;
            if ([asset[@"kind"] isEqualToString:@"LiveClip"]) {
                NSMutableDictionary *clip = [asset[@"liveClip"] isKindOfClass:NSDictionary.class] ? [asset[@"liveClip"] mutableCopy] : [NSMutableDictionary dictionary];
                if (![clip[@"id"] isKindOfClass:NSString.class]) clip[@"id"] = asset[@"id"];
                if (![clip[@"packID"] isKindOfClass:NSString.class]) clip[@"packID"] = pack[@"id"] ?: @"";
                if (![clip[@"mode"] isKindOfClass:NSString.class]) clip[@"mode"] = @"Keep";
                if (![clip[@"capturedImage"] isKindOfClass:NSString.class] && filePath.length) clip[@"capturedImage"] = filePath;
                if (![clip[@"extractedText"] isKindOfClass:NSString.class]) clip[@"extractedText"] = @"";
                if (![clip[@"contentType"] isKindOfClass:NSString.class]) clip[@"contentType"] = [clip[@"extractedText"] length] ? @"text" : @"image";
                if (![clip[@"extractedContent"] isKindOfClass:NSDictionary.class]) clip[@"extractedContent"] = [clip[@"extractedText"] length] ? @{@"text": clip[@"extractedText"]} : @{};
                if (![clip[@"confidence"] isKindOfClass:NSNumber.class]) clip[@"confidence"] = @0.5;
                if (![clip[@"source"] isKindOfClass:NSDictionary.class]) {
                    NSMutableDictionary *source = [NSMutableDictionary dictionary];
                    if ([clip[@"sourceApplicationName"] isKindOfClass:NSString.class]) source[@"applicationName"] = clip[@"sourceApplicationName"];
                    if ([clip[@"sourceBundleIdentifier"] isKindOfClass:NSString.class]) source[@"bundleIdentifier"] = clip[@"sourceBundleIdentifier"];
                    if ([clip[@"sourceWindowTitle"] isKindOfClass:NSString.class]) source[@"windowTitle"] = clip[@"sourceWindowTitle"];
                    if ([clip[@"sourceURL"] isKindOfClass:NSString.class]) source[@"sourceURL"] = clip[@"sourceURL"];
                    if ([clip[@"displayID"] isKindOfClass:NSNumber.class]) source[@"displayID"] = clip[@"displayID"];
                    if ([clip[@"captureRect"] isKindOfClass:NSDictionary.class]) source[@"screenCaptureRect"] = clip[@"captureRect"];
                    if (source.count) {
                        source[@"schemaVersion"] = @1;
                        source[@"sourceType"] = source[@"sourceURL"] ? @"browserPage" : @"application";
                        clip[@"source"] = source;
                    }
                }
                asset[@"liveClip"] = clip;
            }
            asset[@"source"] = filePath ?: originURL.absoluteString ?: payload ?: @"";
            [assets addObject:asset];
        }
        pack[@"assets"] = assets;
        NSArray *rawTrash = [pack[@"trash"] isKindOfClass:NSArray.class] ? pack[@"trash"] : @[];
        pack[@"trash"] = [rawTrash mutableCopy];
        [loadedPacks addObject:pack];
    }
    if (!loadedPacks.count) return NO;

    self.packs = loadedPacks;
    NSInteger storedIndex = [state[@"selectedPackIndex"] integerValue];
    self.selectedPackIndex = MAX(0, MIN(storedIndex, (NSInteger)self.packs.count - 1));
    NSString *email = [state[@"userEmail"] isKindOfClass:NSString.class] ? state[@"userEmail"] : nil;
    self.userEmail = email.length ? email : nil;
    self.loggedIn = [state[@"loggedIn"] boolValue] && self.userEmail.length > 0;
    self.boardMode = [state[@"boardMode"] boolValue];
    self.panelPinned = [state[@"panelPinned"] boolValue];
    id storedAnimated = state[@"voltAnimated"];
    self.voltAnimated = [storedAnimated isKindOfClass:NSNumber.class] ? [storedAnimated boolValue] : YES;
    NSString *storedFilter = [state[@"assetFilter"] isKindOfClass:NSString.class] ? state[@"assetFilter"] : nil;
    if ([@[@"All", @"Images", @"Links", @"PDFs", @"Videos", @"Trash"] containsObject:storedFilter]) self.assetFilter = storedFilter;
    LPPLog(@"state.loaded", @{ @"packs": @(self.packs.count) });
    return YES;
}

- (void)saveState {
    if (!self.packs.count) return;
    NSDictionary *state = @{
        @"version": @4,
        @"packs": self.packs,
        @"selectedPackIndex": @(self.selectedPackIndex),
        @"loggedIn": @(self.loggedIn),
        @"userEmail": self.userEmail ?: @"",
        @"boardMode": @(self.boardMode),
        @"panelPinned": @(self.panelPinned),
        @"voltAnimated": @(self.voltAnimated),
        @"assetFilter": self.assetFilter ?: @"All"
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    if (!data || error) {
        LPPLog(@"state.encode_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
        return;
    }
    if (![data writeToURL:[self stateURL] options:NSDataWritingAtomic error:&error]) {
        LPPLog(@"state.save_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self saveState];
}

- (void)buildPanel {
    self.panel = [[FocusPanel alloc] initWithContentRect:NSMakeRect(0, 0, 390, 520) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    ((FocusPanel *)self.panel).controller = self;
    self.panel.title = @"Packs";
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.hidesOnDeactivate = !self.panelPinned;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    self.rootView = [[DropShelfView alloc] initWithFrame:self.panel.contentView.bounds];
    self.rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.rootView.controller = self;
    self.panel.contentView = self.rootView;
}

- (void)buildCornerTab {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect frame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    CGFloat tabWidth = 104;
    CGFloat tabHeight = 92;
    NSSize tabSize = NSMakeSize(tabWidth, tabHeight);
    NSPoint origin = NSMakePoint(NSMaxX(frame) - tabWidth - 8, NSMaxY(frame) - tabHeight - 8);

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"VoltCornerPositionSaved"]) {
        NSPoint savedOrigin = NSMakePoint(
            [defaults doubleForKey:@"VoltCornerOriginX"],
            [defaults doubleForKey:@"VoltCornerOriginY"]
        );
        NSPoint savedCenter = NSMakePoint(savedOrigin.x + tabWidth / 2, savedOrigin.y + tabHeight / 2);
        NSScreen *savedScreen = ScreenContainingPoint(savedCenter) ?: screen;
        if (savedScreen) origin = ClampedPanelOrigin(savedOrigin, tabSize, savedScreen.visibleFrame);
    }

    self.tabPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, tabWidth, tabHeight) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.tabPanel.floatingPanel = YES;
    self.tabPanel.level = NSFloatingWindowLevel;
    self.tabPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.tabPanel.hidesOnDeactivate = NO;
    self.tabPanel.opaque = NO;
    self.tabPanel.backgroundColor = NSColor.clearColor;
    self.tabPanel.hasShadow = NO;
    self.tabPanel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    self.compactTabView = [[CompactTabView alloc] initWithFrame:NSMakeRect(0, 0, tabWidth, tabHeight)];
    self.compactTabView.controller = self;
    self.tabPanel.contentView = self.compactTabView;
    [self.tabPanel orderFront:nil];
}

- (void)saveCornerTabPosition {
    if (!self.tabPanel) return;
    NSPoint origin = self.tabPanel.frame.origin;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"VoltCornerPositionSaved"];
    [defaults setDouble:origin.x forKey:@"VoltCornerOriginX"];
    [defaults setDouble:origin.y forKey:@"VoltCornerOriginY"];
}

- (void)buildMenuBar {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = nil;
    self.statusItem.button.title = @"Packs";
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Show Live Project Packs" action:@selector(showPanel) keyEquivalent:@"p"].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;
}

- (void)registerHotKey {
    EventHotKeyID panelHotKeyID = {'LPCK', 1};
    RegisterEventHotKey(kVK_ANSI_P, cmdKey | shiftKey, panelHotKeyID, GetApplicationEventTarget(), 0, &_hotKeyRef);
    EventHotKeyID clipHotKeyID = {'LPCK', 2};
    RegisterEventHotKey(kVK_Space, optionKey, clipHotKeyID, GetApplicationEventTarget(), 0, &_liveClipHotKeyRef);
    EventHotKeyID scoutHotKeyID = {'LPCK', 3};
    RegisterEventHotKey(kVK_ANSI_S, optionKey | shiftKey, scoutHotKeyID, GetApplicationEventTarget(), 0, &_scoutHotKeyRef);
    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallEventHandler(GetApplicationEventTarget(), HotKeyHandler, 1, &eventType, (__bridge void *)self, &_eventHandler);
}

static OSStatus HotKeyHandler(__unused EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    AppController *controller = (__bridge AppController *)userData;
    EventHotKeyID hotKeyID = {0, 0};
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    if (hotKeyID.id == 2) [controller beginLiveClipCapture:nil];
    else if (hotKeyID.id == 3) [controller beginScoutCapture:nil];
    else [controller togglePanel];
    return noErr;
}

- (void)showPanel {
    NSSize panelSize = self.panel.frame.size;
    NSRect tabFrame = self.tabPanel ? self.tabPanel.frame : NSZeroRect;
    NSScreen *screen = ScreenContainingPoint(NSMakePoint(NSMidX(tabFrame), NSMidY(tabFrame)))
        ?: self.tabPanel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);

    NSPoint origin;
    if (NSIsEmptyRect(tabFrame)) {
        origin = ClampedPanelOrigin(NSMakePoint(NSMaxX(visible) - panelSize.width - 18, NSMaxY(visible) - panelSize.height - 18), panelSize, visible);
    } else {
        origin = PanelOriginNearTab(tabFrame, panelSize, visible);
    }
    [self.panel setFrameOrigin:origin];
    [self.panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (!self.loggedIn && self.emailField) [self.panel makeFirstResponder:self.emailField];
}

- (void)togglePanel {
    self.panel.visible ? [self.panel orderOut:nil] : [self showPanel];
}

- (NSMutableDictionary *)selectedPack {
    return self.packs[self.selectedPackIndex];
}

- (NSString *)currentPackName {
    return [self selectedPack][@"name"] ?: @"Pack";
}

- (NSUInteger)currentAssetCount {
    return [[self selectedPack][@"assets"] count];
}

- (NSArray<NSMutableDictionary *> *)visibleAssets {
    NSMutableArray<NSMutableDictionary *> *assets = [NSMutableArray array];
    NSDictionary *pack = [self selectedPack];
    if ([self.assetFilter isEqualToString:@"Trash"]) {
        for (NSMutableDictionary *asset in pack[@"trash"]) {
            if (AssetMatchesSearch(asset, self.searchQuery, pack)) [assets addObject:asset];
        }
        return assets;
    }
    NSDictionary<NSString *, NSString *> *kindForFilter = @{@"Images": @"Image", @"Links": @"Link", @"PDFs": @"PDF", @"Videos": @"Video"};
    NSString *requiredKind = kindForFilter[self.assetFilter ?: @"All"];
    for (NSMutableDictionary *asset in pack[@"assets"]) {
        BOOL matchesSearch = AssetMatchesSearch(asset, self.searchQuery, pack);
        BOOL matchesFilter = !requiredKind || [asset[@"kind"] isEqualToString:requiredKind];
        if (matchesSearch && matchesFilter) [assets addObject:asset];
    }
    return assets;
}

- (NSArray<NSMutableDictionary *> *)selectedAssets {
    NSMutableArray<NSMutableDictionary *> *assets = [NSMutableArray array];
    for (NSMutableDictionary *asset in [self visibleAssets]) {
        NSString *assetID = asset[@"id"];
        if (assetID.length && [self.selectedAssetIDs containsObject:assetID]) [assets addObject:asset];
    }
    return assets;
}

- (NSMutableDictionary *)primarySelectedAsset {
    NSArray<NSMutableDictionary *> *selected = [self selectedAssets];
    if (!selected.count) return nil;
    if (self.selectionAnchorID.length) {
        for (NSMutableDictionary *asset in selected) {
            if ([asset[@"id"] isEqualToString:self.selectionAnchorID]) return asset;
        }
    }
    return selected.firstObject;
}

- (void)refreshAssetSelectionVisuals {
    for (AssetTile *tile in self.visibleAssetTiles) [tile refreshInteractionState];
}

- (BOOL)isAssetSelected:(NSDictionary *)asset {
    NSString *assetID = asset[@"id"];
    return assetID.length && [self.selectedAssetIDs containsObject:assetID];
}

- (void)clearAssetSelection {
    if (!self.selectedAssetIDs.count) return;
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    self.selectionCursorID = nil;
    [self refreshAssetSelectionVisuals];
}

- (void)scrollAssetIntoView:(NSDictionary *)asset {
    NSString *assetID = asset[@"id"];
    if (!assetID.length) return;
    for (AssetTile *tile in self.visibleAssetTiles) {
        if (![tile.asset[@"id"] isEqualToString:assetID]) continue;
        [tile.superview scrollRectToVisible:NSInsetRect(tile.frame, 0, -8)];
        return;
    }
}

- (void)moveSelectionBy:(NSInteger)delta extend:(BOOL)extend {
    NSArray<NSMutableDictionary *> *assets = [self visibleAssets];
    if (!assets.count) return;

    NSString *cursorID = self.selectionCursorID.length ? self.selectionCursorID : self.selectionAnchorID;
    NSInteger current = NSNotFound;
    if (cursorID.length) {
        for (NSUInteger index = 0; index < assets.count; index++) {
            if (![assets[index][@"id"] isEqualToString:cursorID]) continue;
            current = (NSInteger)index;
            break;
        }
    }
    NSInteger next = NextSelectionIndex(current, delta, (NSInteger)assets.count);
    if (next == NSNotFound) return;

    NSMutableDictionary *asset = assets[next];
    NSString *assetID = asset[@"id"];
    if (!assetID.length) return;

    [self.panel makeFirstResponder:nil];
    if (extend && self.selectionAnchorID.length) {
        NSArray<NSString *> *range = AssetIDsInInclusiveRange(assets, self.selectionAnchorID, assetID);
        [self.selectedAssetIDs removeAllObjects];
        [self.selectedAssetIDs addObjectsFromArray:range];
    } else {
        [self.selectedAssetIDs removeAllObjects];
        [self.selectedAssetIDs addObject:assetID];
        self.selectionAnchorID = assetID;
    }
    self.selectionCursorID = assetID;
    [self refreshAssetSelectionVisuals];
    [self scrollAssetIntoView:asset];
}

- (void)selectAsset:(NSMutableDictionary *)asset modifiers:(NSEventModifierFlags)modifiers {
    NSString *assetID = asset[@"id"];
    if (!assetID.length) return;
    [self.panel makeFirstResponder:nil];
    NSEventModifierFlags flags = modifiers & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;

    if (shift && self.selectionAnchorID.length) {
        NSArray<NSString *> *range = AssetIDsInInclusiveRange([self visibleAssets], self.selectionAnchorID, assetID);
        if (!command) [self.selectedAssetIDs removeAllObjects];
        [self.selectedAssetIDs addObjectsFromArray:range];
    } else if (command) {
        if ([self.selectedAssetIDs containsObject:assetID]) {
            [self.selectedAssetIDs removeObject:assetID];
            if ([self.selectionAnchorID isEqualToString:assetID]) self.selectionAnchorID = self.selectedAssetIDs.lastObject;
        } else {
            [self.selectedAssetIDs addObject:assetID];
            self.selectionAnchorID = assetID;
        }
    } else {
        if (self.selectedAssetIDs.count != 1 || ![self.selectedAssetIDs containsObject:assetID]) {
            [self.selectedAssetIDs removeAllObjects];
            [self.selectedAssetIDs addObject:assetID];
        }
        self.selectionAnchorID = assetID;
    }
    self.selectionCursorID = assetID;
    [self refreshAssetSelectionVisuals];
}

- (void)prepareAssetForContextMenu:(NSMutableDictionary *)asset {
    if (![self isAssetSelected:asset]) [self selectAsset:asset modifiers:0];
}

- (void)selectAllVisibleAssets {
    [self.selectedAssetIDs removeAllObjects];
    for (NSDictionary *asset in [self visibleAssets]) {
        NSString *assetID = asset[@"id"];
        if (assetID.length) [self.selectedAssetIDs addObject:assetID];
    }
    self.selectionAnchorID = self.selectedAssetIDs.lastObject;
    [self.panel makeFirstResponder:nil];
    [self refreshAssetSelectionVisuals];
}

- (BOOL)handlePanelKeyEvent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    BOOL isEscape = event.keyCode == kVK_Escape;
    BOOL isSpace = event.keyCode == kVK_Space;
    BOOL isReturn = event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter;
    BOOL isDelete = event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete;
    BOOL plainKey = (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) == 0;

    if (command && [characters isEqualToString:@"k"] && self.loggedIn) {
        if (!self.panel.visible) [self showPanel];
        if (!self.searchActive) {
            self.searchActive = YES;
            [self render];
        }
        [self.panel makeFirstResponder:self.searchField];
        [self.searchField selectText:nil];
        return YES;
    }

    if (self.previewPanel.visible) {
        // Space is Quick Look's "dismiss", but notes are editable now — it has
        // to type a space when you're in the text, and keys typed into other
        // panels (Ask AI, note composer) must never close the preview.
        BOOL typingInPreview = event.window == self.previewPanel && [event.window.firstResponder isKindOfClass:NSTextView.class];
        if (plainKey && event.window == self.previewPanel && (isEscape || (isSpace && !typingInPreview))) {
            [self closePreview];
            return YES;
        }
        return NO;
    }

    NSResponder *responder = event.window.firstResponder;
    BOOL editingText = [responder isKindOfClass:NSTextView.class];
    id textDelegate = editingText ? [(NSTextView *)responder delegate] : nil;
    BOOL editingSearch = textDelegate == self.searchField;
    if (editingText) {
        if (isEscape && editingSearch) {
            if (self.searchQuery.length) {
                self.searchQuery = @"";
                [self.selectedAssetIDs removeAllObjects];
                self.selectionAnchorID = nil;
                [self render];
                [self.panel makeFirstResponder:self.searchField];
            } else {
                self.searchActive = NO;
                [self.panel makeFirstResponder:nil];
                [self render];
            }
            return YES;
        }
        return NO;
    }

    if (command && [characters isEqualToString:@"a"] && self.loggedIn) {
        [self selectAllVisibleAssets];
        return YES;
    }
    if (command && [characters isEqualToString:@"c"] && self.selectedAssetIDs.count) {
        [self copySelectedAssets];
        return YES;
    }
    if (command && [characters isEqualToString:@"v"] && self.loggedIn) {
        [self paste:self];
        return YES;
    }
    if (command && [characters isEqualToString:@"z"] && self.lastDeletedAssetRecords.count) {
        [self undoLastDelete:self];
        return YES;
    }
    if (plainKey && isEscape && self.selectedAssetIDs.count) {
        [self clearAssetSelection];
        return YES;
    }
    if (plainKey && isDelete && self.selectedAssetIDs.count) {
        if ([self.assetFilter isEqualToString:@"Trash"]) [self deletePermanentlySelectedAssets:self];
        else [self moveSelectedAssetsToTrash:self];
        return YES;
    }
    if (plainKey && isSpace && self.selectedAssetIDs.count) {
        [self showPreviewForAsset:[self primarySelectedAsset]];
        return YES;
    }
    if (plainKey && isReturn && self.selectedAssetIDs.count) {
        [self activateAsset:[self primarySelectedAsset]];
        return YES;
    }

    BOOL arrowsOnly = (flags & ~NSEventModifierFlagShift) == 0;
    if (arrowsOnly && self.loggedIn) {
        BOOL extend = (flags & NSEventModifierFlagShift) != 0;
        NSInteger columns = self.boardMode ? 2 : 1;
        switch (event.keyCode) {
            case kVK_DownArrow: [self moveSelectionBy:columns extend:extend]; return YES;
            case kVK_UpArrow: [self moveSelectionBy:-columns extend:extend]; return YES;
            case kVK_RightArrow:
                if (!self.boardMode) break;
                [self moveSelectionBy:1 extend:extend];
                return YES;
            case kVK_LeftArrow:
                if (!self.boardMode) break;
                [self moveSelectionBy:-1 extend:extend];
                return YES;
            default: break;
        }
    }
    return NO;
}

- (void)hidePanelAfterDrag {
    [self.panel orderOut:nil];
}

- (BOOL)isRelocatingLiveClipSource {
    return self.relocatingLiveClipAsset != nil;
}

- (NSDictionary *)currentLiveClipSourceContext {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    if (front.localizedName.length) context[@"sourceApplicationName"] = front.localizedName;
    if (front.bundleIdentifier.length) context[@"sourceBundleIdentifier"] = front.bundleIdentifier;
    if (front.processIdentifier > 0) context[@"processIdentifier"] = @(front.processIdentifier);
    NSString *title = WindowTitleForApplication(front);
    if (title.length) context[@"sourceWindowTitle"] = title;
    NSString *browser = ScriptableBrowserName();
    if (browser.length && [front.localizedName isEqualToString:browser]) {
        context[@"browserName"] = browser;
        NSDictionary *errorInfo = nil;
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:FrontTabScriptForBrowser(browser)];
        NSAppleEventDescriptor *result = [script executeAndReturnError:&errorInfo];
        NSURL *url = errorInfo ? nil : WebURLFromText(result.stringValue);
        if (url) context[@"sourceURL"] = url.absoluteString;
    }
    return context;
}

- (void)beginLiveClipCapture:(id)sender {
    [self cancelLiveClipCapture];
    self.liveClipSourceContext = [self currentLiveClipSourceContext];
    self.liveClipCapturePanels = [NSMutableArray array];
    BOOL createdAny = NO;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID displayID = DisplayIDForScreen(screen);
        NSImage *image = ImageForDisplay(displayID);
        if (!image) continue;
        NSPanel *overlay = [[NSPanel alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        overlay.level = NSScreenSaverWindowLevel;
        overlay.opaque = YES;
        overlay.backgroundColor = NSColor.blackColor;
        overlay.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        overlay.releasedWhenClosed = NO;
        LiveClipCaptureView *view = [[LiveClipCaptureView alloc] initWithFrame:NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height) screen:screen image:image displayID:displayID controller:self];
        overlay.contentView = view;
        [overlay makeKeyAndOrderFront:nil];
        [overlay makeFirstResponder:view];
        [self.liveClipCapturePanels addObject:overlay];
        createdAny = YES;
    }
    if (!createdAny) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Screen Recording permission needed";
        alert.informativeText = @"Live Clips are captured and processed locally on your Mac.";
        [alert addButtonWithTitle:@"Open Settings"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        }
    }
}

- (void)cancelLiveClipCapture {
    for (NSPanel *panel in self.liveClipCapturePanels) [panel orderOut:nil];
    self.liveClipCapturePanels = nil;
    self.relocatingLiveClipAsset = nil;
}

// Live Clip (⌥Space) is a screenshot + OCR — the right tool for "watch a
// value on a page," the wrong tool for saving clean research text (OCR is
// lossy on small dense text, e.g. a ChatGPT answer). This is a plain text
// capture instead: it synthesizes ⌘C to whatever's currently focused
// (without switching this app to the foreground, so you never leave
// ChatGPT/Safari/whatever), reads the resulting pasteboard content, and
// saves it straight into the active Pack as a sourced Note. Feeds "Scout."
- (void)beginScoutCapture:(id)sender {
    if (!AXIsProcessTrusted()) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Accessibility permission needed";
        alert.informativeText = @"Scout needs this to copy your current selection from whatever app you're in — text never leaves your Mac except to the Pack you save it into.";
        [alert addButtonWithTitle:@"Open Settings"];
        [alert addButtonWithTitle:@"Cancel"];
        NSDictionary *promptOptions = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)promptOptions);
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
        }
        return;
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSInteger previousChangeCount = pasteboard.changeCount;
    NSRunningApplication *sourceApp = NSWorkspace.sharedWorkspace.frontmostApplication;

    CGEventSourceRef eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef keyDown = CGEventCreateKeyboardEvent(eventSource, (CGKeyCode)kVK_ANSI_C, true);
    CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(eventSource, (CGKeyCode)kVK_ANSI_C, false);
    CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, keyDown);
    CGEventPost(kCGHIDEventTap, keyUp);
    CFRelease(keyDown);
    CFRelease(keyUp);
    if (eventSource) CFRelease(eventSource);

    __weak AppController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AppController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        NSString *text = pb.changeCount != previousChangeCount ? [pb stringForType:NSPasteboardTypeString] : nil;
        if (!text.length) {
            [strongSelf showTransientNotice:@"Nothing was selected to capture"];
            return;
        }
        [strongSelf saveScoutCapture:text fromApp:sourceApp];
    });
}

- (void)saveScoutCapture:(NSString *)text fromApp:(NSRunningApplication *)sourceApp {
    NSString *appName = sourceApp.localizedName.length ? sourceApp.localizedName : @"selection";
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *snippet = trimmed.length > 60 ? [[trimmed substringToIndex:60] stringByAppendingString:@"…"] : trimmed;
    NSString *title = [NSString stringWithFormat:@"%@: %@", appName, snippet];
    NSString *uploader = self.userEmail.length ? self.userEmail : @"You";

    NSMutableDictionary *asset = [self addAssetWithTitle:title kind:@"Note" source:text uploader:uploader];
    asset[@"scoutSourceApp"] = appName;
    [self saveState];
    [self showTransientNotice:[NSString stringWithFormat:@"Scout saved a snippet from %@", appName]];
}

- (NSMutableDictionary *)addLiveClipWithImage:(NSImage *)image mode:(NSString *)mode captureRect:(NSRect)captureRect displayID:(CGDirectDisplayID)displayID sourceContext:(NSDictionary *)sourceContext {
    NSData *png = PNGDataFromImage(image);
    NSURL *stored = [self storeImageData:png extension:@"png"];
    if (!stored) return nil;
    NSString *now = @([[NSDate date] timeIntervalSince1970]).stringValue;
    NSString *hash = ImageHashAtPath(stored.path);
    NSMutableDictionary *asset = [self addAssetWithTitle:[NSString stringWithFormat:@"%@ Live Clip", mode ?: @"Keep"] kind:@"LiveClip" filePath:stored.path originURL:nil uploader:self.userEmail.length ? self.userEmail : @"You"];
    NSMutableDictionary *clip = [@{
        @"id": asset[@"id"] ?: NSUUID.UUID.UUIDString,
        @"packID": [self selectedPack][@"id"] ?: @"",
        @"title": asset[@"title"] ?: @"Live Clip",
        @"createdAt": now,
        @"updatedAt": now,
        @"mode": mode ?: @"Keep",
        @"capturedImage": stored.path,
        @"extractedText": @"",
        @"captureRect": LiveClipRectDictionary(captureRect),
        @"displayID": @(displayID),
        @"lastCheckedAt": now,
        @"lastChangedAt": now,
        @"originalCaptureHash": hash,
        @"latestCaptureHash": hash
    } mutableCopy];
    NSRect unionFrame = NSZeroRect;
    for (NSScreen *screen in NSScreen.screens) unionFrame = NSIsEmptyRect(unionFrame) ? screen.frame : NSUnionRect(unionFrame, screen.frame);
    NSArray *windows = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSDictionary *source = LiveClipSourceFromWindowInfo(captureRect, displayID, sourceContext ?: @{}, windows, NSMaxY(unionFrame));
    clip[@"source"] = source;
    [clip addEntriesFromDictionary:sourceContext ?: @{}];
    if (source[@"applicationName"]) clip[@"sourceApplicationName"] = source[@"applicationName"];
    if (source[@"bundleIdentifier"]) clip[@"sourceBundleIdentifier"] = source[@"bundleIdentifier"];
    if (source[@"windowTitle"]) clip[@"sourceWindowTitle"] = source[@"windowTitle"];
    if (source[@"sourceURL"]) clip[@"sourceURL"] = source[@"sourceURL"];
    asset[@"liveClip"] = clip;
    asset[@"filePath"] = stored.path;
    asset[@"source"] = stored.path;
    if ([mode isEqualToString:@"Watch"]) asset[@"status"] = @"Watching";
    [self saveState];
    [self render];
    [self analyzeLiveClipAsset:asset image:image];
    return asset;
}

- (void)finishLiveClipSelectionFromView:(LiveClipCaptureView *)view mode:(NSString *)mode {
    NSImage *cropped = CroppedImageFromScreenImage(view.screenImage, view.selectionRect, view.bounds.size);
    NSRect absolute = NSMakeRect(NSMinX(view.captureScreen.frame) + NSMinX(view.selectionRect), NSMinY(view.captureScreen.frame) + NSMinY(view.selectionRect), NSWidth(view.selectionRect), NSHeight(view.selectionRect));
    NSMutableDictionary *relocatingAsset = self.relocatingLiveClipAsset;
    NSDictionary *sourceContext = self.liveClipSourceContext;
    self.relocatingLiveClipAsset = nil;
    [self cancelLiveClipCapture];
    if (!cropped) {
        [self showTransientNotice:@"Could not capture that region"];
        return;
    }
    if (relocatingAsset) {
        NSRect unionFrame = NSZeroRect;
        for (NSScreen *screen in NSScreen.screens) unionFrame = NSIsEmptyRect(unionFrame) ? screen.frame : NSUnionRect(unionFrame, screen.frame);
        NSArray *windows = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        NSDictionary *source = LiveClipSourceFromWindowInfo(absolute, view.displayID, sourceContext ?: @{}, windows, NSMaxY(unionFrame));
        NSMutableDictionary *clip = relocatingAsset[@"liveClip"];
        clip[@"source"] = source;
        clip[@"captureRect"] = LiveClipRectDictionary(absolute);
        clip[@"displayID"] = @(view.displayID);
        if (source[@"applicationName"]) clip[@"sourceApplicationName"] = source[@"applicationName"];
        if (source[@"bundleIdentifier"]) clip[@"sourceBundleIdentifier"] = source[@"bundleIdentifier"];
        if (source[@"windowTitle"]) clip[@"sourceWindowTitle"] = source[@"windowTitle"];
        if (source[@"sourceURL"]) clip[@"sourceURL"] = source[@"sourceURL"];
        [self applyLiveClipRefreshToAsset:relocatingAsset image:cropped relocated:YES];
        [self.compactTabView.mascotView playSuccessHop];
        [self showTransientNotice:@"Source relocated"];
        return;
    }
    NSMutableDictionary *asset = [self addLiveClipWithImage:cropped mode:mode captureRect:absolute displayID:view.displayID sourceContext:sourceContext];
    if (asset) {
        [self.compactTabView.mascotView playSuccessHop];
        [self showTransientNotice:[NSString stringWithFormat:@"%@ Live Clip saved", mode ?: @"Keep"]];
    }
}

- (void)analyzeLiveClipAsset:(NSMutableDictionary *)asset image:(NSImage *)image completion:(void (^)(NSDictionary *analysis))completion {
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        if (completion) completion(@{@"contentType": @"image", @"extractedContent": @{}, @"extractedText": @"", @"ocrItems": @[], @"confidence": @0});
        return;
    }
    CGImageRetain(cgImage);
    NSMutableDictionary *clip = asset[@"liveClip"];
    clip[@"analysisStatus"] = @"processing";
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *finishedRequest, NSError *error) {
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (VNRecognizedTextObservation *observation in finishedRequest.results ?: @[]) {
            VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
            if (!candidate.string.length) continue;
            CGRect box = observation.boundingBox;
            [items addObject:@{@"text": candidate.string, @"x": @(box.origin.x), @"y": @(box.origin.y), @"width": @(box.size.width), @"height": @(box.size.height), @"confidence": @(candidate.confidence)}];
        }
        NSDictionary *structured = error ? @{@"contentType": @"image", @"extractedContent": @{}, @"confidence": @0.1} : LiveClipStructuredContentFromOCRItems(items);
        NSString *text = OCRTextFromItems(items);
        dispatch_async(dispatch_get_main_queue(), ^{
            clip[@"extractedText"] = text ?: @"";
            clip[@"ocrItems"] = items ?: @[];
            clip[@"contentType"] = structured[@"contentType"] ?: @"image";
            clip[@"extractedContent"] = structured[@"extractedContent"] ?: @{};
            clip[@"confidence"] = structured[@"confidence"] ?: @0;
            clip[@"analysisStatus"] = @"complete";
            clip[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]).stringValue;
            NSString *contentType = clip[@"contentType"];
            if ([contentType isEqualToString:@"labeledValue"]) {
                NSDictionary *content = clip[@"extractedContent"];
                NSString *label = content[@"label"] ?: @"Live Clip";
                NSString *value = content[@"displayValue"] ?: @"";
                asset[@"title"] = value.length ? [NSString stringWithFormat:@"%@ %@", label, value] : label;
            } else if ([contentType isEqualToString:@"number"]) {
                asset[@"title"] = clip[@"extractedContent"][@"displayValue"] ?: @"Number Live Clip";
            } else if ([contentType isEqualToString:@"url"]) {
                asset[@"title"] = @"URL Live Clip";
            } else if ([contentType isEqualToString:@"text"] && text.length) {
                NSString *flat = CollapsedWhitespace(text);
                asset[@"title"] = flat.length > 64 ? [[flat substringWithRange:[flat rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 64)]] stringByAppendingString:@"…"] : flat;
            }
            [self saveState];
            [self render];
            if (![clip[@"refreshState"] isEqualToString:@"refreshing"]) [self showTransientNotice:text.length ? @"Live Clip understood" : @"Saved as image"];
            if (completion) {
                completion(@{
                    @"contentType": clip[@"contentType"] ?: @"image",
                    @"extractedContent": clip[@"extractedContent"] ?: @{},
                    @"extractedText": clip[@"extractedText"] ?: @"",
                    @"ocrItems": clip[@"ocrItems"] ?: @[],
                    @"confidence": clip[@"confidence"] ?: @0
                });
            }
        });
    }];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
        [handler performRequests:@[request] error:nil];
        CGImageRelease(cgImage);
    });
}

- (void)analyzeLiveClipAsset:(NSMutableDictionary *)asset image:(NSImage *)image {
    [self analyzeLiveClipAsset:asset image:image completion:nil];
}

- (NSMutableDictionary *)addAssetWithTitle:(NSString *)title kind:(NSString *)kind source:(NSString *)source uploader:(NSString *)uploader {
    NSURL *originURL = WebURLFromText(source);
    NSString *filePath = nil;
    NSString *payload = nil;
    if ([source hasPrefix:@"/"]) filePath = source;
    else if (!originURL) payload = source;
    NSMutableDictionary *asset = [self addAssetWithTitle:title kind:kind filePath:filePath originURL:originURL uploader:uploader];
    if (payload.length) {
        asset[@"payload"] = payload;
        asset[@"source"] = payload;
        [self saveState];
    }
    return asset;
}

- (NSMutableDictionary *)addAssetWithTitle:(NSString *)title kind:(NSString *)kind filePath:(NSString *)filePath originURL:(NSURL *)originURL uploader:(NSString *)uploader {
    NSString *name = uploader ?: (self.userEmail.length ? self.userEmail : @"You");
    NSMutableDictionary *asset = [@{
        @"id": NSUUID.UUID.UUIDString,
        @"title": title ?: @"Untitled asset",
        @"kind": kind ?: @"File",
        @"status": @"Reference",
        @"uploader": name,
        @"source": filePath ?: originURL.absoluteString ?: @"",
        @"addedAt": @([[NSDate date] timeIntervalSince1970]),
        @"isNew": @YES
    } mutableCopy];
    if (filePath.length) asset[@"filePath"] = filePath;
    if (originURL) asset[@"originURL"] = originURL.absoluteString;
    NSMutableArray *assets = [self selectedPack][@"assets"];
    [assets insertObject:asset atIndex:0];
    NSString *notice = [NSString stringWithFormat:@"%@ added %@", DisplayName(name), title ?: @"an asset"];
    [self.activity insertObject:[@{@"text": notice, @"time": NSDate.date} mutableCopy] atIndex:0];
    self.transientNotice = notice;
    LPPLog(@"asset.added", @{
        @"id": asset[@"id"],
        @"kind": asset[@"kind"],
        @"hasFile": @(filePath.length > 0),
        @"originHost": originURL.host ?: @""
    });
    [self saveState];
    [self render];
    [self.compactTabView refresh];
    [self requestAINameForAsset:asset placeholderTitle:asset[@"title"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self.transientNotice isEqualToString:notice]) return;
        self.transientNotice = nil;
        [self render];
    });
    return asset;
}

- (void)requestAINameForAsset:(NSMutableDictionary *)asset placeholderTitle:(NSString *)placeholderTitle {
    if (!asset || !LooksAutoGeneratedAssetTitle(placeholderTitle)) return;
    if (![LPPAIExplainer isAvailable]) return;

    NSString *kind = asset[@"kind"] ?: @"File";
    NSString *sample = TextSampleForAsset(asset);
    NSURL *originURL = AssetOriginURL(asset);
    if (!sample.length && originURL) sample = [NSString stringWithFormat:@"Source URL: %@", originURL.absoluteString];
    if (!sample.length && !LooksAutoGeneratedAssetTitle(asset[@"title"])) return;

    __weak AppController *weakSelf = self;
    NSString *assetID = asset[@"id"];
    [LPPAIExplainer suggestAssetNameWithTitle:placeholderTitle ?: @"" kind:kind contentSample:sample completion:^(NSString * _Nullable suggested, NSString * _Nullable error) {
        AppController *strongSelf = weakSelf;
        if (!strongSelf || !suggested.length) return;
        NSString *clean = CleanSuggestedAssetTitle(suggested);
        if (!clean.length) return;

        NSMutableDictionary *currentAsset = nil;
        for (NSMutableDictionary *candidate in [strongSelf selectedPack][@"assets"]) {
            if ([candidate[@"id"] isEqualToString:assetID]) {
                currentAsset = candidate;
                break;
            }
        }
        if (!currentAsset) return;

        NSString *currentTitle = currentAsset[@"title"] ?: @"";
        if (![currentTitle isEqualToString:placeholderTitle ?: @""]) return;
        if ([clean isEqualToString:currentTitle]) return;

        currentAsset[@"title"] = clean;
        [strongSelf saveState];
        [strongSelf render];
    }];
}

- (NSURL *)uploadsRoot {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [[support URLByAppendingPathComponent:@"LiveProjectPacks" isDirectory:YES] URLByAppendingPathComponent:@"Uploads" isDirectory:YES];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) LPPLog(@"uploads.directory_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
    return root;
}

- (NSURL *)storeFileInSelectedPack:(NSURL *)url {
    if (!url.isFileURL) return url;
    NSString *packName = [[self selectedPack][@"name"] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSURL *packRoot = [[self uploadsRoot] URLByAppendingPathComponent:packName isDirectory:YES];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:packRoot withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) {
        LPPLog(@"pack.directory_failed", @{ @"error": directoryError.localizedDescription ?: @"unknown" });
        [self showTransientNotice:@"Could not access this Pack"];
        return nil;
    }
    NSString *fileName = url.lastPathComponent.length ? url.lastPathComponent : @"Uploaded file";
    NSURL *destination = [packRoot URLByAppendingPathComponent:fileName];
    NSInteger copy = 1;
    while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        NSString *base = fileName.stringByDeletingPathExtension;
        NSString *ext = fileName.pathExtension;
        NSString *next = ext.length ? [NSString stringWithFormat:@"%@ %ld.%@", base, (long)copy, ext] : [NSString stringWithFormat:@"%@ %ld", base, (long)copy];
        destination = [packRoot URLByAppendingPathComponent:next];
        copy++;
    }
    NSError *error = nil;
    [NSFileManager.defaultManager copyItemAtURL:url toURL:destination error:&error];
    if (error) {
        LPPLog(@"file.copy_failed", @{ @"name": fileName, @"error": error.localizedDescription ?: @"unknown" });
        [self showTransientNotice:@"Could not add that file"];
        return nil;
    }
    return destination;
}

- (NSURL *)storeImageData:(NSData *)data extension:(NSString *)extension {
    if (!data.length) return nil;
    NSString *packName = [[self selectedPack][@"name"] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSURL *packRoot = [[self uploadsRoot] URLByAppendingPathComponent:packName isDirectory:YES];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:packRoot withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) {
        LPPLog(@"pack.directory_failed", @{ @"error": directoryError.localizedDescription ?: @"unknown" });
        [self showTransientNotice:@"Could not access this Pack"];
        return nil;
    }
    NSString *safeExtension = [[extension ?: @"png" componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    if (!safeExtension.length) safeExtension = @"png";
    NSString *fileName = [NSString stringWithFormat:@"Image-%@.%@", NSUUID.UUID.UUIDString, safeExtension.lowercaseString];
    NSURL *destination = [packRoot URLByAppendingPathComponent:fileName];
    if (![data writeToURL:destination atomically:YES]) {
        LPPLog(@"image.write_failed", @{ @"extension": extension ?: @"png" });
        [self showTransientNotice:@"Could not save that image"];
        return nil;
    }
    return destination;
}

- (NSURL *)storePreviewData:(NSData *)data extension:(NSString *)extension {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [[support URLByAppendingPathComponent:@"LiveProjectPacks" isDirectory:YES] URLByAppendingPathComponent:@"Previews" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *fileName = [NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, extension.length ? extension : @"jpg"];
    NSURL *destination = [root URLByAppendingPathComponent:fileName];
    return [data writeToURL:destination atomically:YES] ? destination : nil;
}

- (void)loadPreviewForAsset:(NSMutableDictionary *)asset fromURL:(NSURL *)url {
    if (!asset || !url) return;
    NSMutableURLRequest *pageRequest = [NSMutableURLRequest requestWithURL:url];
    pageRequest.timeoutInterval = 12;
    [pageRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [pageRequest setValue:@"text/html,application/xhtml+xml,image/avif,image/webp,image/*;q=0.8" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:pageRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) return;
        NSString *mime = response.MIMEType.lowercaseString ?: @"";
        NSURL *imageURL = nil;
        NSData *imageData = nil;
        NSURLResponse *imageResponse = response;
        if ([mime hasPrefix:@"image/"]) {
            imageURL = url;
            imageData = data;
        } else {
            NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            imageURL = ResolvedURL(ImageURLFromHTML(html), url);
        }
        if (!imageURL) return;

        void (^savePreview)(NSData *, NSURLResponse *) = ^(NSData *previewData, NSURLResponse *previewResponse) {
            if (!previewData.length || ![[NSImage alloc] initWithData:previewData]) return;
            NSString *extension = ExtensionForResponse(previewResponse, imageURL);
            NSURL *stored = [self storePreviewData:previewData extension:extension];
            if (!stored) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                asset[@"preview"] = stored.path;
                [self saveState];
                [self render];
            });
        };

        if (imageData) {
            savePreview(imageData, imageResponse);
            return;
        }
        NSMutableURLRequest *imageRequest = [NSMutableURLRequest requestWithURL:imageURL];
        imageRequest.timeoutInterval = 12;
        [imageRequest setValue:pageRequest.allHTTPHeaderFields[@"User-Agent"] forHTTPHeaderField:@"User-Agent"];
        [imageRequest setValue:url.absoluteString forHTTPHeaderField:@"Referer"];
        [[NSURLSession.sharedSession dataTaskWithRequest:imageRequest completionHandler:^(NSData *previewData, NSURLResponse *previewResponse, NSError *previewError) {
            if (!previewError) savePreview(previewData, previewResponse);
        }] resume];
    }] resume];
}

- (BOOL)addFromPasteboard:(NSPasteboard *)pasteboard {
    if (!pasteboard) return NO;
    NSString *uploader = self.userEmail.length ? self.userEmail : @"You";
    NSArray<NSPasteboardItem *> *items = pasteboard.pasteboardItems ?: @[];
    LPPLog(@"drop.received", @{ @"types": pasteboard.types ?: @[] });

    NSMutableArray<NSString *> *htmlPayloads = [NSMutableArray array];
    for (NSPasteboardItem *item in items) {
        NSString *html = [item stringForType:NSPasteboardTypeHTML];
        if (html.length && ![htmlPayloads containsObject:html]) [htmlPayloads addObject:html];
    }
    NSString *directHTML = [pasteboard stringForType:NSPasteboardTypeHTML];
    if (directHTML.length && ![htmlPayloads containsObject:directHTML]) [htmlPayloads addObject:directHTML];

    NSMutableOrderedSet<NSURL *> *webURLs = [NSMutableOrderedSet orderedSet];
    void (^collectURL)(NSURL *) = ^(NSURL *url) {
        if (!url || url.isFileURL) return;
        NSURL *validated = WebURLFromText(url.absoluteString);
        if (validated) [webURLs addObject:validated];
    };
    for (NSPasteboardType type in @[NSPasteboardTypeURL, @"Apple URL pasteboard type"]) {
        for (NSPasteboardItem *item in items) collectURL(WebURLFromText([item stringForType:type]));
        collectURL(WebURLFromText([pasteboard stringForType:type]));
    }
    NSArray<NSURL *> *readURLs = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @NO}];
    for (NSURL *url in readURLs) collectURL(url);
    collectURL(WebURLFromPropertyList([pasteboard propertyListForType:@"WebURLsWithTitlesPboardType"]));

    NSData *archiveData = [pasteboard dataForType:@"Apple Web Archive pasteboard type"];
    if (archiveData.length) {
        id archive = [NSPropertyListSerialization propertyListWithData:archiveData options:NSPropertyListImmutable format:nil error:nil];
        collectURL(WebURLFromPropertyList(archive));
    }

    NSString *plainText = [pasteboard stringForType:NSPasteboardTypeString];
    collectURL(WebURLFromText(plainText));
    for (NSPasteboardItem *item in items) collectURL(WebURLFromText([item stringForType:NSPasteboardTypeString]));

    NSURL *originURL = nil;
    for (NSURL *url in webURLs) originURL = PreferredOriginURL(originURL, url);
    for (NSString *html in htmlPayloads) originURL = PreferredOriginURL(originURL, LinkURLFromHTML(html));

    NSMutableOrderedSet<NSURL *> *imageURLs = [NSMutableOrderedSet orderedSet];
    for (NSString *html in htmlPayloads) {
        NSURL *imageURL = ResolvedURL(ImageURLFromHTML(html), originURL ?: webURLs.firstObject);
        if (imageURL) [imageURLs addObject:imageURL];
    }
    for (NSURL *url in webURLs) {
        if (IsLikelySocialImageURL(url)) [imageURLs addObject:url];
    }
    LPPLog(@"drop.parsed", @{
        @"originHost": originURL.host ?: @"",
        @"webURLs": @(webURLs.count),
        @"imageURLs": @(imageURLs.count),
        @"hasHTML": @(htmlPayloads.count > 0)
    });

    NSMutableOrderedSet<NSURL *> *fileURLs = [NSMutableOrderedSet orderedSet];
    NSArray<NSURL *> *readFileURLs = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in readFileURLs) {
        if (url.isFileURL) [fileURLs addObject:url];
    }
    for (NSPasteboardItem *item in items) {
        NSString *fileString = [item stringForType:NSPasteboardTypeFileURL];
        NSURL *url = fileString.length ? [NSURL URLWithString:fileString] : nil;
        if (url.isFileURL) [fileURLs addObject:url];
    }
    if (fileURLs.count) {
        BOOL added = NO;
        for (NSURL *url in fileURLs) {
            NSURL *stored = [self storeFileInSelectedPack:url];
            if (!stored) continue;
            [self addAssetWithTitle:stored.lastPathComponent kind:KindForURL(stored) filePath:stored.path originURL:originURL uploader:uploader];
            added = YES;
        }
        return added;
    }

    NSString *imageExtension = nil;
    NSData *imageData = ImageDataFromPasteboard(pasteboard, &imageExtension);
    BOOL intentionalImage = imageURLs.count > 0 || !originURL || IsLikelySocialImageURL(originURL) || IsSubstantialImageData(imageData);
    if (imageData.length && intentionalImage) {
        NSURL *stored = [self storeImageData:imageData extension:imageExtension];
        if (!stored) return NO;
        NSString *title = originURL ? TitleForWebURL(originURL) : stored.lastPathComponent;
        [self addAssetWithTitle:title kind:@"Image" filePath:stored.path originURL:originURL uploader:uploader];
        return YES;
    }

    NSURL *imageURL = imageURLs.firstObject;
    if (imageURL) {
        NSURL *preservedOrigin = originURL ?: imageURL;
        [self downloadImageFromURL:imageURL title:TitleForWebURL(preservedOrigin) originURL:preservedOrigin];
        return YES;
    }

    if ([self receivePromisedFilesFromPasteboard:pasteboard originURL:originURL]) return YES;

    if (originURL) {
        [self handleDroppedWebURL:originURL originURL:originURL];
        return YES;
    }

    if (plainText.length) {
        NSString *title = [plainText substringToIndex:MIN((NSUInteger)48, plainText.length)];
        [self addAssetWithTitle:title kind:@"Note" source:plainText uploader:uploader];
        return YES;
    }
    return NO;
}

- (void)paste:(id)sender {
    [self addFromPasteboard:NSPasteboard.generalPasteboard];
}

- (void)grabLink:(id)sender {
    NSString *clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"";
    NSURL *clipboardURL = WebURLFromText(clip);

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"";
    alert.informativeText = @"";
    alert.alertStyle = NSAlertStyleInformational;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 32)];
    field.placeholderString = @"Paste any web link";
    field.stringValue = clipboardURL.absoluteString ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) return;
    NSURL *url = WebURLFromText(field.stringValue);
    if (!url) return;
    [self addWebURL:url];
}

- (void)savePhotoFromLink:(id)sender {
    NSString *clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"";
    NSURL *clipboardURL = WebURLFromText(clip);

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Save full-size photo";
    alert.informativeText = @"";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 32)];
    field.placeholderString = @"Paste the photo or page link";
    field.stringValue = clipboardURL.absoluteString ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Save Photo"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSURL *url = WebURLFromText(field.stringValue);
    if (url) [self savePhotoFromURL:url];
}

- (void)savePhotoFromAsset:(NSDictionary *)asset {
    NSURL *url = AssetOriginURL(asset);
    if (url) [self savePhotoFromURL:url];
}

- (void)showTransientNotice:(NSString *)notice {
    if (!notice.length) return;
    self.transientNotice = notice;
    [self render];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self.transientNotice isEqualToString:notice]) return;
        self.transientNotice = nil;
        [self render];
    });
}

- (void)savePhotoFromURL:(NSURL *)url {
    if (!url) return;
    [self showTransientNotice:@"Finding full-size photo…"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 15;
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"text/html,application/xhtml+xml,image/avif,image/webp,image/*;q=0.9,*/*;q=0.5" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *mime = response.MIMEType.lowercaseString ?: @"";
        NSImage *image = data.length ? [[NSImage alloc] initWithData:data] : nil;
        if (!error && data.length && (image || [mime hasPrefix:@"image/"])) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *extension = ExtensionForResponse(response, url);
                NSURL *stored = [self storeImageData:data extension:extension];
                if (!stored) return;
                [self addAssetWithTitle:stored.lastPathComponent kind:@"Image" filePath:stored.path originURL:url uploader:self.userEmail.length ? self.userEmail : @"You"];
            });
            return;
        }

        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *imageURL = ResolvedURL(PinterestImageURLFromText(html) ?: ImageURLFromHTML(html), url);
        if (imageURL && ![imageURL.absoluteString isEqualToString:url.absoluteString]) {
            NSMutableURLRequest *imageRequest = [NSMutableURLRequest requestWithURL:imageURL];
            imageRequest.timeoutInterval = 15;
            [imageRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
            [imageRequest setValue:@"image/avif,image/webp,image/apng,image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
            [imageRequest setValue:url.absoluteString forHTTPHeaderField:@"Referer"];
            [[NSURLSession.sharedSession dataTaskWithRequest:imageRequest completionHandler:^(NSData *imageData, NSURLResponse *imageResponse, NSError *imageError) {
                NSImage *downloaded = imageData.length ? [[NSImage alloc] initWithData:imageData] : nil;
                if (imageError || !downloaded) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self showTransientNotice:@"No full-size photo found"]; });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *extension = ExtensionForResponse(imageResponse, imageURL);
                    NSURL *stored = [self storeImageData:imageData extension:extension];
                    if (!stored) return;
                    [self addAssetWithTitle:TitleForWebURL(url) kind:@"Image" filePath:stored.path originURL:url uploader:self.userEmail.length ? self.userEmail : @"You"];
                });
            }] resume];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showTransientNotice:@"No full-size photo found"];
        });
    }] resume];
}

- (void)grabVisiblePhoto:(id)sender {
    NSString *packName = [[self selectedPack][@"name"] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSURL *packRoot = [[self uploadsRoot] URLByAppendingPathComponent:packName isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:packRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination = [packRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"Grab-%lld.png", (long long)(NSDate.date.timeIntervalSince1970 * 1000)]];

    [self.panel orderOut:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/sbin/screencapture";
        task.arguments = @[@"-i", destination.path];
        task.terminationHandler = ^(NSTask *finishedTask) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showPanel];
                if (finishedTask.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
                    [self addAssetWithTitle:destination.lastPathComponent kind:@"Image" source:destination.path uploader:self.userEmail.length ? self.userEmail : @"You"];
                }
            });
        };
        @try {
            [task launch];
        } @catch (NSException *exception) {
            [self showPanel];
        }
    });
}

- (void)addWebURL:(NSURL *)url {
    if (!url) return;
    NSMutableDictionary *asset = [self addAssetWithTitle:TitleForWebURL(url) kind:@"Link" filePath:nil originURL:url uploader:self.userEmail.length ? self.userEmail : @"You"];
    [self loadPreviewForAsset:asset fromURL:url];
    [self loadTitleForAsset:asset fromURL:url];
}

- (void)loadTitleForAsset:(NSMutableDictionary *)asset fromURL:(NSURL *)url {
    if (!asset || !url) return;
    NSString *placeholder = asset[@"title"] ?: @"";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 12;
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        if (error || !data.length) return;
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        NSString *title = TitleFromHTML(html);
        if (!title.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Never clobber a title the user renamed while the fetch was in flight.
            if (![asset[@"title"] isEqualToString:placeholder]) return;
            asset[@"title"] = title;
            [self saveState];
            [self render];
        });
    }];
    [task resume];
}

- (void)grabCurrentTab:(id)sender {
    NSString *browser = ScriptableBrowserName();
    if (!browser) {
        [self showTransientNotice:@"Open Safari, Chrome, Arc, Brave, or Edge first"];
        return;
    }

    NSDictionary *errorInfo = nil;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:FrontTabScriptForBrowser(browser)];
    NSAppleEventDescriptor *result = [script executeAndReturnError:&errorInfo];
    if (errorInfo) {
        NSInteger code = [errorInfo[NSAppleScriptErrorNumber] integerValue];
        LPPLog(@"tab.grab_failed", @{ @"browser": browser, @"code": @(code) });
        if (code == errAEEventNotPermitted || code == errAEEventWouldRequireUserConsent) {
            [self showTransientNotice:[NSString stringWithFormat:@"Allow Packs to control %@ in Settings › Privacy & Security › Automation", browser]];
        } else if (code == errAETimeout) {
            [self showTransientNotice:[NSString stringWithFormat:@"%@ did not respond - approve the permission prompt, then try again", browser]];
        } else if (code == -1728) {
            [self showTransientNotice:[NSString stringWithFormat:@"No page open in %@", browser]];
        } else {
            [self showTransientNotice:[NSString stringWithFormat:@"Could not read the front %@ tab", browser]];
        }
        return;
    }

    NSURL *url = WebURLFromText(result.stringValue);
    if (!url) {
        [self showTransientNotice:[NSString stringWithFormat:@"No page open in %@", browser]];
        return;
    }
    LPPLog(@"tab.grabbed", @{ @"browser": browser, @"host": url.host ?: @"" });
    [self addWebURL:url];
}

- (void)handleDroppedWebURL:(NSURL *)url {
    [self handleDroppedWebURL:url originURL:url];
}

- (void)handleDroppedWebURL:(NSURL *)url originURL:(NSURL *)originURL {
    if (!url) return;
    if (IsLikelySocialImageURL(url)) {
        NSURL *preservedOrigin = PreferredOriginURL(originURL, url);
        [self downloadImageFromURL:url title:TitleForWebURL(preservedOrigin ?: url) originURL:preservedOrigin ?: url];
    } else {
        [self addWebURL:PreferredOriginURL(originURL, url) ?: url];
    }
}

- (BOOL)receivePromisedFilesFromPasteboard:(NSPasteboard *)pasteboard originURL:(NSURL *)originURL {
    NSArray<NSFilePromiseReceiver *> *receivers = [pasteboard readObjectsForClasses:@[NSFilePromiseReceiver.class] options:@{}];
    if (!receivers.count) return NO;

    NSString *folderName = [NSString stringWithFormat:@"LiveProjectPacks-Drop-%@", NSUUID.UUID.UUIDString];
    NSURL *temporaryRoot = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:folderName isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:temporaryRoot withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSFilePromiseReceiver *receiver in receivers) {
        [receiver receivePromisedFilesAtDestination:temporaryRoot options:@{} operationQueue:NSOperationQueue.mainQueue reader:^(NSURL *fileURL, NSError *error) {
            if (error || !fileURL.isFileURL) {
                if (error) LPPLog(@"promise.receive_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
                return;
            }
            NSURL *stored = [self storeFileInSelectedPack:fileURL];
            if (!stored) return;
            [self addAssetWithTitle:stored.lastPathComponent kind:KindForURL(stored) filePath:stored.path originURL:originURL uploader:self.userEmail.length ? self.userEmail : @"You"];
        }];
    }
    return YES;
}

- (void)downloadImageFromURL:(NSURL *)url title:(NSString *)title {
    [self downloadImageFromURL:url title:title originURL:url];
}

- (void)downloadImageFromURL:(NSURL *)url title:(NSString *)title originURL:(NSURL *)originURL {
    if (!url) return;
    [self.activity insertObject:[@{@"text": @"Grabbing image", @"time": [NSDate date]} mutableCopy] atIndex:0];
    [self render];
    [self downloadImageFromURL:url title:title originURL:originURL remainingAttempts:2];
}

- (void)downloadImageFromURL:(NSURL *)url title:(NSString *)title originURL:(NSURL *)originURL remainingAttempts:(NSInteger)remainingAttempts {
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15;
    request.cachePolicy = NSURLRequestReloadRevalidatingCacheData;
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    if (originURL && ![originURL.absoluteString isEqualToString:url.absoluteString]) {
        [request setValue:originURL.absoluteString forHTTPHeaderField:@"Referer"];
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSImage *image = data.length ? [[NSImage alloc] initWithData:data] : nil;
            NSString *mime = response.MIMEType.lowercaseString ?: @"";
            BOOL looksLikeImage = image != nil || [mime hasPrefix:@"image/"];
            if (!data.length || error || !looksLikeImage) {
                NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                NSURL *nestedImage = ResolvedURL(PinterestImageURLFromText(html) ?: ImageURLFromHTML(html), originURL ?: url);
                if (remainingAttempts > 0 && nestedImage && ![nestedImage.absoluteString isEqualToString:url.absoluteString]) {
                    [self downloadImageFromURL:nestedImage title:title originURL:originURL ?: url remainingAttempts:remainingAttempts - 1];
                    return;
                }
                LPPLog(@"image.download_failed", @{
                    @"host": url.host ?: @"",
                    @"error": error.localizedDescription ?: @"not an image"
                });
                [self addWebURL:originURL ?: url];
                return;
            }
            NSString *ext = ExtensionForResponse(response, url);
            NSURL *stored = [self storeImageData:data extension:ext];
            if (!stored) return;
            [self addAssetWithTitle:title.length ? title : stored.lastPathComponent kind:@"Image" filePath:stored.path originURL:originURL ?: url uploader:self.userEmail.length ? self.userEmail : @"You"];
        });
    }];
    [task resume];
}

- (void)copyAsset:(NSDictionary *)asset {
    NSString *filePath = AssetFilePath(asset);
    NSURL *originURL = AssetOriginURL(asset);
    NSString *payload = AssetPayload(asset);
    NSString *previewPath = asset[@"preview"];
    if (!filePath.length && !originURL && !payload.length && !previewPath.length) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];

    if (IsLiveClip(asset)) {
        NSString *structured = CopyableTextForLiveClip(asset);
        if (structured.length) {
            [pasteboard setString:structured forType:NSPasteboardTypeString];
        } else {
            NSString *path = LiveClipImagePath(asset);
            NSImage *image = path.length ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
            if (image) [pasteboard writeObjects:@[image]];
            else if (path.length) [pasteboard writeObjects:@[[NSURL fileURLWithPath:path]]];
        }
    } else if (filePath.length) {
        NSURL *url = [NSURL fileURLWithPath:filePath];
        if ([asset[@"kind"] isEqualToString:@"Image"]) {
            NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
            if (image) {
                [pasteboard writeObjects:@[image]];
            } else {
                [pasteboard writeObjects:@[url]];
            }
        } else {
            [pasteboard writeObjects:@[url]];
        }
    } else if (previewPath.length) {
        NSImage *previewImage = [[NSImage alloc] initWithContentsOfFile:previewPath];
        if (previewImage) [pasteboard writeObjects:@[previewImage]];
        else if (originURL) [pasteboard setString:originURL.absoluteString forType:NSPasteboardTypeString];
    } else if (originURL) {
        [pasteboard setString:originURL.absoluteString forType:NSPasteboardTypeString];
    } else {
        [pasteboard setString:payload forType:NSPasteboardTypeString];
    }

    [self.activity insertObject:[@{@"text": [NSString stringWithFormat:@"Copied %@", asset[@"title"] ?: @"asset"], @"time": [NSDate date]} mutableCopy] atIndex:0];
    if ([asset isKindOfClass:NSMutableDictionary.class]) ((NSMutableDictionary *)asset)[@"isNew"] = @NO;
    [self saveState];
    [self render];
    [self showTransientNotice:@"Copied"];
}

- (void)copyLinkForAsset:(NSDictionary *)asset {
    NSURL *originURL = AssetOriginURL(asset);
    if (!originURL) {
        [self showTransientNotice:@"No link available"];
        return;
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:originURL.absoluteString forType:NSPasteboardTypeString];
    if ([asset isKindOfClass:NSMutableDictionary.class]) ((NSMutableDictionary *)asset)[@"isNew"] = @NO;
    [self saveState];
    [self render];
    [self showTransientNotice:@"Link copied"];
}

- (void)viewExtractedTextForSelectedClip:(id)sender {
    NSMutableDictionary *asset = [self primarySelectedAsset];
    NSString *text = asset[@"liveClip"][@"extractedText"] ?: @"";
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = text.length ? @"Extracted Text" : @"No Text Found";
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 220)];
    NSTextView *textView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    textView.editable = NO;
    textView.string = text.length ? text : @"No text was found in this Live Clip.";
    scroll.documentView = textView;
    scroll.hasVerticalScroller = YES;
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"Copy"];
    [alert addButtonWithTitle:@"Done"];
    if ([alert runModal] == NSAlertFirstButtonReturn && text.length) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    }
}

- (void)copyExtractedTextForSelectedClip:(id)sender {
    NSString *text = [self primarySelectedAsset][@"liveClip"][@"extractedText"] ?: @"";
    if (!text.length) {
        [self showTransientNotice:@"No text found"];
        return;
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    [self showTransientNotice:@"Extracted text copied"];
}

- (void)copyLiveClipValue:(id)sender {
    NSString *value = CopyableTextForLiveClip([self primarySelectedAsset]);
    if (!value.length) {
        [self showTransientNotice:@"No value found"];
        return;
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:value forType:NSPasteboardTypeString];
    [self showTransientNotice:@"Value copied"];
}

- (void)copyLiveClipLabelAndValue:(id)sender {
    NSDictionary *content = [self primarySelectedAsset][@"liveClip"][@"extractedContent"];
    NSString *label = content[@"label"] ?: @"";
    NSString *value = content[@"displayValue"] ?: [content[@"numericValue"] stringValue] ?: @"";
    NSString *combined = label.length ? [NSString stringWithFormat:@"%@\t%@", label, value] : value;
    if (!combined.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:combined forType:NSPasteboardTypeString];
    [self showTransientNotice:@"Label and value copied"];
}

- (void)copyLiveClipImage:(id)sender {
    NSString *path = LiveClipImagePath([self primarySelectedAsset]);
    NSImage *image = path.length ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!image) {
        [self showTransientNotice:@"Image not available"];
        return;
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:@[image]];
    [self showTransientNotice:@"Image copied"];
}

- (void)openSourceForAsset:(NSDictionary *)asset {
    NSDictionary *source = LiveClipSource(asset);
    NSURL *sourceURL = WebURLFromText(source[@"sourceURL"]);
    if (sourceURL) {
        [self openURLWithSystemCommand:sourceURL asset:asset browserPath:nil];
        return;
    }
    NSString *documentPath = [source[@"documentPath"] isKindOfClass:NSString.class] ? source[@"documentPath"] : nil;
    NSString *finderPath = [source[@"finderPath"] isKindOfClass:NSString.class] ? source[@"finderPath"] : nil;
    NSString *path = documentPath.length ? documentPath : finderPath;
    if (path.length) {
        NSURL *url = [NSURL fileURLWithPath:path];
        if (finderPath.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
        else [NSWorkspace.sharedWorkspace openURL:url];
        return;
    }
    NSString *bundleID = source[@"bundleIdentifier"];
    NSRunningApplication *target = nil;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.bundleIdentifier isEqualToString:bundleID]) {
            target = app;
            break;
        }
    }
    if (target) {
        [target activateWithOptions:0];
        return;
    }
    NSURL *appURL = bundleID.length ? [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID] : nil;
    if (appURL) {
        [NSWorkspace.sharedWorkspace openApplicationAtURL:appURL configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:nil];
        return;
    }
    NSString *appName = source[@"applicationName"];
    if (appName.length) {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/open";
        task.arguments = @[@"-a", appName];
        @try { [task launch]; } @catch (__unused NSException *exception) {}
        return;
    }
    [self showTransientNotice:@"Source is not available"];
}

- (void)openSourceForSelectedLiveClip:(id)sender {
    [self openSourceForAsset:self.previewedAsset ?: [self primarySelectedAsset]];
}

- (NSImage *)captureImageForRect:(NSRect)absolute displayID:(CGDirectDisplayID)displayID {
    NSImage *screenImage = ImageForDisplay(displayID);
    if (!screenImage) return nil;
    NSScreen *screen = nil;
    for (NSScreen *candidate in NSScreen.screens) {
        if (DisplayIDForScreen(candidate) == displayID) {
            screen = candidate;
            break;
        }
    }
    if (!screen) return nil;
    NSRect local = NSMakeRect(NSMinX(absolute) - NSMinX(screen.frame), NSMinY(absolute) - NSMinY(screen.frame), NSWidth(absolute), NSHeight(absolute));
    return CroppedImageFromScreenImage(screenImage, local, screen.frame.size);
}

- (NSImage *)recaptureImageForLiveClip:(NSDictionary *)asset failure:(NSString **)failure {
    NSDictionary *source = LiveClipSource(asset);
    NSRect unionFrame = NSZeroRect;
    for (NSScreen *screen in NSScreen.screens) unionFrame = NSIsEmptyRect(unionFrame) ? screen.frame : NSUnionRect(unionFrame, screen.frame);
    NSArray *windows = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSDictionary *location = LiveClipResolveCurrentRegion(asset, windows, NSMaxY(unionFrame));
    NSString *reason = location[@"failure"];
    if (reason.length) {
        if ([source[@"sourceURL"] length]) [self openSourceForAsset:asset];
        if (failure) *failure = reason;
        return nil;
    }
    NSRect absolute = RectFromLiveClipDictionary(location[@"rect"]);
    CGDirectDisplayID displayID = [location[@"displayID"] unsignedIntValue];
    if (NSIsEmptyRect(absolute) || displayID == 0) {
        if (failure) *failure = @"Packs can't locate the original source.";
        return nil;
    }
    return [self captureImageForRect:absolute displayID:displayID];
}

- (NSImage *)recaptureImageForLiveClip:(NSDictionary *)asset {
    return [self recaptureImageForLiveClip:asset failure:nil];
}

- (BOOL)replaceLiveClip:(NSMutableDictionary *)asset withImage:(NSImage *)image markChanged:(BOOL)markChanged {
    NSData *png = PNGDataFromImage(image);
    NSURL *stored = [self storeImageData:png extension:@"png"];
    if (!stored) return NO;
    NSMutableDictionary *clip = asset[@"liveClip"];
    NSString *hash = ImageHashAtPath(stored.path);
    clip[@"capturedImage"] = stored.path;
    clip[@"latestCaptureHash"] = hash;
    clip[@"lastCheckedAt"] = @([[NSDate date] timeIntervalSince1970]).stringValue;
    clip[@"updatedAt"] = clip[@"lastCheckedAt"];
    if (markChanged) {
        clip[@"lastChangedAt"] = clip[@"lastCheckedAt"];
        asset[@"isNew"] = @YES;
    }
    asset[@"filePath"] = stored.path;
    asset[@"source"] = stored.path;
    [self saveState];
    [self render];
    return YES;
}

- (void)applyLiveClipRefreshToAsset:(NSMutableDictionary *)asset image:(NSImage *)image relocated:(BOOL)relocated {
    if (!asset || !image) return;
    NSData *png = PNGDataFromImage(image);
    NSString *newHash = SHA256ForData(png);
    if (!png.length || !newHash.length) {
        [self showTransientNotice:@"Could not refresh Live Clip"];
        return;
    }
    NSMutableDictionary *clip = asset[@"liveClip"];
    NSDictionary *oldClip = [clip copy];
    NSString *oldTitle = asset[@"title"];
    NSString *now = @([[NSDate date] timeIntervalSince1970]).stringValue;
    clip[@"refreshState"] = @"refreshing";
    clip[@"refreshFailureReason"] = @"";
    clip[@"refreshAttemptCount"] = @([clip[@"refreshAttemptCount"] integerValue] + 1);
    [self render];
    [self analyzeLiveClipAsset:asset image:image completion:^(NSDictionary *analysis) {
        BOOL changed = relocated || LiveClipStructuredContentChanged(oldClip, analysis, newHash);
        clip[@"lastCheckedAt"] = now;
        clip[@"updatedAt"] = now;
        clip[@"refreshState"] = @"idle";
        clip[@"refreshFailureReason"] = @"";
        if (changed) {
            NSURL *stored = [self storeImageData:png extension:@"png"];
            if (!stored) {
                if (oldClip[@"capturedImage"]) clip[@"capturedImage"] = oldClip[@"capturedImage"];
                if (oldClip[@"latestCaptureHash"]) clip[@"latestCaptureHash"] = oldClip[@"latestCaptureHash"];
                if (oldClip[@"extractedContent"]) clip[@"extractedContent"] = oldClip[@"extractedContent"];
                if (oldClip[@"contentType"]) clip[@"contentType"] = oldClip[@"contentType"];
                if (oldClip[@"extractedText"]) clip[@"extractedText"] = oldClip[@"extractedText"];
                if (oldClip[@"ocrItems"]) clip[@"ocrItems"] = oldClip[@"ocrItems"];
                if (oldClip[@"confidence"]) clip[@"confidence"] = oldClip[@"confidence"];
                if (oldTitle.length) asset[@"title"] = oldTitle;
                clip[@"refreshState"] = @"failed";
                clip[@"refreshFailureReason"] = @"Could not save Live Clip update.";
                [self saveState];
                [self render];
                [self showTransientNotice:clip[@"refreshFailureReason"]];
                return;
            }
            if (oldClip[@"extractedContent"]) clip[@"previousContent"] = oldClip[@"extractedContent"];
            if (oldClip[@"contentType"]) clip[@"previousContentType"] = oldClip[@"contentType"];
            if (oldClip[@"extractedText"]) clip[@"previousExtractedText"] = oldClip[@"extractedText"];
            if (oldClip[@"capturedImage"]) clip[@"previousCapture"] = oldClip[@"capturedImage"];
            if (oldClip[@"latestCaptureHash"]) clip[@"previousCaptureHash"] = oldClip[@"latestCaptureHash"];
            clip[@"capturedImage"] = stored.path;
            clip[@"latestCaptureHash"] = newHash;
            clip[@"lastChangedAt"] = now;
            asset[@"filePath"] = stored.path;
            asset[@"source"] = stored.path;
            asset[@"isNew"] = @YES;
            [self showTransientNotice:relocated ? @"Live Clip reconnected" : @"Live Clip updated"];
        } else {
            if (oldClip[@"capturedImage"]) clip[@"capturedImage"] = oldClip[@"capturedImage"];
            if (oldClip[@"latestCaptureHash"]) clip[@"latestCaptureHash"] = oldClip[@"latestCaptureHash"];
            if (oldClip[@"extractedContent"]) clip[@"extractedContent"] = oldClip[@"extractedContent"];
            if (oldClip[@"contentType"]) clip[@"contentType"] = oldClip[@"contentType"];
            if (oldClip[@"extractedText"]) clip[@"extractedText"] = oldClip[@"extractedText"];
            if (oldClip[@"ocrItems"]) clip[@"ocrItems"] = oldClip[@"ocrItems"];
            if (oldClip[@"confidence"]) clip[@"confidence"] = oldClip[@"confidence"];
            if (oldTitle.length) asset[@"title"] = oldTitle;
            [self showTransientNotice:@"No change"];
        }
        [self saveState];
        [self render];
    }];
}

- (void)checkSelectedLiveClipForChanges:(id)sender {
    NSMutableDictionary *asset = self.previewedAsset ?: [self primarySelectedAsset];
    if (!IsLiveClip(asset)) return;
    NSString *failure = nil;
    NSImage *image = [self recaptureImageForLiveClip:asset failure:&failure];
    if (!image) {
        asset[@"liveClip"][@"refreshState"] = @"failed";
        asset[@"liveClip"][@"refreshFailureReason"] = failure ?: @"Could not check that region.";
        [self saveState];
        [self showTransientNotice:asset[@"liveClip"][@"refreshFailureReason"]];
        return;
    }
    [self applyLiveClipRefreshToAsset:asset image:image relocated:NO];
}

- (void)refreshSelectedLiveClip:(id)sender {
    NSMutableDictionary *asset = self.previewedAsset ?: [self primarySelectedAsset];
    if (!IsLiveClip(asset)) return;
    NSString *failure = nil;
    NSImage *image = [self recaptureImageForLiveClip:asset failure:&failure];
    if (!image) {
        asset[@"liveClip"][@"refreshState"] = @"failed";
        asset[@"liveClip"][@"refreshFailureReason"] = failure ?: @"Could not refresh Live Clip.";
        [self saveState];
        [self showTransientNotice:asset[@"liveClip"][@"refreshFailureReason"]];
        return;
    }
    [self applyLiveClipRefreshToAsset:asset image:image relocated:NO];
}

- (void)relocateSelectedLiveClipSource:(id)sender {
    NSMutableDictionary *asset = self.previewedAsset ?: [self primarySelectedAsset];
    if (!IsLiveClip(asset)) return;
    self.relocatingLiveClipAsset = asset;
    [self beginLiveClipCapture:sender];
    [self showTransientNotice:@"Select the source region again"];
}

- (void)copySelectedAssets {
    NSArray<NSMutableDictionary *> *assets = [self selectedAssets];
    if (!assets.count) return;
    if (assets.count == 1) {
        [self copyAsset:assets.firstObject];
        return;
    }

    NSMutableArray<id<NSPasteboardWriting>> *writers = [NSMutableArray array];
    for (NSMutableDictionary *asset in assets) {
        id<NSPasteboardWriting> writer = AssetDragWriter(asset, YES);
        if (writer) [writers addObject:writer];
        asset[@"isNew"] = @NO;
    }
    if (!writers.count) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:writers];
    [self saveState];
    [self showTransientNotice:[NSString stringWithFormat:@"Copied %lu items", (unsigned long)writers.count]];
}

// Used to only preview a fixed whitelist of kinds (Image/PDF/Video/Note/
// LiveClip/Spreadsheet) and silently jump straight to an external app for
// everything else (plain files, archives, links) — one behavior for some
// kinds and a different, unexplained one for others. Quick Preview's own
// fallback branch already renders a thumbnail-or-icon plus an Open/Open
// Link button for anything with a file, URL, or text payload, so there's
// no reason to gate it by kind: one system, every kind of file.
- (void)activateAsset:(NSMutableDictionary *)asset {
    if (!asset) return;
    BOOL hasPreviewableContent = AssetFilePath(asset).length || [asset[@"preview"] length] || AssetPayload(asset).length || AssetOriginURL(asset) != nil;
    if (hasPreviewableContent) {
        [self showPreviewForAsset:asset];
        return;
    }
    [self openAsset:asset];
}

- (void)closePreview {
    [self flushPreviewNoteSave];
    [self.previewNoteSaveTimer invalidate];
    self.previewNoteSaveTimer = nil;
    self.previewNoteTextView = nil;
    [self.previewPanel orderOut:nil];
    self.previewPanel = nil;
    self.previewedAsset = nil;
    self.previewSpreadsheetSheets = nil;
    self.previewSpreadsheetTable = nil;
    self.previewSpreadsheetTabsStack = nil;
    if (self.panel.visible) [self.panel makeKeyAndOrderFront:nil];
}

- (void)flushPreviewNoteSave {
    if (!self.previewNoteTextView || !self.previewedAsset) return;
    NSString *text = self.previewNoteTextView.string ?: @"";
    self.previewedAsset[@"payload"] = text;
    self.previewedAsset[@"source"] = text;
    [self saveState];
}

- (void)textDidChange:(NSNotification *)notification {
    if (notification.object != self.previewNoteTextView) return;
    [self.previewNoteSaveTimer invalidate];
    self.previewNoteSaveTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(flushPreviewNoteSave) userInfo:nil repeats:NO];
}

// A dedicated blank-page composer, distinct from Quick Preview's edit-in-place
// for existing notes — this is for starting a new one, e.g. a fresh page of
// class notes before or during a lecture.
- (void)composeNewNote:(id)sender {
    [self.composeNotePanel orderOut:nil];

    CGFloat cardWidth = 380;
    CGFloat headerHeight = 40;
    CGFloat gap = 10;
    CGFloat titleFieldHeight = 34;
    CGFloat bodyHeight = 180;
    CGFloat saveRowHeight = 40;
    CGFloat bottomMargin = 16;
    CGFloat cardHeight = headerHeight + gap + titleFieldHeight + gap + bodyHeight + gap + saveRowHeight + bottomMargin;
    CGFloat margin = 20;
    CGFloat outerWidth = cardWidth + margin * 2;
    CGFloat outerHeight = cardHeight + margin * 2;

    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSPoint origin = NSMakePoint(NSMinX(self.panel.frame) - outerWidth - 12 + margin, NSMaxY(self.panel.frame) - outerHeight + margin);
    if (origin.x < NSMinX(visibleFrame)) origin.x = NSMaxX(self.panel.frame) + 12 - margin;
    origin = ClampedPanelOrigin(origin, NSMakeSize(outerWidth, outerHeight), visibleFrame);

    FocusPanel *panel = [[FocusPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, outerWidth, outerHeight) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    panel.controller = self;
    panel.floatingPanel = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *outer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, outerWidth, outerHeight)];
    outer.wantsLayer = YES;
    panel.contentView = outer;

    NSView *cardContainer = [[NSView alloc] initWithFrame:NSMakeRect(margin, margin, cardWidth, cardHeight)];
    cardContainer.wantsLayer = YES;
    cardContainer.layer.shadowColor = NSColor.blackColor.CGColor;
    cardContainer.layer.shadowOpacity = 0.5;
    cardContainer.layer.shadowRadius = 24;
    cardContainer.layer.shadowOffset = CGSizeMake(0, -8);
    [outer addSubview:cardContainer];

    NSVisualEffectView *glass = GlassBackdrop(cardContainer.bounds, 20, NSVisualEffectMaterialHUDWindow);
    // Same reasoning as the Ask AI panel and main shelf: a higher, consistent
    // opacity so this stays a solid dark surface regardless of what's behind
    // the window, instead of leaning on the "behind window" blur to fill in
    // most of its own background.
    glass.layer.backgroundColor = VoltScreenColor().CGColor;
    [cardContainer addSubview:glass];
    NSView *content = glass;

    // Same type scale as the rest of the app's floating panels — 13
    // semibold for the heading, 13 regular for body text.
    NSFont *headingFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSFont *bodyFont = [NSFont systemFontOfSize:13];

    CGFloat headerBottomY = cardHeight - headerHeight;
    NSTextField *heading = [NSTextField labelWithString:@"New Note"];
    heading.font = headingFont;
    heading.textColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
    heading.frame = NSMakeRect(16, headerBottomY + (headerHeight - 15) / 2, 200, 15);
    [content addSubview:heading];

    NSButton *close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"] target:self action:@selector(cancelComposeNote:)];
    close.bordered = NO;
    close.contentTintColor = [NSColor colorWithCalibratedWhite:0.6 alpha:1];
    close.frame = NSMakeRect(cardWidth - 16 - 22, headerBottomY + (headerHeight - 22) / 2, 22, 22);
    [content addSubview:close];

    CGFloat titleY = headerBottomY - gap - titleFieldHeight;
    NSView *titlePill = [[NSView alloc] initWithFrame:NSMakeRect(16, titleY, cardWidth - 32, titleFieldHeight)];
    titlePill.wantsLayer = YES;
    titlePill.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.06].CGColor;
    titlePill.layer.cornerRadius = 10;
    [content addSubview:titlePill];

    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, (titleFieldHeight - 20) / 2, NSWidth(titlePill.bounds) - 24, 20)];
    titleField.placeholderString = @"Note title (optional)";
    titleField.font = headingFont;
    titleField.textColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
    titleField.bordered = NO;
    titleField.focusRingType = NSFocusRingTypeNone;
    titleField.drawsBackground = NO;
    [titlePill addSubview:titleField];
    self.composeNoteTitleField = titleField;

    CGFloat bodyY = titleY - gap - bodyHeight;
    NSView *bodyPill = [[NSView alloc] initWithFrame:NSMakeRect(16, bodyY, cardWidth - 32, bodyHeight)];
    bodyPill.wantsLayer = YES;
    bodyPill.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.045].CGColor;
    bodyPill.layer.cornerRadius = 12;
    [content addSubview:bodyPill];

    NSScrollView *bodyScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(4, 4, NSWidth(bodyPill.bounds) - 8, NSHeight(bodyPill.bounds) - 8)];
    bodyScroll.drawsBackground = NO;
    bodyScroll.borderType = NSNoBorder;
    bodyScroll.hasVerticalScroller = YES;
    bodyScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *bodyView = [[NSTextView alloc] initWithFrame:bodyScroll.bounds];
    bodyView.editable = YES;
    bodyView.selectable = YES;
    bodyView.drawsBackground = NO;
    bodyView.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1];
    bodyView.font = bodyFont;
    bodyView.textContainerInset = NSMakeSize(8, 8);
    bodyScroll.documentView = bodyView;
    [bodyPill addSubview:bodyScroll];
    self.composeNoteBodyView = bodyView;

    NSButton *save = [NSButton buttonWithTitle:@"" target:self action:@selector(saveComposedNote:)];
    save.bordered = NO;
    save.wantsLayer = YES;
    save.layer.backgroundColor = VoltGoldColor().CGColor;
    save.layer.cornerRadius = saveRowHeight / 2;
    save.frame = NSMakeRect(16, bottomMargin, cardWidth - 32, saveRowHeight);
    save.attributedTitle = [[NSAttributedString alloc] initWithString:@"Save to Pack" attributes:@{
        NSFontAttributeName: headingFont,
        NSForegroundColorAttributeName: VoltScreenColor()
    }];
    [content addSubview:save];

    self.composeNotePanel = panel;
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:titleField];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)cancelComposeNote:(id)sender {
    [self.composeNotePanel orderOut:nil];
}

- (void)saveComposedNote:(id)sender {
    NSString *body = [self.composeNoteBodyView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!body.length) {
        [self showTransientNotice:@"Write something before saving"];
        return;
    }
    NSString *title = [self.composeNoteTitleField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!title.length) {
        NSString *firstLine = [body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject ?: @"";
        title = CleanSuggestedAssetTitle(firstLine) ?: @"Class Note";
    }
    [self addAssetWithTitle:title kind:@"Note" source:body uploader:self.userEmail.length ? self.userEmail : @"You"];
    [self.composeNotePanel orderOut:nil];
}

// The frictionless path: no panel, no title field, just the bottom bar on
// the shelf itself. addAssetWithTitle: already re-renders the whole shelf,
// which rebuilds this field empty — refocusing it after is what makes
// typing several quick notes in a row feel continuous instead of having to
// re-click into the field each time.
- (void)quickAddNoteSubmit:(id)sender {
    NSString *text = [self.quickAddNoteField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    NSString *firstLine = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject ?: text;
    NSString *title = CleanSuggestedAssetTitle(firstLine) ?: @"Note";
    [self addAssetWithTitle:title kind:@"Note" source:text uploader:self.userEmail.length ? self.userEmail : @"You"];
    [self.panel makeFirstResponder:self.quickAddNoteField];
}

- (void)openPreviewedAsset:(id)sender {
    NSMutableDictionary *asset = self.previewedAsset;
    [self closePreview];
    if (asset) [self openAsset:asset];
}

// Runs entirely on-device via Apple's Foundation Models framework (see
// AIExplainer.swift) — no API key, no network call, nothing leaves the Mac.
- (void)explainSelectedAsset:(id)sender {
    NSMutableDictionary *asset = [self primarySelectedAsset];
    if (!asset) return;
    if (![LPPAIExplainer isAvailable]) {
        NSString *reason = [LPPAIExplainer unavailabilityReason];
        [self showTransientNotice:reason.length ? reason : @"On-device AI isn't available right now"];
        return;
    }
    [self showExplanationForAsset:asset];
}

- (void)showExplanationForAsset:(NSMutableDictionary *)asset {
    [self.explainPanel orderOut:nil];

    CGFloat width = 420;
    CGFloat height = 260;
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSPoint origin = NSMakePoint(NSMinX(self.panel.frame) - width - 12, NSMaxY(self.panel.frame) - height);
    if (origin.x < NSMinX(visibleFrame)) origin.x = NSMaxX(self.panel.frame) + 12;
    origin = ClampedPanelOrigin(origin, NSMakeSize(width, height), visibleFrame);

    FocusPanel *panel = [[FocusPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, width, height) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    panel.controller = self;
    panel.title = @"Explain This";
    panel.floatingPanel = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = VoltScreenColor();
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    ApplyVoltScreenChrome(content);
    panel.contentView = content;

    NSTextField *titleLabel = [NSTextField labelWithString:asset[@"title"] ?: @"Untitled asset"];
    titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    titleLabel.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    titleLabel.frame = NSMakeRect(18, height - 34, width - 36, 18);
    [content addSubview:titleLabel];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 18, width - 36, height - 62)];
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    NSTextView *textView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    textView.editable = NO;
    textView.selectable = YES;
    textView.drawsBackground = NO;
    textView.textColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1];
    textView.font = [NSFont systemFontOfSize:14];
    textView.textContainerInset = NSMakeSize(0, 4);
    textView.textColor = [VoltTealColor() colorWithAlphaComponent:0.6];
    textView.string = @"Thinking…";
    scroll.documentView = textView;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:scroll];

    self.explainPanel = panel;
    [panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSString *assetTitle = asset[@"title"] ?: @"Untitled";
    NSString *kind = asset[@"kind"] ?: @"File";
    NSString *sample = TextSampleForAsset(asset);
    __weak AppController *weakSelf = self;
    [LPPAIExplainer explainAssetWithTitle:assetTitle kind:kind contentSample:sample completion:^(NSString * _Nullable result, NSString * _Nullable error) {
        AppController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.explainPanel != panel) return;
        textView.textColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1];
        textView.string = result.length ? result : [NSString stringWithFormat:@"Couldn't explain this: %@", error.length ? error : @"unknown error"];
    }];
}

- (void)showAskAIPanel:(id)sender {
    NSArray<NSMutableDictionary *> *selectedAtOpen = [self selectedAssets];
    NSMutableArray<NSString *> *contextIDs = [NSMutableArray array];
    for (NSDictionary *asset in selectedAtOpen) {
        NSString *assetID = asset[@"id"];
        if (assetID.length) [contextIDs addObject:assetID];
    }
    NSArray<NSString *> *newContextIDs = contextIDs.count ? [contextIDs copy] : @[];
    BOOL sameContext = self.askAIContextAssetIDs && [self.askAIContextAssetIDs isEqualToArray:newContextIDs];
    if (self.askAIPanel && sameContext) {
        [self.askAIPanel makeKeyAndOrderFront:nil];
        if (self.askAIQuestionView) [self.askAIPanel makeFirstResponder:self.askAIQuestionView];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResizeNotification object:self.askAIPanel];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidMoveNotification object:self.askAIPanel];
    [self.askAIPanel orderOut:nil];
    [self.askAITypewriterTimer invalidate];
    self.askAITypewriterTimer = nil;
    self.askAITypewriterMessageID = nil;
    self.askAITypewriterVisibleLength = 0;
    [self.askAICursorBlinkTimer invalidate];
    self.askAICursorBlinkTimer = nil;
    self.askAIModeIconView = nil;
    self.askAIEmptyStateView = nil;
    self.askAIMessages = [NSMutableArray array];
    self.askAIWaitingForResponse = NO;
    self.askAIContextAssetIDs = newContextIDs;
    self.askAIMode = self.askAIContextAssetIDs.count > 1 ? @"compare" : @"ask";

    // A free-roam window now, not a fixed popup: draggable by its own
    // background and resizable at the edges, remembering wherever it was
    // last left (size and position) instead of always recomputing a fixed
    // spot relative to the main shelf. Only that initial default (used the
    // very first time, or if the saved frame no longer fits any screen)
    // still derives from the sum of the header/input/body rows.
    CGFloat cardWidth = 400;
    CGFloat defaultCardHeight = 50 /*header*/ + 10 + 42 /*input*/ + 12 + 14 /*label*/ + 8 + 38 /*chips*/ + 16 /*bottom*/;
    CGFloat margin = 22;
    CGFloat minCardWidth = 320;
    CGFloat minCardHeight = 170;

    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSRect savedFrame = SavedNamedPanelFrame(kAskAIPanelFrameDefaultsKey);
    BOOL hasUsableSavedFrame = savedFrame.size.width >= (minCardWidth + margin * 2) && savedFrame.size.height >= (minCardHeight + margin * 2);

    CGFloat outerWidth, outerHeight;
    NSPoint origin;
    if (hasUsableSavedFrame) {
        outerWidth = savedFrame.size.width;
        outerHeight = savedFrame.size.height;
        origin = ClampedPanelOrigin(savedFrame.origin, NSMakeSize(outerWidth, outerHeight), visibleFrame);
    } else {
        outerWidth = cardWidth + margin * 2;
        outerHeight = defaultCardHeight + margin * 2;
        origin = NSMakePoint(NSMinX(self.panel.frame) - outerWidth - 12 + margin, NSMaxY(self.panel.frame) - outerHeight + margin);
        if (origin.x < NSMinX(visibleFrame)) origin.x = NSMaxX(self.panel.frame) + 12 - margin;
        origin = ClampedPanelOrigin(origin, NSMakeSize(outerWidth, outerHeight), visibleFrame);
    }

    // A frosted glass card floating free of any window chrome, with a soft
    // ambient glow bleeding out past its edges — the window itself is
    // transparent and larger than the visible card so that glow has room
    // to breathe without getting clipped at a hard rectangular edge.
    FocusPanel *panel = [[FocusPanel alloc] initWithContentRect:NSMakeRect(origin.x, origin.y, outerWidth, outerHeight) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    panel.controller = self;
    panel.floatingPanel = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.movableByWindowBackground = YES;
    panel.minSize = NSMakeSize(minCardWidth + margin * 2, minCardHeight + margin * 2);

    NSView *outer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, outerWidth, outerHeight)];
    outer.wantsLayer = YES;
    panel.contentView = outer;

    NSView *glowA = [[NSView alloc] initWithFrame:NSMakeRect(-30, outerHeight - 130, 160, 160)];
    glowA.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    glowA.wantsLayer = YES;
    glowA.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.5 green:0.32 blue:0.85 alpha:0.4].CGColor;
    glowA.layer.cornerRadius = 80;
    glowA.layer.shadowColor = glowA.layer.backgroundColor;
    glowA.layer.shadowRadius = 55;
    glowA.layer.shadowOpacity = 1;
    glowA.layer.shadowOffset = CGSizeZero;
    [outer addSubview:glowA];

    NSView *glowB = [[NSView alloc] initWithFrame:NSMakeRect(outerWidth - 130, -30, 160, 160)];
    glowB.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    glowB.wantsLayer = YES;
    glowB.layer.backgroundColor = [VoltTealColor() colorWithAlphaComponent:0.4].CGColor;
    glowB.layer.cornerRadius = 80;
    glowB.layer.shadowColor = glowB.layer.backgroundColor;
    glowB.layer.shadowRadius = 55;
    glowB.layer.shadowOpacity = 1;
    glowB.layer.shadowOffset = CGSizeZero;
    [outer addSubview:glowB];

    // The card container carries the drop shadow (unclipped); the glass
    // view inside it carries the blur and rounded-corner clip. Layer
    // shadows and masksToBounds fight on the same layer, so they're split
    // across two views. Both stretch with the window now — the glass view
    // already gets NSViewWidthSizable|HeightSizable from GlassBackdrop.
    NSView *cardContainer = [[NSView alloc] initWithFrame:NSMakeRect(margin, margin, outerWidth - margin * 2, outerHeight - margin * 2)];
    cardContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cardContainer.wantsLayer = YES;
    cardContainer.layer.shadowColor = NSColor.blackColor.CGColor;
    cardContainer.layer.shadowOpacity = 0.5;
    cardContainer.layer.shadowRadius = 24;
    cardContainer.layer.shadowOffset = CGSizeMake(0, -8);
    [outer addSubview:cardContainer];

    NSVisualEffectView *glass = GlassBackdrop(cardContainer.bounds, 20, NSVisualEffectMaterialHUDWindow);
    // Raised to match the main shelf's opacity (0.88) — at the old 0.55 this
    // panel's "behind window" blur leaned heavily on whatever was actually
    // behind it on screen, so it read as pale/washed-out over a light
    // background (a browser window, a light desktop) instead of staying a
    // consistent dark surface regardless of what's underneath it.
    glass.layer.backgroundColor = VoltScreenColor().CGColor;
    [cardContainer addSubview:glass];

    self.askAIContentView = glass;
    self.askAIPanel = panel;

    // A guaranteed, visible way to resize regardless of whether the native
    // borderless-window edge-drag behaves — see LPPResizeGrip above. Lives
    // on `outer`, not `content`, so it survives every content rebuild.
    CGFloat gripSize = 16;
    LPPResizeGrip *resizeGrip = [[LPPResizeGrip alloc] initWithFrame:NSMakeRect(outerWidth - gripSize - 6, 6, gripSize, gripSize)];
    resizeGrip.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    resizeGrip.targetWindow = panel;
    __weak AppController *weakSelfForGrip = self;
    resizeGrip.onResize = ^{
        AppController *strongSelf = weakSelfForGrip;
        if (!strongSelf) return;
        [strongSelf renderAskAIPanelBody];
        [strongSelf.askAIPanelSaveFrameTimer invalidate];
        strongSelf.askAIPanelSaveFrameTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:strongSelf selector:@selector(persistAskAIPanelFrame) userInfo:nil repeats:NO];
    };
    [outer addSubview:resizeGrip];

    [self renderAskAIPanelBody];

    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:self.askAIQuestionView];
    [NSApp activateIgnoringOtherApps:YES];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(askAIPanelFrameDidChange:) name:NSWindowDidResizeNotification object:panel];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(askAIPanelFrameDidChange:) name:NSWindowDidMoveNotification object:panel];
}

// Everything inside the card — rebuilt from scratch against the card's
// *current* size, same "tear down and redraw" approach the main shelf's
// render() already uses. Called once at creation and again on every resize,
// which is what makes the header/input/chips actually reflow instead of
// staying pinned to whatever size the window was first opened at.
- (void)renderAskAIPanelBody {
    NSView *content = self.askAIContentView;
    if (!content) return;
    [content.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    CGFloat cardWidth = NSWidth(content.bounds);
    CGFloat cardHeight = NSHeight(content.bounds);

    CGFloat headerHeight = 50;
    CGFloat gapHeaderToInput = 10;
    CGFloat inputHeight = 42;
    CGFloat gapInputToBody = 12;
    CGFloat quickLabelHeight = 14;
    CGFloat gapLabelToChips = 8;
    CGFloat bottomMargin = 16;

    // One type scale, reused everywhere in this panel and matched to what
    // the main shelf already uses (13 semibold for names/titles, 11 for
    // secondary status text) — mismatched ad hoc sizes per element was
    // most of why this read as a different app from the rest of Packs.
    NSFont *headingFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSFont *bodyFont = [NSFont systemFontOfSize:13];
    NSFont *metaFont = [NSFont systemFontOfSize:11];
    NSFont *microFont = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];

    CGFloat headerBottomY = cardHeight - headerHeight;
    CGFloat headerMidY = headerBottomY + headerHeight / 2;

    // Sits underneath the avatar/name/status/pill/close — added first, so
    // those still get their own clicks (later-added subviews win hit
    // testing), and anywhere else in this row starts a real window drag.
    LPPPanelDragHandle *dragHandle = [[LPPPanelDragHandle alloc] initWithFrame:NSMakeRect(0, headerBottomY, cardWidth, headerHeight)];
    [content addSubview:dragHandle];

    NSImageView *avatar = [[NSImageView alloc] initWithFrame:NSMakeRect(16, headerMidY - 15, 30, 30)];
    avatar.image = BundledPNG(@"volt-mascot-idle");
    avatar.imageScaling = NSImageScaleProportionallyUpOrDown;
    avatar.wantsLayer = YES;
    avatar.layer.cornerRadius = 15;
    avatar.layer.masksToBounds = YES;
    avatar.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.06].CGColor;
    [content addSubview:avatar];
    self.askAIAvatarView = avatar;

    NSTextField *nameLabel = [NSTextField labelWithString:@"Volt"];
    nameLabel.font = headingFont;
    nameLabel.textColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
    nameLabel.frame = NSMakeRect(54, headerMidY + 1, 160, 15);
    [content addSubview:nameLabel];

    NSString *statusText = self.askAIWaitingForResponse ? @"Thinking…" : @"Online";
    NSTextField *statusLabel = [NSTextField labelWithString:statusText];
    statusLabel.font = metaFont;
    statusLabel.textColor = [NSColor colorWithCalibratedWhite:0.55 alpha:1];
    statusLabel.frame = NSMakeRect(54, headerMidY - 14, 220, 13);
    [content addSubview:statusLabel];
    self.askAIStatusLabel = statusLabel;
    if (self.askAIWaitingForResponse) [self beginAskAIThinkingIndicator];

    NSButton *close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"] target:self action:@selector(closeAskAIPanel:)];
    close.bordered = NO;
    close.contentTintColor = [NSColor colorWithCalibratedWhite:0.6 alpha:1];
    close.frame = NSMakeRect(cardWidth - 16 - 22, headerMidY - 11, 22, 22);
    [content addSubview:close];

    // Reuses the existing mode tracker (already updated after every
    // question in submitAskAIQuestion:) as a live status icon instead of
    // adding a second, redundant piece of state.
    CGFloat modeIconSize = 26;
    NSImageView *modeIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(cardWidth - 16 - 22 - 8 - modeIconSize, headerMidY - modeIconSize / 2, modeIconSize, modeIconSize)];
    modeIcon.image = ChipBadgeImage(PackAIModeSymbol(self.askAIMode), VoltTealColor(), modeIconSize, 12);
    modeIcon.toolTip = PackAIModeLabel(self.askAIMode);
    [content addSubview:modeIcon];
    self.askAIModeIconView = modeIcon;

    CGFloat inputY = headerBottomY - gapHeaderToInput - inputHeight;
    NSView *inputPill = [[NSView alloc] initWithFrame:NSMakeRect(16, inputY, cardWidth - 32, inputHeight)];
    inputPill.wantsLayer = YES;
    inputPill.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.06].CGColor;
    inputPill.layer.cornerRadius = inputHeight / 2;
    [content addSubview:inputPill];

    NSImageView *searchGlyph = [[NSImageView alloc] initWithFrame:NSMakeRect(16, (inputHeight - 16) / 2, 16, 16)];
    searchGlyph.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
    searchGlyph.contentTintColor = [NSColor colorWithCalibratedWhite:0.5 alpha:1];
    [inputPill addSubview:searchGlyph];

    CGFloat sendSize = 30;
    NSButton *send = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.up" accessibilityDescription:@"Send"] target:self action:@selector(submitAskAIQuestion:)];
    send.bordered = NO;
    send.imagePosition = NSImageOnly;
    send.contentTintColor = VoltScreenColor();
    send.wantsLayer = YES;
    send.layer.backgroundColor = VoltGoldColor().CGColor;
    send.layer.cornerRadius = sendSize / 2;
    send.frame = NSMakeRect(NSWidth(inputPill.bounds) - 6 - sendSize, (inputHeight - sendSize) / 2, sendSize, sendSize);
    send.toolTip = @"Send";
    [inputPill addSubview:send];

    // NSTextField top-aligns its text when the frame is much taller than one
    // line — giving it the full pill height (like the icon/button frames)
    // left the text sitting near the top instead of centered. A frame sized
    // to the text's own line height, centered the same way, fixes it.
    CGFloat questionFieldHeight = 20;
    NSTextField *questionField = [[NSTextField alloc] initWithFrame:NSMakeRect(42, (inputHeight - questionFieldHeight) / 2, NSWidth(inputPill.bounds) - 42 - sendSize - 14, questionFieldHeight)];
    questionField.placeholderString = @"Ask about this Pack…";
    questionField.font = bodyFont;
    questionField.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1];
    questionField.bordered = NO;
    questionField.focusRingType = NSFocusRingTypeNone;
    questionField.drawsBackground = NO;
    questionField.target = self;
    questionField.action = @selector(submitAskAIQuestion:);
    [inputPill addSubview:questionField];
    self.askAIQuestionView = questionField;

    // The body (transcript / quick actions) is whatever's left after the
    // fixed-height rows above — this is the part that actually grows when
    // the panel is resized taller.
    CGFloat bodyTop = inputY - gapInputToBody;
    CGFloat bodyHeight = MAX(50, bodyTop - bottomMargin);
    NSRect bodyFrame = NSMakeRect(16, bottomMargin, cardWidth - 32, bodyHeight);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:bodyFrame];
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *answerView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    answerView.editable = NO;
    answerView.selectable = YES;
    answerView.drawsBackground = NO;
    answerView.textColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1];
    answerView.font = bodyFont;
    answerView.textContainerInset = NSMakeSize(4, 8);
    scroll.documentView = answerView;
    [content addSubview:scroll];
    self.askAIAnswerView = answerView;

    // Quick actions fill the empty state instead of a bare headline — real,
    // pre-written prompts a first-time user can just tap instead of having
    // to think of something to ask.
    NSView *emptyState = [[NSView alloc] initWithFrame:bodyFrame];
    emptyState.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *quickLabel = [NSTextField labelWithString:@"QUICK ACTIONS"];
    quickLabel.font = microFont;
    quickLabel.textColor = [NSColor colorWithCalibratedWhite:0.4 alpha:1];
    quickLabel.frame = NSMakeRect(0, NSHeight(emptyState.bounds) - quickLabelHeight, NSWidth(emptyState.bounds), quickLabelHeight);
    [emptyState addSubview:quickLabel];

    NSArray *quickActions = @[
        @[@"Summarize", @"Key points", @"text.alignleft", VoltTealColor(), @"Summarize this Pack in a few bullet points."],
        @[@"Explain", @"What & why", @"sparkles", VoltGoldColor(), @"Explain what this Pack is about and why it matters."],
        @[@"Compare", @"Differences", @"arrow.left.arrow.right", [NSColor colorWithCalibratedRed:0.45 green:0.58 blue:0.85 alpha:1], @"Compare the items in this Pack and highlight differences."],
        @[@"Organize", @"Get ideas", @"tray.full", [NSColor colorWithCalibratedRed:0.82 green:0.4 blue:0.52 alpha:1], @"Suggest how I could better organize this Pack."]
    ];
    CGFloat chipGap = 8;
    CGFloat chipWidth = (NSWidth(emptyState.bounds) - chipGap * (quickActions.count - 1)) / quickActions.count;
    CGFloat badgeSize = 30;
    // Chips center in whatever room is left below the label instead of
    // sitting at one fixed offset — otherwise a taller resized panel would
    // leave them stranded near the top with empty space below.
    CGFloat chipsAreaHeight = MAX(badgeSize, NSHeight(emptyState.bounds) - quickLabelHeight - gapLabelToChips);
    CGFloat chipY = (chipsAreaHeight - badgeSize) / 2;
    self.askAIQuickPrompts = [NSMutableArray array];
    for (NSUInteger i = 0; i < quickActions.count; i++) {
        NSArray *entry = quickActions[i];
        NSString *title = entry[0];
        NSString *subtitle = entry[1];
        NSString *symbol = entry[2];
        NSColor *tint = entry[3];
        [self.askAIQuickPrompts addObject:entry[4]];

        // Icon only now — no translucent card behind it, no title/subtitle
        // text. The badge's own baked-in color is the only chrome; the name
        // is still there as a tooltip for anyone hovering to double-check.
        NSButton *chip = [NSButton buttonWithImage:ChipBadgeImage(symbol, tint, badgeSize, 14) target:self action:@selector(askAISuggestionTapped:)];
        chip.tag = i;
        chip.bordered = NO;
        chip.imagePosition = NSImageOnly;
        chip.toolTip = [NSString stringWithFormat:@"%@ — %@", title, subtitle];
        CGFloat slotX = i * (chipWidth + chipGap);
        chip.frame = NSMakeRect(slotX + (chipWidth - badgeSize) / 2, chipY, badgeSize, badgeSize);
        [emptyState addSubview:chip];
    }

    [content addSubview:emptyState];
    self.askAIEmptyStateView = emptyState;

    // Same signature streak as the main shelf, same rule: amber at rest,
    // purple/blue while actually thinking — the AI panel doesn't get its
    // own decoration, it plugs into the one product-wide state.
    [self refreshAskAIRimGlow];

    [self refreshAskAIConversationView];
}

// Live relayout on every resize/move tick (cheap enough to rebuild each
// time — a dozen views — and rebuilding is what makes the reflow visible
// as you drag, not just after you let go). Only the on-disk save is
// debounced, so dragging doesn't hammer NSUserDefaults.
- (void)askAIPanelFrameDidChange:(NSNotification *)notification {
    if (notification.object != self.askAIPanel) return;
    [self renderAskAIPanelBody];
    [self.askAIPanelSaveFrameTimer invalidate];
    self.askAIPanelSaveFrameTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(persistAskAIPanelFrame) userInfo:nil repeats:NO];
}

- (void)persistAskAIPanelFrame {
    if (!self.askAIPanel) return;
    SaveNamedPanelFrame(kAskAIPanelFrameDefaultsKey, self.askAIPanel.frame);
}

- (void)closeAskAIPanel:(id)sender {
    [self.askAIPanelSaveFrameTimer invalidate];
    [self persistAskAIPanelFrame];
    [self.askAIPanel orderOut:nil];
}

// The blinking transcript cursor alone was too easy to miss — this gives
// "the model is working" an actual physical cue: Volt's avatar breathes
// while waiting, and the status line says so in words too.
- (void)beginAskAIThinkingIndicator {
    self.askAIStatusLabel.stringValue = @"Thinking…";
    self.askAIStatusLabel.textColor = VoltTealColor();
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @(1.0);
    pulse.toValue = @(0.35);
    pulse.duration = 0.85;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.askAIAvatarView.layer addAnimation:pulse forKey:@"thinkingPulse"];
    [self refreshAskAIRimGlow];
    // The Pack window's own perimeter streak is the product-wide "AI is
    // active" signal, not just something inside this panel — it needs to
    // flip to purple/blue the moment thinking starts, which means the main
    // shelf has to re-render too, not just this panel.
    if (self.panel.visible) [self render];
}

- (void)endAskAIThinkingIndicator {
    [self.askAIAvatarView.layer removeAnimationForKey:@"thinkingPulse"];
    self.askAIStatusLabel.stringValue = @"Online";
    self.askAIStatusLabel.textColor = [NSColor colorWithCalibratedWhite:0.55 alpha:1];
    [self refreshAskAIRimGlow];
    if (self.panel.visible) [self render];
}

// Centralizing "remove whatever rim glow is currently there, add a fresh
// one" in one place matters here specifically: renderAskAIPanelBody (full
// rebuild on resize) and begin/endAskAIThinkingIndicator (state change with
// no rebuild) can both run inside the same tick if a resize happens while
// the AI is mid-response. Each going through this same property-guarded
// swap — instead of each inlining its own AddRimGlowOverlay call — is what
// keeps that from leaving an orphaned, still-animating glow layer behind.
- (void)refreshAskAIRimGlow {
    [self.askAIRimGlowView removeFromSuperview];
    self.askAIRimGlowView = AddRimGlowOverlay(self.askAIContentView, 20, self.askAIWaitingForResponse);
}

// The model only ever sees a saved item's title in its context (see
// PackContextSummary), never its id, so any action it wants to take on a
// specific asset has to name it by title. Exact match first; a substring
// match either direction as a fallback for minor rephrasing.
- (NSMutableDictionary *)assetInSelectedPackMatchingTitle:(NSString *)title {
    NSString *needle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (!needle.length) return nil;
    NSMutableDictionary *partial = nil;
    for (NSMutableDictionary *asset in [self selectedPack][@"assets"]) {
        NSString *assetTitle = [asset[@"title"] isKindOfClass:NSString.class] ? asset[@"title"] : @"";
        NSString *hay = assetTitle.lowercaseString;
        if ([hay isEqualToString:needle]) return asset;
        if (!partial && hay.length && ([hay containsString:needle] || [needle containsString:hay])) partial = asset;
    }
    return partial;
}

// Pack AI's tool-calling protocol: a small, local instruction-following
// model can't be trusted with a native function-calling API, so instead
// it's told (in the system prompt) to emit a plain "ACTION: {json}" line
// when it wants to do something. This finds every such line, executes it,
// and swaps it out for a plain-English confirmation (or a warning) before
// the reply is shown — the user never sees raw JSON.
- (NSString *)executeAskAIActionsInReply:(NSString *)reply {
    NSRegularExpression *actionPattern = [NSRegularExpression regularExpressionWithPattern:@"(?m)^ACTION:\\s*(\\{.*\\})\\s*$" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [actionPattern matchesInString:reply options:0 range:NSMakeRange(0, reply.length)];
    if (!matches.count) return reply;

    NSMutableString *cleaned = [reply mutableCopy];
    NSMutableArray<NSString *> *confirmations = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *jsonText = [reply substringWithRange:[match rangeAtIndex:1]];
        NSString *confirmation = [self performAskAIActionFromJSON:jsonText];
        if (confirmation.length) [confirmations insertObject:confirmation atIndex:0];
        [cleaned deleteCharactersInRange:[match rangeAtIndex:0]];
    }
    NSString *trimmedText = [cleaned stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!confirmations.count) return trimmedText.length ? trimmedText : reply;
    NSString *confirmationBlock = [confirmations componentsJoinedByString:@"\n"];
    return trimmedText.length ? [NSString stringWithFormat:@"%@\n\n%@", trimmedText, confirmationBlock] : confirmationBlock;
}

- (NSString *)performAskAIActionFromJSON:(NSString *)jsonText {
    NSData *data = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *action = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *type = [action[@"type"] isKindOfClass:NSString.class] ? action[@"type"] : nil;
    if (!type.length) return @"⚠️ Couldn't understand that action.";

    if ([type isEqualToString:@"create_note"]) {
        NSString *content = [action[@"content"] isKindOfClass:NSString.class] ? action[@"content"] : nil;
        if (!content.length) return @"⚠️ Tried to create a note but had no content for it.";
        NSString *title = [action[@"title"] isKindOfClass:NSString.class] ? action[@"title"] : nil;
        if (!title.length) {
            NSString *firstLine = [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject ?: @"";
            title = CleanSuggestedAssetTitle(firstLine) ?: @"Note";
        }
        [self addAssetWithTitle:title kind:@"Note" source:content uploader:self.userEmail.length ? self.userEmail : @"You"];
        return [NSString stringWithFormat:@"✓ Created note “%@”", title];
    }

    NSString *targetTitle = [action[@"title"] isKindOfClass:NSString.class] ? action[@"title"] : nil;
    NSMutableDictionary *targetAsset = targetTitle.length ? [self assetInSelectedPackMatchingTitle:targetTitle] : nil;

    if ([type isEqualToString:@"trash_asset"]) {
        if (!targetAsset) return [NSString stringWithFormat:@"⚠️ Couldn't find a saved item titled “%@” to trash.", targetTitle ?: @"?"];
        NSString *foundTitle = targetAsset[@"title"];
        [self trashAssets:@[targetAsset]];
        return [NSString stringWithFormat:@"✓ Moved “%@” to Trash", foundTitle];
    }
    if ([type isEqualToString:@"tag_asset"]) {
        if (!targetAsset) return [NSString stringWithFormat:@"⚠️ Couldn't find a saved item titled “%@” to tag.", targetTitle ?: @"?"];
        NSArray *rawTags = [action[@"tags"] isKindOfClass:NSArray.class] ? action[@"tags"] : nil;
        NSMutableArray<NSString *> *tags = [NSMutableArray array];
        for (id tag in rawTags) if ([tag isKindOfClass:NSString.class] && [tag length]) [tags addObject:tag];
        if (!tags.count) return [NSString stringWithFormat:@"⚠️ No tags given for “%@”.", targetAsset[@"title"]];
        NSMutableArray<NSString *> *existing = [NSMutableArray arrayWithArray:[targetAsset[@"tags"] isKindOfClass:NSArray.class] ? targetAsset[@"tags"] : @[]];
        for (NSString *tag in tags) if (![existing containsObject:tag]) [existing addObject:tag];
        targetAsset[@"tags"] = existing;
        [self saveState];
        [self render];
        return [NSString stringWithFormat:@"✓ Tagged “%@” with %@", targetAsset[@"title"], [tags componentsJoinedByString:@", "]];
    }
    if ([type isEqualToString:@"open_asset"]) {
        if (!targetAsset) return [NSString stringWithFormat:@"⚠️ Couldn't find a saved item titled “%@” to open.", targetTitle ?: @"?"];
        [self activateAsset:targetAsset];
        return [NSString stringWithFormat:@"✓ Opened “%@”", targetAsset[@"title"]];
    }
    return [NSString stringWithFormat:@"⚠️ Unknown action “%@”.", type];
}

// A running conversation, not one-question-one-answer: each call resends the
// whole transcript (Ollama's /api/chat has no server-side session), and the
// question field is cleared but the panel stays open so a follow-up is just
// another question away.
- (void)submitAskAIQuestion:(id)sender {
    if (self.askAIWaitingForResponse) return;
    NSString *question = [self.askAIQuestionView.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!question.length) return;
    self.askAIQuestionView.stringValue = @"";
    self.askAIMode = PackAIModeForQuestion(question, self.askAIContextAssetIDs.count);
    if (self.askAIModeIconView) {
        self.askAIModeIconView.image = ChipBadgeImage(PackAIModeSymbol(self.askAIMode), VoltTealColor(), NSWidth(self.askAIModeIconView.frame), 12);
        self.askAIModeIconView.toolTip = PackAIModeLabel(self.askAIMode);
    }

    if (!self.askAIMessages.count) {
        NSMutableArray<NSMutableDictionary *> *contextAssets = [NSMutableArray array];
        if (self.askAIContextAssetIDs.count) {
            NSSet<NSString *> *ids = [NSSet setWithArray:self.askAIContextAssetIDs];
            for (NSMutableDictionary *asset in [self selectedPack][@"assets"]) {
                NSString *assetID = asset[@"id"];
                if (assetID.length && [ids containsObject:assetID]) [contextAssets addObject:asset];
            }
        }
        NSString *context = self.askAIContextAssetIDs.count ? PackContextSummaryForAssets(contextAssets) : PackContextSummary([self selectedPack], question);
        NSString *scope = self.askAIContextAssetIDs.count ? @"selected saved items" : @"the full Pack";
        NSString *modeInstructions = PackAIModeInstructions(self.askAIMode);
        NSString *systemPrompt = [NSString stringWithFormat:
            @"You are Pack AI inside LiveProjectPacks. The user is working from %@ in \"%@\".\n\nSaved context:\n%@\n\nBehavior:\n- Answer from the saved context first.\n- Be concise and useful. No preamble.\n- Do not reveal chain-of-thought or thinking tags.\n- If the context is weak, say what is missing.\n- Cite saved item titles when useful.\n- Make outputs easy to save back into the Pack.\n\nCurrent mode: %@.\n%@\n\nActions: you can take one of these actions when the user actually asks for it (never on your own initiative, never to demonstrate). Reference saved items by their exact title. Put each action on its own line, the whole JSON object on that one line, in this exact form:\nACTION: {\"type\": \"create_note\", \"title\": \"optional title\", \"content\": \"note text\"}\nACTION: {\"type\": \"trash_asset\", \"title\": \"exact saved item title\"}\nACTION: {\"type\": \"tag_asset\", \"title\": \"exact saved item title\", \"tags\": [\"tag1\", \"tag2\"]}\nACTION: {\"type\": \"open_asset\", \"title\": \"exact saved item title\"}\nYou may still write a short sentence before or after an ACTION line. Only emit an ACTION when it directly does what the user asked; otherwise just answer normally with no ACTION line at all.",
            scope, self.currentPackName, context, PackAIModeLabel(self.askAIMode), modeInstructions];
        [self.askAIMessages addObject:@{ @"role": @"system", @"content": systemPrompt }];
    }
    NSString *modeNote = [NSString stringWithFormat:@"Mode for this request: %@. %@\n\nUser request: %@", PackAIModeLabel(self.askAIMode), PackAIModeInstructions(self.askAIMode), question];
    [self.askAIMessages addObject:@{ @"role": @"user", @"content": modeNote, @"displayContent": question, @"mode": self.askAIMode ?: @"ask" }];
    self.askAIWaitingForResponse = YES;
    [self beginAskAIThinkingIndicator];
    [self refreshAskAIConversationView];

    NSPanel *panelAtCallTime = self.askAIPanel;
    NSArray<NSDictionary *> *messagesSnapshot = [self.askAIMessages copy];
    __weak AppController *weakSelf = self;
    CallLocalModel(messagesSnapshot, ^(NSString * _Nullable text, NSString * _Nullable error) {
        AppController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.askAIPanel != panelAtCallTime) return;
        strongSelf.askAIWaitingForResponse = NO;
        [strongSelf endAskAIThinkingIndicator];
        NSString *reply = text.length ? [strongSelf executeAskAIActionsInReply:text] : [NSString stringWithFormat:@"Couldn't get an answer: %@", error.length ? error : @"unknown error"];
        NSString *messageID = NSUUID.UUID.UUIDString;
        [strongSelf.askAIMessages addObject:@{ @"role": @"assistant", @"content": reply, @"id": messageID }];
        [strongSelf beginTypewriterForLatestAIMessage];
    });
}

- (void)beginTypewriterForLatestAIMessage {
    [self.askAITypewriterTimer invalidate];
    self.askAITypewriterTimer = nil;
    NSDictionary *latest = self.askAIMessages.lastObject;
    if (![latest[@"role"] isEqualToString:@"assistant"] || ![latest[@"content"] length]) {
        [self refreshAskAIConversationView];
        return;
    }
    self.askAITypewriterMessageID = latest[@"id"] ?: @"";
    self.askAITypewriterVisibleLength = 0;
    [self refreshAskAIConversationView];
    __weak AppController *weakSelf = self;
    self.askAITypewriterTimer = [NSTimer scheduledTimerWithTimeInterval:0.018 repeats:YES block:^(NSTimer *timer) {
        [weakSelf advanceAITypewriter:timer];
    }];
}

- (void)advanceAITypewriter:(NSTimer *)timer {
    NSDictionary *latest = self.askAIMessages.lastObject;
    NSString *messageID = latest[@"id"] ?: @"";
    NSString *content = latest[@"content"] ?: @"";
    if (!content.length || ![messageID isEqualToString:self.askAITypewriterMessageID ?: @""]) {
        [timer invalidate];
        if (timer == self.askAITypewriterTimer) self.askAITypewriterTimer = nil;
        return;
    }
    NSUInteger step = content.length > 700 ? 6 : 3;
    self.askAITypewriterVisibleLength = MIN(content.length, self.askAITypewriterVisibleLength + step);
    [self refreshAskAIConversationView];
    if (self.askAITypewriterVisibleLength >= content.length) {
        [timer invalidate];
        if (timer == self.askAITypewriterTimer) self.askAITypewriterTimer = nil;
    }
}

- (void)saveLatestAIResultToPack:(id)sender {
    NSDictionary *latestAssistant = nil;
    for (NSDictionary *message in self.askAIMessages.reverseObjectEnumerator) {
        if ([message[@"role"] isEqualToString:@"assistant"] && [message[@"content"] length]) {
            latestAssistant = message;
            break;
        }
    }
    NSString *content = latestAssistant[@"content"];
    if (!content.length) {
        [self showTransientNotice:@"No AI result to save yet"];
        return;
    }

    NSString *firstLine = [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject ?: @"";
    NSString *cleanTitle = CleanSuggestedAssetTitle(firstLine);
    if (!cleanTitle.length || cleanTitle.length < 4) cleanTitle = @"Saved AI Result";
    NSString *title = [NSString stringWithFormat:@"AI: %@", cleanTitle];
    NSArray<NSDictionary *> *messages = [self.askAIMessages copy];
    NSArray<NSString *> *contextIDs = [self.askAIContextAssetIDs copy];
    BOOL waiting = self.askAIWaitingForResponse;
    [self addAssetWithTitle:title kind:@"Note" source:content uploader:self.userEmail.length ? self.userEmail : @"You"];
    self.askAIMessages = [messages mutableCopy];
    self.askAIContextAssetIDs = contextIDs;
    self.askAIWaitingForResponse = waiting;
    [self refreshAskAIConversationView];
    [self showTransientNotice:@"AI result saved to Pack"];
}

- (void)askAISuggestionTapped:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.askAIQuickPrompts.count) return;
    self.askAIQuestionView.stringValue = self.askAIQuickPrompts[index];
    [self submitAskAIQuestion:sender];
}

// A cursor that's just always present as a static "|" reads as inert — an
// actually-blinking one (toggled on a timer, like a real terminal caret) is
// most of what "feels alive" even means here. Runs only while there's
// something to show a cursor for, so it isn't animating a static screen.
- (void)tickAskAICursorBlink {
    self.askAICursorBlinkOn = !self.askAICursorBlinkOn;
    [self refreshAskAIConversationView];
}

- (void)refreshAskAIConversationView {
    NSTextView *view = self.askAIAnswerView;
    if (!view) return;

    BOOL hasMessages = self.askAIMessages.count > 0;
    self.askAIEmptyStateView.hidden = hasMessages;

    BOOL needsCursor = self.askAIWaitingForResponse || (self.askAITypewriterMessageID.length > 0);
    if (needsCursor && !self.askAICursorBlinkTimer) {
        self.askAICursorBlinkOn = YES;
        self.askAICursorBlinkTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tickAskAICursorBlink) userInfo:nil repeats:YES];
    } else if (!needsCursor && self.askAICursorBlinkTimer) {
        [self.askAICursorBlinkTimer invalidate];
        self.askAICursorBlinkTimer = nil;
    }

    // Plain system font now, matching the rest of the panel — the old
    // monospaced "terminal" look was left over from an earlier console-style
    // direction and was the biggest reason the transcript read as a
    // different app from the header and input around it. User vs. assistant
    // is now just weight and color, not a font-family switch.
    NSDictionary *userAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1]
    };
    NSDictionary *bodyAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.82 alpha:1]
    };
    NSDictionary *cursorAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: self.askAICursorBlinkOn ? VoltTealColor() : [VoltTealColor() colorWithAlphaComponent:0]
    };

    NSMutableAttributedString *transcript = [[NSMutableAttributedString alloc] init];
    if (!hasMessages) {
        [view.textStorage setAttributedString:transcript];
        return;
    }

    for (NSDictionary *message in self.askAIMessages) {
        NSString *role = message[@"role"];
        if ([role isEqualToString:@"system"]) continue;
        BOOL isUser = [role isEqualToString:@"user"];
        NSString *content = message[@"displayContent"] ?: message[@"content"] ?: @"";
        BOOL isTyping = !isUser && [message[@"id"] isEqualToString:self.askAITypewriterMessageID ?: @""] && self.askAITypewriterVisibleLength < content.length;
        if (isTyping) {
            NSRange visibleRange = [content rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, self.askAITypewriterVisibleLength)];
            content = [content substringWithRange:visibleRange];
        }
        [transcript appendAttributedString:[[NSAttributedString alloc] initWithString:content attributes:isUser ? userAttrs : bodyAttrs]];
        if (isTyping) [transcript appendAttributedString:[[NSAttributedString alloc] initWithString:@"▍" attributes:cursorAttrs]];
        [transcript appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:bodyAttrs]];
    }

    if (self.askAIWaitingForResponse) {
        [transcript appendAttributedString:[[NSAttributedString alloc] initWithString:@"▍" attributes:cursorAttrs]];
    }

    [view.textStorage setAttributedString:transcript];
    [view scrollRangeToVisible:NSMakeRange(transcript.length, 0)];
}

- (void)characterDockItemTapped:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.characters.count) return;
    [self.characters[index] characterTappedWithController:self anchorButton:sender];
}

// Same Vision framework and dispatch pattern already used for Live Clip OCR
// (see the text-recognition request above): off the main thread, since
// Vision processing a full-size screenshot is not instant, with the result
// handed back on main. VNDetectBarcodesRequest already understands QR
// codes natively — no third-party decoding needed.
static void DetectQRCodeURLInImage(NSImage *image, void (^completion)(NSURL * _Nullable url)) {
    CGImageRef cgImage = image ? [image CGImageForProposedRect:NULL context:nil hints:nil] : NULL;
    if (!cgImage) {
        completion(nil);
        return;
    }
    CGImageRetain(cgImage);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
        request.symbologies = @[VNBarcodeSymbologyQR];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
        [handler performRequests:@[request] error:nil];
        CGImageRelease(cgImage);
        NSURL *found = nil;
        for (VNBarcodeObservation *observation in request.results ?: @[]) {
            NSURL *candidate = WebURLFromText(observation.payloadStringValue);
            if (candidate) { found = candidate; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(found); });
    });
}

- (void)openDetectedQRLink:(id)sender {
    if (!self.previewedQRURL) return;
    [self openURLWithSystemCommand:self.previewedQRURL asset:self.previewedAsset browserPath:nil];
}

- (void)showPreviewForAsset:(NSMutableDictionary *)asset {
    if (!asset) return;
    self.previewedQRURL = nil;
    [self flushPreviewNoteSave];
    [self.previewNoteSaveTimer invalidate];
    self.previewNoteSaveTimer = nil;
    self.previewNoteTextView = nil;
    [self.previewPanel orderOut:nil];
    self.previewedAsset = asset;
    self.previewSpreadsheetSheets = nil;
    self.previewSpreadsheetTable = nil;
    self.previewSpreadsheetTabsStack = nil;

    NSString *previewFilePath = AssetFilePath(asset);
    LPPSpreadsheetKind spreadsheetKind = (!IsLiveClip(asset) && previewFilePath.length && [NSFileManager.defaultManager fileExistsAtPath:previewFilePath])
        ? SpreadsheetKindForPath(previewFilePath)
        : LPPSpreadsheetKindNone;

    CGFloat previewWidth = spreadsheetKind != LPPSpreadsheetKindNone ? 760 : 520;
    CGFloat previewHeight = spreadsheetKind != LPPSpreadsheetKindNone ? 560 : 430;
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    NSPoint preferredOrigin = NSMakePoint(NSMinX(self.panel.frame) - previewWidth - 12, NSMaxY(self.panel.frame) - previewHeight);
    if (preferredOrigin.x < NSMinX(visibleFrame)) preferredOrigin.x = NSMaxX(self.panel.frame) + 12;
    preferredOrigin = ClampedPanelOrigin(preferredOrigin, NSMakeSize(previewWidth, previewHeight), visibleFrame);

    // Titled windows already drag by their title bar for free; adding
    // Resizable gives it real edge/corner resize handles too. Content
    // inside isn't rebuilt on resize yet (unlike the Ask AI panel), so the
    // media/text areas won't reflow to fill extra room — resizing this one
    // gives more breathing room around fixed-size content rather than a
    // fully adaptive layout. A dedicated pass to make its varied per-kind
    // content (image/PDF/spreadsheet/note/LiveClip) reflow live would be
    // its own follow-up.
    FocusPanel *preview = [[FocusPanel alloc] initWithContentRect:NSMakeRect(preferredOrigin.x, preferredOrigin.y, previewWidth, previewHeight) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    preview.controller = self;
    preview.title = asset[@"title"] ?: @"Quick Preview";
    preview.floatingPanel = YES;
    preview.level = NSFloatingWindowLevel;
    preview.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    preview.hidesOnDeactivate = NO;
    preview.backgroundColor = VoltScreenColor();
    preview.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    preview.minSize = NSMakeSize(360, 300);
    // The title bar's text just repeats the asset title shown below; blend
    // the bar into the surface so only the traffic lights remain.
    preview.titleVisibility = NSWindowTitleHidden;
    preview.titlebarAppearsTransparent = YES;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, previewWidth, previewHeight)];
    ApplyVoltScreenChrome(content);
    preview.contentView = content;

    NSRect mediaFrame = NSMakeRect(18, 18, previewWidth - 36, previewHeight - 38);
    if (IsLiveClip(asset)) {
        NSDictionary *clip = asset[@"liveClip"];
        NSDictionary *contentInfo = [clip[@"extractedContent"] isKindOfClass:NSDictionary.class] ? clip[@"extractedContent"] : @{};
        NSString *type = clip[@"contentType"] ?: @"image";
        NSString *summary = CopyableTextForLiveClip(asset) ?: @"";
        if ([type isEqualToString:@"labeledValue"]) summary = [NSString stringWithFormat:@"%@\n%@", contentInfo[@"label"] ?: @"Value", contentInfo[@"displayValue"] ?: summary];
        if (summary.length) {
            NSScrollView *summaryScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, previewHeight - 146, previewWidth - 36, 72)];
            summaryScroll.drawsBackground = NO;
            summaryScroll.borderType = NSNoBorder;
            NSTextView *summaryView = [[NSTextView alloc] initWithFrame:summaryScroll.bounds];
            summaryView.editable = NO;
            summaryView.selectable = YES;
            summaryView.drawsBackground = NO;
            summaryView.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
            summaryView.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
            summaryView.textContainerInset = NSMakeSize(8, 8);
            summaryView.string = summary;
            summaryScroll.documentView = summaryView;
            [content addSubview:summaryScroll];
            mediaFrame = NSMakeRect(18, 18, previewWidth - 36, previewHeight - 214);
        }
        NSDictionary *source = LiveClipSource(asset);
        NSString *app = source[@"applicationName"] ?: @"Unknown source";
        NSString *window = source[@"windowTitle"] ?: @"";
        NSString *urlText = @"";
        NSURL *sourceURL = WebURLFromText(source[@"sourceURL"]);
        if (sourceURL.host.length) urlText = sourceURL.host;
        NSDate *captured = [source[@"capturedAt"] isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSince1970:[source[@"capturedAt"] doubleValue]] : nil;
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterNoStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        NSString *capturedText = captured ? [NSString stringWithFormat:@"Captured %@", [formatter stringFromDate:captured]] : @"";
        NSString *previous = @"";
        if ([clip[@"previousContent"] isKindOfClass:NSDictionary.class]) {
            NSString *previousType = clip[@"previousContentType"] ?: clip[@"contentType"];
            NSDictionary *previousContent = clip[@"previousContent"];
            if ([previousType isEqualToString:@"labeledValue"]) {
                id value = previousContent[@"displayValue"] ?: previousContent[@"numericValue"] ?: clip[@"previousExtractedText"];
                previous = [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : (value ?: @"");
            } else if ([previousType isEqualToString:@"number"]) {
                id value = previousContent[@"displayValue"] ?: previousContent[@"numericValue"];
                previous = [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : (value ?: @"");
            }
            else if ([previousType isEqualToString:@"url"]) previous = previousContent[@"url"] ?: @"";
            else if ([previousType isEqualToString:@"text"]) previous = previousContent[@"text"] ?: clip[@"previousExtractedText"] ?: @"";
            else if ([previousType isEqualToString:@"table"]) previous = @"table changed";
        }
        NSString *lastChecked = [clip[@"lastCheckedAt"] isKindOfClass:NSString.class] || [clip[@"lastCheckedAt"] isKindOfClass:NSNumber.class] ? [NSString stringWithFormat:@"Checked %@", RelativeTimeString(clip[@"lastCheckedAt"])] : @"";
        NSString *lastChanged = [clip[@"lastChangedAt"] isKindOfClass:NSString.class] || [clip[@"lastChangedAt"] isKindOfClass:NSNumber.class] ? [NSString stringWithFormat:@"Changed %@", RelativeTimeString(clip[@"lastChangedAt"])] : @"";
        NSString *failure = [clip[@"refreshFailureReason"] isKindOfClass:NSString.class] ? clip[@"refreshFailureReason"] : @"";
        NSMutableArray *parts = [NSMutableArray arrayWithObjects:@"SOURCE", app, nil];
        if (window.length) [parts addObject:window];
        if (urlText.length) [parts addObject:urlText];
        if (previous.length) [parts addObject:[NSString stringWithFormat:@"Previous %@", previous]];
        if (capturedText.length) [parts addObject:capturedText];
        if (lastChecked.length) [parts addObject:lastChecked];
        if (lastChanged.length) [parts addObject:lastChanged];
        if (failure.length) [parts addObject:failure];
        NSMutableArray *clean = [NSMutableArray array];
        for (NSString *part in parts) if (part.length) [clean addObject:part];
        NSTextField *sourceLabel = [NSTextField labelWithString:[clean componentsJoinedByString:@"\n"]];
        sourceLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        sourceLabel.textColor = [NSColor colorWithCalibratedWhite:0.68 alpha:1];
        sourceLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        sourceLabel.frame = NSMakeRect(26, previewHeight - 236, previewWidth - 156, 82);
        [content addSubview:sourceLabel];
        if (LiveClipSourceCanOpen(asset)) {
            NSButton *sourceButton = [NSButton buttonWithTitle:LiveClipOpenSourceTitle(asset) target:self action:@selector(openSourceForSelectedLiveClip:)];
            sourceButton.bezelStyle = NSBezelStyleTexturedRounded;
            sourceButton.frame = NSMakeRect(previewWidth - 128, previewHeight - 200, 110, 30);
            [content addSubview:sourceButton];
        }
        NSButton *refreshButton = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshSelectedLiveClip:)];
        refreshButton.bezelStyle = NSBezelStyleTexturedRounded;
        refreshButton.frame = NSMakeRect(previewWidth - 128, previewHeight - 234, 110, 30);
        [content addSubview:refreshButton];
    }
    // Resizing: everything built so far (LiveClip header text/buttons) is
    // pinned to the top and right edges; the media below stretches to fill.
    for (NSView *view in content.subviews) {
        BOOL rightSide = NSMinX(view.frame) > previewWidth / 2;
        BOOL fullWidth = NSWidth(view.frame) > previewWidth * 0.8;
        view.autoresizingMask = NSViewMinYMargin | (fullWidth ? NSViewWidthSizable : (rightSide ? NSViewMinXMargin : 0));
    }
    NSString *payload = AssetPayload(asset);
    if (payload.length && !AssetFilePath(asset).length && !AssetOriginURL(asset)) {
        BOOL isEditableNote = [asset[@"kind"] isEqualToString:@"Note"];
        NSScrollView *textScroll = [[NSScrollView alloc] initWithFrame:mediaFrame];
        textScroll.drawsBackground = NO;
        textScroll.hasVerticalScroller = YES;
        textScroll.borderType = NSNoBorder;
        textScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSTextView *textView = [[NSTextView alloc] initWithFrame:textScroll.bounds];
        textView.autoresizingMask = NSViewWidthSizable;
        textView.verticallyResizable = YES;
        textView.textContainer.widthTracksTextView = YES;
        textView.editable = isEditableNote;
        textView.selectable = YES;
        textView.drawsBackground = NO;
        // Terminal feel: monospaced, warm phosphor text, gold caret, a
        // little extra line spacing so it reads like a console, not a doc.
        textView.textColor = [NSColor colorWithCalibratedRed:0.86 green:0.89 blue:0.93 alpha:1];
        textView.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        textView.insertionPointColor = VoltGoldColor();
        NSMutableParagraphStyle *terminalStyle = [NSMutableParagraphStyle new];
        terminalStyle.lineSpacing = 4;
        textView.defaultParagraphStyle = terminalStyle;
        textView.textContainerInset = NSMakeSize(14, 14);
        textView.string = payload;
        textScroll.documentView = textView;
        // Notes are meant to be lived in during class, not just glanced at —
        // editing in place and autosaving on a short pause is what makes
        // that possible instead of a separate save step.
        if (isEditableNote) {
            textView.delegate = self;
            self.previewNoteTextView = textView;
        }
        [content addSubview:textScroll];
    } else {
        BOOL builtSpreadsheet = spreadsheetKind != LPPSpreadsheetKindNone &&
            [self configureSpreadsheetPreviewInContent:content mediaFrame:mediaFrame panelWidth:previewWidth filePath:previewFilePath];

        if (!builtSpreadsheet) {
            NSImageView *imageView = [[NSImageView alloc] initWithFrame:mediaFrame];
            imageView.wantsLayer = YES;
            imageView.layer.cornerRadius = 8;
            imageView.layer.masksToBounds = YES;
            imageView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.035].CGColor;
            imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
            imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            NSImage *sourceImage = ImmediatePreviewImage(asset);
            imageView.image = sourceImage ?: [NSImage imageWithSystemSymbolName:IconForKind(asset[@"kind"]) accessibilityDescription:nil];
            imageView.contentTintColor = MutedKindColor(asset[@"kind"]);
            [content addSubview:imageView];

            // Screenshots and saved images routinely contain a QR code (an
            // event ticket, a Wi-Fi card, a payment link) with no way to act
            // on it except retyping the URL by hand. Detected asynchronously
            // (Vision on a full screenshot isn't instant) — the button only
            // appears once/if something's actually found, and only if the
            // preview hasn't since moved on to a different asset.
            if (sourceImage) {
                NSString *previewAssetID = asset[@"id"];
                __weak AppController *weakSelfForQR = self;
                DetectQRCodeURLInImage(sourceImage, ^(NSURL * _Nullable url) {
                    AppController *strongSelf = weakSelfForQR;
                    if (!strongSelf || !url) return;
                    if (![strongSelf.previewedAsset[@"id"] isEqualToString:previewAssetID]) return;
                    strongSelf.previewedQRURL = url;
                    // Floats over the image itself, bottom-left corner —
                    // the title/subtitle/Open row below is already full
                    // (title + subtitle span nearly to where Open sits),
                    // so there's no free space left down there for this.
                    HoverIconButton *qrButton = [HoverIconButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"qrcode" accessibilityDescription:@"Open QR Link"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]] target:strongSelf action:@selector(openDetectedQRLink:)];
                    qrButton.imagePosition = NSImageOnly;
                    qrButton.contentTintColor = VoltTealColor();
                    qrButton.idleBackground = [NSColor colorWithCalibratedWhite:0.08 alpha:0.75];
                    qrButton.hoverBackground = SurfaceHoverColor();
                    qrButton.pressedBackground = SurfacePressedColor();
                    qrButton.layer.cornerRadius = 7;
                    qrButton.frame = NSMakeRect(NSMinX(mediaFrame) + 10, NSMinY(mediaFrame) + 10, 30, 28);
                    qrButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
                    qrButton.toolTip = [@"Open QR link: " stringByAppendingString:url.absoluteString];
                    [content addSubview:qrButton];
                });
            }

            NSString *filePath = previewFilePath;
            if (filePath.length && [NSFileManager.defaultManager fileExistsAtPath:filePath]) {
                QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:filePath] size:mediaFrame.size scale:NSScreen.mainScreen.backingScaleFactor representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
                NSString *previewID = asset[@"id"];
                __weak AppController *weakSelf = self;
                [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:request completionHandler:^(QLThumbnailRepresentation *representation, NSError *error) {
                    NSImage *image = representation.NSImage;
                    if (!image || error) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (![weakSelf.previewedAsset[@"id"] isEqualToString:previewID]) return;
                        imageView.image = image;
                        imageView.contentTintColor = nil;
                    });
                }];
            }
        }
    }

    // No text row along the bottom anymore — the title/kind/uploader/age
    // live behind an info icon's tooltip, and Open sits beside it, both
    // tucked in the bottom-right corner over the content so the content
    // gets the whole panel.
    NSImageSymbolConfiguration *cornerIconConfig = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    CGFloat cornerX = previewWidth - 18 - 26;
    BOOL hasOpen = AssetFilePath(asset).length || AssetOriginURL(asset);
    if (hasOpen) {
        BOOL isLink = AssetOriginURL(asset) != nil;
        HoverIconButton *open = [HoverIconButton buttonWithImage:[[NSImage imageWithSystemSymbolName:isLink ? @"link" : @"arrow.up.right.square" accessibilityDescription:isLink ? @"Open Link" : @"Open"] imageWithSymbolConfiguration:cornerIconConfig] target:self action:@selector(openPreviewedAsset:)];
        open.imagePosition = NSImageOnly;
        open.contentTintColor = [NSColor colorWithCalibratedWhite:0.85 alpha:1];
        open.idleBackground = [NSColor colorWithCalibratedWhite:0.06 alpha:0.7];
        open.hoverBackground = SurfaceHoverColor();
        open.pressedBackground = SurfacePressedColor();
        open.layer.cornerRadius = 6;
        open.toolTip = isLink ? @"Open Link" : @"Open";
        open.frame = NSMakeRect(cornerX, 24, 26, 24);
        open.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
        open.keyEquivalent = @"\r";
        [content addSubview:open];
        cornerX -= 30;
    }
    HoverIconButton *info = [HoverIconButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:@"Details"] imageWithSymbolConfiguration:cornerIconConfig] target:nil action:nil];
    info.imagePosition = NSImageOnly;
    info.contentTintColor = [NSColor colorWithCalibratedWhite:0.7 alpha:1];
    info.idleBackground = [NSColor colorWithCalibratedWhite:0.06 alpha:0.7];
    info.hoverBackground = SurfaceHoverColor();
    info.layer.cornerRadius = 6;
    info.toolTip = [NSString stringWithFormat:@"%@\n%@", asset[@"title"] ?: @"Untitled asset", AssetSubtitle(asset)];
    info.frame = NSMakeRect(cornerX, 24, 26, 24);
    info.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:info];

    self.previewPanel = preview;
    [preview makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// Builds a real, scrollable table of a CSV/TSV/XLSX file's contents into the
// preview panel's media area. Returns NO (and adds nothing) if the file
// can't be parsed, so the caller can fall back to the QuickLook thumbnail.
- (BOOL)configureSpreadsheetPreviewInContent:(NSView *)content mediaFrame:(NSRect)mediaFrame panelWidth:(CGFloat)panelWidth filePath:(NSString *)filePath {
    LPPSpreadsheetKind kind = SpreadsheetKindForPath(filePath);
    NSArray<NSDictionary *> *sheets = nil;
    NSString *errorMessage = nil;

    if (kind == LPPSpreadsheetKindXLSX) {
        sheets = ParseXLSXFile(filePath, &errorMessage);
    } else if (kind == LPPSpreadsheetKindCSV || kind == LPPSpreadsheetKindTSV) {
        NSArray<NSArray<NSString *> *> *rows = ParseDelimitedFile(filePath, kind == LPPSpreadsheetKindTSV ? '\t' : ',');
        if (rows.count) sheets = @[ @{ @"name": @"Sheet", @"rows": rows } ];
        else errorMessage = @"This file looks empty";
    }
    if (!sheets.count) {
        LPPLog(@"preview.spreadsheet_failed", @{ @"path": filePath.lastPathComponent ?: @"", @"reason": errorMessage ?: @"unknown" });
        return NO;
    }

    self.previewSpreadsheetSheets = sheets;
    self.previewSpreadsheetActiveSheet = 0;

    NSRect tableFrame = mediaFrame;
    if (sheets.count > 1) {
        CGFloat tabsHeight = 26;
        NSStackView *tabs = [NSStackView stackViewWithViews:@[]];
        tabs.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        tabs.alignment = NSLayoutAttributeCenterY;
        tabs.spacing = 6;
        tabs.frame = NSMakeRect(mediaFrame.origin.x, NSMaxY(mediaFrame) - tabsHeight, mediaFrame.size.width, tabsHeight);
        tabs.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        for (NSInteger i = 0; i < (NSInteger)sheets.count; i++) {
            NSButton *tab = [NSButton buttonWithTitle:sheets[i][@"name"] ?: @"Sheet" target:self action:@selector(spreadsheetTabClicked:)];
            tab.tag = i;
            tab.bezelStyle = NSBezelStyleTexturedRounded;
            tab.font = [NSFont systemFontOfSize:11 weight:i == 0 ? NSFontWeightSemibold : NSFontWeightRegular];
            [tabs addArrangedSubview:tab];
        }
        [content addSubview:tabs];
        self.previewSpreadsheetTabsStack = tabs;
        tableFrame = NSMakeRect(mediaFrame.origin.x, mediaFrame.origin.y, mediaFrame.size.width, mediaFrame.size.height - tabsHeight - 6);
    }

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:tableFrame];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.035];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    LPPSpreadsheetTableView *table = [[LPPSpreadsheetTableView alloc] initWithFrame:scrollView.bounds];
    table.controller = self;
    table.usesAlternatingRowBackgroundColors = YES;
    table.gridStyleMask = NSTableViewSolidVerticalGridLineMask | NSTableViewSolidHorizontalGridLineMask;
    table.gridColor = [NSColor colorWithCalibratedWhite:1 alpha:0.06];
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 20;
    table.allowsColumnResizing = YES;
    scrollView.documentView = table;
    [content addSubview:scrollView];

    self.previewSpreadsheetTable = table;
    [self reloadSpreadsheetTableColumns];
    return YES;
}

- (void)spreadsheetTabClicked:(NSButton *)sender {
    [self selectSpreadsheetTabAtIndex:sender.tag];
}

- (void)selectSpreadsheetTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.previewSpreadsheetSheets.count) return;
    self.previewSpreadsheetActiveSheet = index;
    for (NSInteger i = 0; i < (NSInteger)self.previewSpreadsheetTabsStack.arrangedSubviews.count; i++) {
        NSButton *tab = (NSButton *)self.previewSpreadsheetTabsStack.arrangedSubviews[i];
        tab.font = [NSFont systemFontOfSize:11 weight:i == index ? NSFontWeightSemibold : NSFontWeightRegular];
    }
    [self reloadSpreadsheetTableColumns];
}

- (void)reloadSpreadsheetTableColumns {
    NSTableView *table = self.previewSpreadsheetTable;
    if (!table) return;
    NSArray<NSArray<NSString *> *> *rows = self.previewSpreadsheetSheets[self.previewSpreadsheetActiveSheet][@"rows"];

    NSInteger columnCount = 0;
    for (NSArray<NSString *> *row in rows) columnCount = MAX(columnCount, (NSInteger)row.count);
    columnCount = MAX(columnCount, 1);

    for (NSTableColumn *existing in [table.tableColumns copy]) [table removeTableColumn:existing];
    for (NSInteger c = 0; c < columnCount; c++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%ld", (long)c]];
        column.title = ColumnLetterForIndex(c);
        column.width = 96;
        column.minWidth = 40;
        [table addTableColumn:column];
    }
    [table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView != self.previewSpreadsheetTable || !self.previewSpreadsheetSheets.count) return 0;
    NSArray *rows = self.previewSpreadsheetSheets[self.previewSpreadsheetActiveSheet][@"rows"];
    return rows.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView != self.previewSpreadsheetTable || !self.previewSpreadsheetSheets.count) return nil;
    NSArray<NSArray<NSString *> *> *rows = self.previewSpreadsheetSheets[self.previewSpreadsheetActiveSheet][@"rows"];
    if (row < 0 || row >= (NSInteger)rows.count) return nil;
    NSArray<NSString *> *rowValues = rows[row];
    NSInteger col = tableColumn.identifier.integerValue;
    return col < (NSInteger)rowValues.count ? rowValues[col] : @"";
}

- (NSMenu *)spreadsheetCellMenuForText:(NSString *)text {
    if (!text.length) return nil;
    NSString *truncated = text.length > 48 ? [[text substringToIndex:48] stringByAppendingString:@"…"] : text;
    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copySpreadsheetCellText:) keyEquivalent:@""];
    copy.target = self;
    copy.representedObject = text;
    [menu addItem:copy];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *google = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Search Google for “%@”", truncated] action:@selector(searchGoogleForSpreadsheetCellText:) keyEquivalent:@""];
    google.target = self;
    google.representedObject = text;
    google.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
    [menu addItem:google];

    NSURL *asURL = WebURLFromText(text);
    if (asURL) {
        NSMenuItem *openLink = [[NSMenuItem alloc] initWithTitle:@"Open Link" action:@selector(openSpreadsheetCellLink:) keyEquivalent:@""];
        openLink.target = self;
        openLink.representedObject = asURL;
        openLink.image = [NSImage imageWithSystemSymbolName:@"arrow.up.forward.app" accessibilityDescription:nil];
        [menu addItem:openLink];
    }

    return menu;
}

- (void)copySpreadsheetCellText:(NSMenuItem *)sender {
    NSString *text = sender.representedObject;
    if (!text.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:@[text]];
}

- (void)searchGoogleForSpreadsheetCellText:(NSMenuItem *)sender {
    NSString *text = sender.representedObject;
    if (!text.length) return;
    NSString *encoded = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: text;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/search?q=%@", encoded]];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)openSpreadsheetCellLink:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (NSMenuItem *)assetMenuItemWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    if (symbol.length) item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    return item;
}

- (NSMenu *)contextMenuForAsset:(NSMutableDictionary *)asset {
    [self prepareAssetForContextMenu:asset];
    NSArray<NSMutableDictionary *> *selected = [self selectedAssets];
    NSUInteger count = selected.count;
    NSMutableDictionary *single = count == 1 ? selected.firstObject : nil;
    NSMenu *menu = [[NSMenu alloc] init];

    if ([self.assetFilter isEqualToString:@"Trash"]) {
        [menu addItem:[self assetMenuItemWithTitle:count > 1 ? [NSString stringWithFormat:@"Restore %lu Items", (unsigned long)count] : @"Restore" symbol:@"arrow.uturn.backward" action:@selector(restoreSelectedAssets:)]];
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:[self assetMenuItemWithTitle:count > 1 ? [NSString stringWithFormat:@"Delete %lu Items Permanently…", (unsigned long)count] : @"Delete Permanently…" symbol:@"trash" action:@selector(deletePermanentlySelectedAssets:)]];
        return menu;
    }

    NSString *openTitle = count > 1 ? [NSString stringWithFormat:@"Open %lu Items", (unsigned long)count] : (AssetOriginURL(single) ? @"Open Link" : @"Open");
    [menu addItem:[self assetMenuItemWithTitle:openTitle symbol:@"arrow.up.forward.app" action:@selector(openSelectedAssets:)]];
    NSMenuItem *preview = [self assetMenuItemWithTitle:@"Quick Preview" symbol:@"eye" action:@selector(previewSelectedAsset:)];
    preview.enabled = count == 1;
    [menu addItem:preview];
    NSMenuItem *explain = [self assetMenuItemWithTitle:@"Explain This" symbol:@"sparkles" action:@selector(explainSelectedAsset:)];
    explain.enabled = count == 1;
    [menu addItem:explain];
    [menu addItem:NSMenuItem.separatorItem];

    [menu addItem:[self assetMenuItemWithTitle:count > 1 ? [NSString stringWithFormat:@"Copy %lu Items", (unsigned long)count] : @"Copy" symbol:@"doc.on.doc" action:@selector(copySelectedAssetsFromMenu:)]];
    if (single && AssetOriginURL(single)) {
        [menu addItem:[self assetMenuItemWithTitle:@"Copy Link" symbol:@"link" action:@selector(copySelectedLink:)]];
        [menu addItem:[self assetMenuItemWithTitle:@"Save Full-Size Photo" symbol:@"square.and.arrow.down" action:@selector(saveSelectedPhoto:)]];
    }
    if (single && AssetFilePath(single).length) {
        [menu addItem:[self assetMenuItemWithTitle:@"Reveal in Finder" symbol:@"folder" action:@selector(revealSelectedAsset:)]];
    }
    if (single && IsLiveClip(single)) {
        NSDictionary *clip = single[@"liveClip"];
        NSString *type = clip[@"contentType"];
        if ([type isEqualToString:@"number"] || [type isEqualToString:@"labeledValue"] || [type isEqualToString:@"text"] || [type isEqualToString:@"table"]) {
            [menu addItem:[self assetMenuItemWithTitle:[type isEqualToString:@"table"] ? @"Copy Table" : @"Copy Value" symbol:@"doc.on.doc" action:@selector(copyLiveClipValue:)]];
        }
        if ([type isEqualToString:@"labeledValue"]) {
            [menu addItem:[self assetMenuItemWithTitle:@"Copy Label + Value" symbol:@"text.badge.plus" action:@selector(copyLiveClipLabelAndValue:)]];
        }
        if ([type isEqualToString:@"url"]) {
            [menu addItem:[self assetMenuItemWithTitle:@"Copy URL" symbol:@"link" action:@selector(copyLiveClipValue:)]];
        }
        if ([clip[@"extractedText"] length] || [clip[@"mode"] isEqualToString:@"Extract"] || [type isEqualToString:@"text"]) {
            [menu addItem:[self assetMenuItemWithTitle:@"View Extracted Text" symbol:@"text.viewfinder" action:@selector(viewExtractedTextForSelectedClip:)]];
            [menu addItem:[self assetMenuItemWithTitle:@"Copy Extracted Text" symbol:@"doc.on.doc" action:@selector(copyExtractedTextForSelectedClip:)]];
        }
        if (LiveClipSourceCanOpen(single)) {
            [menu addItem:[self assetMenuItemWithTitle:LiveClipOpenSourceTitle(single) symbol:@"arrow.up.forward.app" action:@selector(openSourceForSelectedLiveClip:)]];
        }
        [menu addItem:[self assetMenuItemWithTitle:@"Refresh" symbol:@"arrow.triangle.2.circlepath" action:@selector(refreshSelectedLiveClip:)]];
        [menu addItem:[self assetMenuItemWithTitle:@"Relocate Source" symbol:@"viewfinder" action:@selector(relocateSelectedLiveClipSource:)]];
        [menu addItem:[self assetMenuItemWithTitle:@"Copy Original Image" symbol:@"photo" action:@selector(copyLiveClipImage:)]];
        if ([clip[@"mode"] isEqualToString:@"Watch"]) {
            [menu addItem:[self assetMenuItemWithTitle:@"Check for Changes" symbol:@"arrow.triangle.2.circlepath" action:@selector(checkSelectedLiveClipForChanges:)]];
        }
    }
    [menu addItem:[self assetMenuItemWithTitle:@"Share…" symbol:@"square.and.arrow.up" action:@selector(shareSelectedAssets:)]];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *rename = [self assetMenuItemWithTitle:@"Rename…" symbol:@"pencil" action:@selector(renameSelectedAsset:)];
    rename.enabled = count == 1;
    [menu addItem:rename];
    [menu addItem:[self assetMenuItemWithTitle:count > 1 ? @"Duplicate Items" : @"Duplicate" symbol:@"plus.square.on.square" action:@selector(duplicateSelectedAssets:)]];

    if (self.packs.count > 1) {
        NSMenuItem *move = [[NSMenuItem alloc] initWithTitle:@"Move to Pack" action:nil keyEquivalent:@""];
        move.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
        NSMenu *submenu = [[NSMenu alloc] init];
        for (NSInteger index = 0; index < (NSInteger)self.packs.count; index++) {
            if (index == self.selectedPackIndex) continue;
            NSDictionary *pack = self.packs[index];
            NSMenuItem *destination = [[NSMenuItem alloc] initWithTitle:pack[@"name"] ?: @"Pack" action:@selector(moveSelectedAssetsToPack:) keyEquivalent:@""];
            destination.target = self;
            destination.representedObject = pack[@"id"];
            [submenu addItem:destination];
        }
        move.submenu = submenu;
        [menu addItem:move];
    }

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self assetMenuItemWithTitle:count > 1 ? [NSString stringWithFormat:@"Move %lu Items to Trash", (unsigned long)count] : @"Move to Trash" symbol:@"trash" action:@selector(moveSelectedAssetsToTrash:)]];
    return menu;
}

- (void)openSelectedAssets:(id)sender {
    NSArray<NSMutableDictionary *> *assets = [self selectedAssets];
    if (assets.count == 1) {
        [self activateAsset:assets.firstObject];
        return;
    }
    for (NSMutableDictionary *asset in assets) [self openAsset:asset];
}

- (void)previewSelectedAsset:(id)sender {
    [self showPreviewForAsset:[self primarySelectedAsset]];
}

- (void)copySelectedAssetsFromMenu:(id)sender {
    [self copySelectedAssets];
}

- (void)copySelectedLink:(id)sender {
    NSMutableDictionary *asset = [self primarySelectedAsset];
    if (asset) [self copyLinkForAsset:asset];
}

- (void)saveSelectedPhoto:(id)sender {
    NSMutableDictionary *asset = [self primarySelectedAsset];
    if (asset) [self savePhotoFromAsset:asset];
}

- (void)revealSelectedAsset:(id)sender {
    NSString *filePath = AssetFilePath([self primarySelectedAsset]);
    if (!filePath.length) return;
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:filePath]]];
}

- (void)shareSelectedAssets:(id)sender {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *asset in [self selectedAssets]) {
        id<NSPasteboardWriting> writer = AssetDragWriter(asset, YES);
        if (writer) [items addObject:writer];
    }
    if (!items.count) return;
    NSSharingServicePicker *picker = [[NSSharingServicePicker alloc] initWithItems:items];
    [picker showRelativeToRect:NSMakeRect(NSMidX(self.panel.contentView.bounds), NSMaxY(self.panel.contentView.bounds) - 40, 1, 1) ofView:self.panel.contentView preferredEdge:NSRectEdgeMinY];
}

- (void)renameSelectedAsset:(id)sender {
    NSMutableDictionary *asset = [self primarySelectedAsset];
    if (!asset || [self selectedAssets].count != 1) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rename Asset";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 32)];
    field.stringValue = asset[@"title"] ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *name = Trimmed(field.stringValue);
    if (!name.length) return;
    if (name.length > 180) name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 180)]];
    asset[@"title"] = name;
    [self saveState];
    [self render];
}

- (void)duplicateSelectedAssets:(id)sender {
    NSArray<NSMutableDictionary *> *selected = [[self selectedAssets] copy];
    if (!selected.count) return;
    NSMutableArray *assets = [self selectedPack][@"assets"];
    NSMutableArray<NSString *> *newIDs = [NSMutableArray array];
    for (NSMutableDictionary *asset in selected) {
        NSUInteger index = [assets indexOfObjectIdenticalTo:asset];
        if (index == NSNotFound) continue;
        NSMutableDictionary *duplicate = [asset mutableCopy];
        duplicate[@"id"] = NSUUID.UUID.UUIDString;
        duplicate[@"title"] = [NSString stringWithFormat:@"%@ copy", asset[@"title"] ?: @"Asset"];
        duplicate[@"addedAt"] = @([[NSDate date] timeIntervalSince1970]);
        duplicate[@"isNew"] = @NO;
        [assets insertObject:duplicate atIndex:index + 1];
        [newIDs addObject:duplicate[@"id"]];
    }
    [self.selectedAssetIDs removeAllObjects];
    [self.selectedAssetIDs addObjectsFromArray:newIDs];
    self.selectionAnchorID = newIDs.lastObject;
    [self saveState];
    [self render];
    [self showTransientNotice:[NSString stringWithFormat:@"Duplicated %lu %@", (unsigned long)newIDs.count, newIDs.count == 1 ? @"item" : @"items"]];
}

- (void)moveSelectedAssetsToPack:(NSMenuItem *)sender {
    NSString *packID = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSMutableDictionary *destination = nil;
    for (NSMutableDictionary *pack in self.packs) {
        if ([pack[@"id"] isEqualToString:packID]) destination = pack;
    }
    NSArray<NSMutableDictionary *> *selected = [[self selectedAssets] copy];
    if (!destination || !selected.count || destination == [self selectedPack]) return;
    NSMutableArray *sourceAssets = [self selectedPack][@"assets"];
    NSMutableArray *destinationAssets = destination[@"assets"];
    for (NSMutableDictionary *asset in selected) [sourceAssets removeObjectIdenticalTo:asset];
    for (NSMutableDictionary *asset in selected.reverseObjectEnumerator) [destinationAssets insertObject:asset atIndex:0];
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self saveState];
    [self render];
    [self showTransientNotice:[NSString stringWithFormat:@"Moved %lu %@ to %@", (unsigned long)selected.count, selected.count == 1 ? @"item" : @"items", destination[@"name"] ?: @"Pack"]];
}

- (void)moveSelectedAssetsToTrash:(id)sender {
    [self trashAssets:[[self selectedAssets] copy]];
}

// Shared by the selection-based trash button and Pack AI's trash_asset
// action — same undo window either way, so an AI mis-identifying an asset
// is exactly as recoverable as a manual mis-click.
- (void)trashAssets:(NSArray<NSMutableDictionary *> *)assetsToTrash {
    if (!assetsToTrash.count) return;
    NSMutableDictionary *pack = [self selectedPack];
    NSMutableArray *assets = pack[@"assets"];
    NSMutableArray *trash = pack[@"trash"];
    if (![trash isKindOfClass:NSMutableArray.class]) {
        trash = [NSMutableArray array];
        pack[@"trash"] = trash;
    }
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSMutableDictionary *asset in assetsToTrash) {
        NSUInteger index = [assets indexOfObjectIdenticalTo:asset];
        if (index == NSNotFound) continue;
        [records addObject:@{@"asset": asset, @"index": @(index)}];
        asset[@"trashedAt"] = @([[NSDate date] timeIntervalSince1970]);
        [trash addObject:asset];
    }
    for (NSMutableDictionary *asset in assetsToTrash) [assets removeObjectIdenticalTo:asset];
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    self.undoPack = pack;
    self.lastDeletedAssetRecords = records;
    self.undoToken = NSUUID.UUID.UUIDString;
    NSString *notice = [NSString stringWithFormat:@"%lu %@ moved to Trash", (unsigned long)records.count, records.count == 1 ? @"item" : @"items"];
    self.undoNotice = notice;
    self.transientNotice = notice;
    NSString *token = self.undoToken;
    [self saveState];
    [self render];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self.undoToken isEqualToString:token]) return;
        self.undoToken = nil;
        self.undoPack = nil;
        self.lastDeletedAssetRecords = nil;
        self.undoNotice = nil;
        if ([self.transientNotice isEqualToString:notice]) self.transientNotice = nil;
        [self render];
    });
}

- (void)undoLastDelete:(id)sender {
    if (!self.undoPack || !self.lastDeletedAssetRecords.count) return;
    NSMutableArray *assets = self.undoPack[@"assets"];
    NSMutableArray *trash = self.undoPack[@"trash"];
    NSArray<NSDictionary *> *records = [self.lastDeletedAssetRecords sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        return [first[@"index"] compare:second[@"index"]];
    }];
    [self.selectedAssetIDs removeAllObjects];
    for (NSDictionary *record in records) {
        NSMutableDictionary *asset = record[@"asset"];
        [trash removeObjectIdenticalTo:asset];
        [asset removeObjectForKey:@"trashedAt"];
        NSUInteger index = MIN([record[@"index"] unsignedIntegerValue], assets.count);
        [assets insertObject:asset atIndex:index];
        if (self.undoPack == [self selectedPack] && [asset[@"id"] length]) [self.selectedAssetIDs addObject:asset[@"id"]];
    }
    self.selectionAnchorID = self.selectedAssetIDs.lastObject;
    NSUInteger count = records.count;
    self.undoToken = nil;
    self.undoPack = nil;
    self.lastDeletedAssetRecords = nil;
    self.undoNotice = nil;
    [self saveState];
    [self render];
    [self showTransientNotice:[NSString stringWithFormat:@"Restored %lu %@", (unsigned long)count, count == 1 ? @"item" : @"items"]];
}

// The soft-delete in -moveSelectedAssetsToTrash: only ever had a 6-second Undo
// window and no way to see the Trash it built up in — items piled up forever
// with no way to actually reclaim disk space. These fill out the other half
// of that lifecycle: a real Trash view (see -visibleAssets), restoring items
// out of it, and permanently deleting them (which also cleans up the
// underlying file via the same safe, dedup-checked NSWorkspace recycleURLs:
// pattern -deleteCurrentPack: already uses for whole-pack deletion).
- (BOOL)isFilePathUsedElsewhere:(NSString *)standardizedPath excluding:(NSMutableDictionary *)excludedAsset {
    if (!standardizedPath.length) return NO;
    for (NSDictionary *pack in self.packs) {
        for (NSArray *bucket in @[ pack[@"assets"] ?: @[], pack[@"trash"] ?: @[] ]) {
            for (NSDictionary *asset in bucket) {
                if (asset == excludedAsset) continue;
                NSString *path = AssetFilePath(asset).stringByStandardizingPath;
                if (path.length && [path isEqualToString:standardizedPath]) return YES;
            }
        }
    }
    return NO;
}

- (void)restoreSelectedAssets:(id)sender {
    NSArray<NSMutableDictionary *> *selected = [[self selectedAssets] copy];
    if (!selected.count) return;
    NSMutableDictionary *pack = [self selectedPack];
    NSMutableArray *trash = pack[@"trash"];
    NSMutableArray *assets = pack[@"assets"];
    for (NSMutableDictionary *asset in selected) {
        [trash removeObjectIdenticalTo:asset];
        [asset removeObjectForKey:@"trashedAt"];
        [assets addObject:asset];
    }
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self saveState];
    [self showTransientNotice:[NSString stringWithFormat:@"Restored %lu %@", (unsigned long)selected.count, selected.count == 1 ? @"item" : @"items"]];
    [self render];
}

- (void)deleteAssetsPermanently:(NSArray<NSMutableDictionary *> *)assetsToDelete fromPack:(NSMutableDictionary *)pack confirm:(BOOL)confirm {
    if (!assetsToDelete.count) return;
    if (confirm) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = assetsToDelete.count == 1 ? @"Delete this item permanently?" : [NSString stringWithFormat:@"Delete %lu items permanently?", (unsigned long)assetsToDelete.count];
        alert.informativeText = @"The underlying file will be moved to the macOS Trash. This can't be undone from Packs.";
        [alert addButtonWithTitle:@"Delete Permanently"];
        [alert addButtonWithTitle:@"Cancel"];
        alert.buttons.firstObject.hasDestructiveAction = YES;
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }

    NSMutableArray *trash = pack[@"trash"];
    NSMutableOrderedSet<NSURL *> *filesToTrash = [NSMutableOrderedSet orderedSet];
    NSString *uploadsPrefix = [self.uploadsRoot.path.stringByStandardizingPath stringByAppendingString:@"/"];
    for (NSMutableDictionary *asset in assetsToDelete) {
        NSString *path = AssetFilePath(asset).stringByStandardizingPath;
        BOOL underUploads = path.length && [path hasPrefix:uploadsPrefix];
        [trash removeObjectIdenticalTo:asset];
        if (underUploads && [NSFileManager.defaultManager fileExistsAtPath:path] && ![self isFilePathUsedElsewhere:path excluding:asset]) {
            [filesToTrash addObject:[NSURL fileURLWithPath:path]];
        }
    }
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self saveState];
    [self render];
    LPPLog(@"asset.deleted_permanently", @{ @"count": @(assetsToDelete.count), @"files": @(filesToTrash.count) });
    if (filesToTrash.count) {
        [NSWorkspace.sharedWorkspace recycleURLs:filesToTrash.array completionHandler:^(__unused NSDictionary<NSURL *, NSURL *> *newURLs, NSError *error) {
            if (!error) return;
            LPPLog(@"asset.delete_permanently_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showTransientNotice:@"Deleted; some files stayed on disk"];
            });
        }];
    }
}

- (void)deletePermanentlySelectedAssets:(id)sender {
    NSArray<NSMutableDictionary *> *selected = [[self selectedAssets] copy];
    [self deleteAssetsPermanently:selected fromPack:[self selectedPack] confirm:YES];
}

- (void)emptyTrashForCurrentPack:(id)sender {
    NSMutableDictionary *pack = [self selectedPack];
    NSArray<NSMutableDictionary *> *trashed = [pack[@"trash"] copy];
    if (!trashed.count) {
        [self showTransientNotice:@"Trash is already empty"];
        return;
    }
    [self deleteAssetsPermanently:trashed fromPack:pack confirm:YES];
}

- (void)openAsset:(NSDictionary *)asset {
    NSURL *url = AssetOriginURL(asset);
    NSString *filePath = AssetFilePath(asset);
    if (!url && filePath.length) url = [NSURL fileURLWithPath:filePath];
    if (!url) {
        [self showTransientNotice:@"This link is not valid"];
        LPPLog(@"open.invalid", @{ @"id": asset[@"id"] ?: @"" });
        return;
    }
    LPPLog(@"open.requested", @{
        @"id": asset[@"id"] ?: @"",
        @"scheme": url.scheme ?: @"",
        @"host": url.host ?: @""
    });

    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = YES;
    configuration.promptsUserIfNeeded = YES;
    void (^completion)(NSRunningApplication *, NSError *) = ^(__unused NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                LPPLog(@"open.workspace_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
                [self openURLWithSystemCommand:url asset:asset browserPath:nil];
                return;
            }
            [self finishOpeningAsset:asset error:nil];
        });
    };

    NSURL *applicationURL = [workspace URLForApplicationToOpenURL:url];
    if (applicationURL) {
        [workspace openURLs:@[url] withApplicationAtURL:applicationURL configuration:configuration completionHandler:completion];
    } else {
        [self openURLWithSystemCommand:url asset:asset browserPath:nil];
    }
}

- (void)finishOpeningAsset:(NSDictionary *)asset error:(NSError *)error {
    if (error) {
        [self showTransientNotice:@"Could not open this link"];
        return;
    }
    if ([asset isKindOfClass:NSMutableDictionary.class]) ((NSMutableDictionary *)asset)[@"isNew"] = @NO;
    [self saveState];
    [self render];
    [self.panel orderOut:nil];
}

- (NSString *)installedBrowserPath {
    NSString *userApplications = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    NSArray<NSString *> *paths = @[
        @"/Applications/Safari.app",
        @"/System/Applications/Safari.app",
        @"/Applications/Google Chrome.app",
        @"/Applications/Arc.app",
        @"/Applications/Firefox.app",
        @"/Applications/Brave Browser.app",
        @"/Applications/Microsoft Edge.app",
        [userApplications stringByAppendingPathComponent:@"Safari.app"],
        [userApplications stringByAppendingPathComponent:@"Google Chrome.app"],
        [userApplications stringByAppendingPathComponent:@"Arc.app"],
        [userApplications stringByAppendingPathComponent:@"Firefox.app"]
    ];
    for (NSString *path in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (void)openURLWithSystemCommand:(NSURL *)url asset:(NSDictionary *)asset browserPath:(NSString *)browserPath {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = browserPath.length ? @[@"-a", browserPath, url.absoluteString] : @[url.absoluteString];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.terminationHandler = ^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LPPLog(@"open.command_finished", @{
                @"status": @(finishedTask.terminationStatus),
                @"browser": browserPath.lastPathComponent ?: @"default"
            });
            if (finishedTask.terminationStatus == 0) {
                [self finishOpeningAsset:asset error:nil];
                return;
            }
            NSString *fallbackBrowser = (browserPath.length || url.isFileURL) ? nil : [self installedBrowserPath];
            if (fallbackBrowser.length) {
                [self openURLWithSystemCommand:url asset:asset browserPath:fallbackBrowser];
                return;
            }
            NSError *error = [NSError errorWithDomain:@"LiveProjectPacks.Open" code:finishedTask.terminationStatus userInfo:nil];
            [self finishOpeningAsset:asset error:error];
        });
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        LPPLog(@"open.command_failed", @{ @"error": launchError.localizedDescription ?: @"unknown" });
        NSString *fallbackBrowser = (browserPath.length || url.isFileURL) ? nil : [self installedBrowserPath];
        if (fallbackBrowser.length) {
            [self openURLWithSystemCommand:url asset:asset browserPath:fallbackBrowser];
        } else {
            [self finishOpeningAsset:asset error:launchError];
        }
    }
}

- (void)uploadFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Add";
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) {
            NSURL *stored = [self storeFileInSelectedPack:url];
            if (!stored) continue;
            [self addAssetWithTitle:stored.lastPathComponent kind:KindForURL(stored) source:stored.path uploader:self.userEmail.length ? self.userEmail : @"You"];
        }
    }];
}

- (void)login:(id)sender {
    NSString *email = Trimmed(self.emailField.stringValue).lowercaseString;
    if (!email.length) {
        self.loginError = @"Enter your email";
        [self render];
        return;
    }
    self.loggedIn = YES;
    self.userEmail = email;
    self.loginError = @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSMutableDictionary *pack in self.packs) {
            NSMutableArray *teammates = [pack[@"teammates"] mutableCopy];
            if (![teammates containsObject:email]) [teammates insertObject:email atIndex:0];
            pack[@"teammates"] = teammates;
        }
        [self.activity insertObject:[@{@"text": [NSString stringWithFormat:@"%@ signed in.", email], @"time": [NSDate date]} mutableCopy] atIndex:0];
        [self saveState];
        [self render];
    });
}

- (void)inviteFriend:(id)sender {
    NSString *email = self.inviteField.stringValue.lowercaseString;
    if (!email.length) return;
    NSMutableArray *teammates = [[self selectedPack][@"teammates"] mutableCopy];
    if (![teammates containsObject:email]) [teammates addObject:email];
    [self selectedPack][@"teammates"] = teammates;
    [self.activity insertObject:[@{@"text": [NSString stringWithFormat:@"Invited %@.", email], @"time": [NSDate date]} mutableCopy] atIndex:0];
    self.inviteField.stringValue = @"";
    [self.membersPopover close];
    [self saveState];
    [self render];
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    return item;
}

- (void)createPack:(id)sender {
    NSString *suggestedName = @"";
    NSString *validationMessage = nil;
    while (YES) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"New Pack";
        alert.informativeText = validationMessage ?: @"";
        alert.alertStyle = validationMessage.length ? NSAlertStyleWarning : NSAlertStyleInformational;
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 32)];
        field.placeholderString = @"Pack name";
        field.stringValue = suggestedName;
        alert.accessoryView = field;
        [alert addButtonWithTitle:@"Create"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;

        NSString *name = NormalizedPackName(field.stringValue);
        suggestedName = name;
        if (!name.length) {
            validationMessage = @"Enter a name";
            continue;
        }
        if (PackNameExists(self.packs, name)) {
            validationMessage = @"That Pack already exists";
            continue;
        }

        NSMutableDictionary *pack = [@{
            @"id": NSUUID.UUID.UUIDString,
            @"name": name,
            @"summary": @"",
            @"teammates": [NSMutableArray array],
            @"assets": [NSMutableArray array],
            @"trash": [NSMutableArray array]
        } mutableCopy];
        [self.packs addObject:pack];
        self.selectedPackIndex = self.packs.count - 1;
        self.assetFilter = @"All";
        self.searchQuery = @"";
        self.searchActive = NO;
        [self.selectedAssetIDs removeAllObjects];
        self.selectionAnchorID = nil;
        [self saveState];
        LPPLog(@"pack.created", @{ @"packs": @(self.packs.count) });
        [self render];
        return;
    }
}

- (void)showVoltQuickMenu:(NSView *)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *pack = [[NSMenuItem alloc] initWithTitle:self.currentPackName action:nil keyEquivalent:@""];
    pack.enabled = NO;
    [menu addItem:pack];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItemWithTitle:@"Open Pack" symbol:@"rectangle.expand.vertical" action:@selector(showPanel)]];
    NSMenuItem *animate = [self menuItemWithTitle:@"Animate Volt" symbol:@"sparkles" action:@selector(toggleVoltAnimation:)];
    animate.state = self.voltAnimated ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:animate];
    [menu addItem:NSMenuItem.separatorItem];
    for (NSMenuItem *item in [self addMenuItems]) [menu addItem:item];
    [NSMenu popUpContextMenu:menu withEvent:NSApp.currentEvent forView:sender];
}

- (void)renameCurrentPack:(id)sender {
    NSMutableDictionary *pack = [self selectedPack];
    NSString *suggestedName = pack[@"name"] ?: @"";
    NSString *validationMessage = nil;
    while (YES) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Rename Pack";
        alert.informativeText = validationMessage ?: @"";
        alert.alertStyle = validationMessage.length ? NSAlertStyleWarning : NSAlertStyleInformational;
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 32)];
        field.stringValue = suggestedName;
        alert.accessoryView = field;
        [alert addButtonWithTitle:@"Rename"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;

        NSString *name = NormalizedPackName(field.stringValue);
        suggestedName = name;
        if (!name.length) {
            validationMessage = @"Enter a name";
            continue;
        }
        if (PackNameExistsExcept(self.packs, name, pack)) {
            validationMessage = @"That Pack already exists";
            continue;
        }
        pack[@"name"] = name;
        [self saveState];
        LPPLog(@"pack.renamed", @{ @"packs": @(self.packs.count) });
        [self render];
        return;
    }
}

- (void)deleteCurrentPack:(id)sender {
    if (self.packs.count <= 1) return;
    NSMutableDictionary *pack = [self selectedPack];
    NSString *name = pack[@"name"] ?: @"Pack";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Delete %@?", name];
    alert.informativeText = @"Its saved files will move to Trash.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.buttons.firstObject.hasDestructiveAction = YES;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSMutableSet<NSString *> *pathsUsedElsewhere = [NSMutableSet set];
    for (NSDictionary *otherPack in self.packs) {
        if (otherPack == pack) continue;
        for (NSDictionary *asset in otherPack[@"assets"] ?: @[]) {
            NSString *path = AssetFilePath(asset);
            if (path.length) [pathsUsedElsewhere addObject:path.stringByStandardizingPath];
        }
    }

    NSString *uploadsPath = self.uploadsRoot.path.stringByStandardizingPath;
    NSString *uploadsPrefix = [uploadsPath stringByAppendingString:@"/"];
    NSMutableOrderedSet<NSURL *> *filesToTrash = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *asset in pack[@"assets"] ?: @[]) {
        NSString *path = AssetFilePath(asset).stringByStandardizingPath;
        if (!path.length || ![path hasPrefix:uploadsPrefix] || [pathsUsedElsewhere containsObject:path]) continue;
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) [filesToTrash addObject:[NSURL fileURLWithPath:path]];
    }

    NSInteger deletedIndex = self.selectedPackIndex;
    [self.packs removeObjectAtIndex:deletedIndex];
    self.selectedPackIndex = MIN(deletedIndex, (NSInteger)self.packs.count - 1);
    self.assetFilter = @"All";
    self.searchQuery = @"";
    self.searchActive = NO;
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self closePreview];
    [self saveState];
    LPPLog(@"pack.deleted", @{ @"packs": @(self.packs.count), @"files": @(filesToTrash.count) });
    [self render];

    if (filesToTrash.count) {
        [NSWorkspace.sharedWorkspace recycleURLs:filesToTrash.array completionHandler:^(__unused NSDictionary<NSURL *, NSURL *> *newURLs, NSError *error) {
            if (!error) return;
            LPPLog(@"pack.trash_failed", @{ @"error": error.localizedDescription ?: @"unknown" });
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showTransientNotice:@"Pack deleted; some files stayed on disk"];
            });
        }];
    }
}

- (NSArray<NSMenuItem *> *)addMenuItems {
    return @[
        [self menuItemWithTitle:@"Write a Note…" symbol:@"note.text" action:@selector(composeNewNote:)],
        [self menuItemWithTitle:@"Live Clip" symbol:@"viewfinder.rectangular" action:@selector(beginLiveClipCapture:)],
        [self menuItemWithTitle:@"Current Browser Tab" symbol:@"safari" action:@selector(grabCurrentTab:)],
        [self menuItemWithTitle:@"Files…" symbol:@"doc.badge.plus" action:@selector(uploadFile:)],
        [self menuItemWithTitle:@"Screenshot" symbol:@"viewfinder" action:@selector(grabVisiblePhoto:)],
        [self menuItemWithTitle:@"Paste from Clipboard" symbol:@"doc.on.clipboard" action:@selector(paste:)],
        [self menuItemWithTitle:@"Save Full-Size Photo…" symbol:@"square.and.arrow.down" action:@selector(savePhotoFromLink:)],
        [self menuItemWithTitle:@"Add Link…" symbol:@"link.badge.plus" action:@selector(grabLink:)]
    ];
}

- (void)showAddMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSMenuItem *item in [self addMenuItems]) [menu addItem:item];
    [NSMenu popUpContextMenu:menu withEvent:NSApp.currentEvent forView:sender];
}

- (void)showOverflowMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItem:[self menuItemWithTitle:@"Members…" symbol:@"person.2" action:@selector(showMembers:)]];
    [menu addItem:[self menuItemWithTitle:@"Rename Pack…" symbol:@"pencil" action:@selector(renameCurrentPack:)]];
    NSMenuItem *deletePack = [self menuItemWithTitle:@"Delete Pack…" symbol:@"trash" action:@selector(deleteCurrentPack:)];
    deletePack.enabled = self.packs.count > 1;
    [menu addItem:deletePack];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItemWithTitle:@"New Pack…" symbol:@"folder.badge.plus" action:@selector(createPack:)]];
    [menu addItem:[self menuItemWithTitle:@"Copy Pack Link" symbol:@"link" action:@selector(copyShareLink:)]];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *pin = [self menuItemWithTitle:@"Keep Pack Open" symbol:@"pin" action:@selector(togglePanelPinned:)];
    pin.state = self.panelPinned ? NSControlStateValueOn : NSControlStateValueOff;
    pin.toolTip = @"Stay visible while you work in other apps";
    [menu addItem:pin];
    [menu addItem:NSMenuItem.separatorItem];
    NSUInteger trashCount = [[self selectedPack][@"trash"] count];
    NSMenuItem *emptyTrash = [self menuItemWithTitle:trashCount ? [NSString stringWithFormat:@"Empty Trash (%lu)…", (unsigned long)trashCount] : @"Empty Trash" symbol:@"trash" action:@selector(emptyTrashForCurrentPack:)];
    emptyTrash.enabled = trashCount > 0;
    [menu addItem:emptyTrash];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItemWithTitle:@"Ask AI about this Pack…" symbol:@"sparkles" action:@selector(showAskAIPanel:)]];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *account = [[NSMenuItem alloc] initWithTitle:self.userEmail.length ? self.userEmail : @"Account" action:nil keyEquivalent:@""];
    account.enabled = NO;
    [menu addItem:account];
    [menu addItem:[self menuItemWithTitle:@"Sign Out" symbol:@"rectangle.portrait.and.arrow.right" action:@selector(signOut:)]];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Live Project Packs" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;
    [menu addItem:quit];
    [NSMenu popUpContextMenu:menu withEvent:NSApp.currentEvent forView:sender];
}

- (void)showMembers:(id)sender {
    NSArray<NSString *> *teammates = [self selectedPack][@"teammates"];
    NSUInteger rowCount = teammates.count + 1;
    CGFloat height = MIN(292, 98 + rowCount * 34);
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 286, height)];
    ApplyVoltScreenChrome(content);

    NSTextField *heading = [NSTextField labelWithString:@"Members"];
    heading.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    heading.textColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    heading.frame = NSMakeRect(kVoltBezelWidth + 5, height - 31, 180, 18);
    [content addSubview:heading];

    NSButton *share = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"link" accessibilityDescription:nil] target:self action:@selector(copyShareLink:)];
    share.bordered = NO;
    share.contentTintColor = VoltTealColor();
    share.frame = NSMakeRect(242, height - 36, 30, 26);
    share.toolTip = @"Copy invite link";
    [content addSubview:share];

    NSMutableArray<NSString *> *people = [NSMutableArray arrayWithObject:self.userEmail.length ? self.userEmail : @"You"];
    [people addObjectsFromArray:teammates];
    CGFloat y = height - 67;
    for (NSUInteger index = 0; index < people.count && y > 46; index++) {
        NSString *person = people[index];
        NSView *avatar = [[NSView alloc] initWithFrame:NSMakeRect(kVoltBezelWidth + 5, y, 24, 24)];
        avatar.wantsLayer = YES;
        avatar.layer.cornerRadius = 12;
        avatar.layer.backgroundColor = AvatarColor(person).CGColor;
        [content addSubview:avatar];

        NSTextField *initial = [NSTextField labelWithString:Initials(person)];
        initial.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
        initial.textColor = NSColor.whiteColor;
        initial.alignment = NSTextAlignmentCenter;
        initial.frame = NSMakeRect(kVoltBezelWidth + 5, y + 5, 24, 14);
        [content addSubview:initial];

        NSTextField *name = [NSTextField labelWithString:person];
        name.font = [NSFont systemFontOfSize:12];
        name.textColor = [NSColor colorWithCalibratedWhite:0.88 alpha:1];
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        name.frame = NSMakeRect(48, y + 4, 200, 17);
        [content addSubview:name];
        y -= 34;
    }

    self.inviteField = [[NSTextField alloc] initWithFrame:NSMakeRect(kVoltBezelWidth + 5, 12, 214, 28)];
    self.inviteField.placeholderString = @"friend@email.com";
    self.inviteField.font = [NSFont systemFontOfSize:12];
    self.inviteField.target = self;
    self.inviteField.action = @selector(inviteFriend:);
    [content addSubview:self.inviteField];

    NSButton *invite = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.up" accessibilityDescription:nil] target:self action:@selector(inviteFriend:)];
    invite.bordered = NO;
    invite.contentTintColor = VoltScreenColor();
    invite.wantsLayer = YES;
    invite.layer.backgroundColor = VoltGoldColor().CGColor;
    invite.layer.cornerRadius = 6;
    invite.frame = NSMakeRect(242, 12, 30, 28);
    invite.toolTip = @"Invite";
    [content addSubview:invite];

    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = content;
    self.membersPopover = [[NSPopover alloc] init];
    // NSPopover otherwise follows the system's light/dark setting, not this
    // app's own always-dark theme — without this it renders as a jarring
    // bright native popover in the middle of an otherwise dark app.
    self.membersPopover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.membersPopover.behavior = NSPopoverBehaviorTransient;
    self.membersPopover.contentViewController = controller;
    self.membersPopover.contentSize = content.frame.size;
    [self.membersPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:NSRectEdgeMinY];
}

- (void)copyShareLink:(id)sender {
    NSString *pack = [[self selectedPack][@"name"] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *link = [NSString stringWithFormat:@"pack://share/%@", pack ?: @"pack"];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:link forType:NSPasteboardTypeString];
    [self.activity insertObject:[@{@"text": @"Share link copied", @"time": [NSDate date]} mutableCopy] atIndex:0];
    [self render];
}

- (void)signOut:(id)sender {
    [self.membersPopover close];
    [self closePreview];
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    self.loggedIn = NO;
    self.userEmail = nil;
    self.loginError = @"";
    [self saveState];
    [self render];
}

- (void)toggleView:(NSSegmentedControl *)sender {
    self.boardMode = sender.selectedSegment == 0;
    [self saveState];
    [self render];
}

- (void)togglePanelPinned:(id)sender {
    self.panelPinned = !self.panelPinned;
    self.panel.hidesOnDeactivate = !self.panelPinned;
    [self saveState];
    [self showTransientNotice:self.panelPinned ? @"Pack stays open while you work" : @"Pack hides when you switch apps"];
}

- (void)toggleVoltAnimation:(id)sender {
    self.voltAnimated = !self.voltAnimated;
    [self saveState];
    [self.compactTabView refresh];
    [self showTransientNotice:self.voltAnimated ? @"Volt is awake" : @"Volt will hold still"];
}

- (void)filterChanged:(NSSegmentedControl *)sender {
    NSArray<NSString *> *filters = @[@"All", @"Images", @"Links", @"PDFs", @"Videos", @"Trash"];
    NSInteger index = sender.selectedSegment;
    self.assetFilter = (index >= 0 && index < (NSInteger)filters.count) ? filters[index] : @"All";
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self closePreview];
    [self saveState];
    [self render];
}

- (void)activateSearch:(id)sender {
    self.searchActive = YES;
    [self render];
    [self.panel makeFirstResponder:self.searchField];
    [self.searchField selectText:nil];
}

- (void)searchChanged:(NSSearchField *)sender {
    NSRange selectedRange = NSMakeRange(sender.stringValue.length, 0);
    if ([sender.currentEditor isKindOfClass:NSTextView.class]) selectedRange = [(NSTextView *)sender.currentEditor selectedRange];
    self.searchQuery = sender.stringValue ?: @"";
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self render];
    [self.panel makeFirstResponder:self.searchField];
    if ([self.searchField.currentEditor isKindOfClass:NSTextView.class]) {
        NSUInteger location = MIN(selectedRange.location, self.searchField.stringValue.length);
        [(NSTextView *)self.searchField.currentEditor setSelectedRange:NSMakeRange(location, 0)];
    }
}

- (void)selectPackFromPopup:(NSPopUpButton *)sender {
    NSInteger index = sender.indexOfSelectedItem;
    if (index < 0 || index >= (NSInteger)self.packs.count) {
        [sender selectItemAtIndex:self.selectedPackIndex];
        [self createPack:sender];
        return;
    }
    self.selectedPackIndex = index;
    self.assetFilter = @"All";
    self.searchQuery = @"";
    self.searchActive = NO;
    [self.selectedAssetIDs removeAllObjects];
    self.selectionAnchorID = nil;
    [self closePreview];
    [self saveState];
    [self render];
}

- (void)render {
    BOOL hadScrollView = self.assetScrollView != nil;
    CGFloat previousOffsetY = hadScrollView ? NSMinY(self.assetScrollView.contentView.bounds) : 0;
    NSString *previousSignature = self.listSignature;

    [self.rootView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.visibleAssetTiles = [NSMutableArray array];
    self.searchField = nil;
    self.assetScrollView = nil;
    CGFloat w = self.rootView.bounds.size.width;
    CGFloat h = self.rootView.bounds.size.height;
    // Raised from 0.42 to 0.88 alpha — the low-alpha wash read as thin and
    // washed-out against whatever was behind the window; a near-opaque
    // surface gives every card, pill, and piece of text sitting on top of
    // it something solid and high-contrast to read against.
    NSColor *chrome = [NSColor colorWithCalibratedRed:0.085 green:0.094 blue:0.110 alpha:1];
    // No border here, matching the Ask AI panel and every other control on
    // this screen now — the fill color against the desktop is what defines
    // the edge, not a stroke. Minimal wins; the bezel stays on the small
    // utility panels only (see ApplyVoltScreenChrome).
    self.rootView.wantsLayer = YES;
    self.rootView.layer.cornerRadius = 16;
    self.rootView.layer.backgroundColor = chrome.CGColor;

    NSVisualEffectView *glass = GlassBackdrop(self.rootView.bounds, 16, NSVisualEffectMaterialHUDWindow);
    glass.layer.backgroundColor = chrome.CGColor;
    [self.rootView addSubview:glass positioned:NSWindowBelow relativeTo:nil];

    if (!self.loggedIn) {
        NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect((w - 54) / 2, h - 102, 54, 54)];
        logo.image = AppIconImage();
        logo.imageScaling = NSImageScaleProportionallyUpOrDown;
        [self.rootView addSubview:logo];

        NSTextField *headline = [NSTextField labelWithString:@"Who's using this Pack?"];
        headline.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        headline.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1];
        headline.alignment = NSTextAlignmentCenter;
        headline.frame = NSMakeRect(24, h - 134, w - 48, 20);
        [self.rootView addSubview:headline];

        NSTextField *caption = [NSTextField labelWithString:@"Your email labels whatever you add, so teammates can see who shared it."];
        caption.font = [NSFont systemFontOfSize:11];
        caption.textColor = [NSColor colorWithCalibratedWhite:0.60 alpha:1];
        caption.alignment = NSTextAlignmentCenter;
        caption.lineBreakMode = NSLineBreakByWordWrapping;
        caption.maximumNumberOfLines = 2;
        caption.frame = NSMakeRect(30, h - 176, w - 60, 34);
        [self.rootView addSubview:caption];

        self.emailField = [[NSTextField alloc] initWithFrame:NSMakeRect(34, h - 220, w - 68, 36)];
        self.emailField.placeholderString = @"you@email.com";
        self.emailField.font = [NSFont systemFontOfSize:14];
        self.emailField.target = self;
        self.emailField.action = @selector(login:);
        [self.rootView addSubview:self.emailField];

        // Borderless + hand-drawn, not NSBezelStyleTexturedRounded — that
        // bezel style ignores contentTintColor and always renders in the
        // system accent color regardless of what's set here.
        NSButton *login = [NSButton buttonWithTitle:@"" target:self action:@selector(login:)];
        login.bordered = NO;
        login.attributedTitle = [[NSAttributedString alloc] initWithString:@"Continue" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: VoltScreenColor(),
            NSParagraphStyleAttributeName: ({
                NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
                style.alignment = NSTextAlignmentCenter;
                style;
            })
        }];
        login.wantsLayer = YES;
        login.layer.backgroundColor = VoltGoldColor().CGColor;
        login.layer.cornerRadius = 8;
        login.frame = NSMakeRect(34, h - 266, w - 68, 38);
        login.keyEquivalent = @"\r";
        [self.rootView addSubview:login];

        if (self.loginError.length) {
            NSTextField *error = [NSTextField labelWithString:self.loginError];
            error.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
            error.textColor = NSColor.systemRedColor;
            error.alignment = NSTextAlignmentCenter;
            error.frame = NSMakeRect(34, h - 296, w - 68, 18);
            [self.rootView addSubview:error];
        }

        [self.panel makeFirstResponder:self.emailField];
        return;
    }

    // A brighter band across the top marks off the Pack's identity (name +
    // status) from its contents (filters, cards, notes) below — instead of
    // the whole window reading as one flat surface with no sense of "this
    // part is the header." No divider line under it now — the brightness
    // shift alone is the separation.
    CGFloat headerBandHeight = 56;
    NSView *headerBand = [[NSView alloc] initWithFrame:NSMakeRect(0, h - headerBandHeight, w, headerBandHeight)];
    headerBand.wantsLayer = YES;
    headerBand.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.035].CGColor;
    [self.rootView addSubview:headerBand];

    CGFloat pageInset = 14;
    CGFloat topY = h - 46;
    CGFloat controlHeight = 28;
    // One gap value for every internal spacing in this view (icon-to-icon,
    // row-to-row) instead of a mix of 8/9/10/12 scattered per element —
    // pageInset (14) is the only other spacing constant, for the outer edge.
    CGFloat rowGap = 8;
    // The toolbar icons get their own smaller size and wider gap than the
    // rest of the row — quieter and more breathing room so they read as
    // secondary actions next to the Pack name, not competing UI-kit chrome.
    CGFloat iconButtonSize = 24;
    CGFloat iconGap = 12;
    CGFloat rightEdge = w - pageInset;
    CGFloat moreX = rightEdge - iconButtonSize;
    CGFloat addX = moreX - iconGap - iconButtonSize;
    CGFloat aiX = addX - iconGap - iconButtonSize;
    CGFloat packPickerWidth = 130;

    // A small mint dot for "online/synced" — its own distinct color so it's
    // never confused with the amber perimeter streak (normal) or the
    // purple one (AI thinking). Sits right against the Pack name since
    // that's the identity it's reporting status for.
    CGFloat statusDotSize = 7;
    NSView *statusDot = [[NSView alloc] initWithFrame:NSMakeRect(pageInset, topY + (controlHeight - statusDotSize) / 2, statusDotSize, statusDotSize)];
    statusDot.wantsLayer = YES;
    statusDot.layer.cornerRadius = statusDotSize / 2;
    statusDot.layer.backgroundColor = PackMintColor().CGColor;
    statusDot.toolTip = @"Synced";
    [self.rootView addSubview:statusDot];

    CGFloat packPickerX = pageInset + statusDotSize + rowGap;

    // One header row now carries the pack picker, search, and the three
    // persistent actions (Add / AI / overflow). Members and pack-rename
    // moved into the "more" overflow menu below — a second always-visible
    // row plus inline avatar bubbles was chrome the user called "way too
    // long," not information anyone needed at a glance.
    NSPopUpButton *packPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(packPickerX, topY, packPickerWidth, controlHeight) pullsDown:NO];
    for (NSDictionary *pack in self.packs) [packPicker addItemWithTitle:pack[@"name"]];
    [packPicker selectItemAtIndex:self.selectedPackIndex];
    [packPicker.menu addItem:NSMenuItem.separatorItem];
    [packPicker addItemWithTitle:@"New Pack…"];
    packPicker.itemArray.lastObject.image = [NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:nil];
    // The Pack name is the one thing on this screen that should read as a
    // title, not a control among controls — bigger and bolder than
    // everything around it (icon buttons, filters) so hierarchy is obvious
    // at a glance instead of everything competing at the same weight.
    packPicker.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
    packPicker.bordered = NO;
    packPicker.target = self;
    packPicker.action = @selector(selectPackFromPopup:);
    [self.rootView addSubview:packPicker];

    // NSBezelStyleTexturedRounded ignores contentTintColor for its glyph and
    // always follows the system accent color (blue) — borderless + a
    // hand-drawn layer is what actually lets these carry Volt's colors
    // (confirmed by the character dock buttons below, which are borderless
    // and do render their custom tint correctly). HoverIconButton adds the
    // idle/hover/pressed ladder so these read as clickable, not just static
    // — but idleBackground is left unset here on purpose: no fill at rest
    // at all, quieter than a permanently-visible pill, background only
    // appears on hover/press.
    CGFloat iconY = topY + (controlHeight - iconButtonSize) / 2;
    NSImageSymbolConfiguration *toolbarIconConfig = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    NSColor *toolbarIconTint = [NSColor colorWithCalibratedWhite:0.75 alpha:1];

    HoverIconButton *add = [HoverIconButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"tray.and.arrow.down.fill" accessibilityDescription:@"Add to Pack"] imageWithSymbolConfiguration:toolbarIconConfig] target:self action:@selector(showAddMenu:)];
    add.imagePosition = NSImageOnly;
    add.contentTintColor = toolbarIconTint;
    add.hoverBackground = SurfaceHoverColor();
    add.pressedBackground = SurfacePressedColor();
    add.layer.cornerRadius = 6;
    add.frame = NSMakeRect(addX, iconY, iconButtonSize, iconButtonSize);
    add.toolTip = @"Add to Pack";
    [self.rootView addSubview:add];

    HoverIconButton *ai = [HoverIconButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"terminal.fill" accessibilityDescription:@"Pack AI Console"] imageWithSymbolConfiguration:toolbarIconConfig] target:self action:@selector(showAskAIPanel:)];
    ai.contentTintColor = toolbarIconTint;
    ai.hoverBackground = SurfaceHoverColor();
    ai.pressedBackground = SurfacePressedColor();
    ai.layer.cornerRadius = 6;
    ai.frame = NSMakeRect(aiX, iconY, iconButtonSize, iconButtonSize);
    ai.toolTip = @"Pack AI Console";
    [self.rootView addSubview:ai];

    HoverIconButton *more = [HoverIconButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:nil] imageWithSymbolConfiguration:toolbarIconConfig] target:self action:@selector(showOverflowMenu:)];
    more.contentTintColor = toolbarIconTint;
    more.hoverBackground = SurfaceHoverColor();
    more.pressedBackground = SurfacePressedColor();
    more.layer.cornerRadius = 6;
    more.frame = NSMakeRect(moreX, iconY, iconButtonSize, iconButtonSize);
    more.toolTip = @"More";
    [self.rootView addSubview:more];

    CGFloat toggleWidth = 64;
    CGFloat filterY = topY - rowGap - 24;
    // Icon segments need far less width than the old text labels did — a
    // fixed compact strip instead of stretching to fill the row leaves
    // honest empty space rather than oversized buttons with dead padding.
    CGFloat filterWidth = 168;
    NSArray<NSString *> *filterNames = @[@"All", @"Images", @"Links", @"PDFs", @"Videos", @"Trash"];
    NSArray<NSString *> *filterSymbols = @[@"circle.grid.2x2", @"photo", @"link", @"doc.text", @"video", @"trash"];
    NSMutableArray<NSImage *> *filterImages = [NSMutableArray array];
    for (NSString *symbol in filterSymbols) [filterImages addObject:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
    NSSegmentedControl *filters = [NSSegmentedControl segmentedControlWithImages:filterImages trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filterChanged:)];
    filters.frame = NSMakeRect(pageInset, filterY, filterWidth, 24);
    filters.segmentStyle = NSSegmentStyleCapsule;
    filters.selectedSegmentBezelColor = VoltGoldColor();
    for (NSUInteger i = 0; i < filterNames.count; i++) [filters setToolTip:filterNames[i] forSegment:i];
    NSInteger filterIndex = [filterNames indexOfObject:self.assetFilter ?: @"All"];
    filters.selectedSegment = filterIndex == NSNotFound ? 0 : filterIndex;
    [self.rootView addSubview:filters];

    NSSegmentedControl *viewToggle = [NSSegmentedControl segmentedControlWithImages:@[
        [NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:nil],
        [NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:nil]
    ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(toggleView:)];
    viewToggle.frame = NSMakeRect(w - pageInset - toggleWidth, filterY, toggleWidth, 24);
    viewToggle.segmentStyle = NSSegmentStyleTexturedRounded;
    viewToggle.selectedSegmentBezelColor = VoltGoldColor();
    viewToggle.selectedSegment = self.boardMode ? 0 : 1;
    [viewToggle setToolTip:@"Grid" forSegment:0];
    [viewToggle setToolTip:@"List" forSegment:1];
    [self.rootView addSubview:viewToggle];

    // The bottom corner is the notes bar, full stop — it no longer swaps to
    // a selection tray with Ask/Compare buttons when something's selected.
    // Ask AI already picks up the current selection as context on its own
    // (see showAskAIPanel:), so that capability isn't lost, just no longer
    // duplicated as a second control down here.
    CGFloat quickAddHeight = 44;
    CGFloat bottomBarHeight = quickAddHeight;
    CGFloat scrollBottom = pageInset + bottomBarHeight + 10;
    CGFloat scrollTop = filterY - rowGap;

    NSView *quickAdd = [[NSView alloc] initWithFrame:NSMakeRect(pageInset, pageInset, w - pageInset * 2, quickAddHeight)];
    quickAdd.wantsLayer = YES;
    quickAdd.layer.backgroundColor = SurfaceIdleColor().CGColor;
    quickAdd.layer.cornerRadius = quickAddHeight / 2;
    [self.rootView addSubview:quickAdd];

    NSImageView *noteGlyph = [[NSImageView alloc] initWithFrame:NSMakeRect(14, (quickAddHeight - 16) / 2, 16, 16)];
    noteGlyph.image = [NSImage imageWithSystemSymbolName:@"note.text" accessibilityDescription:nil];
    noteGlyph.contentTintColor = [NSColor colorWithCalibratedWhite:0.5 alpha:1];
    [quickAdd addSubview:noteGlyph];

    CGFloat quickAddSendSize = 30;
    HoverIconButton *quickAddSend = [HoverIconButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.up" accessibilityDescription:@"Save note"] target:self action:@selector(quickAddNoteSubmit:)];
    quickAddSend.imagePosition = NSImageOnly;
    quickAddSend.contentTintColor = VoltScreenColor();
    quickAddSend.hoverBackground = VoltGoldHoverColor();
    quickAddSend.pressedBackground = VoltGoldPressedColor();
    quickAddSend.idleBackground = VoltGoldColor();
    quickAddSend.layer.cornerRadius = quickAddSendSize / 2;
    quickAddSend.frame = NSMakeRect(NSWidth(quickAdd.bounds) - rowGap - quickAddSendSize, (quickAddHeight - quickAddSendSize) / 2, quickAddSendSize, quickAddSendSize);
    quickAddSend.toolTip = @"Save as a note";
    [quickAdd addSubview:quickAddSend];

    CGFloat quickAddFieldHeight = 18;
    CGFloat quickAddFieldX = 38;
    CGFloat quickAddFieldWidth = NSMinX(quickAddSend.frame) - rowGap - quickAddFieldX;
    NSTextField *quickAddField = [[NSTextField alloc] initWithFrame:NSMakeRect(quickAddFieldX, (quickAddHeight - quickAddFieldHeight) / 2, quickAddFieldWidth, quickAddFieldHeight)];
    quickAddField.placeholderString = @"Type a note and press Enter…";
    quickAddField.font = [NSFont systemFontOfSize:13];
    quickAddField.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1];
    quickAddField.bordered = NO;
    quickAddField.focusRingType = NSFocusRingTypeNone;
    quickAddField.drawsBackground = NO;
    quickAddField.target = self;
    quickAddField.action = @selector(quickAddNoteSubmit:);
    [quickAdd addSubview:quickAddField];
    self.quickAddNoteField = quickAddField;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(pageInset, scrollBottom, w - pageInset * 2, scrollTop - scrollBottom)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    [self.rootView addSubview:scroll];

    // Search floats in its own corner, bottom-right, above everything else —
    // a bare icon until tapped (or ⌘K), then it grows into a real field.
    // Nothing to look at when you're not searching, and it no longer
    // crowds the header row.
    BOOL searchExpanded = self.searchActive || self.searchQuery.length > 0;
    CGFloat searchCollapsedSize = 20;
    CGFloat searchExpandedWidth = 170;
    CGFloat searchHeight = 34;
    CGFloat noticeReserve = self.transientNotice.length ? 40 : 0;
    CGFloat searchBottomY = pageInset + bottomBarHeight + 10 + noticeReserve;
    CGFloat searchRightX = w - pageInset;
    if (searchExpanded) {
        CGFloat searchX = searchRightX - searchExpandedWidth;
        NSSearchField *search = [[NSSearchField alloc] initWithFrame:NSMakeRect(searchX, searchBottomY, searchExpandedWidth, searchHeight)];
        search.placeholderString = @"Search";
        search.font = [NSFont systemFontOfSize:12];
        search.stringValue = self.searchQuery ?: @"";
        search.target = self;
        search.action = @selector(searchChanged:);
        search.sendsSearchStringImmediately = YES;
        search.bordered = NO;
        search.focusRingType = NSFocusRingTypeNone;
        search.wantsLayer = YES;
        search.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:0.86].CGColor;
        search.layer.cornerRadius = searchHeight / 2;
        [self.rootView addSubview:search];
        self.searchField = search;
    } else {
        CGFloat searchX = searchRightX - searchCollapsedSize;
        NSImageSymbolConfiguration *searchIconConfig = [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightMedium];
        NSImage *searchIcon = [[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:@"Search"] imageWithSymbolConfiguration:searchIconConfig];
        HoverIconButton *searchButton = [HoverIconButton buttonWithImage:searchIcon target:self action:@selector(activateSearch:)];
        searchButton.contentTintColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1];
        searchButton.hoverBackground = SurfaceHoverColor();
        searchButton.pressedBackground = SurfacePressedColor();
        searchButton.idleBackground = [NSColor colorWithCalibratedWhite:0.08 alpha:0.75];
        searchButton.layer.cornerRadius = searchCollapsedSize / 2;
        searchButton.frame = NSMakeRect(searchX, searchBottomY, searchCollapsedSize, searchCollapsedSize);
        searchButton.toolTip = @"Search";
        [self.rootView addSubview:searchButton];
    }

    NSDictionary<NSString *, NSString *> *kindForFilter = @{@"Images": @"Image", @"Links": @"Link", @"PDFs": @"PDF", @"Videos": @"Video"};
    NSString *requiredKind = kindForFilter[self.assetFilter ?: @"All"];
    NSArray<NSMutableDictionary *> *assets = [self visibleAssets];

    CGFloat contentHeight = scroll.bounds.size.height;
    if (self.boardMode) {
        CGFloat gap = 8;
        CGFloat tileWidth = floor((scroll.bounds.size.width - gap) / 2);
        CGFloat tileHeight = 166;
        NSUInteger rows = (assets.count + 1) / 2;
        contentHeight = MAX(scroll.bounds.size.height, rows ? rows * tileHeight + (rows - 1) * gap : 0);
        AssetCanvasView *canvas = [[AssetCanvasView alloc] initWithFrame:NSMakeRect(0, 0, scroll.bounds.size.width, contentHeight)];
        canvas.controller = self;
        scroll.documentView = canvas;
        for (NSUInteger i = 0; i < assets.count; i++) {
            NSUInteger row = i / 2;
            NSUInteger column = i % 2;
            CGFloat x = column * (tileWidth + gap);
            CGFloat y = contentHeight - tileHeight - row * (tileHeight + gap);
            AssetTile *tile = [[AssetTile alloc] initWithAsset:assets[i] controller:self gridMode:YES];
            tile.frame = NSMakeRect(x, y, tileWidth, tileHeight);
            [canvas addSubview:tile];
            [self.visibleAssetTiles addObject:tile];
        }
        if (!assets.count) {
            [canvas addSubview:[self emptyStateViewForWidth:canvas.bounds.size.width height:contentHeight filtered:(self.searchQuery.length > 0 || requiredKind != nil)]];
        }
    } else {
        CGFloat rowHeight = 68;
        CGFloat gap = 7;
        contentHeight = MAX(scroll.bounds.size.height, assets.count ? assets.count * rowHeight + (assets.count - 1) * gap : 0);
        AssetCanvasView *canvas = [[AssetCanvasView alloc] initWithFrame:NSMakeRect(0, 0, scroll.bounds.size.width, contentHeight)];
        canvas.controller = self;
        scroll.documentView = canvas;
        CGFloat y = contentHeight - rowHeight;
        for (NSMutableDictionary *asset in assets) {
            AssetTile *tile = [[AssetTile alloc] initWithAsset:asset controller:self gridMode:NO];
            tile.frame = NSMakeRect(0, y, scroll.bounds.size.width, rowHeight);
            [canvas addSubview:tile];
            [self.visibleAssetTiles addObject:tile];
            y -= rowHeight + gap;
        }
        if (!assets.count) {
            [canvas addSubview:[self emptyStateViewForWidth:canvas.bounds.size.width height:contentHeight filtered:(self.searchQuery.length > 0 || requiredKind != nil)]];
        }
    }

    self.assetScrollView = scroll;
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%d",
                           [self selectedPack][@"id"] ?: @"",
                           self.assetFilter ?: @"All",
                           self.searchQuery ?: @"",
                           self.boardMode];
    BOOL sameList = hadScrollView && [signature isEqualToString:previousSignature];
    self.listSignature = signature;

    NSClipView *clip = scroll.contentView;
    CGFloat maxOffsetY = MAX(0, contentHeight - NSHeight(clip.bounds));
    CGFloat targetY = sameList ? MIN(MAX(previousOffsetY, 0), maxOffsetY) : maxOffsetY;
    [clip scrollToPoint:NSMakePoint(0, targetY)];
    [scroll reflectScrolledClipView:clip];

    if (self.transientNotice.length) {
        BOOL canUndo = self.undoToken.length && self.lastDeletedAssetRecords.count && [self.transientNotice isEqualToString:self.undoNotice];
        // Sits just above the character dock (when there is one) instead of
        // at a fixed y — otherwise it draws directly on top of Electro/Scout.
        CGFloat noticeY = pageInset + bottomBarHeight + 8;
        NSView *noticeBar = [[NSView alloc] initWithFrame:NSMakeRect(pageInset, noticeY, w - pageInset * 2, 30)];
        noticeBar.wantsLayer = YES;
        noticeBar.layer.cornerRadius = 8;
        noticeBar.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:0.95].CGColor;

        NSTextField *notice = [NSTextField labelWithString:self.transientNotice];
        notice.font = [NSFont systemFontOfSize:11];
        notice.textColor = [NSColor colorWithCalibratedWhite:0.78 alpha:1];
        notice.lineBreakMode = NSLineBreakByTruncatingTail;
        notice.frame = NSMakeRect(10, 7, NSWidth(noticeBar.bounds) - (canUndo ? 78 : 20), 16);
        [noticeBar addSubview:notice];

        if (canUndo) {
            NSButton *undo = [NSButton buttonWithTitle:@"Undo" target:self action:@selector(undoLastDelete:)];
            undo.bezelStyle = NSBezelStyleInline;
            undo.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            undo.contentTintColor = VoltTealColor();
            undo.frame = NSMakeRect(NSWidth(noticeBar.bounds) - 66, 2, 58, 25);
            [noticeBar addSubview:undo];
        }
        [self.rootView addSubview:noticeBar];
    }

    AddRimGlowOverlay(self.rootView, 16, self.askAIWaitingForResponse);

    [self.compactTabView refresh];
}

- (NSView *)emptyStateViewForWidth:(CGFloat)width height:(CGFloat)height filtered:(BOOL)filtered {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    CGFloat centerY = height / 2;

    if (filtered) {
        NSTextField *empty = [NSTextField labelWithString:@"No results"];
        empty.font = [NSFont systemFontOfSize:12];
        empty.textColor = [NSColor colorWithCalibratedWhite:0.58 alpha:1];
        empty.alignment = NSTextAlignmentCenter;
        empty.frame = NSMakeRect(20, centerY - 10, width - 40, 20);
        [container addSubview:empty];
        return container;
    }

    CGFloat artSize = 78;
    NSImageView *art = [[NSImageView alloc] initWithFrame:NSMakeRect((width - artSize) / 2, centerY + 12, artSize, artSize)];
    art.image = BundledPNG(@"volt-mascot-idle") ?: AppIconImage();
    art.imageScaling = NSImageScaleProportionallyUpOrDown;
    art.alphaValue = 0.9;
    [container addSubview:art];

    NSTextField *headline = [NSTextField labelWithString:@"This Pack is empty"];
    headline.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    headline.textColor = [NSColor colorWithCalibratedWhite:0.88 alpha:1];
    headline.alignment = NSTextAlignmentCenter;
    headline.frame = NSMakeRect(16, centerY - 10, width - 32, 18);
    [container addSubview:headline];

    NSTextField *hint = [NSTextField labelWithString:@"Drop files onto Volt or straight in here.\nPress ⌘V to paste whatever you copied."];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor colorWithCalibratedWhite:0.60 alpha:1];
    hint.alignment = NSTextAlignmentCenter;
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 2;
    hint.frame = NSMakeRect(12, centerY - 50, width - 24, 34);
    [container addSubview:hint];

    return container;
}
@end

static void LogUncaughtException(NSException *exception) {
    LPPLog(@"app.uncaught_exception", @{
        @"name": exception.name ?: @"unknown",
        @"reason": exception.reason ?: @"unknown"
    });
    NSLog(@"Uncaught exception: %@ %@", exception.name, exception.reason);
    NSLog(@"%@", exception.callStackSymbols);
}

static int RunSelfTests(void) {
    __block NSUInteger failures = 0;
    __block NSUInteger checks = 0;
    void (^check)(BOOL, NSString *) = ^(BOOL condition, NSString *name) {
        checks++;
        if (condition) return;
        failures++;
        fprintf(stderr, "FAIL: %s\n", name.UTF8String);
    };

    for (NSString *state in @[@"volt-mascot-idle", @"volt-mascot-catching", @"volt-mascot-success"]) {
        check(BundledPNG(state) != nil, [NSString stringWithFormat:@"loads %@", state]);
        check(BundledPNGHasAlpha(state), [NSString stringWithFormat:@"preserves alpha for %@", state]);
    }
    check(BundledPNG(@"LiveProjectPacks-icon") != nil, @"loads the Volt application icon");
    NSPasteboard *testPasteboard = [NSPasteboard pasteboardWithUniqueName];
    [testPasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
    BOOL wrotePasteboard = [testPasteboard setString:@"https://example.com/reference" forType:NSPasteboardTypeString];
    check(!wrotePasteboard || PasteboardLooksDroppable(testPasteboard), @"accepts link text drops on Volt");

    NSRect visibleFrame = NSMakeRect(100, 50, 1000, 700);
    NSSize panelSize = NSMakeSize(104, 92);
    check(NSEqualPoints(ClampedPanelOrigin(NSMakePoint(-40, -20), panelSize, visibleFrame), NSMakePoint(100, 50)), @"keeps Volt inside the lower-left screen edge");
    check(NSEqualPoints(ClampedPanelOrigin(NSMakePoint(1200, 900), panelSize, visibleFrame), NSMakePoint(996, 658)), @"keeps Volt inside the upper-right screen edge");
    check(NSEqualPoints(ClampedPanelOrigin(NSMakePoint(400, 300), panelSize, visibleFrame), NSMakePoint(400, 300)), @"preserves an in-bounds Volt position");

    NSSize packPanel = NSMakeSize(390, 520);
    NSPoint besideLowerLeft = PanelOriginNearTab(NSMakeRect(120, 60, 104, 92), packPanel, visibleFrame);
    check(NSEqualPoints(besideLowerLeft, NSMakePoint(236, 50)), @"opens the Pack beside Volt in the lower-left corner");
    NSPoint besideRightEdge = PanelOriginNearTab(NSMakeRect(980, 640, 104, 92), packPanel, visibleFrame);
    check(NSEqualPoints(besideRightEdge, NSMakePoint(578, 212)), @"flips the Pack to Volt's left when the right edge is tight");
    check(NSContainsRect(visibleFrame, NSMakeRect(besideRightEdge.x, besideRightEdge.y, packPanel.width, packPanel.height)), @"keeps the Pack on screen next to Volt");

    check(NextSelectionIndex(NSNotFound, 1, 4) == 0, @"starts arrow selection at the newest asset");
    check(NextSelectionIndex(NSNotFound, -1, 4) == 3, @"starts upward arrow selection at the oldest asset");
    check(NextSelectionIndex(0, -1, 4) == 0, @"stops arrow selection at the top of the list");
    check(NextSelectionIndex(3, 1, 4) == 3, @"stops arrow selection at the end of the list");
    check(NextSelectionIndex(1, 2, 4) == 3, @"moves a full grid row at a time");
    check(NextSelectionIndex(0, 1, 0) == NSNotFound, @"ignores arrow keys in an empty Pack");

    check([TitleFromHTML(@"<html><head><title>  Hello   World  </title></head>") isEqualToString:@"Hello World"], @"reads a page title and tidies its whitespace");
    check([TitleFromHTML(@"<meta property=\"og:title\" content=\"Ben &amp; Jerry&#39;s\">") isEqualToString:@"Ben & Jerry's"], @"decodes entities in a shared page title");
    check([TitleFromHTML(@"<meta property=\"og:title\" content=\"Shared name\"><title>Tab name</title>") isEqualToString:@"Shared name"], @"prefers og:title over the tab title");
    check(TitleFromHTML(@"<html><body>nothing here</body></html>") == nil, @"reports no title rather than inventing one");
    check(TitleFromHTML(@"") == nil, @"survives an empty response body");
    check([DecodedHTMLEntities(@"a &amp; b &#39;c&#39; &#x2014; d") isEqualToString:@"a & b 'c' — d"], @"decodes named, decimal, and hex entities");
    check([FrontTabScriptForBrowser(@"Safari") containsString:@"current tab"], @"asks Safari for its current tab");
    check([FrontTabScriptForBrowser(@"Safari") containsString:@"with timeout of 5 seconds"], @"bounds the tab lookup so a busy browser cannot hang the app");
    check([FrontTabScriptForBrowser(@"Google Chrome") containsString:@"active tab"], @"asks Chrome-family browsers for their active tab");
    NSDictionary *clipRect = LiveClipRectDictionary(NSMakeRect(12, 34, 56, 78));
    check(NSEqualRects(RectFromLiveClipDictionary(clipRect), NSMakeRect(12, 34, 56, 78)), @"persists a Live Clip capture rectangle");
    NSDictionary *liveClipAsset = @{
        @"id": @"clip-1",
        @"title": @"Price table Live Clip",
        @"kind": @"LiveClip",
        @"filePath": @"/tmp/clip.png",
        @"source": @"/tmp/clip.png",
        @"liveClip": @{
            @"mode": @"Extract",
            @"capturedImage": @"/tmp/clip.png",
            @"extractedText": @"Quarterly pricing table",
            @"sourceApplicationName": @"Safari",
            @"captureRect": clipRect,
            @"latestCaptureHash": @"abc"
        }
    };
    check(IsLiveClip(liveClipAsset), @"recognizes the Live Clip asset kind");
    check([LiveClipImagePath(liveClipAsset) isEqualToString:@"/tmp/clip.png"], @"finds the persisted Live Clip image");
    check(AssetMatchesSearch(liveClipAsset, @"quarterly pricing", @{@"name": @"Case Competition"}), @"searches extracted Live Clip text");
    check(AssetMatchesSearch(liveClipAsset, @"safari", @{@"name": @"Case Competition"}), @"searches Live Clip source app");
    check(LiveClipHashesDiffer(@"abc", @"def"), @"detects changed Live Clip hashes");
    check(!LiveClipHashesDiffer(@"abc", @"abc"), @"ignores identical Live Clip hashes");
    NSDictionary *currency = LiveClipStructuredContentFromOCRItems(@[@{@"text": @"$24,839", @"x": @0.1, @"y": @0.8, @"width": @0.2, @"height": @0.1}]);
    check([currency[@"contentType"] isEqualToString:@"number"] && [currency[@"extractedContent"][@"numericValue"] doubleValue] == 24839, @"extracts a currency-like number");
    NSDictionary *percent = LiveClipStructuredContentFromOCRItems(@[@{@"text": @"73%", @"x": @0.1, @"y": @0.8, @"width": @0.2, @"height": @0.1}]);
    check([percent[@"contentType"] isEqualToString:@"number"] && [percent[@"extractedContent"][@"unit"] isEqualToString:@"percentage"] && [percent[@"extractedContent"][@"numericValue"] doubleValue] == 73, @"extracts a percentage number");
    NSDictionary *followers = LiveClipStructuredContentFromOCRItems(@[@{@"text": @"Followers 12.4K", @"x": @0.1, @"y": @0.8, @"width": @0.4, @"height": @0.1}]);
    check([followers[@"contentType"] isEqualToString:@"labeledValue"] && [followers[@"extractedContent"][@"label"] isEqualToString:@"Followers"] && [followers[@"extractedContent"][@"numericValue"] doubleValue] == 12400, @"extracts an inline abbreviated labeled value");
    NSDictionary *applications = LiveClipStructuredContentFromOCRItems(@[@{@"text": @"Applications: 73", @"x": @0.1, @"y": @0.8, @"width": @0.4, @"height": @0.1}]);
    check([applications[@"contentType"] isEqualToString:@"labeledValue"] && [applications[@"extractedContent"][@"label"] isEqualToString:@"Applications"], @"extracts a colon labeled value");
    NSDictionary *urlClip = LiveClipStructuredContentFromOCRItems(@[@{@"text": @"https://example.com/project", @"x": @0.1, @"y": @0.8, @"width": @0.5, @"height": @0.1}]);
    check([urlClip[@"contentType"] isEqualToString:@"url"] && [urlClip[@"extractedContent"][@"url"] containsString:@"example.com"], @"extracts a visible URL");
    NSDictionary *textClip = LiveClipStructuredContentFromOCRItems(@[@{@"text": @"Applications close September 14.", @"x": @0.1, @"y": @0.8, @"width": @0.6, @"height": @0.1}]);
    check([textClip[@"contentType"] isEqualToString:@"text"], @"falls back to plain text for prose");
    NSDictionary *imageClip = LiveClipStructuredContentFromOCRItems(@[]);
    check([imageClip[@"contentType"] isEqualToString:@"image"], @"falls back to image when OCR sees no text");
    NSDictionary *tableClip = LiveClipStructuredContentFromOCRItems(@[
        @{@"text": @"Name", @"x": @0.1, @"y": @0.8, @"width": @0.1, @"height": @0.05},
        @{@"text": @"Sales", @"x": @0.5, @"y": @0.8, @"width": @0.1, @"height": @0.05},
        @{@"text": @"Adam", @"x": @0.1, @"y": @0.65, @"width": @0.1, @"height": @0.05},
        @{@"text": @"23", @"x": @0.5, @"y": @0.65, @"width": @0.1, @"height": @0.05},
        @{@"text": @"Sarah", @"x": @0.1, @"y": @0.5, @"width": @0.1, @"height": @0.05},
        @{@"text": @"41", @"x": @0.5, @"y": @0.5, @"width": @0.1, @"height": @0.05}
    ]);
    check([tableClip[@"contentType"] isEqualToString:@"table"] && [tableClip[@"extractedContent"][@"rows"] count] == 2, @"reconstructs an obvious small table");
    NSDictionary *mockWindow = @{
        (NSString *)kCGWindowLayer: @0,
        (NSString *)kCGWindowOwnerName: @"Safari",
        (NSString *)kCGWindowOwnerPID: @123,
        (NSString *)kCGWindowNumber: @456,
        (NSString *)kCGWindowName: @"Shopify Admin",
        (NSString *)kCGWindowBounds: @{@"X": @100, @"Y": @100, @"Width": @800, @"Height": @600}
    };
    NSDictionary *source = LiveClipSourceFromWindowInfo(NSMakeRect(500, 450, 120, 80), 77, @{@"sourceApplicationName": @"Safari", @"sourceBundleIdentifier": @"com.apple.Safari", @"sourceURL": @"https://admin.shopify.com/orders"}, @[mockWindow], 1000);
    check([source[@"applicationName"] isEqualToString:@"Safari"] && [source[@"windowTitle"] isEqualToString:@"Shopify Admin"], @"resolves the application and window owning a captured region");
    check([source[@"sourceType"] isEqualToString:@"browserPage"] && [source[@"sourceURL"] containsString:@"shopify"], @"stores browser page source separately");
    check([source[@"displayID"] unsignedIntValue] == 77, @"stores the capture display identifier");
    NSDictionary *normalized = source[@"normalizedWindowRect"];
    check(fabs([normalized[@"x"] doubleValue] - 0.5) < 0.001 && fabs([normalized[@"width"] doubleValue] - 0.15) < 0.001, @"stores normalized window-relative coordinates");
    NSDictionary *refreshAsset = @{@"kind": @"LiveClip", @"liveClip": @{@"captureRect": LiveClipRectDictionary(NSMakeRect(500, 450, 120, 80)), @"displayID": @77, @"source": source}};
    NSDictionary *movedWindow = @{
        (NSString *)kCGWindowLayer: @0,
        (NSString *)kCGWindowOwnerName: @"Safari",
        (NSString *)kCGWindowOwnerPID: @123,
        (NSString *)kCGWindowNumber: @456,
        (NSString *)kCGWindowName: @"Shopify Admin",
        (NSString *)kCGWindowBounds: @{@"X": @200, @"Y": @150, @"Width": @1000, @"Height": @700}
    };
    NSDictionary *location = LiveClipResolveCurrentRegion(refreshAsset, @[movedWindow], 1100);
    NSRect relocated = RectFromLiveClipDictionary(location[@"rect"]);
    check([location[@"strategy"] isEqualToString:@"windowRelative"] && fabs(NSMinX(relocated) - 700) < 0.001 && fabs(NSWidth(relocated) - 150) < 0.001, @"relocates refresh regions from normalized window coordinates");
    NSDictionary *oldNumberClip = @{@"contentType": @"number", @"extractedContent": @{@"numericValue": @12400, @"displayValue": @"12.4K"}};
    NSDictionary *newNumberAnalysis = @{@"contentType": @"number", @"extractedContent": @{@"numericValue": @12400, @"displayValue": @"12,400"}, @"extractedText": @"12,400"};
    check(!LiveClipStructuredContentChanged(oldNumberClip, newNumberAnalysis, @"newhash"), @"compares numeric Live Clip content by value");
    NSDictionary *oldTextClip = @{@"contentType": @"text", @"extractedContent": @{@"text": @"Applications close September 14."}, @"extractedText": @"Applications close September 14."};
    NSDictionary *newTextAnalysis = @{@"contentType": @"text", @"extractedContent": @{@"text": @"Applications   close\nSeptember 14."}, @"extractedText": @"Applications close September 14."};
    check(!LiveClipStructuredContentChanged(oldTextClip, newTextAnalysis, @"newhash"), @"ignores harmless text whitespace during refresh comparison");
    NSDictionary *changedTextAnalysis = @{@"contentType": @"text", @"extractedContent": @{@"text": @"Applications close September 18."}, @"extractedText": @"Applications close September 18."};
    check(LiveClipStructuredContentChanged(oldTextClip, changedTextAnalysis, @"newhash"), @"detects meaningful structured content changes during refresh");
    NSDictionary *visibleURLAsset = @{@"kind": @"LiveClip", @"liveClip": @{@"contentType": @"url", @"extractedContent": @{@"url": @"https://example.com/product"}, @"source": source}};
    check(![visibleURLAsset[@"liveClip"][@"extractedContent"][@"url"] isEqualToString:LiveClipSource(visibleURLAsset)[@"sourceURL"]], @"keeps visible URLs separate from source webpage URLs");
    NSDictionary *oldSourceClip = @{@"kind": @"LiveClip", @"liveClip": @{@"sourceApplicationName": @"Notes", @"sourceBundleIdentifier": @"com.apple.Notes"}};
    check([LiveClipSource(oldSourceClip)[@"applicationName"] isEqualToString:@"Notes"], @"reads legacy source metadata when no structured source exists");
    NSDictionary *documentSourceClip = @{@"kind": @"LiveClip", @"liveClip": @{@"source": @{@"sourceType": @"document", @"documentPath": @"/tmp/report.pdf"}}};
    check(LiveClipSourceCanOpen(documentSourceClip) && [LiveClipOpenSourceTitle(documentSourceClip) isEqualToString:@"Open Document"], @"routes document Live Clip sources to document opening");
    NSDictionary *badURLClip = @{@"kind": @"LiveClip", @"liveClip": @{@"source": @{@"sourceType": @"browserPage", @"sourceURL": @"not a url"}}};
    check(!LiveClipSourceCanOpen(badURLClip), @"does not expose Open Source for malformed source URLs");
    NSDictionary *appSourceClip = @{@"kind": @"LiveClip", @"liveClip": @{@"source": @{@"sourceType": @"application", @"applicationName": @"Notes", @"bundleIdentifier": @"com.apple.Notes"}}};
    check(LiveClipSourceCanOpen(appSourceClip) && [LiveClipOpenSourceTitle(appSourceClip) isEqualToString:@"Open Source"], @"routes application Live Clip sources to app activation");

    check(ShouldAnimateVolt(YES, NO), @"lets Volt idle-animate when motion is welcome");
    check(!ShouldAnimateVolt(YES, YES), @"holds Volt still when the system asks to reduce motion");
    check(!ShouldAnimateVolt(NO, NO), @"holds Volt still when animation is switched off");
    NSRect voltRest = NSMakeRect(16, 13, 71, 66);
    check(NSEqualRects(VoltIdleFrame(voltRest, 0, -1, VoltGestureNone), voltRest), @"leaves Volt at his resting frame");
    NSRect midHop = VoltIdleFrame(voltRest, 0, VoltGestureDuration / 2, VoltGestureHop);
    check(NSMinY(midHop) > NSMinY(voltRest) + 6, @"lifts Volt off the ground mid-hop");
    NSRect squashed = VoltIdleFrame(voltRest, 0, VoltGestureDuration / 2, VoltGestureSquash);
    check(NSHeight(squashed) < NSHeight(voltRest), @"squashes Volt when he catches a file");
    check(fabs(NSMidX(squashed) - NSMidX(voltRest)) < 0.001, @"keeps Volt centred while he squashes");
    BOOL idleStaysSubtle = YES;
    for (NSTimeInterval clock = 0; clock < 12; clock += 0.05) {
        NSRect breathing = VoltIdleFrame(voltRest, clock, -1, VoltGestureNone);
        if (fabs(NSMinY(breathing) - NSMinY(voltRest)) > 3.5) idleStaysSubtle = NO;
        if (fabs(NSMidX(breathing) - NSMidX(voltRest)) > 0.001) idleStaysSubtle = NO;
    }
    check(idleStaysSubtle, @"keeps Volt's idle breathing subtle and centred");

    NSArray<NSDictionary *> *selectionAssets = @[@{@"id": @"a"}, @{@"id": @"b"}, @{@"id": @"c"}, @{@"id": @"d"}];
    check([AssetIDsInInclusiveRange(selectionAssets, @"b", @"d") isEqualToArray:@[@"b", @"c", @"d"]], @"selects a forward asset range");
    check([AssetIDsInInclusiveRange(selectionAssets, @"d", @"b") isEqualToArray:@[@"b", @"c", @"d"]], @"selects a reverse asset range");
    check([AssetIDsInInclusiveRange(selectionAssets, @"missing", @"c") isEqualToArray:@[@"c"]], @"falls back to the clicked asset when the range anchor is hidden");

    NSDictionary *searchAsset = @{
        @"title": @"Pricing reference",
        @"kind": @"PDF",
        @"uploader": @"sarah@example.com",
        @"status": @"Approved",
        @"tags": @[@"competitor", @"market"],
        @"filePath": @"/tmp/Q4-market-report.pdf",
        @"source": @"/tmp/Q4-market-report.pdf"
    };
    NSDictionary *searchPack = @{@"name": @"Case Competition", @"summary": @"Retail strategy"};
    check(AssetMatchesSearch(searchAsset, @"approved", searchPack), @"searches asset status");
    check(AssetMatchesSearch(searchAsset, @"competitor", searchPack), @"searches asset tags");
    check(AssetMatchesSearch(searchAsset, @"q4-market", searchPack), @"searches filenames");
    check(AssetMatchesSearch(searchAsset, @"retail strategy", searchPack), @"searches current Pack metadata");
    check(!AssetMatchesSearch(searchAsset, @"unrelated phrase", searchPack), @"rejects unrelated search text");

    NSString *html = @"<a href='https://ca.pinterest.com/pin/12345/'><img src='https://i.pinimg.com/originals/aa/bb/photo.jpg'></a>";
    NSURL *pageURL = LinkURLFromHTML(html);
    NSURL *imageURL = ImageURLFromHTML(html);
    check([pageURL.host isEqualToString:@"ca.pinterest.com"], @"extracts the source page from dragged HTML");
    check([imageURL.host isEqualToString:@"i.pinimg.com"], @"extracts the image from dragged HTML");
    check([PreferredOriginURL(imageURL, pageURL).absoluteString isEqualToString:pageURL.absoluteString], @"prefers a page over a CDN image as origin");

    NSURL *relative = ResolvedURL([NSURL URLWithString:@"/media/photo.jpg"], [NSURL URLWithString:@"https://example.com/work/42"]);
    check([relative.absoluteString isEqualToString:@"https://example.com/media/photo.jpg"], @"resolves relative image URLs");

    NSDictionary *hybridAsset = @{
        @"filePath": @"/tmp/full-size-photo.jpg",
        @"originURL": @"https://www.instagram.com/p/example/",
        @"source": @"/tmp/full-size-photo.jpg",
        @"addedAt": @([[NSDate date] timeIntervalSince1970])
    };
    check([AssetFilePath(hybridAsset) isEqualToString:@"/tmp/full-size-photo.jpg"], @"retains the local file");
    check([AssetOriginURL(hybridAsset).host isEqualToString:@"www.instagram.com"], @"retains the original web page beside the file");
    check(AssetOriginURL(@{@"source": @"https://example.com/reference"}) != nil, @"reads legacy web assets");
    check([AssetFilePath(@{@"source": @"/tmp/legacy.pdf"}) isEqualToString:@"/tmp/legacy.pdf"], @"reads legacy local assets");

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:hybridAsset options:0 error:&jsonError];
    NSDictionary *restored = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:&jsonError] : nil;
    check(jsonError == nil && [AssetFilePath(restored) isEqualToString:AssetFilePath(hybridAsset)], @"persists a hybrid asset safely");
    check([AssetOriginURL(restored).absoluteString isEqualToString:AssetOriginURL(hybridAsset).absoluteString], @"restores the origin URL after restart");
    check(RelativeTimeString(@([[NSDate date] timeIntervalSince1970])).length > 0, @"renders persisted timestamps");

    NSRect assetFrame = NSMakeRect(44, 112, 354, 68);
    NSRect assetBounds = NSMakeRect(0, 0, 354, 68);
    NSRect copyFrame = NSMakeRect(298, 21, 26, 26);
    NSRect openFrame = NSMakeRect(326, 21, 26, 26);
    NSPoint copyPoint = NSMakePoint(NSMinX(assetFrame) + NSMidX(copyFrame), NSMinY(assetFrame) + NSMidY(copyFrame));
    NSPoint openPoint = NSMakePoint(NSMinX(assetFrame) + NSMidX(openFrame), NSMinY(assetFrame) + NSMidY(openFrame));
    check(NSPointInRect(AssetLocalPoint(copyPoint, assetFrame, assetBounds), copyFrame), @"maps Copy clicks into the card correctly");
    check(NSPointInRect(AssetLocalPoint(openPoint, assetFrame, assetBounds), openFrame), @"maps Open clicks into the card correctly");

    id<NSPasteboardWriting> fileWriter = AssetDragWriter(@{
        @"filePath": @"/System/Library/CoreServices/SystemVersion.plist",
        @"originURL": @"https://example.com/source"
    }, NO);
    check([(id)fileWriter isKindOfClass:NSURL.class] && [(NSURL *)fileWriter isFileURL], @"drags local assets as native file attachments");
    id<NSPasteboardWriting> linkWriter = AssetDragWriter(@{@"originURL": @"https://example.com/reference"}, NO);
    check([(id)linkWriter isKindOfClass:NSURL.class] && ![(NSURL *)linkWriter isFileURL], @"drags web-only assets as native links");
    check([NormalizedPackName(@"  Spring   Campaign\n") isEqualToString:@"Spring Campaign"], @"cleans a new Pack name");
    check(PackNameExists(@[@{@"name": @"Case Competition"}], @"case competition"), @"prevents duplicate Pack names");
    check(!PackNameExists(@[@{@"name": @"Case Competition"}], @"Client Project"), @"allows a distinct Pack name");
    NSDictionary *currentPack = @{@"name": @"Case Competition"};
    NSArray *renamePacks = @[currentPack, @{@"name": @"Client Project"}];
    check(!PackNameExistsExcept(renamePacks, @"case competition", currentPack), @"allows capitalization changes when renaming a Pack");
    check(PackNameExistsExcept(renamePacks, @"client project", currentPack), @"blocks renaming a Pack to another Pack's name");

    if (failures) {
        fprintf(stderr, "%lu of %lu self-tests failed\n", (unsigned long)failures, (unsigned long)checks);
        return 1;
    }
    fprintf(stdout, "%lu self-tests passed\n", (unsigned long)checks);
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return RunSelfTests();
        NSSetUncaughtExceptionHandler(&LogUncaughtException);
        NSApplication *app = NSApplication.sharedApplication;
        AppController *controller = [[AppController alloc] init];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
