// Player redesign: Vinyl mode. When enabled (SGRKeyPlayerVinyl, restart required):
//
//   · The background field (Canvas or Fluid artwork) stays exactly where it is.
//   · The NPVBackgroundViewController's plane gets an SGRVinylOverlayView on top of Spotify's
//     gradients, covering the artwork area and the controls area but below the header. Its dark
//     scrim gives the background field a stage without hiding it entirely.
//   · The vinyl disc is a layered CALayer: the groove pattern ring, the label (album art masked to
//     a circle), the label ring and a central spindle highlight.
//   · A CADisplayLink spins the disc at 0.38 rev/s while playing. When paused, the disc coasts to
//     a stop with a short damped deceleration.
//   · A tonearm pivots from a fixed mount in the top-right corner. Its angle interpolates between
//     kArmLifted (disc edge, song = 0) and kArmPlaying (near centre, song = 1.0). While paused,
//     the arm lifts to kArmLifted with a spring animation.
//   · A tap anywhere on the disc toggles playback through the SPTPlayer the PlayerState module
//     already watches.
//   · Three pill buttons (Prev, Play/Pause, Next) sit at the bottom of the overlay. They forward
//     their taps to Spotify's actual SPTNowPlayingPreviousTrackButton, PlayButtonView and
//     SPTNowPlayingNextTrackButton via the SGRPlayerCommandVia helpers so the player's own
//     telemetry and queue logic run.
//   · The title and artist label (InformationElementsUnit), playback controls
//     (PlaybackControlsElementsUnit), footer (FooterElementsUnit) and artwork cells are hidden via
//     alpha = 0 / userInteractionEnabled = NO. The header is untouched.
//
// Tree references (trees/clean/player/01.txt): NPVBackgroundViewController's view is the plane we
// place our overlay in. HeaderElementsUnit's row sits at the top of the NPV stack and is left alone.
// The artwork list (AccessibleCollectionView) and the three element units are children of the NPV's
// scroll content view; we zero their alpha on every layout pass.
//
// Threading: main thread only throughout.

#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"
#import "PlayerVinyl.h"

// ─────────────────────────────────────────────────────
#pragma mark - constants
// ─────────────────────────────────────────────────────

// Tonearm angles (degrees from 12 o'clock, positive = clockwise).
static const CGFloat kArmLifted  = 21.0;   // resting beside the disc, song start / paused
static const CGFloat kArmOnDisc  = 28.0;   // outermost groove
static const CGFloat kArmEnd     = 48.0;   // innermost groove (song end)

// Disc spin rate while playing (full rotations per second).
static const CGFloat kRPSPlaying = 0.38;
// Deceleration: the disc slows over this many seconds after pause.
static const NSTimeInterval kCoastDuration = 0.65;

// Layout fractions.
static const CGFloat kDiscFraction = 0.78;   // disc diameter as a fraction of the overlay width
static const CGFloat kLabelFraction = 0.285; // album-art hole diameter as fraction of disc diameter
static const CGFloat kArmLength   = 0.52;    // tonearm length as fraction of overlay width
static const CGFloat kArmWidth    = 3.5;     // tonearm line width in points
static const CGFloat kMountRadius = 24.0;    // pivot circle radius
static const CGFloat kMountX      = 0.82;    // pivot centre X as fraction of overlay width
static const CGFloat kMountY      = 0.11;    // pivot centre Y as fraction of overlay height
static const CGFloat kButtonHeight = 52.0;
static const CGFloat kButtonBottom = 48.0;   // bottom edge above safe-area bottom

// ─────────────────────────────────────────────────────
#pragma mark - helpers
// ─────────────────────────────────────────────────────

static BOOL vinylOn(void) {
    return SGFlag(SGRKeyPlayerVinyl, NO);
}

// The SPTPlayer instance we talk to, grabbed from PlayerState's observer mechanism.
static __weak id<SPTPlayer> sg_player;

// Called by the vinyl tap: toggle pause/play.
static void vinylTogglePlayback(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!state) return;
    id<SPTPlayer> player = sg_player;
    if (!player) return;
    if (state.isPaused) [player resume:nil];
    else                [player pause:nil];
}

