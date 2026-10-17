// Player redesign: the cover sits on the field with continuous corners and a soft shadow, and shrinks
// back while playback is paused, the way the Music app's does; the lyric preview under it is gone.
//
// Tree (trees/clean/player/01.txt:36-43): CoverArtCellImpl > ... > CoverArtTiltView 354x354 > an
// ElementView the same size > ImageViewProxy > Encore.ImageView (clips) > UIImageView, with
// Lyrics_NPVContainerKit.LyricsContainerView under the tilt view. The ElementView is what gets the
// corners and the scale: the tilt view's own transform is left to the tilt Spotify gives it when the
// cover is inspected. The image clips, so the shadow is a plate of the Kit's behind it.
//
// A paused cover stays shrunk while the player opens or closes: the morph (PlayerMorph.x) flies to the
// frame the cover is seen at, so growing it for the transition only made it jump afterwards.
#import <math.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/LocalTrackArtwork/LocalTrackArtwork.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const CGFloat kPausedScale = 0.84, kPausedScaleReduceMotion = 0.92;
// The bar's 40pt cover lives in a tilt view of its own; the player's is 354.
static const CGFloat kCoverMinWidth = 200;

static char kPlateKey;
static NSHashTable<UIView *> *sg_tilts;
// The cover of each tilt view once found. A frame Spotify sets on a scaled view becomes its scaled
// size, leaving bounds that no longer match the tilt view's, so the cover is not looked for by size again.
static NSMapTable<UIView *, UIView *> *sg_covers;
static __weak UIImageView *sg_localCoverView;
static __weak UIView *sg_localCoverCell;
static UIImage *sg_originalLocalCover;
static UIImage *sg_appliedLocalCover;
static NSString *sg_appliedLocalURI;
static NSString *sg_appliedLocalURL;
static NSString *sg_loadingLocalCoverKey;
static NSMapTable<UIView *, NSNumber *> *sg_coverOverlayAlphas;
static UIView *coverIn(UIView *tilt);
static UIView *coverCellForTilt(UIView *tilt);
static UIView *showingTilt(void);

static BOOL sameOptionalString(NSString *left, NSString *right) {
    return left == right || [left isEqualToString:right];
}

static CGFloat currentScale(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!state.isPaused) return 1;
    return SGRReduceMotion() ? kPausedScaleReduceMotion : kPausedScale;
}

static UIImageView *coverImageIn(UIView *cover) {
    if ([cover isKindOfClass:UIImageView.class]) return (UIImageView *)cover;
    __block UIImageView *found = nil;
    __block CGFloat widest = 0;
    SGForEachView(cover, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class] || view.bounds.size.width <= widest) return;
        widest = view.bounds.size.width;
        found = (UIImageView *)view;
    });
    return found;
}

static BOOL coverOverlay(UIView *sibling, CGRect coverRect) {
    if (sibling.hidden || sibling.alpha < 0.01) return NO;
    CGRect frame = sibling.frame;
    CGFloat width = CGRectGetWidth(coverRect), height = CGRectGetHeight(coverRect);
    if (width < 1 || height < 1) return NO;
    CGRect overlap = CGRectIntersection(frame, coverRect);
    if (CGRectIsNull(overlap) || CGRectIsEmpty(overlap)) return NO;
    CGFloat overlapArea = CGRectGetWidth(overlap) * CGRectGetHeight(overlap);
    CGFloat coverArea = width * height;
    if (CGRectGetWidth(frame) >= width * 0.5 && CGRectGetHeight(frame) >= height * 0.5 &&
        overlapArea / coverArea >= 0.65) return YES;

    __block BOOL centeredGlyph = NO;
    SGForEachView(sibling, ^(UIView *view) {
        if (centeredGlyph) return;
        if (![view isKindOfClass:UIImageView.class] || view.hidden || view.alpha < 0.01) return;
        CGRect glyph = [view convertRect:view.bounds toView:sibling.superview];
        CGFloat dx = fabs(CGRectGetMidX(glyph) - CGRectGetMidX(coverRect));
        CGFloat dy = fabs(CGRectGetMidY(glyph) - CGRectGetMidY(coverRect));
        centeredGlyph = CGRectGetWidth(glyph) >= 24 && CGRectGetHeight(glyph) >= 24 &&
            CGRectGetWidth(glyph) <= width * 0.5 && CGRectGetHeight(glyph) <= height * 0.5 &&
            dx <= width * 0.08 && dy <= height * 0.08;
    });
    return centeredGlyph;
}

