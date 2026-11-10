// Library redesign: the header of Your Library and of a folder inside it, the way Home and Search have theirs
// (Redesigned/Home/HomeHeader.x, Redesigned/Search/SearchPage.x). A large title at the leading edge, the avatar
// that opens the side drawer at the trailing edge, and the scrim Spotify lays behind the header gone, the soft
// scroll edge (Kit/SGREdgeEffect.x) being what keeps the header clear of the list scrolling under it.
//
// What this file does to the root Library page (and what it does NOT leave of Spotify's):
//  - the filter chips under the row are hidden, the header is shortened to the row (rowBottom) and the list's
//    top inset is rewritten to leave room for the header plus our own shortcut rows;
//  - the shortcut rows and the section title ("Recently Added" / "Playlists") live on the PAGE (never inside the
//    list), positioned from the list's scroll offset, so they scroll away with it without depending on
//    Spotify's changing coordinates;
//  - the list's layout is Spotify's cells in a two column grid: the first kRecentsLimit items on the main
//    Library, every item on the Playlists page.
// Folders keep Spotify's chips and only get the restyled header row.
//
// Tree (trees/clean/library/03.txt:1159-1247): YourLibraryView holds YourLibraryContentView, the size of the
// page, and after it -- so over it -- YourLibraryHeaderView 402x159.33: LiquidGlass.GradientView (the scrim), a
// 402x48 row at {0, 62} holding an AutoLayoutStackView {8, 0} 390x48 of
// ListeningActivity_ElementsKit.AdaptiveFaceContainer (the avatar, id=Components.UI.SideDrawerButton),
// id=YourLibraryHeader.title ("Your Library", 21pt), a spacer, a hidden id=YourLibraryHeader.recents,
// id=YourLibraryHeader.search and id=YourLibraryHeader.plus; and under the row
// YourLibraryHeaderContentFiltersView {0, 110} 402x49.33, the chips. A folder (trees/continuous/1.txt:325-344)
// is the same header under YourLibrary_FolderImpl, with id=YourLibraryFolderHeader.back at the leading edge,
// its title, then contextMenu, plus and play or pause, and the chips at {0, 118}.
//
// The header neither moves nor shrinks as the list scrolls -- 03.txt, 05.txt and 06.txt hold it at
// {0, 0} 402x159.33 at three scroll positions -- so there is nothing here to follow: the row is laid out once a
// pass and stays where it is put.
//
// Each control moves by a transform rather than by a frame. Spotify's stack lays them out from constraints of
// its own on every pass, and Auto Layout sets a view's centre and bounds and leaves its transform alone, so the
// move outlives the pass that made it (Search moves the Browse cells the same way). Nothing leaves the stack:
// an arranged view of Spotify's that hides traps its stack in updateConstraints (Kit/SGRRestyle.h), so what
// goes is alpha, touches and accessibility, and the title Spotify draws goes that way while ours is a subview
// of the header the stack does not arrange.
//
// A move is worked out from where the stack put the control, so it holds only until the stack puts it somewhere
// else, and the stack does that on passes of its own that reach neither the header nor the page. So the row the
// controls stand in is watched too, and every pass of its own places them again. The header itself is watched
// as well, and the page lays out again when it enters a window, so what Spotify un-hides during the tab's
// appearance (old title, chips, scrim) is put away on the next pass instead of lingering.
//
// Scrolling: the list is held at its resting top only inside a short window opened by keepAtRest() right after
// WE change its inset or layout (see restingOffset). It is never held while the person is scrolling, and the
// window closes by itself, so the list can never stay frozen.

#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Library.h"
#import "MusicUniverse.h"
#import "MusicParty.h"
#import "Redesigned/Player/PlayerVinyl.h"
#import "Shared/Navigation/Links.h"

NSString *const SGRLibraryListIdentifier = @"YourLibraryContent.collectionView";

// Spotify's own inset for the header's controls: a 48pt button flush against the header's trailing edge has its
// 24pt glyph 20pt from the screen, and the 32pt avatar inside its own 48pt box 16pt from it, which is the
// margin Home gives the avatar.
static const CGFloat kRowInset = 8;
// Where the chips start in Spotify's header when they have not been measured yet (03.txt: {0, 110}).
static const CGFloat kDefaultRowBottom = 110;
static char kTitleKey, kRowWatchedKey;
static char kRecentsKey, kSearchKey, kPlusKey, kHeaderTitleKey;
static char kBackKey, kMenuKey, kFolderPlusKey, kPlayKey, kPauseKey, kFolderTitleKey;
static char kShortcutViewKey, kForcedTopKey, kRingKey, kLibraryHeaderHeightKey, kLibraryListKey, kHeaderActionsKey;
static char kLibraryRestUntilKey;   // on the list: until when (CACurrentMediaTime) it is kept at its resting top
static char kLibraryMarkKey;   // on the Library's list: "this is the one whose offset is kept at its top"
static char kLibrarySectionsEditorKey;
static char kLibraryLayoutActiveKey, kLibraryLayoutScheduledKey;
static char kHeaderWatchedKey;   // on the header: its own layout passes run layoutRoot too
static char kPlaylistsModeKey;   // on the list: whether it was last taken for the Playlists page
static char kMixedCountKey;      // on the list: the item count at which it was seen to hold mixed content

@interface SGRUniverseButton : UIButton
@end

@implementation SGRUniverseButton
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [self addTarget:self action:@selector(openUniverse:) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)openUniverse:(id)sender {
    (void)sender;
    SGRMusicUniversePresentFrom(self);
}
@end

@interface SGRLibraryShortcut : UIControl
@property (nonatomic, copy) void (^activate)(void);
@end

@implementation SGRLibraryShortcut
- (void)activateTouch:(id)sender {
    (void)sender;
    if (self.activate) self.activate();
}
@end

// The shortcut rows and the section title ahead of the list, in the Music app's Library. They are a
// subview of the PAGE (layoutRootNow puts them there and trackShortcuts moves them with the list's offset); the
// list's top inset is what leaves the room for them.
static const CGFloat kShortcutRowHeight = 54;
static const CGFloat kRecentsTitleGap = 27;     // from the last hairline to the top of the section title
static const CGFloat kRecentsTitleHeight = 28;
static const CGFloat kRecentsSection = 47;      // what the title leaves above the first card (the grid adds 20)
// Three controls share the header's single functional glass surface.
static const CGFloat kPillWidth = 132, kPillHeight = 46;
static const CGFloat kPillGlyph = 18;
static const CGFloat kAvatarScale = 1.25;       // Spotify's 32pt avatar to the Music app's 40pt
static const CGFloat kAvatarRing = 46;          // the thin circle drawn outside it
static const NSUInteger kRecentsLimit = 6;      // the cards under "Recently Added"; every other item is in Playlists
static const CGFloat kGridGap = 12;
static char kRecentsLabelKey, kLibraryActionsGlassKey;
static NSString *const kLibrarySectionVisibilityKey = @"spotifyglass.redesign.library.sections.visible";
static NSString *const kLibrarySectionOrderKey = @"spotifyglass.redesign.library.sections.order";

