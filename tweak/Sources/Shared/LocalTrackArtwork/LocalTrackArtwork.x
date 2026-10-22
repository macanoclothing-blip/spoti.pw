// User-selected Spotify artwork for a local file; playback stays on the local URI.
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <PhotosUI/PhotosUI.h>
#import "Core/SGCore.h"
#import "LocalTrackArtwork.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

static NSString *const kMatchesKey = @"spotifyglass.localTrackArtwork.matches";
static NSString *const kSearchAddress = @"https://api.spotify.com/v1/search";
static NSCache<NSString *, id> *sg_customCoverCache;
static NSCache<NSString *, UIImage *> *sg_coverCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_coverRequests;
static NSCache<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *sg_searchResults;
static NSCache<NSString *, UIImage *> *sg_searchCoverCache;

NSNotificationName const SGLocalArtworkDidChangeNotification = @"spotifyglass.localTrackArtwork.changed";
NSNotificationName const SGLocalArtworkMatchDidChangeNotification = @"spotifyglass.localTrackArtwork.matchChanged";

BOOL SGLocalArtworkIsLocalTrack(NSString *uri) {
    if (![uri isKindOfClass:NSString.class] || !uri.length) return NO;
    return [uri hasPrefix:@"spotify:local:"] ||
           [[NSURLComponents componentsWithString:uri].scheme.lowercaseString isEqualToString:@"file"];
}

static NSString *coverFilePath(NSString *localURI) {
    NSData *identity = [localURI dataUsingEncoding:NSUTF8StringEncoding];
    if (!identity.length) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identity.bytes, (CC_LONG)identity.length, digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [name appendFormat:@"%02x", digest[i]];
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"spoti.pw/LocalArtwork"] stringByAppendingPathComponent:
            [name stringByAppendingString:@".jpg"]];
}

static NSCache<NSString *, id> *customCoverCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_customCoverCache = [NSCache new];
        sg_customCoverCache.countLimit = 128;
        sg_customCoverCache.totalCostLimit = 48 * 1024 * 1024;
    });
    return sg_customCoverCache;
}

BOOL SGLocalArtworkHasCustomCover(NSString *localURI) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) return NO;
    id cached = [customCoverCache() objectForKey:localURI];
    if ([cached isKindOfClass:UIImage.class]) return YES;
    if (cached == NSNull.null) return NO;
    NSString *path = coverFilePath(localURI);
    BOOL exists = path && [NSFileManager.defaultManager fileExistsAtPath:path];
    if (!exists) [customCoverCache() setObject:NSNull.null forKey:localURI];
    return exists;
}

BOOL SGLocalArtworkSaveCustomCover(NSString *localURI, UIImage *image, NSError **error) {
    if (!SGLocalArtworkIsLocalTrack(localURI) || !image) {
        if (error) *error = [NSError errorWithDomain:@"SGLocalArtwork" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Choose a valid image for a local track."}];
        return NO;
    }
    NSString *path = coverFilePath(localURI);
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:@"SGLocalArtwork" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The artwork storage location is unavailable."}];
        return NO;
    }
    CGSize size = image.size;
    CGFloat longest = MAX(size.width, size.height);
    UIImage *storedImage = image;
    if (longest > 2048) {
        CGFloat scale = 2048 / longest;
        CGSize target = CGSizeMake(round(size.width * scale), round(size.height * scale));
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = YES;
        storedImage = [[[UIGraphicsImageRenderer alloc] initWithSize:target format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *context) {
                (void)context;
                [UIColor.blackColor setFill];
                UIRectFill((CGRect){CGPointZero, target});
                [image drawInRect:(CGRect){CGPointZero, target}];
            }];
    }
    NSData *data = UIImageJPEGRepresentation(storedImage, 0.88);
    if (!data.length) {
        if (error) *error = [NSError errorWithDomain:@"SGLocalArtwork" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"The selected photo couldn't be encoded."}];
        return NO;
    }
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    NSUInteger cost = (NSUInteger)(storedImage.size.width * storedImage.size.height * 4);
    [customCoverCache() setObject:storedImage forKey:localURI cost:cost];
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkDidChangeNotification object:localURI];
    return YES;
}

BOOL SGLocalArtworkRemoveCustomCover(NSString *localURI, NSError **error) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) {
        if (error) *error = [NSError errorWithDomain:@"SGLocalArtwork" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"The selected item isn't a local track."}];
        return NO;
    }
    NSString *path = coverFilePath(localURI);
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:@"SGLocalArtwork" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"The artwork storage location is unavailable."}];
        return NO;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:path] &&
        ![NSFileManager.defaultManager removeItemAtPath:path error:error]) return NO;
    [customCoverCache() setObject:NSNull.null forKey:localURI];
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkDidChangeNotification object:localURI];
    return YES;
}

NSDictionary<NSString *, id> *SGLocalArtworkMatch(NSString *localURI) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) return nil;
    id match = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMatchesKey][localURI];
    if (![match isKindOfClass:NSDictionary.class] ||
        ![match[@"spotifyURI"] isKindOfClass:NSString.class] ||
        ![match[@"spotifyURI"] hasPrefix:@"spotify:track:"]) return nil;
    NSString *coverURL = [match[@"coverURL"] isKindOfClass:NSString.class] ? match[@"coverURL"] : nil;
    if (coverURL.length) {
        NSURLComponents *components = [NSURLComponents componentsWithString:coverURL];
        if (![components.scheme.lowercaseString isEqualToString:@"https"] ||
            ![components.host.lowercaseString isEqualToString:@"i.scdn.co"] ||
            !components.path.length || !components.URL) return nil;
    }
    return match;
}

NSString *SGLocalArtworkSpotifyURI(NSString *localURI) {
    return SGLocalArtworkMatch(localURI)[@"spotifyURI"];
}

NSString *SGLocalArtworkCoverURL(NSString *localURI) {
    return SGLocalArtworkMatch(localURI)[@"coverURL"];
}

static NSDictionary<NSString *, id> *storedEntry(NSString *localURI) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) return nil;
    id entry = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMatchesKey][localURI];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}

