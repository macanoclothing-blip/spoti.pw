// Player redesign: Vinyl mode. When enabled (SGRKeyPlayerVinyl, restart required):
//
//   · The Canvas or Fluid artwork remains behind the vinyl.
//   · The NPVBackgroundViewController's plane gets an SGRVinylOverlayView that draws:
//       - The supplied marbled vinyl texture, tinted from the cover's palette, large and left of
//         centre so its left edge is cropped. The cover fills the centre label.
//       - The supplied tonearm image, pivoting from the upper-right towards the record.
//       - Song title (bold) and artist name, left-aligned below the disc.
//       - Four dark pill buttons at the bottom: PLAY/PAUSE · LYRICS · ← · →
//   · Tap the disc → toggle playback.
//   · The disc spins while playback is active and stops when paused.
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
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"
#import "Player.h"
#import "PlayerVinyl.h"
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>

// ─────────────────────────────────────────────────────
#pragma mark - constants
// ─────────────────────────────────────────────────────

// Tonearm angles (degrees, positive = clockwise from 12-o'clock).
static const CGFloat kArmLifted  = 15.0;   // resting position when paused
static const CGFloat kArmOnDisc  = 27.0;   // outermost groove
static const CGFloat kArmEnd     = 46.0;   // innermost groove at song end

// Disc spin rate while playing (33⅓ RPM ≈ 0.555 rev/s).
static const CGFloat kRPSPlaying     = 0.555;

// Layout fractions (relative to overlay width).
static const CGFloat kDiscFraction   = 0.91;  // disc diameter
static const CGFloat kHoleFraction   = 0.17;  // album-art label (of disc radius)
static const CGFloat kMountX         = 0.85;  // pivot X fraction of overlay width
static const CGFloat kMountY         = 0.135; // pivot Y fraction of overlay height
static const CGFloat kTonearmAssetAngle = 36.0 * M_PI / 180.0;
static const CGFloat kButtonHeight   = 54.0;
static const CGFloat kButtonBottom   = 48.0;
static char kVinylResourceAnchor;

// ─────────────────────────────────────────────────────
#pragma mark - helpers
// ─────────────────────────────────────────────────────

static BOOL vinylOn(void) { return SGFlag(SGRKeyPlayerVinyl, NO); }

static UIImage *vinylResource(NSString *name) {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
    if (path) return [UIImage imageWithContentsOfFile:path];

    NSString *appPath = NSBundle.mainBundle.bundlePath;
    NSArray<NSString *> *appPaths = @[
        [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Frameworks/spotifyglass.bundle/%@.png", name]],
        [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"spotifyglass.bundle/%@.png", name]],
        [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/spotifyglass/spotifyglass.bundle/%@.png", name]],
        [NSString stringWithFormat:@"/Library/Application Support/spotifyglass/spotifyglass.bundle/%@.png", name],
        [NSString stringWithFormat:@"/var/jb/Library/Application Support/spotifyglass/spotifyglass.bundle/%@.png", name],
    ];
    for (NSString *candidate in appPaths) {
        UIImage *image = [UIImage imageWithContentsOfFile:candidate];
        if (image) return image;
    }

    Dl_info info = {0};
    if (dladdr(&kVinylResourceAnchor, &info) && info.dli_fname) {
        NSString *dylib = [NSString stringWithUTF8String:info.dli_fname];
        NSString *directory = dylib.stringByDeletingLastPathComponent;
        NSArray<NSString *> *paths = @[
            [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"spotifyglass.bundle/%@.png", name]],
            [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", name]],
            [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"Resources/%@.png", name]],
        ];
        for (NSString *candidate in paths) {
            UIImage *image = [UIImage imageWithContentsOfFile:candidate];
            if (image) return image;
        }
    }
    SGLog(@"redesign player: missing vinyl resource %@", name);
    return nil;
}

static UIImage *vinylDiscTexture(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = vinylResource(@"VinylDisc"); });
    return image;
}

static UIImage *vinylTonearmTexture(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = vinylResource(@"VinylTonearm"); });
    return image;
}

