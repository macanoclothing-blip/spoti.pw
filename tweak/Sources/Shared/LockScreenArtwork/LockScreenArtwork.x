// The track's Canvas or its album's Apple Music cover as animated now-playing artwork. Every supported
// shape is put on each dictionary that goes out, so compact surfaces and lyrics rewrites keep it too.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "LockScreenArtwork.h"
#import "SGAppleArtwork.h"
#import "SGArtworkFile.h"
#import "SGCanvas.h"
#import "Headers/SPTPlayer.h"
#import "Shared/LocalTrackArtwork/LocalTrackArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

static NSString *const kCanvazAddress = @"https://spclient.wg.spotify.com/canvaz-cache/v0/canvases";

// Spotify sets the now playing info from several threads; what the hook reads is behind the lock and
// everything else is main thread.
static NSObject *sg_lock;
static NSDictionary *sg_info;
static CFAbsoluteTime sg_infoAt;
static MPMediaItemArtwork *sg_cover;
static NSDictionary<NSString *, id> *sg_artworkByKey;

static NSString *sg_wanted;
static NSString *sg_playing;   // the source the artwork set for sg_wanted came from
static NSString *sg_offered;
static NSString *sg_waitingForAuthorization;
static NSString *sg_localCoverRequest;
static NSString *sg_localCoverURI;
static UIImage *sg_localCoverImage;
static MPMediaItemArtwork *sg_localMediaArtwork;
static MPMediaItemArtwork *sg_originalMediaArtwork;
static CGFloat sg_aspect;
static void resolve(SPTPlayerTrack *track);
static void refreshLocalStillArtwork(void);

static UIImage *coverImage(CGSize size) {
    MPMediaItemArtwork *cover;
    @synchronized (sg_lock) {
        cover = sg_cover;
    }
    return [cover imageWithSize:size] ?: [cover imageWithSize:cover.bounds.size];
}

// The system drops the whole artwork when the still is more than 3 % off the shape it asked for.
static UIImage *filled(UIImage *image, CGSize size) {
    if (!image || size.width < 1 || size.height < 1 || image.size.width < 1 || image.size.height < 1) return image;
    size = CGSizeMake(round(size.width), round(size.height));
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

static void resend(void);

static id artworkFor(NSString *artworkID, NSURL *file, UIImage *still) {
    if (@available(iOS 26.0, *)) {
        return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
            previewImageRequestHandler:^(CGSize size, void (^done)(UIImage *image)) {
                SGLog(@"lock artwork: still asked at %.0fx%.0f", size.width, size.height);
                done(filled(still ?: coverImage(size), size));
            }
            videoAssetFileURLRequestHandler:^(CGSize size, void (^done)(NSURL *url)) {
                SGLog(@"lock artwork: clip asked at %.0fx%.0f", size.width, size.height);
                done(file);
            }];
    }
    return nil;
}

static void prepareArtworkVariant(NSArray<NSString *> *keys, NSUInteger index, NSString *uri, NSString *source,
                                  SGCanvas *canvas, NSURL *file, NSMutableDictionary<NSString *, id> *artworks) {
    if (index >= keys.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![sg_wanted isEqualToString:uri] || !artworks.count) return;
            @synchronized (sg_lock) { sg_artworkByKey = [artworks copy]; }
            sg_playing = source;
            SGLog(@"lock artwork: %@ set under %@", uri, [artworks.allKeys componentsJoinedByString:@", "]);
            resend();
        });
        return;
    }
    NSString *key = keys[index];
    CGFloat aspect = SGAnimatedArtworkAspect(key);
    NSString *safeURI = [[uri componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                         componentsJoinedByString:@"_"];
    NSString *identifier = [[canvas.identifier stringByAppendingString:safeURI] stringByAppendingFormat:@"-%@", key];
    SGArtworkCrop(file, identifier, aspect, ^(NSURL *ready, NSString *cropNote) {
        SGLog(@"lock artwork: %@ %@ (%@)", canvas.identifier, key, cropNote);
        if (!ready) {
            prepareArtworkVariant(keys, index + 1, uri, source, canvas, file, artworks);
            return;
        }
        SGArtworkFirstFrame(ready, ^(CGImageRef frame) {
            UIImage *still = frame ? [UIImage imageWithCGImage:frame] : nil;
            id artwork = artworkFor(identifier, ready, still);
            if (artwork) artworks[key] = artwork;
            prepareArtworkVariant(keys, index + 1, uri, source, canvas, file, artworks);
        });
    });
}

