#import <Cocoa/Cocoa.h>

NSString *AssetFilePath(NSDictionary *asset);
NSURL *AssetOriginURL(NSDictionary *asset);
NSString *AssetPayload(NSDictionary *asset);
BOOL IsLiveClip(NSDictionary *asset);
NSString *LiveClipImagePath(NSDictionary *asset);
BOOL AssetMatchesSearch(NSDictionary *asset, NSString *query, NSDictionary *pack);
NSArray<NSString *> *AssetIDsInInclusiveRange(NSArray<NSDictionary *> *assets, NSString *anchorID, NSString *targetID);
id<NSPasteboardWriting> AssetDragWriter(NSDictionary *asset, BOOL usePreview);
NSString *ExtensionForResponse(NSURLResponse *response, NSURL *url);
NSString *IconForKind(NSString *kind);
NSColor *ColorForKind(NSString *kind);
NSColor *MutedKindColor(NSString *kind);
