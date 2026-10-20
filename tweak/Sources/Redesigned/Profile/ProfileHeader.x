// The personal profile keeps Spotify's existing actions and playlist list. This gives its header the
// artwork-led treatment used on artist pages: the profile picture fills the header behind its original
// avatar, text and buttons, with a dark top scrim and a fade into the redesigned black page.
//
// The target controller is present in the supported Spotify binary as
// Profile_CommonImpl.ProfileHeaderViewController. The tweak only inserts a non-interactive backdrop;
// it leaves Spotify's header content, constraints, hit targets and scroll behavior alone.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kProfileHeroKey, kProfileArtworkKey;

@interface SGRProfileHero : UIView
- (void)followArtwork:(UIImageView *)source;
@end

@implementation SGRProfileHero {
    UIImageView *_picture;
    CAGradientLayer *_scrim;
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

    _scrim = [CAGradientLayer layer];
    _scrim.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.42].CGColor,
                       (id)[UIColor colorWithWhite:0 alpha:0.08].CGColor];
    _scrim.locations = @[@0, @1];
    [self.layer addSublayer:_scrim];

    _dissolve = [CAGradientLayer layer];
    _dissolve.colors = @[(id)UIColor.whiteColor.CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:0.78].CGColor,
                         (id)UIColor.clearColor.CGColor];
    _dissolve.locations = @[@0, @0.62, @1];
    _dissolve.startPoint = CGPointMake(0.5, 0);
    _dissolve.endPoint = CGPointMake(0.5, 1);
    self.layer.mask = _dissolve;
    [self.layer addSublayer:_scrim];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _picture.frame = self.bounds;
    _scrim.frame = CGRectMake(0, 0, self.bounds.size.width, MIN(170, self.bounds.size.height));
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

@end

static UIImageView *profileArtwork(UIView *root) {
    __block UIImageView *best = nil, *empty = nil;
    __block CGFloat bestArea = 0;
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class]) return;
        UIImageView *image = (UIImageView *)view;
        CGFloat area = image.bounds.size.width * image.bounds.size.height;
        if (area <= bestArea || image.bounds.size.width < 64 || image.bounds.size.height < 64) return;
        bestArea = area;
        if (image.image) best = image;
        else empty = image;
    });
    return best ?: empty;
}

%hook _TtC18Profile_CommonImpl27ProfileHeaderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *header = ((UIViewController *)self).viewIfLoaded;
    if (!header || header.bounds.size.width < 120 || header.bounds.size.height < 100) return;

    SGRProfileHero *hero = objc_getAssociatedObject(header, &kProfileHeroKey);
    if (!hero) {
        hero = [[SGRProfileHero alloc] initWithFrame:header.bounds];
        objc_setAssociatedObject(header, &kProfileHeroKey, hero, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hero.superview != header) [header insertSubview:hero atIndex:0];
    else if (header.subviews.firstObject != hero) [header sendSubviewToBack:hero];
    if (!CGRectEqualToRect(hero.frame, header.bounds)) hero.frame = header.bounds;

    UIImageView *artwork = profileArtwork(header);
    [hero followArtwork:artwork];
    if (artwork && !objc_getAssociatedObject(header, &kProfileArtworkKey)) {
        objc_setAssociatedObject(header, &kProfileArtworkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign profile: artwork-led header backdrop installed; Spotify profile controls and content retained");
    }
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
}
