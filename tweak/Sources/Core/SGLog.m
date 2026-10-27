#import "SGLog.h"

static const unsigned long long SGLogMaximumFileSize = 2 * 1024 * 1024;
static char SGLogQueueSpecificKey;

static dispatch_queue_t SGLogWriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("pw.spoti.spotifyglass.log-writer", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &SGLogQueueSpecificKey, &SGLogQueueSpecificKey, NULL);
    });
    return queue;
}

static NSURL *SGLogDirectoryURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
    return support ? [support URLByAppendingPathComponent:@"spoti.pw" isDirectory:YES] : nil;
}

NSArray<NSString *> *SGLogFilePaths(void) {
    NSURL *directory = SGLogDirectoryURL();
    if (!directory) return @[];
    return @[
        [[directory URLByAppendingPathComponent:@"spotifyglass.log.previous"] path],
        [[directory URLByAppendingPathComponent:@"spotifyglass.log"] path],
    ];
}

static NSString *SGLogTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    });
    return [formatter stringFromDate:NSDate.date];
}

static void SGAppendPersistedLog(NSString *line) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *directory = SGLogDirectoryURL();
        if (!directory || ![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;

        NSArray<NSString *> *paths = SGLogFilePaths();
        NSString *previousPath = paths.firstObject;
        NSString *currentPath = paths.lastObject;
        NSDictionary *attributes = [files attributesOfItemAtPath:currentPath error:nil];
        if ([attributes[NSFileSize] unsignedLongLongValue] >= SGLogMaximumFileSize) {
            [files removeItemAtPath:previousPath error:nil];
            NSError *moveError = nil;
            if (![files moveItemAtPath:currentPath toPath:previousPath error:&moveError]) {
                [files removeItemAtPath:currentPath error:nil];
            }
        }

        if (![files fileExistsAtPath:currentPath] && ![files createFileAtPath:currentPath contents:nil attributes:nil]) return;
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:currentPath];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            NSString *record = [NSString stringWithFormat:@"%@ %@\n", SGLogTimestamp(), line];
            [handle writeData:[record dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (__unused NSException *exception) {
            // Diagnostics must never interrupt Spotify if storage is unavailable.
        } @finally {
            [handle closeFile];
        }
    }
}

void SGLogMessage(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"[spotifyglass] %@", message ?: @""];
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String);
    dispatch_async(SGLogWriteQueue(), ^{
        SGAppendPersistedLog(line);
    });
}

void SGLogFlush(void) {
    dispatch_queue_t queue = SGLogWriteQueue();
    if (dispatch_get_specific(&SGLogQueueSpecificKey)) return;
    dispatch_sync(queue, ^{});
}

// The unified log cuts a message at about 1 KB, so long dumps go out as numbered parts.
void SGLogLong(NSString *tag, NSString *text) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (current.length && [current lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 900) {
            [parts addObject:[current copy]];
            [current setString:@""];
        }
        [current appendFormat:@"%@\n", line];
    }
    if (current.length) [parts addObject:current];
    [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger i, BOOL *stop) {
        SGLog(@"%@ %lu/%lu\n%@", tag, (unsigned long)i + 1, (unsigned long)parts.count, part);
    }];
}

void SGRequireClasses(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if (!NSClassFromString(name)) SGLog(@"class %@ not found, its hooks are inactive", name);
    }
}
