#import "Core/SGCore.h"
#import "SGArtistLogo.h"

static NSString *const kKey = @"spotipw.fanart.artistLogo.key";
static NSString *const kMusicBrainz = @"https://musicbrainz.org/ws/2/artist";
static NSString *const kFanart = @"https://webservice.fanart.tv/v3/music";
static const NSTimeInterval kTimeout = 15;

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
        sg_cache[key] = logo ?: NSNull.null;
        NSArray *callbacks = [sg_pending[key] copy];
        [sg_pending removeObjectForKey:key];
        for (id value in callbacks) {
            void (^callback)(UIImage *) = value;
            callback(logo);
        }
    });
}

static NSString *musicBrainzID(NSDictionary *body, NSString *artist) {
    NSArray *artists = [body[@"artists"] isKindOfClass:NSArray.class] ? body[@"artists"] : nil;
    NSInteger bestScore = NSIntegerMin;
    NSString *bestID = nil;
    BOOL tied = NO;
    for (id value in artists) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *candidate = value;
        NSString *name = [candidate[@"name"] isKindOfClass:NSString.class] ? candidate[@"name"] : nil;
        NSString *identifier = [candidate[@"id"] isKindOfClass:NSString.class] ? candidate[@"id"] : nil;
        if (!name || [name compare:artist options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch] != NSOrderedSame
            || ![[NSUUID alloc] initWithUUIDString:identifier ?: @""]) continue;
        NSInteger score = [candidate[@"score"] respondsToSelector:@selector(integerValue)] ? [candidate[@"score"] integerValue] : 0;
        if (score > bestScore) {
            bestScore = score;
            bestID = identifier;
            tied = NO;
        } else if (score == bestScore) {
            tied = YES;
        }
    }
    if (tied) {
        SGLog(@"artist logos: MusicBrainz returned equally ranked exact-name matches; skipping ambiguous result");
        return nil;
    }
    return bestID;
}

static NSURL *musicBrainzURL(NSString *artist) {
    NSURLComponents *components = [NSURLComponents componentsWithString:kMusicBrainz];
    NSString *escaped = [[artist stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:[NSString stringWithFormat:@"artist:\"%@\"", escaped]],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"5"],
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
        NSString *identifier = musicBrainzID(body, artist);
        if (!identifier) {
            SGLog(@"artist logos: no unambiguous exact MusicBrainz match");
            finishArtist(lookupKey, nil, generation);
            return;
        }
        NSURL *url = fanartURL(identifier, key);
        if (!url) {
            SGLog(@"artist logos: could not form Fanart.tv request URL");
            finishArtist(lookupKey, nil, generation);
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
        sendJSON(request, ^(NSDictionary *fanart, NSError *fanartError) {
            if (fanartError) {
                SGLog(@"artist logos: Fanart.tv lookup failed: %@", fanartError.localizedDescription);
                finishArtist(lookupKey, nil, generation);
                return;
            }
            NSURL *imageURL = logoURL(fanart);
            if (!imageURL) {
                SGLog(@"artist logos: Fanart.tv returned no usable artist logo");
                finishArtist(lookupKey, nil, generation);
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
                finishArtist(lookupKey, image, generation);
            }] resume];
        });
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
    id cached = sg_cache[lookupKey];
    if (cached) {
        done(cached == NSNull.null ? nil : cached);
        return;
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
