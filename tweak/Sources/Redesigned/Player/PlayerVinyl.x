// Player redesign: Vinyl mode. When enabled (SGRKeyPlayerVinyl, restart required):
//
//   · The background field (Canvas or Fluid artwork) stays fully visible — no overlay is added.
//   · The NPVBackgroundViewController's plane gets an SGRVinylOverlayView that draws:
//       - A large translucent vinyl disc (≈91 % of width), centred. The disc body is near-black
//         (88 % opacity) so the canvas is faintly visible. Album art fills the centre hole.
//       - Groove rings tinted with the album's edge colour (SGRPalette), lifted so they are
//         legible even on dark artwork.
//       - A tonearm: silver rod pivoting from a dark mount circle in the top-right, angled down
//         to the disc edge. An L-shaped elbow and black cartridge tip at the needle end.
//       - Song title (bold) and artist name, left-aligned below the disc.
//       - Four dark pill buttons at the bottom: PLAY/PAUSE · LYRICS · ← · →
//   · Tap the disc → toggle playback.
//   · Tap LYRICS → opens the redesigned lyrics view. In the lyrics thumbnail the cover image is
//     replaced by a mini spinning vinyl disc (same art, same rotation). Tapping that disc closes
//     lyrics and returns to the vinyl view.
//   · Everything else in the player (artwork cells, controls unit, duration, info, footer) is
//     hidden (alpha = 0). The header unit (close + ⋯) is left untouched.
//
// Threading: main thread only.

#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"
#import "PlayerVinyl.h"

// ─────────────────────────────────────────────────────
#pragma mark - constants
// ─────────────────────────────────────────────────────

// Tonearm angles (degrees, positive = clockwise from 12-o'clock).
static const CGFloat kArmLifted  = 15.0;   // resting position when paused
static const CGFloat kArmOnDisc  = 27.0;   // outermost groove
static const CGFloat kArmEnd     = 46.0;   // innermost groove at song end

// Disc spin rate while playing (33⅓ RPM ≈ 0.555 rev/s).
static const CGFloat kRPSPlaying     = 0.555;
static const NSTimeInterval kCoastDuration = 0.7; // coast duration after pause

// Layout fractions (relative to overlay width).
static const CGFloat kDiscFraction   = 0.91;  // disc diameter
static const CGFloat kHoleFraction   = 0.28;  // album-art hole (of disc diam)
static const CGFloat kArmLengthFrac  = 0.54;  // rod length
static const CGFloat kArmWidth       = 3.5;
static const CGFloat kMountRadius    = 21.0;
static const CGFloat kMountX         = 0.85;  // pivot X fraction of overlay width
static const CGFloat kMountY         = 0.135; // pivot Y fraction of overlay height
static const CGFloat kButtonHeight   = 54.0;
static const CGFloat kButtonBottom   = 48.0;
static const NSUInteger kGrooveCount = 30;

// ─────────────────────────────────────────────────────
#pragma mark - helpers
// ─────────────────────────────────────────────────────

static BOOL vinylOn(void) { return SGFlag(SGRKeyPlayerVinyl, NO); }

static UIImage *vinylDiscTexture(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = [UIImage imageNamed:@"VinylDisc"] ?: [UIImage imageNamed:@"VinylDisc.png"]; });
    return image;
}

static UIImage *vinylTonearmTexture(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = [UIImage imageNamed:@"VinylTonearm"] ?: [UIImage imageNamed:@"VinylTonearm.png"]; });
    return image;
}

static __weak id<SPTPlayer> sg_player;

static void vinylToggle(void) {
    SPTPlayerState *s = SGPlayerState();
    id<SPTPlayer> p = sg_player;
    if (!s || !p) return;
    if (s.isPaused) [p resume:nil]; else [p pause:nil];
}
static void vinylPrev(void) { [sg_player skipToPreviousTrackWithOptions:nil]; }
static void vinylNext(void) { [sg_player skipToNextTrackWithOptions:nil]; }

// Forward-declared here so mini-disc functions defined earlier can reference it.
@class SGRVinylOverlayView;
static __weak SGRVinylOverlayView *sg_vinylOverlay;

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylDiscLayer
// ─────────────────────────────────────────────────────
// Draws the vinyl record as a stack of CALayers.
// Can be used both for the full-size disc and the mini thumbnail in lyrics view.

@interface SGRVinylDiscLayer : CALayer
@property (nonatomic) CGFloat discRadius;
@property (nonatomic) CGFloat holeRadius;
@property (nonatomic, strong) UIColor *tintColor;
- (void)setAlbumArt:(UIImage *)image;
@end

