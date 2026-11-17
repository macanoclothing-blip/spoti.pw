#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Core/SGPrefs.h"
#import "Headers/SPTPlayer.h"
#import "Redesigned/Kit/SGRBridges.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Moments/Moments.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LockScreenArtwork/SGArtworkFile.h"
#import "Shared/LockScreenArtwork/SGCanvas.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

static NSString *const kMomentsEntriesKey = @"spotifyglass.redesign.moments.entries";
static NSString *const kMomentsAvatarsKey = @"spotifyglass.redesign.moments.avatars";
static NSString *const kMomentsUserAvatarKey = @"spotifyglass.redesign.moments.userAvatar";
static NSString *const kMomentTextKey = @"text";
static NSString *const kMomentTrackKey = @"trackID";
static NSString *const kMomentArtistKey = @"artist";
static NSString *const kMomentArtistIDKey = @"artistID";
static NSString *const kMomentTitleKey = @"title";
static NSString *const kMomentTimeKey = @"timestampMs";
static NSString *const kMomentCreatedKey = @"createdAt";
static NSString *const kMomentDurationKey = @"durationMs"; // opzionale: assente nei momenti vecchi
static NSString *const kMomentCommentsKey = @"comments";
static NSString *const kMomentStylesKey = @"spotifyglass.redesign.moments.styles";
static NSString *const kMomentsAssetsChangedNotification = @"spotifyglass.redesign.moments.assets";
static NSString *const kMomentCanvasIDKey = @"canvasID";
static NSString *const kMomentCanvasURLKey = @"canvasURL";
static NSString *const kMomentPlaybackStateChangedNotification = @"spotifyglass.redesign.moments.playback";
static NSMutableDictionary<NSString *, NSNumber *> *sg_pendingMomentSeeks;
static __weak UIViewController *sg_momentsReturnPage;
static const NSInteger kMomentVisibleForMs = 8000;

typedef NS_ENUM(NSInteger, SGRMomentStyle) {
    SGRMomentStyleLyrics = 0,
    SGRMomentStyleCover = 1, // copertina oppure Canvas, se disponibile
    SGRMomentStyleArtist = 2,
};
static NSArray<NSDictionary<NSString *, id> *> *sg_momentsCache;
static NSMutableDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *sg_trackMomentsCache;
static BOOL sg_momentsCacheLoaded;

BOOL SGRMomentsEnabled(void) {
    return SGFlag(SGRKeyMomentsEnabled, YES);
}

static NSString *artistKey(NSDictionary<NSString *, id> *moment) {
    NSString *artistID = [moment[kMomentArtistIDKey] isKindOfClass:NSString.class] ? moment[kMomentArtistIDKey] : nil;
    NSString *artist = [moment[kMomentArtistKey] isKindOfClass:NSString.class] ? moment[kMomentArtistKey] : nil;
    return artistID.length ? artistID : artist.lowercaseString;
}

static NSArray<NSDictionary<NSString *, id> *> *storedMoments(void) {
    if (sg_momentsCacheLoaded) return sg_momentsCache ?: @[];
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kMomentsEntriesKey];
    if (!stored) {
        sg_momentsCache = @[];
        sg_momentsCacheLoaded = YES;
        return sg_momentsCache;
    }
    if (![stored isKindOfClass:NSArray.class]) {
        SGLog(@"moments: stored comments were not a list; ignoring them");
        sg_momentsCache = @[];
        sg_momentsCacheLoaded = YES;
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *valid = [NSMutableArray array];
    for (id object in (NSArray *)stored) {
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *moment = object;
        if (![moment[kMomentTrackKey] isKindOfClass:NSString.class] ||
            ![moment[kMomentArtistKey] isKindOfClass:NSString.class] ||
            ![moment[kMomentTitleKey] isKindOfClass:NSString.class] ||
            ![moment[kMomentTextKey] isKindOfClass:NSString.class] ||
            ![moment[kMomentTimeKey] isKindOfClass:NSNumber.class] ||
            ![moment[kMomentCreatedKey] isKindOfClass:NSNumber.class] ||
            ![moment[kMomentArtistKey] length] ||
            ![moment[kMomentTextKey] length] ||
            [moment[kMomentTimeKey] longLongValue] < 0) continue;
        [valid addObject:moment];
    }
    sg_momentsCache = [valid copy];
    sg_momentsCacheLoaded = YES;
    return sg_momentsCache;
}

static void invalidateMomentsCache(void) {
    sg_momentsCache = nil;
    sg_trackMomentsCache = nil;
    sg_momentsCacheLoaded = NO;
}

static NSArray<NSDictionary<NSString *, id> *> *momentsForTrack(NSString *trackID) {
    if (!trackID.length) return @[];
    NSArray *cached = sg_trackMomentsCache[trackID];
    if (cached) return cached;
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *moment in storedMoments()) {
        if ([moment[kMomentTrackKey] isEqualToString:trackID]) [matches addObject:moment];
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult timeOrder = [left[kMomentTimeKey] compare:right[kMomentTimeKey]];
        return timeOrder == NSOrderedSame ? [left[kMomentCreatedKey] compare:right[kMomentCreatedKey]] : timeOrder;
    }];
    if (!sg_trackMomentsCache) sg_trackMomentsCache = [NSMutableDictionary dictionary];
    sg_trackMomentsCache[trackID] = [matches copy];
    return sg_trackMomentsCache[trackID];
}

NSDictionary<NSString *, id> *SGRMomentAtPosition(NSString *trackID, NSInteger positionMs) {
    if (!SGRMomentsEnabled() || positionMs < 0) return nil;
    NSArray<NSDictionary<NSString *, id> *> *moments = momentsForTrack(trackID);
    NSInteger low = 0, high = (NSInteger)moments.count - 1, match = -1;
    while (low <= high) {
        NSInteger middle = low + (high - low) / 2;
        NSInteger start = [moments[(NSUInteger)middle][kMomentTimeKey] integerValue];
        if (start <= positionMs) {
            match = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    if (match < 0) return nil;
    NSDictionary *moment = moments[(NSUInteger)match];
    return positionMs - [moment[kMomentTimeKey] integerValue] <= kMomentVisibleForMs ? moment : nil;
}

static NSArray<NSDictionary<NSString *, id> *> *momentsByNewest(void) {
    NSArray<NSDictionary<NSString *, id> *> *ordered = [storedMoments() sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[kMomentCreatedKey] compare:left[kMomentCreatedKey]];
    }];
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *groups = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *byTrack = [NSMutableDictionary dictionary];
    for (NSDictionary *moment in ordered) {
        NSString *trackID = moment[kMomentTrackKey];
        NSMutableDictionary *group = byTrack[trackID];
        if (!group) {
            group = [moment mutableCopy];
            group[kMomentCommentsKey] = [NSMutableArray arrayWithObject:moment];
            byTrack[trackID] = group;
            [groups addObject:group];
        } else {
            [group[kMomentCommentsKey] addObject:moment];
        }
    }
    return [groups copy];
}

static NSArray<NSDictionary<NSString *, id> *> *momentArtists(void) {
    NSMutableArray<NSDictionary<NSString *, id> *> *artists = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *moment in momentsByNewest()) {
        NSString *key = artistKey(moment);
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [artists addObject:moment];
    }
    return artists;
}

static NSData *momentAvatarData(UIImage *image) {
    if (!image.size.width || !image.size.height) return nil;
    CGSize size = CGSizeMake(72, 72);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *thumbnail = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
        CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2,
                                     drawn.width, drawn.height)];
    }];
    return UIImageJPEGRepresentation(thumbnail, 0.68);
}

static UIImage *momentAvatar(NSDictionary<NSString *, id> *moment) {
    NSString *key = artistKey(moment);
    NSData *data = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMomentsAvatarsKey][key];
    return [data isKindOfClass:NSData.class] ? [UIImage imageWithData:data] : nil;
}

static NSString *formattedTime(NSInteger milliseconds) {
    NSInteger seconds = MAX(0, milliseconds / 1000);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static BOOL parseMomentTime(NSString *input, NSInteger *milliseconds) {
    NSString *value = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return NO;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@":"];
    if (parts.count > 2) return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSString *part in parts) {
        if (!part.length || [part rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) return NO;
    }
    NSInteger minutes = parts[0].integerValue;
    NSInteger seconds = parts.count == 2 ? parts[1].integerValue : 0;
    if (seconds > 59 || minutes > (NSIntegerMax - seconds * 1000) / 60000) return NO;
    if (milliseconds) *milliseconds = minutes * 60000 + seconds * 1000;
    return YES;
}

// MARK: - Asset locali (copertine, foto artista, testi, Canvas)
// Tutto vive in Application Support/SpotifyGlassMoments e viene richiesto una sola volta per brano/artista.

static NSURL *momentsAssetDirectory(void) {
    static NSURL *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
        directory = [base URLByAppendingPathComponent:@"SpotifyGlassMoments" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                                attributes:nil error:nil];
    });
    return directory;
}

static NSString *assetName(NSString *key) {
    NSMutableString *safe = [NSMutableString string];
    NSCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger index = 0; index < key.length && safe.length < 120; index++) {
        unichar character = [key characterAtIndex:index];
        [safe appendString:[allowed characterIsMember:character] ? [NSString stringWithCharacters:&character length:1] : @"_"];
    }
    return safe;
}

static NSURL *assetURL(NSString *name, NSString *extension) {
    return [[momentsAssetDirectory() URLByAppendingPathComponent:name] URLByAppendingPathExtension:extension];
}

static NSCache<NSString *, UIImage *> *momentImageCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 40;
    });
    return cache;
}

static UIImage *cachedMomentImage(NSString *name) {
    UIImage *image = [momentImageCache() objectForKey:name];
    if (image) return image;
    NSData *data = [NSData dataWithContentsOfURL:assetURL(name, @"jpg")];
    image = data ? [UIImage imageWithData:data] : nil;
    if (image) [momentImageCache() setObject:image forKey:name];
    return image;
}

