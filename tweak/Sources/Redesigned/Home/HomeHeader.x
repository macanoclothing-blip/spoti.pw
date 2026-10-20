// Home redesign: the header the way the Music app has it. The filter pills (All, Music, Podcasts) go and
// a large title takes their place at the leading edge; the avatar that opens the side drawer moves to the
// trailing edge; the scrim Spotify lays behind the header goes too, the soft scroll edge (Kit/SGREdgeEffect.x)
// being what keeps the title clear of the page scrolling under it, as on every other redesigned page.
//
// Tree (trees/clean/home/10.txt:3018-3051): FunkisViewController's view holds a 402x112 UIView around
// Reprise_LiquidGlassKit LiquidGlass.GradientView (the scrim) and, at {0, 62}, an
// ElementView<HomeHeaderElement> 402x50 holding HomeHeaderView > UIStackView {0, 8} 402x34 of two arranged
// views: ListeningActivity_ElementsKit.AdaptiveFaceContainer {16, 0} 32x34 (the avatar,
// id=Components.UI.SideDrawerButton) and LiquidGlass.LeadingFadeMaskView {48, 1} 354x32 around
// Home_PillUIKit.PillScrollView.
//
// The avatar moves by the stack's layout direction rather than by a frame of ours. Right to left, the stack
// lays its first view out at the trailing edge itself on every pass, whatever width the face container
// takes when friends listening show beside the avatar; its leading margin, 16pt, is the one Spotify gives
// the header in a right to left language. The pills stay in the stack with no alpha rather than hidden,
// the way the redesign takes any view out of a stack Spotify arranges (Kit/SGRRestyle.h).
//
// The title is Spotify's own name for the tab, read off its tab bar item (id=TabBar.Item.Home, 10.txt:3100),
// so it follows the app's language.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/MusicRecognition/SGMusicRecognition.h"
#import "Home.h"

// Tries at finding the tab's name before settling for the English one: a miss walks the window.
static const NSUInteger kTitleTries = 8;

static char kTitleKey, kTabKey;
static char kHomeFilterKey, kHomeShazamKey;
static NSString *sg_tabName;

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

