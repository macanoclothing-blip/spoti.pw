// A fixed, touchable volume lane between the transport controls and the footer.
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"
#import "PlayerVinyl.h"

static const CGFloat kVolumeRowHeight = 32;
static const CGFloat kVolumeGlyphSize = 13;
static const CGFloat kVolumeGlyphGap = 10;
static const CGFloat kVolumeSideInset = 24;
static const CGFloat kVolumeControlClearance = 6;
static const CGFloat kVolumeTrackRest = 5, kVolumeTrackHeld = 8;
static const CGFloat kVolumeFillRest = 0.70, kVolumeFillHeld = 1, kVolumeEmpty = 0.30;
static char kVolumeRowKey;
static char kPreviousButtonKey, kPlayButtonKey, kNextButtonKey;
static char kVolumeSessionContext, kVolumeSliderContext;

static UIImageView *volumeGlyph(NSString *symbol) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:kVolumeGlyphSize weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    UIImageView *view = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    view.tintColor = [UIColor colorWithWhite:1 alpha:0.72];
    view.contentMode = UIViewContentModeCenter;
    view.accessibilityElementsHidden = YES;
    return view;
}

static CGRect volumeControlsFrame(UIView *controls, UIView *stack) {
    static const void *keys[] = {&kPreviousButtonKey, &kPlayButtonKey, &kNextButtonKey};
    NSArray<NSString *> *identifiers = @[
        @"SPTNowPlayingShuffleButton", @"Components.UI.ShuffleButton",
        @"SPTNowPlayingPreviousTrackButton", @"SPTNowPlayingPlayButton", @"SPTNowPlayingNextTrackButton",
        @"SPTNowPlayingRepeatButton", @"Components.UI.RepeatButton", @"Nowplaying-RepeatButton"
    ];
    // Anchor to the controls' actual hit areas, rather than the often much taller unit view.
    CGRect frame = CGRectNull;
    for (NSString *identifier in identifiers) {
        const void *key = nil;
        if ([identifier isEqualToString:@"SPTNowPlayingPreviousTrackButton"]) key = keys[0];
        else if ([identifier isEqualToString:@"SPTNowPlayingPlayButton"]) key = keys[1];
        else if ([identifier isEqualToString:@"SPTNowPlayingNextTrackButton"]) key = keys[2];
        UIView *button = SGRFindByIdentifier(stack ?: controls, identifier, key);
        if (!button || button.hidden || button.alpha < 0.01) continue;
        CGRect buttonFrame = [button convertRect:button.bounds toView:stack];
        frame = CGRectIsNull(frame) ? buttonFrame : CGRectUnion(frame, buttonFrame);
    }
    if (CGRectIsNull(frame)) frame = [controls convertRect:controls.bounds toView:stack];
    return CGRectInset(frame, -2, -4);
}

@interface SGRVolumeRow : UIControl
@end

@implementation SGRVolumeRow {
    MPVolumeView *_system;
    UISlider *_systemSlider;
    UIView *_track, *_fill;
    UIImageView *_quiet, *_loud;
    CGFloat _value, _trackMin, _trackMax;
    BOOL _held, _observingSession, _observingSlider;
    NSTimer *_poll;
    CFTimeInterval _lastPush;
    NSHashTable<UIGestureRecognizer *> *_suspended;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;

    // Keep Apple's volume engine in the hierarchy, but draw and lay out the visible track ourselves.
    _system = [MPVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _system.showsRouteButton = NO;
#pragma clang diagnostic pop
    _system.alpha = 0.01;
    _system.userInteractionEnabled = NO;
    _system.accessibilityElementsHidden = YES;
    [self addSubview:_system];

    _track = [UIView new];
    _track.userInteractionEnabled = NO;
    _track.clipsToBounds = YES;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    _track.backgroundColor = [UIColor colorWithWhite:1 alpha:kVolumeEmpty];
    _fill = [UIView new];
    _fill.userInteractionEnabled = NO;
    _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:kVolumeFillRest];
    [_track addSubview:_fill];
    [self addSubview:_track];

    _quiet = volumeGlyph(@"speaker.fill");
    _loud = volumeGlyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_loud];

    _value = AVAudioSession.sharedInstance.outputVolume;
    @try {
        [AVAudioSession.sharedInstance addObserver:self forKeyPath:@"outputVolume"
                                           options:NSKeyValueObservingOptionNew context:&kVolumeSessionContext];
        _observingSession = YES;
    } @catch (__unused NSException *exception) {}
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshFromSystem)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Volume";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    return self;
}