// Every credited artist, the way the metadata lists them.
static NSString *artistOf(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger at = 0; ; at++) {
        NSString *name = metadata[at ? [NSString stringWithFormat:@"artist_name:%lu", (unsigned long)at] : @"artist_name"];
        if (![name isKindOfClass:NSString.class] || !name.length) break;
        [names addObject:name];
    }
    if (!names.count && track.artistName.length) [names addObject:track.artistName];
    return names.count ? [names componentsJoinedByString:@", "] : nil;
}

// The last dictionary sent again so the system asks for the clip that has just landed, its position
// run on to now. The artist comes off the player rather than out of the dictionary: the lock screen
// lyrics may have put the line being sung there before this hook ever saw it, and a line sent back
// as the track's own would stick until Spotify set the info itself again.
static void resend(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_info;
        reportedAt = sg_infoAt;
    }
    if (!info.count) return;
    NSMutableDictionary *now = [info mutableCopy];
    NSString *artist = artistOf(SGPlayerState().track);
    if (artist) now[MPMediaItemPropertyArtist] = artist;
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    if (elapsed) {
        double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
        now[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed.doubleValue + rate * (CFAbsoluteTimeGetCurrent() - reportedAt));
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = now;
}

static NSDictionary *localStillArtwork(NSDictionary *info) {
    if (!info.count) return info;
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (!SGLocalArtworkIsLocalTrack(uri)) {
        sg_localCoverRequest = nil;
        sg_localCoverURI = nil;
        sg_localCoverImage = nil;
        sg_localMediaArtwork = nil;
        sg_originalMediaArtwork = nil;
        return info;
    }

    UIImage *image = SGLocalArtworkCachedCover(uri);
    if (!image) {
        NSString *coverURL = SGLocalArtworkCoverURL(uri);
        NSString *request = coverURL.length ? [uri stringByAppendingFormat:@"|%@", coverURL] : nil;
        if (!request && [sg_localCoverURI isEqualToString:uri] &&
            info[MPMediaItemPropertyArtwork] == sg_localMediaArtwork) {
            NSMutableDictionary *restored = [info mutableCopy];
            if (sg_originalMediaArtwork) restored[MPMediaItemPropertyArtwork] = sg_originalMediaArtwork;
            else [restored removeObjectForKey:MPMediaItemPropertyArtwork];
            sg_localCoverURI = nil;
            sg_localCoverImage = nil;
            sg_localMediaArtwork = nil;
            sg_originalMediaArtwork = nil;
            return restored;
        }
        if (!request) {
            sg_localCoverURI = nil;
            sg_localCoverImage = nil;
            sg_localMediaArtwork = nil;
            sg_originalMediaArtwork = nil;
        }
        if (request && ![request isEqualToString:sg_localCoverRequest]) {
            sg_localCoverRequest = request;
            SGLocalArtworkLoadCover(uri, ^(UIImage *loaded) {
                if (![sg_localCoverRequest isEqualToString:request]) return;
                sg_localCoverRequest = nil;
                if (loaded && [SGURIString(SGPlayerState().track.URI) isEqualToString:uri]) {
                    refreshLocalStillArtwork();
                }
            });
        }
        return info;
    }

    sg_localCoverRequest = nil;
    BOOL sameTrack = [sg_localCoverURI isEqualToString:uri];
    if (!sameTrack) {
        sg_originalMediaArtwork = [info[MPMediaItemPropertyArtwork] isKindOfClass:MPMediaItemArtwork.class]
            ? info[MPMediaItemPropertyArtwork] : nil;
    }
    if (![sg_localCoverURI isEqualToString:uri] || sg_localCoverImage != image) {
        sg_localCoverURI = uri;
        sg_localCoverImage = image;
        sg_localMediaArtwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
            requestHandler:^UIImage *(CGSize size) {
                return image;
            }];
    }
    if (!sg_localMediaArtwork || info[MPMediaItemPropertyArtwork] == sg_localMediaArtwork) return info;
    NSMutableDictionary *updated = [info mutableCopy] ?: [NSMutableDictionary dictionary];
    updated[MPMediaItemPropertyArtwork] = sg_localMediaArtwork;
    return updated;
}

