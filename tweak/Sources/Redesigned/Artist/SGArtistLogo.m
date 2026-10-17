#import "Core/SGCore.h"
#import "SGArtistLogo.h"
#import "Shared/LockScreenArtwork/SGAppleArtwork.h"
#import <math.h>

static NSString *const kKey = @"spotipw.fanart.artistLogo.key";
static NSString *const kMusicBrainz = @"https://musicbrainz.org/ws/2/artist";
static NSString *const kFanart = @"https://webservice.fanart.tv/v3/music";
static NSString *const kAppleSearch = @"https://amp-api.music.apple.com/v1/catalog/us/search";
static NSString *const kAppleOrigin = @"https://music.apple.com";
static NSString *const kAppleUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
                                          "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
static const NSTimeInterval kTimeout = 15;
static const NSTimeInterval kLogoCacheTime = 24 * 60 * 60, kMissCacheTime = 5 * 60;
static const NSUInteger kFanartCandidateLimit = 20;

NSNotificationName const SGRArtistLogoKeyDidChangeNotification = @"spotifyglass.artistLogoKeyDidChange";

static NSMutableDictionary<NSString *, id> *sg_cache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_pending;
static NSDate *sg_nextMusicBrainzRequest;
static NSDate *sg_appleQuietUntil;
static NSUInteger sg_generation;

static void invalidateArtistLogos(void) {
    sg_generation++;
    [sg_cache removeAllObjects];
    [sg_pending removeAllObjects];
}

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
    invalidateArtistLogos();
    SGLog(@"artist logos: Fanart.tv key %@", key.length ? @"stored" : @"removed");
    [NSNotificationCenter.defaultCenter postNotificationName:SGRArtistLogoKeyDidChangeNotification object:nil];
    return nil;
}

BOOL SGRArtistLogoAppleEnabled(void) {
    return SGFlag(SGRKeyArtistLogoApple, NO);
}

void SGRArtistLogoSetAppleEnabled(BOOL enabled) {
    SGSetEnabled(SGRKeyArtistLogoApple, enabled);
    invalidateArtistLogos();
    SGLog(@"artist logos: Apple Music fallback %@", enabled ? @"enabled" : @"disabled");
    [NSNotificationCenter.defaultCenter postNotificationName:SGRArtistLogoKeyDidChangeNotification object:nil];
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

static NSTimeInterval failureCacheTime(NSError *error) {
    if (error.code == 429 || error.code == 503 || error.code == NSURLErrorTimedOut
        || error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorNotConnectedToInternet) return 30;
    return kMissCacheTime;
}

static void finishArtist(NSString *key, UIImage *logo, NSUInteger generation, NSTimeInterval missCacheTime) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != sg_generation) return;
        if (!sg_cache) sg_cache = [NSMutableDictionary dictionary];
        if (!sg_pending) sg_pending = [NSMutableDictionary dictionary];
        if (sg_cache.count >= 100) [sg_cache removeAllObjects];
        NSTimeInterval lifetime = logo ? kLogoCacheTime : missCacheTime;
        sg_cache[key] = @{@"image": logo ?: NSNull.null, @"expires": [NSDate dateWithTimeIntervalSinceNow:lifetime]};
        NSArray *callbacks = [sg_pending[key] copy];
        [sg_pending removeObjectForKey:key];
        for (id value in callbacks) {
            void (^callback)(UIImage *) = value;
            callback(logo);
        }
    });
}

static NSURL *appleLogoURL(NSDictionary *artwork) {
    NSString *address = [artwork[@"url"] isKindOfClass:NSString.class] ? artwork[@"url"] : nil;
    if (!address.length) return nil;
    CGFloat sourceWidth = [artwork[@"width"] respondsToSelector:@selector(doubleValue)] ? [artwork[@"width"] doubleValue] : 0;
    CGFloat sourceHeight = [artwork[@"height"] respondsToSelector:@selector(doubleValue)] ? [artwork[@"height"] doubleValue] : 0;
    if (!isfinite(sourceWidth) || sourceWidth <= 0) sourceWidth = 2048;
    if (!isfinite(sourceHeight) || sourceHeight <= 0) sourceHeight = sourceWidth;
    NSInteger width = (NSInteger)MIN(2048, sourceWidth);
    NSInteger height = MAX(1, (NSInteger)lround(width * sourceHeight / sourceWidth));
    address = [[address stringByReplacingOccurrencesOfString:@"{w}" withString:[NSString stringWithFormat:@"%ld", (long)width]]
        stringByReplacingOccurrencesOfString:@"{h}" withString:[NSString stringWithFormat:@"%ld", (long)height]];
    address = [address stringByReplacingOccurrencesOfString:@"%7Bw%7D" withString:[NSString stringWithFormat:@"%ld", (long)width]];
    address = [address stringByReplacingOccurrencesOfString:@"%7bw%7d" withString:[NSString stringWithFormat:@"%ld", (long)width]];
    address = [address stringByReplacingOccurrencesOfString:@"%7Bh%7D" withString:[NSString stringWithFormat:@"%ld", (long)height]];
    address = [address stringByReplacingOccurrencesOfString:@"%7bh%7d" withString:[NSString stringWithFormat:@"%ld", (long)height]];
    address = [address stringByReplacingOccurrencesOfString:@"{f}" withString:@"png"];
    NSRange jpg = [address rangeOfString:@".jpg" options:NSBackwardsSearch];
    if (jpg.location != NSNotFound && NSMaxRange(jpg) == address.length) {
        address = [address stringByReplacingCharactersInRange:jpg withString:@".png"];
    }
    NSURL *url = [NSURL URLWithString:address];
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length ? url : nil;
}

