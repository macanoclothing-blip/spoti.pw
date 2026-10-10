#import "Core/SGCore.h"
#import "SGArtistLogo.h"

static NSString *const kKey = @"spotipw.fanart.artistLogo.key";
static NSString *const kMusicBrainz = @"https://musicbrainz.org/ws/2/artist";
static NSString *const kFanart = @"https://webservice.fanart.tv/v3/music";
static const NSTimeInterval kTimeout = 15;
static const NSTimeInterval kLogoCacheTime = 24 * 60 * 60, kMissCacheTime = 5 * 60;

NSNotificationName const SGRArtistLogoKeyDidChangeNotification = @"spotifyglass.artistLogoKeyDidChange";

static NSMutableDictionary<NSString *, id> *sg_cache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_pending;
static NSDate *sg_nextMusicBrainzRequest;
static NSUInteger sg_generation;

static NSString *storedKey(void) {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:kKey];
    return key.length ? key : nil;
}

NSString *SGRArtistLogoKeyShown(void) {
    NSString *key = storedKey();
    if (key.length <= 12) return key;
    return [NSString stringWithFormat:@"%@…%@", [key substringToIndex:6], [key substringFromIndex:key.length - 4]];
}

NSString *SGRArtistLogoSetKey(NSString *text) {
    NSString *key = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if ([key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        return @"The Fanart.tv API key cannot contain whitespace.";
    }
    if (key.length && key.length < 16) return @"That API key is too short.";
    if (key.length) [NSUserDefaults.standardUserDefaults setObject:key forKey:kKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kKey];
    sg_generation++;
    [sg_cache removeAllObjects];
    [sg_pending removeAllObjects];
    SGLog(@"artist logos: Fanart.tv key %@", key.length ? @"stored" : @"removed");
    [NSNotificationCenter.defaultCenter postNotificationName:SGRArtistLogoKeyDidChangeNotification object:nil];
    return nil;
}

static NSString *cacheKey(NSString *artist) {
    NSString *trimmed = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:NSLocale.currentLocale];
}

static NSString *matchKey(NSString *artist) {
    NSString *folded = [[artist stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:NSLocale.currentLocale]
        lowercaseString];
    return [[folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

static void sendJSON(NSURLRequest *request, void (^done)(NSDictionary *, NSError *)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            done(nil, error);
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            NSInteger status = http ? http.statusCode : 0;
            done(nil, [NSError errorWithDomain:@"spoti.pw.artist-logo" code:status
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}]);
            return;
        }
        NSError *parseError = nil;
        id value = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
        if (![value isKindOfClass:NSDictionary.class]) {
            done(nil, parseError ?: [NSError errorWithDomain:@"spoti.pw.artist-logo" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Unexpected JSON response"}]);
            return;
        }
        done(value, nil);
    }] resume];
}

static void finishArtist(NSString *key, UIImage *logo, NSUInteger generation) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != sg_generation) return;
        if (!sg_cache) sg_cache = [NSMutableDictionary dictionary];
        if (!sg_pending) sg_pending = [NSMutableDictionary dictionary];
        if (sg_cache.count >= 100) [sg_cache removeAllObjects];
        NSTimeInterval lifetime = logo ? kLogoCacheTime : kMissCacheTime;
        sg_cache[key] = @{@"image": logo ?: NSNull.null, @"expires": [NSDate dateWithTimeIntervalSinceNow:lifetime]};
        NSArray *callbacks = [sg_pending[key] copy];
        [sg_pending removeObjectForKey:key];
        for (id value in callbacks) {
            void (^callback)(UIImage *) = value;
            callback(logo);
        }
    });
}

