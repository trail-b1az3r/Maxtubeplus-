#import "MTPSearchFilterViewController.h"
#import "MTPSearchFilterState.h"
#import "MTPCommentedVideosViewController.h"
#import "../CreatorSuppression/MTPBanStore.h"

extern NSString *MTPLastSearchQuery(void);
extern void MTPRunSearch(NSString *query);

static const CGFloat kMaxMinutes = 120; // slider top = "no upper bound"

@implementation MTPRangeSlider {
    UIView *_track, *_fill, *_lowerThumb, *_upperThumb;
    UIView *_dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _minimumValue = 0; _maximumValue = 1; _lowerValue = 0; _upperValue = 1;
        _track = [UIView new];
        _track.backgroundColor = [UIColor systemFillColor];
        _track.layer.cornerRadius = 2;
        _fill = [UIView new];
        _fill.backgroundColor = self.tintColor;
        _lowerThumb = [self makeThumb];
        _upperThumb = [self makeThumb];
        for (UIView *v in @[_track, _fill, _lowerThumb, _upperThumb]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Duration range";
    }
    return self;
}

- (UIView *)makeThumb {
    UIView *thumb = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    thumb.backgroundColor = [UIColor whiteColor];
    thumb.layer.cornerRadius = 14;
    thumb.layer.shadowOpacity = 0.25;
    thumb.layer.shadowRadius = 3;
    thumb.layer.shadowOffset = CGSizeMake(0, 1);
    return thumb;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 44); }

- (CGFloat)xFor:(CGFloat)value {
    CGFloat usable = self.bounds.size.width - 28;
    CGFloat span = MAX(_maximumValue - _minimumValue, 0.0001);
    return 14 + usable * (value - _minimumValue) / span;
}

- (CGFloat)valueFor:(CGFloat)x {
    CGFloat usable = MAX(self.bounds.size.width - 28, 1);
    CGFloat v = _minimumValue + (x - 14) / usable * (_maximumValue - _minimumValue);
    return MIN(MAX(v, _minimumValue), _maximumValue);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat mid = self.bounds.size.height / 2;
    _track.frame = CGRectMake(14, mid - 2, self.bounds.size.width - 28, 4);
    CGFloat lx = [self xFor:_lowerValue], ux = [self xFor:_upperValue];
    _fill.frame = CGRectMake(lx, mid - 2, ux - lx, 4);
    _lowerThumb.center = CGPointMake(lx, mid);
    _upperThumb.center = CGPointMake(ux, mid);
    self.accessibilityValue = [NSString stringWithFormat:@"%.0f to %.0f minutes", _lowerValue, _upperValue];
}

- (void)tintColorDidChange { [super tintColorDidChange]; _fill.backgroundColor = self.tintColor; }

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint p = [touch locationInView:self];
    CGFloat dl = fabs(p.x - _lowerThumb.center.x), du = fabs(p.x - _upperThumb.center.x);
    _dragging = dl <= du ? _lowerThumb : _upperThumb;
    if (fabs(dl - du) < 1 && p.x > _upperThumb.center.x) _dragging = _upperThumb;
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat v = roundf([self valueFor:[touch locationInView:self].x]);
    if (_dragging == _lowerThumb) _lowerValue = MIN(v, _upperValue);
    else _upperValue = MAX(v, _lowerValue);
    [self setNeedsLayout];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _dragging = nil;
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

@end

typedef NS_ENUM(NSInteger, MTPSection) {
    MTPSectionActive = 0,
    MTPSectionSort,
    MTPSectionDuration,
    MTPSectionLikes,
    MTPSectionDate,
    MTPSectionMatching,
    MTPSectionTopics,
    MTPSectionBans,
    MTPSectionModes,
    MTPSectionCount,
};

@implementation MTPSearchFilterViewController {
    MTPSearchFilterState *_state;
    UILabel *_durationLabel;
    MTPRangeSlider *_slider;
    UITextField *_termField;
    UISegmentedControl *_termMode;
    UITextField *_banField;
}

