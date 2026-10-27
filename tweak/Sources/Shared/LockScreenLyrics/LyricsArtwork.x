// The lock-screen star temporarily swaps the full-screen Canvas/cover for this track's current line.
// Artwork injection stays in LockScreenArtwork.x, which keeps Spotify's cover and Canvas intact underneath.
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "LockScreenLyricsVideo.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

static const NSTimeInterval kLyricsRefreshInterval = 0.25;
static const NSInteger kAfterLineMs = 4000;
NSNotificationName const SGLockScreenLyricsArtworkStyleDidChangeNotification = @"spotifyglass.lockScreenLyricsArtworkStyleDidChange";

@interface SGLockLyricsArtwork : NSObject
@property (nonatomic, copy) NSString *artworkID, *trackID, *title, *artist, *current, *translation, *next;
@property (nonatomic, strong) UIImage *cover, *renderedFrame;
@property (nonatomic, strong) NSURL *canvas;
@property (nonatomic, copy) NSArray<SGKaraokeWord *> *words;
@property (nonatomic, copy) NSArray<SGKaraokeLine *> *lines;
@property (nonatomic) NSInteger positionMs, style;
@property (nonatomic) NSInteger lineEndMs, activeWordIndex, activeLineIndex;
@property (nonatomic) BOOL resting, animationFinished;
@end
@implementation SGLockLyricsArtwork
@end

static dispatch_source_t sg_lyricsTimer;
static dispatch_queue_t sg_artworkQueue;
static NSObject *sg_stateLock;
static NSString *sg_canvasURI, *sg_trackID, *sg_displayedID;
static NSURL *sg_canvasFile;
static BOOL sg_showingLyrics, sg_overlayInstalled;

BOOL SGLockScreenLyricsArtworkEnabled(void) {
    return SGHidden(SGKeyLockScreenLyricsArtwork) && SGAnimatedArtworkAvailable();
}

BOOL SGLockScreenLyricsArtworkShowing(void) {
    return sg_showingLyrics;
}

static CGFloat artworkWidth(void) {
    return MAX(floor(round(UIScreen.mainScreen.nativeBounds.size.width * 0.75) / 16) * 16, 320);
}

static CGSize artworkSize(void) {
    CGFloat width = artworkWidth();
    return CGSizeMake(width, floor((width * 4.0 / 3.0) / 16) * 16);
}

static NSURL *artworkFolder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"spoti.pw/LockScreenLyrics" isDirectory:YES];
}

static NSURL *movieURL(SGLockLyricsArtwork *artwork) {
    NSString *safe = [[artwork.artworkID componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                      componentsJoinedByString:@"_"];
    return [artworkFolder() URLByAppendingPathComponent:[safe stringByAppendingPathExtension:@"mp4"]];
}

static UIImage *renderedFrame(SGLockLyricsArtwork *artwork) {
    if (artwork.renderedFrame) return artwork.renderedFrame;
    // The star swaps Canvas out for lyrics on top of the album cover. Clearing the overlay
    // restores Spotify's original animated artwork, including Canvas, when the star is tapped again.
    artwork.renderedFrame = SGLockScreenLyricsFrame(nil, artwork.positionMs, artwork.cover,
                                                     artwork.current, artwork.translation, artwork.next,
                                                     artwork.title, artwork.artist, artwork.style,
                                                     artwork.words, artwork.activeWordIndex,
                                                     artwork.lines, artwork.activeLineIndex, artworkSize());
    return artwork.renderedFrame;
}

static NSInteger activeWordAt(NSArray<SGKaraokeWord *> *words, NSInteger positionMs) {
    if (!words.count) return -1;
    NSInteger previous = 0;
    for (NSUInteger index = 0; index < words.count; index++) {
        SGKaraokeWord *word = words[index];
        if (positionMs < word.start) return MAX((NSInteger)index - 1, 0);
        if (positionMs <= word.end) return (NSInteger)index;
        previous = (NSInteger)index;
    }
    return previous;
}

static NSInteger animationEndForLine(SGKaraokeLine *line) {
    if (!line) return 0;
    NSInteger end = line.start;
    for (SGKaraokeWord *word in line.words) end = MAX(end, word.end);
    return line.words.count ? end : SGKaraokeSungEnd(line);
}

static BOOL writeMovie(SGLockLyricsArtwork *artwork) {
    NSURL *url = movieURL(artwork);
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) return YES;
    if (artwork.animationFinished || !artwork.current.length || !artwork.words.count) {
        UIImage *frame = renderedFrame(artwork);
        return frame && SGLockScreenLyricsMovie(20, 10, url, ^UIImage *(NSUInteger index) { return frame; });
    }

    // The word timestamps are expanded into grapheme timings by the renderer, so keep enough
    // frames to make the letter lift and color sweep read as continuous on the lock screen.
    const NSInteger frameRate = 30;
    NSInteger remainingMs = MAX(artwork.lineEndMs - artwork.positionMs, 500);
    NSTimeInterval duration = MAX(remainingMs / 1000.0, 0.8);
    NSUInteger frameCount = (NSUInteger)ceil(duration * frameRate) + 1;
    CGSize size = artworkSize();
    UIImage *background = SGLockScreenLyricsPreparedBackgroundFrame(artwork.cover, artwork.style, size);
    if (!background) return NO;

    return SGLockScreenLyricsMovie(frameCount, frameRate, url, ^UIImage *(NSUInteger frameIndex) {
        CGFloat progress = frameCount > 1 ? (CGFloat)frameIndex / (frameCount - 1) : 0;
        NSInteger samplePosition = artwork.positionMs + (NSInteger)llround(remainingMs * progress);
        NSInteger activeWord = activeWordAt(artwork.words, samplePosition);
        return SGLockScreenLyricsFrameOnBackground(background, samplePosition,
            artwork.current, artwork.translation, artwork.next, artwork.title, artwork.artist,
            artwork.style, artwork.words, activeWord, artwork.lines, artwork.activeLineIndex, size);
    });
}