NSString *SGLocalArtworkTitle(NSString *localURI) {
    id value = storedEntry(localURI)[@"titleOverride"];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

NSString *SGLocalArtworkArtist(NSString *localURI) {
    id value = storedEntry(localURI)[@"artistOverride"];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static NSString *coverCacheKey(NSString *localURI) {
    return [NSString stringWithFormat:@"%@|%@", localURI ?: @"", SGLocalArtworkCoverURL(localURI) ?: @""];
}

UIImage *SGLocalArtworkCachedCover(NSString *localURI) {
    if (SGLocalArtworkIsLocalTrack(localURI)) {
        id custom = [customCoverCache() objectForKey:localURI];
        if (!custom) {
            NSString *path = coverFilePath(localURI);
            UIImage *image = path ? [UIImage imageWithContentsOfFile:path] : nil;
            custom = image ?: NSNull.null;
            NSUInteger cost = image ? (NSUInteger)(image.size.width * image.size.height * 4) : 0;
            [customCoverCache() setObject:custom forKey:localURI cost:cost];
        }
        if ([custom isKindOfClass:UIImage.class]) return custom;
    }
    if (!sg_coverCache) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sg_coverCache = [NSCache new]; });
    }
    return [sg_coverCache objectForKey:coverCacheKey(localURI)];
}

void SGLocalArtworkLoadCover(NSString *localURI, void (^completion)(UIImage *image)) {
    NSString *address = SGLocalArtworkCoverURL(localURI);
    UIImage *cached = SGLocalArtworkCachedCover(localURI);
    if (cached || !address.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sg_coverRequests = [NSMutableDictionary dictionary]; });
    NSString *key = coverCacheKey(localURI);
    @synchronized (sg_coverRequests) {
        NSMutableArray *waiting = sg_coverRequests[key];
        if (waiting) {
            if (completion) [waiting addObject:[completion copy]];
            return;
        }
        void (^requestCompletion)(UIImage *);
        if (completion) requestCompletion = [completion copy];
        else requestCompletion = ^(UIImage *image) {};
        sg_coverRequests[key] = [NSMutableArray arrayWithObject:requestCompletion];
    }

    NSURL *url = [NSURL URLWithString:address];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = data.length && !error && status == 200 ? [UIImage imageWithData:data] : nil;
        NSMutableArray *waiting;
        @synchronized (sg_coverRequests) {
            waiting = sg_coverRequests[key];
            [sg_coverRequests removeObjectForKey:key];
        }
        if (image && [key isEqualToString:coverCacheKey(localURI)]) {
            [sg_coverCache setObject:image forKey:key];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) SGLog(@"local artwork: cover download failed for a selected Spotify track (HTTP %ld, %@)",
                              (long)status, error.localizedDescription);
            for (void (^done)(UIImage *) in waiting) done(image);
        });
    }];
    [task resume];
}

static void saveMatches(NSMutableDictionary *matches) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (matches.count) [defaults setObject:matches forKey:kMatchesKey];
    else [defaults removeObjectForKey:kMatchesKey];
}

void SGLocalArtworkSaveNames(NSString *localURI, NSString *title, NSString *artist) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) {
        SGLog(@"local artwork: refusing edited names for a non-local track");
        return;
    }
    NSMutableDictionary *matches = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kMatchesKey] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = [matches[localURI] isKindOfClass:NSDictionary.class]
        ? [matches[localURI] mutableCopy] : [NSMutableDictionary dictionary];
    NSString *cleanTitle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *cleanArtist = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (cleanTitle.length) entry[@"titleOverride"] = cleanTitle;
    else [entry removeObjectForKey:@"titleOverride"];
    if (cleanArtist.length) entry[@"artistOverride"] = cleanArtist;
    else [entry removeObjectForKey:@"artistOverride"];
    if (entry.count) matches[localURI] = [entry copy];
    else [matches removeObjectForKey:localURI];
    saveMatches(matches);
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkDidChangeNotification object:localURI];
}

static void saveMatch(NSString *localURI, NSDictionary<NSString *, id> *match,
                      NSString *title, NSString *artist, BOOL replaceNames) {
    NSString *spotifyURI = match[@"spotifyURI"];
    NSString *coverURL = match[@"coverURL"];
    if (!SGLocalArtworkIsLocalTrack(localURI) ||
        ![spotifyURI isKindOfClass:NSString.class] || ![spotifyURI hasPrefix:@"spotify:track:"]) {
        SGLog(@"local artwork: refusing an invalid track match");
        return;
    }
    if (coverURL.length) {
        NSURLComponents *components = [NSURLComponents componentsWithString:coverURL];
        if (![components.scheme.lowercaseString isEqualToString:@"https"] ||
            ![components.host.lowercaseString isEqualToString:@"i.scdn.co"] ||
            !components.path.length || !components.URL) {
            SGLog(@"local artwork: refusing a cover URL outside Spotify's image host");
            return;
        }
    }

    NSMutableDictionary *matches = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kMatchesKey] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    NSDictionary *old = [matches[localURI] isKindOfClass:NSDictionary.class] ? matches[localURI] : nil;
    if (replaceNames) {
        NSString *cleanTitle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *cleanArtist = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (cleanTitle.length) stored[@"titleOverride"] = cleanTitle;
        if (cleanArtist.length) stored[@"artistOverride"] = cleanArtist;
    } else {
        for (NSString *key in @[@"titleOverride", @"artistOverride"]) {
            id value = old[key];
            if ([value isKindOfClass:NSString.class] && [value length]) stored[key] = value;
        }
    }
    for (NSString *key in @[@"spotifyURI", @"title", @"artist", @"album", @"coverURL"]) {
        id value = match[key];
        if ([value isKindOfClass:NSString.class] && [value length]) stored[key] = value;
    }
    matches[localURI] = [stored copy];
    saveMatches(matches);
    SGLog(@"local artwork: matched a local track to %@", spotifyURI);
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkDidChangeNotification object:localURI];
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkMatchDidChangeNotification object:localURI];
}

void SGLocalArtworkSaveMatch(NSString *localURI, NSDictionary<NSString *, id> *match) {
    saveMatch(localURI, match, nil, nil, NO);
}

void SGLocalArtworkSaveSelection(NSString *localURI, NSDictionary<NSString *, id> *match,
                                 NSString *title, NSString *artist) {
    saveMatch(localURI, match, title, artist, YES);
}

void SGLocalArtworkRemoveMatch(NSString *localURI) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) return;
    NSMutableDictionary *matches = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kMatchesKey] mutableCopy];
    NSMutableDictionary *entry = [matches[localURI] isKindOfClass:NSDictionary.class]
        ? [matches[localURI] mutableCopy] : nil;
    if (!entry || !entry[@"spotifyURI"]) return;
    for (NSString *key in @[@"spotifyURI", @"title", @"artist", @"album", @"coverURL"]) [entry removeObjectForKey:key];
    if (entry.count) matches[localURI] = [entry copy];
    else [matches removeObjectForKey:localURI];
    saveMatches(matches);
    SGLog(@"local artwork: removed the match for a local track");
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkDidChangeNotification object:localURI];
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalArtworkMatchDidChangeNotification object:localURI];
}