+ (void)presentFromTop {
    UIViewController *top = MTPTopViewController();
    if (!top) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[MTPSearchFilterViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
    [top presentViewController:nav animated:YES completion:nil];
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _state = [MTPSearchFilterState shared];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *query = MTPLastSearchQuery();
    self.title = query.length ? [NSString stringWithFormat:@"Filters · %@", query] : @"Search filters";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:query.length ? @"Apply" : @"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear All" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:MTPBansChangedNotification object:nil];
    [self refresh];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)done {
    [self.view endEditing:YES]; // commits the likes field
    [_state save];
    NSString *query = MTPLastSearchQuery();
    // No search yet: search for the topics/tags themselves.
    if (query.length == 0 && _state.includeTerms.count) query = [_state.includeTerms componentsJoinedByString:@" "];
    [self dismissViewControllerAnimated:YES completion:^{
        MTPRunSearch(query); // re-runs the current search with the filters (or toasts if none)
    }];
}

- (void)clearAll {
    [_state clearAll];
    [self refresh];
}

- (void)refresh {
    self.navigationItem.leftBarButtonItem.enabled = [_state hasActiveFilters];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return MTPSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case MTPSectionActive: return MAX((NSInteger)[_state activeKinds].count, 1);
        case MTPSectionSort: return 1;
        case MTPSectionDuration: return 1;
        case MTPSectionLikes: return 1;
        case MTPSectionDate: return 3;
        case MTPSectionMatching: return 2;
        case MTPSectionTopics: return 1 + (NSInteger)(_state.includeTerms.count + _state.excludeTerms.count);
        case MTPSectionBans: return 1 + (NSInteger)[MTPBanStore shared].creators.count;
        case MTPSectionModes: return 2;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case MTPSectionActive: return @"Active filters";
        case MTPSectionSort: return @"Sort";
        case MTPSectionDuration: return @"Duration";
        case MTPSectionLikes: return @"Minimum likes";
        case MTPSectionDate: return @"Upload date";
        case MTPSectionMatching: return @"Matching";
        case MTPSectionTopics: return @"Topics & tags";
        case MTPSectionBans: return @"Banned creators";
        case MTPSectionModes: return @"Search mode";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case MTPSectionActive: return @"Tap a filter to remove it. Filters stay active when you change the sort order.";
        case MTPSectionSort: return @"Recency asks YouTube to sort by upload date; your filters are sent along with it. Tap Apply to search again with these settings.";
        case MTPSectionLikes: return @"Search results don't include like counts, so they are looked up from the Return YouTube Dislike API (returnyoutubedislikeapi.com). Results are shown until their count is known.";
        case MTPSectionDate: return @"YouTube narrows results to the nearest server bucket (hour/day/week/month/year); MaxTubePlus then applies the exact range using the upload age shown on each result (English UI labels).";
        case MTPSectionMatching: return @"Flexible dates: upload-date and recency filters keep results that are close to the range (YouTube only shows rough ages like \"1 year ago\"). Loose names: topics, tags, banned names and commented-video search ignore upper/lower case and tolerate small typos.";
        case MTPSectionTopics: return @"Results must mention at least one included topic and none of the excluded ones (title, description snippet, #hashtags). Start a #tag to match whole hashtags. Tap a topic to search for it or remove it; with no search open, Apply searches your topics.";
        case MTPSectionBans: return @"Everything from a banned creator — videos, Shorts and posts — is hidden in Home, Shorts, Search, Subscriptions and Watch next, and the next item takes its place. Their own channel page still opens. Tap a creator to unban.";
        case MTPSectionModes: return @"Commented videos searches comments imported from Google Takeout — including videos that are not in your watch history.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    switch (indexPath.section) {
        case MTPSectionActive: {
            NSArray *kinds = [_state activeKinds];
            if (kinds.count == 0) {
                cell.textLabel.text = @"No filters";
                cell.textLabel.textColor = [UIColor secondaryLabelColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = [_state descriptionForKind:[kinds[indexPath.row] integerValue]];
                cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"xmark.circle.fill"]];
                cell.accessoryView.tintColor = [UIColor tertiaryLabelColor];
            }
            break;
        }
        case MTPSectionSort: {
            UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Relevance", @"Recency"]];
            segment.selectedSegmentIndex = _state.sortMode == MTPSortRecency ? 1 : 0;
            [segment addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
            [self embed:segment in:cell];
            break;
        }
        case MTPSectionDuration: {
            UIStackView *stack = [UIStackView new];
            stack.axis = UILayoutConstraintAxisVertical;
            stack.spacing = 4;
            _durationLabel = [UILabel new];
            _durationLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
            _slider = [MTPRangeSlider new];
            _slider.minimumValue = 0;
            _slider.maximumValue = kMaxMinutes;
            _slider.lowerValue = _state.minDuration >= 0 ? _state.minDuration / 60.0 : 0;
            _slider.upperValue = _state.maxDuration >= 0 ? MIN(_state.maxDuration / 60.0, kMaxMinutes) : kMaxMinutes;
            [_slider addTarget:self action:@selector(durationChanged:) forControlEvents:UIControlEventValueChanged];
            [_slider addTarget:self action:@selector(durationCommitted:) forControlEvents:UIControlEventEditingDidEnd];
            [stack addArrangedSubview:_durationLabel];
            [stack addArrangedSubview:_slider];
            [self embed:stack in:cell];
            [self updateDurationLabel];
            break;
        }
        case MTPSectionLikes: {
            UITextField *field = [UITextField new];
            field.placeholder = @"Off (e.g. 10000)";
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = _state.minLikes >= 0 ? [NSString stringWithFormat:@"%lld", _state.minLikes] : nil;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            [field addTarget:self action:@selector(likesChanged:) forControlEvents:UIControlEventEditingDidEnd];
            UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
            bar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                          [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:field action:@selector(resignFirstResponder)]];
            field.inputAccessoryView = bar;
            [self embed:field in:cell];
            break;
        }
        case MTPSectionDate: {
            if (indexPath.row == 0) {
                UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Any", @"Hour", @"Day", @"Week", @"Month", @"Year"]];
                NSArray *ages = @[@(-1), @3600, @86400, @(7 * 86400), @(31 * 86400), @(366 * 86400)];
                NSUInteger idx = [ages indexOfObject:@(_state.maxAge)];
                segment.selectedSegmentIndex = idx == NSNotFound ? 0 : idx;
                [segment addTarget:self action:@selector(recencyChanged:) forControlEvents:UIControlEventValueChanged];
                [self embed:segment in:cell];
            } else {
                BOOL after = indexPath.row == 1;
                cell.textLabel.text = after ? @"Uploaded after" : @"Uploaded before";
                UIDatePicker *picker = [UIDatePicker new];
                picker.datePickerMode = UIDatePickerModeDate;
                picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
                picker.maximumDate = [NSDate date];
                picker.date = (after ? _state.uploadedAfter : _state.uploadedBefore) ?: [NSDate date];
                picker.tag = after ? 1 : 2;
                picker.alpha = (after ? _state.uploadedAfter : _state.uploadedBefore) ? 1.0 : 0.5;
                [picker addTarget:self action:@selector(dateChanged:) forControlEvents:UIControlEventValueChanged];
                [picker sizeToFit];
                cell.accessoryView = picker;
            }
            break;
        }
        case MTPSectionMatching: {
            NSString *key = indexPath.row == 0 ? MTPKeySearchFlexibleDates : MTPKeySearchLooseNames;
            cell.textLabel.text = indexPath.row == 0 ? @"Flexible dates (don't require exact dates)" : @"Loose names (don't require exact names)";
            cell.textLabel.numberOfLines = 0;
            UISwitch *toggle = [UISwitch new];
            toggle.on = [MTPPrefs boolForKey:key];
            toggle.accessibilityIdentifier = key;
            [toggle addTarget:self action:@selector(matchingToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case MTPSectionTopics: {
            if (indexPath.row == 0) {
                if (!_termField) {
                    _termField = [UITextField new];
                    _termField.placeholder = @"Topic, keyword or #tag";
                    _termField.autocapitalizationType = UITextAutocapitalizationTypeNone;
                    _termField.returnKeyType = UIReturnKeyDone;
                    _termField.clearButtonMode = UITextFieldViewModeWhileEditing;
                    [_termField addTarget:self action:@selector(addTerm) forControlEvents:UIControlEventEditingDidEndOnExit];
                    _termMode = [[UISegmentedControl alloc] initWithItems:@[@"Include", @"Exclude"]];
                    _termMode.selectedSegmentIndex = 0;
                }
                UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
                [add setTitle:@"Add" forState:UIControlStateNormal];
                [add addTarget:self action:@selector(addTerm) forControlEvents:UIControlEventTouchUpInside];
                UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_termField, _termMode, add]];
                row.spacing = 8;
                [_termMode setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [add setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [self embed:row in:cell];
            } else {
                NSInteger i = indexPath.row - 1;
                BOOL exclude = i >= (NSInteger)_state.includeTerms.count;
                NSString *term = exclude ? _state.excludeTerms[i - _state.includeTerms.count] : _state.includeTerms[i];
                cell.textLabel.text = term;
                cell.detailTextLabel.text = exclude ? @"Excluded" : @"Included";
                cell.imageView.image = [UIImage systemImageNamed:exclude ? @"minus.circle" : ([term hasPrefix:@"#"] ? @"number" : @"plus.circle")];
                cell.imageView.tintColor = exclude ? [UIColor systemRedColor] : [UIColor systemGreenColor];
            }
            break;
        }
        case MTPSectionBans: {
            if (indexPath.row == 0) {
                if (!_banField) {
                    _banField = [UITextField new];
                    _banField.placeholder = @"@handle";
                    _banField.autocapitalizationType = UITextAutocapitalizationTypeNone;
                    _banField.autocorrectionType = UITextAutocorrectionTypeNo;
                    _banField.keyboardType = UIKeyboardTypeTwitter;
                    _banField.returnKeyType = UIReturnKeyDone;
                    [_banField addTarget:self action:@selector(addBan) forControlEvents:UIControlEventEditingDidEndOnExit];
                }
                UIButton *ban = [UIButton buttonWithType:UIButtonTypeSystem];
                [ban setTitle:@"Ban" forState:UIControlStateNormal];
                [ban setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
                [ban addTarget:self action:@selector(addBan) forControlEvents:UIControlEventTouchUpInside];
                [ban setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_banField, ban]];
                row.spacing = 8;
                [self embed:row in:cell];
            } else {
                MTPBannedCreator *creator = [MTPBanStore shared].creators[indexPath.row - 1];
                cell.textLabel.text = creator.displayName;
                cell.detailTextLabel.text = creator.channelID ?: (creator.resolveError ?: @"Looking up…");
                cell.imageView.image = [UIImage systemImageNamed:@"nosign"];
                cell.imageView.tintColor = [UIColor systemRedColor];
            }
            break;
        }
        case MTPSectionModes: {
            cell.textLabel.text = indexPath.row == 0 ? @"Videos (YouTube search)" : @"Commented videos";
            cell.accessoryType = indexPath.row == 0 ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
    }
    return cell;
}

- (void)embed:(UIView *)view in:(UITableViewCell *)cell {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:view];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == MTPSectionActive) {
        NSArray *kinds = [_state activeKinds];
        if (indexPath.row < (NSInteger)kinds.count) {
            [_state removeKind:[kinds[indexPath.row] integerValue]];
            [self refresh];
        }
    } else if (indexPath.section == MTPSectionModes && indexPath.row == 1) {
        [self.navigationController pushViewController:[MTPCommentedVideosViewController new] animated:YES];
    } else if (indexPath.section == MTPSectionTopics && indexPath.row > 0) {
        NSInteger i = indexPath.row - 1;
        BOOL exclude = i >= (NSInteger)_state.includeTerms.count;
        NSString *term = exclude ? _state.excludeTerms[i - _state.includeTerms.count] : _state.includeTerms[i];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:term message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:[term hasPrefix:@"#"] ? @"Open hashtag page" : @"Search YouTube for this" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self searchTerm:term];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self->_state removeTerm:term];
            [self refresh];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.section == MTPSectionBans && indexPath.row > 0) {
        MTPBannedCreator *creator = [MTPBanStore shared].creators[indexPath.row - 1];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[@"Unban " stringByAppendingString:creator.displayName] message:@"Their videos, Shorts and posts will appear again." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Unban" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[MTPBanStore shared] unbanHandle:creator.handle];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)matchingToggled:(UISwitch *)toggle {
    [MTPPrefs setBool:toggle.on forKey:toggle.accessibilityIdentifier];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MTPSectionActive] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)addTerm {
    NSString *term = _termField.text;
    if (term.length < 2) return;
    [_state addTerm:term exclude:_termMode.selectedSegmentIndex == 1];
    _termField.text = nil;
    [self refresh];
}

