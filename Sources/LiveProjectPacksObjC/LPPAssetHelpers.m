#import "LPPAssetHelpers.h"
#import "LPPWebParsing.h"

NSString *AssetFilePath(NSDictionary *asset) {
    id explicitPath = asset[@"filePath"];
    if ([explicitPath isKindOfClass:NSString.class] && [explicitPath length]) return explicitPath;
    id sourceValue = asset[@"source"];
    if (![sourceValue isKindOfClass:NSString.class]) return nil;
    NSString *source = sourceValue;
    if ([source hasPrefix:@"/"]) return source;
    if ([source hasPrefix:@"file://"]) return [NSURL URLWithString:source].path;
    return nil;
}

NSURL *AssetOriginURL(NSDictionary *asset) {
    id explicitURL = asset[@"originURL"];
    if ([explicitURL isKindOfClass:NSString.class] && [explicitURL length]) {
        NSURL *url = WebURLFromText(explicitURL);
        if (url) return url;
    }
    id sourceValue = asset[@"source"];
    return [sourceValue isKindOfClass:NSString.class] ? WebURLFromText(sourceValue) : nil;
}

NSString *AssetPayload(NSDictionary *asset) {
    id payload = asset[@"payload"];
    if ([payload isKindOfClass:NSString.class] && [payload length]) return payload;
    id sourceValue = asset[@"source"];
    if (![sourceValue isKindOfClass:NSString.class]) return nil;
    NSString *source = sourceValue;
    if (AssetFilePath(asset) || AssetOriginURL(asset)) return nil;
    return source;
}

BOOL IsLiveClip(NSDictionary *asset) {
    return [asset[@"kind"] isEqualToString:@"LiveClip"];
}

NSString *LiveClipImagePath(NSDictionary *asset) {
    id clip = asset[@"liveClip"];
    if (![clip isKindOfClass:NSDictionary.class]) return AssetFilePath(asset);
    id path = [(NSDictionary *)clip objectForKey:@"capturedImage"];
    return [path isKindOfClass:NSString.class] && [path length] ? path : AssetFilePath(asset);
}

static BOOL SearchValueContains(id value, NSString *query) {
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value localizedCaseInsensitiveContainsString:query];
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            if (SearchValueContains(item, query)) return YES;
        }
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id item in [(NSDictionary *)value allValues]) {
            if (SearchValueContains(item, query)) return YES;
        }
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return [[(NSNumber *)value stringValue] localizedCaseInsensitiveContainsString:query];
    }
    return NO;
}

BOOL AssetMatchesSearch(NSDictionary *asset, NSString *query, NSDictionary *pack) {
    NSString *needle = Trimmed(query ?: @"");
    if (!needle.length) return YES;
    NSString *filePath = AssetFilePath(asset);
    NSURL *originURL = AssetOriginURL(asset);
    NSArray *values = @[
        asset[@"title"] ?: @"",
        asset[@"kind"] ?: @"",
        asset[@"uploader"] ?: @"",
        asset[@"status"] ?: @"",
        asset[@"source"] ?: @"",
        asset[@"tags"] ?: @[],
        filePath ?: @"",
        filePath.lastPathComponent ?: @"",
        originURL.absoluteString ?: @"",
        AssetPayload(asset) ?: @"",
        asset[@"liveClip"][@"extractedText"] ?: @"",
        asset[@"liveClip"][@"contentType"] ?: @"",
        asset[@"liveClip"][@"extractedContent"] ?: @{},
        asset[@"liveClip"][@"sourceApplicationName"] ?: @"",
        asset[@"liveClip"][@"mode"] ?: @"",
        pack[@"name"] ?: @"",
        pack[@"summary"] ?: @""
    ];
    for (id value in values) {
        if (SearchValueContains(value, needle)) return YES;
    }
    return NO;
}

