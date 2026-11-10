// Home redesign: a shortcut tile the way an Apple list row holds artwork. The cover sits inset from the tile's
// edges with its own corners, the title follows it in, and the tile is a dark surface tinted faintly towards the
// cover's dominant colour (Kit/SGRPalette.h, +tintForImage:), so the grid is not one grey and white text always
// reads. Until the cover has loaded, the tile is the untinted surface.
//
// The surface sits behind Spotify's stack, over the tile's own fill, so the title, the playing indicator and
// the button's touches stay Spotify's. The inset and the title's move are transforms, which Spotify's layout
// never reads, so its constraints are left as they are. The tint is worked out off the main thread once per
// picture and follows the cover as Spotify sets it (SGRObserveImage), since a cover lands after layout.
//
// Tree (trees/home 3 more scrolled.txt:36-50, 2026-09-17): InteractableLayoutBackingButton id=Shortcut.Card.Home
// 181x48 clips > UIView 181x48 bg=#FFFFFF@0.10 (the fill), then Encore.StackView > AutoLayoutStackView >
// UIView 173x48 (the row) > UIView {0, 0} 48x48 bg=#000000@0.90 r=4 (the cover's square) > Encore.ImageView >
// UIImageView 48x48 and the PlaceholderView; then the row's 8pt spacer and the title's stack at x 56.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// How far the cover sits in from the tile's top, bottom and leading edges, and its corners there.
static const CGFloat kInset = 5, kCoverRadius = 4;
static const CGFloat kTileRadius = 14;

static char kSurfaceKey, kSurfaceGlassKey, kSurfaceGlassTintKey, kImageKey, kShownKey;
static char kPartsKey, kObservedCoverKey, kRefreshBoundsKey, kRefreshImageKey, kImageObserverReadyKey;

// Tints already worked out, by the image object while it lives (main thread only).
static NSMapTable<UIImage *, UIColor *> *tints(void) {
    static NSMapTable *table;
    if (!table) table = [NSMapTable weakToStrongObjectsMapTable];
    return table;
}

static UIColor *untinted(void) {
    static UIColor *color;
    if (!color) color = SGRElevated(UIColor.blackColor);
    return color;
}

@interface SGRTileParts : NSObject
@property (nonatomic, weak) UIView *fill;
@property (nonatomic, weak) UIView *holder;
@property (nonatomic, weak) UIView *square;
@property (nonatomic, weak) UIImageView *cover;
@end

@implementation SGRTileParts
@end

