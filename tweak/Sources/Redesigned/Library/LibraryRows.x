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
static char kVinylAlbumRowKey, kVinylCardKey;

// In Vinyl mode the album list reads as a vertical cover flow: the album nearest the centre faces the
// listener, while the neighbouring covers recede. The underlying collection view and its selection
// delegate stay intact, so scrolling and opening an album still use Spotify's native page transition.
static void applyVinylFlow(UIView *cell, UICollectionView *collection) {
    if (!cell) return;
    BOOL album = SGRFindByIdentifier(cell, @"Album.Row.Library", &kVinylAlbumRowKey) != nil ||
        SGRFindByIdentifier(cell, @"Components.UI.CardLibrary.Artwork", &kVinylCardKey) != nil;
    if (!SGFlag(SGRKeyPlayerVinyl, NO) || !album || !collection || CGRectGetHeight(collection.bounds) < 160) {
        if (!CATransform3DIsIdentity(cell.layer.transform)) cell.layer.transform = CATransform3DIdentity;
        if (cell.layer.zPosition != 0) cell.layer.zPosition = 0;
        if (cell.alpha != 1) cell.alpha = 1;
        return;
    }
    CGRect frame = [cell convertRect:cell.bounds toView:collection];
    CGFloat centre = CGRectGetHeight(collection.bounds) * 0.53;
    CGFloat step = MAX(72, CGRectGetHeight(frame) + 18);
    CGFloat distance = (CGRectGetMidY(frame) - centre) / step;
    CGFloat depth = MIN(3.2, fabs(distance));
    CGFloat direction = distance < 0 ? -1 : 1;
    CGFloat angle = direction * MIN(0.92, depth * 0.27);
    CGFloat scale = MAX(0.70, 1.08 - depth * 0.105);
    CATransform3D transform = CATransform3DIdentity;
    transform.m34 = -1.0 / 760.0;
    transform = CATransform3DRotate(transform, angle, 1, 0, 0);
    transform = CATransform3DScale(transform, scale, scale, 1);
    transform = CATransform3DTranslate(transform, 0, 0, -depth * 34);
    if (!CATransform3DEqualToTransform(cell.layer.transform, transform)) cell.layer.transform = transform;
    CGFloat z = 100 - depth * 18;
    if (fabs(cell.layer.zPosition - z) > 0.5) cell.layer.zPosition = z;
    CGFloat alpha = MAX(0.42, 1 - depth * 0.16);
    if (fabs(cell.alpha - alpha) > 0.02) cell.alpha = alpha;
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
%end

// Cells do not always relayout while a collection scrolls. Recompute the perspective from the visible
// album positions on the list's own scroll layout pass; other Spotify collections are untouched.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    UICollectionView *collection = (UICollectionView *)self;
    if (!SGFlag(SGRKeyPlayerVinyl, NO) || ![collection.accessibilityIdentifier isEqualToString:SGRLibraryListIdentifier]) return;
    for (UIView *cell in collection.visibleCells) applyVinylFlow(cell, collection);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC21YourLibrary_CommonKit47YourLibrarySwipeableCollectionViewCellContainer"]);
}
