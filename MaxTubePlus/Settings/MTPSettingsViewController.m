#import "MTPSettingsViewController.h"
#import "../Common/MTPCommon.h"
#import "../Downloads/MTPDownloadsViewController.h"
#import "../DeArrow/MTPDeArrowClient.h"
#import "../CreatorSuppression/MTPSuppressedCreatorsViewController.h"
#import "../AdvancedSearch/MTPSearchFilterViewController.h"
#import "../AdvancedSearch/MTPCommentedVideosViewController.h"
#import "../ModernUI/MTPTabLayout.h"
#import <SafariServices/SafariServices.h>

extern NSString *MTPRefreshRateStatus(void);
extern NSString *MTPDeArrowStatus(void);
extern NSString *MTPAdvancedSearchStatus(void);

typedef NS_ENUM(NSInteger, MTPRowKind) { MTPRowSwitch, MTPRowChoice, MTPRowAction, MTPRowInfo };

@interface MTPRow : NSObject
@property (nonatomic) MTPRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, copy) NSString *(^detail)(void);
@property (nonatomic, copy) void (^action)(UIViewController *from);
@property (nonatomic) BOOL destructive;
@end
@implementation MTPRow
@end

@interface MTPSection : NSObject
@property (nonatomic, copy) NSString *header, *footer;
@property (nonatomic, copy) NSArray<MTPRow *> *rows;
@end
@implementation MTPSection
@end

static MTPRow *Switch(NSString *title, NSString *key) { MTPRow *r = [MTPRow new]; r.kind = MTPRowSwitch; r.title = title; r.key = key; return r; }
static MTPRow *Choice(NSString *title, NSString *key, NSArray *values, NSArray *labels) { MTPRow *r = [MTPRow new]; r.kind = MTPRowChoice; r.title = title; r.key = key; r.values = values; r.labels = labels; return r; }
static MTPRow *Action(NSString *title, void (^action)(UIViewController *)) { MTPRow *r = [MTPRow new]; r.kind = MTPRowAction; r.title = title; r.action = action; return r; }
static MTPRow *Info(NSString *title, NSString *(^detail)(void)) { MTPRow *r = [MTPRow new]; r.kind = MTPRowInfo; r.title = title; r.detail = detail; return r; }
static MTPSection *Section(NSString *header, NSString *footer, NSArray *rows) { MTPSection *s = [MTPSection new]; s.header = header; s.footer = footer; s.rows = rows; return s; }

static void OpenURL(UIViewController *from, NSString *url) {
    [from presentViewController:[[SFSafariViewController alloc] initWithURL:[NSURL URLWithString:url]] animated:YES completion:nil];
}

static NSString *JoinTabs(NSArray<NSString *> *tabs) {
    if (tabs.count == 0) return @"—";
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *t in tabs) [names addObject:[MTPTabLayout displayNameForIdentifier:t]];
    return [names componentsJoinedByString:@", "];
}

@implementation MTPSettingsViewController {
    MTPSettingsGroup _group;
    NSArray<MTPSection *> *_sections;
}

+ (NSString *)titleForGroup:(MTPSettingsGroup)group {
    return @[@"Background Downloads", @"DeArrow", @"120Hz Playback", @"Creator Suppression", @"Advanced Search",
             @"Modern UI Compatibility", @"General Settings", @"About MaxTubePlus"][group];
}

+ (NSString *)symbolForGroup:(MTPSettingsGroup)group {
    return @[@"arrow.down.circle", @"textformat", @"speedometer", @"person.crop.circle.badge.minus", @"line.3.horizontal.decrease.circle",
             @"dock.rectangle", @"gearshape", @"info.circle"][group];
}

- (instancetype)initWithGroup:(MTPSettingsGroup)group {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _group = group;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [MTPSettingsViewController titleForGroup:_group];
    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
}

- (void)rebuild {
    _sections = [self buildSections];
    [self.tableView reloadData];
}