static void vinylToggle(void) {
    SPTPlayerState *s = SGPlayerState();
    id<SPTPlayer> p = SGKaraokePlayer();
    if (!s) {
        SGLog(@"redesign player: no player state for play/pause");
        return;
    }
    SEL command = s.isPaused ? @selector(resume:) : @selector(pause:);
    if (![p respondsToSelector:command]) {
        SGLog(@"redesign player: no player available for %@", NSStringFromSelector(command));
        return;
    }
    id result = s.isPaused ? [p resume:nil] : [p pause:nil];
    SGLog(@"redesign player: %@ -> %@", s.isPaused ? @"resume" : @"pause", result);
}

static void vinylSkip(BOOL next) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SEL command = next ? @selector(skipToNextTrackWithOptions:) : @selector(skipToPreviousTrackWithOptions:);
    if (![player respondsToSelector:command]) {
        SGLog(@"redesign player: no player available for %@", NSStringFromSelector(command));
        return;
    }
    id result = next ? [player skipToNextTrackWithOptions:nil] : [player skipToPreviousTrackWithOptions:nil];
    SGLog(@"redesign player: %@ -> %@", next ? @"next" : @"previous", result);
}

static UIImage *tintedVinylTexture(UIColor *color) {
    UIImage *texture = vinylDiscTexture();
    if (!texture.CGImage || !color) return texture;

    CGFloat red = 0, green = 0, blue = 0, alpha = 1;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return texture;
    NSString *cacheKey = [NSString stringWithFormat:@"%.3f-%.3f-%.3f", red, green, blue];
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t cacheOnce;
    dispatch_once(&cacheOnce, ^{ cache = [NSCache new]; });
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });

    CIFilter *filter = [CIFilter filterWithName:@"CIColorMonochrome"];
    [filter setValue:[CIImage imageWithCGImage:texture.CGImage] forKey:kCIInputImageKey];
    [filter setValue:[CIColor colorWithCGColor:color.CGColor] forKey:kCIInputColorKey];
    [filter setValue:@1.0 forKey:kCIInputIntensityKey];
    CIImage *output = filter.outputImage;
    CGImageRef image = output ? [context createCGImage:output fromRect:output.extent] : NULL;
    if (!image) return texture;
    UIImage *tinted = [UIImage imageWithCGImage:image scale:texture.scale orientation:texture.imageOrientation];
    CGImageRelease(image);
    [cache setObject:tinted forKey:cacheKey];
    return tinted;
}

