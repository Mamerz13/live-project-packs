#import "LPPLiveClipCore.h"
#import "LPPAssetHelpers.h"
#import "LPPWebParsing.h"
#import <CommonCrypto/CommonDigest.h>

NSDictionary *LiveClipRectDictionary(NSRect rect) {
    return @{@"x": @(NSMinX(rect)), @"y": @(NSMinY(rect)), @"width": @(NSWidth(rect)), @"height": @(NSHeight(rect))};
}

NSRect RectFromLiveClipDictionary(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return NSZeroRect;
    return NSMakeRect([dictionary[@"x"] doubleValue], [dictionary[@"y"] doubleValue], [dictionary[@"width"] doubleValue], [dictionary[@"height"] doubleValue]);
}

NSDictionary *LiveClipNormalizedRectDictionary(NSRect rect, NSRect container) {
    if (NSWidth(container) <= 0 || NSHeight(container) <= 0) return @{};
    return @{
        @"x": @((NSMinX(rect) - NSMinX(container)) / NSWidth(container)),
        @"y": @((NSMinY(rect) - NSMinY(container)) / NSHeight(container)),
        @"width": @(NSWidth(rect) / NSWidth(container)),
        @"height": @(NSHeight(rect) / NSHeight(container))
    };
}

static CGFloat RectIntersectionArea(NSRect first, NSRect second) {
    NSRect intersection = NSIntersectionRect(first, second);
    if (NSIsEmptyRect(intersection)) return 0;
    return NSWidth(intersection) * NSHeight(intersection);
}

static BOOL RectContainsCenter(NSRect container, NSRect rect) {
    return NSPointInRect(NSMakePoint(NSMidX(rect), NSMidY(rect)), container);
}

NSRect AppKitWindowFrameFromCGBounds(NSDictionary *bounds, CGFloat globalMaxY) {
    CGFloat x = [bounds[@"X"] doubleValue];
    CGFloat y = [bounds[@"Y"] doubleValue];
    CGFloat width = [bounds[@"Width"] doubleValue];
    CGFloat height = [bounds[@"Height"] doubleValue];
    return NSMakeRect(x, globalMaxY - y - height, width, height);
}

static NSString *BrowserNameForBundleIdentifier(NSString *bundleIdentifier) {
    NSDictionary *names = @{
        @"com.apple.Safari": @"Safari",
        @"com.google.Chrome": @"Google Chrome",
        @"company.thebrowser.Browser": @"Arc",
        @"com.brave.Browser": @"Brave Browser",
        @"com.microsoft.edgemac": @"Microsoft Edge",
        @"com.vivaldi.Vivaldi": @"Vivaldi"
    };
    return names[bundleIdentifier ?: @""];
}