NSArray<NSString *> *AssetIDsInInclusiveRange(NSArray<NSDictionary *> *assets, NSString *anchorID, NSString *targetID) {
    if (!targetID.length) return @[];
    NSUInteger anchorIndex = NSNotFound;
    NSUInteger targetIndex = NSNotFound;
    for (NSUInteger index = 0; index < assets.count; index++) {
        NSString *assetID = assets[index][@"id"];
        if ([assetID isEqualToString:anchorID]) anchorIndex = index;
        if ([assetID isEqualToString:targetID]) targetIndex = index;
    }
    if (anchorIndex == NSNotFound || targetIndex == NSNotFound) return @[targetID];
    NSRange range = NSMakeRange(MIN(anchorIndex, targetIndex), MAX(anchorIndex, targetIndex) - MIN(anchorIndex, targetIndex) + 1);
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:range.length];
    for (NSDictionary *asset in [assets subarrayWithRange:range]) {
        NSString *assetID = asset[@"id"];
        if (assetID.length) [identifiers addObject:assetID];
    }
    return identifiers;
}

id<NSPasteboardWriting> AssetDragWriter(NSDictionary *asset, BOOL usePreview) {
    if (IsLiveClip(asset)) {
        NSString *path = LiveClipImagePath(asset);
        if (path.length && [NSFileManager.defaultManager fileExistsAtPath:path]) return [NSURL fileURLWithPath:path];
    }
    NSString *filePath = AssetFilePath(asset);
    if (filePath.length && [NSFileManager.defaultManager fileExistsAtPath:filePath]) {
        return [NSURL fileURLWithPath:filePath];
    }

    NSString *previewPath = usePreview ? asset[@"preview"] : nil;
    if (previewPath.length && [NSFileManager.defaultManager fileExistsAtPath:previewPath]) {
        return [NSURL fileURLWithPath:previewPath];
    }

    NSURL *originURL = AssetOriginURL(asset);
    if (originURL) return originURL;
    NSString *text = AssetPayload(asset) ?: asset[@"title"];
    return text.length ? text : nil;
}

NSString *ExtensionForResponse(NSURLResponse *response, NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    if (ext.length) return ext;
    NSString *mime = response.MIMEType.lowercaseString ?: @"";
    if ([mime containsString:@"png"]) return @"png";
    if ([mime containsString:@"avif"]) return @"avif";
    if ([mime containsString:@"webp"]) return @"webp";
    if ([mime containsString:@"gif"]) return @"gif";
    if ([mime containsString:@"heic"]) return @"heic";
    if ([mime containsString:@"jpeg"] || [mime containsString:@"jpg"]) return @"jpg";
    return @"jpg";
}

NSString *IconForKind(NSString *kind) {
    NSDictionary *map = @{@"Image": @"photo", @"Video": @"play.rectangle", @"PDF": @"doc.richtext", @"Link": @"link", @"Document": @"doc.text", @"Note": @"note.text", @"Font": @"textformat", @"LiveClip": @"viewfinder.rectangular", @"File": @"doc"};
    return map[kind] ?: @"doc";
}

NSColor *ColorForKind(NSString *kind) {
    NSDictionary *map = @{@"Image": NSColor.systemGreenColor, @"Video": NSColor.systemPinkColor, @"PDF": NSColor.systemRedColor, @"Link": NSColor.systemBlueColor, @"Document": NSColor.systemOrangeColor, @"Note": NSColor.systemYellowColor, @"Font": NSColor.systemPurpleColor, @"LiveClip": NSColor.systemTealColor, @"File": NSColor.systemGrayColor};
    return map[kind] ?: NSColor.systemGrayColor;
}

NSColor *MutedKindColor(NSString *kind) {
    NSColor *base = [ColorForKind(kind) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!base) return [NSColor colorWithCalibratedWhite:0.60 alpha:1];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [base getRed:&r green:&g blue:&b alpha:&a];
    const CGFloat grey = 0.58;
    const CGFloat hueKept = 0.30;
    return [NSColor colorWithCalibratedRed:grey + (r - grey) * hueKept
                                     green:grey + (g - grey) * hueKept
                                      blue:grey + (b - grey) * hueKept
                                     alpha:1];
}
