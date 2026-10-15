// The animated-artwork source-order row used by the redesigned player.
#import "Core/SGCore.h"
#import "Settings/SGOrderPage.h"
#import "Settings/SGPageStyle.h"
#import "LockScreenArtwork.h"

static NSArray<SGOrderItem *> *sources(void) {
    return @[
        SGOrderItemMake(SGArtworkSourceSpotify, @"Spotify Canvas", @"The track's own clip"),
        SGOrderItemMake(SGArtworkSourceApple, @"Apple Music", @"The album's animated cover"),
    ];
}

SGModRow *SGArtworkSourcesRow(NSString *key, NSString *note) {
    SGModRow *row = SGPageRow(@"Sources", ^UIViewController *{
        return SGOrderPage(@"Artwork sources", sources(), ^NSArray<NSString *> *{ return SGArtworkOrderFor(key); },
                           ^(NSArray<NSString *> *keys) { SGArtworkSetOrderFor(key, keys); }, note);
    });
    row.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *source in SGArtworkOrderFor(key)) {
            for (SGOrderItem *item in sources()) {
                if ([item.key isEqualToString:source]) [names addObject:item.name];
            }
        }
        return names.count ? [names componentsJoinedByString:@", "] : @"None";
    };
    return row;
}