static UIImage *scaledMomentImage(UIImage *image, CGFloat maxSide) {
    CGFloat longest = MAX(image.size.width, image.size.height);
    if (longest <= 0 || longest <= maxSide) return image;
    CGFloat scale = maxSide / longest;
    CGSize size = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
            [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
}

static void storeMomentImage(UIImage *image, NSString *name) {
    UIImage *scaled = scaledMomentImage(image, 900);
    NSData *data = UIImageJPEGRepresentation(scaled, 0.8);
    if (!data) return;
    [data writeToURL:assetURL(name, @"jpg") atomically:YES];
    [momentImageCache() setObject:scaled forKey:name];
}

// Solo dal main thread.
static NSMutableSet<NSString *> *momentPending(void) {
    static NSMutableSet<NSString *> *pending;
    if (!pending) pending = [NSMutableSet set];
    return pending;
}

static UIColor *momentAverageColor(UIImage *image) {
    if (!image.CGImage) return nil;
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    return [UIColor colorWithRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
}

static UIColor *momentTone(UIColor *base, CGFloat saturationScale, CGFloat brightness) {
    CGFloat hue = 0, saturation = 0, value = 0, alpha = 0;
    if (![base getHue:&hue saturation:&saturation brightness:&value alpha:&alpha]) return base;
    return [UIColor colorWithHue:hue saturation:MIN(1, saturation * saturationScale) brightness:brightness alpha:1];
}

// Copertina ad alta risoluzione (l'avatar da 72px resta solo come ripiego per i momenti vecchi).
static NSString *momentCoverName(NSString *trackID) {
    return [@"cover-" stringByAppendingString:assetName(trackID)];
}

static UIImage *momentCover(NSString *trackID) {
    return trackID.length ? cachedMomentImage(momentCoverName(trackID)) : nil;
}

// Foto dell'artista, scaricata dall'oEmbed pubblico di Spotify (nessun token necessario).
static NSString *momentArtistAssetName(NSDictionary<NSString *, id> *moment) {
    return [@"artist-" stringByAppendingString:assetName(artistKey(moment))];
}

static UIImage *momentArtistPhoto(NSDictionary<NSString *, id> *moment) {
    return cachedMomentImage(momentArtistAssetName(moment));
}

static UIImage *momentPortrait(NSDictionary<NSString *, id> *moment) {
    return momentArtistPhoto(moment) ?: momentAvatar(moment);
}

static UIImage *momentUserAvatar(void) {
    NSData *stored = [NSUserDefaults.standardUserDefaults objectForKey:kMomentsUserAvatarKey];
    return [stored isKindOfClass:NSData.class] ? [UIImage imageWithData:stored] : nil;
}

static void findAvatarImage(UIView *view, UIImage **bestImage, CGFloat *bestArea) {
    if (view.hidden || view.alpha <= 0.01) return;
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        CGFloat area = CGRectGetWidth(imageView.bounds) * CGRectGetHeight(imageView.bounds);
        if (imageView.image && area > *bestArea) {
            *bestImage = imageView.image;
            *bestArea = area;
        }
    }
    for (UIView *child in view.subviews) findAvatarImage(child, bestImage, bestArea);
}

static UIImage *captureUserAvatar(void) {
    UIImage *stored = momentUserAvatar();
    if (stored) return stored;
    static char kUserAvatarViewKey;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *avatar = SGRFindByIdentifier(window, @"Components.UI.SideDrawerButton", &kUserAvatarViewKey);
            if (!avatar) continue;
            UIImage *image = nil;
            CGFloat area = 0;
            findAvatarImage(avatar, &image, &area);
            NSData *data = image ? momentAvatarData(image) : nil;
            if (data) {
                [NSUserDefaults.standardUserDefaults setObject:data forKey:kMomentsUserAvatarKey];
                return image;
            }
        }
    }
    return nil;
}

static void ensureArtistPhoto(NSDictionary<NSString *, id> *moment) {
    NSString *artistID = [moment[kMomentArtistIDKey] isKindOfClass:NSString.class] ? moment[kMomentArtistIDKey] : nil;
    if (!artistID.length || momentArtistPhoto(moment)) return;
    NSString *name = momentArtistAssetName(moment);
    if ([momentPending() containsObject:name]) return; // in corso, o già fallito in questa sessione

    NSString *identifier = artistID;
    NSRange query = [identifier rangeOfString:@"?"];
    if (query.location != NSNotFound) identifier = [identifier substringToIndex:query.location];
    identifier = [[identifier componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":/"]] lastObject];
    if (identifier.length < 10) return;

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://open.spotify.com/oembed"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"url"
        value:[@"https://open.spotify.com/artist/" stringByAppendingString:identifier]]];
    NSURL *url = components.URL;
    if (!url) return;
    [momentPending() addObject:name];

    NSURLSession *session = NSURLSession.sharedSession;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *thumbnail = [json isKindOfClass:NSDictionary.class] && [json[@"thumbnail_url"] isKindOfClass:NSString.class]
            ? json[@"thumbnail_url"] : nil;
        NSURL *thumbnailURL = thumbnail.length ? [NSURL URLWithString:thumbnail] : nil;
        if (!thumbnailURL) {
            SGLog(@"moments: no artist photo for %@ (%@)", identifier, error.localizedDescription ?: @"no thumbnail");
            return;
        }
        [[session dataTaskWithURL:thumbnailURL completionHandler:^(NSData *imageData, NSURLResponse *imageResponse, NSError *imageError) {
            (void)imageResponse;
            (void)imageError;
            UIImage *image = imageData ? [UIImage imageWithData:imageData] : nil;
            if (!image) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                storeMomentImage(image, name);
                [NSNotificationCenter.defaultCenter postNotificationName:kMomentsAssetsChangedNotification object:nil];
            });
        }] resume];
    }] resume];
}

// Testi sincronizzati da lrclib.net (gratuito, senza chiave). Salvati su disco come [{t: ms, s: riga}].
static NSMutableDictionary<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *sg_lyricsCache;
static NSMutableSet<NSString *> *sg_lyricsFailed;

static NSArray<NSDictionary<NSString *, id> *> *momentLyrics(NSString *trackID) {
    if (!trackID.length) return nil;
    if (!sg_lyricsCache) sg_lyricsCache = [NSMutableDictionary dictionary];
    NSArray *cached = sg_lyricsCache[trackID];
    if (cached) return cached;
    NSData *data = [NSData dataWithContentsOfURL:assetURL([@"lyrics-" stringByAppendingString:assetName(trackID)], @"json")];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSArray.class] || ![(NSArray *)json count]) return nil;
    sg_lyricsCache[trackID] = json;
    return json;
}

static BOOL momentLyricsFailed(NSString *trackID) {
    return [sg_lyricsFailed containsObject:trackID];
}

static NSArray<NSDictionary<NSString *, id> *> *parseSyncedLyrics(NSString *lrc) {
    static NSRegularExpression *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d+):(\\d{2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
    });
    NSMutableArray<NSDictionary<NSString *, id> *> *lines = [NSMutableArray array];
    for (NSString *raw in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSTextCheckingResult *> *matches = [stamp matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (!matches.count) continue;
        NSString *text = [[raw substringFromIndex:NSMaxRange(matches.lastObject.range)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!text.length) continue;
        for (NSTextCheckingResult *match in matches) {
            NSInteger minutes = [raw substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger seconds = [raw substringWithRange:[match rangeAtIndex:2]].integerValue;
            NSString *fraction = [match rangeAtIndex:3].location != NSNotFound ? [raw substringWithRange:[match rangeAtIndex:3]] : @"0";
            NSInteger fractionMs = fraction.integerValue * (fraction.length == 1 ? 100 : fraction.length == 2 ? 10 : 1);
            [lines addObject:@{@"t": @(minutes * 60000 + seconds * 1000 + fractionMs), @"s": text}];
        }
    }
    [lines sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"t"] compare:right[@"t"]];
    }];
    return lines;
}

static NSString *syncedLyricsFromJSON(id json) {
    NSArray *candidates = [json isKindOfClass:NSArray.class] ? json : (json ? @[json] : @[]);
    for (id candidate in candidates) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSString *synced = candidate[@"syncedLyrics"];
        if ([synced isKindOfClass:NSString.class] && synced.length) return synced;
    }
    return nil;
}

static void requestSyncedLyrics(NSString *path, NSString *artist, NSString *title, void (^completion)(NSString *synced)) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"https://lrclib.net/api/" stringByAppendingString:path]];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"artist_name" value:artist],
                              [NSURLQueryItem queryItemWithName:@"track_name" value:title]];
    if (!components.URL) { completion(nil); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = 15;
    [request setValue:@"SpotifyGlass/1.0" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        (void)error;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion(syncedLyricsFromJSON(json));
    }] resume];
}

static void ensureLyrics(NSDictionary<NSString *, id> *moment) {
    NSString *trackID = moment[kMomentTrackKey];
    if (!trackID.length || momentLyrics(trackID)) return;
    NSString *pendingKey = [@"lyrics-" stringByAppendingString:trackID];
    if ([momentPending() containsObject:pendingKey]) return;
    [momentPending() addObject:pendingKey];
    NSString *artist = [[[moment[kMomentArtistKey] componentsSeparatedByString:@","] firstObject]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *title = moment[kMomentTitleKey];

    void (^finish)(NSString *) = ^(NSString *synced) {
        NSArray *lines = synced.length ? parseSyncedLyrics(synced) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (lines.count) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:lines options:0 error:nil];
                [data writeToURL:assetURL([@"lyrics-" stringByAppendingString:assetName(trackID)], @"json") atomically:YES];
                if (!sg_lyricsCache) sg_lyricsCache = [NSMutableDictionary dictionary];
                sg_lyricsCache[trackID] = lines;
            } else {
                if (!sg_lyricsFailed) sg_lyricsFailed = [NSMutableSet set];
                [sg_lyricsFailed addObject:trackID];
                SGLog(@"moments: no synced lyrics found for %@", title);
            }
            [NSNotificationCenter.defaultCenter postNotificationName:kMomentsAssetsChangedNotification object:nil];
        });
    };
    requestSyncedLyrics(@"get", artist, title, ^(NSString *synced) {
        if (synced.length) { finish(synced); return; }
        requestSyncedLyrics(@"search", artist, title, finish);
    });
}

// Canvas: il tweak non conosce l'URL del video, quindi lo "ascolta". Quando Spotify crea un asset video
// per il Canvas (file *.cnvs.mp4 su canvaz.scdn.co) lo associo al brano in riproduzione e lo scarico.
// Per i brani che hanno già dei momenti il video viene salvato appena Spotify lo carica (basta riascoltarli).
static NSMutableDictionary<NSString *, NSURL *> *sg_canvasURLs;

static NSURL *momentCanvasFile(NSString *trackID) {
    if (!trackID.length) return nil;
    NSURL *file = assetURL([@"canvas-" stringByAppendingString:assetName(trackID)], @"mp4");
    return [NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil;
}

static void cacheCanvasURL(NSString *trackID, NSURL *source) {
    if (!trackID.length || !source || momentCanvasFile(trackID)) return;
    NSString *pendingKey = [@"canvas-" stringByAppendingString:trackID];
    if ([momentPending() containsObject:pendingKey]) return;
    [momentPending() addObject:pendingKey];
    NSURL *destination = assetURL([@"canvas-" stringByAppendingString:assetName(trackID)], @"mp4");
    void (^finish)(BOOL) = ^(BOOL stored) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (stored) {
                SGLog(@"moments: canvas saved for %@", trackID);
                [NSNotificationCenter.defaultCenter postNotificationName:kMomentsAssetsChangedNotification object:nil];
            } else {
                [momentPending() removeObject:pendingKey]; // riprova al prossimo ascolto
            }
        });
    };
    if (source.isFileURL) {
        [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
        finish([NSFileManager.defaultManager copyItemAtURL:source toURL:destination error:nil]);
        return;
    }
    [[NSURLSession.sharedSession downloadTaskWithURL:source completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        (void)response;
        BOOL stored = NO;
        if (location && !error) {
            [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
            stored = [NSFileManager.defaultManager moveItemAtURL:location toURL:destination error:nil];
        }
        finish(stored);
    }] resume];
}

// Chiamata al salvataggio di un momento: se il Canvas del brano è già stato visto lo scarica.
static void cacheCanvas(NSString *trackID) {
    NSURL *url = sg_canvasURLs[trackID];
    if (url) cacheCanvasURL(trackID, url);
}

static void saveMomentCanvasMetadata(NSDictionary<NSString *, id> *moment, SGCanvas *canvas) {
    if (!canvas.video || !canvas.address.length) return;
    NSMutableArray *all = [storedMoments() mutableCopy];
    NSNumber *created = moment[kMomentCreatedKey];
    NSString *trackID = moment[kMomentTrackKey];
    for (NSUInteger index = 0; index < all.count; index++) {
        NSDictionary *entry = all[index];
        if (![entry[kMomentTrackKey] isEqualToString:trackID] ||
            [entry[kMomentCreatedKey] doubleValue] != created.doubleValue) continue;
        NSMutableDictionary *updated = [entry mutableCopy];
        updated[kMomentCanvasIDKey] = canvas.identifier ?: @"";
        updated[kMomentCanvasURLKey] = canvas.address;
        all[index] = updated;
        [NSUserDefaults.standardUserDefaults setObject:all forKey:kMomentsEntriesKey];
        invalidateMomentsCache();
        [NSNotificationCenter.defaultCenter postNotificationName:kMomentsAssetsChangedNotification object:nil];
        return;
    }
}

