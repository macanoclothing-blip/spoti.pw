#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"

// Every key under the prefix travels, the way the reset sweeps them, so a new switch needs nothing
// here. What is left out belongs to this install rather than to its user's choices.
static BOOL isSetting(NSString *key) {
    if (![key hasPrefix:@"spotifyglass."]) return NO;
    for (NSString *local in @[@"spotifyglass.adblock.counts", @"spotifyglass.privacy.counts", @"spotifyglass.update.",
                              @"spotifyglass.signing.", @"spotifyglass.onboarding.", @"spotifyglass.navbar.stock",
                              @"spotifyglass.redesign.navbar.stock"]) {
        if ([key hasPrefix:local]) return NO;
    }
    return YES;
}

static NSDictionary *storedDefaults(void) {
    return [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
}

static void showAlert(NSString *title, NSString *message, UIAlertAction *confirm) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (confirm) [alert addAction:confirm];
    [alert addAction:[UIAlertAction actionWithTitle:confirm ? @"Cancel" : @"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

void SGExportSettings(void) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [storedDefaults() enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (isSetting(key) && [NSJSONSerialization isValidJSONObject:@[value]]) settings[key] = value;
    }];
    NSDictionary *file = @{
        @"mod": @(SG_VERSION),
        @"spotify": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"settings": settings,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:file options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"spotifyglass-settings.json"]];
    [data writeToURL:url atomically:YES];

    UIViewController *top = SGTopController();
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

static NSString *redactedLogMessage(NSString *message) {
    NSArray<NSArray<NSString *> *> *patterns = @[
        @[@"(?i)(authorization\\s*[:=]\\s*)([^\\s,;]+(?:\\s+[^\\s,;]+)?)", @"$1[REDACTED]"],
        @[@"(?i)(\\b(?:access[_-]?token|refresh[_-]?token|client[_-]?token)\\b\\s*[:=]\\s*)[^\\s,;]+", @"$1[REDACTED]"],
    ];
    NSString *safe = message ?: @"";
    for (NSArray<NSString *> *pair in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pair[0] options:0 error:nil];
        safe = [regex stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0, safe.length) withTemplate:pair[1]];
    }
    return safe;
}

static void presentLogFile(NSURL *url) {
    UIViewController *top = SGTopController();
    if (!top || !url) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
    [top presentViewController:sheet animated:YES completion:nil];
}

void SGExportLogs(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SGLogFlush();
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSUInteger bytesRead = 0;
        for (NSString *path in SGLogFilePaths()) {
            NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            if (!data.length) continue;
            bytesRead += data.length;
            NSString *fileText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!fileText.length) continue;
            for (NSString *line in [fileText componentsSeparatedByString:@"\n"]) {
                if (line.length) [lines addObject:redactedLogMessage(line)];
            }
        }

        NSDateFormatter *filenameFormatter = [NSDateFormatter new];
        filenameFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        filenameFormatter.timeZone = [NSTimeZone localTimeZone];
        filenameFormatter.dateFormat = @"yyyyMMdd-HHmmss";
        NSMutableString *contents = [NSMutableString stringWithFormat:
            @"spoti.pw diagnostic logs\nMod version: %@\nSpotify version: %@\niOS: %@\nSource: local rolling log collected by this build\n",
            @(SG_VERSION),
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
            UIDevice.currentDevice.systemVersion];
        [contents appendFormat:@"Read %lu bytes and %lu log lines. Tokens and authorization headers are redacted.\n\n",
         (unsigned long)bytesRead, (unsigned long)lines.count];
        if (lines.count) {
            for (NSString *line in lines) [contents appendFormat:@"%@\n", line];
        } else {
            [contents appendString:@"No local log entries have been collected yet. Restart Spotify, reproduce the issue, then export again.\n"];
        }

        NSString *filename = [NSString stringWithFormat:@"spotifyglass-logs-%@.txt", [filenameFormatter stringFromDate:NSDate.date]];
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
        NSError *writeError = nil;
        BOOL written = [contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (written) presentLogFile(url);
            else showAlert(@"Could not export logs", writeError.localizedDescription ?: @"The log file could not be created.", nil);
        });
    });
}

static Class kindOf(id value) {
    for (Class kind in @[NSNumber.class, NSString.class, NSArray.class, NSDictionary.class]) {
        if ([value isKindOfClass:kind]) return kind;
    }
    return Nil;
}

// A key already stored keeps its type: the hooks send boolValue to whatever they find at launch, and
// an array there would crash Spotify before the reset row could be reached.
static void importSettings(NSDictionary *settings) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSDictionary *stored = storedDefaults();
    for (NSString *key in stored) {
        if (isSetting(key)) [store removeObjectForKey:key];
    }
    NSUInteger skipped = 0;
    for (NSString *key in settings) {
        id value = settings[key];
        id current = stored[key];
        BOOL fits = isSetting(key)
            && [NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0]
            && (!current || kindOf(current) == kindOf(value));
        if (fits) [store setObject:value forKey:key];
        else skipped++;
    }
    SGLog(@"import: set %lu keys, skipped %lu", (unsigned long)(settings.count - skipped), (unsigned long)skipped);
    SGRestartSpotify();
}

@interface SGSettingsPicker : NSObject <UIDocumentPickerDelegate>
@end

@implementation SGSettingsPicker

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = [NSData dataWithContentsOfURL:urls.firstObject];
    id file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *settings = [file isKindOfClass:NSDictionary.class] ? file[@"settings"] : nil;
    if (![settings isKindOfClass:NSDictionary.class]) {
        showAlert(@"Not a settings file", @"Pick a file made by Export settings.", nil);
        return;
    }
    NSString *mod = [file[@"mod"] isKindOfClass:NSString.class] ? file[@"mod"] : @"unknown";
    NSString *message = [NSString stringWithFormat:@"Your settings are replaced by the file's, exported from version %@. Anything it does not have goes back to its default, and Spotify restarts.", mod];
    showAlert(@"Import settings?", message, [UIAlertAction actionWithTitle:@"Import and restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        importSettings(settings);
    }]);
}

@end

void SGImportSettings(void) {
    static SGSettingsPicker *delegate;
    if (!delegate) delegate = [SGSettingsPicker new];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = delegate;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}