static void hideCoverOverlays(UIImageView *cover, UIView *container, BOOL hide) {
    if (!sg_coverOverlayAlphas) sg_coverOverlayAlphas = [NSMapTable weakToStrongObjectsMapTable];
    if (!hide) {
        for (UIView *overlay in sg_coverOverlayAlphas.keyEnumerator.allObjects) {
            NSNumber *alpha = [sg_coverOverlayAlphas objectForKey:overlay];
            if (overlay.alpha == 0 && alpha) overlay.alpha = alpha.doubleValue;
        }
        [sg_coverOverlayAlphas removeAllObjects];
        return;
    }
    if (!cover || !container) return;

    for (UIView *node = cover; node && node != container; node = node.superview) {
        UIView *parent = node.superview;
        if (!parent) break;
        CGRect coverRect = [cover convertRect:cover.bounds toView:parent];
        BOOL above = NO;
        for (UIView *sibling in parent.subviews) {
            if (sibling == node) {
                above = YES;
                continue;
            }
            if (!above || !coverOverlay(sibling, coverRect)) continue;
            if (![sg_coverOverlayAlphas objectForKey:sibling]) {
                [sg_coverOverlayAlphas setObject:@(sibling.alpha) forKey:sibling];
            }
            sibling.alpha = 0;
        }
    }
}

static void scheduleCoverOverlayHiding(void) {
    __weak UIImageView *weakCover = sg_localCoverView;
    __weak UIView *weakCell = sg_localCoverCell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImageView *cover = weakCover;
        UIView *container = weakCell;
        if (cover && container) hideCoverOverlays(cover, container, YES);
    });
}

static void restoreLocalCover(void) {
    hideCoverOverlays(nil, nil, NO);
    UIImageView *view = sg_localCoverView;
    if (view && view.image == sg_appliedLocalCover) view.image = sg_originalLocalCover;
    sg_localCoverView = nil;
    sg_localCoverCell = nil;
    sg_originalLocalCover = nil;
    sg_appliedLocalCover = nil;
    sg_appliedLocalURI = nil;
    sg_appliedLocalURL = nil;
    sg_loadingLocalCoverKey = nil;
}

static void updateLocalCover(UIView *tilt) {
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (!SGLocalArtworkIsLocalTrack(uri)) {
        restoreLocalCover();
        return;
    }
    if (!tilt) return;
    UIImageView *view = coverImageIn(coverIn(tilt));
    if (!view) return;
    NSString *address = SGLocalArtworkCoverURL(uri);
    UIImage *selected = SGLocalArtworkCachedCover(uri);
    if (!selected && !address.length) {
        restoreLocalCover();
        return;
    }
    if (!selected) {
        if (view != sg_localCoverView || ![uri isEqualToString:sg_appliedLocalURI] ||
            !sameOptionalString(address, sg_appliedLocalURL)) {
            restoreLocalCover();
            sg_localCoverView = view;
            sg_localCoverCell = coverCellForTilt(tilt) ?: tilt;
            sg_originalLocalCover = view.image;
            sg_appliedLocalURI = uri;
            sg_appliedLocalURL = address;
        }
        NSString *requestKey = [uri stringByAppendingFormat:@"|%@", address];
        if (![requestKey isEqualToString:sg_loadingLocalCoverKey]) {
            sg_loadingLocalCoverKey = requestKey;
            SGLocalArtworkLoadCover(uri, ^(UIImage *image) {
                if (![sg_loadingLocalCoverKey isEqualToString:requestKey]) return;
                sg_loadingLocalCoverKey = nil;
                if (image && [SGURIString(SGPlayerState().track.URI) isEqualToString:uri]) {
                    updateLocalCover(showingTilt());
                }
            });
        }
        return;
    }
    sg_loadingLocalCoverKey = nil;
    if (view != sg_localCoverView || ![uri isEqualToString:sg_appliedLocalURI] ||
        !sameOptionalString(address, sg_appliedLocalURL)) {
        restoreLocalCover();
        sg_localCoverView = view;
        sg_originalLocalCover = view.image;
        sg_appliedLocalURI = uri;
        sg_appliedLocalURL = address;
    }
    if (view.image != selected) view.image = selected;
    sg_appliedLocalCover = selected;
    // Spotify's missing-art glyph can be a sibling of the tilt view in the cell, not a child of it.
    sg_localCoverCell = coverCellForTilt(tilt) ?: tilt;
    hideCoverOverlays(view, sg_localCoverCell, YES);
}

// The child of the tilt view the size of the cover.
static UIView *coverIn(UIView *tilt) {
    UIView *cover = [sg_covers objectForKey:tilt];
    if (cover.superview == tilt) return cover;
    for (UIView *sub in tilt.subviews) {
        if (![sub isKindOfClass:SGRShadowPlate.class] && CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size)) {
            [sg_covers setObject:sub forKey:tilt];
            return sub;
        }
    }
    return nil;
}

