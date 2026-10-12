// Separate from the system Canvas option: this page controls only the optional card in redesigned Home.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Home.h"

#define SGRKeyHomeLyrics @"spotifyglass.redesign.homeLyrics"

static SGModRow *filterRow(NSString *title, NSArray<NSString *> *choices,
                           NSString *(^current)(void), void (^set)(NSString *)) {
    NSArray<NSString *> *options = [@[@"Tutti"] arrayByAddingObjectsFromArray:choices];
    SGModRow *row = SGDropdownRow(title, options, ^NSInteger{
        NSUInteger index = [options indexOfObject:current()];
        return index == NSNotFound ? 0 : (NSInteger)index;
    }, ^(NSInteger index) {
        if (index >= 0 && (NSUInteger)index < options.count) set(options[index]);
    });
    row.subtitle = choices.count ? @"Mostra solo tag che Spotify fornisce ai brani" :
                                    @"Spotify non ha ancora fornito tag per i brani disponibili";
    return row;
}

UIViewController *SGRHomeLyricsSettingsPage(void) {
    SGModRow *enabled = SGOptionRow(@"Riquadro lyrics casuali",
        @"Mostra nella Home un verso sincronizzato e il comando per ascoltarne il frammento",
        SGRKeyHomeLyrics);
    SGModRow *mood = filterRow(@"Mood", SGRHomeLyricsMoodChoices(), ^NSString *{
        return SGRHomeLyricsMoodFilter();
    }, ^(NSString *value) {
        SGRHomeLyricsSetMoodFilter(value);
    });
    SGModRow *genre = filterRow(@"Genere", SGRHomeLyricsGenreChoices(), ^NSString *{
        return SGRHomeLyricsGenreFilter();
    }, ^(NSString *value) {
        SGRHomeLyricsSetGenreFilter(value);
    });
    mood.visible = ^BOOL { return SGFlag(SGRKeyHomeLyrics, NO); };
    genre.visible = mood.visible;
    return [[SGModPage alloc] initWithTitle:@"Lyrics nella Home" intro:nil sections:@[
        SGSection(nil, @[enabled]),
        SGNotedSection(@"Filtri", @[mood, genre],
            @"I filtri usano solo mood e generi presenti nei metadati Spotify; non vengono stimati dal testo."),
    ] footer:nil];
}
