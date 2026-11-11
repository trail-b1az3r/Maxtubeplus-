// Native DeArrow integration (no WebView).
//
// Flow
//  1. Every element YouTube renders passes through MTPContext's element hook.
//     Video IDs are taken from the i.ytimg.com thumbnail paths in the bytes.
//  2. For each ID, DeArrow branding is fetched (cached on disk, TTL based).
//  3. Titles: when DeArrow has a title, the original title is obtained from
//     YouTube oEmbed and an original->replacement mapping is registered.
//     Text nodes (Texture ASTextNode, used by YouTube's element renderer) and
//     UILabels showing exactly the original title are rewritten; nodes that
//     rendered before the lookup finished are updated in place.
//  4. Thumbnails: ASNetworkImageNode URLs pointing at /vi/<id>/ are replaced
//     with DeArrow's thumbnail service when a trusted submission exists.
//  No submission -> nothing changes (original title/thumbnail stay).

#import <objc/runtime.h>
#import <objc/message.h>
#import "MTPDeArrowClient.h"
#import "../Common/MTPContext.h"
#import "../Common/MTPVideoInfo.h"
#import "../Common/MTPYouTube.h"

@interface ASNetworkImageNode : NSObject
@property (nonatomic, copy) NSURL *URL;
@end

static NSMutableDictionary<NSString *, NSString *> *gTitleMap;           // original -> DeArrow
static NSMapTable<NSString *, NSHashTable *> *gTextNodes;                // original text -> nodes
static NSMapTable<NSString *, NSHashTable *> *gImageNodes;               // video ID -> image nodes
static NSMutableSet<NSString *> *gRequested;
static const void *kOriginalURLKey = &kOriginalURLKey;
static BOOL gReplacing = NO;

static BOOL TitlesOn(void) { return [MTPPrefs boolForKey:MTPKeyDeArrowTitles]; }
static BOOL ThumbsOn(void) { return [MTPPrefs boolForKey:MTPKeyDeArrowThumbnails]; }

static NSAttributedString *Replace(NSAttributedString *text, NSString *replacement) {
    if (text.length == 0) return [[NSAttributedString alloc] initWithString:replacement];
    NSDictionary *attributes = [text attributesAtIndex:0 effectiveRange:NULL];
    return [[NSAttributedString alloc] initWithString:replacement attributes:attributes];
}

static void RegisterNode(NSMapTable *table, NSString *key, id node) {
    @synchronized (table) {
        NSHashTable *nodes = [table objectForKey:key];
        if (!nodes) {
            if (table.count > 5000) [table removeAllObjects];
            nodes = [NSHashTable weakObjectsHashTable];
            [table setObject:nodes forKey:key];
        }
        [nodes addObject:node];
    }
}

static NSArray *NodesFor(NSMapTable *table, NSString *key) {
    @synchronized (table) { return [[table objectForKey:key] allObjects] ?: @[]; }
}

static void ApplyTitleMapping(NSString *original, NSString *replacement) {
    @synchronized (gTitleMap) {
        if (gTitleMap.count > 5000) [gTitleMap removeAllObjects];
        gTitleMap[original] = replacement;
    }
    for (id node in NodesFor(gTextNodes, original)) {
        NSAttributedString *current = [node valueForKey:@"attributedText"];
        if ([current.string isEqualToString:original]) [node setValue:Replace(current, replacement) forKey:@"attributedText"];
    }
}

static NSURL *ThumbnailOverride(NSURL *url, NSString **videoIDOut) {
    if (!url || ![url.host hasSuffix:@"ytimg.com"]) return nil;
    NSString *videoID = nil;
    NSArray *parts = url.path.pathComponents; // "/", "vi", "<id>", "hqdefault.jpg"
    if (parts.count >= 3 && ([parts[1] isEqualToString:@"vi"] || [parts[1] isEqualToString:@"vi_webp"])) videoID = parts[2];
    if (!mtp_is_video_id(videoID.UTF8String)) return nil;
    if (videoIDOut) *videoIDOut = videoID;
    MTPDeArrowBranding *branding = [[MTPDeArrowClient shared] cachedBrandingForVideoID:videoID];
    return branding.thumbnailURL;
}

static void RefreshImages(NSString *videoID, MTPDeArrowBranding *branding) {
    NSURL *replacement = branding.thumbnailURL;
    if (!replacement || !ThumbsOn()) return;
    for (ASNetworkImageNode *node in NodesFor(gImageNodes, videoID)) {
        if (![node.URL isEqual:replacement]) node.URL = replacement; // goes through the hook (no-op)
    }
}

