// Artist redesign: the photo's field behind the whole page, with Spotify's Music and Video tabs reachable.
//
// Tree (trees/clean/artist/01.txt:26-40). The page is a TemplateView holding two scroll views of the page's
// size -- PCFFTabLayoutViewController.overlayScrollView and .containerScrollView -- and the container's stack:
// the header, then PCFFTabLayoutViewController.tabsViewAccessibilityID, the strip of tabs
// (Components.UI.TabsSectionHeading, 44pt) over a paging scroll view with one list per tab. The field goes
// under all of it, as the page's bottom-most view, and what Spotify paints the page, its lists and its rows
// with -- the base surface -- is kept clear by the Kit's repaint hook while sgr_artistRoot is this page.
//
// The strip is Music, Video and Merch. Keeping it reachable is necessary because Spotify supplies many
// artists' videos only in the Video tab, not as a shelf in the Music list. The page and its video cells stay
// Spotify's; the redesign keeps its own field behind them.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Artist.h"

static NSString *const kPageIdentifier = @"creator-page";

// Above for the bounce at the top of the page, below for the one at the end of it.
static const UIEdgeInsets kBleed = {600, 0, 600, 0};

static char kFieldKey;
static char kArtistTabGroupKey, kArtistTabSelectionKey;

#pragma mark - the page

UIView *SGRArtistPageOf(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kPageIdentifier]) return v;
    }
    return nil;
}

#pragma mark - the page's field

static SGRArtworkField *fieldOn(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        SGRArtworkField *field = objc_getAssociatedObject(v, &kFieldKey);
        if (field) return field;
    }
    return nil;
}

UIColor *SGRArtistFieldColor(UIView *view) {
    SGRArtworkField *field = fieldOn(view);
    return field.fieldColor ?: SGRNeutralField();
}

void SGRArtistSetArtwork(UIView *view, UIImage *image) {
    if (image) [fieldOn(view) setArtwork:image identity:nil animated:YES];
}

