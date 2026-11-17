// Place the system output-volume control in the space between the transport controls and footer.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Moments/Moments.h"
#import "Player.h"
#import "PlayerVinyl.h"

static const CGFloat kVolumeRowHeight = 34;
static const CGFloat kMomentButtonHeight = 38;
static const CGFloat kMomentButtonCompactHeight = 34;
static const CGFloat kMomentButtonWidth = 224;
static const CGFloat kVolumeGlyphSize = 16;
static const CGFloat kVolumeGlyphGap = 8;
static const CGFloat kVolumeSideInset = 24;
static const CGFloat kVolumeControlClearance = 12;
static const CGFloat kControlsBottomPadding = 14;
static const CGFloat kMaxControlsLift = 60;
static char kVolumeRowKey;
static char kMomentButtonKey, kMomentButtonGlassKey;
static char kPreviousButtonKey, kPlayButtonKey, kNextButtonKey;
static char kVolumeProgressSliderKey;
static BOOL sg_idleHidden;

static UIImage *volumeTrackImage(UIColor *color) {
    CGSize size = CGSizeMake(6, 4);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    format.opaque = NO;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
            [color setFill];
            [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size}
                                        cornerRadius:size.height / 2] fill];
        }];
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 2, 0, 2)
                                 resizingMode:UIImageResizingModeStretch];
}

static UIImage *volumeThumbImage(void) {
    CGSize size = CGSizeMake(18, 18);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
        }];
}

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
        @"SPTNowPlayingPreviousTrackButton", @"SPTNowPlayingPlayButton", @"SPTNowPlayingNextTrackButton"
    ];
    // Use the whole controls unit as the safe envelope. Spotify's button identifiers can sit on small
    // inner views while their rendered glyphs and hit targets extend past those bounds.
    CGRect frame = [controls convertRect:controls.bounds toView:stack];
    for (NSUInteger index = 0; index < identifiers.count; index++) {
        UIView *button = SGRFindByIdentifier(controls, identifiers[index], keys[index]);
        if (!button || button.hidden || button.alpha < 0.01) continue;
        CGRect buttonFrame = [button convertRect:button.bounds toView:stack];
        frame = CGRectUnion(frame, buttonFrame);
    }
    return CGRectInset(frame, -2, -4);
}

@interface SGRVolumeRow : UIView
@end

@interface SGRMomentCommentButton : UIControl
@end

@implementation SGRMomentCommentButton {
    SGRGlyphView *_glyph;
    UILabel *_title;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.accessibilityLabel = @"Lascia un commento";
    self.accessibilityHint = @"Aggiunge una frase al minuto scelto del brano";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _glyph = [[SGRGlyphView alloc] initWithSymbol:@"quote.bubble" pointSize:16 weight:UIImageSymbolWeightSemibold];
    _glyph.tintColor = UIColor.whiteColor;
    _glyph.userInteractionEnabled = NO;
    _title = [UILabel new];
    _title.text = @"Lascia un commento";
    _title.textColor = UIColor.whiteColor;
    _title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _title.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    [self addSubview:_title];
    [self addTarget:self action:@selector(openComposer) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat contentWidth = 20 + 8 + _title.intrinsicContentSize.width;
    CGFloat start = MAX(14, (CGRectGetWidth(self.bounds) - contentWidth) / 2);
    _glyph.frame = CGRectMake(start, (CGRectGetHeight(self.bounds) - 20) / 2, 20, 20);
    _title.frame = CGRectMake(CGRectGetMaxX(_glyph.frame) + 8, 0,
                              MAX(0, CGRectGetWidth(self.bounds) - CGRectGetMaxX(_glyph.frame) - 14),
                              CGRectGetHeight(self.bounds));
    SGRGlassCapsuleInside(self, &kMomentButtonGlassKey, self.bounds.size, NO);
}

- (void)openComposer {
    SGRPresentMomentComposer(self);
}

@end

static SGRMomentCommentButton *momentCommentButton(UIView *stack) {
    SGRMomentCommentButton *button = objc_getAssociatedObject(stack, &kMomentButtonKey);
    if (!button) {
        button = [SGRMomentCommentButton new];
        objc_setAssociatedObject(stack, &kMomentButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *host = stack.superview ?: stack;
    if (button.superview != host) [host addSubview:button];
    return button;
}

@interface SGRInteractiveVolumeView : MPVolumeView
@end

@implementation SGRInteractiveVolumeView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(1, 1.55);
    } completion:nil];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self sgr_restoreTrack];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self sgr_restoreTrack];
}
- (void)sgr_restoreTrack {
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}
@end