static void vinylSkipPrev(void) {
    [sg_player skipToPreviousTrackWithOptions:nil];
}

static void vinylSkipNext(void) {
    [sg_player skipToNextTrackWithOptions:nil];
}

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylDiscLayer
// ─────────────────────────────────────────────────────
// A CALayer hierarchy that draws the vinyl disc (grooves, label hole, spindle).
// The caller rotates this layer's transform to spin the disc.

@interface SGRVinylDiscLayer : CALayer
@property (nonatomic) CGFloat discRadius;
@property (nonatomic) CGFloat labelRadius;
- (void)setAlbumArt:(UIImage *)image;
@end

@implementation SGRVinylDiscLayer {
    CALayer         *_grooveLayer;   // the semi-transparent groove rings
    CALayer         *_labelLayer;    // album art + coloured ring
    CALayer         *_artLayer;      // the art inside labelLayer, masked to a circle
    CALayer         *_spindleLayer;  // white/grey centre dot
    CAGradientLayer *_shineLayer;    // subtle highlight that makes it feel 3-D
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = NO;
    [self _buildLayers];
    return self;
}

- (void)_buildLayers {
    // ── Outer disc ──
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1].CGColor;

    // ── Groove rings (semi-transparent alternating light bands) ──
    _grooveLayer = [CALayer layer];
    _grooveLayer.masksToBounds = YES;
    [self addSublayer:_grooveLayer];

    // ── Label (album art + coloured ring) ──
    _labelLayer = [CALayer layer];
    _labelLayer.masksToBounds = YES;
    _labelLayer.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1].CGColor;
    [self addSublayer:_labelLayer];

    // ── Art (masked to circle inside label) ──
    _artLayer = [CALayer layer];
    _artLayer.masksToBounds = YES;
    _artLayer.contentsGravity = kCAGravityResizeAspectFill;
    [_labelLayer addSublayer:_artLayer];

    // ── Spindle ──
    _spindleLayer = [CALayer layer];
    _spindleLayer.backgroundColor = [UIColor colorWithWhite:0.85 alpha:0.9].CGColor;
    [self addSublayer:_spindleLayer];

    // ── Radial shine ──
    _shineLayer = [CAGradientLayer layer];
    _shineLayer.type = kCAGradientLayerRadial;
    _shineLayer.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.07].CGColor,
                           (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor];
    _shineLayer.startPoint = CGPointMake(0.35, 0.28);
    _shineLayer.endPoint   = CGPointMake(1.0, 1.0);
    [self addSublayer:_shineLayer];
}

- (void)setAlbumArt:(UIImage *)image {
    _artLayer.contents = (id)image.CGImage;
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGFloat R = _discRadius;
    CGFloat r = _labelRadius;
    if (R < 1 || r < 1) return;
    CGFloat diameter = 2 * R;
    CGFloat diam_r   = 2 * r;
    CGRect disc  = CGRectMake(0, 0, diameter, diameter);
    CGRect label = CGRectMake(R - r, R - r, diam_r, diam_r);

    self.bounds           = disc;
    self.cornerRadius     = R;

    _grooveLayer.frame        = disc;
    _grooveLayer.cornerRadius = R;
    [self _rebuildGrooves:R label:r];

    _labelLayer.frame        = label;
    _labelLayer.cornerRadius = r;

    _artLayer.frame        = CGRectMake(0, 0, diam_r, diam_r);
    _artLayer.cornerRadius = r;

    CGFloat spR = 5;
    _spindleLayer.frame        = CGRectMake(R - spR, R - spR, 2 * spR, 2 * spR);
    _spindleLayer.cornerRadius = spR;

    _shineLayer.frame = disc;
}

