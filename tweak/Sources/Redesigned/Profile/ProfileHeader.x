// The personal profile keeps Spotify's existing actions and playlist list. Its header uses the
// artist-page treatment: square artwork, compact centered details, and a fade into the playlist list.
//
// Layout facts (from the view dump):
//  - ProfileHeaderViewController's view is a 390x283 overlay that sits ABOVE the playlists collection view
//    (it is not a cell of it); the collection reserves 283pt with its contentInset.
//  - Spotify draws an opaque gradient/blur over the header, and the avatar is a 64x64 EncoreImageView;
//    a hidden 300x300 placeholder icon also exists in the same subtree.
//
// This file never touches the collection's contentInset/contentOffset (Spotify owns them).
// It adds a non-interactive backdrop, permanently hides the round avatar, the duplicated labels and
// Spotify's own backdrop views (via a setAlpha: hook, because Spotify resets alpha on every layout/scroll),
// and shifts the playlist cells down with a transform measured from their real on-screen position.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kProfileHeroKey, kProfileArtworkKey, kProfileTitleKey, kProfileMetadataKey;
static char kProfileHeaderRefKey, kProfileActionRowRefKey, kProfileActionBarKey;
static char kProfileFollowingButtonKey, kProfileFollowersButtonKey;
static char kProfileExtensionKey, kProfileCellTransformKey;
static char kProfileKillKey, kProfileCollectionHeaderKey, kProfileCanvasKey;
static char kProfileScrollBaselineKey, kProfileCanvasTransformKey;
static char kProfileRefreshGenerationKey;

// Fixed point sizes (independent from Dynamic Type) so the header matches the artist page.
static const CGFloat kProfileTitleSize = 22;
static const CGFloat kProfileMetadataSize = 12;
static const CGFloat kProfileHeadingMaxSize = 20;
// Extra space (points) between the bottom of the square header and the "Le tue playlist" section.
static const CGFloat kProfilePlaylistsDrop = 0;
static const CGFloat kProfileActionSide = 48, kProfileActionSpacing = 8, kProfileEditWidth = 128;

@interface SGRProfileWeakBox : NSObject
@property (nonatomic, weak) UIView *view;
@end

@implementation SGRProfileWeakBox
@end

@interface SGRProfileHero : UIView
- (void)followArtwork:(UIImageView *)source;
@end

@implementation SGRProfileHero {
    UIImageView *_picture;
    CAGradientLayer *_scrim, *_bottomScrim;
    CAGradientLayer *_dissolve;
    __weak UIImageView *_source;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;

    _picture = [UIImageView new];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    _picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_picture];

    // Soft darkening at the top so the back button stays readable.
    _scrim = [CAGradientLayer layer];
    _scrim.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.42].CGColor,
                       (id)[UIColor colorWithWhite:0 alpha:0.0].CGColor];
    _scrim.locations = @[@0, @1];
    [self.layer addSublayer:_scrim];

    // Darkening behind the name, the statistics and the action row.
    _bottomScrim = [CAGradientLayer layer];
    _bottomScrim.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                            (id)[UIColor colorWithWhite:0 alpha:0.70].CGColor];
    _bottomScrim.locations = @[@0, @1];
    [self.layer addSublayer:_bottomScrim];

    // The image dissolves into the black page background, like on artist pages.
    _dissolve = [CAGradientLayer layer];
    _dissolve.colors = @[(id)UIColor.whiteColor.CGColor,
                         (id)UIColor.whiteColor.CGColor,
                         (id)UIColor.clearColor.CGColor];
    _dissolve.locations = @[@0, @0.78, @1];
    _dissolve.startPoint = CGPointMake(0.5, 0);
    _dissolve.endPoint = CGPointMake(0.5, 1);
    self.layer.mask = _dissolve;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _picture.frame = self.bounds;
    _scrim.frame = CGRectMake(0, 0, self.bounds.size.width, MIN(150, self.bounds.size.height));
    CGFloat bottomHeight = MIN(230, self.bounds.size.height);
    _bottomScrim.frame = CGRectMake(0, self.bounds.size.height - bottomHeight,
                                    self.bounds.size.width, bottomHeight);
    _dissolve.frame = self.bounds;
}

- (void)followArtwork:(UIImageView *)source {
    if (!source || source == _source) {
        if (source.image && _picture.image != source.image) _picture.image = source.image;
        return;
    }
    _source = source;
    _picture.image = source.image;
    __weak SGRProfileHero *weakSelf = self;
    SGRObserveImage(source, ^(UIImageView *updated) {
        SGRProfileHero *hero = weakSelf;
        if (hero && hero->_source == updated && updated.image) hero->_picture.image = updated.image;
    });
}

