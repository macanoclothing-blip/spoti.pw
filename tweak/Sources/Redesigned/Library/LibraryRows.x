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
//
// The grid under "Recently Added" (SGRRecentsGridLayout, in the header file) makes each cell the size of a card,
// but what the cell holds is still Spotify's row: a 64x64 cover and a text stack that is 16+64+12 from its
// leading edge, narrower than the card. Setting the frames of those views loses to the stack's constraints on
// its next pass, which left the cover small and the text cut off, so a card is made another way: the cover is
// moved and scaled by a transform (Auto Layout leaves it alone), Spotify's own labels and icons are put out of
// sight by alpha, and the title and the kind are drawn by two labels of ours that copy their text and run the
// whole width of the card.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Library.h"

// What a row leaves between its artwork and its text (03.txt:36 and :39: the artwork ends at 64, the text
// starts at 76), and where the hairline starts with it.
static const CGFloat kTextGap = 12;

static char kThumbKey, kCoverKey, kLineKey;
static char kCardWatchedKey, kCardTitleKey, kCardSubtitleKey, kCardHiddenKey;

// Whether the row is an artist's, which Spotify draws as a circle: by the radius Spotify gave the picture, or by
// an identifier on it or its stack that says artist.
static BOOL isArtistPicture(UIView *artwork) {
    CGFloat side = MIN(artwork.bounds.size.width, artwork.bounds.size.height);
    if (side >= 1 && artwork.layer.cornerRadius >= side / 2 - 0.5) return YES;
    UIView *view = artwork;
    for (int depth = 0; view && depth < 8; depth++, view = view.superview) {
        NSString *identifier = view.accessibilityIdentifier.lowercaseString;
        NSString *className = NSStringFromClass(view.class).lowercaseString;
        if ([identifier containsString:@"artist"] || [className containsString:@"artist"]) return YES;
    }
    return NO;
}

static BOOL isArtistCell(UIView *cell) {
    UIView *view = cell;
    for (int depth = 0; view && depth < 6; depth++, view = view.superview) {
        NSString *identifier = view.accessibilityIdentifier.lowercaseString;
        NSString *className = NSStringFromClass(view.class).lowercaseString;
        if ([identifier containsString:@"artist"] || [className containsString:@"artist"]) return YES;
    }
    return NO;
}

static void roundArtistArtwork(UIView *cell) {
    if (!isArtistCell(cell)) return;
    SGForEachView(cell, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class]) return;
        CGFloat side = MIN(view.bounds.size.width, view.bounds.size.height);
        if (side < 1) return;
        view.layer.cornerRadius = side / 2;
        view.layer.cornerCurve = kCACornerCurveCircular;
        view.layer.masksToBounds = YES;
    });
}