static void Lookup(NSString *videoID) {
    @synchronized (gRequested) {
        if ([gRequested containsObject:videoID]) return;
        if (gRequested.count > 20000) [gRequested removeAllObjects];
        [gRequested addObject:videoID];
    }
    [[MTPDeArrowClient shared] brandingForVideoID:videoID completion:^(MTPDeArrowBranding *branding) {
        if (!branding) return;
        RefreshImages(videoID, branding);
        if (branding.title && TitlesOn()) {
            [[MTPVideoInfoProvider shared] infoForVideoID:videoID completion:^(MTPVideoInfo *info) {
                if (info.title.length && ![info.title isEqualToString:branding.title]) ApplyTitleMapping(info.title, branding.title);
            }];
        }
    }];
}

static void OnElementVideoID(const char *videoID, void *context) {
    Lookup(@(videoID));
}

%group DeArrowText
%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    if (!gReplacing && TitlesOn() && text.length >= 4 && text.length <= 300) {
        NSString *string = text.string;
        NSString *replacement;
        @synchronized (gTitleMap) { replacement = gTitleMap[string]; }
        RegisterNode(gTextNodes, string, self);
        if (replacement) {
            gReplacing = YES;
            %orig(Replace(text, replacement));
            gReplacing = NO;
            return;
        }
    }
    %orig;
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    if (TitlesOn() && text.length >= 4 && text.length <= 300) {
        NSString *replacement;
        @synchronized (gTitleMap) { replacement = gTitleMap[text]; }
        if (replacement) { %orig(replacement); return; }
    }
    %orig;
}
%end
%end

%group DeArrowImages
%hook ASNetworkImageNode
- (void)setURL:(NSURL *)url {
    if (ThumbsOn()) {
        NSString *videoID = nil;
        NSURL *replacement = ThumbnailOverride(url, &videoID);
        if (videoID) {
            RegisterNode(gImageNodes, videoID, self);
            objc_setAssociatedObject(self, kOriginalURLKey, url, OBJC_ASSOCIATION_COPY_NONATOMIC);
            if (!replacement) Lookup(videoID);
        }
        if (replacement) { %orig(replacement); return; }
    }
    %orig;
}
%end
%end

NSString *MTPDeArrowStatus(void) {
    MTPDeArrowClient *client = [MTPDeArrowClient shared];
    NSUInteger mapped;
    @synchronized (gTitleMap) { mapped = gTitleMap.count; }
    return [NSString stringWithFormat:@"%lu API requests this session, %lu videos with submissions, %lu titles mapped",
            (unsigned long)client.requestCount, (unsigned long)client.replacementCount, (unsigned long)mapped];
}

void MTPInstallDeArrow(void) {
    MTPCompat *compat = [MTPCompat shared];
    if (![compat mayInstallModule:MTPModuleDeArrow]) {
        [compat setStatus:@"Disabled: unverified YouTube version" forModule:MTPModuleDeArrow];
        return;
    }
    gTitleMap = [NSMutableDictionary dictionary];
    gTextNodes = [NSMapTable strongToStrongObjectsMapTable];
    gImageNodes = [NSMapTable strongToStrongObjectsMapTable];
    gRequested = [NSMutableSet set];
    NSMutableArray *notes = [NSMutableArray array];

    [MTPContext addElementObserver:^(NSData *bytes, MTPSurface surface) {
        if (!TitlesOn() && !ThumbsOn()) return;
        mtp_scan_thumbnail_video_ids(bytes.bytes, bytes.length, OnElementVideoID, NULL);
    }];

    if (MTPClassWithSelectors(@"ASTextNode", @[@"setAttributedText:"])) {
        %init(DeArrowText);
        [notes addObject:@"titles: ASTextNode/UILabel hooked"];
    } else {
        [notes addObject:@"titles: ASTextNode missing"];
    }
    if (MTPClassWithSelectors(@"ASNetworkImageNode", @[@"setURL:"])) {
        %init(DeArrowImages);
        [notes addObject:@"thumbnails: ASNetworkImageNode hooked"];
    } else {
        [notes addObject:@"thumbnails: ASNetworkImageNode missing"];
    }
    // The player's own video also gets looked up so the watch page title is covered.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSString *video = [MTPContext currentVideoID];
        if (video) Lookup(video);
    }];
    [compat setStatus:[notes componentsJoinedByString:@"; "] forModule:MTPModuleDeArrow];
}
