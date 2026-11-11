#import "MTPDownloadsViewController.h"
#import "MTPDownloadManager.h"

@implementation MTPDownloadsViewController {
    NSArray<MTPDownloadItem *> *_items;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Background Downloads";
    UIAction *clear = [UIAction actionWithTitle:@"Clear finished from list" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *a) {
        [[MTPDownloadManager shared] removeAllFinished];
    }];
    UIAction *open = [UIAction actionWithTitle:@"Show downloads folder" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
        NSURL *url = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:[MTPDownloadManager downloadsDirectory]]];
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[open, clear]]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:MTPDownloadsChangedNotification object:nil];
    [self reload];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)reload {
    _items = [MTPDownloadManager shared].items;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : MAX((NSInteger)_items.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Storage" : @"Queue";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Files are saved to Files › On My iPhone › YouTube › MaxTubePlus Downloads.";
    return @"Swipe for pause, resume, retry, cancel and delete. Downloads continue in the background and resume after the app is closed; interrupted downloads are recovered at next launch.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (indexPath.section == 0) {
        long long used = [[MTPDownloadManager shared] storageUsedBytes];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        long long free = [attrs[NSFileSystemFreeSize] longLongValue];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ used", [NSByteCountFormatter stringFromByteCount:used countStyle:NSByteCountFormatterCountStyleFile]];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ free on device", [NSByteCountFormatter stringFromByteCount:free countStyle:NSByteCountFormatterCountStyleFile]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (_items.count == 0) {
        cell.textLabel.text = @"No downloads";
        cell.detailTextLabel.text = @"While watching, open the video's ⋯ menu and choose \"Download in background (MaxTubePlus)\".";
        cell.detailTextLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    MTPDownloadItem *item = _items[indexPath.row];
    cell.textLabel.text = item.title;
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", item.qualityLabel, item.stateDescription];
    cell.detailTextLabel.numberOfLines = 2;
    if (item.state == MTPDownloadStateDownloading || item.state == MTPDownloadStatePaused) {
        UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        progress.progress = item.progress;
        progress.frame = CGRectMake(0, 0, 60, 4);
        cell.accessoryView = progress;
    } else if (item.state == MTPDownloadStateCompleted) {
        cell.accessoryType = UITableViewCellAccessoryDetailButton;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || indexPath.row >= (NSInteger)_items.count) return;
    MTPDownloadItem *item = _items[indexPath.row];
    if (item.state == MTPDownloadStateCompleted && item.outputPath) {
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:item.outputPath]] applicationActivities:nil];
        share.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:share animated:YES completion:nil];
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    [self tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1 || indexPath.row >= (NSInteger)_items.count) return nil;
    MTPDownloadItem *item = _items[indexPath.row];
    MTPDownloadManager *manager = [MTPDownloadManager shared];
    NSMutableArray *actions = [NSMutableArray array];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [manager remove:item deleteFile:YES];
        done(YES);
    }];
    [actions addObject:delete];
    switch (item.state) {
        case MTPDownloadStateDownloading:
        case MTPDownloadStateQueued: {
            UIContextualAction *pause = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Pause" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [manager pause:item]; done(YES); }];
            pause.backgroundColor = [UIColor systemOrangeColor];
            UIContextualAction *cancel = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Cancel" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [manager cancel:item]; done(YES); }];
            [actions addObjectsFromArray:@[cancel, pause]];
            break;
        }
        case MTPDownloadStatePaused: {
            UIContextualAction *resume = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Resume" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [manager resume:item]; done(YES); }];
            resume.backgroundColor = [UIColor systemGreenColor];
            UIContextualAction *cancel = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Cancel" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [manager cancel:item]; done(YES); }];
            [actions addObjectsFromArray:@[cancel, resume]];
            break;
        }
        case MTPDownloadStateFailed:
        case MTPDownloadStateCancelled: {
            UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Retry" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [manager retry:item]; done(YES); }];
            retry.backgroundColor = [UIColor systemBlueColor];
            [actions addObject:retry];
            break;
        }
        default: break;
    }
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

@end
