// The player's background on Mod Settings' Player page: Fluid artwork or Animated artwork picked in place,
// and under it the settings of the one picked: Fluid artwork's sliders under a preview drawn by the same
// renderer as the player's field, or Animated artwork's sources.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Player.h"

NSNotificationName const SGRPlayerFluidLookDidChangeNotification = @"spotifyglass.redesign.player.fluidLookDidChange";
NSNotificationName const SGRPlayerBackgroundDidChangeNotification = @"spotifyglass.redesign.player.backgroundDidChange";

static const SGRPlayerBackground kDefaultBackground = SGRPlayerBackgroundFluid;

// A slider of the page: its key, range, step and default, in the whole numbers it stores.
typedef struct {
    __unsafe_unretained NSString *key, *title;
    NSInteger minimum, maximum, step, fallback;
    BOOL percent;
} SGRFluidSlider;

static const SGRFluidSlider kSpeed = {SGRKeyFluidSpeed, @"Speed", 25, 300, 25, 100, YES};
static const SGRFluidSlider kWarp = {SGRKeyFluidWarp, @"Warp", 0, 100, 5, 100, YES};
static const SGRFluidSlider kBlur = {SGRKeyFluidBlur, @"Blur", 2, 24, 1, 8, NO};
static const SGRFluidSlider kSaturation = {SGRKeyFluidSaturation, @"Saturation", 0, 250, 10, 150, YES};
static const SGRFluidSlider kBrightness = {SGRKeyFluidBrightness, @"Brightness", 40, 150, 5, 100, YES};

static NSInteger stored(SGRFluidSlider slider) {
    return MAX(slider.minimum, MIN(slider.maximum, SGInt(slider.key, slider.fallback)));
}

// Still artwork, Colour flow and the Moving background switch are gone, and whatever they stored reads as
// Fluid artwork, the default: the old keys only have to go.
static void migrate(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[SGRKeyPlayerBackgroundWas, SGRKeyPlayerMotionWas]) {
        id was = [store objectForKey:key];
        if (!was) continue;
        [store removeObjectForKey:key];
        SGLog(@"redesign player: %@ was %@, now Fluid artwork", key, was);
    }
}

SGRPlayerBackground SGRPlayerBackgroundStyle(void) {
    migrate();
    NSInteger style = SGInt(SGRKeyPlayerBackground, kDefaultBackground);
    return style >= SGRPlayerBackgroundFluid && style <= SGRPlayerBackgroundMosaic ? (SGRPlayerBackground)style : kDefaultBackground;
}

void SGRPlayerSetBackgroundStyle(SGRPlayerBackground style) {
    if (style < SGRPlayerBackgroundFluid || style > SGRPlayerBackgroundMosaic || style == SGRPlayerBackgroundStyle()) return;
    SGSetInt(SGRKeyPlayerBackground, style);
    [NSNotificationCenter.defaultCenter postNotificationName:SGRPlayerBackgroundDidChangeNotification object:nil];
    SGRPlayerHoldField();
    SGRPlayerVisualiserUpdate();
    SGRPlayerTextShadowsChanged();
}

SGRWarpLook SGRPlayerFluidLook(void) {
    return (SGRWarpLook){
        .speed = stored(kSpeed) / 100.0f,
        .warp = stored(kWarp) / 100.0f,
        .blur = stored(kBlur),
        .saturation = stored(kSaturation) / 100.0f,
        .brightness = stored(kBrightness) / 100.0f,
    };
}

static void lookChanged(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGRPlayerFluidLookDidChangeNotification object:nil];
}

#pragma mark - the preview

static const CGFloat kPreviewHeight = 240, kPreviewRadius = 26;

// A band across the middle of the player at the player's own scale, so the blur and the warp look the
// size they will there.
@interface SGRFluidPreview : SGRWarpView
@end

@interface SGRPlayerStylePreview : UIView
@end