static UIView *coverCellForTilt(UIView *tilt) {
    static Class cell;
    if (!cell) cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if ([v isKindOfClass:cell]) return v;
    }
    return nil;
}

static BOOL inCoverCell(UIView *tilt) {
    return coverCellForTilt(tilt) != nil;
}

static void scaleCover(UIView *tilt, CGFloat scale) {
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    SGRShadowPlate *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    cover.transform = transform;
    plate.transform = transform;
}

#pragma mark - where the cover is

// The tilt view of the cover on screen: the queue is a cover per cell and the cells out of view are
// kept hidden (player/02.txt:521), so the one showing is the one in a window with nothing hidden over it.
static UIView *showingTilt(void) {
    for (UIView *tilt in sg_tilts) {
        if (!tilt.window) continue;
        BOOL hidden = NO;
        for (UIView *v = tilt; v && !hidden; v = v.superview) hidden = v.hidden;
        if (!hidden) return tilt;
    }
    return nil;
}

UIView *SGRPlayerCoverList(void) {
    for (UIView *v = showingTilt(); v; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) return v;
    }
    return nil;
}

CGRect SGRPlayerCoverFrameIn(UIView *host) {
    UIView *tilt = showingTilt();
    UIView *cover = coverIn(tilt);
    // The cover's own transform is the paused shrink, which is what the eye sees it at.
    return cover && host ? [host convertRect:cover.bounds fromView:cover] : CGRectNull;
}

CGRect SGRPlayerArtworkAreaIn(UIView *host) {
    UIView *tilt = showingTilt();
    if (!tilt || !host) return CGRectNull;
    // The band is the first view over the cover as wide as the player: the cover sits inset inside it
    // (01.txt:33-36, CoverArtCellImpl > UIView {0, 110, 402, 466.67} > UIView {24, 8, ...} > the tilt view).
    for (UIView *v = tilt.superview; v; v = v.superview) {
        if (v == host) break;
        if (v.bounds.size.width >= host.bounds.size.width - 1) return [host convertRect:v.bounds fromView:v];
    }
    return CGRectNull;
}

#pragma mark - hidden

// The cover hidden for a stand-in, so the same one comes back if the list moved on meanwhile.
static __weak UIView *sg_hiddenCover;
// The tilt views whose cover this file took away, the only ones it gives back: any alpha Spotify sets on
// a cover itself is left alone.
static NSHashTable<UIView *> *sg_gone;

// With a clip over the field no cover shows, in any cell (PlayerAnimated.x). Only the cover and its plate
// go, never the list or anything over it: UIKit hit tests nothing under alpha 0.01, and a swipe on the
// list is what skips. The tilt view is the element VoiceOver names the cover by.
static void showCover(UIView *tilt) {
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    BOOL clip = SGRPlayerAnimatedShowing(NULL, NULL), gone = clip || cover == sg_hiddenCover;
    if (gone) [sg_gone addObject:tilt];
    else if ([sg_gone containsObject:tilt]) [sg_gone removeObject:tilt];
    else return;
    UIView *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    CGFloat alpha = gone ? 0 : 1;
    if (cover.alpha != alpha) cover.alpha = alpha;
    if (plate.alpha != alpha) plate.alpha = alpha;
    if (tilt.accessibilityElementsHidden != clip) tilt.accessibilityElementsHidden = clip;
}

static void fadeCovers(NSArray<UIView *> *tilts, NSTimeInterval duration) {
    void (^apply)(void) = ^{
        for (UIView *tilt in tilts) showCover(tilt);
    };
    if (duration <= 0) {
        [UIView performWithoutAnimation:apply];
        return;
    }
    [UIView animateWithDuration:duration delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:apply completion:nil];
}

void SGRPlayerCoversFollowClip(NSTimeInterval duration) {
    fadeCovers(sg_tilts.allObjects, duration);
}

void SGRPlayerSetCoverHidden(BOOL hidden) {
    UIView *was = sg_hiddenCover;
    sg_hiddenCover = nil;
    if (was) {
        // Given back halfway through a clip's fade, it joins the fade where the clip has got to.
        CGFloat shown = 0;
        NSTimeInterval left = 0;
        SGRPlayerAnimatedShowing(&shown, &left);
        UIView *tilt = was.superview, *plate = SGRShadowPlateIn(tilt, &kPlateKey);
        if (left > 0) {
            [UIView performWithoutAnimation:^{
                was.alpha = 1 - shown;
                plate.alpha = 1 - shown;
            }];
        }
        if (tilt) fadeCovers(@[tilt], left);
    }
    if (!hidden) return;
    UIView *tilt = showingTilt();
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    sg_hiddenCover = cover;
    [UIView performWithoutAnimation:^{ showCover(tilt); }];
}