- (void)dealloc {
    [_poll invalidate];
    [self restoreAncestorGestures];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_observingSession) {
        [AVAudioSession.sharedInstance removeObserver:self forKeyPath:@"outputVolume" context:&kVolumeSessionContext];
    }
    if (_observingSlider) {
        [_systemSlider removeObserver:self forKeyPath:@"value" context:&kVolumeSliderContext];
    }
}

- (UISlider *)systemSlider {
    if (!_systemSlider) {
        __block UISlider *slider = nil;
        SGForEachView(_system, ^(UIView *view) {
            if (!slider && [view isKindOfClass:UISlider.class]) slider = (UISlider *)view;
        });
        _systemSlider = slider;
        if (_systemSlider) @try {
            [_systemSlider addObserver:self forKeyPath:@"value" options:NSKeyValueObservingOptionNew
                               context:&kVolumeSliderContext];
            _observingSlider = YES;
        } @catch (__unused NSException *exception) {}
    }
    _systemSlider.thumbTintColor = UIColor.clearColor;
    _systemSlider.minimumTrackTintColor = UIColor.clearColor;
    _systemSlider.maximumTrackTintColor = UIColor.clearColor;
    return _systemSlider;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kVolumeSliderContext && context != &kVolumeSessionContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFromSystem]; });
}

- (void)refreshFromSystem {
    if (_held || CACurrentMediaTime() - _lastPush < 0.6) return;
    UISlider *slider = [self systemSlider];
    CGFloat systemValue = slider ? slider.value : AVAudioSession.sharedInstance.outputVolume;
    if (fabs(systemValue - _value) > 0.002) [self setVolumeValue:systemValue fromUser:NO];
}

- (void)pushVolume {
    UISlider *slider = [self systemSlider];
    if (!slider) return;
    _lastPush = CACurrentMediaTime();
    [slider setValue:_value animated:NO];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)syncTrack {
    CGFloat height = MIN(_held ? kVolumeTrackHeld : kVolumeTrackRest, MAX(1, CGRectGetHeight(self.bounds) - 4));
    CGFloat scale = self.traitCollection.displayScale ?: 3;
    CGFloat top = round((CGRectGetMidY(self.bounds) - height / 2) * scale) / scale;
    _track.frame = CGRectMake(_trackMin, top, MAX(0, _trackMax - _trackMin), height);
    _track.layer.cornerRadius = height / 2;
    _fill.frame = CGRectMake(0, 0, CGRectGetWidth(_track.bounds) * _value, CGRectGetHeight(_track.bounds));
}

- (void)syncStyle {
    _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:_held ? kVolumeFillHeld : kVolumeFillRest];
    _quiet.alpha = _loud.alpha = _held ? 1 : 0.72;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat rowHeight = MIN(kVolumeRowHeight, CGRectGetHeight(bounds));
    CGFloat middle = CGRectGetMidY(bounds);
    CGFloat glyphWidth = rowHeight / 2 + kVolumeGlyphSize / 2;
    CGFloat loudX = CGRectGetWidth(bounds) - glyphWidth;

    // The system view is an invisible output-volume adapter only.
    _system.frame = CGRectMake(0, 0, MAX(140, CGRectGetWidth(bounds)), rowHeight);
    [_system layoutIfNeeded];
    [self systemSlider];

    _quiet.bounds = _loud.bounds = CGRectMake(0, 0, glyphWidth, rowHeight);
    _quiet.center = CGPointMake(glyphWidth / 2, middle);
    _loud.center = CGPointMake(loudX + glyphWidth / 2, middle);
    _trackMin = glyphWidth + kVolumeGlyphGap;
    _trackMax = loudX - kVolumeGlyphGap;
    [self syncTrack];
    [self syncStyle];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [_poll invalidate];
        _poll = nil;
        [self restoreAncestorGestures];
        return;
    }
    [self systemSlider];
    [self refreshFromSystem];
    if (_poll) return;
    __weak SGRVolumeRow *weakSelf = self;
    _poll = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf refreshFromSystem];
    }];
    _poll.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:_poll forMode:NSRunLoopCommonModes];
}

- (void)suspendAncestorGestures {
    if (_suspended) return;
    _suspended = [NSHashTable weakObjectsHashTable];
    for (UIView *view = self.superview; view; view = view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if (![recognizer isKindOfClass:UIPanGestureRecognizer.class] ||
                [recognizer isKindOfClass:UIScreenEdgePanGestureRecognizer.class] || !recognizer.enabled) continue;
            recognizer.enabled = NO;
            [_suspended addObject:recognizer];
        }
    }
}