- (void)_rebuildGrooves:(CGFloat)R label:(CGFloat)r {
    // Remove old groove sub-layers.
    [_grooveLayer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];

    // Draw rings between label edge and disc edge.
    CGFloat outer = R - 4;
    CGFloat inner = r + 4;
    NSInteger count = 22;
    CGFloat step = (outer - inner) / count;

    for (NSInteger i = 0; i < count; i++) {
        CGFloat rr = inner + i * step;
        CALayer *ring = [CALayer layer];
        BOOL bright = (i % 2 == 0);
        ring.backgroundColor = [UIColor colorWithWhite:bright ? 0.18 : 0.10 alpha:1].CGColor;
        ring.frame = CGRectMake(R - rr, R - rr, 2 * rr, 2 * rr);
        ring.cornerRadius = rr;
        [_grooveLayer addSublayer:ring];
    }
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylTonearmLayer
// ─────────────────────────────────────────────────────

@interface SGRVinylTonearmLayer : CALayer
@property (nonatomic) CGPoint pivotInHost;   // in the overlay's coordinate space
@property (nonatomic) CGFloat armLength;
@property (nonatomic) CGFloat angleRadians;  // arm angle in radians from 12-o-clock
- (void)relayout;
@end

@implementation SGRVinylTonearmLayer {
    CALayer *_arm;
    CALayer *_mount;
    CALayer *_needle;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = NO;

    // Arm rod
    _arm = [CALayer layer];
    _arm.backgroundColor = [UIColor colorWithWhite:0.72 alpha:1].CGColor;
    _arm.cornerRadius = kArmWidth / 2;
    [self addSublayer:_arm];

    // Needle head
    _needle = [CALayer layer];
    _needle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    _needle.cornerRadius = 5;
    [self addSublayer:_needle];

    // Pivot mount circle
    _mount = [CALayer layer];
    _mount.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.95].CGColor;
    _mount.borderColor = [UIColor colorWithWhite:0.5 alpha:0.6].CGColor;
    _mount.borderWidth = 1.5;
    [self addSublayer:_mount];

    return self;
}

- (void)relayout {
    CGPoint P = self.pivotInHost;
    CGFloat L = self.armLength;
    CGFloat angle = self.angleRadians;  // from 12-o'clock, positive = CW

    // The arm rod: anchorPoint at its top centre so rotation pivots at P.
    // In CALayer, anchorPoint (0.5, 0) means the top-centre is the anchor.
    _arm.anchorPoint = CGPointMake(0.5, 0);
    // bounds: a thin rectangle, L tall, kArmWidth wide.
    _arm.bounds   = CGRectMake(0, 0, kArmWidth, L);
    // position = the pivot in the host layer coordinates.
    _arm.position = P;
    _arm.transform = CATransform3DMakeRotation(angle, 0, 0, 1);

    // Tip of the arm in host space.
    CGFloat tipX = P.x + sin(angle) * L;
    CGFloat tipY = P.y - cos(angle) * L;   // up = -Y in UIKit

    // Needle head at tip (small dark rectangle, slightly angled).
    CGFloat nW = 14, nH = 8;
    _needle.anchorPoint = CGPointMake(0.5, 0.5);
    _needle.bounds = CGRectMake(0, 0, nW, nH);
    _needle.position = CGPointMake(tipX, tipY);
    _needle.transform = CATransform3DMakeRotation(angle, 0, 0, 1);

    // Mount circle at pivot.
    _mount.anchorPoint = CGPointMake(0.5, 0.5);
    _mount.bounds = CGRectMake(0, 0, 2 * kMountRadius, 2 * kMountRadius);
    _mount.position = P;
    _mount.cornerRadius = kMountRadius;
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylPillButton
// ─────────────────────────────────────────────────────

@interface SGRVinylPillButton : UIControl
- (instancetype)initWithSymbol:(NSString *)symbol size:(CGFloat)size;
@property (nonatomic, copy) void (^onTap)(void);
- (void)setSymbol:(NSString *)symbol;
@end

@implementation SGRVinylPillButton {
    UIImageView *_icon;
    NSString    *_symbol;
    CGFloat      _size;
}

- (instancetype)initWithSymbol:(NSString *)symbol size:(CGFloat)size {
    if (!(self = [super init])) return nil;
    _symbol = symbol;
    _size = size;
    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.85];
    self.layer.cornerRadius = kButtonHeight / 2;
    self.layer.cornerCurve  = kCACornerCurveContinuous;

    _icon = [[UIImageView alloc] init];
    _icon.tintColor = UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.userInteractionEnabled = NO;
    [self addSubview:_icon];
    [self _applySymbol:symbol];

    [self addTarget:self action:@selector(_tapped) forControlEvents:UIControlEventTouchUpInside];
    [self addTarget:self action:@selector(_press:)  forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragInside];
    [self addTarget:self action:@selector(_release) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return self;
}

- (void)_applySymbol:(NSString *)symbol {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:_size weight:UIImageSymbolWeightRegular];
    _icon.image = [UIImage systemImageNamed:symbol withConfiguration:cfg];
}

