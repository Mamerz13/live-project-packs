#import <Cocoa/Cocoa.h>

NSString *ExportSafeFileName(NSString *name);
NSString *ExportUniqueName(NSString *name, NSMutableSet<NSString *> *used);
NSString *PackExportIndexHTML(NSString *title, NSArray<NSDictionary *> *entries);
// Writes `assets` into a ZIP at `destination` that opens anywhere: real files, notes as
// .txt, and an index.html that lists everything. Returns NO with `error` set on failure.
// `skipped` counts assets whose file has gone missing. Blocks, so call it off the main thread.
BOOL BuildPackExportZip(NSString *title, NSArray<NSDictionary *> *assets, NSURL *destination, NSUInteger *itemCount, NSUInteger *skipped, NSString **error);
