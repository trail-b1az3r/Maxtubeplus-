#import "MTPSuppressedCreatorsViewController.h"
#import "MTPSuppressionStore.h"

@implementation MTPSuppressedCreatorsViewController {
    NSArray<MTPCreator *> *_suppressed;
    NSArray<MTPCreator *> *_tracked;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Suppressed Creators";
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Restore All" style:UIBarButtonItemStylePlain target:self action:@selector(restoreAll)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:MTPSuppressionChangedNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
    MTPSuppressionStore *store = [MTPSuppressionStore shared];
    _suppressed = [store suppressedCreators];
    _tracked = [store trackedCreators];
    self.navigationItem.rightBarButtonItem.enabled = _suppressed.count > 0;
    [self.tableView reloadData];
}

- (void)restoreAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore all creators?" message:@"They will appear in recommendations again. Feedback history is cleared." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        for (MTPCreator *c in self->_suppressed) [[MTPSuppressionStore shared] restoreCreatorWithKey:c.key];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *rows = section == 0 ? _suppressed : _tracked;
    return MAX((NSInteger)rows.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Suppressed" : @"Tracking (below threshold)";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Hidden from Home, Shorts, Explore and Watch next. Always reachable via search, channel search and their channel page. Tap to restore.";
    NSInteger threshold = mtp_clamp_threshold((int)[MTPPrefs integerForKey:MTPKeySuppressionThreshold]);
    return [NSString stringWithFormat:@"Creators are suppressed automatically after %ld \"Don't recommend channel\" / \"Show fewer\" interactions%@. Swipe to forget.",
            (long)threshold, [MTPPrefs boolForKey:MTPKeySuppressionAuto] ? @"" : @" (automatic suppression is OFF)"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *rows = indexPath.section == 0 ? _suppressed : _tracked;
    if (rows.count == 0) {
        cell.textLabel.text = indexPath.section == 0 ? @"No suppressed creators" : @"No feedback recorded";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    MTPCreator *creator = rows[indexPath.row];
    cell.textLabel.text = creator.displayName;
    NSDate *last = [NSDate dateWithTimeIntervalSince1970:creator.record.lastEventUnix];
    NSString *when = [NSDateFormatter localizedStringFromDate:last dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle];
    cell.detailTextLabel.text = creator.manual ? [NSString stringWithFormat:@"Suppressed manually · %@", when]
        : [NSString stringWithFormat:@"%d interaction(s) · last %@%@", creator.record.negativeCount, when, creator.channelID ? [@" · " stringByAppendingString:creator.channelID] : @""];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (indexPath.section == 0) {
        UILabel *restore = [UILabel new];
        restore.text = @"Restore";
        restore.textColor = self.view.tintColor;
        [restore sizeToFit];
        cell.accessoryView = restore;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || _suppressed.count == 0) return;
    MTPCreator *creator = _suppressed[indexPath.row];
    [[MTPSuppressionStore shared] restoreCreatorWithKey:creator.key];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = indexPath.section == 0 ? _suppressed : _tracked;
    if (rows.count == 0) return nil;
    MTPCreator *creator = rows[indexPath.row];
    UIContextualAction *forget = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Forget" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        [[MTPSuppressionStore shared] forgetCreatorWithKey:creator.key];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[forget]];
}

@end