@implementation SGRVinylDiscLayer {
    CALayer         *_bodyLayer;
    CAGradientLayer *_shineLayer;
    NSMutableArray  *_grooveLayers;
    CALayer         *_artLayer;
    CALayer         *_spindleLayer;
    UIColor         *_lastTint;
    CGFloat          _lastR;
    CGFloat          _lastHR;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = NO;
    _grooveLayers = [NSMutableArray array];
    [self _buildBase];
    return self;
}

- (void)_buildBase {
    _bodyLayer = [CALayer layer];
    _bodyLayer.masksToBounds = YES;
    [self addSublayer:_bodyLayer];

    _shineLayer = [CAGradientLayer layer];
    _shineLayer.type = kCAGradientLayerRadial;
    _shineLayer.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.18].CGColor,
                           (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor,
                           (id)[UIColor colorWithWhite:0.30 alpha:0.05].CGColor];
    _shineLayer.startPoint = CGPointMake(0.28, 0.18);
    _shineLayer.endPoint   = CGPointMake(0.92, 0.92);
    [self addSublayer:_shineLayer];

    _artLayer = [CALayer layer];
    _artLayer.masksToBounds = YES;
    _artLayer.contentsGravity = kCAGravityResizeAspectFill;
    [self addSublayer:_artLayer];

    _spindleLayer = [CALayer layer];
    _spindleLayer.backgroundColor = [UIColor colorWithWhite:0.82 alpha:1].CGColor;
    [self addSublayer:_spindleLayer];
}

- (void)setAlbumArt:(UIImage *)image {
    _artLayer.contents = (id)image.CGImage;
    if (!image) {
        _artLayer.contents = nil;
    }
}

- (void)setTintColor:(UIColor *)tintColor {
    _tintColor = tintColor;
    _lastTint = nil;
    [self setNeedsLayout];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGFloat R  = _discRadius;
    CGFloat HR = _holeRadius;
    if (R < 1) return;

    BOOL sizeChanged = (fabs(R - _lastR) > 0.5 || fabs(HR - _lastHR) > 0.5);
    BOOL tintChanged = _lastTint != _tintColor;
    _lastR = R; _lastHR = HR; _lastTint = _tintColor;

    CGFloat D  = 2 * R;
    CGRect disc = CGRectMake(0, 0, D, D);

    self.bounds       = disc;
    self.cornerRadius = R;

    _bodyLayer.frame        = disc;
    _bodyLayer.cornerRadius = R;

    UIColor *vinylBase = _tintColor ?: [UIColor colorWithWhite:0.82 alpha:0.78];
    UIColor *bodyColor = [vinylBase colorWithAlphaComponent:0.58];
    _bodyLayer.backgroundColor = bodyColor.CGColor;

    _shineLayer.frame = disc;
    _shineLayer.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.28].CGColor,
                           (id)[UIColor colorWithWhite:1 alpha:0.00].CGColor,
                           (id)[UIColor colorWithWhite:0.60 alpha:0.02].CGColor,
                           (id)[UIColor colorWithWhite:0.20 alpha:0.12].CGColor];

    if (sizeChanged || tintChanged) [self _rebuildGrooves:R hole:HR];

    CGFloat hD = 2 * HR;
    CGRect holeRect = CGRectMake(R - HR, R - HR, hD, hD);
    _artLayer.frame       = holeRect;
    _artLayer.cornerRadius = HR;

    CGFloat spR = 3.5;
    _spindleLayer.frame        = CGRectMake(R - spR, R - spR, 2 * spR, 2 * spR);
    _spindleLayer.cornerRadius = spR;
}

