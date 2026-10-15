// Full screen player: glass where Liquid Glass belongs and nowhere else, and the album colour
// behind it traded for the cover art.
//
// Glass is the navigation layer floating over content, so only the header's two round buttons get
// a pane, the way the Music app keeps its chrome. The playlist name between them is a label, and
// shuffle, repeat, previous, next and the footer (connect, share, queue) are bare glyphs over the
// artwork next to Spotify's white play disc: a pane each turned both rows into a strip of glass
// discs sampling one another, which is the one thing the material cannot do. The cards below the
// player are surfaces rather than controls; the lyrics one is in LyricsCard.x.
//
// Tree (trees/now-playing.txt): NowPlaying_ModesImpl units, each a child controller whose view
// holds one UIStackView row; the header row is chevron 48x48, playlist name 110x48, more 48x48.
//
// The background is one plane the size of the screen painted the album colour, Spotify's gradients
// on top of it, and it is NPVBackgroundViewController's own view. Glass over a flat fill samples
// that same flat fill back, which is why the header panes cannot be made out on it; white text and
// Spotify's green both sit badly on saturated colour as well. SGKeyPlayerBackdrop strips the plane
// and puts the cover behind the player instead, shrunk until none of the picture is left in it,
// blurred, under a scrim ending near black so the cards scrolled up from below meet it. The switch
// covers what that field changes around it too: the artwork takes corners and a shadow so it sits
// on the field rather than being pasted onto it, the lyric under it drops behind the title in
// contrast, and the timestamps take monospaced digits so they stop twitching every second.
#import <math.h>
#import "Core/SGCore.h"
#import "Native/Appearance/Repaint.h"
#import "Native/NowPlayingBar/NowPlayingBar.h"
#import "NowPlaying.h"
#import "Native/Appearance/Appearance.h"
#import "Shared/LocalTrackArtwork/LocalTrackArtwork.h"
#import "Shared/Player/PlayerState.h"

static const CGFloat kButtonMin = 36, kButtonMax = 48;
static const CGFloat kArtRadius = 12;

static __weak UIImageView *sg_nativeBarArtwork;
static __weak UIView *sg_nativeBarRoot;
static UIImage *sg_nativeOriginalArtwork;
static UIImage *sg_nativeAppliedArtwork;
static NSString *sg_nativeArtworkURI;
static NSString *sg_nativeLoadingArtworkKey;

static BOOL backdropOn(void) {
    return SGFlag(SGKeyPlayerBackdrop, NO);
}

static BOOL sameOptionalString(NSString *left, NSString *right) {
    return left == right || [left isEqualToString:right];
}

static UIImageView *barArtworkIn(UIView *root) {
    __block UIImageView *best = nil;
    __block CGFloat bestSide = 31;
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class]) return;
        CGSize size = view.bounds.size;
        if (size.width < 32 || size.width > 80 || fabs(size.width - size.height) > 4 || size.width <= bestSide) return;
        bestSide = size.width;
        best = (UIImageView *)view;
    });
    return best;
}

static void restoreBarArtwork(void) {
    UIImageView *view = sg_nativeBarArtwork;
    if (view && view.image == sg_nativeAppliedArtwork) view.image = sg_nativeOriginalArtwork;
    sg_nativeBarArtwork = nil;
    sg_nativeOriginalArtwork = nil;
    sg_nativeAppliedArtwork = nil;
    sg_nativeArtworkURI = nil;
    sg_nativeLoadingArtworkKey = nil;
}

void SGNativePlayerUpdateBarArtwork(UIView *root) {
    if (root) sg_nativeBarRoot = root;
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (!SGLocalArtworkIsLocalTrack(uri)) {
        restoreBarArtwork();
        return;
    }
    UIImageView *view = barArtworkIn(root);
    if (!view) return;
    if (view != sg_nativeBarArtwork || ![uri isEqualToString:sg_nativeArtworkURI]) {
        restoreBarArtwork();
        sg_nativeBarArtwork = view;
        sg_nativeOriginalArtwork = view.image;
        sg_nativeArtworkURI = uri;
    }
    UIImage *artwork = SGLocalArtworkCachedCover(uri);
    if (artwork) {
        sg_nativeLoadingArtworkKey = nil;
        if (view.image != artwork) view.image = artwork;
        sg_nativeAppliedArtwork = artwork;
        return;
    }
    NSString *coverURL = SGLocalArtworkCoverURL(uri);
    if (!coverURL.length) {
        restoreBarArtwork();
        return;
    }
    NSString *requestKey = [uri stringByAppendingFormat:@"|%@", coverURL];
    if ([requestKey isEqualToString:sg_nativeLoadingArtworkKey]) return;
    sg_nativeLoadingArtworkKey = requestKey;
    SGLocalArtworkLoadCover(uri, ^(UIImage *image) {
        if (![sg_nativeLoadingArtworkKey isEqualToString:requestKey]) return;
        sg_nativeLoadingArtworkKey = nil;
        if (image && view == sg_nativeBarArtwork &&
            [uri isEqualToString:SGURIString(SGPlayerState().track.URI)]) {
            view.image = image;
            sg_nativeAppliedArtwork = image;
        }
    });
}