- (void)addBan {
    NSString *input = _banField.text;
    if (input.length == 0) return;
    [_banField resignFirstResponder];
    [[MTPBanStore shared] banHandle:input completion:^(NSString *error) {
        if (error) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ban creator" message:error preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        [self refresh];
    }];
    _banField.text = nil;
    [self refresh];
}

- (void)searchTerm:(NSString *)term {
    [_state save];
    [self dismissViewControllerAnimated:YES completion:^{
        if ([term hasPrefix:@"#"] && term.length > 1) {
            NSString *tag = [[term substringFromIndex:1] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[@"youtube://www.youtube.com/hashtag/" stringByAppendingString:tag]] options:@{} completionHandler:nil];
        } else {
            MTPRunSearch(term);
        }
    }];
}

- (void)sortChanged:(UISegmentedControl *)segment {
    _state.sortMode = segment.selectedSegmentIndex == 1 ? MTPSortRecency : MTPSortRelevance;
    [_state save]; // filters are untouched
}

- (void)updateDurationLabel {
    NSString *low = _slider.lowerValue <= 0 ? @"Any" : [NSString stringWithFormat:@"%.0f min", _slider.lowerValue];
    NSString *high = _slider.upperValue >= kMaxMinutes ? @"Any" : [NSString stringWithFormat:@"%.0f min", _slider.upperValue];
    _durationLabel.text = [NSString stringWithFormat:@"Minimum: %@   Maximum: %@", low, high];
}