static void fetchMomentCanvas(NSDictionary<NSString *, id> *moment, SGCanvas *canvas) {
    NSString *trackID = moment[kMomentTrackKey];
    if (!trackID.length || !canvas.video || !canvas.address.length || momentCanvasFile(trackID)) return;
    NSString *pendingKey = [@"canvas-" stringByAppendingString:trackID];
    if ([momentPending() containsObject:pendingKey]) return;
    [momentPending() addObject:pendingKey];
    saveMomentCanvasMetadata(moment, canvas);
    SGArtworkFetchAside(canvas.identifier, canvas.address, ^(NSURL *file, NSString *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [momentPending() removeObject:pendingKey];
            if (!file) {
                SGLog(@"moments: canvas fetch failed for %@ (%@)", trackID, note);
                return;
            }
            cacheCanvasURL(trackID, file);
        });
    });
}

static NSString *momentIDFromURI(id value) {
    NSString *uri = SGURIString(value);
    NSString *prefix = @"spotify:track:";
    return [uri hasPrefix:prefix] ? [uri substringFromIndex:prefix.length] : nil;
}

static void ensureMomentCanvas(NSDictionary<NSString *, id> *moment) {
    NSString *trackID = moment[kMomentTrackKey];
    if (!SGRMomentsEnabled() || !trackID.length || momentCanvasFile(trackID)) return;

    NSString *address = [moment[kMomentCanvasURLKey] isKindOfClass:NSString.class] ? moment[kMomentCanvasURLKey] : nil;
    if (address.length) {
        SGCanvas *canvas = [SGCanvas new];
        canvas.identifier = [moment[kMomentCanvasIDKey] isKindOfClass:NSString.class] ? moment[kMomentCanvasIDKey] : nil;
        canvas.address = address;
        canvas.video = YES;
        fetchMomentCanvas(moment, canvas);
        return;
    }

    SPTPlayerTrack *track = SGKaraokeTrackFor(trackID);
    if (!track && [momentIDFromURI(SGPlayerState().track.URI) isEqualToString:trackID]) track = SGPlayerState().track;
    if (!track) return;
    NSString *pendingKey = [@"canvas-" stringByAppendingString:trackID];
    if ([momentPending() containsObject:pendingKey]) return;
    [momentPending() addObject:pendingKey];
    SGCanvas *metadataCanvas = SGCanvasFromMetadata(track.metadata);
    SGArtworkAsk(SGArtworkSourceSpotify, track, metadataCanvas, NO, ^(SGCanvas *canvas, NSString *note) {
        [momentPending() removeObject:pendingKey];
        if (!canvas.video) {
            SGLog(@"moments: no Spotify Canvas for %@ (%@)", trackID, note);
            return;
        }
        saveMomentCanvasMetadata(moment, canvas);
        fetchMomentCanvas(moment, canvas);
    });
}

@interface SGRMomentCanvasObserver : NSObject <SGPlayerStateObserver>
@end

@implementation SGRMomentCanvasObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *trackID = momentIDFromURI(state.track.URI);
    NSNumber *pendingSeek = trackID.length ? sg_pendingMomentSeeks[trackID] : nil;
    if (pendingSeek) {
        [sg_pendingMomentSeeks removeObjectForKey:trackID];
        SGKaraokeSeek(pendingSeek.integerValue);
    }
    if (!trackID.length || !momentsForTrack(trackID).count) return;
    for (NSDictionary *moment in momentsForTrack(trackID)) ensureMomentCanvas(moment);
}
@end

static SGRMomentCanvasObserver *sg_momentCanvasObserver;

static void observeMomentCanvasPlayback(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_momentCanvasObserver = [SGRMomentCanvasObserver new];
        SGAddPlayerStateObserver(sg_momentCanvasObserver);
    });
}

static void noteMediaURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return;
    NSString *extension = url.pathExtension.lowercaseString;
    if (![@[@"mp4", @"m4v", @"mov"] containsObject:extension]) return;
    NSString *lower = url.absoluteString.lowercaseString;
    BOOL canvas = [lower containsString:@"canvaz"] || [lower containsString:@"cnvs"] || [lower containsString:@"canvas"];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SGRMomentsEnabled()) return;
        SGLog(@"moments: video asset %@ (canvas: %d)", url, canvas);
        if (!canvas) return;
        // Il brano corrente si aggiorna pochi istanti dopo l'inizio del Canvas: aspetto prima di associarli.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *trackID = SGKaraokePlayingTrack();
            if (!trackID.length) return;
            if (!sg_canvasURLs) sg_canvasURLs = [NSMutableDictionary dictionary];
            sg_canvasURLs[trackID] = url;
            if (momentsForTrack(trackID).count) cacheCanvasURL(trackID, url);
        });
    });
}

static IMP sg_assetInitOriginal;
static IMP sg_itemInitOriginal;

static id sg_assetInitHook(id self, SEL _cmd, NSURL *URL, NSDictionary *options) {
    noteMediaURL(URL);
    return ((id (*)(id, SEL, NSURL *, NSDictionary *))sg_assetInitOriginal)(self, _cmd, URL, options);
}

static id sg_itemInitHook(id self, SEL _cmd, NSURL *URL) {
    noteMediaURL(URL);
    return ((id (*)(id, SEL, NSURL *))sg_itemInitOriginal)(self, _cmd, URL);
}

__attribute__((constructor)) static void installMomentsCanvasHooks(void) {
    Method asset = class_getInstanceMethod(AVURLAsset.class, @selector(initWithURL:options:));
    if (asset && !sg_assetInitOriginal) sg_assetInitOriginal = method_setImplementation(asset, (IMP)sg_assetInitHook);
    Method item = class_getInstanceMethod(AVPlayerItem.class, @selector(initWithURL:));
    if (item && !sg_itemInitOriginal) sg_itemInitOriginal = method_setImplementation(item, (IMP)sg_itemInitHook);
}

// Stile di visualizzazione scelto per ogni momento (testi / copertina-Canvas / foto artista).
static NSString *momentIdentifier(NSDictionary<NSString *, id> *moment) {
    return [NSString stringWithFormat:@"%.3f", [moment[kMomentCreatedKey] doubleValue]];
}

static NSInteger momentStyle(NSDictionary<NSString *, id> *moment) {
    NSNumber *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMomentStylesKey][momentIdentifier(moment)];
    NSInteger style = [stored isKindOfClass:NSNumber.class] ? stored.integerValue : SGRMomentStyleCover;
    return style >= SGRMomentStyleLyrics && style <= SGRMomentStyleArtist ? style : SGRMomentStyleCover;
}

static void setMomentStyle(NSDictionary<NSString *, id> *moment, NSInteger style) {
    NSMutableDictionary *styles = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kMomentStylesKey] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    styles[momentIdentifier(moment)] = @(style);
    [NSUserDefaults.standardUserDefaults setObject:styles forKey:kMomentStylesKey];
}

static void forgetMomentStyle(NSDictionary<NSString *, id> *moment) {
    NSMutableDictionary *styles = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kMomentStylesKey] mutableCopy];
    if (!styles) return;
    NSArray *comments = moment[kMomentCommentsKey];
    if (![comments isKindOfClass:NSArray.class]) comments = @[moment];
    for (NSDictionary *comment in comments) [styles removeObjectForKey:momentIdentifier(comment)];
    [NSUserDefaults.standardUserDefaults setObject:styles forKey:kMomentStylesKey];
}

static void playMomentTrackAtPosition(NSDictionary<NSString *, id> *moment, NSInteger positionMs,
                                     UIViewController *returnPage) {
    NSString *trackID = moment[kMomentTrackKey];
    if (!trackID.length) return;
    NSString *uri = [trackID hasPrefix:@"spotify:"] ? trackID : [@"spotify:track:" stringByAppendingString:trackID];
    SPTPlayerState *state = SGPlayerState();
    NSString *currentURI = SGURIString(state.track.URI);
    if ([currentURI isEqualToString:uri]) {
        if (positionMs >= 0) {
            SGKaraokeSeek(positionMs);
            if (!state.isPlaying || state.isPaused) {
                id<SPTPlayer> player = SGKaraokePlayer();
                if ([player respondsToSelector:@selector(resume:)]) [player resume:nil];
            }
            return;
        }
        id<SPTPlayer> player = SGKaraokePlayer();
        if (![player respondsToSelector:@selector(pause:)] || ![player respondsToSelector:@selector(resume:)]) {
            SGLog(@"moments: player cannot toggle playback for %@", uri);
            return;
        }
        id result = state.isPlaying && !state.isPaused ? [player pause:nil] : [player resume:nil];
        SGLog(@"moments: %@ %@ -> %@", state.isPlaying && !state.isPaused ? @"pause" : @"resume", uri, result);
        [NSNotificationCenter.defaultCenter postNotificationName:kMomentPlaybackStateChangedNotification object:nil];
        return;
    }
    if (positionMs >= 0) {
        if (!sg_pendingMomentSeeks) sg_pendingMomentSeeks = [NSMutableDictionary dictionary];
        sg_pendingMomentSeeks[trackID] = @(positionMs);
    }
    sg_momentsReturnPage = returnPage;
    NSURL *url = [NSURL URLWithString:uri];
    if (!url) {
        [sg_pendingMomentSeeks removeObjectForKey:trackID];
        sg_momentsReturnPage = nil;
        SGLog(@"moments: invalid track URI %@", uri);
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SGLog(@"moments: play %@ via UIApplication, success: %d", uri, success);
            if (!success) {
                [sg_pendingMomentSeeks removeObjectForKey:trackID];
                sg_momentsReturnPage = nil;
                SGLog(@"moments: Spotify did not accept the track URI %@", uri);
                return;
            }
            [NSNotificationCenter.defaultCenter postNotificationName:kMomentPlaybackStateChangedNotification object:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *page = returnPage;
                if (sg_momentsReturnPage != page) return;
                UINavigationController *navigation = page.navigationController;
                if (navigation && [navigation.viewControllers containsObject:page] &&
                    navigation.topViewController != page) {
                    [navigation popToViewController:page animated:NO];
                } else if (page.presentedViewController) {
                    [page.presentedViewController dismissViewControllerAnimated:NO completion:nil];
                }
                sg_momentsReturnPage = nil;
            });
        });
    }];
}

static void playMomentTrack(NSDictionary<NSString *, id> *moment, UIViewController *returnPage) {
    playMomentTrackAtPosition(moment, -1, returnPage);
}

@interface SGRMomentProgressTrackView : UIView
@end

@implementation SGRMomentProgressTrackView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -18), point);
}
@end

@interface SGRMomentBubbleView ()
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) CAShapeLayer *bubbleLayer;
@end

@implementation SGRMomentBubbleView

