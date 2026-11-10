// Home redesign: every card Home keeps is the same Encore button, told apart where it lays out:
//   id=Shortcut.Card.Home          a shortcut tile 181x48 r=4 that clips, in a ConfigurableUIEventObservingView
//                                  r=4 (trees/clean/home/01.txt:36-37): the cover radius, continuous, and its
//                                  picture run across it (HomeTiles.m)
//   id=Components.UI.HomeCard      a shelf card, its picture Encore.ImageView 149x149 > UIImageView with no radius
//                                  of its own (10.txt:2280-2286): cut at the cover radius, continuous, over the
//                                  4pt Spotify bakes into the picture (an artist's round one sits inside it)
//   in Discovery_MediumDensityCardKit.DJMDCView   the DJ card 370x192 r=8 that clips (01.txt:477-478): the card
//                                  radius, and without the transcript Spotify's DJ talks through
//                                  (Discovery_MediumDensityCardKit.TranscriptView, :500) or the Beta badge (:503)
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// Below this a card's picture is a glyph or a placeholder, not a cover.
static const CGFloat kCoverMinWidth = 80;

static char kImageKey, kGlassFilmKey, kGlassRimKey, kGlassBoundsKey;
static char kCardGlassKey, kCardImageKey, kCardTintKey, kHighlightTransformKey;
static char kCardCoverKey, kCardObservedCoverKey, kCardImageObserverReadyKey, kCardStyleBoundsKey;
static NSMapTable<UIImage *, UIColor *> *cardTints(void) {
    static NSMapTable *table;
    if (!table) table = [NSMapTable weakToStrongObjectsMapTable];
    return table;
}

static void tintArtworkGlass(UIView *card, UIColor *color) {
    UIVisualEffectView *glass = objc_getAssociatedObject(card, &kCardGlassKey);
    if (!glass) return;
    if (@available(iOS 26.0, *)) {
        if (!SGRReduceTransparency()) {
            UIColor *tint = color ? [color colorWithAlphaComponent:0.36] : [UIColor colorWithWhite:1 alpha:0.10];
            UIColor *previous = objc_getAssociatedObject(card, &kCardTintKey);
            if ([previous isEqual:tint]) return;
            objc_setAssociatedObject(card, &kCardTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleClear];
            effect.interactive = YES;
            effect.tintColor = tint;
            glass.effect = effect;
        }
    }
}

