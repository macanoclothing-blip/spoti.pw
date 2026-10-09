// Player redesign: Vinyl mode. When enabled (SGRKeyPlayerVinyl, restart required):
//
//   · The Canvas or Fluid artwork remains behind the vinyl.
//   · The NPVBackgroundViewController's plane gets an SGRVinylOverlayView that draws:
//       - The supplied marbled vinyl texture, tinted from the cover's palette, large and left of
//         centre so its left edge is cropped. The cover fills the centre label.
//       - The supplied tonearm image, pivoting from the upper-right towards the record.
//       - Song title (bold) and artist name, left-aligned below the disc.
//       - Four dark pill buttons at the bottom: PLAY/PAUSE · LYRICS · ← · →
//   · Tap the disc → toggle playback; drag across it to scratch with sound and haptics.
//   · The disc spins while playback is active and stops when paused.
//   · Tap LYRICS → opens the redesigned lyrics view. In the lyrics thumbnail the cover image is
//     replaced by a mini spinning vinyl disc (same art, same rotation). Tapping that disc closes
//     lyrics and returns to the vinyl view.
//   · Spotify's artwork, playback buttons, information and footer are hidden; its seekable progress
//     bar and the header (close + ⋯) remain available.
//
// Threading: main thread only.

#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"
#import "Player.h"
#import "PlayerVinyl.h"
#import "Shared/Haptics/Haptics.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>

// ─────────────────────────────────────────────────────
#pragma mark - constants
// ─────────────────────────────────────────────────────

// Tonearm angles (degrees, positive = clockwise from 12-o'clock).
static const CGFloat kArmLifted  = 15.0;   // resting position when paused
static const CGFloat kArmOnDisc  = 27.0;   // outermost groove
static const CGFloat kArmEnd     = 46.0;   // innermost groove at song end

// The disc is deliberately slower than an actual 33⅓ RPM turn for a calmer screen.
static const CGFloat kRPSPlaying = 0.22;
static const NSTimeInterval kScratchInterval = 0.5;

// Layout fractions (relative to overlay width).
static const CGFloat kDiscFraction   = 0.91;  // disc diameter
static const CGFloat kHoleFraction   = 0.17;  // album-art label (of disc radius)
static const CGFloat kMountX         = 0.85;  // pivot X fraction of overlay width
static const CGFloat kMountY         = 0.135; // pivot Y fraction of overlay height
static const CGFloat kTonearmAssetAngle = 36.0 * M_PI / 180.0;
static const CGFloat kButtonHeight   = 68.0;
static const CGFloat kButtonBottom   = 16.0;
static const NSTimeInterval kFastForwardHoldDuration = 0.38;
static char kVinylResourceAnchor;
static char kVinylOverlayKey;
static char kCanvasHoldKey;

// ─────────────────────────────────────────────────────
#pragma mark - helpers
// ─────────────────────────────────────────────────────

static BOOL vinylOn(void) { return SGFlag(SGRKeyPlayerVinyl, NO); }

static NSString *vinylResourcePath(NSString *name, NSString *extension) {
    NSString *filename = [NSString stringWithFormat:@"%@.%@", name, extension];
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:extension];
    if (path) return path;

    NSString *appPath = NSBundle.mainBundle.bundlePath;
    NSArray<NSString *> *appPaths = @[
        [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Frameworks/spotifyglass.bundle/%@", filename]],
        [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"spotifyglass.bundle/%@", filename]],
        [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/spotifyglass/spotifyglass.bundle/%@", filename]],
        [NSString stringWithFormat:@"/Library/Application Support/spotifyglass/spotifyglass.bundle/%@", filename],
        [NSString stringWithFormat:@"/var/jb/Library/Application Support/spotifyglass/spotifyglass.bundle/%@", filename],
    ];
    for (NSString *candidate in appPaths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    _isPlaying = NO;

    Dl_info info = {0};
    if (dladdr(&kVinylResourceAnchor, &info) && info.dli_fname) {
        NSString *dylib = [NSString stringWithUTF8String:info.dli_fname];
        NSString *directory = dylib.stringByDeletingLastPathComponent;
        NSArray<NSString *> *paths = @[
            [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"spotifyglass.bundle/%@", filename]],
            [directory stringByAppendingPathComponent:filename],
            [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"Resources/%@", filename]],
        ];
        for (NSString *candidate in paths) {
            if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
        }
    }
    SGLog(@"redesign player: missing vinyl resource %@", filename);
    return nil;
}

