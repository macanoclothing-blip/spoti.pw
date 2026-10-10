// Keep the public iOS output-volume control in the player's bottom stack, between its transport
// controls and footer. This adjusts the iPhone's system output, not a Spotify Connect device.
#import "Core/SGCore.h"
#import <MediaPlayer/MediaPlayer.h>
#import "Redesigned/Kit/SGRTokens.h"

static char kVolumeRowKey;

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
        row.spacing = 10;
        row.layoutMarginsRelativeArrangement = YES;
        row.layoutMargins = UIEdgeInsetsMake(0, 18, 0, 18);
        UIImageView *quiet = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.fill"]];
        quiet.tintColor = SGRSecondary();
        quiet.contentMode = UIViewContentModeScaleAspectFit;
        [quiet.widthAnchor constraintEqualToConstant:18].active = YES;
        [row addArrangedSubview:quiet];
        MPVolumeView *volume = [[MPVolumeView alloc] initWithFrame:CGRectZero];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        volume.showsRouteButton = NO;
#pragma clang diagnostic pop
        volume.showsVolumeSlider = YES;
        volume.tintColor = SGRAccent();
        volume.accessibilityLabel = @"iPhone volume";
        volume.translatesAutoresizingMaskIntoConstraints = NO;
        [volume.heightAnchor constraintEqualToConstant:30].active = YES;
        [row addArrangedSubview:volume];
        UIImageView *loud = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.wave.3.fill"]];
        loud.tintColor = SGRSecondary();
        loud.contentMode = UIViewContentModeScaleAspectFit;
        [loud.widthAnchor constraintEqualToConstant:20].active = YES;
        [row addArrangedSubview:loud];
        [row.heightAnchor constraintEqualToConstant:36].active = YES;
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