@implementation SGRPlayerStylePreview {
    SGRFluidPreview *_fluid;
    UIView *_visualiser;
    UILabel *_caption;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.layer.cornerRadius = kPreviewRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1];
    _fluid = [[SGRFluidPreview alloc] initWithFrame:self.bounds];
    [self addSubview:_fluid];
    _caption = [UILabel new];
    _caption.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _caption.textColor = UIColor.whiteColor;
    _caption.textAlignment = NSTextAlignmentCenter;
    _caption.backgroundColor = [UIColor colorWithWhite:0 alpha:0.46];
    _caption.layer.cornerRadius = 11;
    _caption.clipsToBounds = YES;
    _caption.hidden = YES;
    [self addSubview:_caption];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateStyle) name:SGRPlayerBackgroundDidChangeNotification object:nil];
    [self updateStyle];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    _fluid.frame = self.bounds;
    _visualiser.frame = self.bounds;
    CGSize captionSize = [_caption sizeThatFits:CGSizeMake(self.bounds.size.width - 24, 30)];
    _caption.frame = CGRectMake(12, self.bounds.size.height - 42, MIN(self.bounds.size.width - 24, captionSize.width + 20), 28);
    _caption.center = CGPointMake(CGRectGetMidX(self.bounds), _caption.center.y);
}

- (void)updateStyle {
    SGRPlayerBackground style = SGRPlayerBackgroundStyle();
    BOOL visual = style == SGRPlayerBackgroundVisualiser || style == SGRPlayerBackgroundMosaic;
    if (visual && !_visualiser) {
        _visualiser = SGRPlayerVisualiserPreview();
        [self addSubview:_visualiser];
    } else if (!visual && _visualiser) {
        [_visualiser removeFromSuperview];
        _visualiser = nil;
    }
    if (visual) SGRPlayerVisualiserPreviewSetMosaic(_visualiser, style == SGRPlayerBackgroundMosaic);
    _caption.hidden = style != SGRPlayerBackgroundAnimated;
    _caption.text = @"Canvas / animated artwork";
    [self setNeedsLayout];
}
@end

@interface SGRPlayerBackgroundPicker : UIView
@end

@implementation SGRPlayerBackgroundPicker {
    UISegmentedControl *_segments;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _segments = [[UISegmentedControl alloc] initWithItems:@[@"Fluid", @"Animated", @"Visualizer", @"Mosaic"]];
    _segments.apportionsSegmentWidthsByContent = YES;
    _segments.selectedSegmentIndex = SGRPlayerBackgroundStyle();
    _segments.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.24];
    _segments.tintColor = SGRPrimary();
    [_segments setTitleTextAttributes:@{NSForegroundColorAttributeName: SGRPrimary(), NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]} forState:UIControlStateNormal];
    [_segments setTitleTextAttributes:@{NSForegroundColorAttributeName: SGRPrimary(), NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    [_segments addTarget:self action:@selector(picked) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_segments];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSelection) name:SGRPlayerBackgroundDidChangeNotification object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)layoutSubviews { [super layoutSubviews]; _segments.frame = self.bounds; }
- (void)picked { SGRPlayerSetBackgroundStyle((SGRPlayerBackground)_segments.selectedSegmentIndex); }
- (void)updateSelection { _segments.selectedSegmentIndex = SGRPlayerBackgroundStyle(); }
@end

@implementation SGRFluidPreview {
    CGSize _laidOutFor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layer.cornerRadius = kPreviewRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.warpLayer.look = SGRPlayerFluidLook();
    [self showArtwork];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(showLook) name:SGRPlayerFluidLookDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(showArtwork) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (CGSizeEqualToSize(size, _laidOutFor) || size.width < 1) return;
    _laidOutFor = size;
    CGSize screen = self.window.bounds.size.width > 0 ? self.window.bounds.size : UIScreen.mainScreen.bounds.size;
    CGFloat pictureHeight = size.width * screen.height / MAX(1, screen.width);
    self.warpLayer.pictureFrame = CGRectMake(0, (size.height - pictureHeight) / 2, size.width, pictureHeight);
}

