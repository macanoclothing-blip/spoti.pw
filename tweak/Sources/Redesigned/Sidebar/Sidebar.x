#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kSidebarTitleKey, kSidebarCloseKey, kSidebarTopCardKey, kSidebarRowsCardKey;
static char kSidebarHeaderTransformKey, kSidebarListTransformKey, kSidebarProfileTransformKey, kSidebarAddTransformKey;
static char kSidebarProfileChevronKey, kSidebarCellChevronKey, kSidebarSeparatorKey, kSidebarSectionSeparatorKey;
static char kSidebarModSeparatorKey, kSidebarAddCellKey;
static char kSidebarClipMaskKey;

static const CGFloat kSidebarAddRowHeight = 58;
static const CGFloat kSidebarContentInset = 16;
// Tag per riconoscere le view create da noi (separatori) ed escluderle dalla pulizia delle linee native
static const NSInteger kSidebarOwnedTag = 9071;

static UIView *sidebarFind(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) containsString:className]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = sidebarFind(child, className);
        if (found) return found;
    }
    return nil;
}

static UIView *sidebarFindID(UIView *root, NSString *identifier) {
    if (!root) return nil;
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = sidebarFindID(child, identifier);
        if (found) return found;
    }
    return nil;
}

static void sidebarSetTranslation(UIView *view, const void *key, CGFloat x, CGFloat y) {
    if (!view) return;
    NSValue *stored = objc_getAssociatedObject(view, key);
    CGAffineTransform base = stored ? stored.CGAffineTransformValue : view.transform;
    if (!stored) {
        objc_setAssociatedObject(view, key, [NSValue valueWithCGAffineTransform:base],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform moved = CGAffineTransformTranslate(base, x, y);
    if (!CGAffineTransformEqualToTransform(view.transform, moved)) view.transform = moved;
}

static UIView *sidebarCard(UIView *host, const void *key) {
    UIView *card = objc_getAssociatedObject(host, key);
    if (!card) {
        card = [UIView new];
        card.userInteractionEnabled = NO;
        card.accessibilityElementsHidden = YES;
        card.backgroundColor = SGRElevated(UIColor.blackColor);
        card.layer.cornerRadius = 24;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(host, key, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (card.superview != host) [host insertSubview:card atIndex:0];
    return card;
}

static UIView *sidebarSeparator(UIView *host, UIView *owner, const void *key, CGRect frame) {
    UIView *separator = objc_getAssociatedObject(owner, key);
    if (!separator) {
        separator = [UIView new];
        separator.tag = kSidebarOwnedTag;
        separator.userInteractionEnabled = NO;
        separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        objc_setAssociatedObject(owner, key, separator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (separator.superview != host) [host addSubview:separator];
    separator.frame = frame;
    [host bringSubviewToFront:separator];
    return separator;
}

static UIImageView *sidebarChevron(UIView *host, const void *key, CGFloat extraX) {
    UIImageView *chevron = objc_getAssociatedObject(host, key);
    if (!chevron) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        chevron = [[UIImageView alloc] initWithImage:
                   [[UIImage systemImageNamed:@"chevron.right" withConfiguration:configuration]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        chevron.tintColor = SGRTertiary();
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        chevron.userInteractionEnabled = NO;
        objc_setAssociatedObject(host, key, chevron, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:chevron];
    }
    chevron.frame = CGRectMake(CGRectGetWidth(host.bounds) - 34 + extraX,
                               round((CGRectGetHeight(host.bounds) - 18) / 2), 10, 18);
    return chevron;
}

@interface SGRSidebarCloseButton : UIButton
@end

@implementation SGRSidebarCloseButton
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    self.layer.cornerRadius = 22;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    [self setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:configuration]
          forState:UIControlStateNormal];
    self.tintColor = SGRPrimary();
    self.accessibilityLabel = @"Chiudi account";
    [self addTarget:self action:@selector(sgr_close) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)sgr_close {
    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    UIViewController *drawer = (UIViewController *)responder;
    while (drawer && !drawer.presentingViewController) drawer = drawer.parentViewController;
    [drawer dismissViewControllerAnimated:YES completion:nil];
}
@end

static UIView *sidebarHost(UIView *header, UICollectionView *list) {
    for (UIView *candidate = header; candidate; candidate = candidate.superview) {
        if ([list isDescendantOfView:candidate]) return candidate;
    }
    return nil;
}

static BOOL sidebarCellMatches(UIView *cell, NSString *identifier) {
    return sidebarFindID(cell, identifier) != nil;
}

// Restringe la cella dal lato sinistro usando i frame del layout, così il valore
// è identico a ogni passata e Spotify non può resettarlo.
static void sidebarInsetCell(UICollectionView *list, UICollectionViewCell *cell) {
    NSIndexPath *indexPath = [list indexPathForCell:cell];
    if (!indexPath) return;
    UICollectionViewLayoutAttributes *attributes =
        [list.collectionViewLayout layoutAttributesForItemAtIndexPath:indexPath];
    if (!attributes) return;

    CGRect frame = attributes.frame;
    CGFloat width = MAX(0, CGRectGetWidth(frame) - kSidebarContentInset);
    CGRect bounds = CGRectMake(0, 0, width, CGRectGetHeight(frame));
    CGPoint center = CGPointMake(CGRectGetMinX(frame) + kSidebarContentInset + width / 2,
                                 CGRectGetMidY(frame));
    if (!CGRectEqualToRect(cell.bounds, bounds)) cell.bounds = bounds;
    if (!CGPointEqualToPoint(cell.center, center)) cell.center = center;
    cell.clipsToBounds = NO;
}

static void sidebarStyleCell(UIView *cell) {
    UIView *account = sidebarFindID(cell, @"AccountSwitching.AddAccountRow");
    UIView *row = account ?: sidebarFindID(cell, @"Components.UI.NavigationRowSideDrawer");
    if (!row) row = sidebarFindID(cell, @"Components.UI.YourPlanRowSideDrawer");
    if (!row) return;

    UIView *content = ((UICollectionViewCell *)cell).contentView;
    cell.backgroundColor = UIColor.clearColor;
    content.backgroundColor = UIColor.clearColor;
    row.backgroundColor = UIColor.clearColor;
    row.layer.cornerRadius = 0;
    row.clipsToBounds = NO;

    if (account) {
        SGForEachView(account, ^(UIView *view) {
            if (![view isKindOfClass:UILabel.class]) return;
            NSString *text = ((UILabel *)view).text.lowercaseString;
            if ([text containsString:@"bambino"] || [text containsString:@"altra persona"]) {
                view.alpha = 0;
                view.hidden = YES; // collassa lo spazio nello stack
                view.accessibilityElementsHidden = YES;
            }
        });
    }
}

// Chevron della cella: stessa x (in coordinate host) di quella del profilo e di Chroma Settings,
// quindi dentro il box grigio. Il calcolo passa dall'host così non dipende dall'inset della cella.
static void sidebarPlaceCellChevron(UIView *host, UICollectionViewCell *cell) {
    UIImageView *chevron = sidebarChevron(cell, &kSidebarCellChevronKey, 0);
    CGPoint origin = [host convertPoint:CGPointMake(CGRectGetWidth(host.bounds) - 34, 0) toView:cell];
    chevron.frame = CGRectMake(origin.x, round((CGRectGetHeight(cell.bounds) - 18) / 2), 10, 18);
    [cell bringSubviewToFront:chevron];
}

// "Aggiungi account": dopo aver nascosto la sottoriga la label restava in alto nella riga;
// la centriamo verticalmente rispetto alla riga (e quindi all'icona +).
static void sidebarCenterAddLabel(UIView *host, UICollectionViewCell *cell) {
    UIView *account = sidebarFindID(cell, @"AccountSwitching.AddAccountRow");
    if (!account) return;
    __block UILabel *label = nil;
    SGForEachView(account, ^(UIView *view) {
        if (label || ![view isKindOfClass:UILabel.class] || view.hidden || view.alpha == 0) return;
        if (((UILabel *)view).text.length) label = (UILabel *)view;
    });
    if (!label) return;
    CGFloat cellMid = CGRectGetMidY([cell convertRect:cell.bounds toView:host]);
    CGFloat labelMid = CGRectGetMidY([label convertRect:label.bounds toView:host]);
    CGFloat delta = cellMid - labelMid;
    if (fabs(delta) > 0.5) label.transform = CGAffineTransformTranslate(label.transform, 0, delta);
}

// Riga del piano: il badge (es. "Eevee") arrivava fino al bordo del box e finirebbe sotto
// la chevron spostata. Lo teniamo a sinistra della chevron.
static void sidebarKeepPillClearOfChevron(UIView *host, UICollectionViewCell *cell) {
    UIView *row = sidebarFindID(cell, @"Components.UI.YourPlanRowSideDrawer");
    if (!row) return;
    __block UILabel *last = nil;
    __block CGFloat maxX = -CGFLOAT_MAX;
    SGForEachView(row, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class] || view.hidden || view.alpha == 0) return;
        CGFloat x = CGRectGetMaxX([view convertRect:view.bounds toView:host]);
        if (x > maxX) { maxX = x; last = (UILabel *)view; }
    });
    if (!last) return;
    // Il rosa è lo sfondo di un contenitore del testo: risali dalla label fino alla riga e
    // sposta il primo antenato con sfondo visibile (altrimenti si sposta solo il testo e viene tagliato).
    UIView *pill = nil, *topmostSmall = nil;
    for (UIView *view = last.superview; view && view != row && view != cell.contentView && view != cell;
         view = view.superview) {
        if (CGRectGetWidth(view.bounds) >= CGRectGetWidth(row.bounds) * 0.6) break;
        topmostSmall = view;
        CGFloat alpha = 0;
        if (view.backgroundColor) [view.backgroundColor getRed:NULL green:NULL blue:NULL alpha:&alpha];
        if (!pill && alpha > 0.05) pill = view;
    }
    if (!pill) pill = topmostSmall ?: last;
    // se il testo era già stato spostato da solo, ripristinalo
    if (pill != last && !CGAffineTransformIsIdentity(last.transform)) last.transform = CGAffineTransformIdentity;
    CGFloat limit = CGRectGetWidth(host.bounds) - 34 - 8; // bordo sinistro della chevron meno 8pt
    CGFloat pillMax = CGRectGetMaxX([pill convertRect:pill.bounds toView:host]);
    CGFloat delta = limit - pillMax;
    if (delta < -0.5) pill.transform = CGAffineTransformTranslate(pill.transform, delta, 0);
}

// Nasconde la parte della view che sta sopra clipTop (coordinate host), così durante lo
// scroll le celle non si sovrappongono alla card del profilo / riga "Aggiungi account".
static void sidebarClipAbove(UIView *host, UIView *view, CGFloat clipTop) {
    CGRect frame = [view convertRect:view.bounds toView:host];
    CGFloat cut = clipTop - CGRectGetMinY(frame);
    CALayer *mask = objc_getAssociatedObject(view, &kSidebarClipMaskKey);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (cut <= 0) {
        if (mask && view.layer.mask == mask) view.layer.mask = nil;
    } else {
        if (!mask) {
            mask = [CALayer layer];
            mask.backgroundColor = UIColor.blackColor.CGColor;
            objc_setAssociatedObject(view, &kSidebarClipMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGSize size = view.bounds.size;
        mask.frame = CGRectMake(-50, cut, size.width + 100, MAX(0, size.height - cut));
        if (view.layer.mask != mask) view.layer.mask = mask;
    }
    [CATransaction commit];
}

// Nasconde le linee sottili a tutta larghezza create da Spotify (non i nostri separatori).
// Solo foglie (nessuna subview) con altezza tra 0.25 e 1.5pt: i contenitori con altezza 0
// non devono mai essere nascosti, altrimenti spariscono anche i loro figli.
static void sidebarHideStrayLines(UIView *host, UIView *header) {
    CGFloat hostWidth = CGRectGetWidth(host.bounds);
    SGForEachView(header, ^(UIView *view) {
        if (view == header || view.tag == kSidebarOwnedTag || view.subviews.count > 0) return;
        if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UIControl.class] || [view isKindOfClass:UIScrollView.class]) return;
        CGRect frame = [view convertRect:view.bounds toView:host];
        CGFloat height = CGRectGetHeight(frame);
        if (height >= 0.25 && height <= 1.5 && CGRectGetWidth(frame) >= hostWidth * 0.8) view.hidden = YES;
    });
}

static void sidebarApply(UIViewController *controller) {
    UIView *header = sidebarFind(controller.view, @"ReflowingHeaderStackView");
    UICollectionView *list = (UICollectionView *)sidebarFind(controller.view, @"SideDrawerListCollectionView");
    if (![list isKindOfClass:UICollectionView.class] || !header) return;

    UIView *host = sidebarHost(header, list);
    if (!host) return;
    [UIView performWithoutAnimation:^{
    host.backgroundColor = UIColor.blackColor;
    list.backgroundColor = UIColor.clearColor;
    list.opaque = NO;
    list.clipsToBounds = NO; // la cella Add account viene spostata sopra il bordo della lista
    list.backgroundView.backgroundColor = UIColor.clearColor;
    header.backgroundColor = UIColor.clearColor;
    UIView *profile = sidebarFind(header, @"SideDrawerProfileElement");
    sidebarSetTranslation(header, &kSidebarHeaderTransformKey, 0, 45);
    sidebarSetTranslation(list, &kSidebarListTransformKey, 0, 45);
    sidebarSetTranslation(profile, &kSidebarProfileTransformKey, kSidebarContentInset, 0);

    UILabel *title = objc_getAssociatedObject(host, &kSidebarTitleKey);
    if (!title) {
        title = [UILabel new];
        title.text = @"Account";
        title.textColor = SGRPrimary();
        title.font = SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryLarge);
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(host, &kSidebarTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:title];
    }
    title.frame = CGRectMake(16, 49, MAX(0, CGRectGetWidth(host.bounds) - 88), 40);

    SGRSidebarCloseButton *close = objc_getAssociatedObject(host, &kSidebarCloseKey);
    if (!close) {
        close = [[SGRSidebarCloseButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(host, &kSidebarCloseKey, close, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:close];
    }
    close.frame = CGRectMake(CGRectGetWidth(host.bounds) - 60, 45, 44, 44);

    if (profile) sidebarChevron(header, &kSidebarProfileChevronKey, 0);

    CGRect profileFrame = profile ? [profile convertRect:profile.bounds toView:host] : CGRectNull;
    CGFloat hostWidth = CGRectGetWidth(host.bounds);

    CGRect rowsFrame = CGRectNull;
    NSMutableArray<UICollectionViewCell *> *navigationCells = [NSMutableArray array];
    UICollectionViewCell *addAccountCell = nil;
    UICollectionViewCell *planCell = nil;
    for (UICollectionViewCell *cell in list.visibleCells) {
        BOOL account = sidebarCellMatches(cell, @"AccountSwitching.AddAccountRow");
        BOOL plan = sidebarCellMatches(cell, @"Components.UI.YourPlanRowSideDrawer");
        BOOL nav = sidebarCellMatches(cell, @"Components.UI.NavigationRowSideDrawer");

        if (account) addAccountCell = cell;
        if (plan) planCell = cell;
        if (!account && !plan && !nav) continue;
        sidebarInsetCell(list, cell);
        sidebarStyleCell(cell);
        sidebarPlaceCellChevron(host, cell);
        if (plan) sidebarKeepPillClearOfChevron(host, cell);
        if (account) continue;
        CGRect frame = [cell convertRect:cell.bounds toView:host];
        rowsFrame = CGRectIsNull(rowsFrame) ? frame : CGRectUnion(rowsFrame, frame);
        [navigationCells addObject:cell];
    }
    // visibleCells non è ordinato
    [navigationCells sortUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        return [@(a.center.y) compare:@(b.center.y)];
    }];

    // --- Add account: spostala subito sotto il profilo ---
    CGRect topFrame = profileFrame;
    if (addAccountCell && profile && !CGRectIsNull(profileFrame)) {
        objc_setAssociatedObject(list, &kSidebarAddCellKey, addAccountCell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGSize size = addAccountCell.bounds.size;
        CGRect natural = [list convertRect:CGRectMake(addAccountCell.center.x - size.width / 2,
                                                       addAccountCell.center.y - size.height / 2,
                                                       size.width, size.height)
                                    toView:host];
        CGFloat targetCenterY = CGRectGetMaxY(profileFrame) + kSidebarAddRowHeight / 2;
        sidebarSetTranslation(addAccountCell, &kSidebarAddTransformKey, 0, targetCenterY - CGRectGetMidY(natural));
        // la cella è ora in posizione: centra la label rispetto alla riga
        sidebarCenterAddLabel(host, addAccountCell);
        topFrame = CGRectMake(0, CGRectGetMinY(profileFrame), hostWidth,
                              CGRectGetHeight(profileFrame) + kSidebarAddRowHeight);
    }

    if (!CGRectIsNull(topFrame)) {
        UIView *topCard = sidebarCard(host, &kSidebarTopCardKey);
        // Keep the profile card behind the account row. The row is a real
        // collection cell and must remain visible while it is translated below
        // the profile.
        topCard.frame = CGRectMake(16, CGRectGetMinY(topFrame), MAX(0, hostWidth - 32),
                                   CGRectGetHeight(topFrame));
        UIView *profileSeparator = objc_getAssociatedObject(profile, &kSidebarSectionSeparatorKey);
        profileSeparator.hidden = YES;
    }

    // --- Riga Chroma Settings ---
    UIView *modRow = sidebarFind(list, @"SGModSettingsRow");
    if ([modRow isKindOfClass:UIControl.class] && planCell) {
        CGRect planFrame = [planCell convertRect:planCell.bounds toView:host];
        CGRect targetFrame = CGRectMake(16, CGRectGetMinY(planFrame) - 48, MAX(0, hostWidth - 32), 48);
        modRow.frame = [list convertRect:targetFrame fromView:host];
        modRow.autoresizingMask = UIViewAutoresizingNone;
        for (UIView *subview in modRow.subviews) {
            if (![subview isKindOfClass:UIImageView.class]) continue;
            if (CGRectGetWidth(subview.frame) <= 14) {
                subview.hidden = NO;
                subview.tintColor = SGRTertiary();
            }
        }
        CGRect customFrame = [modRow convertRect:modRow.bounds toView:host];
        rowsFrame = CGRectIsNull(rowsFrame) ? customFrame : CGRectUnion(rowsFrame, customFrame);
        sidebarSeparator(host, modRow, &kSidebarModSeparatorKey,
                         CGRectMake(68, CGRectGetMaxY(customFrame) - 0.5, MAX(0, hostWidth - 68 - 32), 0.5));
    }

    // --- Card delle righe ---
    // Tutto ciò che sta sopra clipTop (fondo del profilo + riga Add account) viene ritagliato,
    // così durante lo scroll le celle non passano sopra la parte fissa.
    CGFloat clipTop = CGRectIsNull(topFrame) ? 0 : CGRectGetMaxY(topFrame);
    if (!CGRectIsNull(rowsFrame)) {
        UIView *rowsCard = sidebarCard(host, &kSidebarRowsCardKey);
        CGFloat top = MAX(CGRectGetMinY(rowsFrame), clipTop);
        CGFloat bottom = MIN(CGRectGetMaxY(rowsFrame), CGRectGetHeight(host.bounds));
        rowsCard.hidden = (bottom <= top);
        if (!rowsCard.hidden) {
            rowsCard.frame = CGRectMake(16, top, MAX(0, hostWidth - 32), bottom - top);
        }

        for (NSUInteger index = 0; index < navigationCells.count; index++) {
            UICollectionViewCell *cell = navigationCells[index];
            BOOL plan = sidebarCellMatches(cell, @"Components.UI.YourPlanRowSideDrawer");
            BOOL nav = sidebarCellMatches(cell, @"Components.UI.NavigationRowSideDrawer");
            if (!plan && !nav) continue;
            UIView *row = sidebarFindID(cell, plan ? @"Components.UI.YourPlanRowSideDrawer"
                                                    : @"Components.UI.NavigationRowSideDrawer");
            if (row) row.backgroundColor = UIColor.clearColor;

            sidebarClipAbove(host, cell, clipTop);

            if (index + 1 == navigationCells.count) {
                // ultima riga: niente separatore
                UIView *old = objc_getAssociatedObject(cell, &kSidebarSeparatorKey);
                old.hidden = YES;
                continue;
            }
            CGRect cellFrame = [cell convertRect:cell.bounds toView:host];
            UIView *separator = sidebarSeparator(host, cell, &kSidebarSeparatorKey,
                CGRectMake(68, CGRectGetMaxY(cellFrame) - 0.5, MAX(0, hostWidth - 68 - 32), 0.5));
            // nascondi i separatori che finiscono sotto il profilo / fuori dall'host
            separator.hidden = CGRectGetMinY(separator.frame) < clipTop ||
                               CGRectGetMinY(separator.frame) > CGRectGetHeight(host.bounds);
        }

        if (modRow) {
            sidebarClipAbove(host, modRow, clipTop);
            UIView *modSeparator = objc_getAssociatedObject(modRow, &kSidebarModSeparatorKey);
            modSeparator.hidden = CGRectGetMinY(modSeparator.frame) < clipTop ||
                                  CGRectGetMinY(modSeparator.frame) > CGRectGetHeight(host.bounds);
        }
    }

    // The collection view scrolls underneath this fixed header card. Reassert the
    // stacking order on every pass because UICollectionView may reinsert cells
    // above sibling overlays while it is decelerating.
    UIView *topCard = objc_getAssociatedObject(host, &kSidebarTopCardKey);
    if (topCard) {
        UIView *rowsCard = objc_getAssociatedObject(host, &kSidebarRowsCardKey);
        [host sendSubviewToBack:topCard];
        if (rowsCard) [host sendSubviewToBack:rowsCard];
        [host bringSubviewToFront:list];
        [host bringSubviewToFront:header];
        [host bringSubviewToFront:title];
        [host bringSubviewToFront:close];
    }

    // linea grigia sottile a tutta larghezza sotto il nome account
    sidebarHideStrayLines(host, header);
    }];
}

%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    sidebarApply((UIViewController *)self);
}
%end

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    if (![NSStringFromClass(self.class) containsString:@"SideDrawerListCollectionView"]) return;
    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    if (responder) sidebarApply((UIViewController *)responder);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    if (![NSStringFromClass(self.class) containsString:@"SideDrawerListCollectionView"]) return;
    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    if (responder) sidebarApply((UIViewController *)responder);
}

// la cella "Add account" ora sta fuori dai bounds della lista: inoltra i tap
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    if (hit || ![NSStringFromClass(self.class) containsString:@"SideDrawerListCollectionView"]) return hit;
    UIView *cell = objc_getAssociatedObject(self, &kSidebarAddCellKey);
    if (!cell || cell.hidden || !cell.window) return nil;
    CGPoint local = [cell convertPoint:point fromView:self];
    return [cell pointInside:local withEvent:event] ? [cell hitTest:local withEvent:event] : nil;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC23SideDrawer_ListPageImpl18ListViewController"]);
}