- (void)_rebuildGrooves:(CGFloat)R hole:(CGFloat)HR {
    for (CALayer *l in _grooveLayers) [l removeFromSuperlayer];
    [_grooveLayers removeAllObjects];

    UIColor *tint = _tintColor ?: [UIColor colorWithWhite:0.35 alpha:1];
    CGFloat h, s, b, a;
    [tint getHue:&h saturation:&s brightness:&b alpha:&a];

    NSUInteger shineIndex = [self.sublayers indexOfObject:_shineLayer];
    CGFloat outer = R - 5;
    CGFloat inner = HR + 7;
    CGFloat step  = (outer - inner) / kGrooveCount;

    for (NSUInteger i = 0; i < kGrooveCount; i++) {
        CGFloat rr = inner + i * step;
        CALayer *ring = [CALayer layer];
        BOOL bright = (i % 2 == 0);
        CGFloat base = MAX(b, 0.18);
        CGFloat bv = bright ? MIN(base + 0.15, 0.44) : MAX(base - 0.07, 0.11);
        CGFloat sv = s * 0.50;
        UIColor *color = [UIColor colorWithHue:h saturation:sv brightness:bv alpha:bright ? 0.82 : 0.65];
        ring.backgroundColor = color.CGColor;
        CGFloat d = 2 * rr;
        ring.frame        = CGRectMake(R - rr, R - rr, d, d);
        ring.cornerRadius = rr;
        [self insertSublayer:ring atIndex:(unsigned)shineIndex];
        shineIndex++;
        [_grooveLayers addObject:ring];
    }
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylTonearmLayer
// ─────────────────────────────────────────────────────
// Silver rod from a dark pivot circle, L-elbow and black cartridge head at the tip.

@interface SGRVinylTonearmLayer : CALayer
@property (nonatomic) CGPoint pivotPoint;
@property (nonatomic) CGFloat rodLength;
@property (nonatomic) CGFloat angleRad;
- (void)relayout;
@end

@implementation SGRVinylTonearmLayer {
    CALayer *_mount;
    CALayer *_rod;
    CALayer *_elbow;
    CALayer *_cartridge;
    CALayer *_needle;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = NO;

    _mount = [CALayer layer];
    _mount.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.93].CGColor;
    _mount.borderColor     = [UIColor colorWithWhite:0.50 alpha:0.45].CGColor;
    _mount.borderWidth     = 1.0;
    [self addSublayer:_mount];

    _rod = [CALayer layer];
    _rod.backgroundColor = [UIColor colorWithWhite:0.76 alpha:1].CGColor;
    _rod.anchorPoint     = CGPointMake(0.5, 0);
    [self addSublayer:_rod];

    _elbow = [CALayer layer];
    _elbow.backgroundColor = [UIColor colorWithWhite:0.58 alpha:1].CGColor;
    [self addSublayer:_elbow];

    _cartridge = [CALayer layer];
    _cartridge.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1].CGColor;
    _cartridge.cornerRadius    = 3;
    [self addSublayer:_cartridge];

    _needle = [CALayer layer];
    _needle.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1].CGColor;
    [self addSublayer:_needle];

    return self;
}

