// The redesign's rows on the Player page (App/Pages.m puts them there): the bar and what moves behind
// the player.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlayingBar.h"
#import "Redesigned/Player/Player.h"
#import "Redesigned/Player/PlayerVinyl.h"

NSArray<SGModSection *> *SGRNowPlayingSections(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    SGModRow *idleChrome = SGSwitchRow(@"Hide player controls when idle",
        @"After 3 seconds, fade the player controls and move the track details and progress bar lower while music is playing",
        SGRKeyPlayerIdleChrome);
    idleChrome.changed = ^(BOOL enabled) {
        (void)enabled;
        SGRPlayerIdleChromeSettingChanged();
    };
    [sections addObject:SGSection(nil, @[
        SGHideRow(@"Hide the device button", nil, SGRHideBarConnect),
        SGSwitchRow(@"Show rotation button", @"Show the button used to rotate the lyrics player", SGRKeyPlayerAutoRotate),
        idleChrome,
    ])];
    [sections addObjectsFromArray:SGRPlayerBackgroundSections()];
    [sections addObject:SGRVinylSection()];
    return sections;
}