static NSString *tabName(UIWindow *window) {
    if (sg_tabName || !window) return sg_tabName ?: @"Home";
    static NSUInteger tries;
    if (tries >= kTitleTries) return @"Home";
    tries++;
    UIView *item = SGRFindByIdentifier(window, @"TabBar.Item.Home", &kTabKey);
    __block NSString *name = nil;
    if (item) SGForEachView(item, ^(UIView *v) {
        if (!name && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) name = ((UILabel *)v).text;
    });
    if (!name) {
        if (tries == kTitleTries) SGLog(@"redesign home: the Home tab's name not found, the title stays English");
        return @"Home";
    }
    sg_tabName = [name copy];
    SGLog(@"redesign home: title \"%@\" from the tab bar", sg_tabName);
    return sg_tabName;
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

// The header's views, found once: the page lays out again as it appears, and the walk names classes.
static __weak UIView *sg_header;
static __weak UIStackView *sg_stack;
static __weak UIView *sg_scrim;

@interface SGRHomeHeaderButton : UIControl
@property (nonatomic, copy) void (^action)(void);
- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title;
@end
@implementation SGRHomeHeaderButton {
    SGRGlyphView *_glyph;
}
- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.accessibilityLabel = title;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = 22;
    self.clipsToBounds = YES;
    SGRGlassInside(self, (__bridge const void *)(self), 44);
    _glyph = [[SGRGlyphView alloc] initWithSymbol:symbol pointSize:19 weight:UIImageSymbolWeightSemibold];
    _glyph.tintColor = SGRPrimary();
    [self addSubview:_glyph];
    [self addTarget:self action:@selector(sgr_activate) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _glyph.frame = self.bounds;
}
- (void)sgr_activate { if (self.action) self.action(); }
@end

static void selectHomePill(UIView *header, NSArray<NSString *> *names) {
    __block UIControl *match = nil;
    SGForEachView(header, ^(UIView *view) {
        if (match || ![view isKindOfClass:UIControl.class]) return;
        NSMutableArray<NSString *> *words = [NSMutableArray array];
        if (view.accessibilityLabel.length) [words addObject:view.accessibilityLabel];
        SGForEachView(view, ^(UIView *child) {
            if ([child isKindOfClass:UILabel.class] && ((UILabel *)child).text.length) [words addObject:((UILabel *)child).text];
        });
        NSString *label = [[words componentsJoinedByString:@" "] lowercaseString];
        for (NSString *name in names) if ([label containsString:name.lowercaseString]) { match = (UIControl *)view; break; }
    });
    if (!match) {
        SGLog(@"redesign home: filter pill was not found for %@", [names componentsJoinedByString:@"/"]);
        return;
    }
    [match sendActionsForControlEvents:UIControlEventTouchUpInside];
}

static void showHomeFilters(UIView *header) {
    UIViewController *presenter = SGTopController();
    if (!presenter || presenter.presentedViewController) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *choices = @[
        @[@"Tutti", @[@"All", @"Tutti"]],
        @[@"Musica", @[@"Music", @"Musica"]],
        @[@"Podcast", @[@"Podcast", @"Show", @"Programmi"]],
        @[@"Audiolibri", @[@"Audiobook", @"Audiolibri"]],
    ];
    for (NSArray *choice in choices) {
        [menu addAction:[UIAlertAction actionWithTitle:choice[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            selectHomePill(header, choice[1]);
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = header;
        menu.popoverPresentationController.sourceRect = CGRectMake(18, CGRectGetMidY(header.bounds), 1, 1);
    }
    [presenter presentViewController:menu animated:YES completion:nil];
}

static SGRHomeHeaderButton *headerButton(UIView *header, const void *key, NSString *symbol, NSString *title) {
    SGRHomeHeaderButton *button = objc_getAssociatedObject(header, key);
    if (!button) {
        button = [[SGRHomeHeaderButton alloc] initWithSymbol:symbol title:title];
        objc_setAssociatedObject(header, key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (button.superview != header) [header addSubview:button];
    return button;
}

static BOOL findHeader(UIView *view) {
    if (sg_stack && [sg_stack isDescendantOfView:view]) return YES;
    for (UIView *wrapper in view.subviews) {
        UIView *scrim = childNamed(wrapper, @"GradientView");
        if (scrim) sg_scrim = scrim;
    }
    UIView *header = childNamed(childNamed(view, @"HomeHeaderElement"), @"HomeHeaderView");
    for (UIView *sub in header.subviews) {
        if ([sub isKindOfClass:UIStackView.class]) sg_stack = (UIStackView *)sub;
    }
    sg_header = header;
    if (sg_stack) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign home: header stack not found, header left as Spotify's"); });
    return NO;
}

static void layoutHeader(UIViewController *page) {
    UIView *view = page.viewIfLoaded;
    if (!view || !findHeader(view)) return;
    UIView *header = sg_header;
    UIStackView *stack = sg_stack;
    vanish(sg_scrim);

    static Class faceClass;
    if (!faceClass) faceClass = NSClassFromString(@"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer");
    UIView *face = nil;
    for (UIView *part in stack.arrangedSubviews) {
        if (faceClass && [part isKindOfClass:faceClass]) face = part;
        else vanish(part);
    }
    if (stack.semanticContentAttribute != UISemanticContentAttributeForceRightToLeft) {
        stack.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        [stack setNeedsLayout];
    }
    [stack layoutIfNeeded];

    UILabel *title = titleIn(header);
    NSString *text = tabName(header.window);
    if (![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    SGRHomeHeaderButton *filters = headerButton(header, &kHomeFilterKey, "line.3.horizontal", @"Filtri Home");
    SGRHomeHeaderButton *shazam = headerButton(header, &kHomeShazamKey, "waveform", @"Riconosci una canzone con Shazam");
    filters.action = ^{ showHomeFilters(header); };
    shazam.action = ^{ SGMusicRecognitionStart(); };
    filters.frame = CGRectMake(SGRSideMargin, round(CGRectGetMidY(stack.frame) - 22), 44, 44);
    shazam.frame = CGRectMake(CGRectGetMaxX(filters.frame) + 8, filters.frame.origin.y, 44, 44);
    CGFloat trailing = face ? CGRectGetMinX([stack convertRect:face.frame toView:header]) - SGRGrid : header.bounds.size.width - SGRSideMargin;
    CGFloat height = ceil(font.lineHeight);
    CGFloat titleStart = CGRectGetMaxX(shazam.frame) + SGRGrid;
    CGRect frame = CGRectMake(titleStart, round(CGRectGetMidY(stack.frame) - height / 2), MAX(0, trailing - titleStart), height);
    if (!CGRectEqualToRect(title.frame, frame)) title.frame = frame;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign home: header %@, avatar %@ in the stack %@, title %@, scrim %@", NSStringFromCGRect(header.frame),
              face ? NSStringFromCGRect(face.frame) : @"not found", NSStringFromCGRect(stack.frame), NSStringFromCGRect(frame),
              sg_scrim ? @"found" : @"not found");
    });
}

%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    layoutHeader((UIViewController *)self);
    SGRHomeProbeEnd(SGRHomeProbeHeader, began);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    [((UIViewController *)self).viewIfLoaded setNeedsLayout];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC19Home_FunkisPageImpl20FunkisViewController",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