- (void)setSymbol:(NSString *)symbol {
    if ([symbol isEqualToString:_symbol]) return;
    _symbol = symbol;
    [self _applySymbol:symbol];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad = 12;
    _icon.frame = CGRectInset(self.bounds, pad, pad);
}

- (void)_tapped {
    if (self.onTap) self.onTap();
}

- (void)_press:(UIControl *)sender {
    [UIView animateWithDuration:0.1 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.88, 0.88);
    } completion:nil];
}

- (void)_release {
    [UIView animateWithDuration:0.35 delay:0
     usingSpringWithDamping:0.55 initialSpringVelocity:0.3
     options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
     animations:^{ self.transform = CGAffineTransformIdentity; }
     completion:nil];
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - SGRVinylOverlayView
// ─────────────────────────────────────────────────────

@interface SGRVinylOverlayView : UIView <SGPlayerStateObserver>
- (void)setAlbumArt:(UIImage *)image;
- (void)playerStateDidChange:(SPTPlayerState *)state;
@end

@implementation SGRVinylOverlayView {
    SGRVinylDiscLayer    *_disc;
    SGRVinylTonearmLayer *_arm;
    SGRVinylPillButton   *_btnPrev;
    SGRVinylPillButton   *_btnPlay;
    SGRVinylPillButton   *_btnNext;

    CADisplayLink   *_displayLink;
    CGFloat          _discAngle;     // current rotation in radians
    BOOL             _isPlaying;
    CFTimeInterval   _lastTimestamp;

    // Coasting state (post-pause deceleration)
    BOOL             _coasting;
    CFTimeInterval   _coastStart;
    CGFloat          _coastInitialRPS;

    // Song progress for the tonearm (0...1)
    double           _songProgress;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0];  // transparent – the field shows through
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // ── Disc ──
    _disc = [SGRVinylDiscLayer layer];
    [self.layer addSublayer:_disc];

    // Tap to toggle playback – the disc recognizer is on a transparent UIView the size of the disc.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_discTapped)];
    [self addGestureRecognizer:tap];

    // ── Arm ──
    _arm = [SGRVinylTonearmLayer layer];
    [self.layer addSublayer:_arm];

    // ── Pill buttons ──
    _btnPrev = [[SGRVinylPillButton alloc] initWithSymbol:@"backward.fill" size:22];
    __weak typeof(self) weak = self;
    _btnPrev.onTap = ^{ vinylSkipPrev(); };
    [self addSubview:_btnPrev];

    _btnPlay = [[SGRVinylPillButton alloc] initWithSymbol:@"play.fill" size:28];
    _btnPlay.onTap = ^{ vinylTogglePlayback(); };
    [self addSubview:_btnPlay];

    _btnNext = [[SGRVinylPillButton alloc] initWithSymbol:@"forward.fill" size:22];
    _btnNext.onTap = ^{ (void)weak; vinylSkipNext(); };
    [self addSubview:_btnNext];

    // ── Display link ──
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_tick:)];
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    // ── Observe player state ──
    SGAddPlayerStateObserver(self);
    // Apply current state immediately if available.
    SPTPlayerState *state = SGPlayerState();
    if (state) [self playerStateDidChange:state];

    // Observe artwork changes.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];

    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// ── Layout ──

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 10 || H < 10) return;

    CGFloat discDiam = W * kDiscFraction;
    CGFloat discR    = discDiam / 2;
    CGFloat labelR   = discR * kLabelFraction;

    // Centre the disc horizontally, top area (leaving room for header above overlay).
    CGFloat discCX = W / 2;
    CGFloat discCY = H * 0.38;   // eye-balled: below the header, above the buttons

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _disc.discRadius  = discR;
    _disc.labelRadius = labelR;
    [_disc setNeedsLayout];
    [_disc layoutIfNeeded];
    _disc.position = CGPointMake(discCX, discCY);

    // Shadow under the disc.
    _disc.shadowColor  = [UIColor blackColor].CGColor;
    _disc.shadowOpacity = 0.6;
    _disc.shadowRadius = 30;
    _disc.shadowOffset = CGSizeMake(0, 10);

    // Tonearm pivot (top-right region of the disc area).
    CGPoint pivot = CGPointMake(W * kMountX, H * kMountY);
    _arm.pivotInHost = pivot;
    _arm.armLength   = W * kArmLength;
    _arm.frame       = self.bounds;
    _arm.angleRadians = [self _armAngleForProgress:_songProgress playing:_isPlaying];
    [_arm relayout];

    [CATransaction commit];

    // Pill buttons.
    CGFloat safeBottom = self.safeAreaInsets.bottom;
    CGFloat btnY   = H - safeBottom - kButtonBottom - kButtonHeight;
    CGFloat btnW   = kButtonHeight * 1.8;
    CGFloat midBtnW = kButtonHeight * 2.2;
    CGFloat spacing = 14;
    CGFloat totalW = btnW + midBtnW + btnW + 2 * spacing;
    CGFloat startX = (W - totalW) / 2;

    _btnPrev.frame = CGRectMake(startX, btnY, btnW, kButtonHeight);
    _btnPlay.frame = CGRectMake(startX + btnW + spacing, btnY, midBtnW, kButtonHeight);
    _btnNext.frame = CGRectMake(startX + btnW + spacing + midBtnW + spacing, btnY, btnW, kButtonHeight);
}