NSDictionary *LiveClipSourceFromWindowInfo(NSRect captureRect, CGDirectDisplayID displayID, NSDictionary *fallback, NSArray<NSDictionary *> *windows, CGFloat globalMaxY) {
    NSDictionary *bestWindow = nil;
    NSRect bestFrame = NSZeroRect;
    CGFloat bestArea = 0;
    for (NSDictionary *window in windows ?: @[]) {
        if ([window[(NSString *)kCGWindowLayer] integerValue] != 0) continue;
        NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
        if (![bounds isKindOfClass:NSDictionary.class]) continue;
        NSRect frame = AppKitWindowFrameFromCGBounds(bounds, globalMaxY);
        CGFloat area = RectIntersectionArea(captureRect, frame);
        if (area <= 0) continue;
        BOOL centerHit = RectContainsCenter(frame, captureRect);
        if (centerHit) area += NSWidth(captureRect) * NSHeight(captureRect);
        if (area > bestArea) {
            bestArea = area;
            bestWindow = window;
            bestFrame = frame;
        }
    }

    NSMutableDictionary *source = [NSMutableDictionary dictionary];
    source[@"schemaVersion"] = @1;
    source[@"displayID"] = @(displayID);
    source[@"screenCaptureRect"] = LiveClipRectDictionary(captureRect);
    source[@"capturedAt"] = @([[NSDate date] timeIntervalSince1970]);
    NSString *fallbackApp = fallback[@"sourceApplicationName"];
    NSString *fallbackBundle = fallback[@"sourceBundleIdentifier"];
    NSString *fallbackURL = fallback[@"sourceURL"];
    NSString *appName = bestWindow[(NSString *)kCGWindowOwnerName] ?: fallbackApp;
    NSString *windowTitle = bestWindow[(NSString *)kCGWindowName] ?: fallback[@"sourceWindowTitle"];
    NSNumber *pid = bestWindow[(NSString *)kCGWindowOwnerPID] ?: fallback[@"processIdentifier"];
    NSNumber *windowID = bestWindow[(NSString *)kCGWindowNumber];
    NSString *bundleID = fallbackBundle;
    if (pid) {
        for (NSRunningApplication *running in NSWorkspace.sharedWorkspace.runningApplications) {
            if (running.processIdentifier != pid.integerValue) continue;
            if (running.bundleIdentifier.length) bundleID = running.bundleIdentifier;
            if (running.localizedName.length) appName = running.localizedName;
            break;
        }
    }

    if (appName.length) source[@"applicationName"] = appName;
    if (bundleID.length) source[@"bundleIdentifier"] = bundleID;
    if (pid) source[@"processIdentifier"] = pid;
    if (windowTitle.length) source[@"windowTitle"] = windowTitle;
    if (windowID) source[@"windowIdentifier"] = windowID;
    if (!NSIsEmptyRect(bestFrame)) {
        source[@"windowBounds"] = LiveClipRectDictionary(bestFrame);
        NSRect relative = NSMakeRect(NSMinX(captureRect) - NSMinX(bestFrame), NSMinY(captureRect) - NSMinY(bestFrame), NSWidth(captureRect), NSHeight(captureRect));
        source[@"windowRelativeRect"] = LiveClipRectDictionary(relative);
        source[@"normalizedWindowRect"] = LiveClipNormalizedRectDictionary(captureRect, bestFrame);
    }

    NSString *browserName = BrowserNameForBundleIdentifier(bundleID);
    if (browserName.length) source[@"browserName"] = browserName;
    if (fallbackURL.length) source[@"sourceURL"] = fallbackURL;
    NSString *sourceType = @"unknown";
    if (fallbackURL.length && browserName.length) sourceType = @"browserPage";
    else if ([bundleID isEqualToString:@"com.apple.finder"]) sourceType = @"finder";
    else if ([source[@"documentPath"] length]) sourceType = @"document";
    else if (appName.length || bundleID.length) sourceType = @"application";
    source[@"sourceType"] = sourceType;

    CGFloat captureArea = MAX(1, NSWidth(captureRect) * NSHeight(captureRect));
    CGFloat overlapRatio = bestArea / captureArea;
    source[@"confidence"] = overlapRatio > 0.8 ? @"high" : (overlapRatio > 0.35 ? @"medium" : @"low");
    return source;
}

NSString *SHA256ForData(NSData *data) {
    if (!data.length) return @"";
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [value appendFormat:@"%02x", hash[i]];
    return value;
}

NSString *ImageHashAtPath(NSString *path) {
    NSData *data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    return SHA256ForData(data);
}

BOOL LiveClipHashesDiffer(NSString *first, NSString *second) {
    return first.length && second.length && ![first isEqualToString:second];
}