- (void)relayout {
    CGPoint P     = self.pivotPoint;
    CGFloat L     = self.rodLength;
    CGFloat angle = self.angleRad;

    CGFloat ux = sin(angle);
    CGFloat uy = -cos(angle);

    // Rod
    _rod.anchorPoint  = CGPointMake(0.5, 0);
    _rod.bounds       = CGRectMake(0, 0, kArmWidth, L);
    _rod.position     = P;
    _rod.cornerRadius = kArmWidth / 2;
    _rod.transform    = CATransform3DMakeRotation(angle, 0, 0, 1);

    CGPoint tipP = CGPointMake(P.x + ux * L, P.y + uy * L);

    // Elbow (perpendicular, ≈20 pt)
    CGFloat elbowLen = 20;
    CGFloat elbowW   = kArmWidth * 0.80;
    CGFloat ex = uy, ey = -ux;
    CGPoint elbowMid = CGPointMake(tipP.x + ex * elbowLen * 0.5,
                                   tipP.y + ey * elbowLen * 0.5);
    _elbow.anchorPoint = CGPointMake(0.5, 0.5);
    _elbow.bounds      = CGRectMake(0, 0, elbowW, elbowLen);
    _elbow.position    = elbowMid;
    _elbow.transform   = CATransform3DMakeRotation(angle + M_PI_2, 0, 0, 1);

    CGPoint cartPos = CGPointMake(tipP.x + ex * elbowLen, tipP.y + ey * elbowLen);

    // Cartridge
    CGFloat cW = 16, cH = 24;
    _cartridge.anchorPoint = CGPointMake(0.5, 0.5);
    _cartridge.bounds      = CGRectMake(0, 0, cW, cH);
    _cartridge.position    = cartPos;
    _cartridge.transform   = CATransform3DMakeRotation(angle, 0, 0, 1);

    // Needle
    CGFloat nLen = 13;
    CGPoint needleMid = CGPointMake(cartPos.x + ux * nLen / 2, cartPos.y + uy * nLen / 2);
    _needle.anchorPoint = CGPointMake(0.5, 0.5);
    _needle.bounds      = CGRectMake(0, 0, 2, nLen);
    _needle.position    = needleMid;
    _needle.transform   = CATransform3DMakeRotation(angle, 0, 0, 1);

    // Mount circle
    _mount.anchorPoint  = CGPointMake(0.5, 0.5);
    _mount.bounds       = CGRectMake(0, 0, 2 * kMountRadius, 2 * kMountRadius);
    _mount.position     = P;
    _mount.cornerRadius = kMountRadius;
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylPillButton
// ─────────────────────────────────────────────────────

@interface SGRVinylPillButton : UIControl
- (instancetype)initWithSymbol:(NSString *)symbol iconSize:(CGFloat)iconSize label:(NSString *)label;
- (void)setSymbol:(NSString *)symbol;
- (void)setCaption:(NSString *)text;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation SGRVinylPillButton {
    UIImageView *_icon;
    UILabel     *_label;
    NSString    *_symbol;
    CGFloat      _iconSize;
}

- (instancetype)initWithSymbol:(NSString *)symbol iconSize:(CGFloat)size label:(NSString *)label {
    if (!(self = [super init])) return nil;
    _symbol   = symbol;
    _iconSize = size;
    self.backgroundColor    = [UIColor colorWithWhite:0.13 alpha:0.90];
    self.layer.cornerRadius = kButtonHeight / 2;
    self.layer.cornerCurve  = kCACornerCurveContinuous;
    self.userInteractionEnabled = YES;
    self.clipsToBounds = YES;

    _icon = [[UIImageView alloc] init];
    _icon.tintColor          = UIColor.whiteColor;
    _icon.contentMode        = UIViewContentModeScaleAspectFit;
    _icon.userInteractionEnabled = NO;
    [self addSubview:_icon];
    [self _applySymbol:symbol];

    if (label) {
        _label = [[UILabel alloc] init];
        _label.text          = label;
        _label.textColor     = [UIColor colorWithWhite:1 alpha:0.70];
        _label.font          = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];
    }

    [self addTarget:self action:@selector(_tapped)   forControlEvents:UIControlEventTouchUpInside];
    [self addTarget:self action:@selector(_pressed)  forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragInside];
    [self addTarget:self action:@selector(_released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return self;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.onTap) self.onTap();
}

- (void)_applySymbol:(NSString *)sym {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:_iconSize
                                                                                      weight:UIImageSymbolWeightMedium];
    _icon.image = [UIImage systemImageNamed:sym withConfiguration:cfg];
}

- (void)setSymbol:(NSString *)symbol {
    if ([symbol isEqualToString:_symbol]) return;
    _symbol = symbol;
    [self _applySymbol:symbol];
}

- (void)setCaption:(NSString *)text { _label.text = text; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (_label) {
        CGFloat lblH  = 13;
        CGFloat iconH = H - lblH - 6;
        _icon.frame  = CGRectMake(4, 4, W - 8, iconH - 4);
        _label.frame = CGRectMake(0, H - lblH - 2, W, lblH);
    } else {
        _icon.frame = CGRectInset(self.bounds, 10, 10);
    }
}

- (void)_tapped   { if (self.onTap) self.onTap(); }
- (void)_pressed {
    [UIView animateWithDuration:0.09 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.transform = CGAffineTransformMakeScale(0.88, 0.88); }
                     completion:nil];
}
- (void)_released {
    [UIView animateWithDuration:0.38 delay:0
         usingSpringWithDamping:0.50 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.transform = CGAffineTransformIdentity; }
                     completion:nil];
}
@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylOverlayView
// ─────────────────────────────────────────────────────

@interface SGRVinylOverlayView : UIView <SGPlayerStateObserver>
- (void)setAlbumArt:(UIImage *)image tintColor:(UIColor *)tintColor;
- (void)playerStateDidChange:(SPTPlayerState *)state;
// Returns the current disc rotation angle (used by the mini disc in lyrics).
@property (nonatomic, readonly) CGFloat discAngle;
@property (nonatomic, readonly) UIImage *currentArtwork;
@property (nonatomic, readonly) UIColor *currentTint;
@end