@interface SGNativeBarArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGNativeBarArtworkWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    (void)state;
    SGNativePlayerUpdateBarArtwork(sg_nativeBarRoot);
}
@end

static SGNativeBarArtworkWatcher *sg_nativeBarArtworkWatcher;

#pragma mark - glass behind the header buttons

// A glass circle per round button in the unit's row: children about as wide as they are tall.
// The playlist name is 110 wide against 48 tall, so it keeps no pane, and neither do the children
// PlayerDeclutter.x made invisible.
static void glassBehindRoundButtons(UIViewController *unit) {
    if (!SGFlag(SGKeyPlayer, NO)) return;
    UIView *host = unit.viewIfLoaded;
    UIStackView *row = SGRowIn(host);
    if (!row) return;
    [row layoutIfNeeded];
    NSUInteger index = 0;
    for (UIView *child in row.arrangedSubviews) {
        CGRect f = SGFrameIn(child, host);
        if (child.hidden || child.alpha == 0 || f.size.width < 20 || f.size.height < 20) continue;
        if (f.size.width > f.size.height * 1.4) continue;
        CGFloat side = MAX(kButtonMin, MIN(MAX(f.size.width, f.size.height), kButtonMax));
        UIVisualEffectView *glass = SGGlassAt(host, index++);
        // Dark whatever the system is set to: the player is presented outside the navigation stacks
        // Spotify makes dark itself, so its panes took the system's light glass on a phone in light mode.
        if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        glass.frame = CGRectMake(CGRectGetMidX(f) - side / 2, CGRectGetMidY(f) - side / 2, side, side);
        SGShapeGlass(glass, side / 2, YES);
    }
    SGHideGlassFrom(host, index);
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    glassBehindRoundButtons((UIViewController *)self);
}
%end

#pragma mark - the cover behind the player

static char kBackdropKey;

static UIImage *sg_cover;       // the cover the backdrop stands on, compared by pointer
static UIImage *sg_coverSmall;
static __weak UIImageView *sg_coverView;
static __weak UIImageView *sg_localCoverView;
static UIImage *sg_originalLocalCover;
static UIImage *sg_appliedLocalCover;
static NSString *sg_appliedLocalURI;
static NSString *sg_appliedLocalURL;
static NSString *sg_loadingLocalCoverKey;
static __weak UIScrollView *sg_playerCoverList;
static void updateLocalCover(void);
static NSMapTable<UIView *, NSNumber *> *sg_coverOverlayAlphas;
static void showCover(UIImage *cover) {
    if (!cover || cover == sg_cover) return;
    sg_cover = cover;
    sg_coverSmall = SGBackdropSample(cover);
    UIImageView *view = sg_coverView;
    if (!view) return;
    [UIView transitionWithView:view duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        view.image = sg_coverSmall;
    } completion:nil];
}