NSString *CopyableTextForLiveClip(NSDictionary *asset) {
    NSDictionary *clip = asset[@"liveClip"];
    NSDictionary *content = [clip[@"extractedContent"] isKindOfClass:NSDictionary.class] ? clip[@"extractedContent"] : @{};
    NSString *type = clip[@"contentType"];
    if ([type isEqualToString:@"text"]) return content[@"text"];
    if ([type isEqualToString:@"url"]) return content[@"url"];
    if ([type isEqualToString:@"number"] || [type isEqualToString:@"labeledValue"]) {
        id value = content[@"numericValue"] ?: content[@"displayValue"];
        return [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : value;
    }
    if ([type isEqualToString:@"table"]) {
        NSMutableArray *lines = [NSMutableArray array];
        NSArray *columns = content[@"columns"];
        if ([columns isKindOfClass:NSArray.class]) [lines addObject:[columns componentsJoinedByString:@"\t"]];
        for (NSArray *row in content[@"rows"] ?: @[]) {
            if ([row isKindOfClass:NSArray.class]) [lines addObject:[row componentsJoinedByString:@"\t"]];
        }
        return [lines componentsJoinedByString:@"\n"];
    }
    return clip[@"extractedText"];
}

NSDictionary *LiveClipSource(NSDictionary *asset) {
    NSDictionary *clip = asset[@"liveClip"];
    NSDictionary *source = [clip[@"source"] isKindOfClass:NSDictionary.class] ? clip[@"source"] : nil;
    if (source) return source;
    NSMutableDictionary *legacy = [NSMutableDictionary dictionary];
    if ([clip[@"sourceApplicationName"] isKindOfClass:NSString.class]) legacy[@"applicationName"] = clip[@"sourceApplicationName"];
    if ([clip[@"sourceBundleIdentifier"] isKindOfClass:NSString.class]) legacy[@"bundleIdentifier"] = clip[@"sourceBundleIdentifier"];
    if ([clip[@"sourceWindowTitle"] isKindOfClass:NSString.class]) legacy[@"windowTitle"] = clip[@"sourceWindowTitle"];
    if ([clip[@"sourceURL"] isKindOfClass:NSString.class]) legacy[@"sourceURL"] = clip[@"sourceURL"];
    if (legacy.count) legacy[@"sourceType"] = legacy[@"sourceURL"] ? @"browserPage" : @"application";
    return legacy.count ? legacy : @{};
}

BOOL LiveClipSourceCanOpen(NSDictionary *asset) {
    NSDictionary *source = LiveClipSource(asset);
    if ([source[@"sourceURL"] isKindOfClass:NSString.class] && WebURLFromText(source[@"sourceURL"])) return YES;
    if ([source[@"documentPath"] isKindOfClass:NSString.class] && [source[@"documentPath"] length]) return YES;
    if ([source[@"finderPath"] isKindOfClass:NSString.class] && [source[@"finderPath"] length]) return YES;
    if ([source[@"bundleIdentifier"] isKindOfClass:NSString.class] && [source[@"bundleIdentifier"] length]) return YES;
    if ([source[@"applicationName"] isKindOfClass:NSString.class] && [source[@"applicationName"] length]) return YES;
    return NO;
}

NSString *LiveClipOpenSourceTitle(NSDictionary *asset) {
    NSDictionary *source = LiveClipSource(asset);
    NSString *type = source[@"sourceType"];
    if ([type isEqualToString:@"browserPage"] && [source[@"sourceURL"] length]) return @"Open Webpage";
    if ([type isEqualToString:@"document"]) return @"Open Document";
    if ([type isEqualToString:@"finder"]) return @"Reveal in Finder";
    return @"Open Source";
}

static NSString *NormalizedComparableText(NSString *text) {
    return [CollapsedWhitespace(text ?: @"").lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *NormalizedURLString(NSString *text) {
    NSURL *url = WebURLFromText(text);
    if (!url) return NormalizedComparableText(text);
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;
    NSString *value = components.URL.absoluteString ?: url.absoluteString;
    if ([value hasSuffix:@"/"]) value = [value substringToIndex:value.length - 1];
    return value;
}

NSString *LiveClipContentSignature(NSString *type, NSDictionary *content, NSString *text, NSString *imageHash) {
    type = type ?: @"image";
    content = [content isKindOfClass:NSDictionary.class] ? content : @{};
    if ([type isEqualToString:@"number"]) {
        NSNumber *number = [content[@"numericValue"] isKindOfClass:NSNumber.class] ? content[@"numericValue"] : nil;
        if (number) return [NSString stringWithFormat:@"number:%.6f:%@", number.doubleValue, content[@"unit"] ?: @""];
        return [NSString stringWithFormat:@"number:%@", NormalizedComparableText(content[@"displayValue"] ?: text)];
    }
    if ([type isEqualToString:@"labeledValue"]) {
        NSString *label = NormalizedComparableText(content[@"label"]);
        NSNumber *number = [content[@"numericValue"] isKindOfClass:NSNumber.class] ? content[@"numericValue"] : nil;
        NSString *value = number ? [NSString stringWithFormat:@"%.6f", number.doubleValue] : NormalizedComparableText(content[@"displayValue"] ?: text);
        return [NSString stringWithFormat:@"labeled:%@:%@:%@", label, value, content[@"unit"] ?: @""];
    }
    if ([type isEqualToString:@"url"]) return [NSString stringWithFormat:@"url:%@", NormalizedURLString(content[@"url"] ?: text)];
    if ([type isEqualToString:@"table"]) {
        NSMutableArray *cells = [NSMutableArray array];
        for (id column in content[@"columns"] ?: @[]) [cells addObject:NormalizedComparableText([column description])];
        for (NSArray *row in content[@"rows"] ?: @[]) {
            if (![row isKindOfClass:NSArray.class]) continue;
            for (id cell in row) [cells addObject:NormalizedComparableText([cell description])];
        }
        return [NSString stringWithFormat:@"table:%@", [cells componentsJoinedByString:@"|"]];
    }
    if ([type isEqualToString:@"text"]) return [NSString stringWithFormat:@"text:%@", NormalizedComparableText(content[@"text"] ?: text)];
    return [NSString stringWithFormat:@"image:%@", imageHash ?: @""];
}

BOOL LiveClipStructuredContentChanged(NSDictionary *oldClip, NSDictionary *newAnalysis, NSString *newImageHash) {
    NSString *oldSignature = LiveClipContentSignature(oldClip[@"contentType"], oldClip[@"extractedContent"], oldClip[@"extractedText"], oldClip[@"latestCaptureHash"]);
    NSString *newSignature = LiveClipContentSignature(newAnalysis[@"contentType"], newAnalysis[@"extractedContent"], newAnalysis[@"extractedText"], newImageHash);
    return oldSignature.length && newSignature.length && ![oldSignature isEqualToString:newSignature];
}

NSRect RectFromNormalizedRect(NSDictionary *normalized, NSRect container) {
    if (![normalized isKindOfClass:NSDictionary.class] || NSWidth(container) <= 0 || NSHeight(container) <= 0) return NSZeroRect;
    return NSMakeRect(NSMinX(container) + [normalized[@"x"] doubleValue] * NSWidth(container),
                      NSMinY(container) + [normalized[@"y"] doubleValue] * NSHeight(container),
                      [normalized[@"width"] doubleValue] * NSWidth(container),
                      [normalized[@"height"] doubleValue] * NSHeight(container));
}

NSDictionary *LiveClipResolveCurrentRegion(NSDictionary *asset, NSArray<NSDictionary *> *windows, CGFloat globalMaxY) {
    NSDictionary *clip = asset[@"liveClip"];
    NSDictionary *source = LiveClipSource(asset);
    NSDictionary *normalized = source[@"normalizedWindowRect"];
    NSNumber *sourceWindowID = source[@"windowIdentifier"];
    NSNumber *sourcePID = source[@"processIdentifier"];
    NSString *bundleID = source[@"bundleIdentifier"];
    NSString *appName = source[@"applicationName"];
    NSString *windowTitle = source[@"windowTitle"];
    NSDictionary *bestWindow = nil;
    NSRect bestFrame = NSZeroRect;
    NSInteger bestScore = NSIntegerMin;
    for (NSDictionary *window in windows ?: @[]) {
        if ([window[(NSString *)kCGWindowLayer] integerValue] != 0) continue;
        NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
        if (![bounds isKindOfClass:NSDictionary.class]) continue;
        NSString *owner = window[(NSString *)kCGWindowOwnerName];
        NSString *title = window[(NSString *)kCGWindowName];
        NSNumber *pid = window[(NSString *)kCGWindowOwnerPID];
        NSNumber *windowID = window[(NSString *)kCGWindowNumber];
        NSInteger score = 0;
        if (sourceWindowID && [windowID isEqualToNumber:sourceWindowID]) score += 100;
        if (sourcePID && [pid isEqualToNumber:sourcePID]) score += 35;
        if (appName.length && [owner isEqualToString:appName]) score += 25;
        if (bundleID.length && sourcePID && [pid isEqualToNumber:sourcePID]) score += 10;
        if (windowTitle.length && title.length) {
            if ([title isEqualToString:windowTitle]) score += 35;
            else if ([title localizedCaseInsensitiveContainsString:windowTitle] || [windowTitle localizedCaseInsensitiveContainsString:title]) score += 18;
        }
        if (score > bestScore) {
            bestScore = score;
            bestWindow = window;
            bestFrame = AppKitWindowFrameFromCGBounds(bounds, globalMaxY);
        }
    }
    if (bestWindow && bestScore >= 35 && [normalized isKindOfClass:NSDictionary.class]) {
        NSRect rect = RectFromNormalizedRect(normalized, bestFrame);
        if (!NSIsEmptyRect(rect) && NSContainsRect(bestFrame, rect)) {
            NSNumber *displayID = [source[@"displayID"] isKindOfClass:NSNumber.class] ? source[@"displayID"] : clip[@"displayID"];
            return @{@"rect": LiveClipRectDictionary(rect), @"displayID": displayID ?: @(CGMainDisplayID()), @"confidence": bestScore >= 70 ? @"high" : @"medium", @"strategy": @"windowRelative"};
        }
        return @{@"failure": @"The saved region is outside the current source window."};
    }
    NSDictionary *absolute = [clip[@"captureRect"] isKindOfClass:NSDictionary.class] ? clip[@"captureRect"] : source[@"screenCaptureRect"];
    NSNumber *fallbackDisplayID = [clip[@"displayID"] isKindOfClass:NSNumber.class] ? clip[@"displayID"] : source[@"displayID"];
    if ([absolute isKindOfClass:NSDictionary.class] && [fallbackDisplayID isKindOfClass:NSNumber.class]) {
        return @{@"rect": absolute, @"displayID": fallbackDisplayID, @"confidence": @"low", @"strategy": @"absoluteFallback"};
    }
    if ([source[@"sourceURL"] length]) return @{@"failure": @"Packs opened the source page. Try Refresh again once it is visible."};
    return @{@"failure": @"Packs can't locate the original source."};
}

NSArray<NSDictionary *> *SortedOCRItems(NSArray<NSDictionary *> *items) {
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        CGFloat fy = [first[@"y"] doubleValue];
        CGFloat sy = [second[@"y"] doubleValue];
        if (fabs(fy - sy) > 0.035) return fy > sy ? NSOrderedAscending : NSOrderedDescending;
        CGFloat fx = [first[@"x"] doubleValue];
        CGFloat sx = [second[@"x"] doubleValue];
        if (fx == sx) return NSOrderedSame;
        return fx < sx ? NSOrderedAscending : NSOrderedDescending;
    }];
}

NSString *OCRTextFromItems(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *item in SortedOCRItems(items)) {
        NSString *text = item[@"text"];
        if (text.length) [lines addObject:text];
    }
    return [lines componentsJoinedByString:@"\n"];
}

