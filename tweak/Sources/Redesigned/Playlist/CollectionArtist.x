// The songs one has liked by an artist: Spotify's CollectionArtist page, separate from its playlist page.
// It keeps Spotify's table and row actions, with the same black field, header controls and track treatment
// as the redesigned playlist, using only identifiers and components present in Spotify 9.1.78.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Playlist.h"

static const UIEdgeInsets kBleed = {600, 0, 600, 0};
static const CGFloat kHairline = 0.5, kHairlineGap = 12;
static char kFieldKey, kTrackKey, kListRowKey, kArtworkKey, kSubtitleKey;
static char kHairlineKey, kOriginalRadiusKey;

UIView *SGRCollectionArtistPageOf(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        NSString *name = NSStringFromClass(responder.class);
        if ([name containsString:@"CollectionArtistViewController"]) {
            return ((UIViewController *)responder).viewIfLoaded;
        }
    }
    return nil;
}

UIViewController *SGRCollectionArtistHeaderOf(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        NSString *name = NSStringFromClass(responder.class);
        if ([name containsString:@"CollectionArtistViewController"]) return (UIViewController *)responder;
    }
    return nil;
}

static SGRArtworkField *fieldFor(UIView *page) {
    SGRArtworkField *field = objc_getAssociatedObject(page, &kFieldKey);
    if (!field) {
        field = [[SGRArtworkField alloc] initWithFrame:page.bounds];
        field.bleed = kBleed;
        objc_setAssociatedObject(page, &kFieldKey, field, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return field;
}

static UIView *tableFor(UIView *page) {
    __block UIView *table = nil;
    SGForEachView(page, ^(UIView *view) {
        if (!table && [view.accessibilityIdentifier isEqualToString:@"CollectionArtistView.tableView"]) table = view;
    });
    if (!table) {
        static Class tableClass;
        if (!tableClass) tableClass = NSClassFromString(@"SPTTableView");
        SGForEachView(page, ^(UIView *view) {
            if (!table && tableClass && [view isKindOfClass:tableClass]) table = view;
        });
    }
    return table;
}

static void clearSurface(UIView *view) {
    CGColorRef color = view.layer.backgroundColor;
    if (color && SGIsBaseSurface(color)) view.backgroundColor = UIColor.clearColor;
}

static UIView *identified(UIView *root, NSString *identifier, const void *key) {
    return SGRFindByIdentifier(root, identifier, key);
}

static void removeArtistStyling(UIView *cell) {
    CALayer *line = objc_getAssociatedObject(cell, &kHairlineKey);
    [line removeFromSuperlayer];
    UIView *art = identified(cell, @"Encore.ImageView", &kArtworkKey);
    NSNumber *radius = objc_getAssociatedObject(art, &kOriginalRadiusKey);
    if (art && radius) {
        art.layer.cornerRadius = radius.doubleValue;
        art.layer.cornerCurve = kCACornerCurveCircular;
        art.clipsToBounds = radius.doubleValue > 0;
    }
}

static void applyArtistRow(UIView *cell) {
    SGRClearCellPaint(cell);
    clearSurface(cell);

    UIView *track = identified(cell, @"Track.Row", &kTrackKey);
    if (!track) return;
    clearSurface(track);
    UIView *row = identified(track, @"Encore.ListRow", &kListRowKey) ?: track;
    clearSurface(row);

    UIView *art = identified(row, @"Encore.ImageView", &kArtworkKey);
    CGFloat leading = SGRSideMargin + 48 + kHairlineGap;
    if (art) {
        if (!objc_getAssociatedObject(art, &kOriginalRadiusKey)) {
            objc_setAssociatedObject(art, &kOriginalRadiusKey, @(art.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (art.layer.cornerRadius != SGRRadiusThumb) {
            art.layer.cornerRadius = SGRRadiusThumb;
            art.layer.cornerCurve = kCACornerCurveContinuous;
            art.clipsToBounds = YES;
        }
        CGRect artFrame = [row convertRect:art.bounds fromView:art];
        if (artFrame.size.width > 0) leading = CGRectGetMaxX(artFrame) + kHairlineGap;
    }

    UIView *subtitle = identified(row, @"Track.Row.Content.Subtitle", &kSubtitleKey);
    SGForEachView(subtitle, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class]) ((UILabel *)view).textColor = SGRSecondary();
    });

    CALayer *line = objc_getAssociatedObject(cell, &kHairlineKey);
    if (!line) {
        line = [CALayer layer];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        line.zPosition = 1;
        objc_setAssociatedObject(cell, &kHairlineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superlayer != row.layer) [row.layer addSublayer:line];
    CGRect bounds = row.bounds;
    CGRect frame = CGRectMake(leading, bounds.size.height - kHairline,
                              MAX(0, bounds.size.width - leading - SGRSideMargin), kHairline);
    if (!CGRectEqualToRect(line.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        line.frame = frame;
        [CATransaction commit];
    }
}

%hook _TtC27CollectionArtist_ArtistImpl30CollectionArtistViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *page = ((UIViewController *)self).viewIfLoaded;
    if (!page || page.bounds.size.height < 200) return;
    sgr_playlistRoot = page;
    SGRArtworkField *field = fieldFor(page);
    if (field.superview != page) [page insertSubview:field atIndex:0];
    else if (page.subviews.firstObject != field) [page sendSubviewToBack:field];
    if (!CGRectEqualToRect(field.frame, page.bounds)) field.frame = page.bounds;

    UIView *table = tableFor(page);
    if (table) clearSurface(table);
    SGRCollectionArtistApplyHeader(page);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIView *page = ((UIViewController *)self).viewIfLoaded;
    if (page) sgr_playlistRoot = page;
}
%end

%hook SPTTableView
- (void)layoutSubviews {
    %orig;
    UIView *table = (UIView *)self;
    if (!SGRCollectionArtistPageOf(table)) return;
    clearSurface(table);
}
%end

%hook SPTEncoreSwipeableTableViewCell
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    if (SGRCollectionArtistPageOf(cell)) applyArtistRow(cell);
    else removeArtistStyling(cell);
}

- (void)prepareForReuse {
    %orig;
    removeArtistStyling((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC27CollectionArtist_ArtistImpl30CollectionArtistViewController",
        @"SPTTableView",
        @"SPTEncoreSwipeableTableViewCell",
    ]);
}