// The covers are the cells of a list scrolled sideways, one per track in the queue; the cell under
// the middle of the list is the one playing.
static UIImageView *coverViewInFront(UIScrollView *list) {
    CGFloat middle = list.contentOffset.x + list.bounds.size.width / 2;
    __block UIImageView *cover = nil;
    // The cover is 354pt across, the glyph standing in for a missing one 64pt.
    __block CGFloat widest = 200;
    for (UIView *cell in list.subviews) {
        if (middle < CGRectGetMinX(cell.frame) || middle > CGRectGetMaxX(cell.frame)) continue;
        SGForEachView(cell, ^(UIView *view) {
            UIImageView *image = (UIImageView *)view;
            if (![view isKindOfClass:UIImageView.class] || image.bounds.size.width < widest) return;
            widest = image.bounds.size.width;
            cover = image;
        });
    }
    return cover;
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

    if (![sibling isKindOfClass:UIImageView.class] || CGRectGetWidth(frame) > width * 0.5 ||
        CGRectGetHeight(frame) > height * 0.5) return NO;
    CGFloat dx = fabs(CGRectGetMidX(frame) - CGRectGetMidX(coverRect));
    CGFloat dy = fabs(CGRectGetMidY(frame) - CGRectGetMidY(coverRect));
    return CGRectGetWidth(frame) >= 24 && CGRectGetHeight(frame) >= 24 &&
           dx <= width * 0.08 && dy <= height * 0.08;
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

static void restoreLocalCover(void) {
    hideCoverOverlays(nil, nil, NO);
    UIImageView *view = sg_localCoverView;
    UIImage *original = sg_originalLocalCover;
    UIImage *applied = sg_appliedLocalCover;
    if (view && view.image == applied) {
        [UIView transitionWithView:view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ view.image = original; } completion:nil];
    }
    sg_localCoverView = nil;
    sg_originalLocalCover = nil;
    sg_appliedLocalCover = nil;
    sg_appliedLocalURI = nil;
    sg_appliedLocalURL = nil;
    sg_loadingLocalCoverKey = nil;
}

static void updateLocalCover(void) {
    UIScrollView *list = sg_playerCoverList;
    if (!list) return;
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    NSString *address = SGLocalArtworkCoverURL(uri);
    if (!SGLocalArtworkIsLocalTrack(uri)) {
        restoreLocalCover();
        if (backdropOn()) showCover(coverViewInFront(list).image);
        return;
    }
    UIImage *selected = SGLocalArtworkCachedCover(uri);
    if (!selected && !address.length) {
        restoreLocalCover();
        if (backdropOn()) showCover(coverViewInFront(list).image);
        return;
    }
    if (!selected) {
        if (![sg_appliedLocalURI isEqualToString:uri] || !sameOptionalString(sg_appliedLocalURL, address)) {
            restoreLocalCover();
        }
        NSString *requestKey = [uri stringByAppendingFormat:@"|%@", address];
        if (![requestKey isEqualToString:sg_loadingLocalCoverKey]) {
            sg_loadingLocalCoverKey = requestKey;
            __weak UIScrollView *weakList = list;
            SGLocalArtworkLoadCover(uri, ^(UIImage *image) {
                if (![sg_loadingLocalCoverKey isEqualToString:requestKey]) return;
                sg_loadingLocalCoverKey = nil;
                if (image && [SGURIString(SGPlayerState().track.URI) isEqualToString:uri] && weakList) {
                    updateLocalCover();
                }
            });
        }
        return;
    }
    sg_loadingLocalCoverKey = nil;
    UIImageView *view = coverViewInFront(list);
    if (!view) return;
    if (view != sg_localCoverView || ![uri isEqualToString:sg_appliedLocalURI] ||
        !sameOptionalString(address, sg_appliedLocalURL)) {
        restoreLocalCover();
        sg_localCoverView = view;
        sg_originalLocalCover = view.image;
        sg_appliedLocalURI = uri;
        sg_appliedLocalURL = address;
    }
    if (view.image != selected) {
        [UIView transitionWithView:view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ view.image = selected; } completion:nil];
    }
    sg_appliedLocalCover = selected;
    UIView *cell = view;
    while (cell.superview && cell.superview != list) cell = cell.superview;
    hideCoverOverlays(view, cell, YES);
    if (backdropOn()) showCover(selected);
}

@interface SGNativeLocalCoverWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGNativeLocalCoverWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    if (!SGLocalArtworkIsLocalTrack(uri)) {
        updateLocalCover();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([uri isEqualToString:SGURIString(SGPlayerState().track.URI)]) updateLocalCover();
    });
}
@end

static SGNativeLocalCoverWatcher *sg_nativeLocalCoverWatcher;

