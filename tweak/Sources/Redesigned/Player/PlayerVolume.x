// Keep the public iOS output-volume control in the player's bottom stack, between its transport
// controls and footer. This adjusts the iPhone's system output, not a Spotify Connect device.
#import <math.h>
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import <MediaPlayer/MediaPlayer.h>

static char kVolumeRowKey;

static UIImage *volumeTrackImage(UIColor *color) {
    CGSize size = CGSizeMake(6, 4);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    format.opaque = NO;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
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
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
    }];
}

@interface SGRCenteredVolumeView : MPVolumeView
@end

@implementation SGRCenteredVolumeView
- (void)sgr_recenterSlider {
    __block UISlider *slider = nil;
    __block CGFloat widest = 0;
    SGForEachView(self, ^(UIView *view) {
        if (![view isKindOfClass:UISlider.class] || view.bounds.size.width <= widest) return;
        widest = view.bounds.size.width;
        slider = (UISlider *)view;
    });
    if (!slider) return;
    // MPVolumeView recreates or hides its internal slider when the audio session
    // deactivates (pause). Until the next layout pass bounds/frames are zero or
    // the slider is temporarily at the top (y=0), which appeared as the volume
    // bar jumping up on every pause. Guard against zero sizes and against a pass
    // where the MPVolumeView itself has not been sized to its 44pt row yet.
    if (self.bounds.size.height < 10 || slider.bounds.size.height < 2) return;
    if (slider.bounds.size.width < 10) return;
    CGRect frame = slider.frame;
    CGFloat centeredY = round((self.bounds.size.height - frame.size.height) / 2);
    if (fabs(frame.origin.y - centeredY) > 0.5) {
        frame.origin.y = centeredY;
        slider.frame = frame;
    }
}

- (void)sgr_scheduleRecenter {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRCenteredVolumeView *strongSelf = weakSelf;
        if (!strongSelf) return;
        // The stack that hosts the volume row may not have laid out the row's
        // 44pt height yet when the audio notification fires on pause. Forcing
        // a layout on the nearest bottom stack first gives the MPVolumeView its
        // final bounds before centering, so the slider does not get centered
        // inside a transient zero-height bounds and then appear to jump.
        UIStackView *stack = nil;
        for (UIView *v = strongSelf; v; v = v.superview) {
            if ([v.superview isKindOfClass:UIStackView.class] && [v.superview.accessibilityIdentifier isEqualToString:@"npv.bottomStackView"]) {
                stack = (UIStackView *)v.superview;
                break;
            }
        }
        if (stack) [stack layoutIfNeeded];
        [strongSelf setNeedsLayout];
        [strongSelf layoutIfNeeded];
        [strongSelf sgr_recenterSlider];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf sgr_recenterSlider];
        });
    });
}

- (void)sgr_audioStateChanged:(NSNotification *)notification {
    (void)notification;
    [self sgr_scheduleRecenter];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(sgr_audioStateChanged:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(sgr_audioStateChanged:)
                   name:AVAudioSessionInterruptionNotification object:nil];
    // Pausing via the player's play button does not always post a route/interruption
    // notification, yet MPVolumeView still rebuilds its internals on the next runloop,
    // leaving the slider at the top until the next layout pass. Listening to the
    // player's own paused state as well makes the recentering fire on every pause/play.
    [center addObserver:self selector:@selector(sgr_audioStateChanged:) name:@"SGPlayerStateDidChange" object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self sgr_recenterSlider];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf sgr_recenterSlider];
    });
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self sgr_scheduleRecenter];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self sgr_scheduleRecenter];
}
@end

static void installVolumeRow(UIViewController *unit) {
    UIView *unitView = unit.viewIfLoaded, *controls = nil;
    UIStackView *stack = nil;
    for (UIView *view = unitView; view && !stack; view = view.superview) {
        if (![view.superview isKindOfClass:UIStackView.class]) continue;
        UIStackView *candidate = (UIStackView *)view.superview;
        if (![candidate.accessibilityIdentifier isEqualToString:@"npv.bottomStackView"]) continue;
        controls = view;
        stack = candidate;
    }
    if (!stack) return;

    UIStackView *row = objc_getAssociatedObject(stack, &kVolumeRowKey);
    if (!row) {
        row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8;
        row.layoutMarginsRelativeArrangement = YES;
        row.layoutMargins = UIEdgeInsetsMake(0, 24, 0, 24);
        UIImageSymbolConfiguration *iconConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImageView *quiet = [[UIImageView alloc] initWithImage:
            [[UIImage systemImageNamed:@"speaker.fill" withConfiguration:iconConfiguration]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        UIImageView *loud = [[UIImageView alloc] initWithImage:
            [[UIImage systemImageNamed:@"speaker.wave.3.fill" withConfiguration:iconConfiguration]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        for (UIImageView *icon in @[quiet, loud]) {
            icon.tintColor = [UIColor colorWithWhite:1 alpha:0.72];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.accessibilityElementsHidden = YES;
        }
        [quiet.widthAnchor constraintEqualToConstant:20].active = YES;
        [loud.widthAnchor constraintEqualToConstant:24].active = YES;
        [row addArrangedSubview:quiet];
        MPVolumeView *volume = [[SGRCenteredVolumeView alloc] initWithFrame:CGRectZero];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        volume.showsRouteButton = NO;
#pragma clang diagnostic pop
        volume.showsVolumeSlider = YES;
        UIImage *minimumTrack = volumeTrackImage([UIColor colorWithWhite:1 alpha:0.82]);
        UIImage *maximumTrack = volumeTrackImage([UIColor colorWithWhite:1 alpha:0.30]);
        UIImage *thumb = volumeThumbImage();
        for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled)]) {
            UIControlState controlState = state.unsignedIntegerValue;
            [volume setMinimumVolumeSliderImage:minimumTrack forState:controlState];
            [volume setMaximumVolumeSliderImage:maximumTrack forState:controlState];
            [volume setVolumeThumbImage:thumb forState:controlState];
        }
        volume.accessibilityLabel = @"iPhone volume";
        volume.translatesAutoresizingMaskIntoConstraints = NO;
        [volume setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [volume setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [volume.heightAnchor constraintEqualToConstant:44].active = YES;
        [row addArrangedSubview:volume];
        [row addArrangedSubview:loud];
        [row.heightAnchor constraintEqualToConstant:44].active = YES;
        objc_setAssociatedObject(stack, &kVolumeRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSUInteger controlsIndex = [stack.arrangedSubviews indexOfObject:controls];
    if (controlsIndex == NSNotFound) return;
    NSUInteger volumeIndex = [stack.arrangedSubviews indexOfObject:row];
    NSUInteger wantedIndex = controlsIndex + 1;
    if (volumeIndex == NSNotFound) {
        [stack insertArrangedSubview:row atIndex:wantedIndex];
    } else if (volumeIndex != wantedIndex) {
        [stack removeArrangedSubview:row];
        [row removeFromSuperview];
        controlsIndex = [stack.arrangedSubviews indexOfObject:controls];
        if (controlsIndex != NSNotFound) [stack insertArrangedSubview:row atIndex:controlsIndex + 1];
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: iPhone output-volume row inserted under playback controls"); });
}

%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    installVolumeRow((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl40ReinventFreePlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    installVolumeRow((UIViewController *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl40ReinventFreePlaybackControlsElementsUnit",
    ]);
}