- (NSArray<MTPSection *> *)buildSections {
    MTPCompat *compat = [MTPCompat shared];
    switch (_group) {
        case MTPSettingsGroupDownloads:
            return @[
                Section(nil, @"Runs alongside YTPlus's own downloader (unchanged). Uses an iOS background transfer session, so downloads continue while YouTube is in the background or closed, and interrupted downloads resume at next launch.", @[
                    Switch(@"Background downloads", MTPKeyDownloadsEnabled),
                    Choice(@"Video quality", MTPKeyDownloadsQuality, @[@0, @2160, @1440, @1080, @720, @480, @360], @[@"Best available", @"2160p", @"1440p", @"1080p", @"720p", @"480p", @"360p"]),
                    Switch(@"Audio only (M4A)", MTPKeyDownloadsAudioOnly),
                    Switch(@"Allow cellular data", MTPKeyDownloadsCellular),
                    Switch(@"Notifications", MTPKeyDownloadsNotifications),
                    Choice(@"Simultaneous downloads", MTPKeyDownloadsMaxConcurrent, @[@1, @2, @3, @4], @[@"1", @"2", @"3", @"4"]),
                    Choice(@"Automatic retries", MTPKeyDownloadsMaxRetries, @[@0, @3, @5, @10], @[@"Off", @"3", @"5", @"10"]),
                ]),
                Section(@"Queue & storage", @"H.264/AAC MP4 streams are used because iOS can merge them natively; quality above the highest H.264 stream YouTube offers (usually 1080p) falls back to the best H.264 stream.", @[
                    Action(@"Downloads & storage", ^(UIViewController *from) { [from.navigationController pushViewController:[MTPDownloadsViewController new] animated:YES]; }),
                    Info(@"Status", ^{ return [compat statusForModule:MTPModuleDownloads]; }),
                ]),
            ];
        case MTPSettingsGroupDeArrow:
            return @[
                Section(nil, @"Replaces clickbait titles and thumbnails with community submissions. When a video has no trusted submission, YouTube's original is kept.", @[
                    Switch(@"Replace titles", MTPKeyDeArrowTitles),
                    Switch(@"Replace thumbnails", MTPKeyDeArrowThumbnails),
                    Action(@"Clear DeArrow cache", ^(UIViewController *from) { [[MTPDeArrowClient shared] clearCache]; MTPToast(@"DeArrow cache cleared"); }),
                    Info(@"Status", ^{ return [NSString stringWithFormat:@"%@\n%@", [compat statusForModule:MTPModuleDeArrow], MTPDeArrowStatus()]; }),
                ]),
                Section(@"Attribution", @"Titles and thumbnails: DeArrow by Ajay Ramachandran and contributors (dearrow.ajay.app). Database licensed CC BY-NC-SA 4.0. Not affiliated with MaxTubePlus.", @[
                    Action(@"Open dearrow.ajay.app", ^(UIViewController *from) { OpenURL(from, @"https://dearrow.ajay.app"); }),
                ]),
            ];
        case MTPSettingsGroupRefreshRate:
            return @[
                Section(nil, @"Lifts 60Hz caps on interface animation (scrolling, scrubbing, player controls) on ProMotion displays. Video frames are never interpolated: 24/30/60fps videos play at their real frame rate. Requires the CADisableMinimumFrameDurationOnPhone Info.plist key, which the MaxTubePlus build adds.", @[
                    Switch(@"120Hz interface", MTPKeyHighRefreshEnabled),
                    Info(@"Display", ^{ return compat.proMotionDisplay ? [NSString stringWithFormat:@"ProMotion, up to %ldHz", (long)[UIScreen mainScreen].maximumFramesPerSecond] : @"60Hz display — feature inactive"; }),
                    Info(@"Status", ^{ return [NSString stringWithFormat:@"%@\n%@", [compat statusForModule:MTPModuleRefreshRate], MTPRefreshRateStatus()]; }),
                ]),
            ];
        case MTPSettingsGroupSuppression: {
            NSArray *thresholds = @[@2, @3, @4, @5, @7, @10];
            return @[
                Section(nil, @"Counts how often you choose \"Don't recommend channel\" / \"Show fewer … from this channel\". A creator is only suppressed after the threshold is reached — never after one interaction. Suppressed creators are hidden on Home, Shorts, Explore and Watch next, and stay available in search, channel search and on their channel page.", @[
                    Switch(@"Automatic suppression", MTPKeySuppressionAuto),
                    Choice(@"Interactions before suppressing", MTPKeySuppressionThreshold, thresholds, @[@"2", @"3", @"4", @"5", @"7", @"10"]),
                    Choice(@"Forget interactions after", MTPKeySuppressionWindowDays, @[@0, @30, @60, @90, @180], @[@"Never", @"30 days", @"60 days", @"90 days", @"180 days"]),
                    Action(@"Manage suppressed creators", ^(UIViewController *from) { [from.navigationController pushViewController:[MTPSuppressedCreatorsViewController new] animated:YES]; }),
                    Info(@"Status", ^{ return [compat statusForModule:MTPModuleSuppression]; }),
                ]),
            ];
        }
        case MTPSettingsGroupSearch:
            return @[
                Section(nil, @"Long-press the search button to open the filter panel. Filters combine, can be removed individually, and stay active when the sort order changes.", @[
                    Switch(@"Advanced search filters", MTPKeySearchFiltersEnabled),
                    Switch(@"Look up like counts (RYD API)", MTPKeySearchFetchLikes),
                    Action(@"Filters & sorting", ^(UIViewController *from) { [MTPSearchFilterViewController presentFromTop]; }),
                    Action(@"Commented videos search", ^(UIViewController *from) { [from.navigationController pushViewController:[MTPCommentedVideosViewController new] animated:YES]; }),
                    Info(@"Status", ^{ return [NSString stringWithFormat:@"%@\n%@", [compat statusForModule:MTPModuleSearch], MTPAdvancedSearchStatus()]; }),
                ]),
            ];
        case MTPSettingsGroupModernUI: {
            MTPTabLayout *layout = [MTPTabLayout shared];
            NSMutableArray *controls = [@[
                Switch(@"Floating-menu dock compatibility", MTPKeyModernUICompat),
                Switch(@"Restore Subscriptions tab", MTPKeyRestoreSubscriptions),
            ] mutableCopy];
            if (layout.ytplusTabHelperAvailable) {
                [controls addObject:Info(@"Dock order & visibility", ^{ return @"Managed by YTPlus (YTPlus settings › Tab bar). MaxTubePlus applies it to the floating menu."; })];
            } else {
                [controls addObject:Action(@"Edit dock (YTPlus tab editor not found)", ^(UIViewController *from) { [from.navigationController pushViewController:[MTPDockEditorViewController new] animated:YES]; })];
            }
            [controls addObject:Action(@"Apply now", ^(UIViewController *from) { [[MTPTabLayout shared] requestRefresh]; })];
            return @[
                Section(@"Status", @"MaxTubePlus keeps YouTube's newer floating menu and does not spoof the iOS version. It edits the tab data YouTube hands to the floating menu, re-adds Subscriptions (which the redesign no longer sends), and runs YTPlus's own tab customisation on it.", @[
                    Info(@"Floating menu", ^{ return layout.floatingConsumerSeen ? [NSString stringWithFormat:@"Detected (%@)", layout.lastConsumer] : [NSString stringWithFormat:@"Not seen yet (last: %@)", layout.lastConsumer]; }),
                    Info(@"Dock customisation", ^{ return layout.ytplusTabHelperAvailable ? @"YTPlus tab helper connected" : @"YTPlus tab helper not present — MaxTubePlus editor in use"; }),
                    Info(@"Subscriptions tab", ^{
                        if (![MTPPrefs boolForKey:MTPKeyRestoreSubscriptions]) return @"Not restored (disabled)";
                        if ([layout.lastFinalTabs containsObject:@"FEsubscriptions"]) return layout.subscriptionsInjected ? @"Visible (restored by MaxTubePlus)" : @"Visible (sent by YouTube)";
                        return layout.applicationCount ? @"Hidden by your dock settings" : @"Pending first dock layout";
                    }),
                    Info(@"iOS version spoofing", ^{ return compat.systemVersionSpoofed ? [NSString stringWithFormat:@"ACTIVE — reports iOS %@ on iOS %@. Turn off the spoof in YTPlus to get the floating menu.", compat.reportedSystemVersion, compat.realSystemVersion] : @"Off (recommended)"; }),
                    Info(@"Tabs from YouTube", ^{ return JoinTabs(layout.lastServerTabs); }),
                    Info(@"Tabs shown", ^{ return JoinTabs(layout.lastFinalTabs); }),
                    Info(@"Hooks", ^{ return [compat statusForModule:MTPModuleModernUI]; }),
                ]),
                Section(@"Controls", nil, controls),
            ];
        }
        case MTPSettingsGroupGeneral:
            return @[
                Section(@"Compatibility", [NSString stringWithFormat:@"MaxTubePlus targets YouTube %@. On other 21.x builds every hook checks that its class and selector exist and stays inactive otherwise. On older or unknown builds all modules are disabled unless you force them.", MTP_TARGET_YT_VERSION], @[
                    Info(@"Environment", ^{ return compat.summary; }),
                    Switch(@"Force-enable on unverified YouTube versions", MTPKeyForceUnverifiedVersion),
                    Switch(@"Debug logging (Console: com.maxtubeplus)", MTPKeyDebugLogging),
                ]),
                Section(nil, @"Changes to version gating take effect after restarting YouTube.", @[
                    ({ MTPRow *r = Action(@"Reset all MaxTubePlus settings", ^(UIViewController *from) {
                        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset MaxTubePlus settings?" message:@"YTPlus settings, downloads, suppressed creators and imported comments are not affected." preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                        [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [MTPPrefs resetAll]; if ([from respondsToSelector:@selector(rebuild)]) [(MTPSettingsViewController *)from rebuild]; }]];
                        [from presentViewController:a animated:YES completion:nil];
                    }); r.destructive = YES; r; }),
                ]),
            ];
        case MTPSettingsGroupAbout:
            return @[
                Section(@"MaxTubePlus", nil, @[
                    Info(@"Version", ^{ return [NSString stringWithFormat:@"%s (target YouTube %@)", MTP_VERSION, MTP_TARGET_YT_VERSION]; }),
                    Action(@"Source code", ^(UIViewController *from) { OpenURL(from, @"https://github.com/trail-b1az3r/Maxtubeplus-"); }),
                ]),
                Section(@"Credits", @"MaxTubePlus is a fork of MaxTube by Mark02-2012 and builds on YouTube Plus (YTPlus/YTLite) by dayanch96. DeArrow by Ajay Ramachandran (CC BY-NC-SA 4.0 data). Like counts from Return YouTube Dislike (returnyoutubedislikeapi.com). YouTube is a trademark of Google LLC; this project is not affiliated with Google.", @[
                    Action(@"MaxTube (upstream)", ^(UIViewController *from) { OpenURL(from, @"https://github.com/Mark02-2012/MaxTube"); }),
                    Action(@"YouTube Plus", ^(UIViewController *from) { OpenURL(from, @"https://github.com/dayanch96/YTLite"); }),
                    Action(@"DeArrow", ^(UIViewController *from) { OpenURL(from, @"https://dearrow.ajay.app"); }),
                ]),
            ];
        default:
            return @[];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _sections[section].rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return _sections[section].header; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return _sections[section].footer; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MTPRow *row = _sections[indexPath.section].rows[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:row.kind == MTPRowInfo ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = row.title;
    cell.textLabel.numberOfLines = 0;
    switch (row.kind) {
        case MTPRowSwitch: {
            UISwitch *toggle = [UISwitch new];
            toggle.on = [MTPPrefs boolForKey:row.key];
            toggle.accessibilityIdentifier = row.key;
            [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case MTPRowChoice: {
            NSUInteger idx = [row.values indexOfObject:@([MTPPrefs integerForKey:row.key])];
            cell.detailTextLabel.text = idx == NSNotFound ? [NSString stringWithFormat:@"%ld", (long)[MTPPrefs integerForKey:row.key]] : row.labels[idx];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MTPRowAction:
            cell.textLabel.textColor = row.destructive ? [UIColor systemRedColor] : self.view.tintColor;
            break;
        case MTPRowInfo:
            cell.detailTextLabel.text = row.detail ? row.detail() : nil;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
    }
    return cell;
}

- (void)toggled:(UISwitch *)toggle {
    [MTPPrefs setBool:toggle.on forKey:toggle.accessibilityIdentifier];
    if ([toggle.accessibilityIdentifier hasPrefix:@"modernui."]) [[MTPTabLayout shared] requestRefresh];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    MTPRow *row = _sections[indexPath.section].rows[indexPath.row];
    if (row.kind == MTPRowAction && row.action) {
        row.action(self);
    } else if (row.kind == MTPRowChoice) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row.title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSUInteger i = 0; i < row.values.count; i++) {
            NSNumber *value = row.values[i];
            [sheet addAction:[UIAlertAction actionWithTitle:row.labels[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [MTPPrefs setInteger:value.integerValue forKey:row.key];
                [self rebuild];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:sheet animated:YES completion:nil];
    }
}

@end

#pragma mark - Fallback dock editor

@implementation MTPDockEditorViewController {
    NSMutableArray<NSString *> *_order;
    NSMutableSet<NSString *> *_hidden;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dock";
    NSArray *saved = [MTPPrefs objectForKey:MTPKeyTabOrder];
    _order = [NSMutableArray array];
    NSArray *seen = [MTPTabLayout shared].lastFinalTabs;
    for (NSString *t in (saved.count ? saved : (seen.count ? seen : @[]))) if (![_order containsObject:t]) [_order addObject:t];
    for (NSString *t in [MTPTabLayout knownTabIdentifiers]) if (![_order containsObject:t]) [_order addObject:t];
    _hidden = [NSMutableSet setWithArray:[MTPPrefs objectForKey:MTPKeyHiddenTabs] ?: @[]];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reset" style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
}

- (void)save {
    [MTPPrefs setObject:[_order copy] forKey:MTPKeyTabOrder];
    [MTPPrefs setObject:_hidden.allObjects forKey:MTPKeyHiddenTabs];
    [[MTPTabLayout shared] requestRefresh];
}

- (void)reset {
    [MTPPrefs setObject:@[] forKey:MTPKeyTabOrder];
    [MTPPrefs setObject:@[] forKey:MTPKeyHiddenTabs];
    [_hidden removeAllObjects];
    [[MTPTabLayout shared] requestRefresh];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _order.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Drag to reorder, tap to show or hide. Tabs YouTube does not provide are skipped, except Subscriptions which MaxTubePlus can restore. Saved locally and kept across restarts.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *identifier = _order[indexPath.row];
    BOOL hidden = [_hidden containsObject:identifier];
    cell.textLabel.text = [MTPTabLayout displayNameForIdentifier:identifier];
    cell.textLabel.textColor = hidden ? [UIColor tertiaryLabelColor] : [UIColor labelColor];
    cell.detailTextLabel.text = hidden ? @"Hidden" : identifier;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:hidden ? @"eye.slash" : @"eye"];
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *item = _order[from.row];
    [_order removeObjectAtIndex:from.row];
    [_order insertObject:item atIndex:to.row];
    [self save];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = _order[indexPath.row];
    if ([_hidden containsObject:identifier]) [_hidden removeObject:identifier];
    else [_hidden addObject:identifier];
    [self save];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end