static UIView *backdropIn(UIView *plane) {
    UIView *backdrop = objc_getAssociatedObject(plane, &kBackdropKey);
    if (backdrop) return backdrop;

    backdrop = SGBackdropMake(plane.bounds, SGFlag(SGKeyAmoled, NO) ? 1 : 0.94);
    UIImageView *cover = SGBackdropImageView(backdrop);
    cover.image = sg_coverSmall;
    sg_coverView = cover;

    objc_setAssociatedObject(plane, &kBackdropKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return backdrop;
}

%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!backdropOn()) return;
    UIView *plane = ((UIViewController *)self).viewIfLoaded;
    if (!plane || plane.bounds.size.height < 200) return;
    sg_npvBackdropRoot = plane;
    UIView *backdrop = backdropIn(plane);
    for (UIView *sub in plane.subviews) {
        if (sub != backdrop) SGStripBackgrounds(sub);
    }
    plane.layer.backgroundColor = NULL;
    if (backdrop.superview != plane) [plane insertSubview:backdrop atIndex:0];
}
%end

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    sg_playerCoverList = (UIScrollView *)self;
    updateLocalCover();
    if (backdropOn()) showCover(coverViewInFront((UIScrollView *)self).image);
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (self == sg_localCoverView) {
        NSString *uri = SGURIString(SGPlayerState().track.URI);
        NSString *coverURL = SGLocalArtworkCoverURL(uri);
        UIImage *selected = SGLocalArtworkCachedCover(uri);
        if ([uri isEqualToString:sg_appliedLocalURI] && sameOptionalString(coverURL, sg_appliedLocalURL)) {
            if (selected && image != selected) {
                sg_originalLocalCover = image;
                %orig(selected);
                return;
            }
            if (!selected) sg_originalLocalCover = image;
        }
    }
    if (self == sg_nativeBarArtwork) {
        NSString *uri = SGURIString(SGPlayerState().track.URI);
        UIImage *selected = SGLocalArtworkCachedCover(uri);
        if ([uri isEqualToString:sg_nativeArtworkURI]) {
            if (selected && image != selected) {
                sg_nativeOriginalArtwork = image;
                %orig(selected);
                sg_nativeAppliedArtwork = selected;
                return;
            }
            if (!selected) sg_nativeOriginalArtwork = image;
        }
    }
    %orig(image);
}
%end

#pragma mark - what the cover behind it changes around the player

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    if (!backdropOn()) return;
    UIView *tilt = (UIView *)self;
    CGSize size = tilt.bounds.size;
    // The player's cover only; the bar downstairs carries a 40pt one of its own.
    if (size.width < 200) return;
    SGForEachView(tilt, ^(UIView *view) {
        if (view == tilt || !CGSizeEqualToSize(view.bounds.size, size)) return;
        view.layer.cornerRadius = kArtRadius;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.clipsToBounds = YES;
    });
    tilt.layer.shadowColor = UIColor.blackColor.CGColor;
    tilt.layer.shadowOpacity = 0.45;
    tilt.layer.shadowRadius = 32;
    tilt.layer.shadowOffset = CGSizeMake(0, 12);
    tilt.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:tilt.bounds cornerRadius:kArtRadius].CGPath;
}
%end

%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)layoutSubviews {
    %orig;
    // White at full strength, and alone in the space under the artwork, the line reads louder than
    // the title it sits above. PlayerDeclutter.x hides the same view outright.
    if (backdropOn()) ((UIView *)self).alpha = 0.72;
}
%end

static UIFont *timeFont(void) {
    static UIFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    });
    return font;
}

%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = backdropOn() ? ((UIViewController *)self).viewIfLoaded : nil;
    if (!host) return;
    SGForEachView(host, ^(UIView *view) {
        UILabel *label = (UILabel *)view;
        if (![view isKindOfClass:UILabel.class] || label.font.pointSize > 11 || label.font == timeFont()) return;
        label.font = timeFont();
    });
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit",
        @"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController",
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC22Lyrics_NPVContainerKit19LyricsContainerView",
        @"_TtC20NowPlaying_ModesImpl19DurationElementUnit",
    ]);
    sg_nativeLocalCoverWatcher = [SGNativeLocalCoverWatcher new];
    SGAddPlayerStateObserver(sg_nativeLocalCoverWatcher);
    sg_nativeBarArtworkWatcher = [SGNativeBarArtworkWatcher new];
    SGAddPlayerStateObserver(sg_nativeBarArtworkWatcher);
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalArtworkDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *notification) {
        if (![notification.object isEqualToString:SGURIString(SGPlayerState().track.URI)]) return;
        updateLocalCover();
        SGNativePlayerUpdateBarArtwork(sg_nativeBarRoot);
    }];
}