@implementation SGRVolumeRow {
    MPVolumeView *_volume;
    UIImageView *_quiet;
    UIImageView *_loud;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _volume = [SGRInteractiveVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _volume.showsRouteButton = NO;
#pragma clang diagnostic pop
    _volume.showsVolumeSlider = YES;
    UIImage *minimumTrack = volumeTrackImage([UIColor colorWithWhite:1 alpha:0.82]);
    UIImage *maximumTrack = volumeTrackImage([UIColor colorWithWhite:1 alpha:0.30]);
    UIImage *thumb = volumeThumbImage();
    for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled)]) {
        UIControlState controlState = state.unsignedIntegerValue;
        [_volume setMinimumVolumeSliderImage:minimumTrack forState:controlState];
        [_volume setMaximumVolumeSliderImage:maximumTrack forState:controlState];
        [_volume setVolumeThumbImage:thumb forState:controlState];
    }
    _volume.accessibilityLabel = @"iPhone volume";
    _quiet = volumeGlyph(@"speaker.fill");
    _loud = volumeGlyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_volume];
    [self addSubview:_loud];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat midY = CGRectGetMidY(bounds);
    CGFloat iconWidth = kVolumeRowHeight / 2 + kVolumeGlyphSize / 2;
    _quiet.frame = CGRectMake(0, midY - kVolumeRowHeight / 2, iconWidth, kVolumeRowHeight);
    _loud.frame = CGRectMake(CGRectGetWidth(bounds) - iconWidth, midY - kVolumeRowHeight / 2,
                             iconWidth, kVolumeRowHeight);
    CGFloat left = CGRectGetMaxX(_quiet.frame) + kVolumeGlyphGap;
    CGFloat right = CGRectGetMinX(_loud.frame) - kVolumeGlyphGap;
    CGSize fitting = [_volume sizeThatFits:CGSizeMake(MAX(0, right - left), kVolumeRowHeight)];
    CGFloat volumeHeight = fitting.height > 0 ? MIN(kVolumeRowHeight, fitting.height) : kVolumeRowHeight;
    _volume.frame = CGRectMake(left, round(midY - volumeHeight / 2),
                               MAX(0, right - left), volumeHeight);
}

@end

static UIView *volumeArrangedRow(UIStackView *stack, UIView *view) {
    for (UIView *candidate = view; candidate && candidate != stack; candidate = candidate.superview) {
        if (candidate.superview == stack) return candidate;
    }
    return nil;
}

BOOL SGRPlayerLayoutVinylVolume(UIView *stack) {
    SGRVolumeRow *volume = stack ? objc_getAssociatedObject(stack, &kVolumeRowKey) : nil;
    if (!stack || !volume) return NO;
    SGRMomentCommentButton *comment = objc_getAssociatedObject(stack, &kMomentButtonKey);
    comment.hidden = YES;
    UIInterfaceOrientation orientation = stack.window.windowScene.interfaceOrientation;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation) ||
        (!UIInterfaceOrientationIsPortrait(orientation) && stack.window.bounds.size.width > stack.window.bounds.size.height);
    if (landscape || !stack.window) {
        volume.hidden = YES;
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        return NO;
    }

    CGRect buttons = SGRVinylTransportButtonsFrameInView(stack);
    if (CGRectIsNull(buttons) || CGRectIsEmpty(buttons)) {
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        return NO;
    }
    UIView *slider = SGRFindByIdentifier(stack, @"SPTNowPlayingSliderV2", &kVolumeProgressSliderKey);
    UIView *progress = slider ? volumeArrangedRow((UIStackView *)stack, slider) : nil;
    CGRect progressFrame = progress ? [progress convertRect:progress.bounds toView:stack] : CGRectNull;

    CGFloat bottom = CGRectGetMinY(buttons) - kVolumeControlClearance;
    CGFloat top = CGRectIsNull(progressFrame) ? CGRectGetMinY(stack.bounds) + 48
                                             : CGRectGetMaxY(progressFrame) + 8;
    CGFloat available = MAX(0, bottom - top);
    CGFloat height = MIN(kVolumeRowHeight, available);
    // The controls sit on the lower edge of the player's artwork. A compact row is still preferable
    // to letting Spotify's old layout put the slider across the transport buttons.
    if (height < 18) {
        top = MAX(CGRectGetMinY(stack.bounds) + 24, bottom - 22);
        height = MAX(18, bottom - top);
    }
    CGFloat width = MAX(0, CGRectGetWidth(stack.bounds) - 2 * kVolumeSideInset);
    CGRect frame = CGRectMake(kVolumeSideInset, round(bottom - height), width, height);
    volume.hidden = NO;
    volume.userInteractionEnabled = YES;
    volume.accessibilityElementsHidden = NO;
    volume.frame = frame;
    [volume setNeedsLayout];
    [stack bringSubviewToFront:volume];
    __block MPVolumeView *systemVolume = nil;
    SGForEachView(volume, ^(UIView *view) {
        if (!systemVolume && [view isKindOfClass:MPVolumeView.class]) systemVolume = (MPVolumeView *)view;
    });
    SGRVinylStyleVolumeView(systemVolume);
    volume.alpha = 1;
    return YES;
}