static void refreshLocalStillArtwork(void) {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    if (!info.count) {
        @synchronized (sg_lock) { info = sg_info; }
    }
    if (!info.count) return;
    NSDictionary *updated = localStillArtwork(info);
    if (updated != info) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = updated;
}

static void play(NSString *uri, SGCanvas *canvas, NSString *source) {
    SGLog(@"lock artwork: clip for %@ from %@: %@", uri, source, canvas.address);
    SGArtworkFetch(canvas.identifier, canvas.address, ^(NSURL *file, NSString *note) {
        SGLog(@"lock artwork: %@ %@", canvas.identifier, note);
        if (!file) return;
        NSArray<NSString *> *keys = SGAnimatedArtworkKeys();
        NSMutableDictionary<NSString *, id> *artworks = [NSMutableDictionary dictionary];
        prepareArtworkVariant(keys, 0, uri, source, canvas, file, artworks);
    });
}

static void askCanvaz(NSString *uri, void (^done)(SGCanvas *canvas, NSString *note)) {
    NSData *body = SGCanvazRequestBody(uri);
    NSDictionary<NSString *, NSString *> *headers = SGKaraokeSpotifyHeaders();
    if (!headers[@"authorization"] || !body) {
        if (body && !headers[@"authorization"]) sg_waitingForAuthorization = uri;
        done(nil, body ? @"no token for canvaz yet" : @"no canvaz request body");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kCanvazAddress]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.allowsConstrainedNetworkAccess = NO;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *answer, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        SGCanvas *canvas = status >= 200 && status < 300 ? SGCanvazFromBody(answer) : nil;
        NSString *note = [NSString stringWithFormat:@"canvaz status %ld, %lu bytes, error %@",
                          (long)status, (unsigned long)answer.length, error.localizedDescription];
        dispatch_async(dispatch_get_main_queue(), ^{ done(canvas, note); });
    }] resume];
}

void SGArtworkAsk(NSString *source, SPTPlayerTrack *track, SGCanvas *fromMetadata, BOOL tall, void (^done)(SGCanvas *canvas, NSString *note)) {
    if ([source isEqualToString:SGArtworkSourceSpotify]) {
        NSString *uri = SGURIString(track.URI);
        if (fromMetadata) done(fromMetadata, @"track metadata");
        else if (uri) {
            NSString *canvasURI = SGLocalArtworkIsLocalTrack(uri) ? SGLocalArtworkSpotifyURI(uri) : nil;
            askCanvaz(canvasURI ?: uri, done);
        }
        else done(nil, @"no track");
        return;
    }
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSString *uri = SGURIString(track.URI);
    NSDictionary *match = SGLocalArtworkMatch(uri);
    NSString *artist = match[@"artist"] ?: metadata[@"artist_name"] ?: track.artistName;
    NSString *album = match[@"album"] ?: metadata[@"album_title"];
    SGAppleArtworkFind(artist, album, tall, done);
}

static void walk(NSString *uri, SPTPlayerTrack *track, SGCanvas *fromMetadata, NSArray<NSString *> *order, NSUInteger at) {
    if (at >= order.count) {
        SGLog(@"lock artwork: no clip for %@ from %@", uri, order.count ? [order componentsJoinedByString:@", "] : @"no source");
        return;
    }
    if ([order[at] isEqualToString:SGArtworkSourceSpotify] && !fromMetadata && !SGKaraokeSpotifyAuthorization()) {
        sg_waitingForAuthorization = uri;
        SGLog(@"lock artwork: no Spotify authorization yet for %@, trying the next source", uri);
        walk(uri, track, fromMetadata, order, at + 1);
        return;
    }
    SGArtworkAsk(order[at], track, fromMetadata, sg_aspect < 0.9,
                 ^(SGCanvas *canvas, NSString *note) {
        if (![sg_wanted isEqualToString:uri]) return;
        if (canvas.video) {
            play(uri, canvas, order[at]);
            return;
        }
        SGLog(@"lock artwork: %@ has no clip for %@ (%@)", order[at], uri, canvas ? @"a still canvas" : note);
        walk(uri, track, fromMetadata, order, at + 1);
    });
}

