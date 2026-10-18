#import "LPPPackExport.h"
#import "LPPAssetHelpers.h"

static NSString *HTMLEscape(NSString *text) {
    NSString *result = [text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    result = [result stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    result = [result stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return [result stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}

NSString *ExportSafeFileName(NSString *name) {
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *banned = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        [clean appendString:(c < 32 || [banned characterIsMember:c]) ? @"-" : [NSString stringWithCharacters:&c length:1]];
    }
    NSString *trimmed = [clean stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .\n\t"]];
    if (trimmed.length > 80) trimmed = [trimmed substringToIndex:80];
    return trimmed.length ? trimmed : @"Untitled";
}

NSString *ExportUniqueName(NSString *name, NSMutableSet<NSString *> *used) {
    NSString *stem = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    NSString *candidate = name;
    for (NSUInteger n = 2; [used containsObject:candidate.lowercaseString]; n++) {
        candidate = ext.length ? [NSString stringWithFormat:@"%@ %lu.%@", stem, (unsigned long)n, ext] : [NSString stringWithFormat:@"%@ %lu", stem, (unsigned long)n];
    }
    [used addObject:candidate.lowercaseString];
    return candidate;
}

// entries: title, kind, and any of file (relative path), image (YES to show inline),
// url (http/https only), text.
NSString *PackExportIndexHTML(NSString *title, NSArray<NSDictionary *> *entries) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterLongStyle;
    NSMutableString *cards = [NSMutableString string];
    for (NSDictionary *entry in entries) {
        [cards appendString:@"<article class=\"card\">"];
        NSString *file = entry[@"file"];
        NSString *href = file.length ? [file stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] : nil;
        if (href && [entry[@"image"] boolValue]) [cards appendFormat:@"<a href=\"%@\"><img src=\"%@\" alt=\"\" loading=\"lazy\"></a>", href, href];
        [cards appendFormat:@"<div class=\"body\"><span class=\"kind\">%@</span><h2>%@</h2>", HTMLEscape(entry[@"kind"] ?: @"File"), HTMLEscape(entry[@"title"] ?: @"Untitled")];
        NSString *url = entry[@"url"];
        if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) [cards appendFormat:@"<a class=\"open\" href=\"%@\">%@</a>", HTMLEscape(url), HTMLEscape(url)];
        else if (href) [cards appendFormat:@"<a class=\"open\" href=\"%@\">Open %@</a>", href, HTMLEscape(file.lastPathComponent)];
        if ([entry[@"text"] length]) [cards appendFormat:@"<pre>%@</pre>", HTMLEscape(entry[@"text"])];
        [cards appendString:@"</div></article>\n"];
    }
    return [NSString stringWithFormat:
        @"<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>%@</title>\n"
        "<style>:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--ink:#16181d;--mute:#6b7280;--line:#e3e6eb;--accent:#3b6fd8}"
        "@media(prefers-color-scheme:dark){:root{--bg:#14161a;--card:#1d2026;--ink:#eceef2;--mute:#9aa1ad;--line:#2b2f37;--accent:#8fb0f5}}"
        "body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif}"
        "main{max-width:880px;margin:0 auto;padding:40px 20px 64px}h1{margin:0;font-size:28px}header p{margin:4px 0 28px;color:var(--mute)}"
        ".grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fill,minmax(260px,1fr))}"
        ".card{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:flex;flex-direction:column}"
        ".card img{width:100%%;height:220px;object-fit:contain;background:var(--bg);display:block;border-bottom:1px solid var(--line)}"
        ".body{padding:14px 16px 16px;min-width:0}.kind{font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--mute)}"
        "h2{margin:2px 0 8px;font-size:16px;overflow-wrap:anywhere}.open{color:var(--accent);text-decoration:none;overflow-wrap:anywhere;font-size:14px}.open:hover{text-decoration:underline}"
        "pre{margin:8px 0 0;white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink)}</style></head>\n"
        "<body><main><header><h1>%@</h1><p>%lu item%@ · %@</p></header><section class=\"grid\">\n%@</section></main></body></html>\n",
        HTMLEscape(title), HTMLEscape(title), (unsigned long)entries.count, entries.count == 1 ? @"" : @"s", [formatter stringFromDate:NSDate.date], cards];
}

static NSString *ExportFileName(NSString *title, NSString *extension, NSMutableSet<NSString *> *used) {
    NSString *base = ExportSafeFileName(title);
    if (extension.length && ![base.pathExtension.lowercaseString isEqualToString:extension.lowercaseString]) base = [base stringByAppendingPathExtension:extension];
    return ExportUniqueName(base, used);
}

BOOL BuildPackExportZip(NSString *title, NSArray<NSDictionary *> *assets, NSURL *destination, NSUInteger *itemCount, NSUInteger *skipped, NSString **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *folderName = ExportSafeFileName(title);
    NSURL *scratch = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"lpp-export-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSURL *folder = [scratch URLByAppendingPathComponent:folderName isDirectory:YES];
    NSURL *filesDir = [folder URLByAppendingPathComponent:@"files" isDirectory:YES];
    NSURL *notesDir = [folder URLByAppendingPathComponent:@"notes" isDirectory:YES];
    [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *usedFiles = [NSMutableSet set], *usedNotes = [NSMutableSet set];
    NSSet *imageTypes = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"gif", @"webp", nil];
    NSUInteger missing = 0;
    for (NSDictionary *asset in assets) {
        NSString *assetTitle = asset[@"title"] ?: @"Untitled";
        NSMutableDictionary *entry = [@{@"title": assetTitle, @"kind": asset[@"kind"] ?: @"File"} mutableCopy];
        NSString *path = AssetFilePath(asset) ?: LiveClipImagePath(asset);
        NSString *text = IsLiveClip(asset) ? asset[@"liveClip"][@"extractedText"] : AssetPayload(asset);
        if ([text isKindOfClass:NSString.class] && text.length) entry[@"text"] = text;
        if (path.length) {
            if (![fm fileExistsAtPath:path]) {
                missing++;
                continue;
            }
            [fm createDirectoryAtURL:filesDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *name = ExportFileName(assetTitle, path.pathExtension, usedFiles);
            if (![fm copyItemAtPath:path toPath:[filesDir.path stringByAppendingPathComponent:name] error:nil]) {
                missing++;
                continue;
            }
            entry[@"file"] = [@"files" stringByAppendingPathComponent:name];
            entry[@"image"] = @([imageTypes containsObject:path.pathExtension.lowercaseString]);
        } else if (AssetOriginURL(asset)) {
            entry[@"url"] = AssetOriginURL(asset).absoluteString;
        } else if (entry[@"text"]) {
            [fm createDirectoryAtURL:notesDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *name = ExportFileName(assetTitle, @"txt", usedNotes);
            [text writeToFile:[notesDir.path stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            entry[@"file"] = [@"notes" stringByAppendingPathComponent:name];
        } else {
            continue;
        }
        [entries addObject:entry];
    }
    if (itemCount) *itemCount = entries.count;
    if (skipped) *skipped = missing;

    BOOL ok = NO;
    if (!entries.count) {
        if (error) *error = missing ? @"The files in this Pack are no longer on disk." : @"There is nothing in this Pack to export.";
    } else {
        [PackExportIndexHTML(title, entries) writeToURL:[folder URLByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm removeItemAtURL:destination error:nil];   // zip would otherwise add to an existing archive
        NSTask *zip = [[NSTask alloc] init];
        zip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/zip"];
        zip.arguments = @[@"-r", @"-X", @"-q", destination.path, folderName];
        zip.currentDirectoryURL = scratch;
        zip.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        zip.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *launchError = nil;
        if ([zip launchAndReturnError:&launchError]) {
            [zip waitUntilExit];
            ok = zip.terminationStatus == 0;
        }
        if (!ok && error) *error = @"Could not create the ZIP file.";
    }
    [fm removeItemAtURL:scratch error:nil];
    return ok;
}
