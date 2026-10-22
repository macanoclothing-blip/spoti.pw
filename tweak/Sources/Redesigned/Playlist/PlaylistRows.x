// Playlist redesign: the track rows on the field, the way the Music app has them -- no surface of their own,
// artwork with rounded corners, and a hairline from the text's edge between one row and the next.
//
// Tree (trees/clean/playlist/02.txt:164-247): a cell id=Playlist.ItemCell holds an Encore.ListRow painted the
// base surface, and in it Encore.ImageView 48x48 (the artwork), Track.Row.Content.Title,
// Track.Row.Content.Subtitle and, at the trailing edge, Components.UI.ContextMenuButton. The row's own paint
// is cleared here rather than left to the Kit's repaint hook, which only hears about a colour when Spotify
// sets it and not when a reused cell already carries one.
//
// Spotify's type and its spacing are left alone: the row is 64pt for a title of 18pt, and a larger font of
// the Kit's would be cut off by the box the element framework measured for it.
//
// The pills over the first row (own-playlist/01.txt:33) are a cell of the list: Add, Mix, Notes, Video,
// Edit, Sort and Name & details. The row is closed up -- ListUXPlatform_LayoutKit.ListLayout gives every
// item its height, so the cell can only close up where the layout asks it how tall it wants to be -- and
// Sort and Mix are put on the ⋯ sheet instead (PlaylistMenu.x), where the rest of the row already is. The
// cell is handed over as it lays out, so the sheet has Spotify's own buttons to fire.
//
// Not every cell of the list is a track row. Under the tracks Spotify puts the extender -- Recommended
// songs, its rows and Refresh (ListUXPlatformConsumers_PlaylistExtenderImpl) -- and its heading and its
// Refresh cell paint the base surface over the field, where the black made bands of them (device,
// trees/continuous/2.txt 2026-09-20). So the paint comes off every cell of the page, the Kit's way, and
// only the row below is a row.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Playlist.h"
#import "Shared/LocalTrackArtwork/LocalTrackArtwork.h"

// Under the text rather than the whole row, as the Music app draws it; the trailing end clears the page margin.
static const CGFloat kHairline = 0.5, kHairlineGap = 12;

static char kRowKey, kArtKey, kTitleKey, kSubtitleKey, kLineKey, kToolbarKey;
static char kLocalURIKey, kLocalRequestURIKey, kLocalImageViewKey, kLocalOriginalImageKey, kLocalAppliedImageKey, kLocalHiddenViewsKey;
static NSHashTable<UIView *> *sg_localArtworkRows;
static UIView *identified(UIView *root, NSString *identifier, const void *cacheKey);
static void applyLocalArtworkForElement(UIView *artwork);

static UIImageView *artworkImageView(UIView *artwork) {
    if ([artwork isKindOfClass:UIImageView.class]) return (UIImageView *)artwork;
    __block UIImageView *best = nil;
    __block CGFloat largest = 0;
    SGForEachView(artwork, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class] || view.hidden) return;
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (area > largest) { largest = area; best = (UIImageView *)view; }
    });
    return best;
}

static void restorePlaceholderViews(UIView *artwork) {
    NSMapTable<UIView *, NSNumber *> *hidden = objc_getAssociatedObject(artwork, &kLocalHiddenViewsKey);
    for (UIView *view in hidden.keyEnumerator.allObjects) {
        NSNumber *alpha = [hidden objectForKey:view];
        if (alpha) view.alpha = alpha.doubleValue;
    }
    [hidden removeAllObjects];
}