- (instancetype)initWithText:(NSString *)text {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;
    self.accessibilityLabel = [NSString stringWithFormat:@"Il tuo commento: %@", text];
    _bubbleLayer = [CAShapeLayer layer];
    _bubbleLayer.fillColor = [UIColor colorWithWhite:0.08 alpha:0.94].CGColor;
    _bubbleLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _bubbleLayer.lineWidth = 1;
    [self.layer addSublayer:_bubbleLayer];

    _messageLabel = [UILabel new];
    _messageLabel.text = text;
    _messageLabel.numberOfLines = 3;
    _messageLabel.textColor = UIColor.whiteColor;
    _messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _messageLabel.adjustsFontForContentSizeCategory = YES;
    [self addSubview:_messageLabel];
    return self;
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat width = MAX(0, size.width - 32);
    CGSize text = [_messageLabel sizeThatFits:CGSizeMake(width, 72)];
    return CGSizeMake(MIN(size.width, ceil(text.width) + 32), MIN(82, ceil(text.height) + 22));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect body = CGRectMake(0.5, 0.5, MAX(0, self.bounds.size.width - 1), MAX(0, self.bounds.size.height - 8));
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:17];
    CGFloat tailX = 25;
    [path moveToPoint:CGPointMake(tailX, CGRectGetMaxY(body) - 1)];
    [path addLineToPoint:CGPointMake(tailX + 8, CGRectGetMaxY(body) - 1)];
    [path addLineToPoint:CGPointMake(tailX + 3, CGRectGetMaxY(body) + 7)];
    [path closePath];
    _bubbleLayer.frame = self.bounds;
    _bubbleLayer.path = path.CGPath;
    _messageLabel.frame = CGRectInset(body, 16, 8);
}

@end

@interface SGRMomentComposerController : UIViewController <UITextViewDelegate, UITextFieldDelegate>
- (instancetype)initWithState:(SPTPlayerState *)state;
- (void)refreshSave;
@end

@implementation SGRMomentComposerController {
    SPTPlayerState *_state;
    NSString *_trackID;
    UITextView *_comment;
    UILabel *_placeholder;
    UITextField *_time;
    UILabel *_error;
    UIBarButtonItem *_save;
}

- (instancetype)initWithState:(SPTPlayerState *)state {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _state = state;
    _trackID = SGKaraokePlayingTrack();
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Nuovo momento";
    self.view.backgroundColor = SGRNeutralField();
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Annulla"
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    _save = [[UIBarButtonItem alloc] initWithTitle:@"Salva" style:UIBarButtonItemStyleDone
        target:self action:@selector(save)];
    self.navigationItem.rightBarButtonItem = _save;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    UILabel *track = [UILabel new];
    track.text = [NSString stringWithFormat:@"%@\n%@", _state.track.trackTitle ?: @"Brano in riproduzione",
                  _state.track.artistName ?: @""];
    track.numberOfLines = 2;
    track.textColor = SGRSecondary();
    track.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightMedium, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    [stack addArrangedSubview:track];

    UILabel *commentTitle = [UILabel new];
    commentTitle.text = @"Il tuo commento";
    commentTitle.textColor = SGRPrimary();
    commentTitle.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightSemibold, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    [stack addArrangedSubview:commentTitle];

    UIView *commentCard = [UIView new];
    commentCard.backgroundColor = SGRElevated(UIColor.blackColor);
    commentCard.layer.cornerRadius = 18;
    commentCard.layer.cornerCurve = kCACornerCurveContinuous;
    _comment = [UITextView new];
    _comment.translatesAutoresizingMaskIntoConstraints = NO;
    _comment.backgroundColor = UIColor.clearColor;
    _comment.textColor = SGRPrimary();
    _comment.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    _comment.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    _comment.delegate = self;
    _comment.accessibilityLabel = @"Il tuo commento";
    _placeholder = [UILabel new];
    _placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    _placeholder.text = @"Scrivi una frase da ritrovare durante il brano";
    _placeholder.textColor = SGRTertiary();
    _placeholder.font = _comment.font;
    _placeholder.numberOfLines = 2;
    _placeholder.userInteractionEnabled = NO;
    [commentCard addSubview:_comment];
    [commentCard addSubview:_placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [_comment.leadingAnchor constraintEqualToAnchor:commentCard.leadingAnchor],
        [_comment.trailingAnchor constraintEqualToAnchor:commentCard.trailingAnchor],
        [_comment.topAnchor constraintEqualToAnchor:commentCard.topAnchor],
        [_comment.bottomAnchor constraintEqualToAnchor:commentCard.bottomAnchor],
        [_comment.heightAnchor constraintGreaterThanOrEqualToConstant:108],
        [_placeholder.leadingAnchor constraintEqualToAnchor:commentCard.leadingAnchor constant:18],
        [_placeholder.trailingAnchor constraintLessThanOrEqualToAnchor:commentCard.trailingAnchor constant:-18],
        [_placeholder.topAnchor constraintEqualToAnchor:commentCard.topAnchor constant:19],
    ]];
    [stack addArrangedSubview:commentCard];

    UILabel *timeTitle = [UILabel new];
    timeTitle.text = @"Minuto della canzone";
    timeTitle.textColor = SGRPrimary();
    timeTitle.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightSemibold, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    [stack addArrangedSubview:timeTitle];

    _time = [UITextField new];
    _time.backgroundColor = SGRElevated(UIColor.blackColor);
    _time.textColor = SGRPrimary();
    _time.tintColor = SGRAccent();
    _time.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    _time.borderStyle = UITextBorderStyleNone;
    _time.layer.cornerRadius = 14;
    _time.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    _time.leftViewMode = UITextFieldViewModeAlways;
    _time.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _time.placeholder = @"m:ss";
    _time.accessibilityLabel = @"Minuto della canzone, minuti e secondi";
    _time.delegate = self;
    NSInteger position = SGKaraokePositionMs();
    _time.text = formattedTime(position >= 0 ? position : (NSInteger)(_state.position * 1000));
    [stack addArrangedSubview:_time];
    [_time.heightAnchor constraintEqualToConstant:52].active = YES;

    _error = [UILabel new];
    _error.textColor = [UIColor systemRedColor];
    _error.font = SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    _error.numberOfLines = 0;
    _error.text = @"Il commento e il minuto restano solo su questo dispositivo.";
    [stack addArrangedSubview:_error];

    [self refreshSave];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshSave {
    NSInteger timestamp = 0;
    BOOL validTime = parseMomentTime(_time.text ?: @"", &timestamp);
    BOOL withinTrack = _state.duration <= 0 || timestamp <= (NSInteger)(_state.duration * 1000);
    NSString *comment = [_comment.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _save.enabled = comment.length > 0 && validTime && withinTrack;
    if (!validTime) {
        _error.textColor = UIColor.systemRedColor;
        _error.text = @"Usa il formato minuti:secondi, per esempio 1:24.";
    } else if (!withinTrack) {
        _error.textColor = UIColor.systemRedColor;
        _error.text = @"Il minuto inserito supera la durata del brano.";
    } else {
        _error.textColor = SGRSecondary();
        _error.text = @"Il commento e il minuto restano solo su questo dispositivo.";
    }
}

- (void)textViewDidChange:(UITextView *)textView {
    _placeholder.hidden = textView.text.length > 0;
    [self refreshSave];
}

- (void)textFieldDidChangeSelection:(UITextField *)textField {
    (void)textField;
    [self refreshSave];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    (void)textField;
    NSString *updated = [_time.text stringByReplacingCharactersInRange:range withString:string];
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshSave]; });
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789:"];
    if ([updated rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    if ([[updated componentsSeparatedByString:@":"] count] > 2) return NO;
    return YES;
}

- (void)save {
    NSString *text = [_comment.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger timestamp = 0;
    if (!text.length || !parseMomentTime(_time.text ?: @"", &timestamp) ||
        (_state.duration > 0 && timestamp > (NSInteger)(_state.duration * 1000))) {
        [self refreshSave];
        return;
    }
    if (!_trackID.length) {
        _error.text = @"Spotify non ha ancora identificato il brano. Chiudi e riprova.";
        _error.textColor = UIColor.systemRedColor;
        _save.enabled = NO;
        return;
    }

    NSString *artist = _state.track.artistName ?: @"Artista";
    NSString *artistID = SGURIString(_state.track.artistURI);
    NSMutableDictionary *moment = [@{
        kMomentTrackKey: _trackID,
        kMomentTitleKey: _state.track.trackTitle ?: @"Brano",
        kMomentArtistKey: artist,
        kMomentTextKey: text,
        kMomentTimeKey: @(timestamp),
        kMomentCreatedKey: @([NSDate date].timeIntervalSince1970),
    } mutableCopy];
    if (artistID.length) moment[kMomentArtistIDKey] = artistID;
    if (_state.duration > 0) moment[kMomentDurationKey] = @((NSInteger)(_state.duration * 1000));
    SGCanvas *canvas = SGCanvasFromMetadata(_state.track.metadata);
    if (canvas.video) {
        moment[kMomentCanvasIDKey] = canvas.identifier ?: @"";
        moment[kMomentCanvasURLKey] = canvas.address;
    }
    captureUserAvatar();
    NSString *profileKey = artistID.length ? artistID : artist.lowercaseString;
    NSString *artworkURI = nil;
    UIImage *artwork = SGRNowPlayingArtwork(&artworkURI, NULL);
    if (artwork && [artworkURI isEqualToString:SGURIString(_state.track.URI)]) {
        if (!momentCover(_trackID)) storeMomentImage(artwork, momentCoverName(_trackID));
        NSData *avatar = momentAvatarData(artwork);
        if (avatar) {
            NSMutableDictionary *avatars = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kMomentsAvatarsKey] mutableCopy]
                ?: [NSMutableDictionary dictionary];
            if (!avatars[profileKey]) avatars[profileKey] = avatar;
            [NSUserDefaults.standardUserDefaults setObject:avatars forKey:kMomentsAvatarsKey];
        }
    }
    NSMutableArray *all = [storedMoments() mutableCopy];
    [all addObject:moment];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:kMomentsEntriesKey];
    ensureArtistPhoto(moment);
    ensureLyrics(moment);
    cacheCanvas(_trackID);
    ensureMomentCanvas(moment);
    invalidateMomentsCache();
    [NSNotificationCenter.defaultCenter postNotificationName:@"spotifyglass.redesign.moments.changed" object:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

void SGRPresentMomentComposer(UIView *source) {
    if (!SGRMomentsEnabled()) return;
    SPTPlayerState *state = SGPlayerState();
    if (!state.track) {
        SGLog(@"moments: comment composer requested without a current track");
        return;
    }
    UIViewController *presenter = SGTopController();
    if (!presenter || presenter.presentedViewController) {
        SGLog(@"moments: comment composer could not find a free presenter");
        return;
    }
    (void)source;
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:[[SGRMomentComposerController alloc] initWithState:state]];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [presenter presentViewController:navigation animated:YES completion:nil];
}

// MARK: - Moments page
// Come "Latest Moments" di Apple Music: una riga di avatar tondi in alto (più "Tutti"), poi una grande card
// per ogni commento. Sulla card: il commento in una nuvoletta sopra il miniplayer (play + scelta dello stile).
// Tre stili per card: testi sincronizzati (scrollabili), copertina/Canvas, foto dell'artista.

static const CGFloat kMomentAvatarSize = 78;
static const CGFloat kMomentAvatarColumn = 90;
static const CGFloat kMomentAvatarRowHeight = 106;
static const CGFloat kMomentHeaderTitleHeight = 52;
static const CGFloat kMomentCardAspect = 1.4; // altezza / larghezza, come nello screenshot
static const CGFloat kMomentPanelHeight = 120;
static const CGFloat kMomentLyricsParagraphSpacing = 14;

static UIColor *momentHue(NSString *artist, CGFloat saturation, CGFloat brightness) {
    return [UIColor colorWithHue:(artist.hash % 360) / 360.0 saturation:saturation brightness:brightness alpha:1];
}

