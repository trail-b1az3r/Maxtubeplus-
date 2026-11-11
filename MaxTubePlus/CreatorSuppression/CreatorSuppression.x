// Intelligent Creator Suppression.
//
// Learning: menu sheets are decorated through MTPContext. Actions whose title
// is YouTube's channel-level negative feedback ("Don't recommend channel",
// "Show fewer ... from this channel", localized variants) are wrapped so that
// tapping them (YouTube still receives the feedback as usual) also records an
// interaction for that creator. The creator is identified from the cell's
// thumbnail video ID via oEmbed (author name), or from the player (channel ID).
//
// Suppression: element bytes on recommendation surfaces are matched exactly
// (protobuf string field) against suppressed channel IDs / names and hidden.
// Search, channel search, channel pages and Subscriptions are never filtered.

#import "MTPSuppressionStore.h"
#import "MTPSuppressedCreatorsViewController.h"
#import "../Common/MTPContext.h"
#import "../Common/MTPVideoInfo.h"

extern void MTPContextBumpFilterGeneration(void);

static NSArray<NSString *> *NegativeFeedbackPhrases(void) {
    return @[
        @"don't recommend channel", @"don’t recommend channel", @"do not recommend channel",
        @"from this channel", @"show fewer", // "Show fewer Shorts/videos from this channel"
        @"no recomendar el canal", @"kanal nicht empfehlen", @"ne pas recommander la chaîne",
        @"não recomendar canal", @"non consigliare il canale", @"не рекомендовать видео с этого канала",
        @"nie polecaj kanału", @"このチャンネルをおすすめに表示しない", @"不推荐此频道",
    ];
}

static BOOL IsChannelNegativeFeedback(NSString *title) {
    NSString *lower = title.lowercaseString;
    // "Show fewer" alone (without a channel) is video-level feedback on some
    // surfaces; only count it when the action is channel-scoped.
    if ([lower containsString:@"show fewer"] && ![lower containsString:@"channel"]) return NO;
    for (NSString *phrase in NegativeFeedbackPhrases()) if ([lower containsString:phrase]) return YES;
    return NO;
}

static void ResolveCreator(MTPItemContext *context, void (^completion)(NSString *channelID, NSString *name)) {
    // oEmbed's author_name is the channel's display name exactly as YouTube
    // renders it, which is what element matching needs.
    if (context.videoID) {
        [[MTPVideoInfoProvider shared] infoForVideoID:context.videoID completion:^(MTPVideoInfo *info) {
            completion(context.channelID, info.authorName ?: context.channelName);
        }];
        return;
    }
    completion(context.channelID, context.channelName);
}

void MTPInstallCreatorSuppression(void) {
    MTPCompat *compat = [MTPCompat shared];
    if (![compat mayInstallModule:MTPModuleSuppression]) {
        [compat setStatus:@"Disabled: unverified YouTube version" forModule:MTPModuleSuppression];
        return;
    }
    MTPSuppressionStore *store = [MTPSuppressionStore shared];

    [MTPContext addElementFilter:^BOOL(NSData *bytes, MTPSurface surface) {
        if (!mtp_surface_allows_suppression(surface)) return NO;
        return [store bytesReferenceSuppressedCreator:bytes];
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:MTPSuppressionChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        MTPContextBumpFilterGeneration();
    }];

    [MTPContext addSheetDecorator:^(id sheet, MTPItemContext *context) {
        NSArray *actions = [sheet respondsToSelector:@selector(actions)] ? [sheet performSelector:@selector(actions)] : nil;
        BOOL wrapped = NO;
        for (id action in actions) {
            NSString *title = [MTPContext titleOfSheetAction:action];
            if (!title || !IsChannelNegativeFeedback(title)) continue;
            [MTPContext wrapHandlerOfSheetAction:action before:^{
                ResolveCreator(context, ^(NSString *channelID, NSString *name) {
                    if (!channelID.length && !name.length) {
                        MTPLog(@"suppression: could not identify creator for %@", context);
                        return;
                    }
                    MTPCreator *suppressed = [store recordNegativeFeedbackForChannelID:channelID name:name];
                    if (suppressed) MTPToast([NSString stringWithFormat:@"MaxTubePlus: %@ suppressed from recommendations", suppressed.displayName]);
                });
            }];
            wrapped = YES;
        }
        // Explicit, user-initiated suppression for the item.
        if ((context.videoID || context.channelID || context.channelName) && [sheet respondsToSelector:@selector(addAction:)]) {
            id action = [MTPContext makeSheetActionWithTitle:@"Suppress creator (MaxTubePlus)" iconType:0 handler:^{
                ResolveCreator(context, ^(NSString *channelID, NSString *name) {
                    if (!channelID.length && !name.length) { MTPToast(@"MaxTubePlus: couldn't identify this creator"); return; }
                    [store suppressManuallyWithChannelID:channelID name:name];
                    MTPToast([NSString stringWithFormat:@"MaxTubePlus: %@ suppressed. Restore in Settings > MaxTubePlus.", name ?: channelID]);
                });
            }];
            if (action) [sheet performSelector:@selector(addAction:) withObject:action];
        }
        if (wrapped && [MTPPrefs boolForKey:MTPKeyDebugLogging]) MTPLog(@"suppression: wrapped negative feedback for %@", context);
    }];

    [compat setStatus:[NSString stringWithFormat:@"Active: %lu suppressed, %lu tracked", (unsigned long)store.suppressedCreators.count, (unsigned long)store.trackedCreators.count] forModule:MTPModuleSuppression];
}