static UIImageView *artworkCover(UIView *card) {
    UIView *holder = SGRFindByIdentifier(card, @"Encore.ImageView", &kImageKey);
    if (!holder) return nil;
    UIImageView *cover = objc_getAssociatedObject(card, &kCardCoverKey);
    if (cover && cover.superview == holder) return cover;
    for (UIView *view in holder.subviews) {
        if ([view isKindOfClass:UIImageView.class]) {
            cover = (UIImageView *)view;
            break;
        }
    }
    objc_setAssociatedObject(card, &kCardCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cover;
}

static void updateArtworkGlassTint(UIView *card) {
    UIImageView *cover = artworkCover(card);
    UIImage *image = cover.image;
    if (!image) {
        objc_setAssociatedObject(card, &kCardImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tintArtworkGlass(card, nil);
        return;
    }
    UIColor *known = [cardTints() objectForKey:image];
    if (known) {
        objc_setAssociatedObject(card, &kCardImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tintArtworkGlass(card, known);
        return;
    }
    if (objc_getAssociatedObject(card, &kCardImageKey) == image) return;
    objc_setAssociatedObject(card, &kCardImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakCard = card;
    [SGRPalette tintForImage:image surface:SGRElevated(UIColor.blackColor) completion:^(UIColor *color) {
        UIView *strongCard = weakCard;
        if (color) [cardTints() setObject:color forKey:image];
        if (strongCard && objc_getAssociatedObject(strongCard, &kCardImageKey) == image) {
            tintArtworkGlass(strongCard, color);
        }
    }];
}

static BOOL watchArtworkCover(UIView *card) {
    UIImageView *cover = artworkCover(card);
    if (!cover) return NO;
    if (objc_getAssociatedObject(card, &kCardObservedCoverKey) == cover) {
        NSNumber *ready = objc_getAssociatedObject(card, &kCardImageObserverReadyKey);
        if (ready) return ready.boolValue;
    }
    objc_setAssociatedObject(card, &kCardObservedCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakCard = card;
    BOOL observing = SGRObserveImage(cover, ^(UIImageView *changed) {
        UIView *strongCard = weakCard;
        if (strongCard && [changed isDescendantOfView:strongCard]) updateArtworkGlassTint(strongCard);
    });
    objc_setAssociatedObject(card, &kCardImageObserverReadyKey, @(observing), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return observing;
}

static void roundCorners(UIView *view, CGFloat radius) {
    CALayer *layer = view.layer;
    if (layer.cornerRadius != radius) layer.cornerRadius = radius;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
}

static void roundCover(UIView *card) {
    UIView *holder = SGRFindByIdentifier(card, @"Encore.ImageView", &kImageKey);
    if (!holder || holder.bounds.size.width < kCoverMinWidth) return;
    for (UIView *sub in holder.subviews) {
        if (![sub isKindOfClass:UIImageView.class]) continue;
        roundCorners(sub, SGRRadiusCover);
        if (!sub.layer.masksToBounds) sub.layer.masksToBounds = YES;
    }
}

// Tinted clear glass sits below each card's content; the light wash and rim stay as cheap layers above it,
// so the artwork and labels remain sharp while the card still reads as glass.
static void glassArtworkCard(UIView *card) {
    roundCorners(card, 16);
    card.layer.masksToBounds = YES;
    UIVisualEffectView *glass = objc_getAssociatedObject(card, &kCardGlassKey);
    if (@available(iOS 26.0, *)) {
        if (!SGRReduceTransparency()) {
            if (!glass) {
                glass = [UIVisualEffectView new];
                glass.userInteractionEnabled = NO;
                glass.accessibilityElementsHidden = YES;
                objc_setAssociatedObject(card, &kCardGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (glass.superview != card) [card insertSubview:glass atIndex:0];
            glass.hidden = NO;
            if (!objc_getAssociatedObject(card, &kCardTintKey)) tintArtworkGlass(card, nil);
            if (!CGRectEqualToRect(glass.frame, card.bounds)) glass.frame = card.bounds;
            SGShapeGlass(glass, 16, NO);
        } else if (glass) {
            glass.hidden = YES;
        }
    } else if (glass) {
        glass.hidden = YES;
    }
    watchArtworkCover(card);
    updateArtworkGlassTint(card);

    CAGradientLayer *film = objc_getAssociatedObject(card, &kGlassFilmKey);
    CAShapeLayer *rim = objc_getAssociatedObject(card, &kGlassRimKey);
    if (!film) {
        film = [CAGradientLayer layer];
        film.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.105].CGColor,
                        (id)[UIColor colorWithWhite:1 alpha:0.012].CGColor,
                        (id)[UIColor colorWithWhite:1 alpha:0.035].CGColor];
        film.locations = @[@0, @0.48, @1];
        film.startPoint = CGPointMake(0.5, 0);
        film.endPoint = CGPointMake(0.5, 1);
        film.zPosition = 1;
        CAShapeLayer *mask = [CAShapeLayer layer];
        film.mask = mask;
        [card.layer addSublayer:film];
        objc_setAssociatedObject(card, &kGlassFilmKey, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!rim) {
        rim = [CAShapeLayer layer];
        rim.fillColor = UIColor.clearColor.CGColor;
        rim.strokeColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        rim.lineWidth = 1;
        rim.zPosition = 2;
        [card.layer addSublayer:rim];
        objc_setAssociatedObject(card, &kGlassRimKey, rim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect bounds = card.bounds;
    NSValue *lastBounds = objc_getAssociatedObject(card, &kGlassBoundsKey);
    if (lastBounds && CGRectEqualToRect(lastBounds.CGRectValue, bounds)) return;
    if (!CGRectEqualToRect(film.frame, bounds)) film.frame = bounds;
    CAShapeLayer *mask = (CAShapeLayer *)film.mask;
    mask.frame = film.bounds;
    mask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(film.bounds, 0.5, 0.5)
                                            cornerRadius:MIN(16, CGRectGetHeight(film.bounds) / 2)].CGPath;
    rim.frame = bounds;
    rim.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, 0.5, 0.5)
                                           cornerRadius:MIN(16, CGRectGetHeight(bounds) / 2)].CGPath;
    objc_setAssociatedObject(card, &kGlassBoundsKey, [NSValue valueWithCGRect:bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The transcript's own labels are plain UILabels the Kit keeps transparent; the Swift views around them
// take their alpha again on every pass.
static void calmDJ(UIView *card) {
    for (UIView *sub in card.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if (![name containsString:@"TranscriptView"] && ![name containsString:@"BetaBadge"]) continue;
        if (sub.alpha != 0) sub.alpha = 0;
        sub.accessibilityElementsHidden = YES;
        SGForEachView(sub, ^(UIView *v) {
            if ([v isKindOfClass:UILabel.class]) SGRSuppress(v);
        });
    }
}

static void style(UIView *button) {
    NSString *identifier = button.accessibilityIdentifier;
    if ([identifier isEqualToString:@"Shortcut.Card.Home"]) {
        roundCorners(button, SGRRadiusCover);
        if (button.superview.layer.cornerRadius > 0) roundCorners(button.superview, SGRRadiusCover);
        SGRHomeStyleTile(button);
        return;
    }
    if ([identifier isEqualToString:@"Components.UI.HomeCard"]) {
        NSValue *lastBounds = objc_getAssociatedObject(button, &kCardStyleBoundsKey);
        NSNumber *observerReady = objc_getAssociatedObject(button, &kCardImageObserverReadyKey);
        UIVisualEffectView *glass = objc_getAssociatedObject(button, &kCardGlassKey);
        CAGradientLayer *film = objc_getAssociatedObject(button, &kGlassFilmKey);
        CAShapeLayer *rim = objc_getAssociatedObject(button, &kGlassRimKey);
        BOOL appearanceIntact = button.layer.cornerRadius == 16 && button.layer.masksToBounds &&
                                film.superlayer == button.layer && rim.superlayer == button.layer &&
                                (!glass || glass.superview == button);
        if (appearanceIntact && observerReady.boolValue && lastBounds &&
            CGRectEqualToRect(lastBounds.CGRectValue, button.bounds)) return;
        roundCover(button);
        glassArtworkCard(button);
        objc_setAssociatedObject(button, &kCardStyleBoundsKey, [NSValue valueWithCGRect:button.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    static Class dj;
    if (!dj) dj = NSClassFromString(@"_TtC30Discovery_MediumDensityCardKit9DJMDCView");
    if (dj && [button.superview isKindOfClass:dj]) {
        roundCorners(button, SGRRadiusCard);
        calmDJ(button);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign home: DJ card at the card radius, transcript gone"); });
    }
}

%hook _TtC19LegacyUI_ECMCoreKit31InteractableLayoutBackingButton
- (void)layoutSubviews {
    %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    style((UIView *)self);
    SGRHomeProbeEnd(SGRHomeProbeCards, began);
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    UIView *button = (UIView *)self;
    NSString *identifier = button.accessibilityIdentifier;
    if (![identifier isEqualToString:@"Shortcut.Card.Home"] &&
        ![identifier isEqualToString:@"Components.UI.HomeCard"]) return;
    NSValue *stored = objc_getAssociatedObject(button, &kHighlightTransformKey);
    CGAffineTransform base = stored ? stored.CGAffineTransformValue : button.transform;
    if (highlighted && !stored) {
        objc_setAssociatedObject(button, &kHighlightTransformKey,
                                 [NSValue valueWithCGAffineTransform:base], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform transform = highlighted && !SGRReduceMotion()
        ? CGAffineTransformConcat(base, CGAffineTransformMakeScale(0.985, 0.985)) : base;
    SGRAnimate(SGRMotionPress, ^{ button.transform = transform; }, nil);
    if (!highlighted) objc_setAssociatedObject(button, &kHighlightTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC19LegacyUI_ECMCoreKit31InteractableLayoutBackingButton",
        @"_TtC30Discovery_MediumDensityCardKit9DJMDCView",
    ]);
}