- (void)_applyDiscRotation {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _disc.transform = CATransform3DMakeRotation(_discAngle, 0, 0, 1);
    [CATransaction commit];
    if (SGRPlayerLyricsOpen()) SGRVinylUpdateMiniDisc(_discAngle);
}

static UIImage *vinylResource(NSString *name) {
    NSString *path = vinylResourcePath(name, @"png");
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
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
    _bodyLayer.opacity = 1;
    _bodyLayer.backgroundColor = [UIColor colorWithWhite:0.035 alpha:1].CGColor;
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
    _bodyLayer.backgroundColor = (tintColor ?: UIColor.darkGrayColor).CGColor;
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
    UIView      *_well;
    UIView      *_wellInner;
    CAGradientLayer *_wellGradient;
    UIImageView *_icon;
    UILabel     *_label;
    NSString    *_symbol;
    CGFloat      _iconSize;
}

- (instancetype)initWithSymbol:(NSString *)symbol iconSize:(CGFloat)size label:(NSString *)label {
    if (!(self = [super init])) return nil;
    _symbol   = symbol;
    _iconSize = size;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = label ?: ([symbol isEqualToString:@"backward.fill"] ? @"Previous track" : @"Next track");

    _well = [UIView new];
    _well.backgroundColor = [UIColor colorWithWhite:0.24 alpha:0.96];
    _well.layer.cornerRadius = 17;
    _well.layer.cornerCurve = kCACornerCurveContinuous;
    _well.layer.borderWidth = 1;
    _well.layer.borderColor = [UIColor colorWithWhite:0.48 alpha:0.65].CGColor;
    _well.layer.shadowColor = UIColor.blackColor.CGColor;
    _well.layer.shadowOpacity = 0.78;
    _well.layer.shadowRadius = 5;
    _well.layer.shadowOffset = CGSizeMake(0, 3);
    [self addSubview:_well];

    _wellInner = [UIView new];
    _wellInner.userInteractionEnabled = NO;
    _wellInner.backgroundColor = [UIColor colorWithWhite:0.075 alpha:1];
    _wellInner.layer.cornerRadius = 14;
    _wellInner.layer.cornerCurve = kCACornerCurveContinuous;
    _wellInner.layer.borderWidth = 1;
    _wellInner.layer.borderColor = [UIColor colorWithWhite:0.01 alpha:1].CGColor;
    [_well addSubview:_wellInner];

    _wellGradient = [CAGradientLayer layer];
    _wellGradient.colors = @[
        (id)[UIColor colorWithWhite:0.42 alpha:0.45].CGColor,
        (id)[UIColor colorWithWhite:0.07 alpha:0.05].CGColor,
    ];
    _wellGradient.startPoint = CGPointMake(0.5, 0);
    _wellGradient.endPoint = CGPointMake(0.5, 1);
    _wellGradient.cornerRadius = 14;
    [_wellInner.layer addSublayer:_wellGradient];

    _icon = [[UIImageView alloc] init];
    _icon.tintColor          = UIColor.whiteColor;
    _icon.contentMode        = UIViewContentModeScaleAspectFit;
    _icon.userInteractionEnabled = NO;
    _icon.hidden = [label isEqualToString:@"PLAY"];
    [self addSubview:_icon];
    [self _applySymbol:symbol];

    if (label) {
        _label = [[UILabel alloc] init];
        _label.text          = label;
        _label.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.textColor = [UIColor colorWithWhite:1 alpha:0.88];
        _label.userInteractionEnabled = NO;
        _label.numberOfLines = 1;
        [_well addSubview:_label];
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
    CGFloat wellWidth = MIN(W - 4, 88);
    CGFloat wellHeight = MIN(48, H - 4);
    CGFloat wellX = (W - wellWidth) / 2;
    CGFloat wellY = (H - wellHeight) / 2;
    _well.frame = CGRectMake(wellX, wellY, wellWidth, wellHeight);
    _wellInner.frame = CGRectInset(_well.bounds, 3, 3);
    _wellGradient.frame = _wellInner.bounds;
    if (_label && ([_label.text isEqualToString:@"PLAY"] || [_label.text isEqualToString:@"PAUSE"])) {
        CGFloat iconHeight = MIN(17, wellHeight * 0.42);
        _icon.hidden = NO;
        _icon.frame = CGRectMake(wellX + (wellWidth - iconHeight) / 2, wellY + 3, iconHeight, iconHeight);
        _label.frame = CGRectMake(2, iconHeight + 3, wellWidth - 4, wellHeight - iconHeight - 4);
    } else if (_label) {
        CGFloat iconHeight = MIN(15, wellHeight * 0.36);
        _icon.hidden = NO;
        _icon.frame = CGRectMake(wellX + (wellWidth - iconHeight) / 2, wellY + 3, iconHeight, iconHeight);
        _label.frame = CGRectMake(2, iconHeight + 2, wellWidth - 4, wellHeight - iconHeight - 3);
    } else {
        CGFloat iconHeight = MIN(22, MAX(16, wellHeight - 8));
        _icon.hidden = NO;
        _icon.frame = CGRectMake(wellX + (wellWidth - iconHeight) / 2, wellY + (wellHeight - iconHeight) / 2,
                                 iconHeight, iconHeight);
    }
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylOverlayView
// ─────────────────────────────────────────────────────

@interface SGRVinylOverlayView : UIView <SGPlayerStateObserver, UIGestureRecognizerDelegate>
- (void)setAlbumArt:(UIImage *)image tintColor:(UIColor *)tintColor;
- (void)playerStateDidChange:(SPTPlayerState *)state;
- (void)setLyricsPresentation:(BOOL)open informationUnit:(UIView *)informationUnit;
- (void)setLyricsControlsAlpha:(CGFloat)alpha;
- (BOOL)handlesLyricsControlAtPoint:(CGPoint)point;
- (void)setCanvasHoldRecognizer:(UILongPressGestureRecognizer *)recognizer;
// Returns the current disc rotation angle (used by the mini disc in lyrics).
@property (nonatomic, readonly) CGFloat discAngle;
@property (nonatomic, readonly) UIImage *currentArtwork;
@property (nonatomic, readonly) UIColor *currentTint;
@end

@implementation SGRVinylOverlayView {
    SGRVinylDiscLayer    *_disc;
    CALayer              *_arm;
    UITapGestureRecognizer *_tap;
    UIPanGestureRecognizer *_scratchPan;
    UILongPressGestureRecognizer *_fastForwardPress;
    AVAudioPlayer *_scratchAudio;
    NSTimer *_scratchTimer;
    NSString *_scratchTrackURI;
    BOOL _scratchWasPlaying;
    CGFloat _scratchLastAngle;
    BOOL _fastForwarding;
    double _speedBeforeHold;

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

    _scratchPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_scratchMoved:)];
    _scratchPan.minimumNumberOfTouches = 1;
    _scratchPan.maximumNumberOfTouches = 1;
    _scratchPan.cancelsTouchesInView = NO;
    _scratchPan.delegate = self;
    [_tap requireGestureRecognizerToFail:_scratchPan];
    [self addGestureRecognizer:_scratchPan];

    NSString *scratchPath = vinylResourcePath(@"VinylScratch", @"m4a");
    if (scratchPath) {
        NSError *error = nil;
        _scratchAudio = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:scratchPath] error:&error];
        if (_scratchAudio) {
            _scratchAudio.numberOfLoops = 0;
            [_scratchAudio prepareToPlay];
        } else {
            SGLog(@"redesign player: could not load vinyl scratch audio: %@", error);
        }
    } else {
        SGLog(@"redesign player: missing bundled VinylScratch.m4a");
    }

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
    [self _endScratchResumingPlayback:YES];
    [self _restorePlaybackSpeed];
    [_link invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (SGRPlayerLyricsOpen()) {
        for (UIView *button in @[_btnPlay, _btnLyrics, _btnPrev, _btnNext]) {
            if (button.alpha > 0.01 && CGRectContainsPoint(button.frame, point)) return YES;
        }
        return NO;
    }
    for (UIView *button in @[_btnPlay, _btnLyrics, _btnPrev, _btnNext]) {
        if (button.alpha > 0.01 && CGRectContainsPoint(button.frame, point)) return YES;
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    CGPoint point = [touch locationInView:self];
    CGFloat dx = point.x - _discCenter.x, dy = point.y - _discCenter.y;
    BOOL onDisc = dx * dx + dy * dy <= _discR * _discR;
    if (gestureRecognizer == _scratchPan) return !SGRPlayerLyricsOpen() && onDisc;
    if (gestureRecognizer == _fastForwardPress) {
        if (SGRPlayerLyricsOpen() || onDisc) return NO;
        for (UIView *button in @[_btnPlay, _btnLyrics, _btnPrev, _btnNext]) {
            if (button.alpha > 0.01 && CGRectContainsPoint(button.frame, point)) return NO;
        }
        return YES;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return gestureRecognizer == _tap || otherGestureRecognizer == _tap;
}

- (void)_scratchMoved:(UIPanGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            SPTPlayerState *state = SGPlayerState();
            CGPoint point = [gesture locationInView:self];
            _scratchLastAngle = atan2(point.y - _discCenter.y, point.x - _discCenter.x);
            _scratchWasPlaying = state && !state.isPaused;
            _scratchTrackURI = state ? SGURIString(state.track.URI) : nil;
            BOOL playbackPaused = !_scratchWasPlaying;
            if (_scratchWasPlaying) {
                id<SPTPlayer> player = SGKaraokePlayer();
                if ([player respondsToSelector:@selector(pause:)]) {
                    id result = [player pause:nil];
                    playbackPaused = YES;
                    SGLog(@"redesign player: paused for vinyl scratch -> %@", result);
                } else {
                    SGLog(@"redesign player: no player available to pause for vinyl scratch");
                    _scratchWasPlaying = NO;
                }
            }
            if (playbackPaused) _isPlaying = NO;
            SGPrepareFeedback(SGFeedbackGrab);
            [self _playScratchTick];
            __weak typeof(self) weakSelf = self;
            _scratchTimer = [NSTimer timerWithTimeInterval:kScratchInterval repeats:YES block:^(NSTimer *timer) {
                (void)timer;
                [weakSelf _playScratchTick];
            }];
            [NSRunLoop.mainRunLoop addTimer:_scratchTimer forMode:NSRunLoopCommonModes];
            SGLog(@"redesign player: vinyl scratch began (was playing: %@)", _scratchWasPlaying ? @"yes" : @"no");
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint point = [gesture locationInView:self];
            CGFloat angle = atan2(point.y - _discCenter.y, point.x - _discCenter.x);
            CGFloat delta = angle - _scratchLastAngle;
            delta = atan2(sin(delta), cos(delta));
            _scratchLastAngle = angle;
            _discAngle += delta;
            [self _applyDiscRotation];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self _endScratchResumingPlayback:YES];
            break;
        default:
            break;
    }
}