// Tutto il testo del brano: la riga del momento è bianca, le altre sbiadite. Restituisce anche dove
// inizia la riga corrente, per far partire lo scroll da lì.
static NSAttributedString *momentLyricsText(NSArray<NSDictionary<NSString *, id> *> *lines, NSInteger position,
                                            NSUInteger *currentLocation) {
    NSInteger current = -1;
    for (NSUInteger index = 0; index < lines.count; index++) {
        if ([lines[index][@"t"] integerValue] <= position) current = (NSInteger)index;
        else break;
    }
    UIFont *font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineSpacing = 3;
    paragraph.paragraphSpacing = kMomentLyricsParagraphSpacing;

    NSMutableAttributedString *result = [NSMutableAttributedString new];
    for (NSInteger index = 0; index < (NSInteger)lines.count; index++) {
        CGFloat alpha = current < 0 ? 0.5 : (index < current ? 0.32 : (index == current ? 1 : 0.5));
        if (index == MAX(current, 0) && currentLocation) *currentLocation = result.length;
        NSString *text = lines[(NSUInteger)index][@"s"];
        if (index + 1 < (NSInteger)lines.count) text = [text stringByAppendingString:@"\n"];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:alpha],
            NSParagraphStyleAttributeName: paragraph,
        }]];
    }
    return result;
}

@interface SGRMomentArtistButton : UIControl
@property (nonatomic, copy) NSString *filterKey; // nil mostra tutti gli artisti
- (instancetype)initWithMoment:(NSDictionary<NSString *, id> *)moment selected:(BOOL)selected;
@end

@implementation SGRMomentArtistButton {
    UIView *_circle;
    UILabel *_initials;
    UIImageView *_avatar;
    UIImageView *_allGlyph;
    UIView *_dot;
}

- (instancetype)initWithMoment:(NSDictionary<NSString *, id> *)moment selected:(BOOL)selected {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    NSString *artist = moment[kMomentArtistKey];

    _circle = [UIView new];
    _circle.userInteractionEnabled = NO;
    _circle.clipsToBounds = YES;
    _circle.layer.cornerRadius = kMomentAvatarSize / 2;
    _circle.layer.borderWidth = selected ? 2.5 : 0;
    _circle.layer.borderColor = SGRPrimary().CGColor;
    _circle.backgroundColor = moment ? momentHue(artist, 0.46, 0.48) : [UIColor colorWithWhite:1 alpha:0.14];
    _circle.alpha = selected ? 1 : 0.5;
    [self addSubview:_circle];

    if (moment) {
        NSArray<NSString *> *parts = [artist componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableString *initials = [NSMutableString string];
        for (NSString *part in parts) {
            if (!part.length) continue;
            [initials appendString:[[part substringToIndex:1] uppercaseString]];
            if (initials.length == 2) break;
        }
        _initials = [UILabel new];
        _initials.text = initials.length ? initials : @"♫";
        _initials.textAlignment = NSTextAlignmentCenter;
        _initials.textColor = UIColor.whiteColor;
        _initials.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        [_circle addSubview:_initials];
        UIImage *image = momentPortrait(moment);
        if (image) {
            _avatar = [[UIImageView alloc] initWithImage:image];
            _avatar.contentMode = UIViewContentModeScaleAspectFill;
            [_circle addSubview:_avatar];
        }
    } else {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightSemibold];
        _allGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.stack.fill"
                                                               withConfiguration:configuration]];
        _allGlyph.tintColor = UIColor.whiteColor;
        _allGlyph.contentMode = UIViewContentModeCenter;
        [_circle addSubview:_allGlyph];
    }

    _dot = [UIView new];
    _dot.userInteractionEnabled = NO;
    _dot.backgroundColor = selected ? SGRPrimary() : SGRAccent();
    _dot.layer.cornerRadius = 3;
    [self addSubview:_dot];

    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = moment ? [NSString stringWithFormat:@"Mostra i momenti di %@", artist]
                                     : @"Mostra tutti i momenti";
    self.accessibilityValue = selected ? @"Selezionato" : nil;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _circle.frame = CGRectMake((width - kMomentAvatarSize) / 2, 0, kMomentAvatarSize, kMomentAvatarSize);
    _initials.frame = _circle.bounds;
    _avatar.frame = _circle.bounds;
    _allGlyph.frame = _circle.bounds;
    _dot.frame = CGRectMake((width - 6) / 2, kMomentAvatarSize + 14, 6, 6);
}

@end

@interface SGRMomentCell : UITableViewCell <UIGestureRecognizerDelegate>
@property (nonatomic, copy) void (^playHandler)(void);
@property (nonatomic, copy) void (^commentHandler)(NSInteger positionMs);
@property (nonatomic, copy) void (^styleHandler)(NSInteger style);
- (void)fillWithMoment:(NSDictionary<NSString *, id> *)moment style:(NSInteger)style;
- (void)refreshPlayback;
- (void)pauseLyricsPlayback;
@end

@implementation SGRMomentCell {
    NSDictionary<NSString *, id> *_moment;
    NSInteger _style;
    CGFloat _progress;
    BOOL _hasDuration;
    BOOL _isSeeking;
    NSInteger _duration;
    NSAttributedString *_lyricsAttributed;
    NSUInteger _lyricsCurrentLocation;
    BOOL _scrollsToCurrentLine;

    UIView *_card;
    UIImageView *_coverView;
    AVPlayerLayer *_canvasLayer;
    AVQueuePlayer *_canvasPlayer;
    AVPlayerLooper *_canvasLooper;
    NSURL *_canvasURL;
    UIImageView *_artistView;
    UILabel *_artistInitial;
    CAGradientLayer *_lyricsGradient;
    UIView *_lyricsContainer;
    UIView *_animatedLyricsHost;
    SGRKaraokeView *_karaokeLyrics;
    UITextView *_lyricsView;
    CAGradientLayer *_lyricsMask;
    CAGradientLayer *_shade;

    UIVisualEffectView *_bubble;
    UILabel *_comment;
    UIScrollView *_commentScroll;
    NSArray<NSNumber *> *_commentTimes;
    UIImageView *_bubbleAvatar;
    UILabel *_bubbleInitial;

    UIVisualEffectView *_panel;
    UIView *_panelTint;
    UILabel *_track;
    UILabel *_artist;
    UIButton *_playButton;
    UIButton *_styleButton;
    UILabel *_elapsed;
    UILabel *_remaining;
    UIView *_barBackground;
    UIView *_progressFill;
    UIView *_knob;
    NSArray<UIView *> *_commentMarkers;
    UIPanGestureRecognizer *_progressPan;
    CGFloat _progressGrabOffset;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.isAccessibilityElement = NO;

    _card = [UIView new];
    _card.layer.cornerRadius = 30;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.contentView addSubview:_card];

    // Stile copertina / Canvas
    _coverView = [UIImageView new];
    _coverView.contentMode = UIViewContentModeScaleAspectFill;
    _coverView.clipsToBounds = YES;
    [_card addSubview:_coverView];
    _canvasLayer = [AVPlayerLayer layer];
    _canvasLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _canvasLayer.hidden = YES;
    [_card.layer addSublayer:_canvasLayer];

    // Stile foto artista
    _artistView = [UIImageView new];
    _artistView.contentMode = UIViewContentModeScaleAspectFill;
    _artistView.clipsToBounds = YES;
    [_card addSubview:_artistView];
    _artistInitial = [UILabel new];
    _artistInitial.textAlignment = NSTextAlignmentCenter;
    _artistInitial.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _artistInitial.font = [UIFont systemFontOfSize:96 weight:UIFontWeightBold];
    [_card addSubview:_artistInitial];

    // Stile testi: vista scrollabile con sfumatura in alto e in basso
    _lyricsGradient = [CAGradientLayer layer];
    [_card.layer addSublayer:_lyricsGradient];
    _lyricsContainer = [UIView new];
    _lyricsContainer.clipsToBounds = YES;
    [_card addSubview:_lyricsContainer];
    _lyricsView = [UITextView new];
    _lyricsView.editable = NO;
    _lyricsView.selectable = NO;
    _lyricsView.scrollEnabled = YES;
    _lyricsView.backgroundColor = UIColor.clearColor;
    _lyricsView.textContainerInset = UIEdgeInsetsZero;
    _lyricsView.textContainer.lineFragmentPadding = 0;
    _lyricsView.showsVerticalScrollIndicator = NO;
    _lyricsView.contentInset = UIEdgeInsetsMake(26, 0, 60, 0);
    [_lyricsContainer addSubview:_lyricsView];
    UITapGestureRecognizer *lyricsTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lyricsTapped:)];
    lyricsTap.cancelsTouchesInView = NO;
    [_lyricsView addGestureRecognizer:lyricsTap];
    _animatedLyricsHost = [UIView new];
    _animatedLyricsHost.clipsToBounds = YES;
    [_lyricsContainer addSubview:_animatedLyricsHost];
    _karaokeLyrics = [[SGRKaraokeView alloc] initWithFrame:CGRectZero];
    [_karaokeLyrics setFontSize:25];
    [_karaokeLyrics setPlaybackActive:NO];
    __weak typeof(self) weakSelf = self;
    _karaokeLyrics.lineTapHandler = ^(NSInteger positionMs) {
        if (weakSelf.commentHandler) weakSelf.commentHandler(positionMs);
    };
    [_animatedLyricsHost addSubview:_karaokeLyrics];
    _animatedLyricsHost.hidden = YES;
    _lyricsMask = [CAGradientLayer layer];
    _lyricsMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
                           (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _lyricsMask.locations = @[@0, @0.1, @0.86, @1];
    _lyricsContainer.layer.mask = _lyricsMask;

    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.5].CGColor];
    [_card.layer addSublayer:_shade];

    // Commento: sopra il miniplayer, uguale in tutti e tre gli stili
    _bubble = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _bubble.layer.cornerRadius = 19;
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
    _bubble.clipsToBounds = YES;
    [_card addSubview:_bubble];
    UIView *bubbleWash = [UIView new];
    bubbleWash.userInteractionEnabled = NO;
    bubbleWash.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    bubbleWash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_bubble.contentView addSubview:bubbleWash];
    _comment = [UILabel new];
    _comment.hidden = YES;
    [_bubble.contentView addSubview:_comment];
    _commentScroll = [UIScrollView new];
    _commentScroll.showsHorizontalScrollIndicator = NO;
    _commentScroll.alwaysBounceHorizontal = YES;
    _commentScroll.delaysContentTouches = NO;
    [_bubble.contentView addSubview:_commentScroll];
    _bubbleAvatar = [UIImageView new];
    _bubbleAvatar.contentMode = UIViewContentModeScaleAspectFill;
    _bubbleAvatar.clipsToBounds = YES;
    _bubbleAvatar.layer.cornerRadius = 14;
    _bubbleAvatar.layer.borderWidth = 1.5;
    _bubbleAvatar.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    [_card addSubview:_bubbleAvatar];
    _bubbleInitial = [UILabel new];
    _bubbleInitial.textAlignment = NSTextAlignmentCenter;
    _bubbleInitial.textColor = UIColor.whiteColor;
    _bubbleInitial.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _bubbleInitial.clipsToBounds = YES;
    _bubbleInitial.layer.cornerRadius = 14;
    [_card addSubview:_bubbleInitial];

    // Miniplayer: vetro arrotondato con bordo chiaro, titolo/artista a sinistra, pulsanti a destra,
    // sotto la barra vuota con il cursore a pillola bianca e il pallino scuro.
    _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _panel.layer.cornerRadius = 30;
    _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    _panel.clipsToBounds = YES;
    [_card addSubview:_panel];
    _panelTint = [UIView new];
    _panelTint.userInteractionEnabled = NO;
    [_panel.contentView addSubview:_panelTint];

    _track = [UILabel new];
    _track.textColor = UIColor.whiteColor;
    _track.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _track.lineBreakMode = NSLineBreakByTruncatingTail;
    [_panel.contentView addSubview:_track];
    _artist = [UILabel new];
    _artist.textColor = [UIColor colorWithWhite:1 alpha:0.62];
    _artist.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    _artist.lineBreakMode = NSLineBreakByTruncatingTail;
    [_panel.contentView addSubview:_artist];

    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *playConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
    [_playButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:playConfiguration] forState:UIControlStateNormal];
    _playButton.tintColor = UIColor.whiteColor;
    _playButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _playButton.layer.cornerRadius = 16;
    _playButton.accessibilityLabel = @"Riproduci il brano";
    [_playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel.contentView addSubview:_playButton];

    _styleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *styleConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    [_styleButton setImage:[UIImage systemImageNamed:@"photo.on.rectangle" withConfiguration:styleConfiguration] forState:UIControlStateNormal];
    _styleButton.tintColor = UIColor.whiteColor;
    _styleButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _styleButton.layer.cornerRadius = 16;
    _styleButton.accessibilityLabel = @"Stile della card";
    [_panel.contentView addSubview:_styleButton];

    _elapsed = [UILabel new];
    _elapsed.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    _elapsed.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    [_panel.contentView addSubview:_elapsed];
    _remaining = [UILabel new];
    _remaining.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    _remaining.textAlignment = NSTextAlignmentRight;
    _remaining.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    [_panel.contentView addSubview:_remaining];
    _barBackground = [SGRMomentProgressTrackView new];
    _barBackground.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _barBackground.layer.borderWidth = 1.2;
    _barBackground.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [_panel.contentView addSubview:_barBackground];
    _barBackground.userInteractionEnabled = YES;
    UITapGestureRecognizer *progressTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(progressTapped:)];
    progressTap.cancelsTouchesInView = NO;
    [_barBackground addGestureRecognizer:progressTap];
    _progressPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(progressPanned:)];
    _progressPan.delegate = self;
    _progressPan.cancelsTouchesInView = NO;
    [_barBackground addGestureRecognizer:_progressPan];
    _progressFill = [UIView new];
    _progressFill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.74];
    _progressFill.userInteractionEnabled = NO;
    [_panel.contentView addSubview:_progressFill];
    _knob = [UIView new];
    _knob.backgroundColor = UIColor.whiteColor;
    _knob.layer.cornerCurve = kCACornerCurveContinuous;
    _knob.userInteractionEnabled = NO;
    [_panel.contentView addSubview:_knob];
    return self;
}

