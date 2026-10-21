// Artist redesign: the Music list, including Spotify's own music video shelf, with nothing painted over the field.
//
// Tree (trees/clean/artist/05.txt, the Music list top to bottom): Popular, Artist pick, Popular releases and
// its Show all, Featuring, Release Countdown, Music videos, Watch more from…, About, Artist playlists, Fans
// also like, Appears on. Every section is three Element_List cells in a row -- a 16pt spacer, a heading
// (Components.UI.SectionHeadingHome) and what the section holds -- and every kind of content carries an
// identifier of its own, in any language: Components.UI.RetrievalRowElementUI (tracks), PinnedItemUI (the
// pick), HomeCard (a carousel), UpcomingReleaseRow, CreatorBiographyCard (About),
// Components.UI.MusicVideoShelfHeader and WatchFeedCarouselEntryPointElement (videos).
//
// The Music video shelf remains in the artist's Music feed, alongside its other Spotify supplied carousels.
// The type walk is retained to keep Spotify's cell sizing stable if the shelf is absent from a particular artist.
//
// A dropped cell is 0 tall but what it holds keeps the height it measured at, hidden and cut off by the
// cell: content squeezed to 0 breaks Spotify's required constraints on every pass (Album/AlbumSections.x).
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Artist.h"

static char kSettledKey, kKindsKey, kDroppedKey, kTrackKey;
static char kLikedRowKey, kLikedOriginalAlphaKey;

@interface SGRArtistLikedRow : UIView
@property (nonatomic, weak) UICollectionViewCell *sourceCell;
- (void)updateTitle:(NSString *)title subtitle:(NSString *)subtitle;
@end