static UIColor *vinylColorFromPalette(UIColor *color) {
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 1;
    if (![color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) return color;
    return [UIColor colorWithHue:hue saturation:MAX(saturation, 0.62) brightness:0.62 alpha:1];
}

// Forward-declared here so mini-disc functions defined earlier can reference it.
@class SGRVinylOverlayView;
static __weak SGRVinylOverlayView *sg_vinylOverlay;

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylDiscLayer
// ─────────────────────────────────────────────────────
// Draws the vinyl record from the bundled texture and cover artwork.
// Can be used both for the full-size disc and the mini thumbnail in lyrics view.

@interface SGRVinylDiscLayer : CALayer
@property (nonatomic) CGFloat discRadius;
@property (nonatomic) CGFloat holeRadius;
@property (nonatomic, strong) UIColor *tintColor;
- (void)setAlbumArt:(UIImage *)image;
@end

@implementation SGRVinylDiscLayer {
    CALayer *_bodyLayer;
    CALayer *_artLayer;
    CALayer *_spindleLayer;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = NO;
    [self _buildBase];
    return self;
}

- (void)_buildBase {
    _bodyLayer = [CALayer layer];
    _bodyLayer.masksToBounds = YES;
    _bodyLayer.contentsGravity = kCAGravityResizeAspectFill;
    _bodyLayer.opacity = 0.82;
    _bodyLayer.contents = (__bridge id)vinylDiscTexture().CGImage;
    [self addSublayer:_bodyLayer];

    _artLayer = [CALayer layer];
    _artLayer.masksToBounds = YES;
    _artLayer.contentsGravity = kCAGravityResizeAspectFill;
    [self addSublayer:_artLayer];

    _spindleLayer = [CALayer layer];
    _spindleLayer.backgroundColor = [UIColor colorWithWhite:0.82 alpha:1].CGColor;
    [self addSublayer:_spindleLayer];
}

- (void)setAlbumArt:(UIImage *)image {
    _artLayer.contents = (__bridge id)image.CGImage;
}

- (void)setTintColor:(UIColor *)tintColor {
    _tintColor = tintColor;
    UIImage *texture = tintedVinylTexture(tintColor);
    _bodyLayer.contents = (__bridge id)texture.CGImage;
    [self setNeedsLayout];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGFloat R  = _discRadius;
    CGFloat HR = _holeRadius;
    if (R < 1) return;

    CGFloat D  = 2 * R;
    CGRect disc = CGRectMake(0, 0, D, D);

    self.bounds       = disc;
    self.cornerRadius = R;

    _bodyLayer.frame        = disc;
    _bodyLayer.cornerRadius = R;

    CGFloat hD = 2 * HR;
    CGRect holeRect = CGRectMake(R - HR, R - HR, hD, hD);
    _artLayer.frame       = holeRect;
    _artLayer.cornerRadius = HR;

    CGFloat spR = 3.5;
    _spindleLayer.frame        = CGRectMake(R - spR, R - spR, 2 * spR, 2 * spR);
    _spindleLayer.cornerRadius = spR;
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylPillButton
// ─────────────────────────────────────────────────────

@interface SGRVinylPillButton : UIView
- (instancetype)initWithSymbol:(NSString *)symbol iconSize:(CGFloat)iconSize label:(NSString *)label;
- (void)setSymbol:(NSString *)symbol;
- (void)setCaption:(NSString *)text;
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
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = label ?: ([symbol isEqualToString:@"backward.fill"] ? @"Previous track" : @"Next track");

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

    return self;
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

- (void)setCaption:(NSString *)text {
    _label.text = text;
    self.accessibilityLabel = text;
}

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

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylOverlayView
// ─────────────────────────────────────────────────────

@interface SGRVinylOverlayView : UIView <SGPlayerStateObserver, UIGestureRecognizerDelegate>
- (void)setAlbumArt:(UIImage *)image tintColor:(UIColor *)tintColor;
- (void)playerStateDidChange:(SPTPlayerState *)state;
// Returns the current disc rotation angle (used by the mini disc in lyrics).
@property (nonatomic, readonly) CGFloat discAngle;
@property (nonatomic, readonly) UIImage *currentArtwork;
@property (nonatomic, readonly) UIColor *currentTint;
@end

@implementation SGRVinylOverlayView {
    SGRVinylDiscLayer    *_disc;
    CALayer              *_arm;
    UITapGestureRecognizer *_tap;

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

    // The supplied transparent PNG contains the complete tonearm.
    _arm = [CALayer layer];
    _arm.contents = (__bridge id)vinylTonearmTexture().CGImage;
    _arm.contentsGravity = kCAGravityResizeAspect;
    _arm.contentsScale = UIScreen.mainScreen.scale;
    [self.layer addSublayer:_arm];

    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_overlayTapped:)];
    _tap.cancelsTouchesInView = NO;
    _tap.delegate = self;
    [self addGestureRecognizer:_tap];

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
    [self addSubview:_btnPlay];

    // LYRICS — pill with music-note glyph
    _btnLyrics = [[SGRVinylPillButton alloc] initWithSymbol:@"music.note" iconSize:18 label:@"LYRICS"];
    [self addSubview:_btnLyrics];

    // ← (prev)
    _btnPrev = [[SGRVinylPillButton alloc] initWithSymbol:@"backward.fill" iconSize:18 label:nil];
    [self addSubview:_btnPrev];

    // → (next)
    _btnNext = [[SGRVinylPillButton alloc] initWithSymbol:@"forward.fill" iconSize:18 label:nil];
    [self addSubview:_btnNext];

    // Display link (120 Hz cap)
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(_tick:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    _armAngle = kArmLifted * M_PI / 180.0;
    SGAddPlayerStateObserver(self);
    SPTPlayerState *state = SGPlayerState();
    if (state) [self playerStateDidChange:state];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_artworkChanged)
                                               name:SGRNowPlayingArtworkDidChangeNotification object:nil];

    return self;
}