@implementation SGRVinylOverlayView {
    SGRVinylDiscLayer    *_disc;
    UIView               *_discHitView;
    SGRVinylTonearmLayer *_arm;

    UILabel  *_titleLabel;
    UILabel  *_artistLabel;

    SGRVinylPillButton *_btnPlay;
    SGRVinylPillButton *_btnLyrics;
    SGRVinylPillButton *_btnPrev;
    SGRVinylPillButton *_btnNext;

    CADisplayLink   *_link;
    CGFloat          _discAngle;
    BOOL             _isPlaying;
    CFTimeInterval   _lastTS;
    BOOL             _coasting;
    CFTimeInterval   _coastStart;

    CGFloat          _armAngle;
    double           _progress;
    CGFloat          _discR;
    CGPoint          _discCenter;

    UIImage *_currentArtwork;
    UIColor *_currentTint;
}

- (CGFloat)discAngle      { return _discAngle; }
- (UIImage *)currentArtwork { return _currentArtwork; }
- (UIColor *)currentTint  { return _currentTint; }

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // Disc
    _disc = [SGRVinylDiscLayer layer];
    [self.layer addSublayer:_disc];

    // Disc hit view
    _discHitView = [[UIView alloc] init];
    _discHitView.backgroundColor = UIColor.clearColor;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_discTapped)];
    [_discHitView addGestureRecognizer:tap];
    [self addSubview:_discHitView];

    // Tonearm
    _arm = [SGRVinylTonearmLayer layer];
    [self.layer addSublayer:_arm];

    // Tonearm asset: use provided metal/black tonearm image for the top mount and one stylus/rod artifact.
    // The imported asset is not a file in the bundle, so the visuals are drawn by the layer itself using the
    // same shape and color treatment to preserve the vinyl look while keeping the repo self-contained.

    // Title
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.textColor    = UIColor.whiteColor;
    _titleLabel.font         = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _titleLabel.numberOfLines = 2;
    [self addSubview:_titleLabel];

    // Artist
    _artistLabel = [[UILabel alloc] init];
    _artistLabel.textColor    = [UIColor colorWithWhite:1 alpha:0.70];
    _artistLabel.font         = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    _artistLabel.numberOfLines = 1;
    [self addSubview:_artistLabel];

    // ── Buttons ──
    // PLAY/PAUSE — wider pill with label
    _btnPlay = [[SGRVinylPillButton alloc] initWithSymbol:@"play.fill" iconSize:24 label:@"PLAY"];
    _btnPlay.onTap = ^{ vinylToggle(); };
    [self addSubview:_btnPlay];

    // LYRICS — pill with music-note glyph
    _btnLyrics = [[SGRVinylPillButton alloc] initWithSymbol:@"music.note" iconSize:18 label:@"LYRICS"];
    _btnLyrics.onTap = ^{ SGRPlayerToggleLyrics(); };
    [self addSubview:_btnLyrics];

    // ← (prev)
    _btnPrev = [[SGRVinylPillButton alloc] initWithSymbol:@"backward.fill" iconSize:18 label:nil];
    _btnPrev.onTap = ^{ vinylPrev(); };
    [self addSubview:_btnPrev];

    // → (next)
    _btnNext = [[SGRVinylPillButton alloc] initWithSymbol:@"forward.fill" iconSize:18 label:nil];
    _btnNext.onTap = ^{ vinylNext(); };
    [self addSubview:_btnNext];

    // Display link (120 Hz cap)
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(_tick:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    SGAddPlayerStateObserver(self);
    SPTPlayerState *state = SGPlayerState();
    if (state) [self playerStateDidChange:state];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_artworkChanged)
                                               name:SGRNowPlayingArtworkDidChangeNotification object:nil];

    _armAngle = kArmLifted * M_PI / 180.0;
    return self;
}