@implementation SGRArtistLikedRow {
    UIView *_capsule, *_heartDisc, *_chevronDisc;
    UIImageView *_heart, *_chevron;
    UILabel *_title, *_subtitle;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Apri i brani che hai salvato per questo artista";
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sgr_tap)];
    tap.cancelsTouchesInView = YES;
    [self addGestureRecognizer:tap];

    _capsule = [UIView new];
    _capsule.userInteractionEnabled = NO;
    _capsule.backgroundColor = [UIColor colorWithWhite:1 alpha:0.105];
    _capsule.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.13].CGColor;
    _capsule.layer.borderWidth = 0.75;
    _capsule.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_capsule];

    _heartDisc = [UIView new];
    _heartDisc.userInteractionEnabled = NO;
    _heartDisc.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _heartDisc.layer.cornerCurve = kCACornerCurveContinuous;
    [_capsule addSubview:_heartDisc];
    _heart = [UIImageView new];
    _heart.image = [[UIImage systemImageNamed:@"heart.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _heart.tintColor = SGRAccent();
    _heart.contentMode = UIViewContentModeScaleAspectFit;
    _heart.userInteractionEnabled = NO;
    [_heartDisc addSubview:_heart];

    _title = [UILabel new];
    _title.textColor = SGRPrimary();
    _title.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightSemibold, UIContentSizeCategoryExtraLarge);
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.userInteractionEnabled = NO;
    [_capsule addSubview:_title];
    _subtitle = [UILabel new];
    _subtitle.textColor = SGRSecondary();
    _subtitle.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryExtraLarge);
    _subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitle.userInteractionEnabled = NO;
    [_capsule addSubview:_subtitle];

    _chevronDisc = [UIView new];
    _chevronDisc.userInteractionEnabled = NO;
    _chevronDisc.backgroundColor = [UIColor colorWithWhite:1 alpha:0.11];
    _chevronDisc.layer.cornerCurve = kCACornerCurveContinuous;
    [_capsule addSubview:_chevronDisc];
    _chevron = [UIImageView new];
    _chevron.image = [[UIImage systemImageNamed:@"chevron.right"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _chevron.tintColor = SGRPrimary();
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    _chevron.userInteractionEnabled = NO;
    [_chevronDisc addSubview:_chevron];
    return self;
}
- (void)sgr_tap {
    SGRActivate(self.sourceCell);
}
- (void)updateTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if (title.length && ![_title.text isEqualToString:title]) _title.text = title;
    if (subtitle.length && ![_subtitle.text isEqualToString:subtitle]) _subtitle.text = subtitle;
    _subtitle.hidden = !subtitle.length;
    self.accessibilityLabel = title;
    self.accessibilityValue = subtitle;
    [self setNeedsLayout];
}
- (BOOL)accessibilityActivate {
    SGRActivate(self.sourceCell);
    return self.sourceCell != nil;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat cardHeight = MIN(72, MAX(56, CGRectGetHeight(bounds) - 8));
    CGFloat cardY = round((CGRectGetHeight(bounds) - cardHeight) / 2);
    _capsule.frame = CGRectMake(16, cardY, MAX(0, CGRectGetWidth(bounds) - 32), cardHeight);
    _capsule.layer.cornerRadius = cardHeight / 2;

    CGFloat discSide = MIN(48, cardHeight - 8);
    _heartDisc.frame = CGRectMake(6, round((cardHeight - discSide) / 2), discSide, discSide);
    _heartDisc.layer.cornerRadius = discSide / 2;
    CGFloat heartSide = MIN(26, discSide * 0.56);
    _heart.frame = CGRectMake(round((discSide - heartSide) / 2), round((discSide - heartSide) / 2), heartSide, heartSide);

    CGFloat trailing = 12, chevronSide = MIN(36, cardHeight - 16);
    _chevronDisc.frame = CGRectMake(CGRectGetWidth(_capsule.bounds) - trailing - chevronSide,
                                    round((cardHeight - chevronSide) / 2), chevronSide, chevronSide);
    _chevronDisc.layer.cornerRadius = chevronSide / 2;
    CGFloat chevronGlyph = MIN(17, chevronSide * 0.48);
    _chevron.frame = CGRectMake(round((chevronSide - chevronGlyph) / 2), round((chevronSide - chevronGlyph) / 2),
                                chevronGlyph, chevronGlyph);

    CGFloat labelX = CGRectGetMaxX(_heartDisc.frame) + 12;
    CGFloat labelWidth = MAX(0, CGRectGetMinX(_chevronDisc.frame) - labelX - 10);
    CGFloat titleHeight = 23, subtitleHeight = 20, textHeight = _subtitle.hidden ? titleHeight : titleHeight + subtitleHeight + 2;
    CGFloat textY = round((cardHeight - textHeight) / 2);
    _title.frame = CGRectMake(labelX, textY, labelWidth, titleHeight);
    _subtitle.frame = CGRectMake(labelX, textY + titleHeight + 2, labelWidth, subtitleHeight);
}
@end

static NSString *normalizedArtistRowText(NSString *text) {
    return [[text stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil]
            lowercaseString];
}

static BOOL isLikedArtistRow(UIView *cell) {
    __block BOOL liked = NO;
    SGForEachView(cell, ^(UIView *view) {
        if (liked) return;
        NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : view.accessibilityLabel;
        NSString *normalized = normalizedArtistRowText(text ?: @"");
        liked = [normalized containsString:@"cosa ti e piaciuto"] ||
                [normalized containsString:@"you liked"] ||
                [normalized containsString:@"liked songs"] ||
                [normalized containsString:@"brani che ti sono piaciuti"];
    });
    return liked;
}

static void artistLikedRowText(UIView *cell, NSString **title, NSString **subtitle) {
    __block NSString *foundTitle = nil, *foundSubtitle = nil;
    SGForEachView(cell, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        NSString *text = [((UILabel *)view).text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length) return;
        NSString *normalized = normalizedArtistRowText(text);
        BOOL isTitle = [normalized containsString:@"cosa ti e piaciuto"] || [normalized containsString:@"you liked"] ||
                       [normalized containsString:@"liked songs"] || [normalized containsString:@"brani che ti sono piaciuti"];
        if (isTitle) foundTitle = text;
        else if (!foundSubtitle) foundSubtitle = text;
    });
    if (title) *title = foundTitle ?: @"Cosa ti è piaciuto";
    if (subtitle) *subtitle = foundSubtitle;
}