// ── Helpers ──

- (CGFloat)_armAngleForProgress:(double)progress playing:(BOOL)playing {
    CGFloat angle;
    if (!playing) {
        // Lifted to resting position
        angle = kArmLifted;
    } else {
        // Interpolate from outermost groove to innermost as song progresses
        angle = kArmOnDisc + (kArmEnd - kArmOnDisc) * (CGFloat)progress;
    }
    return angle * M_PI / 180.0;
}

// ── Disc tap ──

- (void)_discTapped {
    // Only register the tap if it's on the disc area.
    vinylTogglePlayback();
}

// ── Display link tick ──

- (void)_tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt  = (_lastTimestamp > 0) ? (now - _lastTimestamp) : 0;
    _lastTimestamp = now;

    if (dt > 0.2) dt = 0.2;   // clamp on resume from background

    CGFloat rps = 0;
    if (_isPlaying) {
        rps = kRPSPlaying;
        _coasting = NO;
    } else if (_coasting) {
        CGFloat elapsed = (CGFloat)(now - _coastStart);
        if (elapsed >= kCoastDuration) {
            _coasting = NO;
        } else {
            // Linear deceleration to zero
            rps = _coastInitialRPS * (1.0f - elapsed / kCoastDuration);
        }
    }

    if (rps > 0) {
        _discAngle += 2 * M_PI * rps * dt;
    }

    // Apply rotation to disc layer (no implicit transaction – we are already inside the display link).
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _disc.transform = CATransform3DMakeRotation(_discAngle, 0, 0, 1);
    [CATransaction commit];
}

// ── Artwork ──

- (void)setAlbumArt:(UIImage *)image {
    [_disc setAlbumArt:image];
}

- (void)_artworkChanged {
    UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
    if (art) [self setAlbumArt:art];
}

// ── Player state ──