static NSError *searchError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SGLocalArtworkSearch" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *cleanSearchQuery(NSString *query) {
    NSArray<NSString *> *parts = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *part, NSDictionary *bindings) {
        (void)bindings;
        return part.length > 0;
    }]];
    return [parts componentsJoinedByString:@" "];
}

static NSCache<NSString *, NSArray<NSDictionary<NSString *, id> *> *> *searchResultCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_searchResults = [NSCache new];
        sg_searchResults.countLimit = 32;
    });
    return sg_searchResults;
}

static NSCache<NSString *, UIImage *> *searchCoverCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_searchCoverCache = [NSCache new];
        sg_searchCoverCache.countLimit = 80;
        sg_searchCoverCache.totalCostLimit = 20 * 1024 * 1024;
    });
    return sg_searchCoverCache;
}

static NSString *normalizedName(NSString *name) {
    NSString *clean = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [clean componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *part, NSDictionary *bindings) {
        (void)bindings;
        return part.length > 0;
    }]];
    clean = [parts componentsJoinedByString:@" "];
    return [clean stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch
                                      locale:NSLocale.currentLocale];
}

static NSString *normalizedDisplayedName(NSString *name) {
    NSString *value = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *edgeMarks = [NSCharacterSet characterSetWithCharactersInString:@". …⋯"];
    while (value.length && [edgeMarks characterIsMember:[value characterAtIndex:0]]) value = [value substringFromIndex:1];
    while (value.length && [edgeMarks characterIsMember:[value characterAtIndex:value.length - 1]]) value = [value substringToIndex:value.length - 1];
    return normalizedName(value);
}

static BOOL displayedNameMatches(NSString *displayed, NSString *stored) {
    NSString *left = normalizedDisplayedName(displayed);
    NSString *right = normalizedDisplayedName(stored);
    if (!left.length || !right.length) return NO;
    if ([left isEqualToString:right]) return YES;
    // Some Spotify local-file rows truncate the actual UILabel text itself (rather than only clipping
    // it visually). Accept only a useful, unambiguous prefix; the caller rejects multiple matches.
    return (left.length >= 8 && [right hasPrefix:left]) || (right.length >= 8 && [left hasPrefix:right]);
}

NSString *SGLocalArtworkURIForTitleAndArtist(NSString *title, NSString *artist) {
    NSString *wantedTitle = normalizedDisplayedName(title ?: @"");
    NSString *wantedArtist = normalizedDisplayedName(artist ?: @"");
    if (wantedTitle.length < 3) return nil;

    NSDictionary *entries = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMatchesKey];
    NSString *foundURI = nil;
    for (id candidateURI in entries) {
        if (![candidateURI isKindOfClass:NSString.class] || !SGLocalArtworkIsLocalTrack(candidateURI)) continue;
        NSDictionary *entry = [entries[candidateURI] isKindOfClass:NSDictionary.class] ? entries[candidateURI] : nil;
        if (!entry[@"spotifyURI"]) continue;
        NSString *candidateTitle = [entry[@"titleOverride"] isKindOfClass:NSString.class] && [entry[@"titleOverride"] length]
            ? entry[@"titleOverride"] : entry[@"title"];
        NSString *candidateArtist = [entry[@"artistOverride"] isKindOfClass:NSString.class] && [entry[@"artistOverride"] length]
            ? entry[@"artistOverride"] : entry[@"artist"];
        if (!displayedNameMatches(title, candidateTitle ?: @"")) continue;

        BOOL artistMatches = !wantedArtist.length || displayedNameMatches(artist, candidateArtist ?: @"");
        if (!artistMatches && wantedArtist.length) {
            for (NSString *part in [candidateArtist componentsSeparatedByString:@","]) {
                if (displayedNameMatches(artist, part)) { artistMatches = YES; break; }
            }
            if (!artistMatches) {
                for (NSString *part in [artist componentsSeparatedByString:@"·"]) {
                    if (displayedNameMatches(part, candidateArtist ?: @"")) { artistMatches = YES; break; }
                }
            }
        }
        if (!artistMatches) continue;
        // A title-only match is safe only when it identifies one mapped file; never put one song's
        // artwork on another file that happens to share its title.
        if (foundURI) return nil;
        foundURI = candidateURI;
    }
    return foundURI;
}

static void searchArtist(NSString *query, void (^completion)(NSDictionary<NSString *, NSString *> *artist, NSError *error)) {
    NSString *authorization = SGKaraokeSpotifyAuthorization();
    if (!authorization.length) {
        completion(nil, searchError(1, @"Spotify artist search authorization is not available yet."));
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:kSearchAddress];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query],
        [NSURLQueryItem queryItemWithName:@"type" value:@"artist"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = 20;
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSError *error = networkError;
        NSDictionary *match = nil;
        if (!error && (status < 200 || status >= 300)) {
            error = searchError(status, status == 401 || status == 403
                ? @"Spotify rejected the artist search authorization. Play a Spotify track online and try again."
                : [NSString stringWithFormat:@"Spotify artist search failed (HTTP %ld).", (long)status]);
        }
        if (!error && !data.length) error = searchError(status, @"Spotify artist search returned no data.");
        if (!error) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            NSDictionary *artists = [root isKindOfClass:NSDictionary.class] ? root[@"artists"] : nil;
            NSArray *items = [artists isKindOfClass:NSDictionary.class] ? artists[@"items"] : nil;
            if (![items isKindOfClass:NSArray.class] && !error) error = searchError(3, @"Spotify artist search returned an unexpected response.");
            NSString *wanted = normalizedName(query);
            for (id item in items) {
                if (![item isKindOfClass:NSDictionary.class]) continue;
                NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : nil;
                NSString *uri = [item[@"uri"] isKindOfClass:NSString.class] ? item[@"uri"] : nil;
                if (name.length && [uri hasPrefix:@"spotify:artist:"] &&
                    [normalizedName(name) isEqualToString:wanted]) {
                    match = @{@"name": name, @"uri": uri};
                    break;
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(match, error); });
    }] resume];
}

