// The player's settings that do not depend on the look: controls for the system's lock screen widget.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"

UIViewController *SGLockScreenWidgetPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Lock screen widget" intro:SGRestartNote sections:@[
        SGSection(@"Controls", @[
            SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
            SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts"),
            SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls"),
            SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled"),
            SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled"),
        ]),
    ] footer:nil];
}
