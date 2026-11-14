#import "MTPSearchFilterViewController.h"
#import "MTPSearchFilterState.h"
#import "MTPCommentedVideosViewController.h"

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
    MTPSectionModes,
    MTPSectionCount,
};

@implementation MTPSearchFilterViewController {
    MTPSearchFilterState *_state;
    UILabel *_durationLabel;
    MTPRangeSlider *_slider;
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
    [self refresh];
}

- (void)done {
    [self.view endEditing:YES]; // commits the likes field
    [_state save];
    NSString *query = MTPLastSearchQuery();
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
    }
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
