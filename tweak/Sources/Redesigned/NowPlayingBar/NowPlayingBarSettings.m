// The redesign's rows on the Player page (App/Pages.m puts them there): the bar and what moves behind
// the player.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlayingBar.h"
#import "Redesigned/Player/Player.h"
#import "Redesigned/Player/PlayerVinyl.h"

NSArray<SGModSection *> *SGRNowPlayingSections(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    [sections addObject:SGSection(nil, @[
        SGHideRow(@"Hide the device button", nil, SGRHideBarConnect),
    ])];
    [sections addObjectsFromArray:SGRPlayerBackgroundSections()];
    [sections addObject:SGRVinylSection()];
    return sections;
}