- (void)_playScratchTick {
    if (_scratchAudio) {
        [_scratchAudio stop];
        _scratchAudio.currentTime = 0;
        if (![_scratchAudio play]) SGLog(@"redesign player: vinyl scratch audio could not start");
    }
    SGPlayFeedback(SGFeedbackGrab);
}

- (void)_endScratchResumingPlayback:(BOOL)resume {
    if (!_scratchTimer && !_scratchWasPlaying) return;
    [_scratchTimer invalidate];
    _scratchTimer = nil;
    [_scratchAudio stop];
    _scratchAudio.currentTime = 0;

    BOOL shouldResume = resume && _scratchWasPlaying;
    NSString *track = SGURIString(SGPlayerState().track.URI);
    if (shouldResume && _scratchTrackURI && ![_scratchTrackURI isEqualToString:track]) {
        shouldResume = NO;
        SGLog(@"redesign player: not resuming vinyl scratch because the track changed");
    }
    _scratchWasPlaying = NO;
    _scratchTrackURI = nil;
    if (!shouldResume) return;

    id<SPTPlayer> player = SGKaraokePlayer();
    if ([player respondsToSelector:@selector(resume:)]) {
        id result = [player resume:nil];
        SGLog(@"redesign player: vinyl scratch ended; resume -> %@", result);
    } else {
        SGLog(@"redesign player: no player available to resume after vinyl scratch");
    }
}