static NSArray<NSDictionary<NSString *, id> *> *tracksFromSearchData(NSData *data, NSError **error) {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSDictionary *tracks = [root isKindOfClass:NSDictionary.class] ? root[@"tracks"] : nil;
    NSArray *items = [tracks isKindOfClass:NSDictionary.class] ? tracks[@"items"] : nil;
    if (![items isKindOfClass:NSArray.class]) {
        if (error && !*error) *error = searchError(3, @"Spotify search returned an unexpected response.");
        return nil;
    }

    NSMutableArray *results = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *uri = [item[@"uri"] isKindOfClass:NSString.class] ? item[@"uri"] : nil;
        NSString *title = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : nil;
        NSDictionary *album = [item[@"album"] isKindOfClass:NSDictionary.class] ? item[@"album"] : nil;
        NSArray *artists = [item[@"artists"] isKindOfClass:NSArray.class] ? item[@"artists"] : nil;
        NSArray *images = [album[@"images"] isKindOfClass:NSArray.class] ? album[@"images"] : nil;
        NSMutableArray<NSString *> *coverURLs = [NSMutableArray array];
        for (id image in images) {
            NSString *candidate = [image isKindOfClass:NSDictionary.class] && [image[@"url"] isKindOfClass:NSString.class]
                ? image[@"url"] : nil;
            NSURLComponents *components = candidate ? [NSURLComponents componentsWithString:candidate] : nil;
            if ([components.scheme.lowercaseString isEqualToString:@"https"] &&
                [components.host.lowercaseString isEqualToString:@"i.scdn.co"] &&
                components.path.length && components.URL) {
                [coverURLs addObject:candidate];
            }
        }
        NSString *coverURL = coverURLs.firstObject;
        if (![uri hasPrefix:@"spotify:track:"] || !title.length) continue;
        NSMutableArray<NSString *> *artistNames = [NSMutableArray array];
        for (id artist in artists) {
            NSString *name = [artist isKindOfClass:NSDictionary.class] && [artist[@"name"] isKindOfClass:NSString.class]
                ? artist[@"name"] : nil;
            if (name.length) [artistNames addObject:name];
        }
        NSMutableDictionary<NSString *, id> *result = [@{
            @"spotifyURI": uri,
            @"title": title,
            @"artist": [artistNames componentsJoinedByString:@", "],
            @"album": [album[@"name"] isKindOfClass:NSString.class] ? album[@"name"] : @"",
        } mutableCopy];
        if (coverURL.length) result[@"coverURL"] = coverURL;
        NSString *thumbnailURL = coverURLs.lastObject ?: coverURL;
        if (thumbnailURL.length) result[@"thumbnailURL"] = thumbnailURL;
        [results addObject:result];
    }
    return results;
}

static NSURLSessionDataTask *searchTracks(NSString *query, void (^completion)(NSArray<NSDictionary<NSString *, id> *> *results, NSError *error)) {
    query = cleanSearchQuery(query);
    NSString *cacheKey = query.lowercaseString;
    NSArray *cached = [searchResultCache() objectForKey:cacheKey];
    if (cached) {
        completion(cached, nil);
        return nil;
    }
    NSString *authorization = SGKaraokeSpotifyAuthorization();
    if (!authorization.length) {
        completion(nil, searchError(1, @"Spotify search authorization is not available yet. Play a Spotify track online, then try again."));
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:kSearchAddress];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query],
        [NSURLQueryItem queryItemWithName:@"type" value:@"track"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"15"],
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = 20;
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSError *error = networkError;
        NSArray *results = nil;
        if (!error && (status < 200 || status >= 300)) {
            NSString *message = status == 401 || status == 403
                ? @"Spotify rejected the search authorization. Play a Spotify track online and search again."
                : [NSString stringWithFormat:@"Spotify search failed (HTTP %ld).", (long)status];
            error = searchError(status, message);
        }
        if (!error && !data.length) error = searchError(status, @"Spotify search returned no data.");
        if (!error) results = tracksFromSearchData(data, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (results) [searchResultCache() setObject:results forKey:cacheKey];
            completion(results, error);
        });
    }];
    [task resume];
    return task;
}

@interface SGLocalArtworkResultCell : UITableViewCell
@property (nonatomic, strong) UIImageView *coverImageView;
@property (nonatomic, strong) UILabel *trackTitleLabel;
@property (nonatomic, strong) UILabel *trackDetailLabel;
@end