static NSArray<NSDictionary *> *librarySectionDefinitions(void) {
    return @[
        @{@"id": @"playlists", @"title": @"Playlists", @"symbol": @"music.note.list", @"uri": @"spotify:playlists"},
        @{@"id": @"artists", @"title": @"Artists", @"symbol": @"music.mic", @"uri": @"spotify:collection:artists"},
        @{@"id": @"albums", @"title": @"Albums", @"symbol": @"square.stack", @"uri": @"spotify:collection:albums"},
        @{@"id": @"songs", @"title": @"Songs", @"symbol": @"music.note", @"uri": @"spotify:collection:tracks"},
        @{@"id": @"downloaded", @"title": @"Downloaded", @"symbol": @"arrow.down.circle", @"uri": @"spotify:collection:downloads"},
        @{@"id": @"universe", @"title": @"Music Universe", @"symbol": @"sparkles", @"universe": @YES},
        @{@"id": @"party", @"title": @"Music Party", @"symbol": @"gamecontroller.fill", @"party": @YES},
    ];
}

static NSArray<NSDictionary *> *orderedLibrarySections(void) {
    NSArray<NSDictionary *> *definitions = librarySectionDefinitions();
    NSMutableDictionary<NSString *, NSDictionary *> *byID = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *defaultOrder = [NSMutableArray array];
    for (NSDictionary *section in definitions) {
        byID[section[@"id"]] = section;
        [defaultOrder addObject:section[@"id"]];
    }

    id saved = [NSUserDefaults.standardUserDefaults objectForKey:kLibrarySectionOrderKey];
    NSArray *requested = [saved isKindOfClass:NSArray.class] ? saved : defaultOrder;
    NSMutableArray<NSDictionary *> *ordered = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id identifier in requested) {
        if (![identifier isKindOfClass:NSString.class] || [seen containsObject:identifier]) continue;
        NSDictionary *section = byID[identifier];
        if (!section) continue;
        [ordered addObject:section];
        [seen addObject:identifier];
    }
    for (NSDictionary *section in definitions) {
        NSString *identifier = section[@"id"];
        if ([seen containsObject:identifier]) continue;
        [ordered addObject:section];
    }
    return ordered;
}

static NSSet<NSString *> *selectedLibrarySectionIDs(void) {
    NSArray<NSDictionary *> *definitions = librarySectionDefinitions();
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:kLibrarySectionVisibilityKey];
    if (![saved isKindOfClass:NSArray.class]) {
        NSMutableSet<NSString *> *all = [NSMutableSet set];
        for (NSDictionary *section in definitions) [all addObject:section[@"id"]];
        return all;
    }
    NSMutableSet<NSString *> *valid = [NSMutableSet set];
    for (NSDictionary *section in definitions) [valid addObject:section[@"id"]];
    NSMutableSet<NSString *> *selected = [NSMutableSet set];
    for (id identifier in (NSArray *)saved) {
        if ([identifier isKindOfClass:NSString.class] && [valid containsObject:identifier]) [selected addObject:identifier];
    }
    return selected;
}

static NSArray<NSDictionary *> *visibleLibrarySections(void) {
    NSSet<NSString *> *selected = selectedLibrarySectionIDs();
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray array];
    for (NSDictionary *section in orderedLibrarySections()) {
        if ([selected containsObject:section[@"id"]]) [visible addObject:section];
    }
    return visible;
}

static void layoutRoot(UIView *page);

// The layout of Spotify's list under the section title: the first `limit` items (the list is sorted by what
// was played last) as two columns of cards, every other item left out, and none of the supplementary views Spotify
// puts above them (its sort row). On the main Library the limit is kRecentsLimit; on the Playlists page it is
// NSUIntegerMax, so every playlist is shown, two by two. The cells are Spotify's own; the rows file turns a row
// into a card.
@interface SGRRecentsGridLayout : UICollectionViewLayout
@property (nonatomic) NSUInteger limit;   // NSUIntegerMax = every item
@end

@implementation SGRRecentsGridLayout {
    NSMutableDictionary<NSIndexPath *, UICollectionViewLayoutAttributes *> *_attributes;
    NSMutableArray<UICollectionViewLayoutAttributes *> *_shown;
    CGSize _size;
}

- (instancetype)init {
    if ((self = [super init])) _limit = kRecentsLimit;
    return self;
}

- (void)prepareLayout {
    [super prepareLayout];
    UICollectionView *view = self.collectionView;
    CGFloat width = view.bounds.size.width;
    CGFloat card = floor((width - 2 * SGRSideMargin - kGridGap) / 2.0);
    // The cover a square, the title and the kind under it (the rows file draws them 8 and 26pt below the cover).
    CGFloat height = card + 48, lineGap = 18, top = 20, bottom = 24;
    _attributes = [NSMutableDictionary dictionary];
    _shown = [NSMutableArray array];
    for (NSInteger section = 0; section < view.numberOfSections; section++) {
        for (NSInteger item = 0; item < [view numberOfItemsInSection:section]; item++) {
            NSIndexPath *path = [NSIndexPath indexPathForItem:item inSection:section];
            UICollectionViewLayoutAttributes *attributes = [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:path];
            NSUInteger n = _shown.count;
            if (n < self.limit) {
                attributes.frame = CGRectMake(SGRSideMargin + (n % 2) * (card + kGridGap),
                                              top + (n / 2) * (height + lineGap), card, height);
                [_shown addObject:attributes];
            } else {
                attributes.frame = CGRectZero;
                attributes.hidden = YES;
            }
            _attributes[path] = attributes;
        }
    }
    NSUInteger rows = (_shown.count + 1) / 2;
    _size = CGSizeMake(width, top + rows * height + (rows ? (rows - 1) * lineGap : 0) + bottom);
}

- (CGSize)collectionViewContentSize { return _size; }

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray *found = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attributes in _shown) {
        if (CGRectIntersectsRect(attributes.frame, rect)) [found addObject:attributes];
    }
    return found;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)path {
    return _attributes[path];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    return fabs(newBounds.size.width - self.collectionView.bounds.size.width) > 0.5;
}
@end

static NSString *recentlyAddedTitle(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en";
    return [language hasPrefix:@"it"] ? @"Aggiunti di recente" : @"Recently Added";
}

static NSString *playlistsTitle(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en";
    return [language hasPrefix:@"it"] ? @"Playlist" : @"Playlists";
}