static SGRTileParts *partsOf(UIView *tile) {
    SGRTileParts *cached = objc_getAssociatedObject(tile, &kPartsKey);
    if (cached.cover && cached.cover.superview == cached.holder &&
        cached.holder && [cached.holder isDescendantOfView:tile] &&
        cached.square && [cached.square isDescendantOfView:tile]) return cached;
    objc_setAssociatedObject(tile, &kRefreshBoundsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tile, &kRefreshImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *holder = SGRFindByIdentifier(tile, @"Encore.ImageView", &kImageKey);
    SGRTileParts *parts = [SGRTileParts new];
    parts.holder = holder;
    for (UIView *sub in holder.subviews) {
        if ([sub isKindOfClass:UIImageView.class]) parts.cover = (UIImageView *)sub;
    }
    parts.square = holder.superview;
    UIView *first = tile.subviews.firstObject;
    if (object_getClass(first) == UIView.class && CGRectEqualToRect(first.frame, tile.bounds)) parts.fill = first;
    objc_setAssociatedObject(tile, &kPartsKey, parts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return parts;
}

static UIView *surfaceIn(UIView *tile, UIView *fill) {
    UIView *surface = objc_getAssociatedObject(tile, &kSurfaceKey);
    if (!surface) {
        surface = [UIView new];
        surface.userInteractionEnabled = NO;
        surface.accessibilityElementsHidden = YES;
        surface.backgroundColor = untinted();
        objc_setAssociatedObject(tile, &kSurfaceKey, surface, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (surface.superview != tile) {
        if (fill) [tile insertSubview:surface aboveSubview:fill];
        else [tile insertSubview:surface atIndex:0];
    }
    if (!CGRectEqualToRect(surface.frame, tile.bounds)) surface.frame = tile.bounds;
    surface.layer.cornerRadius = kTileRadius;
    surface.layer.cornerCurve = kCACornerCurveContinuous;
    surface.layer.borderWidth = 0.75;
    surface.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    surface.clipsToBounds = YES;
    UIVisualEffectView *glass = objc_getAssociatedObject(surface, &kSurfaceGlassKey);
    if (@available(iOS 26.0, *)) {
        if (!SGRReduceTransparency()) {
            if (!glass) {
                glass = [UIVisualEffectView new];
                glass.userInteractionEnabled = NO;
                glass.accessibilityElementsHidden = YES;
                glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                objc_setAssociatedObject(surface, &kSurfaceGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (glass.superview != surface) [surface insertSubview:glass atIndex:0];
            glass.hidden = NO;
            if (!CGRectEqualToRect(glass.frame, surface.bounds)) glass.frame = surface.bounds;
            SGShapeGlass(glass, kTileRadius, NO);
        } else if (glass) {
            glass.hidden = YES;
        }
    } else if (glass) {
        glass.hidden = YES;
    }
    return surface;
}

// The square scaled about its centre so it clears the tile's edges by kInset, and everything after it in the
// row moved in by what that took off its trailing side.
static void inset(UIView *square) {
    CGFloat side = square.bounds.size.height;
    if (side <= kInset * 4) return;
    CGFloat scale = (side - kInset * 2) / side;
    CGAffineTransform shrink = CGAffineTransformMakeScale(scale, scale);
    if (!CGAffineTransformEqualToTransform(square.transform, shrink)) square.transform = shrink;
    CALayer *layer = square.layer;
    // The radius is drawn scaled with the square.
    CGFloat radius = kCoverRadius / scale;
    if (layer.cornerRadius != radius) layer.cornerRadius = radius;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
    if (!layer.masksToBounds) layer.masksToBounds = YES;

    CGAffineTransform follow = CGAffineTransformMakeTranslation(-square.bounds.size.width * (1 - scale) / 2, 0);
    BOOL after = NO;
    for (UIView *sibling in square.superview.subviews) {
        if (sibling == square) {
            after = YES;
            continue;
        }
        if (after && !CGAffineTransformEqualToTransform(sibling.transform, follow)) sibling.transform = follow;
    }
}

static void tint(UIView *tile, UIView *surface, UIColor *color, BOOL animated) {
    color = color ?: untinted();
    UIVisualEffectView *glass = objc_getAssociatedObject(surface, &kSurfaceGlassKey);
    if (@available(iOS 26.0, *)) {
        if (glass && !SGRReduceTransparency()) {
            UIColor *glassTint = [color colorWithAlphaComponent:0.42];
            UIColor *previous = objc_getAssociatedObject(glass, &kSurfaceGlassTintKey);
            if (![previous isEqual:glassTint]) {
                UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleClear];
                effect.tintColor = glassTint;
                effect.interactive = YES;
                glass.effect = effect;
                objc_setAssociatedObject(glass, &kSurfaceGlassTintKey, glassTint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if ([surface.backgroundColor isEqual:color]) return;
    if (!animated || !tile.window) {
        surface.backgroundColor = color;
        return;
    }
    SGRAnimate(SGRMotionFade, ^{ surface.backgroundColor = color; }, nil);
}

static void refresh(UIView *tile) {
    SGRTileParts *parts = partsOf(tile);
    UIImageView *cover = parts.cover;
    UIView *square = parts.square;
    if (!cover || !square || square.bounds.size.width < 20 || tile.bounds.size.width <= square.bounds.size.width) return;
    UIImage *image = cover.image;
    NSValue *lastBounds = objc_getAssociatedObject(tile, &kRefreshBoundsKey);
    id lastImage = objc_getAssociatedObject(tile, &kRefreshImageKey);
    id imageValue = image ?: NSNull.null;
    UIView *cachedSurface = objc_getAssociatedObject(tile, &kSurfaceKey);
    if (lastBounds && CGRectEqualToRect(lastBounds.CGRectValue, tile.bounds) &&
        lastImage == imageValue && cachedSurface.superview == tile) return;

    UIView *surface = surfaceIn(tile, parts.fill);
    inset(square);

    if (!image) {
        objc_setAssociatedObject(tile, &kShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tint(tile, surface, nil, NO);
        objc_setAssociatedObject(tile, &kRefreshBoundsKey, [NSValue valueWithCGRect:tile.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tile, &kRefreshImageKey, NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    objc_setAssociatedObject(tile, &kRefreshBoundsKey, [NSValue valueWithCGRect:tile.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tile, &kRefreshImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *known = [tints() objectForKey:image];
    if (known) {
        objc_setAssociatedObject(tile, &kShownKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tint(tile, surface, known, YES);
        return;
    }
    if (objc_getAssociatedObject(tile, &kShownKey) == image) return;
    objc_setAssociatedObject(tile, &kShownKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakTile = tile;
    [SGRPalette tintForImage:image surface:untinted() completion:^(UIColor *color) {
        UIView *strongTile = weakTile;
        if (color) [tints() setObject:color forKey:image];
        // A tile reused for another cover in the meantime has asked for that one.
        if (!strongTile || objc_getAssociatedObject(strongTile, &kShownKey) != image) return;
        tint(strongTile, surfaceIn(strongTile, partsOf(strongTile).fill), color, YES);
    }];
}

void SGRHomeStyleTile(UIView *tile) {
    CFTimeInterval began = SGRHomeProbeBegin();
    UIImageView *cover = partsOf(tile).cover;
    if (!cover) return;
    if (objc_getAssociatedObject(tile, &kObservedCoverKey) != cover) {
        objc_setAssociatedObject(tile, &kObservedCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakTile = tile;
        BOOL observing = SGRObserveImage(cover, ^(UIImageView *view) {
            UIView *strongTile = weakTile;
            if (strongTile && [view isDescendantOfView:strongTile]) refresh(strongTile);
        });
        objc_setAssociatedObject(tile, &kImageObserverReadyKey, @(observing), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSValue *lastBounds = objc_getAssociatedObject(tile, &kRefreshBoundsKey);
    NSNumber *observerReady = objc_getAssociatedObject(tile, &kImageObserverReadyKey);
    id imageValue = cover.image ?: NSNull.null;
    if (observerReady.boolValue && lastBounds &&
        CGRectEqualToRect(lastBounds.CGRectValue, tile.bounds) &&
        objc_getAssociatedObject(tile, &kRefreshImageKey) == imageValue) {
        SGRHomeProbeEnd(SGRHomeProbeTiles, began);
        return;
    }
    refresh(tile);
    SGRHomeProbeEnd(SGRHomeProbeTiles, began);
}