static void restoreLikedArtistCell(UICollectionViewCell *cell, BOOL removeCard) {
    UIView *card = objc_getAssociatedObject(cell, &kLikedRowKey);
    if (!card) return;
    for (UIView *view in cell.contentView.subviews) {
        if (view == card) continue;
        NSNumber *alpha = objc_getAssociatedObject(view, &kLikedOriginalAlphaKey);
        if (alpha) view.alpha = alpha.doubleValue;
        objc_setAssociatedObject(view, &kLikedOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (removeCard && card) {
        [card removeFromSuperview];
        objc_setAssociatedObject(cell, &kLikedRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void styleLikedArtistCell(UICollectionViewCell *cell) {
    static BOOL logged;
    NSString *title = nil, *subtitle = nil;
    artistLikedRowText(cell, &title, &subtitle);
    SGRArtistLikedRow *card = objc_getAssociatedObject(cell, &kLikedRowKey);
    if (!card) {
        card = [[SGRArtistLikedRow alloc] initWithFrame:cell.contentView.bounds];
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        card.sourceCell = cell;
        objc_setAssociatedObject(cell, &kLikedRowKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell.contentView addSubview:card];
    }
    for (UIView *view in cell.contentView.subviews) {
        if (view == card) continue;
        if (!objc_getAssociatedObject(view, &kLikedOriginalAlphaKey)) {
            objc_setAssociatedObject(view, &kLikedOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.alpha = 0;
    }
    [card updateTitle:title subtitle:subtitle];
    card.frame = cell.contentView.bounds;
    if (!logged) {
        logged = YES;
        SGLog(@"redesign artist: styled the liked songs row as an Apple Music card");
    }
}

typedef NS_ENUM(NSInteger, SGRArtistCell) {
    SGRArtistCellOther,
    SGRArtistCellSpacer,
    SGRArtistCellHeading,
    SGRArtistCellVideos,
};

static SGRArtistCell kindOf(UIView *content, CGFloat height) {
    __block SGRArtistCell kind = SGRArtistCellOther;
    SGForEachView(content, ^(UIView *v) {
        NSString *identifier = v.accessibilityIdentifier;
        if (kind != SGRArtistCellOther || !identifier.length) return;
        if ([identifier isEqualToString:@"Components.UI.MusicVideoShelfHeader"] ||
            [identifier isEqualToString:@"Music-Videos.Video-Card-Carousel"] ||
            [identifier isEqualToString:@"WatchFeedCarouselEntryPointElement"]) kind = SGRArtistCellVideos;
        else if ([identifier isEqualToString:@"Components.UI.SectionHeadingHome"]) kind = SGRArtistCellHeading;
    });
    if (kind == SGRArtistCellOther && height <= 16.5 && content.subviews.count <= 1) {
        __block BOOL empty = YES;
        SGForEachView(content, ^(UIView *v) { if (v.accessibilityIdentifier.length) empty = NO; });
        if (empty) kind = SGRArtistCellSpacer;
    }
    return kind;
}

static NSMutableDictionary<NSIndexPath *, NSNumber *> *kindsOf(UICollectionView *list) {
    NSMutableDictionary *kinds = objc_getAssociatedObject(list, &kKindsKey);
    if (!kinds) {
        kinds = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(list, &kKindsKey, kinds, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return kinds;
}

static NSMutableSet<NSIndexPath *> *droppedOf(UICollectionView *list) {
    NSMutableSet *dropped = objc_getAssociatedObject(list, &kDroppedKey);
    if (!dropped) {
        dropped = [NSMutableSet set];
        objc_setAssociatedObject(list, &kDroppedKey, dropped, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return dropped;
}

static UICollectionView *listOf(UIView *cell) {
    for (UIView *v = cell.superview; v; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) return (UICollectionView *)v;
    }
    return nil;
}

static void settle(UICollectionViewCell *cell, CGFloat natural) {
    UIView *content = cell.contentView;
    objc_setAssociatedObject(cell, &kSettledKey, @(natural), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (content.autoresizingMask & UIViewAutoresizingFlexibleHeight) content.autoresizingMask &= ~UIViewAutoresizingFlexibleHeight;
    CGRect frame = CGRectMake(0, 0, cell.bounds.size.width, natural);
    if (!CGRectEqualToRect(content.frame, frame)) content.frame = frame;
    if (!content.hidden) content.hidden = YES;
    if (!cell.clipsToBounds) cell.clipsToBounds = YES;
    cell.accessibilityElementsHidden = YES;
}

static void unsettle(UICollectionViewCell *cell) {
    UIView *content = cell.contentView;
    objc_setAssociatedObject(cell, &kSettledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    content.autoresizingMask |= UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    content.frame = cell.bounds;
    content.hidden = NO;
    cell.clipsToBounds = NO;
    cell.accessibilityElementsHidden = NO;
}

static void logOnce(NSString *what) {
    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:what]) return;
    [logged addObject:what];
    SGLog(@"redesign artist: %@", what);
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    UICollectionView *list = listOf(cell);
    // Only the page's own list: a card inside a carousel is a cell of the same class, and its row decides.
    BOOL page = list && ![listOf(list) isKindOfClass:UICollectionView.class] && SGRArtistPageOf(cell) && attributes.indexPath;
    if (!page) {
        if (objc_getAssociatedObject(cell, &kSettledKey)) unsettle(cell);
        return %orig;
    }
    UICollectionViewLayoutAttributes *result = %orig;
    NSIndexPath *path = attributes.indexPath;
    UIView *content = cell.contentView.subviews.firstObject ?: cell.contentView;
    SGRArtistCell kind = kindOf(content, result.size.height);
    kindsOf(list)[path] = @(kind);

    BOOL drop = [droppedOf(list) containsObject:path];
    if (!drop) {
        if (objc_getAssociatedObject(cell, &kSettledKey)) unsettle(cell);
        return result;
    }
    settle(cell, MAX(1, result.size.height));
    result.size = CGSizeMake(result.size.width, 0);
    logOnce(@"the videos dropped from the Music list");
    return result;
}

// The cell's own passes size the content to the cell again.
- (void)layoutSubviews {
    %orig;
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    NSNumber *settled = objc_getAssociatedObject(self, &kSettledKey);
    if (settled) settle(cell, settled.doubleValue);
    UICollectionView *list = listOf(cell);
    UIView *page = list && ![listOf(list) isKindOfClass:UICollectionView.class] ? SGRArtistPageOf(cell) : nil;
    if (page) {
        // What the cell paints over the field -- the "You liked" row, every carousel's collection and the
        // fade Popular's "See more" draws over its last track (device, trees/continuous/3.txt 2026-09-18).
        SGRClearCellPaint(cell);
        if (isLikedArtistRow(cell)) styleLikedArtistCell(cell);
        else restoreLikedArtistCell(cell, YES);
        // The first of Popular's tracks with its title in is the list the page waits for (Kit/SGRReveal.h); a
        // row still loading is RetrievalRowLoadingElementUI, grey bars with empty labels.
        if (SGRRevealWaitsFor(page, SGRRevealList)) {
            UIView *track = SGRFindByIdentifier(cell, @"Components.UI.RetrievalRowElementUI*", &kTrackKey);
            if (track && SGRRevealShowsText(track)) SGRRevealMark(page, SGRRevealList);
        }
    }
}

- (void)prepareForReuse {
    %orig;
    restoreLikedArtistCell((UICollectionViewCell *)self, YES);
    if (objc_getAssociatedObject(self, &kSettledKey)) unsettle((UICollectionViewCell *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC12Element_List18CollectionViewCell"]);
}