BOOL SGRPlayerLayoutVolume(UIView *stack, UIView *controls, UIView *footer) {
    if (!stack) return NO;
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeRowKey);
    if (!volume) {
        volume = [SGRVolumeRow new];
        objc_setAssociatedObject(stack, &kVolumeRowKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (volume.superview != stack) [stack addSubview:volume];
    SGRMomentCommentButton *comment = momentCommentButton(stack);
    if (SGFlag(SGRKeyPlayerVinyl, NO)) return SGRPlayerLayoutVinylVolume(stack);
    UIInterfaceOrientation orientation = stack.window.windowScene.interfaceOrientation;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation) ||
        (!UIInterfaceOrientationIsPortrait(orientation) && stack.window.bounds.size.width > stack.window.bounds.size.height);
    if (landscape) {
        volume.hidden = YES;
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        comment.hidden = YES;
        comment.userInteractionEnabled = NO;
        comment.accessibilityElementsHidden = YES;
        return NO;
    }
    volume.hidden = NO;
    volume.userInteractionEnabled = !sg_idleHidden;
    volume.accessibilityElementsHidden = sg_idleHidden;
    comment.hidden = sg_idleHidden || !SGRMomentsEnabled();
    comment.userInteractionEnabled = !sg_idleHidden && !comment.hidden;
    comment.accessibilityElementsHidden = sg_idleHidden || comment.hidden;
    comment.alpha = sg_idleHidden || comment.hidden ? 0 : 1;
    if (!stack.window) {
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        comment.hidden = YES;
        SGLog(@"redesign player: player controls have no window");
        return NO;
    }

    UIView *playButton = controls
        ? SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kPlayButtonKey)
        : SGRFindByIdentifier(stack.window, @"SPTNowPlayingPlayButton", &kPlayButtonKey);
    CGRect controlsFrame = controls ? volumeControlsFrame(controls, stack) : CGRectNull;
    if (CGRectIsNull(controlsFrame) && playButton) controlsFrame = [playButton convertRect:playButton.bounds toView:stack];
    CGRect footerFrame = footer ? [footer convertRect:footer.bounds toView:stack] :
        CGRectMake(0, CGRectGetHeight(stack.bounds) - stack.safeAreaInsets.bottom - 44,
                   CGRectGetWidth(stack.bounds), 44);
    CGFloat top = CGRectIsNull(controlsFrame)
        ? MAX(stack.safeAreaInsets.top + 24, CGRectGetHeight(stack.bounds) * 0.58)
        : CGRectGetMaxY(controlsFrame) - kControlsBottomPadding + kVolumeControlClearance;
    CGFloat bottom = CGRectGetMinY(footerFrame) - kVolumeControlClearance;
    CGFloat room = bottom - top;
    CGFloat buttonHeight = kMomentButtonHeight;
    CGFloat buttonGap = 6;
    CGFloat availableLift = CGRectIsNull(controlsFrame) ? 0 :
        MIN(kMaxControlsLift, MAX(0, CGRectGetMinY(controlsFrame) - MAX(stack.safeAreaInsets.top + 24, 32)));
    CGFloat desiredRoom = comment.hidden ? kVolumeRowHeight :
        kMomentButtonHeight + buttonGap + kVolumeRowHeight;
    if (room < desiredRoom && controls && availableLift > 0) {
        CGFloat shortage = MIN(desiredRoom - room, availableLift);
        CGAffineTransform transform = controls.transform;
        transform.ty -= shortage;
        controls.transform = transform;
        controlsFrame = volumeControlsFrame(controls, stack);
        top = CGRectGetMaxY(controlsFrame) - kControlsBottomPadding + kVolumeControlClearance;
        room = bottom - top;
    }
    if (CGRectIsNull(controlsFrame)) {
        SGLog(@"redesign player: transport container not found; placing Moments from the play button or player bounds");
    }

    if (!comment.hidden) {
        if (room < kMomentButtonHeight + buttonGap) {
            buttonHeight = kMomentButtonCompactHeight;
            buttonGap = 6;
        }
        CGFloat minButtonY = CGRectIsNull(controlsFrame)
            ? top : CGRectGetMaxY(controlsFrame) - kControlsBottomPadding + kVolumeControlClearance;
        CGFloat buttonY = MIN(minButtonY, bottom - buttonHeight);
        CGFloat buttonWidth = MIN(kMomentButtonWidth, MAX(0, CGRectGetWidth(stack.bounds) - 2 * kVolumeSideInset));
        CGRect buttonFrame = [stack convertRect:CGRectMake((CGRectGetWidth(stack.bounds) - buttonWidth) / 2,
                                                            buttonY, buttonWidth, buttonHeight)
                                          toView:comment.superview];
        CGRect hostBounds = comment.superview.bounds;
        buttonFrame.origin.x = round((CGRectGetWidth(hostBounds) - buttonWidth) / 2);
        buttonFrame.origin.y = MIN(MAX(buttonFrame.origin.y, CGRectGetMinY(hostBounds)),
                                   CGRectGetMaxY(hostBounds) - buttonHeight);
        comment.frame = buttonFrame;
        comment.hidden = room < buttonHeight + buttonGap || !CGRectContainsRect(hostBounds, buttonFrame);
        if (comment.hidden && SGRMomentsEnabled()) {
            static NSUInteger hiddenMomentLogs;
            if (hiddenMomentLogs++ < 5) {
                SGLog(@"redesign player: Moments button awaiting room (%.0fpt; controls %@, footer %@)",
                      room, NSStringFromCGRect(controlsFrame), NSStringFromCGRect(footerFrame));
            }
        }
        comment.userInteractionEnabled = !comment.hidden && !sg_idleHidden;
        comment.accessibilityElementsHidden = comment.hidden || sg_idleHidden;
        comment.alpha = sg_idleHidden || comment.hidden ? 0 : 1;
        [comment.superview bringSubviewToFront:comment];
    }

    CGFloat width = MAX(0, CGRectGetWidth(stack.bounds) - 2 * kVolumeSideInset);
    CGFloat volumeTop = top;
    if (!comment.hidden) {
        volumeTop = [comment.superview convertPoint:CGPointMake(0, CGRectGetMaxY(comment.frame) + buttonGap)
                                             toView:stack].y;
    }
    CGFloat volumeRoom = bottom - volumeTop;
    CGFloat rowHeight = MIN(kVolumeRowHeight, volumeRoom);
    if (width < 1 || rowHeight < 18) {
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        if (!comment.hidden) [comment.superview bringSubviewToFront:comment];
        static NSUInteger noGapLogs;
        if (noGapLogs++ < 3) SGLog(@"redesign player: volume row hidden; Moments button remains visible (room %.0fpt)", room);
        return NO;
    }
    CGFloat rowY = round(volumeTop + (volumeRoom - rowHeight) / 2);
    CGRect frame = CGRectMake(kVolumeSideInset, rowY, width, rowHeight);
    if ((!CGRectIsNull(controlsFrame) && CGRectIntersectsRect(frame, controlsFrame)) ||
        CGRectIntersectsRect(frame, footerFrame)) {
        volume.alpha = 0;
        volume.userInteractionEnabled = NO;
        volume.accessibilityElementsHidden = YES;
        if (!comment.hidden) [comment.superview bringSubviewToFront:comment];
        SGLog(@"redesign player: volume row suppressed by collision guard; Moments button remains visible");
        return NO;
    }
    if (!CGRectEqualToRect(volume.frame, frame)) volume.frame = frame;
    [stack bringSubviewToFront:volume];
    CGFloat alpha = sg_idleHidden ? 0 : 1;
    if (volume.alpha != alpha) volume.alpha = alpha;
    if (!comment.hidden) {
        comment.alpha = alpha;
        comment.userInteractionEnabled = !sg_idleHidden;
        comment.accessibilityElementsHidden = sg_idleHidden;
        [comment.superview bringSubviewToFront:comment];
    }
    return YES;
}

void SGRPlayerSetVolumeIdleHidden(UIView *stack, BOOL hidden) {
    sg_idleHidden = hidden;
    SGRMomentCommentButton *comment = stack ? objc_getAssociatedObject(stack, &kMomentButtonKey) : nil;
    if (comment) {
        comment.hidden = hidden || !SGRMomentsEnabled();
        comment.userInteractionEnabled = !comment.hidden;
        comment.accessibilityElementsHidden = comment.hidden;
        comment.alpha = comment.hidden ? 0 : 1;
    }
    SGRVolumeRow *volume = stack ? objc_getAssociatedObject(stack, &kVolumeRowKey) : nil;
    if (!volume || SGFlag(SGRKeyPlayerVinyl, NO)) return;
    UIInterfaceOrientation orientation = stack.window.windowScene.interfaceOrientation;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation) ||
        (!UIInterfaceOrientationIsPortrait(orientation) && stack.window.bounds.size.width > stack.window.bounds.size.height);
    if (landscape) return;
    volume.userInteractionEnabled = !hidden;
    volume.accessibilityElementsHidden = hidden;
    volume.alpha = hidden ? 0 : 1;
}