- (void)showLook {
    self.warpLayer.look = SGRPlayerFluidLook();
}

- (void)showArtwork {
    UIImage *artwork = SGRNowPlayingArtwork(NULL, NULL);
    [self.warpLayer setArtwork:artwork ?: SGRWarpSampleArtwork() animated:self.window != nil];
}

@end

#pragma mark - the rows

static SGModRow *sliderRow(SGRFluidSlider slider) {
    return SGSliderRow(slider.title, nil, slider.minimum, slider.maximum, slider.step,
        ^double { return stored(slider); },
        ^(double value) {
            SGSetInt(slider.key, lround(value));
            lookChanged();
        },
        ^NSString *(double value) {
            return slider.percent ? [NSString stringWithFormat:@"%ld%%", lround(value)] : [NSString stringWithFormat:@"%ld", lround(value)];
        });
}

static NSArray<SGModRow *> *shownFor(SGRPlayerBackground background, NSArray<SGModRow *> *rows) {
    for (SGModRow *row in rows) row.visible = ^BOOL { return SGRPlayerBackgroundStyle() == background; };
    return rows;
}

NSArray<SGModSection *> *SGRPlayerBackgroundSections(void) {
    migrate();
    SGModRow *picker = SGViewRow([SGRPlayerBackgroundPicker new], 40);
    SGModRow *preview = SGViewRow([SGRPlayerStylePreview new], kPreviewHeight);
    NSArray<SGModRow *> *sliders = @[sliderRow(kSpeed), sliderRow(kWarp), sliderRow(kBlur), sliderRow(kSaturation), sliderRow(kBrightness)];
    SGModRow *reset = SGActionRow(@"Reset", nil, ^{
        for (NSString *key in @[SGRKeyFluidSpeed, SGRKeyFluidWarp, SGRKeyFluidBlur, SGRKeyFluidSaturation, SGRKeyFluidBrightness]) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        }
        lookChanged();
    });
    reset.color = SGRed();
    reset.symbol = @"arrow.counterclockwise";

    SGModRow *sources = SGArtworkSourcesRow(SGRKeyPlayerArtworkSources,
        @"Asked top to bottom until one has a clip. Apple Music gets only the artist and album name.");

    NSArray<SGModRow *> *mosaic = @[
        SGSliderRow(@"Dots across", nil, SGRMosaicDotsLeast, SGRMosaicDotsMost, 1,
                    ^double { return SGRMosaicDots(); },
                    ^(double value) { SGSetInt(SGRKeyMosaicDots, lround(value)); },
                    ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f", value]; }),
        SGSliderRow(@"Dot size", nil, SGRMosaicSizeLeast, SGRMosaicSizeMost, 1,
                    ^double { return SGRMosaicSize(); },
                    ^(double value) { SGSetInt(SGRKeyMosaicSize, lround(value)); },
                    ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; }),
        SGSwitchRow(@"Shadow under text", nil, SGRKeyMosaicTextShadow),
    ];

    return @[
        SGNotedSection(@"Background", @[picker], @"Fluid warps the cover, Animated shows Canvas, Visualizer follows the sound, and Mosaic turns the cover colors into a reactive grid."),
        SGSection(nil, @[preview]),
        SGNotedSection(nil, shownFor(SGRPlayerBackgroundFluid, sliders),
                       @"The player follows these as they move. Brightness past 100% can make white text harder to read on a light cover."),
        SGSection(nil, shownFor(SGRPlayerBackgroundFluid, @[reset])),
        SGNotedSection(nil, shownFor(SGRPlayerBackgroundAnimated, @[sources]),
                       @"A track without a clip shows Fluid artwork, and so does every track in Low Power Mode or with Reduce Motion on."),
        SGNotedSection(nil, shownFor(SGRPlayerBackgroundMosaic, mosaic),
                       @"Adjust the grid density and light size. Text shadow improves contrast over bright dots."),
    ];
}