- (void)playTapped {
    if (_playHandler) _playHandler();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != _progressPan) return YES;
    CGPoint velocity = [_progressPan velocityInView:_barBackground];
    return fabs(velocity.x) > fabs(velocity.y);
}

- (void)seekToProgressAtCenterX:(CGFloat)centerX commit:(BOOL)commit {
    CGFloat width = CGRectGetWidth(_barBackground.bounds);
    CGFloat thumbWidth = MIN(40, width);
    CGFloat travel = width - thumbWidth;
    if (!_hasDuration || _duration <= 0 || travel <= 0) return;
    CGFloat fraction = MIN(1, MAX(0, (centerX - thumbWidth / 2) / travel));
    _progress = fraction;
    NSInteger position = (NSInteger)llround((CGFloat)_duration * fraction);
    _elapsed.text = formattedTime(position);
    _remaining.text = [NSString stringWithFormat:@"−%@", formattedTime(MAX(0, _duration - position))];
    [self setNeedsLayout];
    if (commit && _commentHandler) _commentHandler(position);
}

- (void)progressTapped:(UITapGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:_barBackground];
    [self seekToProgressAtCenterX:point.x commit:YES];
}

- (void)progressPanned:(UIPanGestureRecognizer *)gesture {
    CGFloat width = CGRectGetWidth(_barBackground.bounds);
    CGFloat thumbWidth = MIN(40, width);
    CGPoint point = [gesture locationInView:_barBackground];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _isSeeking = YES;
        CGFloat currentCenter = thumbWidth / 2 + MAX(0, width - thumbWidth) * _progress;
        _progressGrabOffset = fabs(point.x - currentCenter) <= thumbWidth / 2 ? point.x - currentCenter : 0;
    }
    [self seekToProgressAtCenterX:point.x - _progressGrabOffset
                           commit:gesture.state == UIGestureRecognizerStateEnded];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        _isSeeking = NO;
    }
}

- (void)lyricsTapped:(UITapGestureRecognizer *)gesture {
    if (_style != SGRMomentStyleLyrics || !_moment) return;
    NSArray<NSDictionary<NSString *, id> *> *lines = momentLyrics(_moment[kMomentTrackKey]);
    if (!lines.count || !_lyricsView.attributedText.length || !_commentHandler) return;
    CGPoint point = [gesture locationInView:_lyricsView];
    point.x -= _lyricsView.textContainerInset.left;
    point.y = point.y + _lyricsView.contentOffset.y - _lyricsView.textContainerInset.top;
    NSLayoutManager *layoutManager = _lyricsView.layoutManager;
    NSTextContainer *textContainer = _lyricsView.textContainer;
    if (!layoutManager.numberOfGlyphs) return;
    NSUInteger glyph = [layoutManager glyphIndexForPoint:point inTextContainer:textContainer];
    NSUInteger character = [layoutManager characterIndexForGlyphAtIndex:MIN(glyph, layoutManager.numberOfGlyphs - 1)];
    NSString *text = _lyricsView.attributedText.string;
    NSUInteger newlineCount = 0;
    for (NSUInteger index = 0; index < MIN(character, text.length); index++) {
        if ([text characterAtIndex:index] == '\n') newlineCount++;
    }
    if (newlineCount >= lines.count) return;
    _commentHandler([lines[newlineCount][@"t"] integerValue]);
}

- (void)commentTapped:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _commentTimes.count || !_commentHandler) return;
    _commentHandler(_commentTimes[index].integerValue);
}

- (void)refreshPlayback {
    if (!_moment) return;
    NSString *trackID = _moment[kMomentTrackKey];
    SPTPlayerState *state = SGPlayerState();
    BOOL currentTrack = [momentIDFromURI(state.track.URI) isEqualToString:trackID];
    BOOL playing = currentTrack && state.isPlaying && !state.isPaused;
    NSInteger commentPosition = [_moment[kMomentTimeKey] integerValue];
    NSInteger position = currentTrack ? commentPosition : 0;
    NSInteger duration = [_moment[kMomentDurationKey] isKindOfClass:NSNumber.class]
        ? [_moment[kMomentDurationKey] integerValue] : 0;
    if (currentTrack) {
        NSInteger livePosition = SGKaraokePositionMs();
        if (livePosition >= 0) position = livePosition;
        if (state.duration > 0) duration = (NSInteger)(state.duration * 1000);
        NSNumber *pendingSeek = sg_pendingMomentSeeks[trackID];
        if (pendingSeek) {
            [sg_pendingMomentSeeks removeObjectForKey:trackID];
            SGKaraokeSeek(pendingSeek.integerValue);
            position = pendingSeek.integerValue;
        }
    }
    NSInteger lyricsPosition = currentTrack ? position : commentPosition;

    NSString *symbol = playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
    [_playButton setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
                 forState:UIControlStateNormal];
    _playButton.accessibilityLabel = playing ? @"Metti in pausa il brano" : @"Riproduci il brano";
    _hasDuration = duration > 0;
    if (!_isSeeking) _elapsed.text = formattedTime(position);
    _elapsed.accessibilityLabel = [NSString stringWithFormat:@"Posizione %@", formattedTime(position)];
    if (!_isSeeking) {
        _remaining.text = _hasDuration && duration >= position
            ? [NSString stringWithFormat:@"−%@", formattedTime(duration - position)] : @"";
    }
    _duration = duration;
    _knob.hidden = !_hasDuration;
    if (!_isSeeking) _progress = _hasDuration ? MIN(1, MAX(0, (CGFloat)position / (CGFloat)duration)) : 0;

    BOOL hasPlayerLyrics = currentTrack && SGKaraokeLinesForTrack(trackID) != nil;
    if (currentTrack && !hasPlayerLyrics) SGKaraokeRequestLyrics(trackID);
    BOOL usesAnimatedLyrics = _style == SGRMomentStyleLyrics && hasPlayerLyrics;
    [_karaokeLyrics setPlaybackActive:usesAnimatedLyrics];
    _animatedLyricsHost.hidden = !usesAnimatedLyrics;
    _lyricsView.hidden = usesAnimatedLyrics;
    _karaokeLyrics.hidden = !usesAnimatedLyrics;

    if (_style == SGRMomentStyleLyrics && !_lyricsContainer.hidden) {
        NSArray *lines = momentLyrics(trackID);
        if (lines.count) {
            NSUInteger location = 0;
            NSAttributedString *lyrics = momentLyricsText(lines, lyricsPosition, &location);
            if (location != _lyricsCurrentLocation || !_lyricsAttributed) {
                _lyricsCurrentLocation = location;
                _lyricsAttributed = lyrics;
                _lyricsView.attributedText = lyrics;
                _scrollsToCurrentLine = YES;
            }
        }
    }
    [self setNeedsLayout];
}

- (void)rebuildStyleMenu {
    if (@available(iOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        NSArray<NSString *> *titles = @[@"Testi", @"Copertina o Canvas", @"Foto dell’artista"];
        NSArray<NSString *> *symbols = @[@"text.quote", @"square.stack", @"person.crop.circle"];
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        for (NSInteger index = 0; index < 3; index++) {
            UIAction *action = [UIAction actionWithTitle:titles[(NSUInteger)index]
                                                   image:[UIImage systemImageNamed:symbols[(NSUInteger)index]]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *selected) {
                (void)selected;
                [weakSelf selectStyle:index];
            }];
            action.state = index == _style ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        _styleButton.menu = [UIMenu menuWithTitle:@"Stile del momento" children:actions];
        _styleButton.showsMenuAsPrimaryAction = YES;
    }
}

- (void)selectStyle:(NSInteger)style {
    if (style == _style || !_moment) return;
    NSDictionary *moment = _moment;
    if (_styleHandler) _styleHandler(style);
    [UIView transitionWithView:_card duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ [self fillWithMoment:moment style:style]; } completion:nil];
}

- (void)configureCanvas:(NSURL *)url {
    if (url && [url isEqual:_canvasURL]) {
        _canvasLayer.hidden = NO;
        [_canvasPlayer play];
        return;
    }
    [self stopCanvas];
    if (!url) return;
    _canvasURL = url;
    AVQueuePlayer *player = [AVQueuePlayer new];
    player.muted = YES;
    _canvasLooper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:[AVPlayerItem playerItemWithURL:url]];
    _canvasPlayer = player;
    _canvasLayer.player = player;
    _canvasLayer.hidden = NO;
    [player play];
}

- (void)stopCanvas {
    [_canvasPlayer pause];
    _canvasLayer.player = nil;
    _canvasLayer.hidden = YES;
    _canvasLooper = nil;
    _canvasPlayer = nil;
    _canvasURL = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self stopCanvas];
    [self pauseLyricsPlayback];
    _playHandler = nil;
    _styleHandler = nil;
}

- (void)pauseLyricsPlayback {
    [_karaokeLyrics setPlaybackActive:NO];
}