// Spotify's own button for what ours stands in for: its action is run, the button itself stays out of sight.
static BOOL fire(UIView *view) {
    if (!view) return NO;
    __block UIControl *control = [view isKindOfClass:UIControl.class] ? (UIControl *)view : nil;
    if (!control) {
        SGForEachView(view, ^(UIView *sub) {
            if (!control && [sub isKindOfClass:UIControl.class]) control = (UIControl *)sub;
        });
    }
    if (!control) return NO;
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}

static UIView *childNamed(UIView *host, NSString *marker);

// The view controller in front, to say in the log what a shortcut opened.
static UIViewController *frontController(void) {
    UIViewController *vc = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) vc = window.rootViewController;
        }
    }
    while (vc) {
        UIViewController *next = vc.presentedViewController;
        if (!next && [vc isKindOfClass:UINavigationController.class]) next = ((UINavigationController *)vc).topViewController;
        if (!next && [vc isKindOfClass:UITabBarController.class]) next = ((UITabBarController *)vc).selectedViewController;
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

// The shortcuts' container, made once per list. It is NOT added to the list here: layoutRootNow puts it on the
// page, and adding it to the list on every call is what made it jump between the two parents on each pass.
static UIView *libraryShortcuts(UIView *list) {
    UIView *existing = objc_getAssociatedObject(list, &kShortcutViewKey);
    if (existing) return existing;

    UIView *container = [UIView new];
    container.backgroundColor = UIColor.clearColor;
    container.clipsToBounds = NO;
    objc_setAssociatedObject(list, &kShortcutViewKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSDictionary *> *items = visibleLibrarySections();
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:SGRSideMargin],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-SGRSideMargin],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor],
        [stack.heightAnchor constraintEqualToConstant:items.count * kShortcutRowHeight],
    ]];

    CGFloat hairlineThickness = 1.0 / MAX(1, UIScreen.mainScreen.scale);
    UIImageSymbolConfiguration *iconConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    UIImageSymbolConfiguration *chevronConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    for (NSDictionary *item in items) {
        SGRLibraryShortcut *row = [SGRLibraryShortcut new];
        row.accessibilityLabel = item[@"title"];
        row.accessibilityTraits = UIAccessibilityTraitButton;
        [row addTarget:row action:@selector(activateTouch:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:item[@"symbol"]
                                                                     withConfiguration:iconConfiguration]];
        icon.tintColor = UIColor.whiteColor;
        icon.contentMode = UIViewContentModeCenter;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = item[@"title"];
        label.textColor = SGRPrimary();
        label.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryLarge);
        label.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
                                                                        withConfiguration:chevronConfiguration]];
        chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
        chevron.contentMode = UIViewContentModeCenter;
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        UIView *line = [UIView new];
        line.backgroundColor = SGRHairline();
        line.userInteractionEnabled = NO;
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:icon];
        [row addSubview:label];
        [row addSubview:chevron];
        [row addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToConstant:kShortcutRowHeight],
            [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:29],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [chevron.widthAnchor constraintEqualToConstant:18],
            // The hairline under each row starts where its text does and runs to the page's margin.
            [line.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
            [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
            [line.heightAnchor constraintEqualToConstant:hairlineThickness],
        ]];
        __weak SGRLibraryShortcut *weakRow = row;
        NSString *uri = item[@"uri"];
        row.activate = ^{
            SGRLibraryShortcut *strongRow = weakRow;
            if (!strongRow) return;
            if (item[@"universe"]) {
                SGRMusicUniversePresentFrom(strongRow);
            } else if (item[@"party"]) {
                SGRMusicPartyPresentFrom(strongRow);
            } else if (!SGOpenSpotifyURI([NSURL URLWithString:uri])) {
                SGLog(@"redesign library: cannot open shortcut %@", uri);
            } else {
                // What the shortcut led to: a page of its own, or the Library itself filtered.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    SGLog(@"redesign library: shortcut %@ opened, front controller %@", uri,
                          NSStringFromClass(frontController().class));
                });
            }
        };
        [stack addArrangedSubview:row];
    }

    UILabel *recents = [UILabel new];
    recents.text = recentlyAddedTitle();
    recents.textColor = SGRPrimary();
    recents.font = SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryLarge);
    recents.accessibilityTraits = UIAccessibilityTraitHeader;
    [container addSubview:recents];
    objc_setAssociatedObject(container, &kRecentsLabelKey, recents, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return container;
}

@interface SGRLibrarySectionCell : UITableViewCell
@property (nonatomic, copy) void (^toggle)(void);
- (void)configureWithSection:(NSDictionary *)section selected:(BOOL)selected;
@end

@implementation SGRLibrarySectionCell {
    UIButton *_check;
    UIImageView *_icon;
    UILabel *_title;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.separatorInset = UIEdgeInsetsMake(0, 96, 0, 16);
    _check = [UIButton buttonWithType:UIButtonTypeSystem];
    [_check addTarget:self action:@selector(toggleSection) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_check];
    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.tintColor = SGRPrimary();
    [self.contentView addSubview:_icon];
    _title = [UILabel new];
    _title.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryLarge);
    _title.textColor = SGRPrimary();
    [self.contentView addSubview:_title];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat midY = CGRectGetMidY(self.contentView.bounds);
    _check.frame = CGRectMake(8, midY - 18, 36, 36);
    _icon.frame = CGRectMake(56, midY - 14, 28, 28);
    _title.frame = CGRectMake(96, 0, MAX(0, CGRectGetWidth(self.contentView.bounds) - 144),
                              CGRectGetHeight(self.contentView.bounds));
}

- (BOOL)shouldIndentWhileEditing {
    return NO;
}

- (void)configureWithSection:(NSDictionary *)section selected:(BOOL)selected {
    NSString *symbol = section[@"symbol"];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightRegular];
    _icon.image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    _title.text = section[@"title"];
    BOOL italian = [NSLocale.preferredLanguages.firstObject hasPrefix:@"it"];
    _check.accessibilityLabel = selected
        ? [NSString stringWithFormat:italian ? @"Rimuovi %@ dalla Libreria" : @"Remove %@ from Library", _title.text]
        : [NSString stringWithFormat:italian ? @"Aggiungi %@ alla Libreria" : @"Add %@ to Library", _title.text];
    _check.accessibilityValue = selected ? @"Selected" : @"Not selected";
    _check.accessibilityTraits = UIAccessibilityTraitButton;
    UIImageSymbolConfiguration *checkConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:31 weight:UIImageSymbolWeightRegular];
    UIImage *checkImage = [UIImage systemImageNamed:selected ? @"checkmark.circle.fill" : @"circle"
                                  withConfiguration:checkConfiguration];
    [_check setImage:checkImage forState:UIControlStateNormal];
    _check.tintColor = selected ? SGRAccent() : SGRSecondary();
}

- (void)toggleSection {
    if (self.toggle) self.toggle();
}
@end

