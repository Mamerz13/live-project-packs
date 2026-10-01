#import <Cocoa/Cocoa.h>

NSString *KindForURL(NSURL *url);
NSString *TitleForWebURL(NSURL *url);
NSString *Trimmed(NSString *value);
NSString *CleanURLString(NSString *value);
BOOL IsDirectImageURL(NSURL *url);
BOOL IsLikelySocialImageURL(NSURL *url);
NSString *FirstMatch(NSString *text, NSString *pattern);
NSArray<NSString *> *AllMatches(NSString *text, NSString *pattern);
NSString *DecodedWebText(NSString *text);
NSString *CollapsedWhitespace(NSString *value);
NSString *DecodedHTMLEntities(NSString *text);
NSString *TitleFromHTML(NSString *html);
NSURL *WebURLFromText(NSString *text);