- (void)setArtwork:(UIImage *)image {
    if (image && _picture.image != image) _picture.image = image;
}

@end

@interface SGRProfileStatButton : UIControl
@property (nonatomic, weak) UIView *source;
- (void)setTitle:(NSString *)title;
@end

@implementation SGRProfileStatButton {
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _label = [UILabel new];
    _label.font = [SGRFont(UIFontTextStyleFootnote, UIFontWeightSemibold, UIContentSizeCategoryLarge)
                   fontWithSize:kProfileMetadataSize];
    _label.textColor = SGRSecondary();
    _label.userInteractionEnabled = NO;
    [self addSubview:_label];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(activateSource) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)setTitle:(NSString *)title {
    _label.text = title;
    self.accessibilityLabel = title;
    [_label sizeToFit];
    CGFloat width = ceil(_label.bounds.size.width);
    self.bounds = CGRectMake(0, 0, MAX(44, width), 44);
    _label.frame = CGRectMake(round((self.bounds.size.width - width) / 2),
                              round((self.bounds.size.height - _label.bounds.size.height) / 2),
                              width, _label.bounds.size.height);
}

- (void)activateSource {
    UIView *source = self.source;
    for (UIView *view = source; view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) {
            SGRActivate(view);
            return;
        }
        if ([view accessibilityActivate]) return;
    }
}
@end

static NSString *profileControlLabel(UIView *control) {
    if (control.accessibilityLabel.length) return control.accessibilityLabel;
    __block NSString *text = nil;
    SGForEachView(control, ^(UIView *view) {
        if (!text.length && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length)
            text = ((UILabel *)view).text;
    });
    return text;
}

static BOOL profileFollowState(UIView *control, BOOL *following) {
    NSString *label = profileControlLabel(control);
    if (!label.length) return NO;
    NSString *normalized = [[label stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                       locale:NSLocale.currentLocale] lowercaseString];
    for (NSString *value in @[@"segui gia", @"following", @"unfollow", @"stai seguendo",
                              @"abonne", @"abbonat", @"folgst", @"siguiendo", @"seguindo"]) {
        if ([normalized containsString:value]) {
            if (following) *following = YES;
            return YES;
        }
    }
    for (NSString *value in @[@"segui", @"follow", @"suivre", @"folgen", @"seguir"]) {
        if ([normalized containsString:value]) {
            if (following) *following = NO;
            return YES;
        }
    }
    return NO;
}

@interface SGRProfileActionBar : UIView
@property (nonatomic, strong) SGRPlayCapsule *edit;
@property (nonatomic, strong) SGRMirrorButton *share;
@property (nonatomic, strong) SGRMirrorButton *privacy;
@property (nonatomic, strong) SGRMirrorButton *more;
- (void)feedEdit:(UIView *)edit message:(UIView *)message follow:(UIView *)follow
           share:(UIView *)share privacy:(UIView *)privacy more:(UIView *)more;
@end

@implementation SGRProfileActionBar
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.accessibilityElementsHidden = NO;

    _edit = [[SGRPlayCapsule alloc] initWithFrame:CGRectZero];
    _edit.fillColor = UIColor.whiteColor;
    _edit.contentColor = UIColor.blackColor;
    _edit.fallbackGlyph = [UIImage systemImageNamed:@"pencil"];
    [self addSubview:_edit];

    _share = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
    _share.glyphColor = SGRPrimary();
    [self addSubview:_share];

    _privacy = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
    _privacy.glyphColor = SGRPrimary();
    [self addSubview:_privacy];

    _more = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
    _more.glyphColor = SGRPrimary();
    _more.fallbackGlyph = [UIImage systemImageNamed:@"ellipsis"];
    [self addSubview:_more];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = kProfileActionSide;
    CGFloat editWidth = MAX(0, MIN(kProfileEditWidth,
                                   self.bounds.size.width - 2 * side - 2 * kProfileActionSpacing));
    _share.frame = CGRectMake(0, 0, side, side);
    _edit.frame = CGRectMake(round((self.bounds.size.width - editWidth) / 2), 0, editWidth, side);
    _privacy.frame = CGRectMake(self.bounds.size.width - 2 * side - kProfileActionSpacing, 0, side, side);
    _more.frame = CGRectMake(self.bounds.size.width - side, 0, side, side);
}