@implementation SGLocalArtworkResultCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    (void)style;
    if (!(self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) return nil;
    _coverImageView = [UIImageView new];
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.clipsToBounds = YES;
    _coverImageView.layer.cornerRadius = 8;
    _coverImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _trackTitleLabel = [UILabel new];
    _trackTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _trackTitleLabel.adjustsFontForContentSizeCategory = YES;
    _trackTitleLabel.numberOfLines = 2;
    _trackDetailLabel = [UILabel new];
    _trackDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _trackDetailLabel.textColor = UIColor.secondaryLabelColor;
    _trackDetailLabel.adjustsFontForContentSizeCategory = YES;
    _trackDetailLabel.numberOfLines = 2;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_trackTitleLabel, _trackDetailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 3;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_coverImageView];
    [self.contentView addSubview:labels];
    [NSLayoutConstraint activateConstraints:@[
        [_coverImageView.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [_coverImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_coverImageView.widthAnchor constraintEqualToConstant:56],
        [_coverImageView.heightAnchor constraintEqualToConstant:56],
        [_coverImageView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:10],
        [_coverImageView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        [labels.leadingAnchor constraintEqualToAnchor:_coverImageView.trailingAnchor constant:12],
        [labels.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
        [labels.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:10],
        [labels.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return self;
}
@end

@interface SGLocalArtworkSearchController : UIViewController <UISearchBarDelegate, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *localURI;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITextField *titleField;
@property (nonatomic, strong) UITextField *artistField;
@property (nonatomic, strong) UIButton *artistLinkButton;
@property (nonatomic, strong) UILabel *artistStatusLabel;
@property (nonatomic, strong) UIButton *removeMatchButton;
@property (nonatomic, strong) UIStackView *searchHeader;
@property (nonatomic, strong) UIStackView *detailsStack;
@property (nonatomic, strong) UIButton *detailsToggleButton;
@property (nonatomic, strong) UIImageView *coverPreview;
@property (nonatomic, strong) UILabel *coverTitleLabel;
@property (nonatomic, strong) UILabel *coverSubtitleLabel;
@property (nonatomic, strong) UILabel *photoStatusLabel;
@property (nonatomic, strong) UILabel *catalogHintLabel;
@property (nonatomic, strong) UIButton *choosePhotoButton;
@property (nonatomic, strong) UIButton *removeCustomCoverButton;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *results;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, copy) NSString *lastSearchQuery;
@property (nonatomic, strong) NSURLSessionDataTask *searchTask;
@property (nonatomic) NSUInteger searchGeneration;
@property (nonatomic) NSUInteger artistSearchGeneration;
@property (nonatomic, copy) NSString *matchedArtistName;
@property (nonatomic, copy) NSString *matchedArtistURI;
@property (nonatomic) BOOL detailsExpanded;
@end

@implementation SGLocalArtworkSearchController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"Choose Spotify song";
    SPTPlayerTrack *playing = SGPlayerState().track;
    if ([SGURIString(playing.URI) isEqualToString:self.localURI]) {
        NSString *artist = [playing.artistName isKindOfClass:NSString.class] ? playing.artistName : nil;
        self.navigationItem.prompt = artist.length
            ? [NSString stringWithFormat:@"Local file · %@ — %@", playing.trackTitle ?: @"", artist]
            : [NSString stringWithFormat:@"Local file · %@", playing.trackTitle ?: @""];
    }
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self action:@selector(cancel)];
    UIBarButtonItemStyle saveStyle = UIBarButtonItemStylePlain;
    if (@available(iOS 26.0, *)) saveStyle = UIBarButtonItemStyleProminent;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save"
        style:saveStyle target:self action:@selector(saveNames)];

    _searchBar = [UISearchBar new];
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = @"Search Spotify songs";
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchBar.returnKeyType = UIReturnKeySearch;

    _catalogHintLabel = [UILabel new];
    _catalogHintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _catalogHintLabel.adjustsFontForContentSizeCategory = YES;
    _catalogHintLabel.textColor = UIColor.secondaryLabelColor;
    _catalogHintLabel.numberOfLines = 0;
    _catalogHintLabel.text = @"Choose the Spotify track whose cover and Canvas should appear for this local file. Its audio keeps playing.";

    _titleField = [UITextField new];
    _titleField.borderStyle = UITextBorderStyleRoundedRect;
    _titleField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _titleField.adjustsFontForContentSizeCategory = YES;
    _titleField.placeholder = @"Song name";
    _titleField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _titleField.returnKeyType = UIReturnKeyNext;
    _titleField.delegate = self;
    [_titleField addTarget:self action:@selector(nameFieldChanged:) forControlEvents:UIControlEventEditingChanged];

    _artistField = [UITextField new];
    _artistField.borderStyle = UITextBorderStyleRoundedRect;
    _artistField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _artistField.adjustsFontForContentSizeCategory = YES;
    _artistField.placeholder = @"Artist";
    _artistField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _artistField.returnKeyType = UIReturnKeyDone;
    _artistField.delegate = self;
    [_artistField addTarget:self action:@selector(artistFieldChanged:) forControlEvents:UIControlEventEditingChanged];

    _artistLinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _artistLinkButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _artistLinkButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _artistLinkButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    _artistLinkButton.accessibilityHint = @"Opens the exact matching artist page in Spotify.";
    _artistLinkButton.hidden = YES;
    [_artistLinkButton addTarget:self action:@selector(openMatchedArtist) forControlEvents:UIControlEventTouchUpInside];

    _artistStatusLabel = [UILabel new];
    _artistStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _artistStatusLabel.textColor = UIColor.secondaryLabelColor;
    _artistStatusLabel.numberOfLines = 0;
    _artistStatusLabel.hidden = YES;

    _removeMatchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_removeMatchButton setTitle:@"Remove Spotify song source" forState:UIControlStateNormal];
    [_removeMatchButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    _removeMatchButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _removeMatchButton.hidden = !SGLocalArtworkSpotifyURI(self.localURI);
    [_removeMatchButton addTarget:self action:@selector(removeMatch) forControlEvents:UIControlEventTouchUpInside];

    _coverPreview = [UIImageView new];
    _coverPreview.contentMode = UIViewContentModeScaleAspectFill;
    _coverPreview.clipsToBounds = YES;
    _coverPreview.layer.cornerRadius = 10;
    _coverPreview.backgroundColor = UIColor.tertiarySystemFillColor;
    _coverPreview.translatesAutoresizingMaskIntoConstraints = NO;
    _coverTitleLabel = [UILabel new];
    _coverTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _coverTitleLabel.adjustsFontForContentSizeCategory = YES;
    _coverSubtitleLabel = [UILabel new];
    _coverSubtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _coverSubtitleLabel.textColor = UIColor.secondaryLabelColor;
    _coverSubtitleLabel.adjustsFontForContentSizeCategory = YES;
    _coverSubtitleLabel.numberOfLines = 2;
    UIStackView *coverLabels = [[UIStackView alloc] initWithArrangedSubviews:@[_coverTitleLabel, _coverSubtitleLabel]];
    coverLabels.axis = UILayoutConstraintAxisVertical;
    coverLabels.spacing = 4;
    coverLabels.translatesAutoresizingMaskIntoConstraints = NO;
    _choosePhotoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *photoSymbol = [UIImage systemImageNamed:@"photo.badge.plus"] ?: [UIImage systemImageNamed:@"photo"];
    [_choosePhotoButton setImage:photoSymbol forState:UIControlStateNormal];
    _choosePhotoButton.accessibilityLabel = @"Choose a photo for this track's cover";
    _choosePhotoButton.accessibilityHint = @"Opens the iPhone photo picker.";
    [_choosePhotoButton addTarget:self action:@selector(choosePhoto) forControlEvents:UIControlEventTouchUpInside];
    _choosePhotoButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *coverCard = [UIView new];
    coverCard.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    coverCard.layer.cornerRadius = 16;
    coverCard.translatesAutoresizingMaskIntoConstraints = NO;
    [coverCard addSubview:_coverPreview];
    [coverCard addSubview:coverLabels];
    [coverCard addSubview:_choosePhotoButton];
    [NSLayoutConstraint activateConstraints:@[
        [_coverPreview.leadingAnchor constraintEqualToAnchor:coverCard.leadingAnchor constant:12],
        [_coverPreview.centerYAnchor constraintEqualToAnchor:coverCard.centerYAnchor],
        [_coverPreview.widthAnchor constraintEqualToConstant:64],
        [_coverPreview.heightAnchor constraintEqualToConstant:64],
        [coverLabels.leadingAnchor constraintEqualToAnchor:_coverPreview.trailingAnchor constant:12],
        [coverLabels.centerYAnchor constraintEqualToAnchor:coverCard.centerYAnchor],
        [coverLabels.trailingAnchor constraintEqualToAnchor:_choosePhotoButton.leadingAnchor constant:-8],
        [_choosePhotoButton.trailingAnchor constraintEqualToAnchor:coverCard.trailingAnchor constant:-8],
        [_choosePhotoButton.centerYAnchor constraintEqualToAnchor:coverCard.centerYAnchor],
        [_choosePhotoButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
        [_choosePhotoButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [coverCard.heightAnchor constraintGreaterThanOrEqualToConstant:88],
    ]];
    _photoStatusLabel = [UILabel new];
    _photoStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _photoStatusLabel.textColor = UIColor.secondaryLabelColor;
    _photoStatusLabel.numberOfLines = 0;
    _photoStatusLabel.hidden = YES;
    _removeCustomCoverButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_removeCustomCoverButton setTitle:@"Use Spotify cover instead" forState:UIControlStateNormal];
    _removeCustomCoverButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _removeCustomCoverButton.hidden = !SGLocalArtworkHasCustomCover(self.localURI);
    [_removeCustomCoverButton addTarget:self action:@selector(removeCustomCover) forControlEvents:UIControlEventTouchUpInside];

    _detailsToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_detailsToggleButton setTitle:@"Edit song title and artist" forState:UIControlStateNormal];
    _detailsToggleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_detailsToggleButton setImage:[UIImage systemImageNamed:@"pencil"] forState:UIControlStateNormal];
    _detailsToggleButton.accessibilityHint = @"Shows fields to edit the local file's displayed title and artist.";
    [_detailsToggleButton addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];
    _detailsStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _titleField, _artistField, _artistLinkButton, _artistStatusLabel, _removeMatchButton
    ]];
    _detailsStack.axis = UILayoutConstraintAxisVertical;
    _detailsStack.spacing = 8;
    _detailsStack.hidden = YES;
    _searchHeader = [[UIStackView alloc] initWithArrangedSubviews:@[
        coverCard, _photoStatusLabel, _removeCustomCoverButton, _catalogHintLabel, _searchBar,
        _detailsToggleButton, _detailsStack
    ]];
    _searchHeader.axis = UILayoutConstraintAxisVertical;
    _searchHeader.spacing = 6;
    _searchHeader.layoutMargins = UIEdgeInsetsMake(12, 16, 8, 16);
    _searchHeader.layoutMarginsRelativeArrangement = YES;
    _searchHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_searchHeader];
    [_titleField.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [_artistField.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [_detailsToggleButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [_artistLinkButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [_removeMatchButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [_removeCustomCoverButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 80;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [_tableView registerClass:SGLocalArtworkResultCell.class forCellReuseIdentifier:@"SpotifyTrack"];
    [self.view addSubview:_tableView];

    _messageLabel = [UILabel new];
    _messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _messageLabel.textColor = UIColor.secondaryLabelColor;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;
    _messageLabel.hidden = YES;
    _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_messageLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[
        [_searchHeader.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_searchHeader.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_searchHeader.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.topAnchor constraintEqualToAnchor:_searchHeader.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_messageLabel.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_messageLabel.centerYAnchor constraintEqualToAnchor:_tableView.centerYAnchor],
        [_messageLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:28],
        [_messageLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-28],
        [_spinner.centerXAnchor constraintEqualToAnchor:_tableView.centerXAnchor],
        [_spinner.topAnchor constraintEqualToAnchor:_tableView.topAnchor constant:24],
    ]];
    self.tableView.tableFooterView = [UIView new];
    NSDictionary *match = SGLocalArtworkMatch(self.localURI);
    _titleField.text = SGLocalArtworkTitle(self.localURI) ?: ([playing.trackTitle isKindOfClass:NSString.class] ? playing.trackTitle : match[@"title"]);
    _artistField.text = SGLocalArtworkArtist(self.localURI) ?: ([playing.artistName isKindOfClass:NSString.class] ? playing.artistName : match[@"artist"]);
    _titleField.accessibilityLabel = @"Song title";
    _artistField.accessibilityLabel = @"Artist";
    [self updateCoverCard];
    [self updateMessage];
    if (_artistField.text.length) [self scheduleArtistSearch];
    if ([SGURIString(playing.URI) isEqualToString:self.localURI]) {
        NSString *title = _titleField.text;
        NSString *artist = _artistField.text;
        NSString *query = [[@[title ?: @"", artist ?: @""] componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (query.length >= 2) {
            _searchBar.text = query;
            [self searchBar:_searchBar textDidChange:query];
        }
    }
}

- (void)updateCoverCard {
    BOOL custom = SGLocalArtworkHasCustomCover(self.localURI);
    NSString *fallback = SGLocalArtworkSpotifyURI(self.localURI) ? @"Use matched Spotify cover" : @"Use file's embedded cover";
    [_removeCustomCoverButton setTitle:fallback forState:UIControlStateNormal];
    _coverTitleLabel.text = custom ? @"Custom photo" : @"Cover artwork";
    _coverSubtitleLabel.text = custom
        ? @"Used for this file; the Spotify match can still supply its Canvas."
        : (SGLocalArtworkSpotifyURI(self.localURI)
        ? @"The matched Spotify song supplies its cover and Canvas when available."
        : @"Choose a photo, or select a Spotify song below for its cover and Canvas.");
    _removeCustomCoverButton.hidden = !custom;
    _choosePhotoButton.accessibilityLabel = custom ? @"Change custom cover photo" : @"Choose a custom cover photo";
    UIImage *cover = SGLocalArtworkCachedCover(self.localURI);
    _coverPreview.image = cover ?: [UIImage systemImageNamed:@"music.note"];
    _coverPreview.tintColor = UIColor.secondaryLabelColor;
    if (!cover && SGLocalArtworkCoverURL(self.localURI)) {
        NSString *uri = self.localURI;
        NSString *url = SGLocalArtworkCoverURL(uri);
        __weak SGLocalArtworkSearchController *weakSelf = self;
        SGLocalArtworkLoadCover(uri, ^(UIImage *image) {
            SGLocalArtworkSearchController *strongSelf = weakSelf;
            if (image && strongSelf && [uri isEqualToString:strongSelf.localURI] &&
                [url isEqualToString:SGLocalArtworkCoverURL(uri)]) {
                strongSelf.coverPreview.image = image;
            }
        });
    }
}

- (void)toggleDetails {
    self.detailsExpanded = !self.detailsExpanded;
    self.detailsStack.hidden = !self.detailsExpanded;
    [_detailsToggleButton setTitle:self.detailsExpanded ? @"Hide song details" : @"Edit song title and artist"
                          forState:UIControlStateNormal];
    [UIView animateWithDuration:0.2 animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)choosePhoto {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = PHPickerFilter.imagesFilter;
    configuration.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    PHPickerResult *result = results.firstObject;
    if (!result) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) {
        [picker dismissViewControllerAnimated:YES completion:^{
            self.photoStatusLabel.text = @"This photo format couldn't be opened. Choose another image.";
            self.photoStatusLabel.hidden = NO;
        }];
        SGLog(@"local artwork: selected photo could not provide an image");
        return;
    }
    __weak SGLocalArtworkSearchController *weakSelf = self;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *loadError) {
        UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGLocalArtworkSearchController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [picker dismissViewControllerAnimated:YES completion:^{
                if (!image || loadError) {
                    NSString *message = loadError.localizedDescription ?: @"The selected photo couldn't be opened.";
                    SGLog(@"local artwork: photo import failed (%@)", message);
                    strongSelf.photoStatusLabel.text = [NSString stringWithFormat:@"Couldn't use that photo: %@", message];
                    strongSelf.photoStatusLabel.hidden = NO;
                    return;
                }
                strongSelf.photoStatusLabel.text = @"Saving cover photo…";
                strongSelf.photoStatusLabel.hidden = NO;
                strongSelf.choosePhotoButton.enabled = NO;
                strongSelf.removeCustomCoverButton.enabled = NO;
                NSString *uri = strongSelf.localURI;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSError *saveError = nil;
                    BOOL saved = SGLocalArtworkSaveCustomCover(uri, image, &saveError);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SGLocalArtworkSearchController *current = weakSelf;
                        if (!current) return;
                        current.choosePhotoButton.enabled = YES;
                        current.removeCustomCoverButton.enabled = YES;
                        if (!saved) {
                            NSString *message = saveError.localizedDescription ?: @"The photo couldn't be saved.";
                            SGLog(@"local artwork: custom cover save failed (%@)", message);
                            current.photoStatusLabel.text = [NSString stringWithFormat:@"Couldn't save that photo: %@", message];
                            current.photoStatusLabel.hidden = NO;
                            return;
                        }
                        current.photoStatusLabel.hidden = YES;
                        [current updateCoverCard];
                    });
                });
            }];
        });
    }];
}