@interface SGRLibrarySectionsEditor : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) UIView *libraryPage;
- (void)finish;
@end

@implementation SGRLibrarySectionsEditor {
    UITableView *_table;
    UILabel *_title;
    UIButton *_done;
    NSMutableArray<NSDictionary *> *_sections;
    NSMutableSet<NSString *> *_selected;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.backgroundColor = UIColor.blackColor;
    self.accessibilityViewIsModal = YES;
    _sections = [orderedLibrarySections() mutableCopy];
    _selected = [selectedLibrarySectionIDs() mutableCopy];

    _title = [UILabel new];
    _title.text = [NSLocale.preferredLanguages.firstObject hasPrefix:@"it"] ? @"Libreria" : @"Library";
    _title.font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    _title.textColor = SGRPrimary();
    _title.accessibilityTraits = UIAccessibilityTraitHeader;
    [self addSubview:_title];

    _done = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightSemibold];
    [_done setImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:configuration]
           forState:UIControlStateNormal];
    _done.tintColor = UIColor.whiteColor;
    _done.backgroundColor = SGRAccent();
    _done.layer.cornerRadius = 28;
    _done.accessibilityLabel = [NSLocale.preferredLanguages.firstObject hasPrefix:@"it"] ? @"Fine" : @"Done";
    [_done addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_done];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor;
    _table.opaque = NO;
    _table.separatorColor = SGRHairline();
    _table.separatorInset = UIEdgeInsetsMake(0, 96, 0, 16);
    _table.rowHeight = 68;
    _table.estimatedRowHeight = 68;
    _table.dataSource = self;
    _table.delegate = self;
    _table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _table.showsVerticalScrollIndicator = NO;
    _table.tableFooterView = [UIView new];
    [_table registerClass:SGRLibrarySectionCell.class forCellReuseIdentifier:@"library-section"];
    [_table setEditing:YES animated:NO];
    [self addSubview:_table];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _title.frame = CGRectMake(24, 42, MAX(0, CGRectGetWidth(self.bounds) - 104), 54);
    _done.frame = CGRectMake(CGRectGetWidth(self.bounds) - 72, 38, 56, 56);
    _table.frame = CGRectMake(0, 118, CGRectGetWidth(self.bounds), MAX(0, CGRectGetHeight(self.bounds) - 118));
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SGRLibrarySectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"library-section" forIndexPath:indexPath];
    NSDictionary *section = _sections[indexPath.row];
    NSString *identifier = section[@"id"];
    [cell configureWithSection:section selected:[_selected containsObject:identifier]];
    __weak typeof(self) weakSelf = self;
    __weak UITableView *weakTableView = tableView;
    cell.toggle = ^{
        SGRLibrarySectionsEditor *editor = weakSelf;
        UITableView *strongTableView = weakTableView;
        if (!editor || !strongTableView) return;
        if ([editor->_selected containsObject:identifier]) [editor->_selected removeObject:identifier];
        else [editor->_selected addObject:identifier];
        [strongTableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    };
    cell.showsReorderControl = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) return;
    NSDictionary *section = _sections[sourceIndexPath.row];
    [_sections removeObjectAtIndex:sourceIndexPath.row];
    [_sections insertObject:section atIndex:destinationIndexPath.row];
}

- (void)finish {
    NSMutableArray<NSString *> *selected = [NSMutableArray array];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *section in _sections) {
        NSString *identifier = section[@"id"];
        [order addObject:identifier];
        if ([_selected containsObject:identifier]) [selected addObject:identifier];
    }
    [NSUserDefaults.standardUserDefaults setObject:selected forKey:kLibrarySectionVisibilityKey];
    [NSUserDefaults.standardUserDefaults setObject:order forKey:kLibrarySectionOrderKey];
    UIView *page = self.libraryPage;
    [self removeFromSuperview];
    objc_setAssociatedObject(page, &kLibrarySectionsEditorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UICollectionView *list = (UICollectionView *)SGRFindByIdentifier(page, SGRLibraryListIdentifier, NULL);
    UIView *shortcuts = list ? objc_getAssociatedObject(list, &kShortcutViewKey) : nil;
    [shortcuts removeFromSuperview];
    if (list) objc_setAssociatedObject(list, &kShortcutViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (page) layoutRoot(page);
}
@end

static CGFloat libraryEditorBottom(UIView *page) {
    CGFloat bottom = CGRectGetHeight(page.bounds);
    UIWindow *window = page.window;
    if (!window) return MAX(0, bottom - 160);
    UIView *nowPlaying = SGRFindByIdentifier(window, @"SPTNowPlayingBar", NULL);
    if (nowPlaying && !nowPlaying.hidden && nowPlaying.alpha > 0.01) {
        CGFloat top = CGRectGetMinY([nowPlaying convertRect:nowPlaying.bounds toView:page]);
        if (top > 0) bottom = MIN(bottom, top - 8);
    }
    __block UIView *tabBar = nil;
    SGForEachView(window, ^(UIView *view) {
        if (!tabBar && [NSStringFromClass(view.class) containsString:@"UITabBarContainerWrapperView"] &&
            !view.hidden && view.alpha > 0.01) tabBar = view;
    });
    if (tabBar) {
        CGFloat top = CGRectGetMinY([tabBar convertRect:tabBar.bounds toView:page]);
        if (top > 0) bottom = MIN(bottom, top - 8);
    }
    if (bottom >= CGRectGetHeight(page.bounds) - 1) bottom = MAX(0, bottom - 160);
    return MAX(0, bottom);
}

static void presentLibrarySectionsEditor(UIView *header) {
    UIView *page = header;
    while (page && !SGRFindByIdentifier(page, SGRLibraryListIdentifier, NULL)) page = page.superview;
    if (!page) {
        SGLog(@"redesign library: cannot open section editor without the Library page");
        return;
    }
    SGRLibrarySectionsEditor *editor = objc_getAssociatedObject(page, &kLibrarySectionsEditorKey);
    if (editor) return;
    editor = [[SGRLibrarySectionsEditor alloc] initWithFrame:CGRectZero];
    editor.libraryPage = page;
    objc_setAssociatedObject(page, &kLibrarySectionsEditorKey, editor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    editor.frame = CGRectMake(0, 0, CGRectGetWidth(page.bounds), libraryEditorBottom(page));
    editor.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [page addSubview:editor];
    [page bringSubviewToFront:editor];
}

// Spotify's search and add actions are fired through their original controls; editing stays in the redesign.
static UIView *libraryHeaderActions(UIView *header) {
    UIView *existing = objc_getAssociatedObject(header, &kHeaderActionsKey);
    if (existing) return existing;

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPillWidth, kPillHeight)];
    pill.layer.cornerRadius = kPillHeight / 2;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    SGRGlassCapsuleInside(pill, &kLibraryActionsGlassKey, CGSizeMake(kPillWidth, kPillHeight), NO);

    UIStackView *stack = [[UIStackView alloc] initWithFrame:pill.bounds];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [pill addSubview:stack];

    __weak UIView *weakHeader = header;
    NSArray<NSString *> *symbols = @[@"text.badge.plus", @"checklist", @"magnifyingglass"];
    BOOL italian = [NSLocale.preferredLanguages.firstObject hasPrefix:@"it"];
    NSArray<NSString *> *labels = italian ? @[@"Aggiungi", @"Modifica sezioni della libreria", @"Cerca"]
                                           : @[@"Add", @"Edit Library Sections", @"Search"];
    for (NSUInteger i = 0; i < symbols.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityLabel = labels[i];
        button.tintColor = UIColor.whiteColor;
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:kPillGlyph weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:symbols[i] withConfiguration:configuration]
                forState:UIControlStateNormal];
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            UIView *owner = weakHeader;
            if (!owner) return;
            BOOL done;
            if (i == 0) {
                done = fire(SGRFindByIdentifier(owner, @"YourLibraryHeader.plus", &kPlusKey));
            } else if (i == 1) {
                presentLibrarySectionsEditor(owner);
                done = YES;
            } else {
                done = fire(SGRFindByIdentifier(owner, @"YourLibraryHeader.search", &kSearchKey));
            }
            if (!done) SGLog(@"redesign library: no Spotify control to run for header button %lu", (unsigned long)i);
        }] forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
    objc_setAssociatedObject(header, &kHeaderActionsKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return pill;
}

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

