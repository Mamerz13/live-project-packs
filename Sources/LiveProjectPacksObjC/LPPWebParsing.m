#import "LPPWebParsing.h"

NSString *KindForURL(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"tiff", @"heic", @"bmp", @"svg", @"avif"] containsObject:ext]) return @"Image";
    if ([@[@"mov", @"mp4", @"m4v", @"avi", @"webm", @"mkv"] containsObject:ext]) return @"Video";
    if ([ext isEqualToString:@"pdf"]) return @"PDF";
    if ([@[@"doc", @"docx", @"pages", @"txt", @"md", @"rtf"] containsObject:ext]) return @"Document";
    if ([@[@"ttf", @"otf", @"woff", @"woff2"] containsObject:ext]) return @"Font";
    if ([@[@"mp3", @"wav", @"m4a", @"aac", @"flac", @"ogg", @"aiff"] containsObject:ext]) return @"Audio";
    if ([@[@"zip", @"rar", @"7z", @"tar", @"gz", @"dmg"] containsObject:ext]) return @"Archive";
    if ([@[@"xls", @"xlsx", @"csv", @"numbers", @"tsv"] containsObject:ext]) return @"Spreadsheet";
    if ([@[@"ppt", @"pptx", @"key"] containsObject:ext]) return @"Presentation";
    if ([@[@"psd", @"ai", @"sketch", @"fig", @"afdesign"] containsObject:ext]) return @"Design";
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDir] && isDir) return @"Folder";
    return @"File";
}

NSString *TitleForWebURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"Link";
    if ([host containsString:@"pinterest."]) return @"Pinterest Pin";
    if ([host containsString:@"pin.it"]) return @"Pinterest Pin";
    if ([host containsString:@"instagram."]) return @"Instagram Post";
    if ([host containsString:@"instagr.am"]) return @"Instagram Post";
    return url.host ?: url.absoluteString;
}

NSString *Trimmed(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *CleanURLString(NSString *value) {
    NSString *clean = Trimmed(value ?: @"");
    while ([clean hasSuffix:@"."] || [clean hasSuffix:@","] || [clean hasSuffix:@")"] || [clean hasSuffix:@"]"]) {
        clean = [clean substringToIndex:clean.length - 1];
    }
    return clean;
}

BOOL IsDirectImageURL(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"tiff", @"heic", @"bmp", @"svg", @"avif"] containsObject:ext];
}

BOOL IsLikelySocialImageURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if (IsDirectImageURL(url)) return YES;
    if ([host containsString:@"cdninstagram."]) return YES;
    if ([host containsString:@"fbcdn."]) return YES;
    if ([host containsString:@"pinimg."]) return YES;
    return NO;
}

NSString *FirstMatch(NSString *text, NSString *pattern) {
    if (!text.length) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [text substringWithRange:[match rangeAtIndex:1]];
}

NSArray<NSString *> *AllMatches(NSString *text, NSString *pattern) {
    if (!text.length) return @[];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSMutableArray *values = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 2) continue;
        [values addObject:[text substringWithRange:[match rangeAtIndex:1]]];
    }
    return values;
}

NSString *DecodedWebText(NSString *text) {
    NSString *decoded = text ?: @"";
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\u002F" withString:@"/"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\u0026" withString:@"&"];
    return decoded;
}

NSString *CollapsedWhitespace(NSString *value) {
    NSArray<NSString *> *parts = [Trimmed(value ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) [words addObject:part];
    }
    return [words componentsJoinedByString:@" "];
}

NSString *DecodedHTMLEntities(NSString *text) {
    if (!text.length) return text;
    NSMutableString *decoded = [text mutableCopy];
    NSDictionary<NSString *, NSString *> *named = @{
        @"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"",
        @"&apos;": @"'", @"&nbsp;": @" ", @"&mdash;": @"—", @"&ndash;": @"–",
        @"&hellip;": @"…", @"&rsquo;": @"’", @"&lsquo;": @"‘",
        @"&ldquo;": @"“", @"&rdquo;": @"”"
    };
    for (NSString *entity in named) {
        [decoded replaceOccurrencesOfString:entity withString:named[entity] options:NSCaseInsensitiveSearch range:NSMakeRange(0, decoded.length)];
    }
    NSRegularExpression *numeric = [NSRegularExpression regularExpressionWithPattern:@"&#(x?)([0-9a-f]+);" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray<NSTextCheckingResult *> *matches = [numeric matchesInString:decoded options:0 range:NSMakeRange(0, decoded.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        unsigned int code = 0;
        NSString *digits = [decoded substringWithRange:[match rangeAtIndex:2]];
        if ([decoded substringWithRange:[match rangeAtIndex:1]].length) {
            [[NSScanner scannerWithString:digits] scanHexInt:&code];
        } else {
            code = (unsigned int)digits.intValue;
        }
        if (!code) continue;
        NSString *character = [[NSString alloc] initWithBytes:&code length:sizeof(code) encoding:NSUTF32LittleEndianStringEncoding];
        if (character.length) [decoded replaceCharactersInRange:match.range withString:character];
    }
    return decoded;
}

NSString *TitleFromHTML(NSString *html) {
    if (!html.length) return nil;
    NSString *raw = FirstMatch(html, @"<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']*)[\"']");
    if (!raw.length) raw = FirstMatch(html, @"<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']og:title[\"']");
    if (!raw.length) raw = FirstMatch(html, @"<title[^>]*>([\\s\\S]{1,400}?)</title>");
    if (!raw.length) return nil;

    NSString *title = CollapsedWhitespace(DecodedHTMLEntities(raw));
    if (!title.length) return nil;
    if (title.length <= 90) return title;
    NSRange safeRange = [title rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 90)];
    return [Trimmed([title substringWithRange:safeRange]) stringByAppendingString:@"…"];
}

NSURL *WebURLFromText(NSString *text) {
    NSString *decoded = DecodedWebText(text);
    if (!decoded.length) return nil;

    NSString *singleValue = CleanURLString(decoded);
    NSURL *directURL = [NSURL URLWithString:singleValue];
    NSString *directScheme = directURL.scheme.lowercaseString;
    if (([directScheme isEqualToString:@"http"] || [directScheme isEqualToString:@"https"]) && directURL.host.length) return directURL;

    static NSDataDetector *detector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    });
    if (!detector) return nil;
    NSArray<NSTextCheckingResult *> *matches = [detector matchesInString:decoded options:0 range:NSMakeRange(0, decoded.length)];
    for (NSTextCheckingResult *match in matches) {
        NSURL *url = match.URL;
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) return url;
    }
    return nil;
}