NSDictionary *ParsedNumberToken(NSString *input) {
    NSString *value = Trimmed(input ?: @"");
    if (!value.length) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?i)([$€£])?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?|[0-9]+(?:\\.[0-9]+)?)(\\s*[KMB])?\\s*(%)?" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (!match) return nil;
    NSString *display = [value substringWithRange:match.range];
    NSString *symbol = [match rangeAtIndex:1].location == NSNotFound ? @"" : [value substringWithRange:[match rangeAtIndex:1]];
    NSString *digits = [value substringWithRange:[match rangeAtIndex:2]];
    NSString *suffix = [match rangeAtIndex:3].location == NSNotFound ? @"" : Trimmed([value substringWithRange:[match rangeAtIndex:3]]).uppercaseString;
    BOOL percent = [match rangeAtIndex:4].location != NSNotFound;
    double numeric = [[digits stringByReplacingOccurrencesOfString:@"," withString:@""] doubleValue];
    if ([suffix isEqualToString:@"K"]) numeric *= 1000;
    else if ([suffix isEqualToString:@"M"]) numeric *= 1000000;
    else if ([suffix isEqualToString:@"B"]) numeric *= 1000000000;
    NSString *unit = percent ? @"percentage" : (symbol.length ? @"currency" : @"number");
    NSMutableDictionary *parsed = [@{@"displayValue": display, @"numericValue": @(numeric), @"unit": unit} mutableCopy];
    if ([symbol isEqualToString:@"$"]) parsed[@"currency"] = @"unknown";
    return parsed;
}

