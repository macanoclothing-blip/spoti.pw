// Keep the public iOS output-volume control in the player's bottom stack, between its transport
// controls and footer. This adjusts the iPhone's system output, not a Spotify Connect device.
#import "Core/SGCore.h"
#import <MediaPlayer/MediaPlayer.h>
#import "Redesigned/Kit/SGRAccent.h"

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
        row.spacing = 8;
        row.layoutMarginsRelativeArrangement = YES;
        row.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 20);
        UILabel *device = [UILabel new];
        device.text = @"iPhone";
        device.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        device.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.65];
        [device.widthAnchor constraintEqualToConstant:44].active = YES;
        [row addArrangedSubview:device];
        MPVolumeView *volume = [[MPVolumeView alloc] initWithFrame:CGRectZero];
        volume.showsRouteButton = NO;
        volume.showsVolumeSlider = YES;
        volume.tintColor = SGRAccent();
        volume.accessibilityLabel = @"iPhone volume";
        [row addArrangedSubview:volume];
        [row.heightAnchor constraintEqualToConstant:30].active = YES;
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