// Spotify gives a cover a square corner and an artist's picture a circle. Only the square becomes the Kit's; the
// circle is made a true one, as big as the picture's side: a circle left with the continuous corner a reused
// cover had (the radius is half the side, so the squircle shows as a diamond) is what an artist looked like.
static void roundCorners(UIView *artwork, CGFloat radius) {
    if (!artwork) return;
    CGFloat side = MIN(artwork.bounds.size.width, artwork.bounds.size.height);
    CALayer *layer = artwork.layer;
    if (side < 1) return;
    if (isArtistPicture(artwork)) {
        if (layer.cornerRadius != side / 2) layer.cornerRadius = side / 2;
        if (layer.cornerCurve != kCACornerCurveCircular) layer.cornerCurve = kCACornerCurveCircular;
        if (!layer.masksToBounds) layer.masksToBounds = YES;
        return;
    }
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

#pragma mark - the cards

static UILabel *cardLabel(UIView *cell, const void *key) {
    UILabel *label = objc_getAssociatedObject(cell, key);
    if (!label) {
        label = [UILabel new];
        label.userInteractionEnabled = NO;
        label.numberOfLines = 1;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        objc_setAssociatedObject(cell, key, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (label.superview != cell) [cell addSubview:label];
    return label;
}

// Spotify's own label or icon, out of sight for as long as the cell is a card; marked, so a cell that goes back
// to being a row gives back exactly what was taken and nothing Spotify had hidden itself.
static void hideForCard(UIView *view) {
    if (view.alpha != 0) view.alpha = 0;
    objc_setAssociatedObject(view, &kCardHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// A cell that is a row again (a folder's, or one reused from a card): the card's changes taken off.
static void cardTeardown(UIView *cell, UIView *thumb) {
    if (thumb && !CGAffineTransformIsIdentity(thumb.transform)) thumb.transform = CGAffineTransformIdentity;
    UILabel *title = objc_getAssociatedObject(cell, &kCardTitleKey);
    UILabel *subtitle = objc_getAssociatedObject(cell, &kCardSubtitleKey);
    if (title && !title.hidden) title.hidden = YES;
    if (subtitle && !subtitle.hidden) subtitle.hidden = YES;
    SGForEachView(cell, ^(UIView *view) {
        if (!objc_getAssociatedObject(view, &kCardHiddenKey)) return;
        view.alpha = 1;
        objc_setAssociatedObject(view, &kCardHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// A Spotify row made as big as a card, the way the Music app draws one: the cover a square across the top, the
// title 13pt semibold and the kind 12pt in the secondary colour under it.
static void cardLayout(UIView *cell, UIView *thumb) {
    if (!thumb || thumb.bounds.size.width < 1) return;
    CGFloat side = cell.bounds.size.width;

    // The cover, moved and scaled about its own centre so that it covers the square at the card's top. The
    // target is worked out in the cover's superview, which is Spotify's stack and not the cell.
    CGRect target = [cell convertRect:CGRectMake(0, 0, side, side) toView:thumb.superview];
    CGFloat scale = target.size.width / thumb.bounds.size.width;
    CGAffineTransform move = CGAffineTransformScale(
        CGAffineTransformMakeTranslation(CGRectGetMidX(target) - thumb.center.x,
                                         CGRectGetMidY(target) - thumb.center.y), scale, scale);
    if (!CGAffineTransformEqualToTransform(thumb.transform, move)) thumb.transform = move;
    // The corner is scaled with the cover, so it is asked for in the cover's own units. An artist's circle is
    // left alone by roundCorners and scales into a bigger circle.
    roundCorners(thumb, SGRRadiusCover / scale);

    UILabel *title = cardLabel(cell, &kCardTitleKey);
    UILabel *subtitle = cardLabel(cell, &kCardSubtitleKey);

    // Spotify's labels give their text and their colour (the item playing is green) and go out of sight, and so
    // does any other icon of the row (the pin) that is not the cover.
    NSMutableArray<UILabel *> *source = [NSMutableArray array];
    SGForEachView(cell, ^(UIView *view) {
        if (view == cell || view == title || view == subtitle) return;
        if ([view isKindOfClass:UILabel.class]) {
            if (((UILabel *)view).text.length) [source addObject:(UILabel *)view];
            hideForCard(view);
        } else if ([view isKindOfClass:UIImageView.class] && view != thumb &&
                   ![view isDescendantOfView:thumb] && ![thumb isDescendantOfView:view]) {
            hideForCard(view);
        }
    });

    UILabel *first = source.count > 0 ? source[0] : nil;
    UILabel *second = source.count > 1 ? source[1] : nil;
    BOOL hideTitle = !first.text.length, hideSubtitle = !second.text.length;
    if (title.hidden != hideTitle) title.hidden = hideTitle;
    if (subtitle.hidden != hideSubtitle) subtitle.hidden = hideSubtitle;
    if (first && ![title.text isEqualToString:first.text]) title.text = first.text;
    if (second && ![subtitle.text isEqualToString:second.text]) subtitle.text = second.text;

    UIFont *titleFont = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    UIFont *subtitleFont = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    if (![title.font isEqual:titleFont]) title.font = titleFont;
    if (![subtitle.font isEqual:subtitleFont]) subtitle.font = subtitleFont;
    title.textColor = first.textColor ?: SGRPrimary();
    subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.55];

    CGRect titleFrame = CGRectMake(0, side + 8, side, 18);
    CGRect subtitleFrame = CGRectMake(0, side + 26, side, 16);
    if (!CGRectEqualToRect(title.frame, titleFrame)) title.frame = titleFrame;
    if (!CGRectEqualToRect(subtitle.frame, subtitleFrame)) subtitle.frame = subtitleFrame;
}

static void style(UIView *cell) {
    UIView *thumb = SGRFindByIdentifier(cell, @"Artwork.Row.Library", &kThumbKey);
    UIView *cardArtwork = SGRFindByIdentifier(cell, @"Components.UI.CardLibrary.Artwork", &kCoverKey);
    BOOL card = cell.bounds.size.height > 120 && cell.bounds.size.width > 140;
    UIView *artwork = thumb ?: cardArtwork;
    if (artwork) {
        if (card) {
            cardLayout(cell, artwork);
            // Spotify's stack lays its arranged views out again on passes of its own, after the cell's: watch it.
            UIView *host = artwork.superview;
            if (host && !objc_getAssociatedObject(host, &kCardWatchedKey)) {
                objc_setAssociatedObject(host, &kCardWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UIView *weakCell = cell;
                __weak UIView *weakThumb = artwork;
                SGRObserveLayout(host, ^(UIView *view) {
                    UIView *owner = weakCell, *art = weakThumb;
                    if (!owner || !art || art.superview != view) return;
                    if (owner.bounds.size.height > 120 && owner.bounds.size.width > 140) cardLayout(owner, art);
                });
            }
        } else {
            cardTeardown(cell, artwork);
            roundCorners(artwork, SGRRadiusThumb);
        }
        roundArtistArtwork(cell);
    }
    hairline(cell, thumb);

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

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC21YourLibrary_CommonKit47YourLibrarySwipeableCollectionViewCellContainer"]);
}