static BOOL LooksLikeLabel(NSString *text) {
    NSString *trimmed = Trimmed(text ?: @"");
    if (!trimmed.length || trimmed.length > 48) return NO;
    if (ParsedNumberToken(trimmed)) return NO;
    return [trimmed rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound;
}

NSDictionary *LiveClipStructuredContentFromOCRItems(NSArray<NSDictionary *> *items) {
    NSString *text = OCRTextFromItems(items);
    if (!items.count || !text.length) return @{@"contentType": @"image", @"extractedContent": @{}, @"confidence": @0.2};

    NSURL *visibleURL = WebURLFromText(text);
    if (visibleURL) return @{@"contentType": @"url", @"extractedContent": @{@"url": visibleURL.absoluteString, @"text": text}, @"confidence": @0.94};

    NSArray<NSDictionary *> *sorted = SortedOCRItems(items);
    NSMutableArray<NSDictionary *> *numberItems = [NSMutableArray array];
    for (NSDictionary *item in sorted) {
        NSDictionary *number = ParsedNumberToken(item[@"text"]);
        if (number) {
            NSMutableDictionary *combined = [item mutableCopy];
            combined[@"number"] = number;
            [numberItems addObject:combined];
        }
    }

    if (numberItems.count == 1) {
        NSDictionary *numberItem = numberItems.firstObject;
        NSDictionary *number = numberItem[@"number"];
        NSString *numberText = numberItem[@"text"] ?: @"";
        NSString *label = nil;
        NSRange numberRange = [numberText rangeOfString:number[@"displayValue"] ?: @"" options:NSCaseInsensitiveSearch];
        NSRange colon = [numberText rangeOfString:@":"];
        if (colon.location != NSNotFound && colon.location > 0) {
            NSString *candidate = Trimmed([numberText substringToIndex:colon.location]);
            if (LooksLikeLabel(candidate)) label = candidate;
        }
        if (!label && numberRange.location != NSNotFound && numberRange.location > 0) {
            NSString *candidate = Trimmed([numberText substringToIndex:numberRange.location]);
            if ([candidate hasSuffix:@":"]) candidate = Trimmed([candidate substringToIndex:candidate.length - 1]);
            NSUInteger wordCount = [candidate componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].count;
            NSString *unit = number[@"unit"];
            BOOL hasValueStyle = ![unit isEqualToString:@"number"] || [number[@"displayValue"] rangeOfString:@"K" options:NSCaseInsensitiveSearch].location != NSNotFound || [number[@"displayValue"] rangeOfString:@"M" options:NSCaseInsensitiveSearch].location != NSNotFound;
            BOOL compactInlineLabel = wordCount <= 2 && ![candidate containsString:@"."] && hasValueStyle;
            if (compactInlineLabel && LooksLikeLabel(candidate)) label = candidate;
        }
        if (!label) {
            CGFloat nx = [numberItem[@"x"] doubleValue];
            CGFloat ny = [numberItem[@"y"] doubleValue];
            for (NSDictionary *item in sorted) {
                NSString *candidate = item[@"text"];
                if ([item isEqual:numberItem] || !LooksLikeLabel(candidate)) continue;
                CGFloat dx = fabs([item[@"x"] doubleValue] - nx);
                CGFloat dy = fabs([item[@"y"] doubleValue] - ny);
                BOOL closeAbove = [item[@"y"] doubleValue] > ny && dy < 0.18 && dx < 0.35;
                BOOL closeLeft = dx < 0.42 && dy < 0.07;
                if (closeAbove || closeLeft) {
                    label = Trimmed(candidate);
                    break;
                }
            }
        }
        if (label.length) {
            NSMutableDictionary *content = [@{@"label": label} mutableCopy];
            [content addEntriesFromDictionary:number];
            return @{@"contentType": @"labeledValue", @"extractedContent": content, @"confidence": @0.88};
        }
        NSString *displayValue = number[@"displayValue"] ?: @"";
        if (sorted.count <= 2 && [Trimmed(numberText) isEqualToString:displayValue]) return @{@"contentType": @"number", @"extractedContent": number, @"confidence": @0.86};
    }

    if (sorted.count >= 4) {
        NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary *> *> *rows = [NSMutableDictionary dictionary];
        for (NSDictionary *item in sorted) {
            NSInteger bucket = lround([item[@"y"] doubleValue] * 20);
            NSNumber *key = @(bucket);
            if (!rows[key]) rows[key] = [NSMutableArray array];
            [rows[key] addObject:item];
        }
        NSArray<NSNumber *> *keys = [[rows allKeys] sortedArrayUsingSelector:@selector(compare:)];
        if (keys.count >= 2) {
            NSMutableArray<NSArray<NSDictionary *> *> *rowItems = [NSMutableArray array];
            for (NSNumber *key in keys.reverseObjectEnumerator) {
                NSArray *row = [rows[key] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [a[@"x"] doubleValue] < [b[@"x"] doubleValue] ? NSOrderedAscending : NSOrderedDescending;
                }];
                if (row.count >= 2) [rowItems addObject:row];
            }
            NSUInteger columnCount = rowItems.firstObject.count;
            if (columnCount >= 2) {
                BOOL consistent = YES;
                for (NSArray *row in rowItems) if (labs((long)row.count - (long)columnCount) > 1) consistent = NO;
                if (consistent && rowItems.count >= 2) {
                    NSMutableArray *columns = [NSMutableArray array];
                    for (NSDictionary *item in rowItems.firstObject) [columns addObject:item[@"text"] ?: @""];
                    NSMutableArray *tableRows = [NSMutableArray array];
                    for (NSUInteger i = 1; i < rowItems.count; i++) {
                        NSMutableArray *cells = [NSMutableArray array];
                        for (NSDictionary *item in rowItems[i]) [cells addObject:item[@"text"] ?: @""];
                        [tableRows addObject:cells];
                    }
                    if (tableRows.count) return @{@"contentType": @"table", @"extractedContent": @{@"columns": columns, @"rows": tableRows, @"text": text}, @"confidence": @0.78};
                }
            }
        }
    }

    return @{@"contentType": @"text", @"extractedContent": @{@"text": text}, @"confidence": @0.72};
}