- (void)durationChanged:(MTPRangeSlider *)slider { [self updateDurationLabel]; }

- (void)durationCommitted:(MTPRangeSlider *)slider {
    _state.minDuration = slider.lowerValue <= 0 ? -1 : (long)(slider.lowerValue * 60);
    _state.maxDuration = slider.upperValue >= kMaxMinutes ? -1 : (long)(slider.upperValue * 60);
    [_state save];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MTPSectionActive] withRowAnimation:UITableViewRowAnimationNone];
    self.navigationItem.leftBarButtonItem.enabled = [_state hasActiveFilters];
}

- (void)likesChanged:(UITextField *)field {
    long long value = field.text.length ? field.text.longLongValue : -1;
    _state.minLikes = value > 0 ? value : -1;
    [_state save];
    [self refresh];
}

- (void)recencyChanged:(UISegmentedControl *)segment {
    NSArray *ages = @[@(-1), @3600, @86400, @(7 * 86400), @(31 * 86400), @(366 * 86400)];
    _state.maxAge = [ages[segment.selectedSegmentIndex] longLongValue];
    [_state save];
    [self refresh];
}

- (void)dateChanged:(UIDatePicker *)picker {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    if (picker.tag == 1) _state.uploadedAfter = [calendar startOfDayForDate:picker.date];
    else _state.uploadedBefore = [[calendar startOfDayForDate:picker.date] dateByAddingTimeInterval:86399];
    [_state save];
    [self refresh];
}

@end