void SGRLibraryClearScrim(UIView *header) {
    vanish(childNamed(header, @"GradientView"));
}

#pragma mark - the controls

// The header's controls, in the order they are to read from the leading edge, leaving out what this build does
// not have, what Spotify has hidden (a folder shows play or pause, never both) and what has not been laid out.
static NSMutableArray<UIView *> *controlsIn(UIView *header, NSArray<NSString *> *identifiers, const void **keys) {
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        UIView *control = SGRFindByIdentifier(header, identifiers[i], keys[i]);
        if (control && !control.hidden && control.alpha > 0.01 && control.bounds.size.width > 1) [found addObject:control];
    }
    return found;
}

// Puts the controls at the header's trailing edge, the last of them flush against it and each keeping the width
// it has, and answers where the leading edge of the first of them fell.
static BOOL isFace(UIView *view);

static CGFloat placeTrailing(UIView *header, NSArray<UIView *> *controls, CGFloat inset) {
    CGFloat right = header.bounds.size.width - inset;
    for (UIView *control in controls.reverseObjectEnumerator) {
        CGFloat width = control.bounds.size.width;
        // The centre is where Auto Layout put the control, whatever transform is on it; its frame is not.
        CGFloat natural = [control.superview convertPoint:CGPointZero toView:header].x + control.center.x - width / 2;
        CGAffineTransform move = CGAffineTransformMakeTranslation(right - width - natural, 0);
        // The avatar is drawn at the Music app's size, about its own centre.
        if (isFace(control)) move = CGAffineTransformScale(move, kAvatarScale, kAvatarScale);
        if (!CGAffineTransformEqualToTransform(control.transform, move)) control.transform = move;
        right -= width;
    }
    return right;
}