- (void)restoreAncestorGestures {
    for (UIGestureRecognizer *recognizer in _suspended) recognizer.enabled = YES;
    _suspended = nil;
}

- (void)setVolumeValue:(CGFloat)value fromUser:(BOOL)fromUser {
    _value = MIN(1, MAX(0, value));
    if (!fromUser && !_held && self.window) {
        [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionBeginFromCurrentState |
             UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                         animations:^{ [self syncTrack]; } completion:nil];
    } else {
        [self syncTrack];
    }
    if (fromUser) [self pushVolume];
}

- (void)setHeld:(BOOL)held {
    if (_held == held) return;
    _held = held;
    if (held) [self suspendAncestorGestures]; else [self restoreAncestorGestures];
    void (^apply)(void) = ^{ [self syncTrack]; [self syncStyle]; };
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    [UIView animateWithDuration:held ? 0.16 : 0.14 delay:0 options:options animations:apply completion:nil];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self setHeld:YES];
    CGFloat x = [touch locationInView:self].x;
    CGFloat span = MAX(1, _trackMax - _trackMin);
    [self setVolumeValue:(x - _trackMin) / span fromUser:YES];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat x = [touch locationInView:self].x;
    CGFloat span = MAX(1, _trackMax - _trackMin);
    [self setVolumeValue:(x - _trackMin) / span fromUser:YES];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { [self setHeld:NO]; }
- (void)cancelTrackingWithEvent:(UIEvent *)event { [self setHeld:NO]; }

- (NSString *)accessibilityValue { return [NSString stringWithFormat:@"%d%%", (int)round(_value * 100)]; }
- (void)accessibilityIncrement { [self setVolumeValue:_value + 0.0625 fromUser:YES]; }
- (void)accessibilityDecrement { [self setVolumeValue:_value - 0.0625 fromUser:YES]; }

@end

BOOL SGRPlayerLayoutVolume(UIView *stack, UIView *controls, UIView *footer) {
    if (!stack) return NO;
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeRowKey);
    if (!volume) {
        volume = [SGRVolumeRow new];
        objc_setAssociatedObject(stack, &kVolumeRowKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (volume.superview != stack) [stack addSubview:volume];

    UIInterfaceOrientation orientation = stack.window.windowScene.interfaceOrientation;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation) ||
        (!UIInterfaceOrientationIsPortrait(orientation) && stack.window.bounds.size.width > stack.window.bounds.size.height);
    // Lyrics take over the landscape player. Once they close, restore the same volume lane
    // between the now-restored transport and footer controls.
    if (landscape && SGRPlayerLyricsOpen()) {
        volume.hidden = YES;
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        return NO;
    }
    volume.hidden = NO;
    volume.userInteractionEnabled = YES;
    volume.accessibilityElementsHidden = NO;
    if (!controls || !footer || !stack.window) {
        volume.alpha = 0;
        SGLog(@"redesign player: volume row has no window, controls or footer");
        return NO;
    }

    CGRect controlsFrame = volumeControlsFrame(controls, stack);
    CGRect footerFrame = [footer convertRect:footer.bounds toView:stack];
    // One stable lane, measured after Spotify lays out both units. Never place the slider over the
    // progress track or another control, even when the player resizes or rotates automatically.
    CGFloat top = CGRectGetMaxY(controlsFrame) + kVolumeControlClearance;
    CGFloat bottom = CGRectGetMinY(footerFrame) - kVolumeControlClearance;
    CGFloat room = bottom - top;
    CGFloat width = MAX(0, CGRectGetWidth(stack.bounds) - 2 * kVolumeSideInset);
    CGFloat rowHeight = MIN(kVolumeRowHeight, room);
    if (width < 1 || rowHeight < 18) {
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        static NSUInteger noGapLogs;
        if (noGapLogs++ < 3) SGLog(@"redesign player: volume row hidden because no controls-to-footer gap is available (%.0fpt)", room);
        return NO;
    }

    CGRect frame = CGRectMake(kVolumeSideInset, round(top + (room - rowHeight) / 2), width, rowHeight);
    if (SGFlag(SGRKeyPlayerVinyl, NO)) frame.origin.y -= 14;
    if (CGRectIntersectsRect(frame, controlsFrame) || CGRectIntersectsRect(frame, footerFrame)) {
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        SGLog(@"redesign player: volume row suppressed after collision guard");
        return NO;
    }
    if (!CGRectEqualToRect(volume.frame, frame)) volume.frame = frame;
    [stack bringSubviewToFront:volume];
    if (volume.alpha != 1) volume.alpha = 1;
    return YES;
}