static MPMediaItemAnimatedArtwork *mediaArtwork(SGLockLyricsArtwork *artwork) API_AVAILABLE(ios(26.0)) {
    return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artwork.artworkID
        previewImageRequestHandler:^(CGSize size, void (^completion)(UIImage *)) {
            dispatch_async(sg_artworkQueue, ^{ completion(renderedFrame(artwork)); });
        }
        videoAssetFileURLRequestHandler:^(CGSize size, void (^completion)(NSURL *)) {
            dispatch_async(sg_artworkQueue, ^{
                BOOL current = NO;
                @synchronized (sg_stateLock) { current = [sg_displayedID isEqualToString:artwork.artworkID]; }
                completion(current && writeMovie(artwork) ? movieURL(artwork) : nil);
            });
        }];
}

static NSString *lineAt(NSArray<SGKaraokeLine *> *lines, NSInteger index) {
    return index >= 0 && index < (NSInteger)lines.count ? SGKaraokeLineText(lines[index]) : nil;
}

static SGLockLyricsArtwork *artworkAt(NSArray<SGKaraokeLine *> *lines, NSInteger index, BOOL resting, BOOL animationFinished,
                                       NSInteger position, NSURL *canvas, SPTPlayerState *state, NSString *trackID) {
    SGLockLyricsArtwork *artwork = [SGLockLyricsArtwork new];
    artwork.trackID = trackID;
    artwork.title = state.track.trackTitle;
    artwork.artist = state.track.artistName;
    artwork.current = resting ? nil : lineAt(lines, index);
    artwork.translation = !resting && index >= 0 && index < (NSInteger)lines.count ? lines[(NSUInteger)index].translation : nil;
    artwork.next = lineAt(lines, index + 1);
    SGKaraokeLine *line = !resting && index >= 0 && index < (NSInteger)lines.count ? lines[(NSUInteger)index] : nil;
    artwork.words = line.words ?: @[];
    artwork.lines = lines;
    artwork.activeLineIndex = index;
    artwork.lineEndMs = animationEndForLine(line);
    artwork.animationFinished = animationFinished;
    artwork.resting = resting;
    artwork.positionMs = animationFinished ? artwork.lineEndMs : position;
    artwork.activeWordIndex = activeWordAt(artwork.words, artwork.positionMs);
    artwork.canvas = canvas;
    NSInteger style = SGInt(SGKeyLockScreenLyricsArtworkStyle, SGLockScreenLyricsArtworkStyleDefault);
    artwork.style = style >= SGLockScreenLyricsArtworkStyleDefault && style <= SGLockScreenLyricsArtworkStyleBlueprint
        ? style : SGLockScreenLyricsArtworkStyleDefault;
    artwork.cover = [MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork]
                     imageWithSize:CGSizeMake(600, 600)];
    NSString *canvasID = artwork.canvas.lastPathComponent ?: @"cover";
    NSString *stateKey = resting ? @"-rest" : (animationFinished ? @"-done" : @"-live");
    artwork.artworkID = [NSString stringWithFormat:@"%@-locklyrics-v3-line-%ld-%@-%ld%@",
                          trackID, (long)index, canvasID, (long)artwork.style, stateKey];
    return artwork;
}

static void removeLyricsArtwork(void) {
    BOOL hadOverlay = sg_overlayInstalled;
    sg_overlayInstalled = NO;
    @synchronized (sg_stateLock) { sg_displayedID = nil; }
    if (hadOverlay) SGArtworkSetLyricsOverlay(nil, nil);
}

