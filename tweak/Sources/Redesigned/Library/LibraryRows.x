// Library redesign: the rows of Your Library and of a folder inside it, and the cards of its grid.
//
// Tree (trees/clean/library/03.txt:30-73, 06.txt:28-40): every cell of the list is a
// YourLibrarySwipeableCollectionViewCellContainer holding either a 402x80 row -- id=Playlist.Row.Library,
// Album.Row.Library or Podcast.Row.Library, all three an AutoLayoutStackView {16, 8} 370x64 of
// id=Artwork.Row.Library 64x64 r=4 and, 12pt after it, the title over its kind and its owner -- or a
// 112.67x161.33 card, id=Components.UI.CardLibrary, over id=Components.UI.CardLibrary.Artwork r=4.
//
// Two things are changed, both of them the Music app's library. The artwork takes the Kit's radius for its
// size with continuous corners, Spotify's 4pt being the square corner of its own look; an artist's picture
// already carries a radius half its side and is left the circle it is (r=32 in the trees, 2 of the 90 rows
// recorded). And a hairline runs between the rows from the text's leading edge, which is where a library list
// draws one -- a layer rather than a view, since the rows are reused as fast as the list scrolls, with its
// actions off so a reused row does not slide its line into place.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Player/PlayerVinyl.h"
#import "Library.h"

// What a row leaves between its artwork and its text (03.txt:36 and :39: the artwork ends at 64, the text
// starts at 76), and where the hairline starts with it.
static const CGFloat kTextGap = 12;

static char kThumbKey, kCoverKey, kLineKey;
static char kVinylAlbumRowKey, kVinylCardKey, kVinylCardViewKey;
static char kVinylOriginalTransformKey, kVinylOriginalZKey, kVinylOriginalAlphaKey, kVinylOriginalClippingKey;
static char kVinylOriginalChildAlphaKey, kVinylOriginalCellLabelKey, kVinylOriginalCellTraitsKey;

@interface SGRLibraryVinylCard : UIView
- (void)updateArtwork:(UIImage *)artwork title:(NSString *)title artist:(NSString *)artist;
- (void)setLabelCounterRotation:(CGFloat)rotation;
@end

@implementation SGRLibraryVinylCard {
    UIImageView *_artwork;
    CAGradientLayer *_shade;
    UILabel *_title;
    UILabel *_artist;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.layer.cornerRadius = 10;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    _artwork = [UIImageView new];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.clipsToBounds = YES;
    [self addSubview:_artwork];
    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)[UIColor clearColor].CGColor,
                      (id)[UIColor colorWithWhite:0 alpha:0.28].CGColor,
                      (id)[UIColor colorWithWhite:0 alpha:0.88].CGColor];
    _shade.locations = @[@0.48, @0.72, @1];
    [self.layer addSublayer:_shade];
    _title = [UILabel new];
    _title.textColor = UIColor.whiteColor;
    _title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_title];
    _artist = [UILabel new];
    _artist.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    _artist.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _artist.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_artist];
    return self;
}

- (void)updateArtwork:(UIImage *)artwork title:(NSString *)title artist:(NSString *)artist {
    if (_artwork.image != artwork) _artwork.image = artwork;
    if (![_title.text isEqualToString:title]) _title.text = title;
    if (![_artist.text isEqualToString:artist]) _artist.text = artist;
    [self setNeedsLayout];
}

- (void)setLabelCounterRotation:(CGFloat)rotation {
    CATransform3D counterRotation = CATransform3DMakeRotation(-rotation, 1, 0, 0);
    if (CATransform3DEqualToTransform(_title.layer.transform, counterRotation) &&
        CATransform3DEqualToTransform(_artist.layer.transform, counterRotation)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _title.layer.transform = counterRotation;
    _artist.layer.transform = counterRotation;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _artwork.frame = self.bounds;
    _shade.frame = self.bounds;
    CGFloat inset = 14;
    CGFloat titleHeight = 21;
    CGFloat artistHeight = 17;
    _artist.frame = CGRectMake(inset, CGRectGetHeight(self.bounds) - artistHeight - 8,
                               MAX(0, CGRectGetWidth(self.bounds) - 2 * inset), artistHeight);
    _title.frame = CGRectMake(inset, CGRectGetMinY(_artist.frame) - titleHeight,
                              MAX(0, CGRectGetWidth(self.bounds) - 2 * inset), titleHeight);
}

@end

static BOOL vinylAlbumCell(UIView *cell) {
    if (SGRFindByIdentifier(cell, @"Album.Row.Library", &kVinylAlbumRowKey)) return YES;
    if (!SGRFindByIdentifier(cell, @"Components.UI.CardLibrary.Artwork", &kVinylCardKey)) return NO;
    __block BOOL albumKind = NO;
    SGForEachView(cell, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        NSString *text = [(UILabel *)view text].lowercaseString;
        if ([text isEqualToString:@"album"] || [text hasPrefix:@"album ·"] || [text hasPrefix:@"album •"]) albumKind = YES;
    });
    return albumKind;
}