static SGRArtworkField *fieldIn(UIView *page) {
    SGRArtworkField *field = objc_getAssociatedObject(page, &kFieldKey);
    if (field) return field;
    field = [[SGRArtworkField alloc] initWithFrame:page.bounds];
    field.bleed = kBleed;
    objc_setAssociatedObject(page, &kFieldKey, field, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakPage = page;
    [field whenColored:^{ SGRRevealMark(weakPage, SGRRevealColor); }];
    SGLog(@"redesign artist: field on the page %.0fx%.0f", page.bounds.size.width, page.bounds.size.height);
    return field;
}

%hook _TtC32CreativeWorkPlatform_TemplateKit12TemplateView
- (void)layoutSubviews {
    %orig;
    UIView *page = (UIView *)self;
    if (![page.accessibilityIdentifier isEqualToString:kPageIdentifier] || page.bounds.size.height < 200) return;
    // The page the repaint hook keeps clear is the one laying out, which is the one on screen.
    sgr_artistRoot = page;
    // Behind a curtain from the first pass (Kit/SGRReveal.h), which the header claims once it lays out the photo
    // header (ArtistHeader.x); a page with a header the redesign does not lay out is shown a moment later.
    SGRRevealHold(page, 0);
    SGRArtworkField *field = fieldIn(page);
    if (field.superview != page) [page insertSubview:field atIndex:0];
    else if (page.subviews.firstObject != field) [page sendSubviewToBack:field];
    if (!CGRectEqualToRect(field.frame, page.bounds)) field.frame = page.bounds;
}
%end

// Each tab's list paints itself the base surface from its own pass, and may have before the page first laid
// out and the repaint hook knew the page; its collection view is a private class whose name carries a build
// hash, so the list view around it -- one public name, one child -- is where it is cleared, as the album's is.
%hook _TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView
- (void)layoutSubviews {
    %orig;
    UIView *list = (UIView *)self;
    if (!SGRArtistPageOf(list)) return;
    if (list.backgroundColor && SGIsBaseSurface(list.backgroundColor.CGColor)) list.backgroundColor = UIColor.clearColor;
    for (UIView *sub in list.subviews) {
        if (sub.backgroundColor && SGIsBaseSurface(sub.backgroundColor.CGColor)) sub.backgroundColor = UIColor.clearColor;
    }
}
%end

#pragma mark - the tab strip

static void showStrip(UIView *strip) {
    if (strip.alpha != 1) strip.alpha = 1;
    if (!strip.userInteractionEnabled) strip.userInteractionEnabled = YES;
    strip.accessibilityElementsHidden = NO;
    for (UIView *v in strip.superview.subviews) {
        if (![v isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *pages = (UIScrollView *)v;
        if (!pages.scrollEnabled) pages.scrollEnabled = YES;
        if (!CGAffineTransformIsIdentity(pages.transform)) pages.transform = CGAffineTransformIdentity;
    }
    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"redesign artist: Spotify's Music and Video tabs are reachable");
    }
}

static UILabel *tabTitleLabel(UIView *button) {
    __block UILabel *label = nil;
    SGForEachView(button, ^(UIView *view) {
        if (!label && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) label = (UILabel *)view;
    });
    return label;
}

static BOOL tabIsSelected(UIView *button) {
    if ([button respondsToSelector:@selector(isSelected)] && ((BOOL (*)(id, SEL))objc_msgSend)(button, @selector(isSelected))) return YES;
    return (button.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
}

static CGFloat tabBrightness(UIView *button) {
    UILabel *label = tabTitleLabel(button);
    if (!label) return 0;
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![label.textColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0;
        if (![label.textColor getWhite:&white alpha:&alpha]) return 0;
        red = green = blue = white;
    }
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha;
}

static void styleArtistTabs(UIView *strip) {
    Class tabClass = NSClassFromString(@"_TtCOOOE16PodcastUI_ECMKitO19LegacyUI_ECMCoreKit10Components18TabsSectionHeading2UI7Private9TabButton");
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *view in strip.subviews) {
        if (tabClass && [view isKindOfClass:tabClass]) [buttons addObject:view];
    }
    if (!buttons.count || strip.bounds.size.width <= 0) return;
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // A compact, centered segmented control, like Apple Music's artist navigation. Keep Spotify's tab
    // controls and their recognizers; only change their frames and visual state.
    CGFloat gap = 3, width = 92, height = CGRectGetHeight(strip.bounds);
    CGFloat groupWidth = width * buttons.count + gap * (buttons.count - 1);
    if (groupWidth > CGRectGetWidth(strip.bounds) - 24) {
        gap = 2;
        width = floor((CGRectGetWidth(strip.bounds) - 24 - gap * (buttons.count - 1)) / buttons.count);
        groupWidth = width * buttons.count + gap * (buttons.count - 1);
    }
    CGFloat x = round((CGRectGetWidth(strip.bounds) - groupWidth) / 2);
    CAShapeLayer *group = objc_getAssociatedObject(strip, &kArtistTabGroupKey);
    if (!group) {
        group = [CAShapeLayer layer];
        group.name = @"spoti.pw.artist-tabs-background";
        objc_setAssociatedObject(strip, &kArtistTabGroupKey, group, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [strip.layer insertSublayer:group atIndex:0];
    }
    CGRect groupFrame = CGRectMake(x - 3, 3, groupWidth + 6, MAX(0, height - 6));
    group.frame = groupFrame;
    group.path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, groupFrame.size}
                                            cornerRadius:groupFrame.size.height / 2].CGPath;
    group.fillColor = [UIColor colorWithWhite:1 alpha:0.09].CGColor;
    group.strokeColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    group.lineWidth = 0.75;
    NSUInteger explicitSelection = NSNotFound, brightestIndex = 0;
    CGFloat brightest = -1;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        UIView *button = buttons[index];
        CGRect frame = CGRectMake(x + index * (width + gap), 0, width, height);
        if (!CGRectEqualToRect(button.frame, frame)) button.frame = frame;
        UILabel *label = tabTitleLabel(button);
        if (label) {
            UIFont *font = SGRFont(UIFontTextStyleHeadline, UIFontWeightSemibold, UIContentSizeCategoryExtraLarge);
            if (![label.font isEqual:font]) label.font = font;
            label.textAlignment = NSTextAlignmentCenter;
            if (label.superview == button) {
                label.autoresizingMask |= UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                if (!CGRectEqualToRect(label.frame, button.bounds)) label.frame = button.bounds;
            }
        }
        CGFloat brightness = tabBrightness(button);
        if (tabIsSelected(button)) explicitSelection = index;
        if (brightness > brightest) {
            brightest = brightness;
            brightestIndex = index;
        }
    }
    NSUInteger selectedIndex = explicitSelection == NSNotFound ? brightestIndex : explicitSelection;

    for (NSUInteger index = 0; index < buttons.count; index++) {
        UIView *button = buttons[index];
        BOOL selected = index == selectedIndex;
        UILabel *label = tabTitleLabel(button);
        UIColor *color = selected ? SGRPrimary() : SGRSecondary();
        if (label && ![label.textColor isEqual:color]) label.textColor = color;
        CAShapeLayer *selection = objc_getAssociatedObject(button, &kArtistTabSelectionKey);
        if (!selection) {
            selection = [CAShapeLayer layer];
            selection.name = @"spoti.pw.artist-tab-selection";
            objc_setAssociatedObject(button, &kArtistTabSelectionKey, selection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [button.layer insertSublayer:selection atIndex:0];
        }
        CGRect frame = CGRectInset(button.bounds, 2, 2);
        selection.frame = frame;
        selection.path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, frame.size}
                                                   cornerRadius:frame.size.height / 2].CGPath;
        selection.fillColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        selection.hidden = !selected;
    }
}

// The strip's buttons are the one class of it Spotify names, and they lay out whenever the strip does.
%hook _TtCOOOE16PodcastUI_ECMKitO19LegacyUI_ECMCoreKit10Components18TabsSectionHeading2UI7Private9TabButton
- (void)layoutSubviews {
    %orig;
    for (UIView *v = ((UIView *)self).superview; v; v = v.superview) {
        if (![v.accessibilityIdentifier isEqualToString:@"Components.UI.TabsSectionHeading"]) continue;
        if (SGRArtistPageOf(v)) {
            showStrip(v);
            styleArtistTabs(v);
        }
        return;
    }
}
%end

%ctor {
    // No flags forced here. `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of
    // the header's row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view of a line
    // that has none and traps as the page opens (device crash 2026-09-18 19:09, SIGTRAP in -[OverflowStackView
    // updateConstraints], OverflowStackViewLayoutBuilder.Line.tallestView nil). The row stays Spotify's, and
    // ArtistHeader.x draws more itself.
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC32CreativeWorkPlatform_TemplateKit12TemplateView",
        @"_TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView",
        @"_TtCOOOE16PodcastUI_ECMKitO19LegacyUI_ECMCoreKit10Components18TabsSectionHeading2UI7Private9TabButton",
    ]);
}