static void updateLyricsArtwork(void) {
    if (@available(iOS 26.0, *)) {
        if (!SGLockScreenLyricsArtworkEnabled() || !sg_showingLyrics) { removeLyricsArtwork(); return; }
        SPTPlayerState *state = SGPlayerState();
        NSString *trackID = SGKaraokePlayingTrack();
        NSString *title = state.track.trackTitle;
        if (!state || !trackID.length || !title.length) { removeLyricsArtwork(); return; }
        if (![trackID isEqualToString:sg_trackID]) {
            sg_trackID = [trackID copy];
            @synchronized (sg_stateLock) { sg_displayedID = nil; }
            dispatch_async(sg_artworkQueue, ^{
                [NSFileManager.defaultManager removeItemAtURL:artworkFolder() error:nil];
                [NSFileManager.defaultManager createDirectoryAtURL:artworkFolder() withIntermediateDirectories:YES attributes:nil error:nil];
            });
        }
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
        if (!lines) { SGKaraokeRequestLyrics(trackID); removeLyricsArtwork(); return; }
        if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) { removeLyricsArtwork(); return; }
        NSInteger position = SGKaraokePositionMs();
        if (position < 0) return;
        NSInteger index = SGKaraokeLeadLine(lines, position);
        if (index < -1) { removeLyricsArtwork(); return; }
        BOOL nextIsDistant = index < 0 || index + 1 >= (NSInteger)lines.count || lines[index + 1].start - position > kAfterLineMs;
        BOOL resting = index < 0 || (position > SGKaraokeSungEnd(lines[index]) + kAfterLineMs && nextIsDistant);
        SGKaraokeLine *activeLine = index >= 0 && index < (NSInteger)lines.count ? lines[(NSUInteger)index] : nil;
        BOOL animationFinished = !resting && activeLine && position >= animationEndForLine(activeLine);
        NSURL *canvas = [sg_canvasURI isEqualToString:SGURIString(state.track.URI)] ? sg_canvasFile : nil;
        SGLockLyricsArtwork *artwork = artworkAt(lines, index, resting, animationFinished, position, canvas, state, trackID);
        if ([artwork.artworkID isEqualToString:sg_displayedID]) return;
        if (![SGAnimatedArtworkKeys() containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
            removeLyricsArtwork();
            return;
        }
        @synchronized (sg_stateLock) { sg_displayedID = [artwork.artworkID copy]; }
        sg_overlayInstalled = YES;
        SGArtworkSetLyricsOverlay(@{MPNowPlayingInfoProperty3x4AnimatedArtwork: mediaArtwork(artwork)}, title);
    }
}

static void setLyricsTimer(BOOL running) {
    if (running == (sg_lyricsTimer != nil)) return;
    if (!running) {
        dispatch_source_cancel(sg_lyricsTimer);
        sg_lyricsTimer = nil;
        return;
    }
    sg_lyricsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
    uint64_t interval = (uint64_t)(kLyricsRefreshInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(sg_lyricsTimer, dispatch_time(DISPATCH_TIME_NOW, interval), interval, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sg_lyricsTimer, ^{ updateLyricsArtwork(); });
    dispatch_resume(sg_lyricsTimer);
}

void SGLockScreenLyricsArtworkSetShowing(BOOL showing) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_showingLyrics = showing && SGLockScreenLyricsArtworkEnabled();
        setLyricsTimer(sg_showingLyrics && !SGPlayerState().isPaused);
        if (sg_showingLyrics) updateLyricsArtwork();
        else removeLyricsArtwork();
    });
}

void SGLockScreenLyricsArtworkStyleDidChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGLockScreenLyricsArtworkStyleDidChangeNotification object:nil];
        if (sg_showingLyrics) updateLyricsArtwork();
    });
}

void SGLyricsArtworkSetMotion(NSString *uri, NSURL *file) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_canvasURI = [uri copy];
        sg_canvasFile = file;
        if (sg_showingLyrics) updateLyricsArtwork();
    });
}

@interface SGLockLyricsArtworkObserver : NSObject <SGPlayerStateObserver>
@end
@implementation SGLockLyricsArtworkObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    setLyricsTimer(sg_showingLyrics && !state.isPaused);
    if (sg_showingLyrics) updateLyricsArtwork();
    else removeLyricsArtwork();
}
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        sg_stateLock = [NSObject new];
        sg_artworkQueue = dispatch_queue_create("spotifyglass.locklyrics.artwork", DISPATCH_QUEUE_SERIAL);
        [NSFileManager.defaultManager createDirectoryAtURL:artworkFolder() withIntermediateDirectories:YES attributes:nil error:nil];
        static SGLockLyricsArtworkObserver *observer;
        observer = [SGLockLyricsArtworkObserver new];
        SGAddPlayerStateObserver(observer);
        [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            if (sg_showingLyrics && [note.object isEqualToString:sg_trackID]) updateLyricsArtwork();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (SGLockScreenLyricsArtworkEnabled()) return;
                sg_showingLyrics = NO;
                setLyricsTimer(NO);
                removeLyricsArtwork();
            });
        }];
    }
}
