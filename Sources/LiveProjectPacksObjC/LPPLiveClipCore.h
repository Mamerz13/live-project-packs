#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

NSDictionary *LiveClipRectDictionary(NSRect rect);
NSRect RectFromLiveClipDictionary(NSDictionary *dictionary);
NSDictionary *LiveClipNormalizedRectDictionary(NSRect rect, NSRect container);
NSRect AppKitWindowFrameFromCGBounds(NSDictionary *bounds, CGFloat globalMaxY);
NSDictionary *LiveClipSourceFromWindowInfo(NSRect captureRect, CGDirectDisplayID displayID, NSDictionary *fallback, NSArray<NSDictionary *> *windows, CGFloat globalMaxY);
NSString *SHA256ForData(NSData *data);
NSString *ImageHashAtPath(NSString *path);
BOOL LiveClipHashesDiffer(NSString *first, NSString *second);
NSString *CopyableTextForLiveClip(NSDictionary *asset);
NSDictionary *LiveClipSource(NSDictionary *asset);
BOOL LiveClipSourceCanOpen(NSDictionary *asset);
NSString *LiveClipOpenSourceTitle(NSDictionary *asset);
NSString *LiveClipContentSignature(NSString *type, NSDictionary *content, NSString *text, NSString *imageHash);
BOOL LiveClipStructuredContentChanged(NSDictionary *oldClip, NSDictionary *newAnalysis, NSString *newImageHash);
NSRect RectFromNormalizedRect(NSDictionary *normalized, NSRect container);
NSDictionary *LiveClipResolveCurrentRegion(NSDictionary *asset, NSArray<NSDictionary *> *windows, CGFloat globalMaxY);
NSArray<NSDictionary *> *SortedOCRItems(NSArray<NSDictionary *> *items);
NSString *OCRTextFromItems(NSArray<NSDictionary *> *items);
NSDictionary *ParsedNumberToken(NSString *input);
NSDictionary *LiveClipStructuredContentFromOCRItems(NSArray<NSDictionary *> *items);
