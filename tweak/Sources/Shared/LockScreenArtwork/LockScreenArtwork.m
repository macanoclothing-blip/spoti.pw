// What the hook, the harness and the settings share: the order of the sources, which key this iOS
// takes a clip under, and putting one there.
#import <MediaPlayer/MediaPlayer.h>
#import "LockScreenArtwork.h"

NSString *const SGArtworkSourceSpotify = @"spotify";
NSString *const SGArtworkSourceApple = @"applemusic";

NSArray<NSString *> *SGArtworkOrderFor(NSString *key) {
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:key];
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : @[SGArtworkSourceSpotify, SGArtworkSourceApple];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        BOOL known = [key isEqual:SGArtworkSourceSpotify] || [key isEqual:SGArtworkSourceApple];
        if (known && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

void SGArtworkSetOrderFor(NSString *key, NSArray<NSString *> *order) {
    [NSUserDefaults.standardUserDefaults setObject:order ?: @[] forKey:key];
}

BOOL SGAnimatedArtworkAvailable(void) {
    if (@available(iOS 26.0, *)) return MPMediaItemAnimatedArtwork.class != nil;
    return NO;
}

NSArray<NSString *> *SGAnimatedArtworkKeys(void) {
    if (@available(iOS 26.0, *)) {
        NSArray<NSString *> *supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        for (NSString *key in @[MPNowPlayingInfoProperty3x4AnimatedArtwork, MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
            if ([supported containsObject:key]) [keys addObject:key];
        }
        return keys;
    }
    return nil;
}

CGFloat SGAnimatedArtworkAspect(NSString *key) {
    if ([key isEqualToString:MPNowPlayingInfoProperty3x4AnimatedArtwork]) return 3.0 / 4.0;
    if ([key isEqualToString:MPNowPlayingInfoProperty1x1AnimatedArtwork]) return 1;
    return 0;
}

NSString *SGAnimatedArtworkKey(CGFloat *aspect) {
    NSArray<NSString *> *supported = SGAnimatedArtworkKeys();
    NSString *key = supported.firstObject;
    if (key && aspect) *aspect = SGAnimatedArtworkAspect(key);
    return key;
}

NSDictionary *SGArtworkInInfo(NSDictionary *info, NSDictionary<NSString *, id> *artworkByKey) {
    if (!info.count) return info;
    NSMutableDictionary *shown;
    for (NSString *key in @[MPNowPlayingInfoProperty3x4AnimatedArtwork, MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
        id artwork = artworkByKey[key];
        if (artwork && info[key] == artwork) continue;
        if (!artwork && !info[key]) continue;
        if (!shown) shown = [info mutableCopy];
        if (artwork) shown[key] = artwork;
        else [shown removeObjectForKey:key];
    }
    return shown ?: info;
}
