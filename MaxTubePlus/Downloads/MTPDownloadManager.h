#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MTPDownloadState) {
    MTPDownloadStateQueued = 0,
    MTPDownloadStateDownloading,
    MTPDownloadStatePaused,
    MTPDownloadStateProcessing,   // muxing audio + video
    MTPDownloadStateCompleted,
    MTPDownloadStateFailed,
    MTPDownloadStateCancelled,
};

/// One part of a download (a single googlevideo stream).
@interface MTPDownloadPart : NSObject
@property (nonatomic, copy) NSString *kind;          // "video" | "audio"
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic) long long expectedBytes;
@property (nonatomic) long long receivedBytes;
@property (nonatomic, copy, nullable) NSString *localPath;      // finished part
@property (nonatomic, copy, nullable) NSString *resumeDataPath; // paused/interrupted
@property (nonatomic) BOOL finished;
@end

@interface MTPDownloadItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *channel;
@property (nonatomic) BOOL audioOnly;
@property (nonatomic, copy) NSString *qualityLabel;
@property (nonatomic) MTPDownloadState state;
@property (nonatomic, copy) NSArray<MTPDownloadPart *> *parts;
@property (nonatomic) NSInteger attempts;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, copy, nullable) NSString *outputPath;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong, nullable) NSDate *nextRetryAt;
- (double)progress;
- (NSString *)stateDescription;
@end

extern NSNotificationName const MTPDownloadsChangedNotification;

/// Background download engine. Uses a background NSURLSession so transfers
/// continue while YouTube is suspended or terminated by the system, and are
/// delivered to the app on relaunch (application:handleEventsForBackgroundURLSession:).
@interface MTPDownloadManager : NSObject
+ (instancetype)shared;
+ (NSString *)sessionIdentifier;
@property (nonatomic, readonly) NSArray<MTPDownloadItem *> *items;
@property (nonatomic, copy, nullable) void (^backgroundCompletionHandler)(void);

/// Builds a download from the currently playing video's streaming data using
/// the user's quality/audio preferences. Returns an error message on failure.
- (nullable NSString *)enqueueFromPlayer:(id)playerViewController;
- (void)pause:(MTPDownloadItem *)item;
- (void)resume:(MTPDownloadItem *)item;
- (void)cancel:(MTPDownloadItem *)item;
- (void)retry:(MTPDownloadItem *)item;
- (void)remove:(MTPDownloadItem *)item deleteFile:(BOOL)deleteFile;
- (void)removeAllFinished;
- (void)reconcileAfterLaunch;

+ (NSString *)downloadsDirectory;
- (long long)storageUsedBytes;
@end

NS_ASSUME_NONNULL_END