static void restoreLocalArtwork(UIView *artwork) {
    if (!artwork) return;
    restorePlaceholderViews(artwork);
    UIImageView *imageView = objc_getAssociatedObject(artwork, &kLocalImageViewKey);
    UIImage *original = objc_getAssociatedObject(artwork, &kLocalOriginalImageKey);
    UIImage *applied = objc_getAssociatedObject(artwork, &kLocalAppliedImageKey);
    if (imageView && imageView.image == applied) imageView.image = original == (id)NSNull.null ? nil : original;
    objc_setAssociatedObject(artwork, &kLocalURIKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(artwork, &kLocalRequestURIKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(artwork, &kLocalImageViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(artwork, &kLocalOriginalImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(artwork, &kLocalAppliedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(artwork, &kLocalHiddenViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void hidePlaceholderGlyphs(UIView *artwork, UIImageView *cover) {
    if (!artwork || !cover) return;
    NSMapTable<UIView *, NSNumber *> *hidden = objc_getAssociatedObject(artwork, &kLocalHiddenViewsKey);
    if (!hidden) {
        hidden = [NSMapTable strongToStrongObjectsMapTable];
        objc_setAssociatedObject(artwork, &kLocalHiddenViewsKey, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect bounds = artwork.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    SGForEachView(artwork, ^(UIView *view) {
        if (view == cover || ![view isKindOfClass:UIImageView.class] || view.hidden || view.alpha < 0.01) return;
        CGRect frame = [view convertRect:view.bounds toView:artwork];
        BOOL centeredGlyph = CGRectGetWidth(frame) >= 8 && CGRectGetHeight(frame) >= 8 &&
            CGRectGetWidth(frame) <= width * 0.55 && CGRectGetHeight(frame) <= height * 0.55 &&
            fabs(CGRectGetMidX(frame) - CGRectGetMidX(bounds)) <= width * 0.12 &&
            fabs(CGRectGetMidY(frame) - CGRectGetMidY(bounds)) <= height * 0.12;
        if (!centeredGlyph || [hidden objectForKey:view]) return;
        [hidden setObject:@(view.alpha) forKey:view];
        view.alpha = 0;
    });
}

static NSString *textIn(UIView *root) {
    __block NSString *text = nil;
    SGForEachView(root, ^(UIView *view) {
        if (!text && [view isKindOfClass:UILabel.class]) {
            NSString *candidate = [((UILabel *)view).text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (candidate.length) text = candidate;
        }
    });
    return text;
}

static void applyLocalArtwork(UIView *row, UIView *artwork) {
    if (!artwork) return;
    if (!sg_localArtworkRows) sg_localArtworkRows = [NSHashTable weakObjectsHashTable];
    [sg_localArtworkRows addObject:artwork];
    NSString *title = textIn(identified(row, @"Track.Row.Content.Title", &kTitleKey));
    NSString *artist = textIn(identified(row, @"Track.Row.Content.Subtitle", &kSubtitleKey));
    NSString *localURI = SGLocalArtworkURIForTitleAndArtist(title, artist);
    NSString *oldURI = objc_getAssociatedObject(artwork, &kLocalURIKey);
    if (![oldURI isEqualToString:localURI]) restoreLocalArtwork(artwork);
    if (!localURI.length) return;
    objc_setAssociatedObject(artwork, &kLocalURIKey, localURI, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIImageView *imageView = artworkImageView(artwork);
    if (!imageView) return;
    UIImage *image = SGLocalArtworkCachedCover(localURI);
    if (!image) {
        NSString *requestedURI = objc_getAssociatedObject(artwork, &kLocalRequestURIKey);
        if ([requestedURI isEqualToString:localURI]) return;
        objc_setAssociatedObject(artwork, &kLocalRequestURIKey, localURI, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SGLocalArtworkLoadCover(localURI, ^(UIImage *loaded) {
            UIView *liveArtwork = identified(row, @"Encore.ImageView", &kArtKey);
            if (![objc_getAssociatedObject(artwork, &kLocalRequestURIKey) isEqualToString:localURI]) return;
            objc_setAssociatedObject(artwork, &kLocalRequestURIKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!loaded || !row.window || liveArtwork != artwork ||
                ![objc_getAssociatedObject(artwork, &kLocalURIKey) isEqualToString:localURI]) return;
            applyLocalArtwork(row, artwork);
        });
        return;
    }
    UIImageView *previous = objc_getAssociatedObject(artwork, &kLocalImageViewKey);
    if (previous != imageView) {
        restorePlaceholderViews(artwork);
        if (previous) {
            UIImage *original = objc_getAssociatedObject(artwork, &kLocalOriginalImageKey);
            UIImage *applied = objc_getAssociatedObject(artwork, &kLocalAppliedImageKey);
            if (previous.image == applied) previous.image = original == (id)NSNull.null ? nil : original;
        }
        objc_setAssociatedObject(artwork, &kLocalImageViewKey, imageView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(artwork, &kLocalOriginalImageKey, imageView.image ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (imageView.image != image) imageView.image = image;
    objc_setAssociatedObject(artwork, &kLocalAppliedImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    hidePlaceholderGlyphs(artwork, imageView);
}

static UIView *identified(UIView *root, NSString *identifier, const void *cacheKey) {
    return SGRFindByIdentifier(root, identifier, cacheKey);
}

static void clearSurface(UIView *view) {
    UIColor *color = view.backgroundColor;
    if (color && SGIsBaseSurface(color.CGColor)) view.backgroundColor = UIColor.clearColor;
}

static void applyHairline(UIView *row, CGFloat leading) {
    CALayer *line = objc_getAssociatedObject(row, &kLineKey);
    if (!line) {
        line = [CALayer layer];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        line.zPosition = 1;
        objc_setAssociatedObject(row, &kLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superlayer != row.layer) [row.layer addSublayer:line];
    CGRect bounds = row.bounds;
    CGRect frame = CGRectMake(leading, bounds.size.height - kHairline,
                              MAX(0, bounds.size.width - leading - SGRSideMargin), kHairline);
    if (CGRectEqualToRect(line.frame, frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    line.frame = frame;
    [CATransaction commit];
}

static void applyRow(UIView *cell) {
    clearSurface(cell);
    UIView *row = identified(cell, @"Encore.ListRow", &kRowKey);
    if (!row) return;
    clearSurface(row);

    // The first track with its title in is the list the page waits for (Kit/SGRReveal.h). A row still loading
    // is Components.UI.RetrievalRowLoadingElementUI rather than Encore.ListRow, grey bars with no text in them
    // (trees/continuous/1.txt).
    UIView *page = SGRPlaylistPageOf(cell);
    if (SGRRevealWaitsFor(page, SGRRevealList) && SGRRevealShowsText(row)) SGRRevealMark(page, SGRRevealList);

    CGFloat leading = SGRSideMargin + 48 + kHairlineGap;
    UIView *art = identified(row, @"Encore.ImageView", &kArtKey);
    if (art) {
        if (art.layer.cornerRadius != SGRRadiusThumb) {
            art.layer.cornerRadius = SGRRadiusThumb;
            art.layer.cornerCurve = kCACornerCurveContinuous;
            art.clipsToBounds = YES;
        }
        CGRect frame = [row convertRect:art.bounds fromView:art];
        if (frame.size.width > 0) leading = CGRectGetMaxX(frame) + kHairlineGap;
        applyLocalArtwork(row, art);
    }

    UIView *subtitle = identified(row, @"Track.Row.Content.Subtitle", &kSubtitleKey);
    SGForEachView(subtitle, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)v;
        if (![label.textColor isEqual:SGRSecondary()]) label.textColor = SGRSecondary();
    });

    applyHairline(row, leading);
}

// The Local Files collection is not a FreeTierPlaylist cell. Spotify still renders its track cover
// through Encore.ImageView, so resolve the nearest row from that stable element rather than assuming
// every track belongs to the playlist controller above.
static void applyLocalArtworkForElement(UIView *artwork) {
    if (![artwork.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]) return;
    for (UIView *row = artwork.superview; row; row = row.superview) {
        UIView *title = identified(row, @"Track.Row.Content.Title", &kTitleKey);
        if (!textIn(title)) continue;
        if (artworkImageView(artwork)) applyLocalArtwork(row, artwork);
        // The closest ancestor with a track title owns this image. Do not walk up into a playlist
        // header or another row if Spotify omits the artist label for a local file.
        return;
    }
}

%hook UIView
- (void)layoutSubviews {
    %orig;
    applyLocalArtworkForElement((UIView *)self);
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    UIView *artwork = nil;
    for (UIView *view = self; view; view = view.superview) {
        if ([view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]) { artwork = view; break; }
    }
    if (!artwork) return;
    __weak UIView *weakArtwork = artwork;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *current = weakArtwork;
        if (current.window) applyLocalArtworkForElement(current);
    });
}
%end

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    if (!SGRPlaylistHeaderOf(cell)) return;
    SGRClearCellPaint(cell);
    SGRPlaylistTakeCuration(cell);
    applyRow(cell);
}

- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    if (!SGRFindByIdentifier((UIView *)self, SGRPlaylistCurationIdentifier, &kToolbarKey)) return result;
    result.size = CGSizeMake(result.size.width, 0);
    ((UIView *)self).clipsToBounds = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign playlist: curation pills asked for a height, answered 0"); });
    return result;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (!sg_localArtworkRows) sg_localArtworkRows = [NSHashTable weakObjectsHashTable];
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalArtworkDidChangeNotification object:nil
                                                      queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        for (UIView *artwork in sg_localArtworkRows.allObjects) if (artwork.window) applyLocalArtworkForElement(artwork);
    }];
    SGRequireClasses(@[@"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell"]);
}