static void restoreVinylFlow(UIView *cell, UICollectionView *collection) {
    SGRLibraryVinylCard *card = objc_getAssociatedObject(cell, &kVinylCardViewKey);
    if (card) card.hidden = YES;
    for (UIView *child in cell.subviews) {
        if (child == card) continue;
        NSNumber *alpha = objc_getAssociatedObject(child, &kVinylOriginalChildAlphaKey);
        if (alpha) {
            child.alpha = alpha.doubleValue;
            objc_setAssociatedObject(child, &kVinylOriginalChildAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    NSValue *transform = objc_getAssociatedObject(cell, &kVinylOriginalTransformKey);
    if (transform) cell.layer.transform = transform.CATransform3DValue;
    NSNumber *z = objc_getAssociatedObject(cell, &kVinylOriginalZKey);
    NSNumber *alpha = objc_getAssociatedObject(cell, &kVinylOriginalAlphaKey);
    if (z) cell.layer.zPosition = z.doubleValue;
    if (alpha) cell.alpha = alpha.doubleValue;
    objc_setAssociatedObject(cell, &kVinylOriginalTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kVinylOriginalZKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kVinylOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *ancestor = cell; ancestor && ancestor != collection; ancestor = ancestor.superview) {
        NSNumber *clips = objc_getAssociatedObject(ancestor, &kVinylOriginalClippingKey);
        if (clips) {
            ancestor.clipsToBounds = clips.boolValue;
            objc_setAssociatedObject(ancestor, &kVinylOriginalClippingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    id originalLabel = objc_getAssociatedObject(cell, &kVinylOriginalCellLabelKey);
    if (originalLabel) {
        cell.accessibilityLabel = originalLabel == NSNull.null ? nil : originalLabel;
        objc_setAssociatedObject(cell, &kVinylOriginalCellLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *originalTraits = objc_getAssociatedObject(cell, &kVinylOriginalCellTraitsKey);
    if (originalTraits) {
        cell.accessibilityTraits = originalTraits.unsignedIntegerValue;
        objc_setAssociatedObject(cell, &kVinylOriginalCellTraitsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// In Vinyl mode album entries become a vertically scrolling cover flow like the reference: wide album
// faces tilt away from the centre of the list, while the collection view keeps its native scrolling and
// selection delegate. The cell hit area follows the larger visual card so tapping its artwork still opens it.
static void applyVinylFlow(UIView *cell, UICollectionView *collection) {
    if (!cell) return;
    BOOL album = vinylAlbumCell(cell);
    if (!SGFlag(SGRKeyPlayerVinyl, NO) || !album || !collection || CGRectGetHeight(collection.bounds) < 160) {
        if (objc_getAssociatedObject(cell, &kVinylOriginalTransformKey)) restoreVinylFlow(cell, collection);
        return;
    }

    if (!objc_getAssociatedObject(cell, &kVinylOriginalTransformKey)) {
        objc_setAssociatedObject(cell, &kVinylOriginalTransformKey,
                                 [NSValue valueWithCATransform3D:cell.layer.transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kVinylOriginalZKey, @(cell.layer.zPosition), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kVinylOriginalAlphaKey, @(cell.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    SGRLibraryVinylCard *card = objc_getAssociatedObject(cell, &kVinylCardViewKey);
    if (!card) {
        card = [SGRLibraryVinylCard new];
        card.autoresizingMask = UIViewAutoresizingNone;
        objc_setAssociatedObject(cell, &kVinylCardViewKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell addSubview:card];
    }

    UIView *artworkContainer = SGRFindByIdentifier(cell, @"Artwork.Row.Library", &kThumbKey) ?: cell;
    __block UIImage *image = nil;
    __block NSMutableArray<NSString *> *labels = [NSMutableArray array];
    SGForEachView(artworkContainer ?: cell, ^(UIView *view) {
        if (!image && [view isKindOfClass:UIImageView.class]) {
            UIImageView *imageView = (UIImageView *)view;
            if (imageView.image && MIN(imageView.bounds.size.width, imageView.bounds.size.height) >= 24) image = imageView.image;
        }
    });
    SGForEachView(cell, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        NSString *text = [(UILabel *)view text];
        if (text.length && ![labels containsObject:text]) [labels addObject:text];
    });
    NSString *title = labels.count ? labels[0] : @"";
    NSString *artist = labels.count > 1 ? labels[1] : @"";
    [card updateArtwork:image title:title artist:artist];
    if (!objc_getAssociatedObject(cell, &kVinylOriginalCellLabelKey)) {
        objc_setAssociatedObject(cell, &kVinylOriginalCellLabelKey,
                                 cell.accessibilityLabel ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kVinylOriginalCellTraitsKey, @(cell.accessibilityTraits), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.accessibilityLabel = artist.length ? [NSString stringWithFormat:@"%@, %@", title, artist] : title;
    cell.accessibilityTraits |= UIAccessibilityTraitButton;
    card.hidden = NO;
    for (UIView *ancestor = cell; ancestor && ancestor != collection; ancestor = ancestor.superview) {
        if (!objc_getAssociatedObject(ancestor, &kVinylOriginalClippingKey)) {
            objc_setAssociatedObject(ancestor, &kVinylOriginalClippingKey, @(ancestor.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ancestor.clipsToBounds = NO;
    }
    for (UIView *child in cell.subviews) {
        if (child == card) continue;
        if (!objc_getAssociatedObject(child, &kVinylOriginalChildAlphaKey)) {
            objc_setAssociatedObject(child, &kVinylOriginalChildAlphaKey, @(child.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        child.alpha = 0;
    }

    CGFloat width = CGRectGetWidth(collection.bounds);
    CGFloat side = MIN(MAX(176, width * 0.90), MAX(0, width - 32));
    CGFloat height = CGRectGetHeight(cell.bounds);
    card.frame = CGRectMake((CGRectGetWidth(cell.bounds) - side) / 2,
                            (height - side) / 2, side, side);
    if (cell.subviews.lastObject != card) [cell bringSubviewToFront:card];

    CGPoint center = cell.superview ? [cell.superview convertPoint:cell.center toView:collection] : CGPointZero;
    CGFloat centre = CGRectGetMidY(collection.bounds);
    CGFloat step = MAX(64, height + 8);
    CGFloat distance = (center.y - centre) / step;
    CGFloat depth = MIN(4.0, fabs(distance));
    CGFloat direction = distance < 0 ? -1 : 1;
    // Keep a strong base tilt even for the cover closest to the viewport centre; farther covers turn
    // more edge-on, which makes the wide square artwork read as stacked vinyl sleeves rather than rows.
    CGFloat angle = direction * MIN(1.38, 1.20 + depth * 0.06);
    [card setLabelCounterRotation:angle];
    CGFloat scale = MAX(0.70, 1.04 - depth * 0.10);
    CATransform3D transform = CATransform3DIdentity;
    transform.m34 = -1.0 / 680.0;
    transform = CATransform3DRotate(transform, angle, 1, 0, 0);
    transform = CATransform3DScale(transform, scale, scale, 1);
    transform = CATransform3DTranslate(transform, 0, 0, -depth * 38);
    BOOL transformChanged = !CATransform3DEqualToTransform(cell.layer.transform, transform);
    CGFloat z = 120 - depth * 18;
    BOOL zChanged = fabs(cell.layer.zPosition - z) > 0.5;
    CGFloat alpha = MAX(0.50, 1 - depth * 0.13);
    BOOL alphaChanged = fabs(cell.alpha - alpha) > 0.02;
    if (transformChanged || zChanged || alphaChanged) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (transformChanged) cell.layer.transform = transform;
        if (zChanged) cell.layer.zPosition = z;
        if (alphaChanged) cell.alpha = alpha;
        [CATransaction commit];
    }
}

// Spotify gives a cover a square corner and an artist's picture a circle. Only the square becomes the Kit's.
static void roundCorners(UIView *artwork, CGFloat radius) {
    if (!artwork) return;
    CGFloat side = MIN(artwork.bounds.size.width, artwork.bounds.size.height);
    CALayer *layer = artwork.layer;
    if (side < 1 || layer.cornerRadius >= side / 2 - 0.5) return;
    if (layer.cornerRadius != radius) layer.cornerRadius = radius;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
    if (!layer.masksToBounds) layer.masksToBounds = YES;
}

// The line under a row, from its text's leading edge to the trailing edge of the page. A cell holding a card
// has none, and one reused from a row into a card loses the line it was left with.
static void hairline(UIView *cell, UIView *thumb) {
    CALayer *line = objc_getAssociatedObject(cell, &kLineKey);
    CGSize size = cell.bounds.size;
    CGRect artwork = thumb ? SGFrameIn(thumb, cell) : CGRectZero;
    BOOL wanted = thumb && size.width > 300 && size.height <= 120 && artwork.size.width > 1;
    if (!wanted) {
        if (line && !line.hidden) line.hidden = YES;
        return;
    }
    if (!line) {
        line = [CALayer layer];
        line.backgroundColor = SGRHairline().CGColor;
        objc_setAssociatedObject(cell, &kLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superlayer != cell.layer) [cell.layer addSublayer:line];

    CGFloat thickness = 1.0 / MAX(1, cell.window.screen.scale ?: UIScreen.mainScreen.scale);
    CGFloat leading = CGRectGetMaxX(artwork) + kTextGap;
    CGRect frame = CGRectMake(leading, size.height - thickness, MAX(0, size.width - leading), thickness);
    if (line.hidden || !CGRectEqualToRect(line.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        line.hidden = NO;
        line.frame = frame;
        [CATransaction commit];
    }
}

static void style(UIView *cell) {
    UIView *thumb = SGRFindByIdentifier(cell, @"Artwork.Row.Library", &kThumbKey);
    if (thumb) roundCorners(thumb, SGRRadiusThumb);
    else roundCorners(SGRFindByIdentifier(cell, @"Components.UI.CardLibrary.Artwork", &kCoverKey), SGRRadiusCover);
    hairline(cell, thumb);
    UICollectionView *collection = nil;
    for (UIView *view = cell.superview; view; view = view.superview) {
        if ([view isKindOfClass:UICollectionView.class]) { collection = (UICollectionView *)view; break; }
    }
    applyVinylFlow(cell, collection);

    // The first cell that held an artwork, so the line says what was found rather than what had not loaded yet.
    static BOOL logged;
    if (!logged && thumb && thumb.bounds.size.width > 1) {
        logged = YES;
        SGLog(@"redesign library: rows styled, first cell %@, thumbnail %@ at r=%.1f",
              NSStringFromCGSize(cell.bounds.size), NSStringFromCGSize(thumb.bounds.size), thumb.layer.cornerRadius);
    }
}

%hook _TtC21YourLibrary_CommonKit47YourLibrarySwipeableCollectionViewCellContainer
- (void)layoutSubviews {
    %orig;
    style((UIView *)self);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL inside = %orig;
    if (inside) return YES;
    SGRLibraryVinylCard *card = objc_getAssociatedObject((UIView *)self, &kVinylCardViewKey);
    return SGFlag(SGRKeyPlayerVinyl, NO) && card && !card.hidden && CGRectContainsPoint(card.frame, point);
}
%end

// Cells do not always relayout while a collection scrolls. Recompute the perspective from the visible
// album positions on the list's own scroll layout pass; other Spotify collections are untouched.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    UICollectionView *collection = (UICollectionView *)self;
    // Album.Row.Library is Spotify's library-only row identifier. Let it drive the effect instead of
    // requiring the collection view itself to expose a particular private accessibility identifier.
    for (UIView *cell in collection.visibleCells) applyVinylFlow(cell, collection);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC21YourLibrary_CommonKit47YourLibrarySwipeableCollectionViewCellContainer"]);
}