static void fetchAppleArtistLogo(NSString *artist, NSString *lookupKey, NSUInteger generation,
                                 BOOL refreshToken, NSTimeInterval missCacheTime) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SGRArtistLogoAppleEnabled()) {
            finishArtist(lookupKey, nil, generation, missCacheTime);
            return;
        }
        if ([sg_appleQuietUntil timeIntervalSinceNow] > 0) {
            finishArtist(lookupKey, nil, generation, MIN(missCacheTime, 30));
            return;
        }
        SGAppleCatalogToken(refreshToken, ^(NSString *token) {
            if (!token.length) {
                SGLog(@"artist logos: Apple Music public catalog token unavailable");
                finishArtist(lookupKey, nil, generation, MIN(missCacheTime, 30));
                return;
            }
            NSURLComponents *components = [NSURLComponents componentsWithString:kAppleSearch];
            components.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"term" value:artist],
                [NSURLQueryItem queryItemWithName:@"types" value:@"artists"],
                [NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
                [NSURLQueryItem queryItemWithName:@"extend" value:@"editorialArtwork"],
            ];
            NSURL *url = components.URL;
            if (!url) {
                SGLog(@"artist logos: could not form Apple Music search URL");
                finishArtist(lookupKey, nil, generation, missCacheTime);
                return;
            }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
            request.allowsConstrainedNetworkAccess = NO;
            [request setValue:kAppleUserAgent forHTTPHeaderField:@"User-Agent"];
            [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
            [request setValue:kAppleOrigin forHTTPHeaderField:@"Origin"];
            sendJSON(request, ^(NSDictionary *body, NSError *error) {
                if (error.code == 401 && !refreshToken) {
                    fetchAppleArtistLogo(artist, lookupKey, generation, YES, missCacheTime);
                    return;
                }
                if (error) {
                    SGLog(@"artist logos: Apple Music search failed: %@", error.localizedDescription);
                    if (error.code == 403 || error.code == 429) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            sg_appleQuietUntil = [NSDate dateWithTimeIntervalSinceNow:10 * 60];
                        });
                    }
                    finishArtist(lookupKey, nil, generation, failureCacheTime(error));
                    return;
                }
                NSDictionary *results = [body[@"results"] isKindOfClass:NSDictionary.class] ? body[@"results"] : nil;
                NSDictionary *artistResults = [results[@"artists"] isKindOfClass:NSDictionary.class] ? results[@"artists"] : nil;
                NSArray *artists = [artistResults[@"data"] isKindOfClass:NSArray.class] ? artistResults[@"data"] : nil;
                NSString *wanted = matchKey(artist);
                NSURL *logoURL = nil;
                for (id entry in artists) {
                    NSDictionary *attributes = [entry isKindOfClass:NSDictionary.class] &&
                        [entry[@"attributes"] isKindOfClass:NSDictionary.class] ? entry[@"attributes"] : nil;
                    NSString *name = [attributes[@"name"] isKindOfClass:NSString.class] ? attributes[@"name"] : nil;
                    if (!name.length || ![matchKey(name) isEqualToString:wanted]) continue;
                    NSDictionary *artwork = [attributes[@"editorialArtwork"] isKindOfClass:NSDictionary.class]
                        ? attributes[@"editorialArtwork"] : nil;
                    NSDictionary *logo = [artwork[@"musicContentColorLogoTrimmed"] isKindOfClass:NSDictionary.class]
                        ? artwork[@"musicContentColorLogoTrimmed"] : nil;
                    logoURL = appleLogoURL(logo);
                    break;
                }
                if (!logoURL) {
                    SGLog(@"artist logos: Apple Music returned no exact-match transparent artist logo");
                    finishArtist(lookupKey, nil, generation, missCacheTime);
                    return;
                }
                NSURLRequest *imageRequest = [NSURLRequest requestWithURL:logoURL
                    cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:kTimeout];
                [[NSURLSession.sharedSession dataTaskWithRequest:imageRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *imageError) {
                    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
                    if (imageError || !http || http.statusCode < 200 || http.statusCode >= 300 ||
                        !data.length || data.length > 16 * 1024 * 1024) {
                        NSString *failure = imageError.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
                        SGLog(@"artist logos: Apple Music logo download failed: %@", failure);
                        NSTimeInterval retry = http.statusCode == 429 || http.statusCode == 503 ? 30 : missCacheTime;
                        finishArtist(lookupKey, nil, generation, imageError ? failureCacheTime(imageError) : retry);
                        return;
                    }
                    UIImage *logo = [UIImage imageWithData:data];
                    if (!logo.CGImage) {
                        SGLog(@"artist logos: Apple Music returned an invalid logo image");
                        finishArtist(lookupKey, nil, generation, missCacheTime);
                        return;
                    }
                    finishArtist(lookupKey, logo, generation, missCacheTime);
                }] resume];
            });
        });
    });
}