static NSArray<NSString *> *musicBrainzIDs(NSDictionary *body, NSString *artist) {
    NSArray *artists = [body[@"artists"] isKindOfClass:NSArray.class] ? body[@"artists"] : nil;
    NSString *wanted = matchKey(artist);
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (id value in artists) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *candidate = value;
        NSString *name = [candidate[@"name"] isKindOfClass:NSString.class] ? candidate[@"name"] : nil;
        NSString *sortName = [candidate[@"sort-name"] isKindOfClass:NSString.class] ? candidate[@"sort-name"] : nil;
        NSString *identifier = [candidate[@"id"] isKindOfClass:NSString.class] ? candidate[@"id"] : nil;
        if (!identifier.length || ![[NSUUID alloc] initWithUUIDString:identifier]) continue;
        BOOL nameMatches = name.length && [matchKey(name) isEqualToString:wanted];
        BOOL sortNameMatches = sortName.length && [matchKey(sortName) isEqualToString:wanted];
        NSArray *aliases = [candidate[@"aliases"] isKindOfClass:NSArray.class] ? candidate[@"aliases"] : nil;
        BOOL aliasMatches = NO;
        for (id alias in aliases) {
            NSString *aliasName = [alias isKindOfClass:NSDictionary.class] && [alias[@"name"] isKindOfClass:NSString.class] ? alias[@"name"] : nil;
            if (aliasName.length && [matchKey(aliasName) isEqualToString:wanted]) {
                aliasMatches = YES;
                break;
            }
        }
        if (!nameMatches && !sortNameMatches && !aliasMatches) continue;
        NSInteger score = [candidate[@"score"] respondsToSelector:@selector(integerValue)] ? [candidate[@"score"] integerValue] : 0;
        [matches addObject:@{@"id": identifier, @"score": @(score), @"rank": @(nameMatches ? 2 : (aliasMatches ? 1 : 0))}];
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger ar = [a[@"rank"] integerValue], br = [b[@"rank"] integerValue];
        if (ar != br) return ar > br ? NSOrderedAscending : NSOrderedDescending;
        NSInteger as = [a[@"score"] integerValue], bs = [b[@"score"] integerValue];
        return as > bs ? NSOrderedAscending : (as < bs ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:matches.count];
    for (NSDictionary *match in matches) [identifiers addObject:match[@"id"]];
    return identifiers;
}

static NSURL *musicBrainzURL(NSString *artist) {
    NSURLComponents *components = [NSURLComponents componentsWithString:kMusicBrainz];
    NSString *escaped = [[artist stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:[NSString stringWithFormat:@"artist:\"%@\"", escaped]],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
    ];
    return components.URL;
}

static NSURL *fanartURL(NSString *identifier, NSString *key) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[kFanart stringByAppendingFormat:@"/%@", identifier]];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"api_key" value:key]];
    return components.URL;
}

static NSURL *logoURL(NSDictionary *body) {
    for (NSString *field in @[@"hdmusiclogo", @"musiclogo"]) {
        NSArray *items = [body[field] isKindOfClass:NSArray.class] ? body[field] : nil;
        NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
        for (id item in items) if ([item isKindOfClass:NSDictionary.class]) [valid addObject:item];
        NSArray<NSDictionary *> *sorted = [valid sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSInteger first = [a[@"likes"] respondsToSelector:@selector(integerValue)] ? [a[@"likes"] integerValue] : 0;
            NSInteger second = [b[@"likes"] respondsToSelector:@selector(integerValue)] ? [b[@"likes"] integerValue] : 0;
            return first > second ? NSOrderedAscending : (first < second ? NSOrderedDescending : NSOrderedSame);
        }];
        for (id value in sorted) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSURL *url = [NSURL URLWithString:[value[@"url"] isKindOfClass:NSString.class] ? value[@"url"] : @""];
            if ([url.scheme.lowercaseString isEqualToString:@"https"]) return url;
        }
    }
    return nil;
}

static UIImage *trimmedLogo(UIImage *image) {
    CGImageRef source = image.CGImage;
    if (!source) return image;
    size_t width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    if (!width || !height || width > 4096 || height > 4096) return image;
    size_t bytesPerRow = width * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bytesPerRow * height];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, bytesPerRow, colorSpace,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) return image;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
    CGContextRelease(context);
    const uint8_t *data = pixels.bytes;
    size_t minX = width, minY = height, maxX = 0, maxY = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (data[y * bytesPerRow + x * 4 + 3] <= 8) continue;
            minX = MIN(minX, x);
            minY = MIN(minY, y);
            maxX = MAX(maxX, x);
            maxY = MAX(maxY, y);
        }
    }
    if (minX == width || maxX <= minX || maxY <= minY) return image;
    size_t padX = MAX((size_t)1, (maxX - minX) / 80), padY = MAX((size_t)1, (maxY - minY) / 80);
    minX = minX > padX ? minX - padX : 0;
    minY = minY > padY ? minY - padY : 0;
    maxX = MIN(width - 1, maxX + padX);
    maxY = MIN(height - 1, maxY + padY);
    CGImageRef cropped = CGImageCreateWithImageInRect(source, CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1));
    if (!cropped) return image;
    UIImage *result = [UIImage imageWithCGImage:cropped scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cropped);
    return result;
}

static void fetchFanartForIDs(NSArray<NSString *> *identifiers, NSUInteger index, NSString *key, NSString *lookupKey, NSUInteger generation);