- (void)_fastForwardHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (!SGPlayerSpeedAllowed()) {
            SGLog(@"redesign player: canvas hold-to-2x is unavailable until Spotify's audio output is active");
            return;
        }
        _speedBeforeHold = SGPlayerSpeed();
        _fastForwarding = YES;
        SGSetPlayerSpeed(2.0);
        SGLog(@"redesign player: canvas held at 2x (previous %.2fx)", _speedBeforeHold);
    } else if (_fastForwarding &&
               (gesture.state == UIGestureRecognizerStateEnded ||
                gesture.state == UIGestureRecognizerStateCancelled ||
                gesture.state == UIGestureRecognizerStateFailed)) {
        [self _restorePlaybackSpeed];
    }
}

- (void)_restorePlaybackSpeed {
    if (!_fastForwarding) return;
    SGSetPlayerSpeed(_speedBeforeHold);
    _fastForwarding = NO;
    SGLog(@"redesign player: restored playback speed to %.2fx", _speedBeforeHold);
}

- (void)setLyricsControlsAlpha:(CGFloat)alpha {
    CGFloat visibleAlpha = MAX(0, MIN(1, alpha));
    for (UIView *button in @[_btnPlay, _btnLyrics, _btnPrev, _btnNext]) {
        button.alpha = visibleAlpha;
    }
}