- (void)dealloc {
    [_link invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// ── Layout ──

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 10 || H < 10) return;

    // ── Disc ──
    CGFloat discDiam = W * kDiscFraction;
    CGFloat discR    = discDiam / 2;
    CGFloat holeR    = discR * kHoleFraction;
    CGFloat discCX   = W * 0.38;
    CGFloat discCY   = H * 0.38;

    _discR      = discR;
    _discCenter = CGPointMake(discCX, discCY);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _disc.discRadius = discR;
    _disc.holeRadius = holeR;
    [_disc setNeedsLayout];
    [_disc layoutIfNeeded];
    _disc.position = CGPointMake(discCX, discCY);
    _disc.shadowColor   = UIColor.blackColor.CGColor;
    _disc.shadowOpacity = 0.50;
    _disc.shadowRadius  = 26;
    _disc.shadowOffset  = CGSizeMake(0, 10);

    // ── Tonearm ──
    CGPoint pivot = CGPointMake(W * kMountX, H * kMountY);
    _arm.frame      = self.bounds;
    _arm.pivotPoint = pivot;
    _arm.rodLength  = W * kArmLengthFrac;
    _arm.angleRad   = _armAngle;
    [_arm relayout];

    [CATransaction commit];

    // Disc hit view
    _discHitView.frame          = CGRectMake(discCX - discR, discCY - discR, discDiam, discDiam);
    _discHitView.layer.cornerRadius = discR;

    // ── Title + artist (left-aligned, below disc) ──
    CGFloat labelTop  = discCY + discR + 22;
    CGFloat sideMargin = 22;
    CGFloat labelW    = MAX(120, W - sideMargin - 14);
    _titleLabel.frame  = CGRectMake(sideMargin, labelTop, labelW, 54);
    _artistLabel.frame = CGRectMake(sideMargin, labelTop + 56, labelW, 22);

    // ── Four pill buttons at the bottom ──
    CGFloat safeBottom  = self.safeAreaInsets.bottom;
    CGFloat btnY        = H - safeBottom - kButtonBottom - kButtonHeight;
    CGFloat gap         = 8;
    CGFloat sideW       = kButtonHeight * 1.4;
    CGFloat midW        = kButtonHeight * 1.75;
    CGFloat totalW      = 2 * midW + 2 * sideW + 3 * gap;
    CGFloat startX      = MAX(18, (W - totalW) / 2);

    _btnPlay.frame   = CGRectMake(startX,                             btnY, midW, kButtonHeight);
    _btnLyrics.frame = CGRectMake(startX + midW + gap,                btnY, midW, kButtonHeight);
    _btnPrev.frame   = CGRectMake(startX + 2 * midW + 2 * gap,        btnY, sideW, kButtonHeight);
    _btnNext.frame   = CGRectMake(startX + 2 * midW + sideW + 3 * gap, btnY, sideW, kButtonHeight);
}

// ── Arm ──

- (CGFloat)_targetArmAngle {
    CGFloat deg = _isPlaying
        ? kArmOnDisc + (kArmEnd - kArmOnDisc) * (CGFloat)_progress
        : kArmLifted;
    return deg * M_PI / 180.0;
}

- (void)_animateArmToTarget {
    CGFloat target = [self _targetArmAngle];
    if (fabs(target - _armAngle) < 0.001) return;
    CGFloat duration = _isPlaying ? 0.6 : 0.35;
    [CATransaction begin];
    [CATransaction setAnimationDuration:duration];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    _armAngle = target;
    _arm.angleRad = target;
    [_arm relayout];
    [CATransaction commit];
}

// ── Disc tap ──

- (void)_discTapped { vinylToggle(); }

// ── Display link ──

- (void)_tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt  = (_lastTS > 0) ? MIN(now - _lastTS, 0.15) : 0;
    _lastTS = now;

    CGFloat rps = 0;
    if (_isPlaying) {
        rps = kRPSPlaying;
        _coasting = NO;
    } else if (_coasting) {
        CGFloat elapsed = (CGFloat)(now - _coastStart);
        if (elapsed >= kCoastDuration) _coasting = NO;
        else rps = kRPSPlaying * (1.0f - elapsed / kCoastDuration);
    }

    if (rps > 0) _discAngle += 2 * M_PI * rps * dt;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _disc.transform = CATransform3DMakeRotation(_discAngle, 0, 0, 1);
    [CATransaction commit];

    // Also spin the mini disc in lyrics if open
    if (SGRPlayerLyricsOpen()) {
        SGRVinylUpdateMiniDisc(_discAngle);
    }
}

// ── Artwork ──

- (void)setAlbumArt:(UIImage *)image tintColor:(UIColor *)tintColor {
    _currentArtwork = image;
    _currentTint    = tintColor;
    [_disc setAlbumArt:image];
    [_disc setTintColor:tintColor];
    // Refresh mini disc art if lyrics are open
    if (SGRPlayerLyricsOpen()) SGRVinylInstallMiniDisc(nil, nil);
}

- (void)_artworkChanged {
    UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
    if (!art) return;
    [SGRPalette paletteForImage:art request:(SGRPaletteRequest){NO} completion:^(SGRPalette *palette) {
        [self setAlbumArt:art tintColor:palette.edgeColor];
    }];
}

// ── Player state ──