- (void)fillWithMoment:(NSDictionary<NSString *, id> *)moment style:(NSInteger)style {
    _moment = moment;
    _style = style;
    NSString *trackID = moment[kMomentTrackKey];
    NSString *artist = moment[kMomentArtistKey];
    UIImage *cover = momentCover(trackID) ?: momentAvatar(moment);
    UIImage *photo = momentArtistPhoto(moment);
    UIColor *base = (cover ? momentAverageColor(cover) : nil) ?: momentHue(artist, 0.45, 0.45);
    BOOL lyrics = style == SGRMomentStyleLyrics, showsCover = style == SGRMomentStyleCover, showsArtist = style == SGRMomentStyleArtist;
    NSInteger position = [moment[kMomentTimeKey] integerValue];

    _card.backgroundColor = momentTone(base, 1, 0.28);

    // Copertina o Canvas
    _coverView.image = cover;
    _coverView.hidden = !showsCover;
    if (showsCover) ensureMomentCanvas(moment);
    [self configureCanvas:showsCover ? momentCanvasFile(trackID) : nil];

    // Foto dell'artista
    _artistView.image = photo;
    _artistView.hidden = !showsArtist || !photo;
    _artistInitial.hidden = !showsArtist || photo != nil;
    _artistInitial.text = artist.length ? [[artist substringToIndex:1] uppercaseString] : @"♫";
    if (showsArtist && !photo) ensureArtistPhoto(moment);

    // Testi
    _lyricsGradient.hidden = !lyrics;
    _lyricsContainer.hidden = !lyrics;
    _shade.hidden = lyrics;
    _lyricsAttributed = nil;
    if (lyrics) {
        _lyricsGradient.colors = @[(id)momentTone(base, 1.05, 0.80).CGColor, (id)momentTone(base, 1.0, 0.30).CGColor];
        NSArray *lines = momentLyrics(trackID);
        if (lines.count) {
            NSUInteger location = 0;
            _lyricsAttributed = momentLyricsText(lines, position, &location);
            _lyricsCurrentLocation = location;
            _lyricsView.attributedText = _lyricsAttributed;
            _scrollsToCurrentLine = YES;
        } else {
            if (!momentLyricsFailed(trackID)) ensureLyrics(moment);
            _lyricsView.attributedText = [[NSAttributedString alloc]
                initWithString:momentLyricsFailed(trackID) ? @"Testo sincronizzato non disponibile per questo brano." : @"Carico il testo…"
                    attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:26 weight:UIFontWeightBold],
                                 NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7]}];
            _lyricsView.contentOffset = CGPointMake(0, -_lyricsView.contentInset.top);
        }
    }

    // Commento
    UIImage *face = captureUserAvatar();
    _bubbleAvatar.image = face;
    _bubbleAvatar.hidden = !face;
    _bubbleInitial.hidden = face != nil;
    _bubbleInitial.text = @"Tu";
    _bubbleInitial.backgroundColor = [SGRAccent() colorWithAlphaComponent:0.72];
    NSArray<NSDictionary<NSString *, id> *> *comments = moment[kMomentCommentsKey];
    if (![comments isKindOfClass:NSArray.class] || !comments.count) comments = @[moment];
    NSMutableArray<NSNumber *> *commentTimes = [NSMutableArray arrayWithCapacity:comments.count];
    for (UIView *view in _commentScroll.subviews) [view removeFromSuperview];
    for (UIView *marker in _commentMarkers) [marker removeFromSuperview];
    NSMutableArray<UIView *> *markers = [NSMutableArray arrayWithCapacity:comments.count];
    CGFloat commentX = 0;
    for (NSUInteger index = 0; index < comments.count; index++) {
        NSDictionary *comment = comments[index];
        NSInteger timestamp = [comment[kMomentTimeKey] integerValue];
        [commentTimes addObject:@(timestamp)];

        NSString *title = [NSString stringWithFormat:@"%@  %@", formattedTime(timestamp), comment[kMomentTextKey] ?: @""];
        UIButtonConfiguration *buttonConfiguration = [UIButtonConfiguration plainButtonConfiguration];
        buttonConfiguration.title = title;
        buttonConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(5, 11, 5, 11);
        buttonConfiguration.baseForegroundColor = UIColor.whiteColor;
        buttonConfiguration.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
        buttonConfiguration.background.cornerRadius = 15;
        buttonConfiguration.background.strokeColor = [UIColor colorWithWhite:1 alpha:0.18];
        buttonConfiguration.background.strokeWidth = 1;
        buttonConfiguration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            return result;
        };
        UIButton *commentButton = [UIButton buttonWithConfiguration:buttonConfiguration primaryAction:nil];
        commentButton.tag = (NSInteger)index;
        commentButton.titleLabel.numberOfLines = 2;
        commentButton.titleLabel.textAlignment = NSTextAlignmentLeft;
        commentButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        commentButton.accessibilityLabel = [NSString stringWithFormat:@"Vai a %@, commento: %@",
                                            formattedTime(timestamp), comment[kMomentTextKey] ?: @""];
        [commentButton addTarget:self action:@selector(commentTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_commentScroll addSubview:commentButton];
        commentButton.frame = CGRectMake(commentX, 0, 204, 54);
        commentX += 212;

        UIView *marker = [UIView new];
        marker.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
        marker.userInteractionEnabled = NO;
        marker.layer.cornerRadius = 4;
        marker.layer.borderWidth = 1.5;
        marker.layer.borderColor = UIColor.whiteColor.CGColor;
        marker.accessibilityLabel = [NSString stringWithFormat:@"Commento a %@", formattedTime(timestamp)];
        [_panel.contentView addSubview:marker];
        [markers addObject:marker];
    }
    _commentTimes = [commentTimes copy];
    _commentMarkers = [markers copy];
    _commentScroll.contentSize = CGSizeMake(MAX(0, commentX - 8), 54);
    _commentScroll.contentOffset = CGPointZero;

    // Miniplayer
    _panelTint.backgroundColor = [momentTone(base, 1.0, 0.42) colorWithAlphaComponent:0.55];
    _track.text = moment[kMomentTitleKey];
    _artist.text = artist;
    NSInteger duration = [moment[kMomentDurationKey] isKindOfClass:NSNumber.class] ? [moment[kMomentDurationKey] integerValue] : 0;
    _duration = duration;
    _hasDuration = duration > 0 && duration >= position;
    _progress = _hasDuration ? MIN(1, MAX(0, (CGFloat)position / (CGFloat)duration)) : 0;
    _elapsed.text = formattedTime(position);
    _elapsed.accessibilityLabel = [NSString stringWithFormat:@"Minuto %@", formattedTime(position)];
    _remaining.text = _hasDuration ? [NSString stringWithFormat:@"−%@", formattedTime(duration - position)] : @"";
    _knob.hidden = !_hasDuration;

    [self rebuildStyleMenu];
    [self refreshPlayback];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect bounds = self.contentView.bounds;
    _card.frame = CGRectMake(16, 8, MAX(0, bounds.size.width - 32), MAX(0, bounds.size.height - 16));
    CGFloat width = _card.bounds.size.width, height = _card.bounds.size.height;
    _coverView.frame = _card.bounds;
    _canvasLayer.frame = _card.bounds;
    _artistView.frame = _card.bounds;
    _artistInitial.frame = _card.bounds;
    _lyricsGradient.frame = _card.bounds;
    _shade.frame = _card.bounds;

    // Miniplayer
    CGFloat panelHeight = kMomentPanelHeight;
    _panel.frame = CGRectMake(12, height - 12 - panelHeight, MAX(0, width - 24), panelHeight);
    CGFloat panelWidth = _panel.bounds.size.width;
    _panelTint.frame = _panel.bounds;
    CGFloat inset = 24, button = 32, gap = 10;
    _playButton.frame = CGRectMake(panelWidth - inset - button, 22, button, button);
    _styleButton.frame = CGRectMake(CGRectGetMinX(_playButton.frame) - gap - button, 22, button, button);
    CGFloat textWidth = MAX(0, CGRectGetMinX(_styleButton.frame) - 12 - inset);
    _track.frame = CGRectMake(inset, 20, textWidth, 22);
    _artist.frame = CGRectMake(inset, 43, textWidth, 22);

    CGFloat rowCenter = 90, timeWidth = 36;
    _elapsed.frame = CGRectMake(inset, rowCenter - 8, timeWidth, 16);
    _remaining.frame = CGRectMake(panelWidth - inset - timeWidth - 4, rowCenter - 8, timeWidth + 4, 16);
    CGFloat barX = CGRectGetMaxX(_elapsed.frame) + 8;
    CGFloat barWidth = MAX(0, CGRectGetMinX(_remaining.frame) - 8 - barX);
    _barBackground.frame = CGRectMake(barX, rowCenter - 3.5, barWidth, 7);
    _barBackground.layer.cornerRadius = 3.5;
    _progressFill.layer.cornerRadius = 2.5;
    CGFloat thumbWidth = MIN(40, barWidth), thumbHeight = 11;
    CGFloat thumbCenter = barX + thumbWidth / 2 + (barWidth - thumbWidth) * _progress;
    _knob.frame = CGRectMake(thumbCenter - thumbWidth / 2, rowCenter - thumbHeight / 2, thumbWidth, thumbHeight);
    _knob.layer.cornerRadius = thumbHeight / 2;
    // Commento sopra il miniplayer
    CGFloat avatarSize = 28, avatarGap = 8;
    CGFloat maxBubbleWidth = MAX(0, width - 24 - avatarSize - avatarGap);
    CGFloat bubbleWidth = maxBubbleWidth;
    CGFloat bubbleHeight = MIN(MAX(0, height - panelHeight - 90), 62);
    CGFloat bubbleBottom = CGRectGetMinY(_panel.frame) - 12;
    _bubble.frame = CGRectMake(12 + avatarSize + avatarGap, bubbleBottom - bubbleHeight, bubbleWidth, bubbleHeight);
    _commentScroll.frame = CGRectMake(6, 4, MAX(0, bubbleWidth - 12), MAX(0, bubbleHeight - 8));
    CGFloat commentX = 0;
    for (UIView *view in _commentScroll.subviews) {
        view.frame = CGRectMake(commentX, 0, 204, 54);
        commentX += 212;
    }
    _commentScroll.contentSize = CGSizeMake(MAX(0, commentX - 8), 54);
    CGRect avatarFrame = CGRectMake(12, bubbleBottom - avatarSize, avatarSize, avatarSize);
    _bubbleAvatar.frame = avatarFrame;
    _bubbleInitial.frame = avatarFrame;

    // Testi: occupano lo spazio sopra la nuvoletta e si scorrono su e giù
    CGFloat lyricsTop = 36;
    CGFloat lyricsBottom = CGRectGetMinY(_bubble.frame) - 14;
    _lyricsContainer.frame = CGRectMake(24, lyricsTop, MAX(0, width - 48), MAX(40, lyricsBottom - lyricsTop));
    _lyricsView.frame = _lyricsContainer.bounds;
    _animatedLyricsHost.frame = _lyricsContainer.bounds;
    _karaokeLyrics.frame = _animatedLyricsHost.bounds;
    _lyricsMask.frame = _lyricsContainer.bounds;
    CGFloat fillWidth = MAX(0, CGRectGetWidth(_barBackground.bounds) - 2) * _progress;
    _progressFill.frame = CGRectMake(CGRectGetMinX(_barBackground.frame) + 1,
                                     CGRectGetMinY(_barBackground.frame) + 1,
                                     fillWidth, MAX(0, CGRectGetHeight(_barBackground.bounds) - 2));
    for (NSUInteger index = 0; index < _commentMarkers.count; index++) {
        UIView *marker = _commentMarkers[index];
        NSInteger timestamp = index < _commentTimes.count ? _commentTimes[index].integerValue : 0;
        CGFloat fraction = _duration > 0 ? MIN(1, MAX(0, (CGFloat)timestamp / (CGFloat)_duration)) : 0;
        CGFloat thumbWidth = MIN(40, CGRectGetWidth(_barBackground.bounds));
        CGFloat centerX = CGRectGetMinX(_barBackground.frame) + thumbWidth / 2 +
            (CGRectGetWidth(_barBackground.bounds) - thumbWidth) * fraction;
        marker.frame = CGRectMake(centerX - 4, CGRectGetMidY(_barBackground.frame) - 4, 8, 8);
        marker.hidden = !_hasDuration || CGRectGetWidth(_barBackground.bounds) <= 0;
    }
    CGFloat lyricsWidth = _lyricsContainer.bounds.size.width;
    if (_scrollsToCurrentLine && lyricsWidth > 0 && _lyricsAttributed.length &&
        !_lyricsContainer.hidden && !_lyricsView.hidden) {
        _scrollsToCurrentLine = NO;
        CGFloat currentY = 0;
        if (_lyricsCurrentLocation > 1) {
            NSAttributedString *before = [_lyricsAttributed attributedSubstringFromRange:NSMakeRange(0, _lyricsCurrentLocation - 1)];
            currentY = ceil([before boundingRectWithSize:CGSizeMake(lyricsWidth, CGFLOAT_MAX)
                                                 options:NSStringDrawingUsesLineFragmentOrigin
                                                 context:nil].size.height) + kMomentLyricsParagraphSpacing;
        }
        [_lyricsView layoutIfNeeded];
        CGFloat minY = -_lyricsView.contentInset.top;
        CGFloat maxY = MAX(minY, _lyricsView.contentSize.height - _lyricsView.bounds.size.height + _lyricsView.contentInset.bottom);
        // La riga del momento parte vicino all'alto, con un assaggio di quella precedente.
        _lyricsView.contentOffset = CGPointMake(0, MIN(maxY, MAX(minY, currentY - 48)));
    }
    [CATransaction commit];
}