- (void)removeCustomCover {
    NSError *error = nil;
    if (!SGLocalArtworkRemoveCustomCover(self.localURI, &error)) {
        NSString *message = error.localizedDescription ?: @"The custom photo couldn't be removed.";
        SGLog(@"local artwork: custom cover removal failed (%@)", message);
        _photoStatusLabel.text = [NSString stringWithFormat:@"Couldn't remove that photo: %@", message];
        _photoStatusLabel.hidden = NO;
        return;
    }
    _photoStatusLabel.hidden = YES;
    [self updateCoverCard];
}

- (void)dealloc {
    [_searchTask cancel];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)removeMatch {
    SGLocalArtworkRemoveMatch(self.localURI);
    _removeMatchButton.hidden = YES;
    [self updateCoverCard];
}

- (void)saveNames {
    SGLocalArtworkSaveNames(self.localURI, _titleField.text, _artistField.text);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)nameFieldChanged:(UITextField *)field {
    (void)field;
    UIBarButtonItem *save = self.navigationItem.rightBarButtonItem;
    save.enabled = YES;
    NSString *title = [_titleField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *artist = [_artistField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *query = [[@[title, artist] componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _searchBar.text = query;
    [self searchBar:_searchBar textDidChange:query];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _titleField) {
        [_artistField becomeFirstResponder];
        return NO;
    }
    [textField resignFirstResponder];
    return YES;
}

- (void)artistFieldChanged:(UITextField *)field {
    (void)field;
    [self nameFieldChanged:field];
    [self scheduleArtistSearch];
}

- (void)scheduleArtistSearch {
    NSString *query = [_artistField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger generation = ++_artistSearchGeneration;
    _matchedArtistName = nil;
    _matchedArtistURI = nil;
    _artistLinkButton.hidden = YES;
    if (query.length < 2) {
        _artistStatusLabel.text = nil;
        _artistStatusLabel.hidden = YES;
        return;
    }
    _artistStatusLabel.text = @"Checking for an exact Spotify artist match…";
    _artistStatusLabel.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.artistSearchGeneration) return;
        __weak SGLocalArtworkSearchController *weakSelf = self;
        searchArtist(query, ^(NSDictionary<NSString *,NSString *> *artist, NSError *error) {
            SGLocalArtworkSearchController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.artistSearchGeneration) return;
            if (![normalizedName(strongSelf.artistField.text) isEqualToString:normalizedName(query)]) return;
            strongSelf.matchedArtistName = artist[@"name"];
            strongSelf.matchedArtistURI = artist[@"uri"];
            strongSelf.artistLinkButton.hidden = !artist;
            if (artist) {
                [strongSelf.artistLinkButton setTitle:[NSString stringWithFormat:@"Open %@ on Spotify  ›", artist[@"name"]]
                                              forState:UIControlStateNormal];
                strongSelf.artistStatusLabel.hidden = YES;
            } else {
                strongSelf.artistStatusLabel.text = error
                    ? [NSString stringWithFormat:@"Could not check Spotify artists: %@", error.localizedDescription]
                    : @"No Spotify artist with this exact name was found.";
                strongSelf.artistStatusLabel.hidden = NO;
            }
        });
    });
}