// Asked on each track until MediaPlayer names one: before the framework is up it answers with none.
static BOOL keyOffered(void) {
    if (sg_offered) return YES;
    sg_offered = SGAnimatedArtworkKey(&sg_aspect);
    SGLog(@"lock artwork: iOS takes %@, going under %@ at %.2f",
          [SGAnimatedArtworkKeys() componentsJoinedByString:@", "] ?: @"nothing", sg_offered, sg_aspect);
    return sg_offered != nil;
}

static void resolve(SPTPlayerTrack *track) {
    if (!keyOffered()) return;
    NSString *uri = SGURIString(track.URI);
    if (![uri isEqualToString:sg_wanted]) sg_waitingForAuthorization = nil;
    SGCanvas *canvas = SGCanvasFromMetadata([track respondsToSelector:@selector(metadata)] ? track.metadata : nil);
    // Pause, shuffle and the like report the same track again; only metadata that landed late is news.
    static BOOL fromMetadata;
    BOOL same = uri == sg_wanted || [uri isEqualToString:sg_wanted];
    if (same && (fromMetadata || !canvas)) return;
    fromMetadata = canvas != nil;
    NSArray<NSString *> *order = SGArtworkOrderFor(SGKeyLockScreenArtworkSources);
    // A Canvas landing late is no news with Spotify off, or with a source asked before it already playing.
    NSUInteger spotifyAt = [order indexOfObject:SGArtworkSourceSpotify];
    if (same && (spotifyAt == NSNotFound || (sg_playing && [order indexOfObject:sg_playing] < spotifyAt))) return;
    sg_wanted = uri;
    sg_playing = nil;
    SGArtworkCancelFetch();
    @synchronized (sg_lock) {
        sg_artworkByKey = nil;
    }
    if (!uri) return;
    walk(uri, track, canvas, order, 0);
}

@interface SGArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGArtworkWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    static NSString *seen;
    NSString *uri = SGURIString(state.track.URI);
    if (uri && ![uri isEqualToString:seen]) {
        seen = uri;
        NSDictionary *metadata = [state.track respondsToSelector:@selector(metadata)] ? state.track.metadata : nil;
        SGLog(@"lock artwork: track %@, canvas keys %@", uri,
              [[metadata.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'canvas'"]] componentsJoinedByString:@","]);
    }
    resolve(state.track);
}
@end

static SGArtworkWatcher *sg_watcher;

void SGArtworkSpotifyHeadersChanged(void) {
    if (!sg_watcher) return;
    SGLog(@"lock artwork: Spotify service authorization captured");
    NSString *waiting = sg_waitingForAuthorization;
    SPTPlayerTrack *track = SGPlayerState().track;
    if (!waiting || ![SGURIString(track.URI) isEqualToString:waiting]) return;
    sg_waitingForAuthorization = nil;
    sg_wanted = nil;
    resolve(track);
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    info = localStillArtwork(info);
    NSDictionary<NSString *, id> *artworkByKey;
    @synchronized (sg_lock) {
        if (info[MPMediaItemPropertyArtwork]) sg_cover = info[MPMediaItemPropertyArtwork];
        sg_info = SGArtworkInInfo(info, nil);
        sg_infoAt = CFAbsoluteTimeGetCurrent();
        artworkByKey = sg_artworkByKey;
    }
    %orig(SGArtworkInInfo(info, artworkByKey));
}
%end

%ctor {
    if (!SGAnimatedArtworkAvailable()) {
        SGLog(@"lock artwork: off, animated artwork needs iOS 26");
        return;
    }
    sg_lock = [NSObject new];
    sg_watcher = [SGArtworkWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    %init;
    SGRequireClasses(@[@"MPNowPlayingInfoCenter"]);
    SGLog(@"lock artwork: on");
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalArtworkMatchDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *notification) {
        NSString *uri = SGURIString(SGPlayerState().track.URI);
        if (![notification.object isEqualToString:uri]) return;
        sg_wanted = nil;
        sg_waitingForAuthorization = nil;
        sg_playing = nil;
        @synchronized (sg_lock) { sg_artworkByKey = nil; }
        resend();
        resolve(SGPlayerState().track);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalArtworkDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *notification) {
        if (![notification.object isEqualToString:SGURIString(SGPlayerState().track.URI)]) return;
        refreshLocalStillArtwork();
    }];
}
