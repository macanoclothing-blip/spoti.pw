// Keep the public iOS output-volume control in the player's bottom stack, between its transport
// controls and footer. This adjusts the iPhone's system output, not a Spotify Connect device.
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
        MPVolumeView *volume = [[MPVolumeView alloc] initWithFrame:CGRectZero];
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