- (void)openMatchedArtist {
    if (!_matchedArtistURI.length ||
        ![normalizedName(_artistField.text) isEqualToString:normalizedName(_matchedArtistName)]) return;
    NSURL *uri = [NSURL URLWithString:_matchedArtistURI];
    UIViewController *presenter = self.navigationController.presentingViewController ?: self.presentingViewController;
    UIViewController *dismissal = self.navigationController ?: self;
    [dismissal dismissViewControllerAnimated:YES completion:^{
        if (SGOpenSpotifyURI(uri)) return;
        SGLog(@"local artwork: Spotify did not open an exact artist match");
        if (!presenter || presenter.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't open artist"
            message:@"Spotify could not open this artist page right now." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)searchTracksForQuery:(NSString *)searchText delay:(NSTimeInterval)delay {
    NSString *query = cleanSearchQuery(searchText ?: @"");
    if ([query isEqualToString:_lastSearchQuery] &&
        (_searchTask || (_spinner.isAnimating && delay > 0))) return;
    NSUInteger generation = ++_searchGeneration;
    [_searchTask cancel];
    _searchTask = nil;
    _errorMessage = nil;
    _lastSearchQuery = query;
    if (query.length < 2) {
        _results = @[];
        _tableView.userInteractionEnabled = YES;
        [_tableView reloadData];
        [self.spinner stopAnimating];
        [self updateMessage];
        return;
    }
    _tableView.userInteractionEnabled = NO;
    self.messageLabel.hidden = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.searchGeneration) return;
        __weak SGLocalArtworkSearchController *weakSelf = self;
        self.searchTask = searchTracks(query, ^(NSArray<NSDictionary<NSString *,id> *> *results, NSError *error) {
            SGLocalArtworkSearchController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.searchGeneration) return;
            strongSelf.searchTask = nil;
            strongSelf.results = results ?: @[];
            strongSelf.errorMessage = error.localizedDescription;
            strongSelf.tableView.userInteractionEnabled = YES;
            [strongSelf.spinner stopAnimating];
            [UIView performWithoutAnimation:^{ [strongSelf.tableView reloadData]; }];
            [strongSelf updateMessage];
        });
        NSURLSessionDataTask *task = self.searchTask;
        if (task) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (generation == self.searchGeneration && self.searchTask == task) {
                    [self.spinner startAnimating];
                }
            });
        }
    });
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    [self searchTracksForQuery:searchText delay:0.22];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self searchTracksForQuery:searchBar.text delay:0];
}