- (void)playerStateDidChange:(SPTPlayerState *)state {
    BOOL was = _isPlaying;
    _isPlaying = !state.isPaused;

    if (was && !_isPlaying) {
        _coasting   = YES;
        _coastStart = CACurrentMediaTime();
    }

    double dur = state.duration;
    double pos = state.positionAsOfTimestamp;
    _progress = (dur > 0.5) ? MAX(0, MIN(1, pos / dur)) : 0;

    if (_isPlaying) {
        [_btnPlay setSymbol:@"pause.fill"];
        [_btnPlay setCaption:@"PAUSE"];
    } else {
        [_btnPlay setSymbol:@"play.fill"];
        [_btnPlay setCaption:@"PLAY"];
    }

    SPTPlayerTrack *track = state.track;
    if (track) {
        _titleLabel.text  = track.trackTitle ?: @"";
        _artistLabel.text = track.artistName ?: @"";
    }

    [self _animateArmToTarget];
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - mini vinyl for lyrics thumbnail
// ─────────────────────────────────────────────────────
// When vinyl mode is on and lyrics are open, we replace the UIImageView inside
// SGRPlayerLyricsThumb.face with a mini SGRVinylDiscLayer, kept spinning by the
// overlay's own display link via SGRVinylUpdateMiniDisc().

static char kMiniDiscKey;
static __weak UIView *sg_miniDiscHost; // the _face of the lyrics thumb

// A thin wrapper view that hosts the mini disc layer.
@interface SGRVinylMiniDiscView : UIView
@property (nonatomic, readonly) SGRVinylDiscLayer *disc;
@end

@implementation SGRVinylMiniDiscView {
    SGRVinylDiscLayer *_disc;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds   = YES;
    _disc = [SGRVinylDiscLayer layer];
    [self.layer addSublayer:_disc];
    return self;
}

- (SGRVinylDiscLayer *)disc { return _disc; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat R  = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
    CGFloat HR = R * kHoleFraction;
    _disc.discRadius = R;
    _disc.holeRadius = HR;
    [_disc setNeedsLayout];
    [_disc layoutIfNeeded];
    _disc.position = CGPointMake(R, R);
}

@end

// Called every display-link tick when lyrics are open, to keep the mini disc spinning.
void SGRVinylUpdateMiniDisc(CGFloat angle) {
    UIView *face = sg_miniDiscHost;
    SGRVinylMiniDiscView *mini = face ? objc_getAssociatedObject(face, &kMiniDiscKey) : nil;
    if (!mini) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mini.disc.transform = CATransform3DMakeRotation(angle, 0, 0, 1);
    [CATransaction commit];
}

// Called when lyrics open/close or artwork changes.
// `face` = SGRPlayerLyricsThumb.face (the view that hosts _cover).
// Pass nil for face to just refresh art on an existing mini disc.
void SGRVinylInstallMiniDisc(UIView *face, UIImageView *cover) {
    if (!vinylOn()) return;

    // If face == nil, try to refresh art on existing mini disc.
    if (!face) {
        UIView *existingFace = sg_miniDiscHost;
        SGRVinylMiniDiscView *existing = existingFace ? objc_getAssociatedObject(existingFace, &kMiniDiscKey) : nil;
        if (existing) {
            SGRVinylOverlayView *overlay = (SGRVinylOverlayView *)sg_vinylOverlay;
            [existing.disc setAlbumArt:overlay.currentArtwork];
            [existing.disc setTintColor:overlay.currentTint];
        }
        return;
    }

    sg_miniDiscHost = face;

    // Hide the original cover image view.
    cover.hidden = YES;

    // Check if already installed.
    SGRVinylMiniDiscView *mini = objc_getAssociatedObject(face, &kMiniDiscKey);
    if (!mini) {
        mini = [[SGRVinylMiniDiscView alloc] initWithFrame:face.bounds];
        mini.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // Tap closes lyrics and returns to vinyl.
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:mini
                                                                              action:@selector(_miniTapped)];
        [mini addGestureRecognizer:tap];
        objc_setAssociatedObject(face, &kMiniDiscKey, mini, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [face addSubview:mini];
    }
    mini.frame  = face.bounds;
    mini.hidden = NO;

    SGRVinylOverlayView *overlay = (SGRVinylOverlayView *)sg_vinylOverlay;
    [mini.disc setAlbumArt:overlay.currentArtwork];
    [mini.disc setTintColor:overlay.currentTint];
    // Set current rotation.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mini.disc.transform = CATransform3DMakeRotation(overlay.discAngle, 0, 0, 1);
    [CATransaction commit];

    SGLog(@"redesign player: vinyl mini disc installed on lyrics thumb %.0fx%.0f", face.bounds.size.width, face.bounds.size.height);
}

// Closes lyrics (returns to main vinyl view) when the mini disc is tapped.
@implementation SGRVinylMiniDiscView (Tap)
- (void)_miniTapped { SGRPlayerToggleLyrics(); }
@end

void SGRVinylRemoveMiniDisc(void) {
    UIView *face = sg_miniDiscHost;
    SGRVinylMiniDiscView *mini = face ? objc_getAssociatedObject(face, &kMiniDiscKey) : nil;
    if (mini) {
        mini.hidden = YES;
        // Restore the original cover image view (it is a sibling inside face).
        for (UIView *sub in face.subviews) {
            if ([sub isKindOfClass:UIImageView.class]) sub.hidden = NO;
        }
    }
    sg_miniDiscHost = nil;
}

// ─────────────────────────────────────────────────────
#pragma mark - overlay management
// ─────────────────────────────────────────────────────

static char kVinylOverlayKey;


static SGRVinylOverlayView *vinylOverlayIn(UIView *plane) {
    SGRVinylOverlayView *v = objc_getAssociatedObject(plane, &kVinylOverlayKey);
    if (v) return v;
    v = [[SGRVinylOverlayView alloc] initWithFrame:plane.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    objc_setAssociatedObject(plane, &kVinylOverlayKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sg_vinylOverlay = v;
    UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
    if (art) {
        [SGRPalette paletteForImage:art request:(SGRPaletteRequest){NO} completion:^(SGRPalette *p) {
            [v setAlbumArt:art tintColor:p.edgeColor];
        }];
    }
    SGLog(@"redesign player: vinyl overlay created %.0fx%.0f", plane.bounds.size.width, plane.bounds.size.height);
    return v;
}

static void placeOverlay(UIView *plane) {
    SGRVinylOverlayView *overlay = vinylOverlayIn(plane);
    if (!CGRectEqualToRect(overlay.frame, plane.bounds)) overlay.frame = plane.bounds;
    if (overlay.superview != plane)                  [plane addSubview:overlay];
    else if (plane.subviews.lastObject != overlay)   [plane bringSubviewToFront:overlay];
}

// ─────────────────────────────────────────────────────
#pragma mark - unit hiding
// ─────────────────────────────────────────────────────

static void hideUnit(UIViewController *vc) {
    UIView *v = vc.viewIfLoaded;
    if (!v || v.alpha == 0) return;
    v.alpha = 0;
    v.userInteractionEnabled = NO;
    v.accessibilityElementsHidden = YES;
}

static void hideView(UIView *v) {
    if (!v || v.alpha == 0) return;
    v.alpha = 0;
    v.userInteractionEnabled = NO;
    v.accessibilityElementsHidden = YES;
}

// ─────────────────────────────────────────────────────
#pragma mark - hooks
// ─────────────────────────────────────────────────────

// Background plane: place vinyl overlay on top of the canvas/fluid field.
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    UIView *plane = ((UIViewController *)self).viewIfLoaded;
    if (!plane || plane.bounds.size.height < 200) return;
    placeOverlay(plane);
}
%end

// Hide Spotify's artwork collection view.
%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideView((UIView *)self);
}
%end

// Hide controls units.
%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl40ReinventFreePlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl20DurationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl26ReinventFreeFooterElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

// ─────────────────────────────────────────────────────
#pragma mark - grab SPTPlayer
// ─────────────────────────────────────────────────────

%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    if (!sg_player) sg_player = (id<SPTPlayer>)self;
}
%end

// ─────────────────────────────────────────────────────
#pragma mark - settings section
// ─────────────────────────────────────────────────────

SGModSection *SGRVinylSection(void) {
    SGModRow *row = SGOptionRow(@"Vinyl mode", @"Replaces the player with a spinning vinyl disc", SGRKeyPlayerVinyl);
    row.symbol = @"record.circle";
    return SGNotedSection(@"Vinyl", @[row], @"Tap the disc to pause or play. Tap Lyrics to open karaoke lyrics. Restart Spotify to apply.");
}

// ─────────────────────────────────────────────────────
#pragma mark - ctor
// ─────────────────────────────────────────────────────

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController",
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl40ReinventFreePlaybackControlsElementsUnit",
        @"_TtC20NowPlaying_ModesImpl19DurationElementUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl20DurationElementsUnit",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        @"_TtC20NowPlaying_ModesImpl18FooterElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl26ReinventFreeFooterElementUnit",
        @"SPTEsperantoPlayer",
    ]);
}
