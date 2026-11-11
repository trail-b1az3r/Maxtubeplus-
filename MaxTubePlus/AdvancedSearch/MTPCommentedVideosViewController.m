#import "MTPCommentedVideosViewController.h"
#import "MTPCommentHistory.h"
#import "../Common/MTPVideoInfo.h"
#import <SafariServices/SafariServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MTPCommentedVideosViewController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@end

@implementation MTPCommentedVideosViewController {
    UISearchController *_search;
    NSArray<MTPCommentRecord *> *_results;
    MTPSortMode _sort;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Commented Videos";
    _sort = MTPSortRecency;
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"Search your comments";
    _search.searchBar.scopeButtonTitles = @[@"Recent", @"Relevance"];
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 88;

    UIAction *import = [UIAction actionWithTitle:@"Import Google Takeout comments…" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) { [self importTakeout]; }];
    UIAction *activity = [UIAction actionWithTitle:@"Open YouTube comment history (My Activity)" image:[UIImage systemImageNamed:@"safari"] identifier:nil handler:^(UIAction *a) { [self openMyActivity]; }];
    UIAction *help = [UIAction actionWithTitle:@"How to export comments" image:[UIImage systemImageNamed:@"questionmark.circle"] identifier:nil handler:^(UIAction *a) { [self showHelp]; }];
    UIAction *clear = [UIAction actionWithTitle:@"Remove imported comments" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
        [[MTPCommentHistory shared] removeAll];
        [self reload];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[import, activity, help, clear]]];
    [self reload];
}

- (void)reload {
    _results = [[MTPCommentHistory shared] search:_search.searchBar.text ?: @"" sort:_sort];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    _sort = controller.searchBar.selectedScopeButtonIndex == 1 ? MTPSortRelevance : MTPSortRecency;
    [self reload];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)_results.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    MTPCommentHistory *history = [MTPCommentHistory shared];
    if (history.records.count == 0) return nil;
    NSString *imported = history.lastImport ? [NSDateFormatter localizedStringFromDate:history.lastImport dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle] : @"never";
    return [NSString stringWithFormat:@"%lu of %lu comments · imported %@", (unsigned long)_results.count, (unsigned long)history.records.count, imported];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 4;
    if (_results.count == 0) {
        BOOL empty = [MTPCommentHistory shared].records.count == 0;
        cell.textLabel.text = empty ? @"No comments imported yet" : @"No matching comments";
        cell.detailTextLabel.text = empty ? @"Tap ⋯ → Import Google Takeout comments. Takeout includes every comment, even on videos that aren't in your watch history." : nil;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    MTPCommentRecord *record = _results[indexPath.row];
    MTPVideoInfo *info = [[MTPVideoInfoProvider shared] cachedInfoForVideoID:record.videoID];
    if (info) {
        cell.textLabel.text = info.unavailable ? [NSString stringWithFormat:@"Unavailable video (%@)", record.videoID] : info.title;
    } else {
        cell.textLabel.text = record.videoID;
        __weak UITableView *weakTable = tableView;
        [[MTPVideoInfoProvider shared] infoForVideoID:record.videoID completion:^(MTPVideoInfo *fetched) {
            if (fetched && [weakTable.indexPathsForVisibleRows containsObject:indexPath]) [weakTable reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }];
    }
    NSString *date = record.date ? [NSDateFormatter localizedStringFromDate:record.date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle] : @"";
    NSString *channel = info.authorName ? [info.authorName stringByAppendingString:@" · "] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@\n“%@”", channel, date, record.text];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)_results.count) return;
    MTPCommentRecord *record = _results[indexPath.row];
    NSString *link = [NSString stringWithFormat:@"youtube://www.youtube.com/watch?v=%@%@", record.videoID,
                      record.commentID ? [@"&lc=" stringByAppendingString:record.commentID] : @""];
    [self.presentingViewController ?: self dismissViewControllerAnimated:YES completion:^{
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:link] options:@{} completionHandler:nil];
    }];
}

- (void)importTakeout {
    NSArray *types = @[UTTypeCommaSeparatedText, UTTypeHTML, UTTypePlainText];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSInteger total = 0;
    NSError *error = nil;
    for (NSURL *url in urls) {
        NSInteger added = [[MTPCommentHistory shared] importTakeoutFileAtURL:url error:&error];
        if (added > 0) total += added;
    }
    NSString *message = error && total == 0 ? error.localizedDescription : [NSString stringWithFormat:@"Imported %ld new comment(s).", (long)total];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Takeout import" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self reload];
}

- (void)openMyActivity {
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:[NSURL URLWithString:@"https://myactivity.google.com/page?page=youtube_comments"]];
    [self presentViewController:safari animated:YES completion:nil];
}

- (void)showHelp {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export your comments"
        message:@"1. Open takeout.google.com\n2. Deselect all, select \"YouTube and YouTube Music\"\n3. Under \"All YouTube data included\" keep \"comments\"\n4. Export, download, unzip\n5. Import YouTube and YouTube Music/comments/comments.csv\n\nYouTube's app API has no comment-history endpoint, so this export is the complete source. Your file is parsed on-device and never uploaded."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