- (void)playerStateDidChange:(SPTPlayerState *)state {
    BOOL wasPlaying = _isPlaying;
    _isPlaying = state.isPlaying && !state.isPaused;

    // Update coast state.
    if (wasPlaying && !_isPlaying) {
        _coasting        = YES;
        _coastStart      = CACurrentMediaTime();
        _coastInitialRPS = kRPSPlaying;
    }

    // Song progress for tonearm (position / duration).
    // positionAsOfTimestamp is close enough; we re-evaluate on every state change.
    double duration = state.duration;
    double position = state.positionAsOfTimestamp;
    if (duration > 0.5) {
        _songProgress = MAX(0, MIN(1, position / duration));
    } else {
        _songProgress = 0;
    }

    // Update play button glyph.
    [_btnPlay setSymbol:_isPlaying ? @"pause.fill" : @"play.fill"];

    // Animate tonearm.
    CGFloat targetAngle = [self _armAngleForProgress:_songProgress playing:_isPlaying];
    [CATransaction begin];
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"angleRadians"];
    anim.fromValue   = @(_arm.angleRadians);
    anim.toValue     = @(targetAngle);
    anim.duration    = 0.5;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    _arm.angleRadians = targetAngle;
    [_arm relayout];
    [CATransaction commit];
    (void)anim;
}

@end

// ─────────────────────────────────────────────────────
#pragma mark - overlay management
// ─────────────────────────────────────────────────────

static char kVinylOverlayKey;
static __weak SGRVinylOverlayView *sg_vinylOverlay;

static SGRVinylOverlayView *vinylOverlayIn(UIView *plane) {
    SGRVinylOverlayView *overlay = objc_getAssociatedObject(plane, &kVinylOverlayKey);
    if (overlay) return overlay;
    overlay = [[SGRVinylOverlayView alloc] initWithFrame:plane.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    objc_setAssociatedObject(plane, &kVinylOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sg_vinylOverlay = overlay;
    UIImage *art = SGRNowPlayingArtwork(NULL, NULL);
    if (art) [overlay setAlbumArt:art];
    SGLog(@"redesign player: vinyl overlay created %.0fx%.0f", plane.bounds.size.width, plane.bounds.size.height);
    return overlay;
}

// Keeps the overlay on top of everything in the plane except the Canvas clip (which we want beneath).
// Canvas clip view, if present, is kept just below our overlay.
static void placeOverlay(UIView *plane) {
    SGRVinylOverlayView *overlay = vinylOverlayIn(plane);

    // Resize to full plane.
    if (!CGRectEqualToRect(overlay.frame, plane.bounds)) overlay.frame = plane.bounds;

    // Insert at the top of the plane's subview stack (above Canvas, above Fluid field).
    if (overlay.superview != plane) {
        [plane addSubview:overlay];
    } else if (plane.subviews.lastObject != overlay) {
        [plane bringSubviewToFront:overlay];
    }
}

// ─────────────────────────────────────────────────────
#pragma mark - unit hiding helpers
// ─────────────────────────────────────────────────────

// We zero the alpha of the artwork list and the information / controls / footer units while vinyl is on.
// We never touch the header unit. This is called from viewDidLayoutSubviews of each unit.

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

// The background plane: insert our overlay here.
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    UIView *plane = ((UIViewController *)self).viewIfLoaded;
    if (!plane || plane.bounds.size.height < 200) return;
    placeOverlay(plane);
}
%end

// Artwork cell list: hide while vinyl is on so the disc is the only artwork visible.
%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideView((UIView *)self);
}
%end

// Playback controls (play/pause/prev/next/shuffle/repeat): hide behind our pill buttons.
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

// Duration bar: hide (our overlay has no scrubber by design).
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

// Information row (title, artist, add-to): hide it; our overlay shows the song name from the system.
%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!vinylOn()) return;
    hideUnit((UIViewController *)self);
}
%end

// Footer (lyrics, connect, queue glyphs): hide them.
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
#pragma mark - grab the SPTPlayer reference
// ─────────────────────────────────────────────────────
// PlayerState.x already hooks SPTEsperantoPlayer; we piggy-back on addPlayerObserver: to grab the player.

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
    return SGNotedSection(@"Vinyl", @[row], @"Tap the disc to pause or play. Restart Spotify to apply.");
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