static void finishWithoutFanart(NSString *artist, NSString *lookupKey, NSUInteger generation,
                                NSTimeInterval missCacheTime) {
    if (SGRArtistLogoAppleEnabled()) {
        fetchAppleArtistLogo(artist, lookupKey, generation, NO, missCacheTime);
    } else {
        finishArtist(lookupKey, nil, generation, missCacheTime);
    }
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
    NSMutableString *escaped = [NSMutableString string];
    NSString *special = @"+-!(){}[]^\"~*?:\\/";
    for (NSUInteger i = 0; i < artist.length; i++) {
        unichar character = [artist characterAtIndex:i];
        if ([special rangeOfString:[NSString stringWithCharacters:&character length:1]].location != NSNotFound) {
            [escaped appendString:@"\\"];
        }
        [escaped appendFormat:@"%C", character];
    }
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:[NSString stringWithFormat:@"artist:\"%@\"", escaped]],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
        [NSURLQueryItem queryItemWithName:@"inc" value:@"aliases"],
    ];
    return components.URL;
}

static NSURL *fanartURL(NSString *identifier, NSString *key) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[kFanart stringByAppendingFormat:@"/%@", identifier]];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"api_key" value:key]];
    return components.URL;
}

static NSArray<NSURL *> *logoURLs(NSDictionary *body) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
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
            if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || [seen containsObject:url.absoluteString]) continue;
            [seen addObject:url.absoluteString];
            [urls addObject:url];
        }
    }
    return urls;
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

static void fetchFanartForIDs(NSString *artist, NSArray<NSString *> *identifiers, NSUInteger index, NSString *key, NSString *lookupKey,
                              NSUInteger generation, NSTimeInterval missCacheTime);
static void fetchLogoURLs(NSString *artist, NSArray<NSURL *> *urls, NSUInteger urlIndex, NSArray<NSString *> *identifiers, NSUInteger identifierIndex,
                          NSString *key, NSString *lookupKey, NSUInteger generation, NSTimeInterval missCacheTime);