- (void)dealloc {
    [_link invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (SGRPlayerLyricsOpen()) return NO;
    for (UIView *button in @[_btnPlay, _btnLyrics, _btnPrev, _btnNext]) {
        if (CGRectContainsPoint(button.frame, point)) return YES;
    }
    CGFloat dx = point.x - _discCenter.x;
    CGFloat dy = point.y - _discCenter.y;
    return dx * dx + dy * dy <= _discR * _discR;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled ||
        ![self pointInside:point withEvent:event]) return nil;
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)otherGestureRecognizer;
    return gestureRecognizer == _tap;
}

- (void)_overlayTapped:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:self];
    if (CGRectContainsPoint(_btnPlay.frame, point)) {
        SGLog(@"redesign player: vinyl play/pause tapped");
        _btnPlay.transform = CGAffineTransformMakeScale(0.92, 0.92);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self->_btnPlay.transform = CGAffineTransformIdentity; }
                         completion:nil];
        vinylToggle();
    } else if (CGRectContainsPoint(_btnLyrics.frame, point)) {
        SGLog(@"redesign player: vinyl lyrics tapped");
        SGRPlayerToggleLyrics();
    } else if (CGRectContainsPoint(_btnPrev.frame, point)) {
        SGLog(@"redesign player: vinyl previous tapped");
        vinylSkip(NO);
    } else if (CGRectContainsPoint(_btnNext.frame, point)) {
        SGLog(@"redesign player: vinyl next tapped");
        vinylSkip(YES);
    } else {
        CGFloat dx = point.x - _discCenter.x;
        CGFloat dy = point.y - _discCenter.y;
        if (dx * dx + dy * dy <= _discR * _discR) vinylToggle();
    }
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

    // ── Tonearm ──
    CGPoint pivot = CGPointMake(W * kMountX, H * kMountY);
    _arm.bounds = CGRectMake(0, 0, W, W);
    _arm.anchorPoint = CGPointMake(0.80, 0.14);
    _arm.position = pivot;
    _arm.transform = CATransform3DMakeRotation(_armAngle - kTonearmAssetAngle, 0, 0, 1);

    [CATransaction commit];

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
    CGFloat scale       = MIN(1, MAX(0, (W - 36 - 3 * gap) / (2 * midW + 2 * sideW)));
    sideW *= scale;
    midW  *= scale;
    CGFloat totalW      = 2 * midW + 2 * sideW + 3 * gap;
    CGFloat startX      = (W - totalW) / 2;

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
    _arm.transform = CATransform3DMakeRotation(target - kTonearmAssetAngle, 0, 0, 1);
    [CATransaction commit];
}

// ── Display link ──

- (void)_tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt  = (_lastTS > 0) ? MIN(now - _lastTS, 0.15) : 0;
    _lastTS = now;

    if (_isPlaying) _discAngle += 2 * M_PI * kRPSPlaying * dt;

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
        [self setAlbumArt:art tintColor:vinylColorFromPalette(palette.fieldColor)];
    }];
}

// ── Player state ──

- (void)playerStateDidChange:(SPTPlayerState *)state {
    _isPlaying = !state.isPaused;

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
            [v setAlbumArt:art tintColor:vinylColorFromPalette(p.fieldColor)];
        }];
    }
    SGLog(@"redesign player: vinyl overlay created %.0fx%.0f", plane.bounds.size.width, plane.bounds.size.height);
    return v;
}

static void placeOverlay(UIView *plane) {
    SGRVinylOverlayView *overlay = vinylOverlayIn(plane);
    plane.userInteractionEnabled = YES;
    overlay.userInteractionEnabled = YES;
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
    ]);
}