@end

@interface SGRMomentsPage : SGPage <SGPlayerStateObserver>
- (void)reloadMoments;
- (NSArray<NSDictionary<NSString *, id> *> *)visibleMoments;
- (void)selectArtist:(SGRMomentArtistButton *)sender;
- (void)startPlaybackUpdates;
- (void)refreshVisibleMomentCells;
@end

@implementation SGRMomentsPage {
    UIView *_momentsHeader;
    UILabel *_headerTitle;
    UIButton *_addButton;
    UIScrollView *_artistScroll;
    NSArray<NSDictionary<NSString *, id> *> *_moments;
    NSArray<NSDictionary<NSString *, id> *> *_artists;
    NSString *_selectedArtist; // nil = tutti
    UILabel *_emptyLabel;
    NSTimer *_playbackTimer;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"Spotify Moments";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = SGRNeutralField();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 520;
    [self.tableView registerClass:SGRMomentCell.class forCellReuseIdentifier:@"moment"];
    captureUserAvatar();
    observeMomentCanvasPlayback();

    _momentsHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width,
                                                              kMomentHeaderTitleHeight + kMomentAvatarRowHeight)];
    _momentsHeader.backgroundColor = SGRNeutralField();
    _headerTitle = [UILabel new];
    UIFont *titleFont = SGRFont(UIFontTextStyleTitle3, UIFontWeightBold, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:@"Ultimi momenti "
        attributes:@{NSFontAttributeName: titleFont, NSForegroundColorAttributeName: SGRPrimary()}];
    NSTextAttachment *chevron = [NSTextAttachment new];
    chevron.image = [[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]]
        imageWithTintColor:SGRSecondary() renderingMode:UIImageRenderingModeAlwaysOriginal];
    [title appendAttributedString:[NSAttributedString attributedStringWithAttachment:chevron]];
    _headerTitle.attributedText = title;
    _headerTitle.accessibilityLabel = @"Ultimi momenti";
    _headerTitle.accessibilityTraits = UIAccessibilityTraitHeader;
    [_momentsHeader addSubview:_headerTitle];

    _addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *plus = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    [_addButton setImage:[UIImage systemImageNamed:@"plus" withConfiguration:plus] forState:UIControlStateNormal];
    _addButton.tintColor = SGRAccent();
    _addButton.accessibilityLabel = @"Nuovo momento";
    [_addButton addTarget:self action:@selector(addMoment) forControlEvents:UIControlEventTouchUpInside];
    [_momentsHeader addSubview:_addButton];

    _artistScroll = [UIScrollView new];
    _artistScroll.showsHorizontalScrollIndicator = NO;
    _artistScroll.alwaysBounceHorizontal = YES;
    [_momentsHeader addSubview:_artistScroll];
    self.tableView.tableHeaderView = _momentsHeader;

    _emptyLabel = [UILabel new];
    _emptyLabel.text = @"I tuoi commenti compariranno qui.\nApri il player per lasciare il primo momento.";
    _emptyLabel.textColor = SGRSecondary();
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
    _emptyLabel.frame = CGRectMake(24, 0, self.tableView.bounds.size.width - 48, 96);
    self.tableView.backgroundView = _emptyLabel;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadMoments)
        name:@"spotifyglass.redesign.moments.changed" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadMoments)
        name:kMomentsAssetsChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshVisibleMomentCells)
        name:kMomentPlaybackStateChangedNotification object:nil];
    SGAddPlayerStateObserver(self);
    [self reloadMoments];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)addMoment {
    SGRPresentMomentComposer(self.view);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    CGRect frame = _momentsHeader.frame;
    frame.size.width = width;
    frame.size.height = kMomentHeaderTitleHeight + (_artists.count ? kMomentAvatarRowHeight : 0);
    BOOL headerSizeChanged = !CGSizeEqualToSize(frame.size, _momentsHeader.frame.size);
    _momentsHeader.frame = frame;
    _headerTitle.frame = CGRectMake(20, 8, MAX(0, width - 20 - 20 - 48), 36);
    _addButton.frame = CGRectMake(width - 20 - 40, 6, 40, 40);
    _artistScroll.hidden = !_artists.count;
    _artistScroll.frame = CGRectMake(0, kMomentHeaderTitleHeight, width, kMomentAvatarRowHeight);
    _emptyLabel.frame = CGRectMake(24, 0, MAX(0, width - 48), 96);
    if (headerSizeChanged) self.tableView.tableHeaderView = _momentsHeader;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadMoments];
    [self startPlaybackUpdates];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_playbackTimer invalidate];
    _playbackTimer = nil;
}

- (void)startPlaybackUpdates {
    [_playbackTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _playbackTimer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refreshVisibleMomentCells];
    }];
    [NSRunLoop.mainRunLoop addTimer:_playbackTimer forMode:NSRunLoopCommonModes];
}

- (void)refreshVisibleMomentCells {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:SGRMomentCell.class]) [(SGRMomentCell *)cell refreshPlayback];
    }
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    (void)state;
    [self refreshVisibleMomentCells];
}

- (void)reloadMoments {
    _moments = momentsByNewest();
    _artists = momentArtists();
    // Se l'artista selezionato non ha più commenti si torna a "Tutti".
    if (_selectedArtist.length) {
        BOOL stillThere = NO;
        for (NSDictionary *moment in _artists) if ([artistKey(moment) isEqualToString:_selectedArtist]) stillThere = YES;
        if (!stillThere) _selectedArtist = nil;
    }

    for (NSDictionary *moment in _artists) ensureArtistPhoto(moment);
    for (UIView *view in [_artistScroll.subviews copy]) [view removeFromSuperview];
    NSUInteger count = _artists.count + 1; // "Tutti" + un avatar per artista
    for (NSUInteger index = 0; index < count; index++) {
        NSDictionary *moment = index == 0 ? nil : _artists[index - 1];
        NSString *key = moment ? artistKey(moment) : nil;
        BOOL selected = key == nil ? _selectedArtist == nil : [_selectedArtist isEqualToString:key];
        SGRMomentArtistButton *button = [[SGRMomentArtistButton alloc] initWithMoment:moment selected:selected];
        button.filterKey = key;
        button.frame = CGRectMake(16 + kMomentAvatarColumn * index, 0, kMomentAvatarColumn, kMomentAvatarRowHeight);
        [button addTarget:self action:@selector(selectArtist:) forControlEvents:UIControlEventTouchUpInside];
        [_artistScroll addSubview:button];
    }
    _artistScroll.contentSize = CGSizeMake(16 + kMomentAvatarColumn * count + 10, kMomentAvatarRowHeight);
    _emptyLabel.hidden = [self visibleMoments].count > 0;
    [self.view setNeedsLayout];
    [self.tableView reloadData];
}

- (NSArray<NSDictionary<NSString *, id> *> *)visibleMoments {
    if (!_selectedArtist.length) return _moments ?: @[];
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *moment in _moments) if ([artistKey(moment) isEqualToString:_selectedArtist]) [visible addObject:moment];
    return visible;
}

- (void)selectArtist:(SGRMomentArtistButton *)button {
    NSString *selected = button.filterKey.length ? button.filterKey : nil;
    if ((selected == nil && _selectedArtist == nil) || [selected isEqualToString:_selectedArtist]) return;
    _selectedArtist = selected;
    [self reloadMoments];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    return ceil(MAX(0, tableView.bounds.size.width - 32) * kMomentCardAspect) + 16;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)[self visibleMoments].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SGRMomentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"moment" forIndexPath:indexPath];
    NSDictionary *moment = [self visibleMoments][(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    [cell fillWithMoment:moment style:momentStyle(moment)];
    cell.playHandler = ^{ playMomentTrack(moment, weakSelf); };
    cell.commentHandler = ^(NSInteger positionMs) { playMomentTrackAtPosition(moment, positionMs, weakSelf); };
    cell.styleHandler = ^(NSInteger style) { setMomentStyle(moment, style); };
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSDictionary *deleted = [self visibleMoments][(NSUInteger)indexPath.row];
    NSString *trackID = deleted[kMomentTrackKey];
    NSMutableArray *remaining = [NSMutableArray array];
    for (NSDictionary *moment in storedMoments()) {
        if (![moment[kMomentTrackKey] isEqualToString:trackID]) [remaining addObject:moment];
    }
    [NSUserDefaults.standardUserDefaults setObject:remaining forKey:kMomentsEntriesKey];
    forgetMomentStyle(deleted);
    invalidateMomentsCache();
    [self reloadMoments];
}

@end

UIViewController *SGRSpotifyMomentsPage(void) {
    return [SGRMomentsPage new];
}

static UINavigationController *navigationControllerIn(UIViewController *controller) {
    if ([controller isKindOfClass:UINavigationController.class]) return (UINavigationController *)controller;
    for (UIViewController *child in controller.childViewControllers) {
        UINavigationController *found = navigationControllerIn(child);
        if (found) return found;
    }
    return nil;
}

void SGROpenSpotifyMoments(UIView *source) {
    if (!SGRMomentsEnabled()) return;
    UIViewController *owner = nil;
    for (UIResponder *responder = source; responder && !owner; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) owner = (UIViewController *)responder;
    }
    UIViewController *presenting = owner.presentingViewController;
    if (presenting) {
        [presenting dismissViewControllerAnimated:YES completion:^{
            UINavigationController *navigation = navigationControllerIn(presenting);
            SGShowPage(navigation.topViewController ?: presenting, SGRSpotifyMomentsPage());
        }];
        return;
    }
    if (owner) SGShowPage(owner, SGRSpotifyMomentsPage());
    else SGLog(@"moments: could not find the drawer controller to open the page");
}

SGModSection *SGRMomentsSettingsSection(void) {
    SGModRow *enabled = SGWithSymbol(SGSwitchRow(@"Spotify Moments",
        @"Commenti personali e nuvolette sincronizzate ai testi. I dati restano su questo dispositivo.",
        SGRKeyMomentsEnabled), @"quote.bubble");
    return SGSection(@"Spotify Moments", @[enabled]);
}