#pragma mark - the paused shrink

static void scaleEveryCover(BOOL animated) {
    CGFloat scale = currentScale();
    NSArray<UIView *> *tilts = sg_tilts.allObjects;
    void (^apply)(void) = ^{
        for (UIView *tilt in tilts) scaleCover(tilt, scale);
    };
    if (animated) SGRAnimate(SGRMotionLayout, apply, nil);
    else apply();
}

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width < kCoverMinWidth || !inCoverCell(tilt)) return;
    if (tilt == showingTilt()) updateLocalCover(tilt);
    UIView *cover = coverIn(tilt);
    if (!cover) return;
    [sg_tilts addObject:tilt];
    // The cover fills the tilt view (01.txt:37); bounds and center, unlike a frame, hold under the scale.
    CGRect bounds = tilt.bounds;
    CGPoint middle = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (!CGSizeEqualToSize(cover.bounds.size, bounds.size)) cover.bounds = (CGRect){cover.bounds.origin, bounds.size};
    if (!CGPointEqualToPoint(cover.center, middle)) cover.center = middle;

    cover.layer.cornerRadius = SGRRadiusArtwork;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.clipsToBounds = YES;
    SGRShadowPlate *plate = SGRShadowPlateIn(tilt, &kPlateKey);
    plate.bounds = cover.bounds;
    plate.center = cover.center;
    // The same value an animation in flight is heading to, so a layout pass never cuts one short.
    scaleCover(tilt, currentScale());
    // A cell laid out later, or reused, takes the rule as it stands.
    [UIView performWithoutAnimation:^{ showCover(tilt); }];

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: cover %@ rounded %.0f with a shadow plate, scale %.2f", NSStringFromClass(cover.class), SGRRadiusArtwork, currentScale()); });
}
%end

%hook _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl
- (void)layoutSubviews {
    %orig;
    UIView *tilt = showingTilt();
    if (tilt && [tilt isDescendantOfView:(UIView *)self]) updateLocalCover(tilt);
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (self == sg_localCoverView) {
        NSString *uri = SGURIString(SGPlayerState().track.URI);
        UIImage *selected = SGLocalArtworkCachedCover(uri);
        if ([uri isEqualToString:sg_appliedLocalURI]) {
            if (selected && image != selected) {
                sg_originalLocalCover = image;
                %orig(selected);
                sg_appliedLocalCover = selected;
                scheduleCoverOverlayHiding();
                return;
            }
            if (!selected) sg_originalLocalCover = image;
        }
    }
    %orig(image);
    if (sg_localCoverCell && self != sg_localCoverView && [self isDescendantOfView:sg_localCoverCell]) {
        scheduleCoverOverlayHiding();
    }
}
%end

// Spotify shows and hides the preview as lyrics come and go; it stays hidden, the way
// Native/Player/PlayerDeclutter.x has shipped it (its parent is a plain view, 01.txt:35, not a stack).
%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)setHidden:(BOOL)hidden {
    %orig(YES);
}
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

@interface SGRPlayerArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerArtworkWatcher {
    NSInteger _paused;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _paused = -1;
    return self;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    updateLocalCover(showingTilt());
    NSInteger paused = state.isPaused ? 1 : 0;
    if (paused == _paused) return;
    _paused = paused;
    scaleEveryCover(YES);
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"redesign player: state paused=%d loading=%d, %lu covers scaled", state.isPaused, state.isLoading, (unsigned long)sg_tilts.count);
}

@end

static SGRPlayerArtworkWatcher *sg_artworkWatcher;

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_tilts = [NSHashTable weakObjectsHashTable];
    sg_covers = [NSMapTable weakToWeakObjectsMapTable];
    sg_gone = [NSHashTable weakObjectsHashTable];
    sg_artworkWatcher = [SGRPlayerArtworkWatcher new];
    SGAddPlayerStateObserver(sg_artworkWatcher);
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalArtworkDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *notification) {
        if (![notification.object isEqualToString:SGURIString(SGPlayerState().track.URI)]) return;
        updateLocalCover(showingTilt());
    }];
    SGRObservePlayerTransition(sg_artworkWatcher, ^(id owner) {
        scaleEveryCover(YES);
    }, ^(id owner) {
        scaleEveryCover(YES);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: transition over, cover scale %.2f", currentScale()); });
    });
    SGRequireClasses(@[
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl",
        @"_TtC22Lyrics_NPVContainerKit19LyricsContainerView",
    ]);
}