- (BOOL)handlesLyricsControlAtPoint:(CGPoint)point {
    if (!SGRPlayerLyricsOpen()) return NO;
    for (UIView *button in @[_btnPlay, _btnLyrics, _btnPrev, _btnNext]) {
        if (button.alpha > 0.01 && CGRectContainsPoint(button.frame, point)) return YES;
    }
    return NO;
}

- (void)setCanvasHoldRecognizer:(UILongPressGestureRecognizer *)recognizer {
    _fastForwardPress = recognizer;
}

- (void)setLyricsPresentation:(BOOL)open informationUnit:(UIView *)informationUnit {
    if (informationUnit) {
        informationUnit.alpha = open ? 1 : 0;
        informationUnit.userInteractionEnabled = open;
        informationUnit.accessibilityElementsHidden = !open;
    }
    _disc.opacity = open ? 0 : 1;
    _arm.opacity = open ? 0 : 1;
    _titleLabel.alpha = open ? 0 : 1;
    _artistLabel.alpha = open ? 0 : 1;
    [self setLyricsControlsAlpha:1];
    if (open) [self _endScratchResumingPlayback:YES];
    if (open) [self _restorePlaybackSpeed];
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

// ── Tonearm ──

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

    if (_isPlaying && !_scratchTimer) _discAngle += 2 * M_PI * kRPSPlaying * SGPlayerSpeed() * dt;
    [self _applyDiscRotation];

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
    if (_scratchTimer && _scratchTrackURI) {
        NSString *trackURI = SGURIString(state.track.URI);
        if (![trackURI isEqualToString:_scratchTrackURI]) {
            SGLog(@"redesign player: vinyl scratch ended because the track changed");
            [self _endScratchResumingPlayback:NO];
        }
    }
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

void SGRVinylLyricsDidChange(BOOL open, UIView *informationUnit) {
    SGRVinylOverlayView *overlay = (SGRVinylOverlayView *)sg_vinylOverlay;
    [overlay setLyricsPresentation:open informationUnit:informationUnit];
}

void SGRVinylLyricsControlsDidChange(CGFloat alpha) {
    [(SGRVinylOverlayView *)sg_vinylOverlay setLyricsControlsAlpha:alpha];
}

void SGRVinylLyricsDidSettleClosed(void) {
    if (!vinylOn()) return;
    UIView *coverList = SGRPlayerCoverList();
    coverList.alpha = 0;
    coverList.userInteractionEnabled = NO;
    coverList.accessibilityElementsHidden = YES;
}

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

    UILongPressGestureRecognizer *hold = objc_getAssociatedObject(plane, &kCanvasHoldKey);
    if (!hold) {
        hold = [[UILongPressGestureRecognizer alloc] initWithTarget:overlay action:@selector(_fastForwardHeld:)];
        hold.minimumPressDuration = kFastForwardHoldDuration;
        hold.cancelsTouchesInView = NO;
        hold.delegate = overlay;
        [plane addGestureRecognizer:hold];
        objc_setAssociatedObject(plane, &kCanvasHoldKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [overlay setCanvasHoldRecognizer:hold];
}

// In lyrics mode this full-screen background plane must yield hit-testing to the lyrics, seek bar and Sing control.
%hook UIView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    SGRVinylOverlayView *overlay = objc_getAssociatedObject(self, &kVinylOverlayKey);
    if (overlay && vinylOn() && SGRPlayerLyricsOpen()) {
        CGPoint overlayPoint = [overlay convertPoint:point fromView:self];
        return [overlay handlesLyricsControlAtPoint:overlayPoint] ? overlay : nil;
    }
    return %orig;
}
%end

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

static void showUnit(UIViewController *vc) {
    UIView *v = vc.viewIfLoaded;
    if (!v) return;
    v.alpha = 1;
    v.userInteractionEnabled = YES;
    v.accessibilityElementsHidden = NO;
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

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    if (SGRPlayerLyricsOpen()) {
        if (((UIViewController *)self).viewIfLoaded.alpha < 0.01) showUnit((UIViewController *)self);
    }
    else hideUnit((UIViewController *)self);
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
    return SGNotedSection(@"Vinyl", @[row], @"Tap the disc to pause or play; drag across it to scratch with sound and haptics. Hold the canvas outside the disc for 2x until release. The progress bar remains available; lyrics controls hide after a few seconds and return on touch. Restart Spotify to apply.");
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
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        @"_TtC20NowPlaying_ModesImpl18FooterElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl26ReinventFreeFooterElementUnit",
    ]);
}