static void loadLogo(NSString *artist, NSString *key, NSString *lookupKey, NSUInteger generation) {
    NSURL *lookupURL = musicBrainzURL(artist);
    if (!lookupURL) {
        SGLog(@"artist logos: could not form MusicBrainz lookup URL");
        finishArtist(lookupKey, nil, generation);
        return;
    }
    NSMutableURLRequest *lookup = [NSMutableURLRequest requestWithURL:lookupURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    [lookup setValue:@"spoti.pw artist logos (https://github.com/macanoclothing-blip/spoti.pw)" forHTTPHeaderField:@"User-Agent"];
    sendJSON(lookup, ^(NSDictionary *body, NSError *error) {
        if (error) {
            SGLog(@"artist logos: MusicBrainz lookup failed: %@", error.localizedDescription);
            finishArtist(lookupKey, nil, generation);
            return;
        }
        NSArray<NSString *> *identifiers = musicBrainzIDs(body, artist);
        if (!identifiers.count) {
            SGLog(@"artist logos: MusicBrainz returned no exact name, sort-name or alias match");
            finishArtist(lookupKey, nil, generation);
            return;
        }
        fetchFanartForIDs(identifiers, 0, key, lookupKey, generation);
    });
}

static void fetchFanartForIDs(NSArray<NSString *> *identifiers, NSUInteger index, NSString *key, NSString *lookupKey, NSUInteger generation) {
    if (index >= identifiers.count) {
        SGLog(@"artist logos: no Fanart.tv logo matched any exact MusicBrainz candidate");
        finishArtist(lookupKey, nil, generation);
        return;
    }
    NSURL *url = fanartURL(identifiers[index], key);
    if (!url) {
        SGLog(@"artist logos: could not form Fanart.tv request URL");
        fetchFanartForIDs(identifiers, index + 1, key, lookupKey, generation);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    sendJSON(request, ^(NSDictionary *fanart, NSError *error) {
        if (error) {
            if (error.code == 404) {
                fetchFanartForIDs(identifiers, index + 1, key, lookupKey, generation);
            } else {
                SGLog(@"artist logos: Fanart.tv lookup failed: %@", error.localizedDescription);
                finishArtist(lookupKey, nil, generation);
            }
            return;
        }
        NSURL *imageURL = logoURL(fanart);
        if (!imageURL) {
            fetchFanartForIDs(identifiers, index + 1, key, lookupKey, generation);
            return;
        }
        NSURLRequest *imageRequest = [NSURLRequest requestWithURL:imageURL cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:kTimeout];
        [[NSURLSession.sharedSession dataTaskWithRequest:imageRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *imageError) {
            if (imageError) {
                SGLog(@"artist logos: image download failed: %@", imageError.localizedDescription);
                finishArtist(lookupKey, nil, generation);
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (!http || http.statusCode < 200 || http.statusCode >= 300) {
                SGLog(@"artist logos: image download returned HTTP %ld", (long)(http ? http.statusCode : 0));
                finishArtist(lookupKey, nil, generation);
                return;
            }
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            if (!image) SGLog(@"artist logos: downloaded logo was not a valid image");
            finishArtist(lookupKey, trimmedLogo(image), generation);
        }] resume];
    });
}

void SGRArtistLogoForArtist(NSString *artist, void (^done)(UIImage *)) {
    NSString *cleanArtist = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lookupKey = cacheKey(cleanArtist ?: @"");
    if (!lookupKey.length || !done) return;
    NSString *key = storedKey();
    if (!key) {
        done(nil);
        return;
    }
    if (!sg_cache) sg_cache = [NSMutableDictionary dictionary];
    if (!sg_pending) sg_pending = [NSMutableDictionary dictionary];
    NSDictionary *cached = sg_cache[lookupKey];
    if (cached) {
        NSDate *expiry = [cached[@"expires"] isKindOfClass:NSDate.class] ? cached[@"expires"] : nil;
        if (expiry && [expiry timeIntervalSinceNow] > 0) {
            id image = cached[@"image"];
            done(image == NSNull.null ? nil : [image isKindOfClass:UIImage.class] ? image : nil);
            return;
        }
        [sg_cache removeObjectForKey:lookupKey];
    }
    if (sg_pending[lookupKey]) {
        [sg_pending[lookupKey] addObject:[done copy]];
        return;
    }
    sg_pending[lookupKey] = [NSMutableArray arrayWithObject:[done copy]];
    NSUInteger generation = sg_generation;
    NSTimeInterval delay = MAX(0, [sg_nextMusicBrainzRequest timeIntervalSinceNow]);
    sg_nextMusicBrainzRequest = [NSDate dateWithTimeIntervalSinceNow:delay + 1.1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        loadLogo(cleanArtist, key, lookupKey, generation);
    });
}