- (void)updateMessage {
    if (_spinner.isAnimating) {
        _messageLabel.hidden = YES;
        return;
    }
    if (_results.count) {
        _messageLabel.hidden = YES;
        return;
    }
    if (_errorMessage.length) _messageLabel.text = _errorMessage;
    else if (_searchBar.text.length < 2) _messageLabel.text = @"Search Spotify by song or artist. The selected cover and Canvas are used while the local audio keeps playing.";
    else _messageLabel.text = @"No matching Spotify songs found.";
    _messageLabel.hidden = NO;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return _results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SGLocalArtworkResultCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SpotifyTrack" forIndexPath:indexPath];
    NSDictionary *result = _results[indexPath.row];
    cell.trackTitleLabel.text = result[@"title"];
    cell.trackDetailLabel.text = [NSString stringWithFormat:@"%@ · %@", result[@"artist"] ?: @"Unknown artist",
                                  result[@"album"] ?: @"Unknown album"];
    cell.accessoryType = [result[@"spotifyURI"] isEqualToString:SGLocalArtworkSpotifyURI(_localURI)]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    cell.coverImageView.image = [UIImage systemImageNamed:@"music.note"];
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",
        result[@"title"], result[@"artist"] ?: @"", result[@"album"] ?: @""];
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    NSString *coverURL = result[@"coverURL"];
    NSString *thumbnailURL = result[@"thumbnailURL"] ?: coverURL;
    cell.accessibilityIdentifier = thumbnailURL;
    UIImage *cachedCover = [searchCoverCache() objectForKey:thumbnailURL];
    if (cachedCover) cell.coverImageView.image = cachedCover;
    NSURL *url = [NSURL URLWithString:thumbnailURL];
    if (url && !cachedCover) {
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *image = data.length && !error ? [UIImage imageWithData:data] : nil;
            if (!image) return;
            NSUInteger cost = (NSUInteger)(image.size.width * image.size.height * 4);
            [searchCoverCache() setObject:image forKey:thumbnailURL cost:cost];
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLocalArtworkResultCell *visible = (SGLocalArtworkResultCell *)[tableView cellForRowAtIndexPath:indexPath];
                if (![visible.accessibilityIdentifier isEqualToString:thumbnailURL]) return;
                visible.coverImageView.image = image;
                [visible setNeedsLayout];
            });
        }] resume];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (!_tableView.userInteractionEnabled || indexPath.row >= _results.count) return;
    NSDictionary *match = _results[indexPath.row];
    SGLocalArtworkSaveSelection(_localURI, match, _titleField.text, _artistField.text);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

void SGLocalArtworkPresentEditor(NSString *localURI, UIViewController *presenter) {
    if (!SGLocalArtworkIsLocalTrack(localURI)) {
        SGLog(@"local artwork: editor requested for a non-local track");
        return;
    }
    if (!presenter || presenter.presentedViewController) {
        SGLog(@"local artwork: cannot present editor because its player is unavailable or presenting another screen");
        return;
    }
    SGLocalArtworkSearchController *editor = [SGLocalArtworkSearchController new];
    editor.localURI = localURI;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:editor];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[
            [UISheetPresentationControllerDetent mediumDetent],
            [UISheetPresentationControllerDetent largeDetent],
        ];
        navigation.sheetPresentationController.selectedDetentIdentifier =
            UISheetPresentationControllerDetentIdentifierLarge;
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
        navigation.sheetPresentationController.preferredCornerRadius = 24;
    }
    [presenter presentViewController:navigation animated:YES completion:nil];
}

%hook SPTPlayerTrack
- (NSString *)trackTitle {
    NSString *override = SGLocalArtworkTitle(SGURIString(self.URI));
    return override.length ? override : %orig;
}
- (NSString *)artistName {
    NSString *override = SGLocalArtworkArtist(SGURIString(self.URI));
    return override.length ? override : %orig;
}
- (NSDictionary<NSString *, NSString *> *)metadata {
    NSDictionary *metadata = %orig;
    NSString *uri = SGURIString(self.URI);
    NSDictionary *match = SGLocalArtworkMatch(uri);
    NSString *coverURL = match[@"coverURL"];
    NSString *title = SGLocalArtworkTitle(uri);
    NSString *artist = SGLocalArtworkArtist(uri);
    if (!coverURL.length && !title.length && !artist.length) return metadata;
    NSMutableDictionary *updated = [metadata isKindOfClass:NSDictionary.class]
        ? [metadata mutableCopy] : [NSMutableDictionary dictionary];
    if (coverURL.length) {
        updated[@"image_xlarge_url"] = coverURL;
        updated[@"image_large_url"] = coverURL;
        updated[@"image_url"] = coverURL;
        updated[@"image_small_url"] = coverURL;
    }
    if (title.length) {
        updated[@"track_title"] = title;
        updated[@"track_name"] = title;
    }
    if (artist.length) {
        for (NSString *key in updated.allKeys) {
            if ([key isEqualToString:@"artist_name"] ||
                [key hasPrefix:@"artist_name:"] ||
                [key isEqualToString:@"artist_uri"] ||
                [key hasPrefix:@"artist_uri:"]) {
                [updated removeObjectForKey:key];
            }
        }
        updated[@"artist_name"] = artist;
    }
    NSString *album = [match[@"album"] isKindOfClass:NSString.class] ? match[@"album"] : nil;
    if (album.length) updated[@"album_title"] = album;
    return [updated copy];
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTPlayerTrack"]);
}