// `place` again after every pass of the row the controls stand in (see the top of the file), for as long as it
// is in the header. The row is the stack's container, a plain UIView the Kit can watch; what `place` does not
// touch -- the header's height, the list under it -- stays the page's pass's.
static void watchRow(UIView *row, UIView *header, NSArray<UIView *> *(*place)(UIView *header)) {
    if (!row || objc_getAssociatedObject(row, &kRowWatchedKey)) return;
    objc_setAssociatedObject(row, &kRowWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHeader = header;
    SGRObserveLayout(row, ^(UIView *view) {
        UIView *owner = weakHeader;
        if (!owner || ![view isDescendantOfView:owner]) return;
        // Once, the first time the row's pass finds a control away from where the page's pass left it.
        static BOOL logged;
        NSMutableArray<NSNumber *> *before = logged ? nil : [NSMutableArray array];
        for (UIView *sub in before ? view.subviews : @[]) [before addObject:@(sub.transform.tx)];
        NSArray<UIView *> *placed = place(owner);
        if (!before || !owner.window) return;
        for (NSUInteger i = 0; i < before.count && i < view.subviews.count; i++) {
            if (fabs(view.subviews[i].transform.tx - before[i].doubleValue) < 0.5) continue;
            logged = YES;
            SGLog(@"redesign library: the header's row laid out on its own after the page, its %lu controls placed again",
                  (unsigned long)placed.count);
            break;
        }
    });
}

#pragma mark - the title

static NSString *textIn(UIView *label) {
    __block NSString *text = nil;
    SGForEachView(label, ^(UIView *view) {
        if (!text && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) text = ((UILabel *)view).text;
    });
    return text;
}

static UILabel *titleIn(UIView *header) {
    UILabel *title = objc_getAssociatedObject(header, &kTitleKey);
    if (!title) {
        title = [UILabel new];
        title.textColor = SGRPrimary();
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.6;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (title.superview != header) [header addSubview:title];
    return title;
}

// The title Spotify's own says, so it follows the app's language, in the Music app's size on the row's middle.
static void layoutTitle(UIView *header, UIView *spotifyTitle, NSString *override, CGFloat leading, CGFloat trailing, CGFloat middle) {
    UILabel *title = titleIn(header);
    NSString *text = override ?: textIn(spotifyTitle);
    if (text.length && ![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    CGFloat height = ceil(font.lineHeight);
    CGRect frame = CGRectMake(leading, round(middle - height / 2), MAX(0, trailing - SGRGrid - leading), height);
    if (!CGRectEqualToRect(title.frame, frame)) title.frame = frame;
}

#pragma mark - the two headers

static BOOL isFace(UIView *view) {
    static Class faceClass;
    if (!faceClass) faceClass = NSClassFromString(@"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer");
    return faceClass && [view isKindOfClass:faceClass];
}

// The root header keeps Spotify's own search button and adds only the two redesign actions beside it.
// The title remains before that group, while Spotify's recents control stays out of sight.
static NSArray<UIView *> *placeRoot(UIView *header) {
    UIView *spotifyTitle = SGRFindByIdentifier(header, @"YourLibraryHeader.title", &kHeaderTitleKey);
    vanish(spotifyTitle);
    static const void *keys[] = {&kRecentsKey, &kPlusKey};
    NSArray<NSString *> *identifiers = @[
        @"YourLibraryHeader.recents", @"YourLibraryHeader.plus",
    ];
    for (NSUInteger i = 0; i < identifiers.count; i++) vanish(SGRFindByIdentifier(header, identifiers[i], keys[i]));

    __block UIView *face = nil;
    SGForEachView(header, ^(UIView *view) {
        if (!face && isFace(view) && view.bounds.size.width > 1) face = view;
    });
    if (!face) return @[];
    UIView *spotifySearch = SGRFindByIdentifier(header, @"YourLibraryHeader.search", &kSearchKey);
    vanish(spotifySearch);
    // Keep Spotify's profile at the trailing edge; its search is represented by a button in our glass capsule.
    NSMutableArray<UIView *> *trailing = [NSMutableArray array];
    [trailing addObject:face];

    placeTrailing(header, trailing, 11);
    // Where the avatar is drawn: its centre as Auto Layout has it, moved by the translation on it.
    CGPoint centre = [face.superview convertPoint:CGPointMake(face.center.x + face.transform.tx, face.center.y)
                                           toView:header];
    UIView *ring = objc_getAssociatedObject(header, &kRingKey);
    if (!ring) {
        ring = [UIView new];
        ring.userInteractionEnabled = NO;
        ring.backgroundColor = UIColor.clearColor;
        ring.layer.borderWidth = 1;
        ring.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
        ring.layer.cornerRadius = kAvatarRing / 2;
        objc_setAssociatedObject(header, &kRingKey, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ring.superview != header) [header addSubview:ring];
    CGRect ringFrame = CGRectMake(centre.x - kAvatarRing / 2, centre.y - kAvatarRing / 2, kAvatarRing, kAvatarRing);
    if (!CGRectEqualToRect(ring.frame, ringFrame)) ring.frame = ringFrame;

    UIView *pill = libraryHeaderActions(header);
    if (pill.superview != header) [header addSubview:pill];
    CGRect pillFrame = CGRectMake(CGRectGetMinX(ringFrame) - 8 - kPillWidth, round(centre.y - kPillHeight / 2),
                                  kPillWidth, kPillHeight);
    if (!CGRectEqualToRect(pill.frame, pillFrame)) pill.frame = pillFrame;

    NSString *override = SGFlag(SGRKeyPlayerVinyl, NO) ? @"Records" : nil;
    layoutTitle(header, spotifyTitle, override, SGRSideMargin, CGRectGetMinX(pillFrame), centre.y);
    for (UIView *control in trailing) watchRow(control.superview, header, placeRoot);
    return trailing;
}

// The folder header's controls at its trailing edge and the title between them and the back button, which stays
// where Spotify has it. Answers what it placed in the order it reads, the back button first.
static NSArray<UIView *> *placeFolder(UIView *header) {
    UIView *spotifyTitle = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.title", &kFolderTitleKey);
    vanish(spotifyTitle);
    UIView *back = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.back", &kBackKey);
    static const void *keys[] = {&kMenuKey, &kFolderPlusKey, &kPlayKey, &kPauseKey};
    NSMutableArray<UIView *> *placed = controlsIn(header, @[
        @"YourLibraryFolderHeader.contextMenu", @"YourLibraryFolderHeader.plus",
        @"YourLibraryFolderHeader.play", @"YourLibraryFolderHeader.pause",
    ], keys);
    if (!placed.count && !back) return placed;

    CGFloat trailingEdge = placed.count ? placeTrailing(header, placed, kRowInset) : header.bounds.size.width - kRowInset;
    if (back) [placed insertObject:back atIndex:0];
    CGRect rowFrame = SGFrameIn(placed.firstObject, header);
    CGFloat leading = back ? CGRectGetMaxX(rowFrame) + SGRGrid : SGRSideMargin;
    layoutTitle(header, spotifyTitle, nil, leading, trailingEdge, CGRectGetMidY(rowFrame));
    for (UIView *control in placed) watchRow(control.superview, header, placeFolder);
    return placed;
}

// Whether the list is the dedicated "Playlists" page (opened from the shortcut) rather than the main Library.
// The main Library also contains Playlist rows, mixed with albums, artists and podcasts, so a single playlist
// row proves nothing: the page counts as the Playlists page only when it holds playlist rows and nothing else.
//
// Two things keep the answer from flapping between the two modes (which was visible as the page
// re-laying itself out right after opening):
//  - with no recognisable cell on screen (not loaded yet) the previous answer stands;
//  - the main Library's grid shows only the first kRecentsLimit items, so six playlists in a row can look like
//    the Playlists page. When the unlimited grid then shows other kinds, the list is remembered as mixed at
//    that item count and stays the main Library until the count changes (a filter, a reload).
static BOOL isPlaylistsPage(UICollectionView *list) {
    __block BOOL hasPlaylist = NO, hasOther = NO;
    for (UICollectionViewCell *cell in list.visibleCells) {
        if (cell.hidden || cell.alpha <= 0.01) continue;
        SGForEachView(cell, ^(UIView *view) {
            NSString *identifier = view.accessibilityIdentifier;
            if ([identifier isEqualToString:@"Playlist.Row.Library"]) {
                hasPlaylist = YES;
            } else if ([identifier isEqualToString:@"Album.Row.Library"] ||
                       [identifier isEqualToString:@"Artist.Row.Library"] ||
                       [identifier isEqualToString:@"Podcast.Row.Library"] ||
                       [identifier isEqualToString:@"Components.UI.CardLibrary"]) {
                hasOther = YES;
            }
        });
    }

    NSNumber *previous = objc_getAssociatedObject(list, &kPlaylistsModeKey);
    if (!hasPlaylist && !hasOther) return previous.boolValue;

    NSInteger total = 0;
    for (NSInteger section = 0; section < list.numberOfSections; section++) total += [list numberOfItemsInSection:section];

    if (hasOther) {
        objc_setAssociatedObject(list, &kMixedCountKey, @(total), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(list, &kPlaylistsModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }

    NSNumber *mixed = objc_getAssociatedObject(list, &kMixedCountKey);
    if (mixed && mixed.integerValue == total) {
        objc_setAssociatedObject(list, &kPlaylistsModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (mixed) objc_setAssociatedObject(list, &kMixedCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(list, &kPlaylistsModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

#pragma mark - resting at the top

// The list rests at its top only inside a short window that WE open (keepAtRest) right after changing its inset
// or layout, so a restored offset or a late inset does not leave it scrolled past the first shortcuts. The
// window closes by itself, and it is dropped the moment the person touches the list, so the list can never
// stay frozen the way an open-ended "until the person scrolls" flag could.
static void keepAtRest(UIScrollView *list, NSTimeInterval seconds) {
    objc_setAssociatedObject(list, &kLibraryRestUntilKey, @(CACurrentMediaTime() + seconds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGPoint restingOffset(UIScrollView *list, CGPoint offset) {
    if (!objc_getAssociatedObject(list, &kLibraryMarkKey)) return offset;
    if (list.isTracking || list.isDragging || list.isDecelerating) {
        objc_setAssociatedObject(list, &kLibraryRestUntilKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return offset;
    }
    NSNumber *until = objc_getAssociatedObject(list, &kLibraryRestUntilKey);
    if (!until || CACurrentMediaTime() > until.doubleValue) return offset;
    offset.y = -list.adjustedContentInset.top;
    return offset;
}

static void layoutRootNow(UIView *page) {
    UIView *header = childNamed(page, @"YourLibraryHeaderView");
    if (!header) return;
    SGRLibrarySectionsEditor *editor = objc_getAssociatedObject(page, &kLibrarySectionsEditorKey);
    if (editor) {
        editor.frame = CGRectMake(0, 0, CGRectGetWidth(page.bounds), libraryEditorBottom(page));
        [page bringSubviewToFront:editor];
        return;
    }

    // Spotify can un-hide its own title, chips and scrim on passes of the header's own (the tab appearing, the
    // model arriving), so the header's passes run this too, once watched.
    if (!objc_getAssociatedObject(header, &kHeaderWatchedKey)) {
        objc_setAssociatedObject(header, &kHeaderWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakPage = page;
        SGRObserveLayout(header, ^(UIView *view) {
            UIView *owner = weakPage;
            if (owner) layoutRoot(owner);
        });
    }

    [header layoutIfNeeded];
    SGRLibraryClearScrim(header);
    UIView *chips = childNamed(header, @"YourLibraryHeaderContentFiltersView");
    vanish(chips);

    // The header ends under the row of the title: the chips Spotify puts below it are gone, and what stood
    // under them scrolls with the list now, so the header must not cover it or take its touches.
    // The height is stored only once it was measured from the chips; until then Spotify's own 110 stands in,
    // so a first pass before the chips are positioned does not fix a wrong height for good.
    NSNumber *storedBottom = objc_getAssociatedObject(header, &kLibraryHeaderHeightKey);
    CGFloat rowBottom;
    if (storedBottom) {
        rowBottom = storedBottom.doubleValue;
    } else {
        if (header.bounds.size.height < 100) return;   // not laid out yet
        if (chips && CGRectGetMinY(chips.frame) > 40) {
            rowBottom = CGRectGetMinY(chips.frame);
            objc_setAssociatedObject(header, &kLibraryHeaderHeightKey, @(rowBottom), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            rowBottom = kDefaultRowBottom;
        }
    }
    CGRect headerFrame = header.frame;
    headerFrame.size.height = rowBottom;
    if (!CGRectEqualToRect(header.frame, headerFrame)) header.frame = headerFrame;

    NSArray<UIView *> *trailing = placeRoot(header);

    UICollectionView *list = (UICollectionView *)SGRFindByIdentifier(page, SGRLibraryListIdentifier, &kLibraryListKey);
    if ([list isKindOfClass:UICollectionView.class]) {
        // The first time the list is taken over, let it settle at its top for a moment.
        if (!objc_getAssociatedObject(list, &kLibraryMarkKey)) keepAtRest(list, 1.5);
        objc_setAssociatedObject(list, &kLibraryMarkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL playlistCollection = isPlaylistsPage(list);

        CGFloat shortcutsHeight = visibleLibrarySections().count * kShortcutRowHeight;
        CGFloat lead = shortcutsHeight + kRecentsSection;
        CGFloat width = list.bounds.size.width;

        // Keep the shortcuts in page coordinates. Placing them at a negative
        // content coordinate inside the scroll view makes their visual frame
        // depend on Spotify's changing contentOffset and breaks hit testing.
        UIView *shortcuts = libraryShortcuts(list);
        shortcuts.alpha = 1;
        shortcuts.userInteractionEnabled = YES;
        shortcuts.accessibilityElementsHidden = NO;
        CGRect listFrame = [list convertRect:list.bounds toView:page];
        if (shortcuts.superview != page) [page addSubview:shortcuts];
        CGFloat scrollDistance = MAX(0, list.contentOffset.y + list.adjustedContentInset.top);
        CGRect shortcutsFrame = CGRectMake(CGRectGetMinX(listFrame), rowBottom - scrollDistance,
                                           width, lead);
        if (!CGRectEqualToRect(shortcuts.frame, shortcutsFrame)) shortcuts.frame = shortcutsFrame;

        // Reorder only when needed: bringSubviewToFront queues another layout pass of the page.
        NSArray<UIView *> *order = page.subviews;
        if (order.count < 2 || order.lastObject != header || order[order.count - 2] != shortcuts) {
            [page bringSubviewToFront:shortcuts];
            [page bringSubviewToFront:header];
        }

        // The section title: "Playlists" on the Playlists page, "Recently Added" on the main Library.
        UILabel *recents = objc_getAssociatedObject(shortcuts, &kRecentsLabelKey);
        recents.hidden = NO;
        NSString *sectionTitle = playlistCollection ? playlistsTitle() : recentlyAddedTitle();
        if (![recents.text isEqualToString:sectionTitle]) recents.text = sectionTitle;
        CGRect recentsFrame = CGRectMake(SGRSideMargin, shortcutsHeight + kRecentsTitleGap,
                                         MAX(0, width - 2 * SGRSideMargin), kRecentsTitleHeight);
        if (!CGRectEqualToRect(recents.frame, recentsFrame)) recents.frame = recentsFrame;

        // The list starts under the header's row and the room the shortcuts take. Its inset is worked out from
        // where it is on the page, not added to whatever Spotify left, so a pass that finds it already
        // changed leaves it as it is.
        // Use the visible bounds origin: CGPointZero is the moving content origin of a scroll view.
        CGFloat listTop = [list convertPoint:list.bounds.origin toView:page].y;
        CGFloat safe = list.adjustedContentInset.top - list.contentInset.top;
        UIEdgeInsets inset = list.contentInset;
        inset.top = rowBottom + lead - listTop - safe;
        // Spotify writes the list's inset on passes of its own; the hook below keeps this one.
        objc_setAssociatedObject(list, &kForcedTopKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (fabs(list.contentInset.top - inset.top) > 0.5) {
            list.contentInset = inset;
            keepAtRest(list, 1.0);
        }
        UIEdgeInsets indicators = list.verticalScrollIndicatorInsets;
        CGFloat indicatorTop = MAX(0, rowBottom - listTop - safe);
        if (fabs(indicators.top - indicatorTop) > 0.5) {
            indicators.top = indicatorTop;
            list.verticalScrollIndicatorInsets = indicators;
        }

        // The sort row Spotify puts above its list (a supplementary view) is what the shortcuts replace.
        for (UIView *sub in list.subviews) {
            if ([sub isKindOfClass:UICollectionReusableView.class] && ![sub isKindOfClass:UICollectionViewCell.class] &&
                sub.bounds.size.height < 80) vanish(sub);
        }

        // Main Library: the first kRecentsLimit items as cards. Playlists page: every item, two by two.
        NSUInteger wanted = playlistCollection ? NSUIntegerMax : kRecentsLimit;
        SGRRecentsGridLayout *grid = [list.collectionViewLayout isKindOfClass:SGRRecentsGridLayout.class]
            ? (SGRRecentsGridLayout *)list.collectionViewLayout : nil;
        if (!grid || grid.limit != wanted) {
            grid = [SGRRecentsGridLayout new];
            grid.limit = wanted;
            [list setCollectionViewLayout:grid animated:NO];
            [list layoutIfNeeded];
            keepAtRest(list, 1.0);
        }

        // Only inside the keepAtRest window is the list put back at its top.
        CGPoint wantedOffset = restingOffset(list, list.contentOffset);
        if (fabs(wantedOffset.y - list.contentOffset.y) > 0.5) list.contentOffset = wantedOffset;

        // Once: what else the page holds, so a control of Spotify's still showing (its list/grid toggle) can be
        // named and put away.
        static BOOL dumped;
        if (!dumped && header.window && list.window) {
            dumped = YES;
            for (UIView *sub in page.subviews) {
                SGLog(@"redesign library: page subview %@ %@", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame));
            }
            for (UIView *sub in list.subviews) {
                if ([sub isKindOfClass:UICollectionViewCell.class]) continue;
                SGLog(@"redesign library: list subview %@ %@", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame));
            }
        }
    }

    if (!trailing.count) return;

    // The first pass that laid the header out, not the first pass at all: a page appearing lays out before
    // its controls have a size, and a line off that pass would say the header was left as Spotify's.
    UIView *face = isFace(trailing.lastObject) ? trailing.lastObject : nil;
    static BOOL logged;
    if (!logged && header.window && face) {
        logged = YES;
        SGLog(@"redesign library: header %@, avatar %@, list inset %@", NSStringFromCGRect(header.frame),
              face ? @"found" : @"not found", list ? NSStringFromUIEdgeInsets(list.contentInset) : @"no list");
    }
}

static void layoutRoot(UIView *page) {
    if (!page || objc_getAssociatedObject(page, &kLibraryLayoutActiveKey)) return;
    objc_setAssociatedObject(page, &kLibraryLayoutActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    layoutRootNow(page);
    objc_setAssociatedObject(page, &kLibraryLayoutActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void layoutFolder(UIView *page) {
    UIView *header = childNamed(page, @"FolderHeaderView");
    if (!header) return;
    [header layoutIfNeeded];
    SGRLibraryClearScrim(header);

    NSArray<UIView *> *placed = placeFolder(header);
    if (!placed.count) return;

    UIView *back = SGRFindByIdentifier(header, @"YourLibraryFolderHeader.back", &kBackKey);
    NSUInteger trailing = placed.count - (back ? 1 : 0);
    static BOOL logged;
    if (!logged && header.window && trailing) {
        logged = YES;
        SGLog(@"redesign library: folder header %@, back %@, %lu controls at the trailing edge, chips %@",
              NSStringFromCGRect(header.frame), back ? @"found" : @"not found", (unsigned long)trailing,
              childNamed(header, @"YourLibraryHeaderContentFiltersView") ? @"Spotify's" : @"not found");
    }
}

// UIKit updates a scroll view's bounds directly during an interactive scroll; setContentOffset:
// is not guaranteed to run. The shortcuts live on the page, so follow the list's bounds here.
static void trackShortcuts(UIScrollView *list) {
    UIView *shortcuts = objc_getAssociatedObject(list, &kShortcutViewKey);
    if (!shortcuts || !shortcuts.superview || shortcuts.superview == list) return;
    UIView *page = shortcuts.superview;
    UIView *header = childNamed(page, @"YourLibraryHeaderView");
    NSNumber *rowBottom = header ? objc_getAssociatedObject(header, &kLibraryHeaderHeightKey) : nil;
    if (!rowBottom) return;

    CGRect listFrame = [list convertRect:list.bounds toView:page];
    CGFloat scrollDistance = MAX(0, list.contentOffset.y + list.adjustedContentInset.top);
    CGRect frame = shortcuts.frame;
    frame.origin.x = CGRectGetMinX(listFrame);
    frame.origin.y = rowBottom.doubleValue - scrollDistance;
    frame.size.width = list.bounds.size.width;
    if (!CGRectEqualToRect(shortcuts.frame, frame)) shortcuts.frame = frame;
}

// The Library list's top inset is the one layoutRoot worked out, whoever writes it.
%hook UIScrollView
- (void)setContentInset:(UIEdgeInsets)inset {
    NSNumber *forced = objc_getAssociatedObject(self, &kForcedTopKey);
    if (forced) inset.top = forced.doubleValue;
    %orig(inset);
    // The inset moved, and the offset with it or not: inside the keepAtRest window put the list back at its top.
    if (forced) {
        CGPoint offset = self.contentOffset, rest = restingOffset(self, offset);
        if (fabs(rest.y - offset.y) > 0.5) self.contentOffset = rest;
    }
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    if (objc_getAssociatedObject(self, &kLibraryMarkKey)) trackShortcuts(self);
}

// No layoutRoot from here: it ran on every scrolled frame and queued layout passes of the page. setBounds:
// above is what moves the shortcuts while scrolling.
- (void)setContentOffset:(CGPoint)offset {
    %orig(restingOffset(self, offset));
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig(restingOffset(self, offset), animated);
}
%end

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    if (!objc_getAssociatedObject(self, &kLibraryMarkKey) ||
        objc_getAssociatedObject(self, &kLibraryLayoutScheduledKey)) return;
    objc_setAssociatedObject(self, &kLibraryLayoutScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UICollectionView *weakList = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UICollectionView *list = weakList;
        if (!list) return;
        objc_setAssociatedObject(list, &kLibraryLayoutScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *page = list;
        while (page && ![NSStringFromClass(page.class) containsString:@"YourLibraryView"]) page = page.superview;
        if (page.window) layoutRoot(page);
    });
}
%end

%hook _TtC28YourLibrary_YourLibraryXImpl15YourLibraryView
- (void)layoutSubviews {
    %orig;
    layoutRoot((UIView *)self);
}

// Entering a window (the tab being selected) lays the page out again, so whatever Spotify un-hid while the tab
// was appearing is put away on the next pass rather than lingering next to the redesigned header.
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) layoutRoot((UIView *)self);
}
%end

%hook _TtC22YourLibrary_FolderImpl10FolderView
- (void)layoutSubviews {
    %orig;
    layoutFolder((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC28YourLibrary_YourLibraryXImpl15YourLibraryView",
        @"_TtC22YourLibrary_FolderImpl10FolderView",
        @"_TtC21YourLibrary_CommonKit35YourLibraryHeaderContentFiltersView",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