- (void)feedEdit:(UIView *)edit message:(UIView *)message follow:(UIView *)follow
           share:(UIView *)share privacy:(UIView *)privacy more:(UIView *)more {
    UIView *primary = message ?: edit;
    _edit.titleOverride = message ? @"Messaggio" : nil;
    _edit.fallbackGlyph = message ? nil : [UIImage systemImageNamed:@"pencil"];
    if (primary) [_edit feedFrom:primary];
    if (share) [_share feedFrom:share];
    if (follow) {
        __weak UIView *weakFollow = follow;
        _privacy.readState = ^BOOL(BOOL *on) {
            UIView *source = weakFollow;
            return source && profileFollowState(source, on);
        };
        _privacy.stateOffSymbol = @"person.badge.plus";
        _privacy.stateOnSymbol = @"person.fill.checkmark";
        _privacy.onGlyphColor = SGRAccent();
        [_privacy feedFrom:follow];
    } else {
        _privacy.readState = nil;
        _privacy.stateOffSymbol = nil;
        _privacy.stateOnSymbol = nil;
        _privacy.onGlyphColor = nil;
        if (privacy) [_privacy feedFrom:privacy];
    }
    if (more) [_more feedFrom:more];
    _edit.hidden = primary == nil;
    _share.hidden = share == nil;
    _privacy.hidden = follow == nil && privacy == nil;
    _more.hidden = more == nil;
}
@end

static NSString *profileText(UIView *root, NSString *identifier) {
    UIView *label = SGRFindByIdentifier(root, identifier, NULL);
    __block NSString *text = nil;
    SGForEachView(label, ^(UIView *view) {
        if (!text.length && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length)
            text = ((UILabel *)view).text;
    });
    return text;
}