static void loadLogo(NSString *artist, NSString *key, NSString *lookupKey, NSUInteger generation) {
    if (!key.length) {
        finishWithoutFanart(artist, lookupKey, generation, kMissCacheTime);
        return;
    }
    NSURL *lookupURL = musicBrainzURL(artist);
    if (!lookupURL) {
        SGLog(@"artist logos: could not form MusicBrainz lookup URL");
        finishWithoutFanart(artist, lookupKey, generation, kMissCacheTime);
        return;
    }
    NSMutableURLRequest *lookup = [NSMutableURLRequest requestWithURL:lookupURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    [lookup setValue:@"spoti.pw artist logos (https://github.com/macanoclothing-blip/spoti.pw)" forHTTPHeaderField:@"User-Agent"];
    sendJSON(lookup, ^(NSDictionary *body, NSError *error) {
        if (error) {
            SGLog(@"artist logos: MusicBrainz lookup failed: %@", error.localizedDescription);
            finishWithoutFanart(artist, lookupKey, generation, failureCacheTime(error));
            return;
        }
        NSArray<NSString *> *identifiers = musicBrainzIDs(body, artist);
        if (!identifiers.count) {
            SGLog(@"artist logos: MusicBrainz returned no exact name, sort-name or alias match");
            finishWithoutFanart(artist, lookupKey, generation, kMissCacheTime);
            return;
        }
        NSUInteger count = MIN(identifiers.count, kFanartCandidateLimit);
        SGLog(@"artist logos: MusicBrainz resolved %@ to %lu candidate artist ID(s)", artist, (unsigned long)count);
        fetchFanartForIDs(artist, [identifiers subarrayWithRange:NSMakeRange(0, count)], 0, key, lookupKey, generation, kMissCacheTime);
    });
}

static void fetchFanartForIDs(NSString *artist, NSArray<NSString *> *identifiers, NSUInteger index, NSString *key, NSString *lookupKey,
                              NSUInteger generation, NSTimeInterval missCacheTime) {
    if (index >= identifiers.count) {
        SGLog(@"artist logos: no Fanart.tv logo matched any exact MusicBrainz candidate");
        finishWithoutFanart(artist, lookupKey, generation, missCacheTime);
        return;
    }
    NSURL *url = fanartURL(identifiers[index], key);
    if (!url) {
        SGLog(@"artist logos: could not form Fanart.tv request URL");
        fetchFanartForIDs(artist, identifiers, index + 1, key, lookupKey, generation, missCacheTime);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    sendJSON(request, ^(NSDictionary *fanart, NSError *error) {
        if (error) {
            if (error.code == 404) {
                fetchFanartForIDs(artist, identifiers, index + 1, key, lookupKey, generation, missCacheTime);
            } else {
                SGLog(@"artist logos: Fanart.tv lookup failed: %@", error.localizedDescription);
                finishWithoutFanart(artist, lookupKey, generation, failureCacheTime(error));
            }
            return;
        }
        NSArray<NSURL *> *urls = logoURLs(fanart);
        if (!urls.count) {
            fetchFanartForIDs(artist, identifiers, index + 1, key, lookupKey, generation, missCacheTime);
            return;
        }
        fetchLogoURLs(artist, urls, 0, identifiers, index, key, lookupKey, generation, missCacheTime);
    });
}

static void fetchLogoURLs(NSString *artist, NSArray<NSURL *> *urls, NSUInteger urlIndex, NSArray<NSString *> *identifiers, NSUInteger identifierIndex,
                          NSString *key, NSString *lookupKey, NSUInteger generation, NSTimeInterval missCacheTime) {
    if (urlIndex >= urls.count) {
        fetchFanartForIDs(artist, identifiers, identifierIndex + 1, key, lookupKey, generation, missCacheTime);
        return;
    }
    NSURLRequest *imageRequest = [NSURLRequest requestWithURL:urls[urlIndex] cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:kTimeout];
    [[NSURLSession.sharedSession dataTaskWithRequest:imageRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *imageError) {
            if (imageError) {
                SGLog(@"artist logos: image download failed: %@", imageError.localizedDescription);
                fetchLogoURLs(artist, urls, urlIndex + 1, identifiers, identifierIndex, key, lookupKey, generation,
                              MIN(missCacheTime, failureCacheTime(imageError)));
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (!http || http.statusCode < 200 || http.statusCode >= 300) {
                SGLog(@"artist logos: image download returned HTTP %ld", (long)(http ? http.statusCode : 0));
                NSTimeInterval retryAfter = http && (http.statusCode == 429 || http.statusCode == 503) ? 30 : missCacheTime;
                fetchLogoURLs(artist, urls, urlIndex + 1, identifiers, identifierIndex, key, lookupKey, generation,
                              MIN(missCacheTime, retryAfter));
                return;
            }
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            UIImage *logo = trimmedLogo(image);
            if (!logo) {
                SGLog(@"artist logos: downloaded logo was not a valid image");
                fetchLogoURLs(artist, urls, urlIndex + 1, identifiers, identifierIndex, key, lookupKey, generation, missCacheTime);
                return;
            }
            finishArtist(lookupKey, logo, generation, kMissCacheTime);
        }] resume];
}

void SGRArtistLogoForArtist(NSString *artist, void (^done)(UIImage *)) {
    NSString *cleanArtist = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lookupKey = cacheKey(cleanArtist ?: @"");
    if (!lookupKey.length || !done) return;
    NSString *key = storedKey();
    if (!key && !SGRArtistLogoAppleEnabled()) {
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
    if (!key) {
        fetchAppleArtistLogo(cleanArtist, lookupKey, generation, NO, kMissCacheTime);
        return;
    }
    NSTimeInterval delay = MAX(0, [sg_nextMusicBrainzRequest timeIntervalSinceNow]);
    sg_nextMusicBrainzRequest = [NSDate dateWithTimeIntervalSinceNow:delay + 1.1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        loadLogo(cleanArtist, key, lookupKey, generation);
    });
}