static NSString *profileCount(NSString *label) {
    NSString *trimmed = [label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange separator = [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return separator.location == NSNotFound ? trimmed : [trimmed substringToIndex:separator.location];
}

static void profileTranslate(UIView *view, const void *key, CGFloat y) {
    if (!view) return;
    NSValue *stored = objc_getAssociatedObject(view, key);
    CGAffineTransform base = stored ? stored.CGAffineTransformValue : view.transform;
    if (!stored) {
        objc_setAssociatedObject(view, key, [NSValue valueWithCGAffineTransform:base],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform moved = CGAffineTransformTranslate(base, 0, y);
    if (!CGAffineTransformEqualToTransform(view.transform, moved)) view.transform = moved;
}

// Marks a view as "must stay invisible". The UIView -setAlpha: hook below forces 0 afterwards, so
// Spotify cannot bring it back when it re-lays out or scrolls.
static void profileKill(UIView *view) {
    if (!view) return;
    if (!objc_getAssociatedObject(view, &kProfileKillKey))
        objc_setAssociatedObject(view, &kProfileKillKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (view.alpha != 0) view.alpha = 0;
}

// True unless the view (or one of its ancestors below `stop`) is hidden. Alpha is ignored on purpose:
// we set alpha 0 on the avatar container ourselves and must still be able to read its image.
static BOOL profileDisplayed(UIView *view, UIView *stop) {
    for (UIView *current = view; current && current != stop; current = current.superview)
        if (current.hidden) return NO;
    return YES;
}

// Artwork = the largest VISIBLE image in the header, ignoring our own overlay. Spotify keeps a hidden
// 300x300 placeholder icon in the same subtree that would otherwise win over the real 64x64 avatar.
static UIImageView *profileArtwork(UIView *root, UIView *exclude) {
    __block UIImageView *best = nil, *empty = nil;
    __block uint64_t bestPixels = 0;
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class]) return;
        if (exclude && [view isDescendantOfView:exclude]) return;
        if (!profileDisplayed(view, root)) return;
        UIImageView *image = (UIImageView *)view;
        if (image.bounds.size.width < 40 || image.bounds.size.height < 40) return;
        CGImageRef bitmap = image.image.CGImage;
        uint64_t pixels = bitmap ? (uint64_t)CGImageGetWidth(bitmap) * CGImageGetHeight(bitmap) : 0;
        if (image.image && pixels > bestPixels) {
            bestPixels = pixels;
            best = image;
        }
        else if (!image.image) empty = image;
    });
    return best ?: empty;
}

static BOOL profileHoldsHeaderContent(UIView *view) {
    return SGRFindByIdentifier(view, @"Components.UI.EditButton", NULL) != nil ||
           SGRFindByIdentifier(view, @"Components.UI.MessageButton", NULL) != nil ||
           SGRFindByIdentifier(view, @"Components.UI.FollowButton", NULL) != nil ||
           SGRFindByIdentifier(view, @"Components.UI.ShareButton", NULL) != nil ||
           SGRFindByIdentifier(view, @"Components.UI.TitleLabel", NULL) != nil ||
           SGRFindByIdentifier(view, @"Components.UI.FollowersButton", NULL) != nil ||
           SGRFindByIdentifier(view, @"Components.UI.FollowingButton", NULL) != nil;
}

// Hides the whole container of the round avatar: the highest ancestor that does not also hold
// the title, the statistics or the action buttons.
static void profileHideAvatar(UIView *header, UIView *artwork) {
    if (!artwork) return;
    UIView *wrapper = artwork;
    while (wrapper.superview && wrapper.superview != header && !profileHoldsHeaderContent(wrapper.superview))
        wrapper = wrapper.superview;
    if (wrapper != header) profileKill(wrapper);
}

// Moves Spotify's action row (Modifica / share / settings / more) onto the dark fade at the bottom of the
// square, under the name. Returns the row so touches can be routed to it (it ends up outside its parents' bounds).
static BOOL profileLooksLikeBackdrop(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) return YES;
    if ([view.accessibilityIdentifier isEqualToString:@"_backgroundViewContainer"]) return YES;
    NSString *name = NSStringFromClass(view.class);
    for (NSString *token in @[@"Background", @"Gradient", @"Blur", @"Backdrop", @"Scrim"])
        if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

// Hides everything of Spotify's header that is not ours: backdrop/blur/gradient views, stray dots,
// the original name/statistics and the round avatar. Safe to call as often as needed.
static void profileEnforce(UIView *root, UIView *canvas, UIView *row) {
    UIView *hero = objc_getAssociatedObject(canvas, &kProfileHeroKey);
    UIView *title = objc_getAssociatedObject(canvas, &kProfileTitleKey);
    UIView *metadata = objc_getAssociatedObject(canvas, &kProfileMetadataKey);

    profileKill(SGRFindByIdentifier(root, @"_backgroundViewContainer", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.TitleLabel", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.FollowersButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.FollowingButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.EditButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.MessageButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.FollowButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.StateButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.ShareButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.SettingsButton", NULL));
    profileKill(SGRFindByIdentifier(root, @"Components.UI.ContextMenuButton", NULL));

    SGForEachView(root, ^(UIView *view) {
        if (view == root || view == canvas || view == hero || view == title || view == metadata) return;
        if (hero && [view isDescendantOfView:hero]) return;
        if (title && [view isDescendantOfView:title]) return;
        if (metadata && [view isDescendantOfView:metadata]) return;
        if (row && ([view isDescendantOfView:row] || [row isDescendantOfView:view])) return;
        if (profileHoldsHeaderContent(view)) return;

        CGSize size = view.bounds.size;
        BOOL dot = size.width > 0 && size.width <= 12 && size.height <= 12 &&
                   ![view isKindOfClass:UIControl.class] && ![view isKindOfClass:UILabel.class];
        NSString *className = NSStringFromClass(view.class);
        BOOL loader = [view isKindOfClass:UIActivityIndicatorView.class] ||
                      [className rangeOfString:@"Spinner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [className rangeOfString:@"ActivityIndicator" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [className rangeOfString:@"ProgressIndicator" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (loader && [view respondsToSelector:@selector(stopAnimating)])
            [(UIActivityIndicatorView *)view stopAnimating];
        if (profileLooksLikeBackdrop(view) || dot || loader) {
            profileKill(view);
            for (CALayer *layer in view.layer.sublayers)
                if ([layer isKindOfClass:CAGradientLayer.class] && !layer.hidden) layer.hidden = YES;
        }
    });
}

static UIView *profileHeaderText(UIView *root, UIView *canvas, UIView *hero, UIImageView *artwork) {
    UILabel *title = objc_getAssociatedObject(canvas, &kProfileTitleKey);
    if (!title) {
        title = [UILabel new];
        title.textColor = SGRPrimary();
        title.font = [SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryLarge)
                      fontWithSize:kProfileTitleSize];
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.65;
        title.textAlignment = NSTextAlignmentCenter;
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(canvas, &kProfileTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (title.superview != canvas) [canvas addSubview:title];

    NSString *name = profileText(root, @"Components.UI.TitleLabel");
    if (name.length && ![title.text isEqualToString:name]) title.text = name;
    NSString *followers = profileCount(profileText(root, @"Components.UI.FollowersButton") ?: @"");
    NSString *following = profileCount(profileText(root, @"Components.UI.FollowingButton") ?: @"");
    SGRProfileStatButton *followingButton = objc_getAssociatedObject(canvas, &kProfileFollowingButtonKey);
    if (!followingButton) {
        followingButton = [[SGRProfileStatButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(canvas, &kProfileFollowingButtonKey, followingButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [canvas addSubview:followingButton];
    }
    SGRProfileStatButton *followersButton = objc_getAssociatedObject(canvas, &kProfileFollowersButtonKey);
    if (!followersButton) {
        followersButton = [[SGRProfileStatButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(canvas, &kProfileFollowersButtonKey, followersButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [canvas addSubview:followersButton];
    }
    UIView *followingSource = SGRFindByIdentifier(root, @"Components.UI.FollowingButton", NULL);
    UIView *followersSource = SGRFindByIdentifier(root, @"Components.UI.FollowersButton", NULL);
    followingButton.source = followingSource;
    followersButton.source = followersSource;
    [followingButton setTitle:following.length ? [NSString stringWithFormat:@"%@ persone che segui", following] : @""];
    [followersButton setTitle:followers.length ? [NSString stringWithFormat:@"%@ follower", followers] : @""];
    followingButton.hidden = !following.length;
    followersButton.hidden = !followers.length;

    UILabel *metadata = objc_getAssociatedObject(canvas, &kProfileMetadataKey);
    if (!metadata) {
        metadata = [UILabel new];
        metadata.textColor = SGRSecondary();
        metadata.font = [SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryLarge)
                         fontWithSize:kProfileMetadataSize];
        metadata.textAlignment = NSTextAlignmentCenter;
        metadata.userInteractionEnabled = NO;
        objc_setAssociatedObject(canvas, &kProfileMetadataKey, metadata, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [canvas addSubview:metadata];
    }
    metadata.text = following.length && followers.length ? @"·" : nil;
    [metadata sizeToFit];

    CGFloat width = CGRectGetWidth(canvas.bounds);
    CGFloat height = CGRectGetHeight(hero.bounds);
    title.frame = CGRectMake(20, MAX(0, height - 136), MAX(0, width - 40), 28);
    title.hidden = !name.length;
    CGFloat followingWidth = following.length ? followingButton.bounds.size.width : 0;
    CGFloat followersWidth = followers.length ? followersButton.bounds.size.width : 0;
    CGFloat separatorWidth = following.length && followers.length ? MAX(18, metadata.bounds.size.width + 12) : 0;
    CGFloat statsWidth = followingWidth + followersWidth + separatorWidth;
    CGFloat statsX = round((width - statsWidth) / 2);
    CGFloat statsY = MAX(0, height - 104);
    followingButton.frame = CGRectMake(statsX, statsY, followingWidth, 44);
    metadata.frame = CGRectMake(CGRectGetMaxX(followingButton.frame), statsY,
                                separatorWidth, 44);
    followersButton.frame = CGRectMake(CGRectGetMaxX(metadata.frame), statsY, followersWidth, 44);
    metadata.hidden = separatorWidth == 0;
    [canvas bringSubviewToFront:title];
    [canvas bringSubviewToFront:followingButton];
    [canvas bringSubviewToFront:metadata];
    [canvas bringSubviewToFront:followersButton];

    profileHideAvatar(root, artwork);

    SGRProfileActionBar *bar = objc_getAssociatedObject(canvas, &kProfileActionBarKey);
    if (!bar) {
        bar = [[SGRProfileActionBar alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(canvas, &kProfileActionBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [canvas addSubview:bar];
    }
    UIView *edit = SGRFindByIdentifier(root, @"Components.UI.EditButton", NULL);
    UIView *message = SGRFindByIdentifier(root, @"Components.UI.MessageButton", NULL);
    if (!profileDisplayed(message, root)) message = nil;
    UIView *follow = SGRFindByIdentifier(root, @"Components.UI.FollowButton", NULL);
    if (!profileDisplayed(follow, root)) follow = nil;
    UIView *share = SGRFindByIdentifier(root, @"Components.UI.ShareButton", NULL);
    UIView *privacy = SGRFindByIdentifier(root, @"Components.UI.SettingsButton", NULL);
    UIView *more = SGRFindByIdentifier(root, @"Components.UI.ContextMenuButton", NULL);
    [bar feedEdit:(message ? nil : edit) message:message follow:follow
            share:share privacy:(message ? nil : privacy) more:more];
    CGFloat barWidth = MAX(0, CGRectGetWidth(canvas.bounds) - 32);
    CGFloat barHeight = kProfileActionSide;
    bar.frame = CGRectMake(round((CGRectGetWidth(canvas.bounds) - barWidth) / 2),
                           MAX(0, height - 54), barWidth, barHeight);
    if (!bar.superview) [canvas addSubview:bar];
    if (bar.superview == canvas) [canvas bringSubviewToFront:bar];

    profileEnforce(root, canvas, bar);
    return bar;
}

static void profilePlaylistHeading(UIView *root) {
    UIView *table = SGRFindByIdentifier(root, @"ProfilePublicPlaylistsElementUI.playlistsTableView", NULL);
    if (!table && [root.accessibilityIdentifier isEqualToString:@"ProfilePublicPlaylistsElementUI.playlistsTableView"])
        table = root;
    profileKill(SGRFindByIdentifier(table, @"Section.Heading.Content.AccessoryItem", NULL));
    UIView *heading = SGRFindByIdentifier(table, @"Section.Heading.Content.Title", NULL);
    SGForEachView(heading, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        if ([label.text isEqualToString:@"Playlist"]) label.text = @"Le tue playlist";
        if (label.font.pointSize > kProfileHeadingMaxSize)
            label.font = [label.font fontWithSize:kProfileHeadingMaxSize];
    });
}

static BOOL profileIsPlaylistManageAction(UIView *view) {
    if (![view.accessibilityIdentifier isEqualToString:@"Section.Heading.Content.AccessoryItem"]) return NO;
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview)
        if ([ancestor.accessibilityIdentifier isEqualToString:@"ProfilePublicPlaylistsElementUI.playlistsTableView"])
            return YES;
    return NO;
}

// How far the playlist cells must move down so the first one starts right below the square (+ drop).
//
// On entry Spotify's list rests at -contentInset.top, while after a pull-and-release UIKit settles it at
// -adjustedContentInset.top (they differ by the safe area), so the cells used to sit at different heights in
// the two states. Here the shift follows the real offset inside that "rest zone": the first cell always lands
// on the same spot, on entry and after a swipe. Outside the zone the offset is clamped, so the shift stays
// constant and the cells scroll / rubber-band naturally. Only the layout position of the first cell (center,
// unaffected by our transform) and the collection's frame are used, so it cannot feed back into the layout.
static CGFloat profileExtension(UICollectionView *collection, UIView *header) {
    NSNumber *previous = objc_getAssociatedObject(collection, &kProfileExtensionKey);
    UIView *parent = collection.superview;
    if (!parent) return previous.doubleValue;

    CGFloat topY = CGFLOAT_MAX, anyTopY = CGFLOAT_MAX;
    for (UICollectionViewCell *cell in collection.visibleCells) {
        CGFloat y = cell.center.y - cell.bounds.size.height / 2;
        if (y < anyTopY) anyTopY = y;
        NSIndexPath *path = [collection indexPathForCell:cell];
        if (path && path.section == 0 && path.item == 0) topY = y;
    }
    if (topY == CGFLOAT_MAX) {
        if (previous) return previous.doubleValue;   // first cell scrolled out / not loaded yet
        topY = anyTopY;
    }
    if (topY == CGFLOAT_MAX) return 0;

    CGFloat insetTop = collection.contentInset.top;
    CGFloat adjustedTop = collection.adjustedContentInset.top;
    CGFloat low = MIN(-insetTop, -adjustedTop), high = MAX(-insetTop, -adjustedTop);
    CGFloat offset = MIN(MAX(collection.contentOffset.y, low), high);

    CGFloat collectionTop = [parent convertPoint:collection.frame.origin toView:header].y;
    CGFloat naturalTop = collectionTop + topY - offset;   // where the first cell sits on screen, without our shift
    CGFloat desiredTop = CGRectGetHeight(header.bounds) + 4 + kProfilePlaylistsDrop;
    return MAX(0, desiredTop - naturalTop);
}

static void profileApplyCells(UICollectionView *collection) {
    NSNumber *extension = objc_getAssociatedObject(collection, &kProfileExtensionKey);
    if (!extension) return;
    for (UICollectionViewCell *cell in collection.visibleCells)
        profileTranslate(cell, &kProfileCellTransformKey, extension.doubleValue);
}

static UIView *profileCanvas(UIView *root) {
    UIView *layout = SGRFindByIdentifier(root, @"Components.UI.ProfileHeader", NULL);
    return layout.superview;
}

static UIView *profileViewForView(UIView *view) {
    for (UIView *current = view; current; current = current.superview)
        if ([NSStringFromClass(current.class) containsString:@"ProfileView"]) return current;
    return nil;
}

static void profilePinActionBar(UIView *root, UIView *header) {
    UIView *canvas = profileCanvas(header);
    SGRProfileHero *hero = objc_getAssociatedObject(canvas, &kProfileHeroKey);
    SGRProfileActionBar *bar = objc_getAssociatedObject(canvas, &kProfileActionBarKey);
    if (!hero || !bar || !root.window) return;

    if (bar.superview != root) [root addSubview:bar];
    root.clipsToBounds = NO;
    CGRect heroFrame = [hero convertRect:hero.bounds toView:root];
    CGFloat naturalY = CGRectGetMaxY(heroFrame) - 62;
    CGFloat pinnedY = root.safeAreaInsets.top + 130;
    CGFloat y = MAX(naturalY, pinnedY);
    CGFloat width = MAX(0, CGRectGetWidth(root.bounds) - 32);
    bar.frame = CGRectMake(16, y, width, kProfileActionSide);
    [root bringSubviewToFront:bar];
}

static UIView *profileApplyHeader(UIView *root) {
    UIView *layout = SGRFindByIdentifier(root, @"Components.UI.ProfileHeader", NULL);
    if (!layout || !layout.superview) return nil;
    UIView *canvas = layout.superview;
    if (canvas.bounds.size.width < 120 || canvas.bounds.size.height < 100) return nil;

    SGRProfileHero *hero = objc_getAssociatedObject(canvas, &kProfileHeroKey);
    canvas.clipsToBounds = NO;
    CGRect heroFrame = CGRectMake(0, 0, CGRectGetWidth(canvas.bounds), CGRectGetWidth(canvas.bounds));
    if (!hero) {
        hero = [[SGRProfileHero alloc] initWithFrame:heroFrame];
        objc_setAssociatedObject(canvas, &kProfileHeroKey, hero, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hero.superview != canvas) [canvas insertSubview:hero atIndex:0];
    else if (canvas.subviews.firstObject != hero) [canvas sendSubviewToBack:hero];
    if (!CGRectEqualToRect(hero.frame, heroFrame)) hero.frame = heroFrame;

    UIImageView *artwork = profileArtwork(root, hero);
    [hero followArtwork:artwork];
    UIView *bar = profileHeaderText(root, canvas, hero, artwork);
    return bar;
}

static UICollectionView *profilePlaylistCollection(UIView *root, UIView *header) {
    __block UICollectionView *collection = nil;
    __block CGFloat largestArea = 0;
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UICollectionView.class] || [view isDescendantOfView:header]) return;
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (area > largestArea) {
            collection = (UICollectionView *)view;
            largestArea = area;
        }
    });
    return collection;
}

static void profileApplyToView(UIView *root) {
    SGRProfileWeakBox *headerBox = objc_getAssociatedObject(root, &kProfileHeaderRefKey);
    UIView *header = headerBox.view;
    if (!header || !SGRFindByIdentifier(header, @"Components.UI.ProfileHeader", NULL)) return;
    profilePlaylistHeading(root);

    UIView *row = profileApplyHeader(header);
    UIView *canvas = profileCanvas(header);
    if (!canvas) return;
    SGRProfileHero *hero = objc_getAssociatedObject(canvas, &kProfileHeroKey);
    SGRProfileWeakBox *rowBox = [SGRProfileWeakBox new];
    rowBox.view = row;
    objc_setAssociatedObject(root, &kProfileActionRowRefKey, rowBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    profilePinActionBar(root, header);

    UICollectionView *collection = profilePlaylistCollection(root, canvas);
    if (!collection) return;

    SGRProfileWeakBox *collectionHeader = [SGRProfileWeakBox new];
    collectionHeader.view = hero;
    objc_setAssociatedObject(collection, &kProfileCollectionHeaderKey, collectionHeader,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRProfileWeakBox *canvasBox = [SGRProfileWeakBox new];
    canvasBox.view = canvas;
    objc_setAssociatedObject(collection, &kProfileCanvasKey, canvasBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(collection, &kProfileScrollBaselineKey))
        objc_setAssociatedObject(collection, &kProfileScrollBaselineKey,
                                 @(collection.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [collection layoutIfNeeded];
    objc_setAssociatedObject(collection, &kProfileExtensionKey,
                             @(profileExtension(collection, hero ?: canvas)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    profileApplyCells(collection);
}

static void profileScheduleInitialLayout(UIView *root) {
    if (!root.window) return;
    NSUInteger generation = [objc_getAssociatedObject(root, &kProfileRefreshGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(root, &kProfileRefreshGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakRoot = root;
    for (NSNumber *delay in @[@0.0, @0.08, @0.2, @0.45, @0.9]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *strongRoot = weakRoot;
            if (!strongRoot.window ||
                [objc_getAssociatedObject(strongRoot, &kProfileRefreshGenerationKey) unsignedIntegerValue] != generation)
                return;
            [strongRoot setNeedsLayout];
            [strongRoot layoutIfNeeded];
            profileApplyToView(strongRoot);
        });
    }
}

%hook _TtC18Profile_CommonImpl27ProfileHeaderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *header = ((UIViewController *)self).viewIfLoaded;
    if (!header || header.bounds.size.width < 120 || header.bounds.size.height < 100) return;

    UIView *profileView = header;
    while (profileView && ![NSStringFromClass(profileView.class) containsString:@"ProfileView"])
        profileView = profileView.superview;
    for (UIView *view = header; view; view = view.superview) {
        view.clipsToBounds = NO;
        if (view == profileView) break;
    }

    UIView *row = profileApplyHeader(header);
    UIView *canvas = profileCanvas(header);
    UIImageView *artwork = profileArtwork(header, objc_getAssociatedObject(canvas, &kProfileHeroKey));

    if (profileView) {
        BOOL first = !objc_getAssociatedObject(profileView, &kProfileHeaderRefKey);
        SGRProfileWeakBox *headerBox = [SGRProfileWeakBox new];
        headerBox.view = header;
        objc_setAssociatedObject(profileView, &kProfileHeaderRefKey, headerBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRProfileWeakBox *rowBox = [SGRProfileWeakBox new];
        rowBox.view = row;
        objc_setAssociatedObject(profileView, &kProfileActionRowRefKey, rowBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        profilePinActionBar(profileView, header);
        if (first) profileScheduleInitialLayout(profileView);
    }

    if (artwork && !objc_getAssociatedObject(header, &kProfileArtworkKey)) {
        objc_setAssociatedObject(header, &kProfileArtworkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign profile: artist-style header installed; artwork=%.0fx%.0f image=%@ profileView=%@ actions=%@",
              artwork.bounds.size.width, artwork.bounds.size.height,
              artwork.image ? @"yes" : @"no", profileView ? @"found" : @"missing", row ? @"found" : @"missing");
    }
}
%end

%hook _TtC18Profile_CommonImpl11ProfileView
- (void)layoutSubviews {
    %orig;
    UIView *root = (UIView *)self;
    profileApplyToView(root);
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) profileScheduleInitialLayout((UIView *)self);
}

// The action row is drawn outside the bounds of the views that contain it, so UIKit would not deliver
// touches to it. Route them here.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *root = (UIView *)self;
    UIView *row = ((SGRProfileWeakBox *)objc_getAssociatedObject(root, &kProfileActionRowRefKey)).view;
    if (row && row.window && !row.hidden && row.alpha > 0.01) {
        CGRect frame = [row convertRect:row.bounds toView:root];
        if (CGRectContainsPoint(frame, point)) {
            UIView *hit = [row hitTest:[row convertPoint:point fromView:root] withEvent:event];
            if (hit) return hit;
        }
    }
    return %orig;
}
%end

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    // Cells are recycled while scrolling; keep them below the square header (transform only, no layout).
    UICollectionView *collection = (UICollectionView *)self;
    UIView *header = ((SGRProfileWeakBox *)objc_getAssociatedObject(self, &kProfileCollectionHeaderKey)).view;
    if (header && header.window) {
        UIView *canvas = ((SGRProfileWeakBox *)objc_getAssociatedObject(self, &kProfileCanvasKey)).view;
        NSNumber *baseline = objc_getAssociatedObject(self, &kProfileScrollBaselineKey);
        if (canvas && baseline) {
            CGFloat scrollDelta = collection.contentOffset.y - baseline.doubleValue;
            profileTranslate(canvas, &kProfileCanvasTransformKey, -scrollDelta);
        }
        NSNumber *previous = objc_getAssociatedObject(self, &kProfileExtensionKey);
        CGFloat extension = profileExtension(collection, header);
        if (!previous || fabs(previous.doubleValue - extension) > 0.5)
            objc_setAssociatedObject(self, &kProfileExtensionKey, @(extension), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        profilePlaylistHeading(collection);
        UIView *profileView = profileViewForView(collection);
        UIView *profileHeader = ((SGRProfileWeakBox *)objc_getAssociatedObject(profileView, &kProfileHeaderRefKey)).view;
        if (profileView && profileHeader) profilePinActionBar(profileView, profileHeader);
    }
    if (objc_getAssociatedObject(self, &kProfileExtensionKey)) profileApplyCells(collection);
}
%end

%hook UITableView
- (void)layoutSubviews {
    %orig;
    if ([((UITableView *)self).accessibilityIdentifier isEqualToString:@"ProfilePublicPlaylistsElementUI.playlistsTableView"])
        profilePlaylistHeading((UIView *)self);
}
%end

// Spotify resets alpha on layout/scroll/re-entry. Views we marked with profileKill stay at 0.
%hook UIView
- (void)didMoveToSuperview {
    %orig;
    if (profileIsPlaylistManageAction((UIView *)self)) {
        profileKill((UIView *)self);
        ((UIView *)self).userInteractionEnabled = NO;
        ((UIView *)self).accessibilityElementsHidden = YES;
    }
}

- (void)setAlpha:(CGFloat)alpha {
    if (objc_getAssociatedObject(self, &kProfileKillKey) || profileIsPlaylistManageAction((UIView *)self))
        alpha = 0;
    %orig(alpha);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
}
