// Artist redesign: the header the playlist and album pages have. The photo runs full bleed across the top
// of the page and dissolves into the page's colour; the name and the monthly listeners are centred on the
// bottom of that dissolve; and under them one row -- shuffle, a white Play capsule, and Follow.
//
// Tree (trees/clean/artist/01.txt:37-170). The header is TemplateKit's HeaderContainer, 568pt, the first view
// of the page's stack, holding an element view that holds the ImageHeaderView:
//
//     UIView 402x424 clips                    the photo (Components.Header.UI.ArtworkImage) and a gradient
//     UIView {16, 334}                        the name, Encore.AdaptiveTitle, 45pt
//     ImageHeaderView.VerifiedBadge           "Verified by Spotify"
//     Components.Header.UI.Metadata           "58,4M monthly listeners"
//     UIStackView {4, 456} 394x48             explore, Follow (Curation.FollowButtonElementKit.FollowButton,
//                                             a text button), more, Components.UI.ShuffleButton, and
//                                             header-play-button
//     UIStackView {0, 504} 402x64             Components.UI.ArtistHeadline, "Pre-save the upcoming album"
//     HeaderForegroundView                    the 100pt navigation bar with the name, shown collapsed
//
// Scrolled (02.txt:26-30), the container keeps its 568pt and scrolls away with the page, while the element
// view slides down inside it and the ImageHeaderView shrinks to the 100pt bar, pinned at the top of the
// screen. So the photo and the redesign's text are the container's, not the ImageHeaderView's: in the header
// view they would be pinned at the top with it. The bar stays Spotify's, drawing the name once the page is
// scrolled, with its gradient masked out as the album's is.
//
// Everything else of the ImageHeaderView is drawn by nothing (an empty mask) and takes no touches: the badge,
// Explore, and the headline go with it -- the headline's pre-save is also the list's own Release Countdown
// section. The Kit's SGRHeaderInfo reads the name and the listeners off Spotify's concealed labels and draws
// and fires Spotify's shuffle, play and Follow, Follow as a glyph from the collection (ArtistFollow.x). More stays in Spotify's row, where the row needs it (ArtistField.x), and the Kit's pinned ⋯
// (SGRPinnedMore) draws and fires it from the top trailing corner of the page, level with the back button.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGPageStyle.h"
#import "SGArtistLogo.h"
#import "Artist.h"
#import <AVFoundation/AVFoundation.h>

// How much of the photo's height the dissolve into the field covers, and the scrim over the top of it that
// keeps the status bar and the back button legible on a bright picture. The playlist's and the album's.
static const CGFloat kDissolve = 0.46, kTopScrim = 140, kTopScrimAlpha = 0.28;
// A photo view narrower than this is a placeholder glyph, and a picture shorter than this one mid load.
static const CGFloat kMinCover = 80, kMinHero = 120;
// The collapsed ImageHeaderView, Spotify's navigation bar; the text fades out over the last kFade before it.
static const CGFloat kBar = 100, kFade = 150;

static char kInfoKey, kHeroKey, kHeroHeightKey, kContainerHeightKey, kRowWatchedKey, kShuffleKey;
static char kTitleKey, kMetaKey, kPlayKey, kFollowKey, kArtworkKey, kBarKey, kMoreKey, kMoreButtonKey;
static char kLogoArtistKey, kArtistInfoButtonKey, kArtistInfoGlassKey;
static NSHashTable<UIView *> *sg_artistHeaders;
static NSMutableDictionary<NSString *, id> *sg_artistVideoCache;
static NSMutableSet<NSString *> *sg_artistVideoRequests;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_artistVideoWaiters;
static void applyHeader(UIView *header);

static NSString *artistSearchKey(NSString *name) {
    NSString *folded = [[name stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil]
                        lowercaseString];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
        if (word.length) [words addObject:word];
    }
    return [words componentsJoinedByString:@" "];
}

static void artistVideoGET(NSURL *url, void (^done)(NSDictionary *json, NSInteger status)) {
    if (!url) { done(nil, 0); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 18;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (error) SGLog(@"redesign artist: external video lookup failed: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{ done([json isKindOfClass:NSDictionary.class] ? json : nil, status); });
    }] resume];
}

static NSURL *artistVideoPreview(NSDictionary *result) {
    NSString *address = [result[@"previewUrl"] isKindOfClass:NSString.class] ? result[@"previewUrl"] : nil;
    NSURL *url = address ? [NSURL URLWithString:address] : nil;
    NSString *host = url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        !([host isEqualToString:@"itunes.apple.com"] || [host hasSuffix:@".itunes.apple.com"])) return nil;
    return url;
}

static void artistVideoFinish(NSString *key, NSURL *url) {
    if (!sg_artistVideoCache) sg_artistVideoCache = [NSMutableDictionary dictionary];
    if (url) sg_artistVideoCache[key] = url;
    else [sg_artistVideoCache removeObjectForKey:key];
    [sg_artistVideoRequests removeObject:key];
    NSArray *waiters = [sg_artistVideoWaiters[key] copy];
    [sg_artistVideoWaiters removeObjectForKey:key];
    SGLog(@"redesign artist: %@ external music-video preview for %@", url ? @"found" : @"no", key);
    for (void (^waiter)(NSURL *) in waiters) waiter(url);
}

static void searchArtistVideo(NSString *name, NSString *key, NSString *country, BOOL canFallback) {
    NSURLComponents *search = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    search.queryItems = @[[NSURLQueryItem queryItemWithName:@"term" value:name],
                          [NSURLQueryItem queryItemWithName:@"entity" value:@"musicVideo"],
                          [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
                          [NSURLQueryItem queryItemWithName:@"limit" value:@"50"],
                          [NSURLQueryItem queryItemWithName:@"country" value:country]];
    artistVideoGET(search.URL, ^(NSDictionary *json, NSInteger status) {
        NSArray *results = [json[@"results"] isKindOfClass:NSArray.class] ? json[@"results"] : nil;
        NSURL *preview = nil;
        // Search relevance can put a song or a different act named the same ahead of the artist.
        // Only accept a licensed music-video preview whose catalog artist matches the profile exactly.
        for (id item in results) {
            NSDictionary *result = [item isKindOfClass:NSDictionary.class] ? item : nil;
            if (![artistSearchKey(result[@"artistName"]) isEqualToString:key]) continue;
            preview = artistVideoPreview(result);
            if (preview) break;
        }
        if (status == 200 && preview) { artistVideoFinish(key, preview); return; }
        if (canFallback && ![country isEqualToString:@"us"]) {
            searchArtistVideo(name, key, @"us", NO);
            return;
        }
        artistVideoFinish(key, nil);
    });
}

static void findArtistVideo(NSString *name, void (^done)(NSURL *url)) {
    NSString *key = artistSearchKey(name);
    if (!key.length) { done(nil); return; }
    NSURL *cached = sg_artistVideoCache[key];
    if (cached) { done(cached); return; }
    if (!sg_artistVideoRequests) sg_artistVideoRequests = [NSMutableSet set];
    if (!sg_artistVideoWaiters) sg_artistVideoWaiters = [NSMutableDictionary dictionary];
    if ([sg_artistVideoRequests containsObject:key]) {
        [sg_artistVideoWaiters[key] addObject:[done copy]];
        return;
    }
    [sg_artistVideoRequests addObject:key];
    sg_artistVideoWaiters[key] = [NSMutableArray arrayWithObject:[done copy]];
    NSString *country = [[NSLocale.currentLocale objectForKey:NSLocaleCountryCode] lowercaseString];
    if (country.length != 2) country = @"us";
    searchArtistVideo(name, key, country, YES);
}

@interface SGRArtistInfoSheet : UIViewController
@property (nonatomic, copy) NSString *artistName;
@end

@interface SGRArtistInfoSheet ()
- (void)loadSummaryLanguage:(NSString *)language;
@end

@implementation SGRArtistInfoSheet {
    UIImageView *_hero;
    UILabel *_title, *_subtitle, *_facts, *_aboutTitle, *_about;
    UIStackView *_sources;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.035 blue:0.04 alpha:1];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    UIView *content = [UIView new]; content.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    _hero = [UIImageView new]; _hero.translatesAutoresizingMaskIntoConstraints = NO; _hero.contentMode = UIViewContentModeScaleAspectFill; _hero.clipsToBounds = YES;
    [content addSubview:_hero];
    _title = [UILabel new]; _title.translatesAutoresizingMaskIntoConstraints = NO; _title.text = self.artistName; _title.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold]; _title.textColor = UIColor.whiteColor; _title.numberOfLines = 0;
    [content addSubview:_title];
    _subtitle = [UILabel new]; _subtitle.translatesAutoresizingMaskIntoConstraints = NO; _subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; _subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.62]; _subtitle.numberOfLines = 0;
    [content addSubview:_subtitle];
    _facts = [UILabel new]; _facts.translatesAutoresizingMaskIntoConstraints = NO; _facts.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; _facts.textColor = [UIColor colorWithWhite:1 alpha:0.72]; _facts.numberOfLines = 0;
    [content addSubview:_facts];
    _aboutTitle = [UILabel new]; _aboutTitle.translatesAutoresizingMaskIntoConstraints = NO; _aboutTitle.text = @"Informazioni"; _aboutTitle.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold]; _aboutTitle.textColor = UIColor.whiteColor;
    [content addSubview:_aboutTitle];
    _about = [UILabel new]; _about.translatesAutoresizingMaskIntoConstraints = NO; _about.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _about.textColor = [UIColor colorWithWhite:1 alpha:0.78]; _about.numberOfLines = 0; _about.text = @"Caricamento delle informazioni…";
    [content addSubview:_about];
    _sources = [UIStackView new]; _sources.translatesAutoresizingMaskIntoConstraints = NO; _sources.axis = UILayoutConstraintAxisHorizontal; _sources.alignment = UIStackViewAlignmentCenter; _sources.distribution = UIStackViewDistributionFillEqually; _sources.spacing = 8;
    NSArray<NSString *> *sourceNames = @[@"Wikipedia", @"Wikidata", @"MusicBrainz", @"AllMusic", @"Discogs"];
    for (NSInteger index = 0; index < sourceNames.count; index++) {
        UIButton *source = [UIButton buttonWithType:UIButtonTypeSystem];
        [source setTitle:sourceNames[index] forState:UIControlStateNormal];
        source.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        source.accessibilityLabel = [NSString stringWithFormat:@"Apri la fonte %@", source.titleLabel.text];
        source.tag = index;
        [source addTarget:self action:@selector(openSource:) forControlEvents:UIControlEventTouchUpInside];
        [_sources addArrangedSubview:source];
    }
    [content addSubview:_sources];
    UILayoutGuide *g = content.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_hero.topAnchor constraintEqualToAnchor:g.topAnchor], [_hero.leadingAnchor constraintEqualToAnchor:content.leadingAnchor], [_hero.trailingAnchor constraintEqualToAnchor:content.trailingAnchor], [_hero.heightAnchor constraintEqualToConstant:230],
        [_title.topAnchor constraintEqualToAnchor:_hero.bottomAnchor constant:18], [_title.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:22], [_title.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-22],
        [_subtitle.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:6], [_subtitle.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor], [_subtitle.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
        [_facts.topAnchor constraintEqualToAnchor:_subtitle.bottomAnchor constant:20], [_facts.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor], [_facts.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
        [_aboutTitle.topAnchor constraintEqualToAnchor:_facts.bottomAnchor constant:24], [_aboutTitle.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
        [_about.topAnchor constraintEqualToAnchor:_aboutTitle.bottomAnchor constant:10], [_about.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor], [_about.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
        [_sources.topAnchor constraintEqualToAnchor:_about.bottomAnchor constant:18], [_sources.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor], [_sources.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor], [_sources.heightAnchor constraintEqualToConstant:44], [_sources.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-20]
    ]];
    [self loadSummary];
}
- (void)openSource:(UIButton *)sender {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+#"];
    NSString *query = [self.artistName stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSArray<NSString *> *sources = @[
        [NSString stringWithFormat:@"https://it.wikipedia.org/w/index.php?search=%@", query ?: @""],
        [NSString stringWithFormat:@"https://www.wikidata.org/w/index.php?search=%@", query ?: @""],
        [NSString stringWithFormat:@"https://musicbrainz.org/search?query=%@&type=artist&method=advanced", query ?: @""],
        [NSString stringWithFormat:@"https://www.allmusic.com/search/artists/%@", query ?: @""],
        [NSString stringWithFormat:@"https://www.discogs.com/search/?type=artist&q=%@", query ?: @""]
    ];
    NSString *urlString = sender.tag >= 0 && sender.tag < (NSInteger)sources.count ? sources[(NSUInteger)sender.tag] : nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
- (void)loadSummary {
    [self loadSummaryLanguage:@"it"];
}
- (void)loadSummaryLanguage:(NSString *)language {
    NSString *slug = [self.artistName stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"/?#"];
    NSString *escaped = [slug stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *url = escaped.length ? [NSURL URLWithString:[NSString stringWithFormat:@"https://%@.wikipedia.org/api/rest_v1/page/summary/%@", language, escaped]] : nil;
    if (!url) { _about.text = @"Le informazioni non sono disponibili."; return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"spoti.pw/1.0 (artist information)" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *extract = [json[@"extract"] isKindOfClass:NSString.class] ? json[@"extract"] : nil;
        NSString *description = [json[@"description"] isKindOfClass:NSString.class] ? json[@"description"] : nil;
        NSString *wikidata = [json[@"wikibase_item"] isKindOfClass:NSString.class] ? json[@"wikibase_item"] : nil;
        NSString *imageURL = [json[@"originalimage"] isKindOfClass:NSDictionary.class] ? json[@"originalimage"][@"source"] : nil;
        if (!extract.length && [language isEqualToString:@"it"]) {
            [self loadSummaryLanguage:@"en"];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.isViewLoaded || !self.view.window) return;
            if (extract.length) self->_about.text = extract;
            else self->_about.text = error ? @"Connessione non disponibile." : @"Non sono state trovate informazioni per questo artista.";
            self->_subtitle.text = description;
            if (wikidata.length) [self loadFacts:wikidata];
            if (imageURL.length) {
                NSURL *image = [NSURL URLWithString:imageURL];
                if (image) [[NSURLSession.sharedSession dataTaskWithURL:image completionHandler:^(NSData *imageData, NSURLResponse *r, NSError *e) {
                    (void)r; (void)e; UIImage *picture = imageData ? [UIImage imageWithData:imageData] : nil;
                    if (picture) dispatch_async(dispatch_get_main_queue(), ^{ if (self.isViewLoaded) self->_hero.image = picture; });
                }] resume];
            }
        });
    }] resume];
}
- (void)loadFacts:(NSString *)identifier {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.wikidata.org/wiki/Special:EntityData/%@.json", identifier]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"spoti.pw/1.0 (artist information)" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response; (void)error;
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *entity = root[@"entities"][identifier];
        NSDictionary *claims = entity[@"claims"];
        NSArray<NSString *> *properties = @[@"P19", @"P740", @"P27", @"P136", @"P106", @"P1303", @"P166", @"P800", @"P527"];
        NSArray<NSString *> *titles = @[@"Luogo di nascita", @"Formati a", @"Paese", @"Generi", @"Professione", @"Strumenti", @"Riconoscimenti", @"Opere note", @"Membri"];
        NSMutableDictionary<NSString *, NSArray<NSString *> *> *idsByProperty = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSString *property in properties) {
            NSArray *propertyClaims = [claims[property] isKindOfClass:NSArray.class] ? claims[property] : nil;
            NSMutableArray<NSString *> *propertyIDs = [NSMutableArray array];
            for (NSDictionary *claim in propertyClaims) {
                NSDictionary *value = claim[@"mainsnak"][@"datavalue"][@"value"];
                NSString *itemID = [value[@"id"] isKindOfClass:NSString.class] ? value[@"id"] : nil;
                if (itemID.length && ![propertyIDs containsObject:itemID]) {
                    [propertyIDs addObject:itemID];
                    if (![ids containsObject:itemID]) [ids addObject:itemID];
                }
                if (propertyIDs.count == 2) break;
            }
            if (propertyIDs.count) idsByProperty[property] = propertyIDs;
        }
        NSString *(^dateFor)(NSString *) = ^NSString *(NSString *property) {
            NSArray *dateClaims = [claims[property] isKindOfClass:NSArray.class] ? claims[property] : nil;
            NSDictionary *claim = dateClaims.firstObject;
            NSString *time = claim[@"mainsnak"][@"datavalue"][@"value"][@"time"];
            return time.length >= 11 ? [time substringWithRange:NSMakeRange(1, 10)] : nil;
        };
        NSString *birthDate = dateFor(@"P569"), *deathDate = dateFor(@"P570"), *foundedDate = dateFor(@"P571");
        if (!ids.count) {
            NSMutableArray<NSString *> *dateParts = [NSMutableArray array];
            if (birthDate.length) [dateParts addObject:[NSString stringWithFormat:@"Nascita  %@", birthDate]];
            if (deathDate.length) [dateParts addObject:[NSString stringWithFormat:@"Morte  %@", deathDate]];
            if (foundedDate.length) [dateParts addObject:[NSString stringWithFormat:@"Fondazione  %@", foundedDate]];
            NSString *dateFacts = [dateParts componentsJoinedByString:@"\n"];
            dispatch_async(dispatch_get_main_queue(), ^{ if (self.isViewLoaded && dateFacts.length) self->_facts.text = dateFacts; });
            return;
        }
        NSString *idList = [ids componentsJoinedByString:@"|"];
        NSString *encodedIDs = [idList stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        NSURL *labelsURL = encodedIDs ? [NSURL URLWithString:[NSString stringWithFormat:@"https://www.wikidata.org/w/api.php?action=wbgetentities&ids=%@&props=labels&languages=it%%7Cen&format=json", encodedIDs]] : nil;
        if (!labelsURL) return;
        NSMutableURLRequest *labelsRequest = [NSMutableURLRequest requestWithURL:labelsURL];
        [labelsRequest setValue:@"spoti.pw/1.0 (artist information)" forHTTPHeaderField:@"User-Agent"];
        [[NSURLSession.sharedSession dataTaskWithRequest:labelsRequest completionHandler:^(NSData *labelsData, NSURLResponse *labelsResponse, NSError *labelsError) {
            (void)labelsResponse; (void)labelsError;
            NSDictionary *labelsRoot = labelsData ? [NSJSONSerialization JSONObjectWithData:labelsData options:0 error:nil] : nil;
            NSDictionary *entities = labelsRoot[@"entities"];
            NSString *(^readLabel)(NSString *) = ^NSString *(NSString *itemID) {
                NSDictionary *entityLabels = entities[itemID][@"labels"];
                NSDictionary *entry = entityLabels[@"it"] ?: entityLabels[@"en"];
                return [entry[@"value"] isKindOfClass:NSString.class] ? entry[@"value"] : nil;
            };
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            if (birthDate.length) [parts addObject:[NSString stringWithFormat:@"Nascita  %@", birthDate]];
            if (deathDate.length) [parts addObject:[NSString stringWithFormat:@"Morte  %@", deathDate]];
            if (foundedDate.length) [parts addObject:[NSString stringWithFormat:@"Fondazione  %@", foundedDate]];
            [properties enumerateObjectsUsingBlock:^(NSString *property, NSUInteger index, BOOL *stop) {
                (void)stop;
                NSMutableArray<NSString *> *values = [NSMutableArray array];
                for (NSString *itemID in idsByProperty[property]) {
                    NSString *label = readLabel(itemID);
                    if (label.length) [values addObject:label];
                }
                if (values.count) [parts addObject:[NSString stringWithFormat:@"%@  %@", titles[index], [values componentsJoinedByString:@", "]]];
            }];
            NSString *facts = [parts componentsJoinedByString:@"\n"];
            dispatch_async(dispatch_get_main_queue(), ^{ if (self.isViewLoaded && facts.length) self->_facts.text = facts; });
        }] resume];
    }] resume];
}
@end

static void showArtistInfo(NSString *name) {
    if (!name.length) return;
    UIViewController *presenter = SGTopController();
    if (!presenter || presenter.presentedViewController) return;
    SGRArtistInfoSheet *sheet = [SGRArtistInfoSheet new];
    sheet.artistName = name;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        sheet.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.sheetPresentationController.prefersGrabberVisible = YES;
        sheet.sheetPresentationController.preferredCornerRadius = 28;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Spotify's views

// Drawn by nothing and out of the way of touches, whatever Spotify does to it: an empty mask. Not hidden --
// the header's OverflowStackView traps when a view in it hides, and a hidden view is one the redesign still
// has to read and fire.
static void blank(UIView *view) {
    if (!view) return;
    if (!view.layer.mask) view.layer.mask = [CALayer layer];
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static void setFrame(UIView *view, CGRect frame) {
    if (view && !CGRectIsEmpty(frame) && !CGRectEqualToRect(view.frame, frame)) view.frame = frame;
}

static CGFloat topOverscrollFor(UIView *view) {
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if (![ancestor isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)ancestor;
        return MAX(0, -(scroll.contentOffset.y + scroll.adjustedContentInset.top));
    }
    return 0;
}

static NSString *trimmed(NSString *text) {
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length ? clean : nil;
}

static NSString *firstText(UIView *root) {
    __block NSString *found = nil;
    SGForEachView(root, ^(UIView *v) {
        if (found || ![v isKindOfClass:UILabel.class]) return;
        found = trimmed(((UILabel *)v).text);
    });
    return found;
}

// The TemplateKit container the header sits in, which scrolls with the page.
static UIView *containerOf(UIView *header) {
    for (UIView *v = header.superview; v; v = v.superview) {
        if ([NSStringFromClass(v.class) containsString:@"HeaderContainer"]) return v;
    }
    return nil;
}

#pragma mark - the photo, full bleed

// The picture across the top of the page with the field showing through the bottom of it: a scrim over the
// top for the status bar, and under it a fade to the very colour the page's field is drawing.
@interface SGRArtistHero : UIView
@property (nonatomic, readonly) UIImageView *picture;
@property (nonatomic, copy) UIColor *fieldColor;
- (void)followArtistVideo:(NSString *)artist;
// The photo in Spotify's artwork view, and every photo it puts there afterwards: the hero keeps itself
// right, rather than being handed a picture on each of the header's passes and staying empty between them.
// The same view again only re-reads it.
- (void)followArtwork:(UIImageView *)source;
@end

@implementation SGRArtistHero {
    CAGradientLayer *_scrim, *_dissolve;
    __weak UIImageView *_artwork;
    AVPlayerLayer *_videoLayer;
    AVPlayer *_videoPlayer;
    NSString *_videoArtist;
    id _videoEndObserver;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;

    _videoLayer = [AVPlayerLayer playerLayerWithPlayer:nil];
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _videoLayer.opacity = 0;
    [self.layer insertSublayer:_videoLayer atIndex:0];
    [_videoLayer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionNew context:NULL];

    _picture = [[UIImageView alloc] initWithFrame:self.bounds];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    _picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_picture];

    _scrim = [CAGradientLayer layer];
    _scrim.zPosition = 1;
    _scrim.colors = @[(id)[UIColor colorWithWhite:0 alpha:kTopScrimAlpha].CGColor, (id)UIColor.clearColor.CGColor];
    [self.layer addSublayer:_scrim];

    _dissolve = [CAGradientLayer layer];
    _dissolve.zPosition = 2;
    [self.layer addSublayer:_dissolve];
    self.fieldColor = SGRNeutralField();
    // The colour is read off the main thread, so it can land after the last layout pass of the page.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_fieldColorDidChange)
                                               name:SGRFieldColorDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_pauseVideo)
                                               name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_resumeVideo)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_videoLayer removeObserver:self forKeyPath:@"readyForDisplay"];
    if (_videoEndObserver) [NSNotificationCenter.defaultCenter removeObserver:_videoEndObserver];
    [_videoPlayer pause];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == _videoLayer && [keyPath isEqualToString:@"readyForDisplay"]) {
        if (!_videoLayer.readyForDisplay || !self.window) return;
        SGRArtistHero *hero = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hero.window && hero->_videoLayer.readyForDisplay) {
                [UIView animateWithDuration:0.45 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
                    hero->_picture.alpha = 0;
                    hero->_videoLayer.opacity = 1;
                } completion:nil];
            }
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self sgr_resumeVideo];
    else [self sgr_pauseVideo];
}

- (void)sgr_pauseVideo { [_videoPlayer pause]; }
- (void)sgr_resumeVideo {
    if (self.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [_videoPlayer play];
}

- (void)followArtistVideo:(NSString *)artist {
    if (!artist.length || [artistSearchKey(artist) isEqualToString:artistSearchKey(_videoArtist)]) return;
    _videoArtist = [artist copy];
    _picture.alpha = 1;
    _videoLayer.opacity = 0;
    [_videoPlayer pause];
    _videoPlayer = nil;
    _videoLayer.player = nil;
    if (_videoEndObserver) [NSNotificationCenter.defaultCenter removeObserver:_videoEndObserver];
    _videoEndObserver = nil;
    NSString *artistKey = artistSearchKey(artist);
    __weak SGRArtistHero *weakSelf = self;
    findArtistVideo(artist, ^(NSURL *url) {
        SGRArtistHero *hero = weakSelf;
        if (!hero || !url || ![artistSearchKey(hero->_videoArtist) isEqualToString:artistKey]) return;
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
        player.muted = YES;
        player.volume = 0;
        player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        hero->_videoPlayer = player;
        hero->_videoLayer.player = player;
        __weak SGRArtistHero *weakHero = hero;
        hero->_videoEndObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            SGRArtistHero *liveHero = weakHero;
            if (!liveHero || liveHero->_videoPlayer.currentItem != item) return;
            __weak AVPlayer *weakPlayer = liveHero->_videoPlayer;
            [weakPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) { if (finished) [weakPlayer play]; }];
        }];
        [hero sgr_resumeVideo];
    });
}

- (void)sgr_fieldColorDidChange {
    if (self.superview) self.fieldColor = SGRArtistFieldColor(self);
}

- (void)setFieldColor:(UIColor *)color {
    if (!color || [_fieldColor isEqual:color]) return;
    _fieldColor = [color copy];
    // The clear end is the same colour with no alpha, so the fade keeps its hue instead of going through grey.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dissolve.colors = @[(id)[color colorWithAlphaComponent:0].CGColor,
                         (id)[color colorWithAlphaComponent:0.72].CGColor,
                         (id)color.CGColor];
    _dissolve.locations = @[@0, @0.62, @1];
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _videoLayer.frame = bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scrim.frame = CGRectMake(0, 0, bounds.size.width, MIN(kTopScrim, bounds.size.height));
    CGFloat fade = round(bounds.size.height * kDissolve);
    _dissolve.frame = CGRectMake(0, bounds.size.height - fade, bounds.size.width, fade);
    [CATransaction commit];
}

- (void)followArtwork:(UIImageView *)source {
    if (!source) return;
    [self takeArtwork:source late:NO];
    if (_artwork == source) return;
    _artwork = source;
    __weak SGRArtistHero *weakSelf = self;
    SGRObserveImage(source, ^(UIImageView *view) { [weakSelf takeArtwork:view late:YES]; });
}

// `late` is a photo that arrived after the header had laid out -- the artist opened for the first time,
// whose picture is still being fetched while the page is already on screen (issue #52). The log line says
// once that the watch, and not one of the header's passes, is what filled the hero.
- (void)takeArtwork:(UIImageView *)source late:(BOOL)late {
    UIImage *image = source.image;
    if (!image || _picture.image == image) return;
    _picture.image = image;
    // The page's field takes its colour from the same picture.
    SGRArtistSetArtwork(self, image);
    SGRRevealMark(SGRArtistPageOf(self), SGRRevealPicture);
    static BOOL logged;
    if (late && !logged) {
        logged = YES;
        SGLog(@"redesign artist: the photo landed after the header had laid out; the hero took it");
    }
}

@end

// The image view of Spotify's artwork: the one with the photo in it, or, before the photo has been fetched,
// the empty one it will land in, so it can be watched from the first pass. Either way one the size of the
// picture, never a small placeholder glyph beside it.
static UIImageView *photoIn(UIView *artwork) {
    __block UIImageView *found = nil, *empty = nil;
    SGForEachView(artwork, ^(UIView *v) {
        if (found || ![v isKindOfClass:UIImageView.class]) return;
        UIImageView *image = (UIImageView *)v;
        if (image.bounds.size.width < kMinCover) return;
        if (image.image) found = image;
        else if (!empty) empty = image;
    });
    return found ?: empty;
}

// The picture from the top of the container down to `bottom`, which comes from the container at rest and only
// ever grows, so it does not change size while the page loads or scrolls.
static void applyHero(UIView *container, UIView *artwork, CGFloat bottom, NSString *artist) {
    SGRArtistHero *hero = objc_getAssociatedObject(container, &kHeroKey);
    if (!hero) {
        hero = [[SGRArtistHero alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(container, &kHeroKey, hero, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hero.superview != container) [container insertSubview:hero atIndex:0];
    else if (container.subviews.firstObject != hero) [container sendSubviewToBack:hero];

    CGFloat height = [objc_getAssociatedObject(hero, &kHeroHeightKey) doubleValue];
    if (bottom > height + 0.5) {
        height = round(bottom);
        objc_setAssociatedObject(hero, &kHeroHeightKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign artist: hero %.0fpt across the top of the page", height);
    }
    if (height < kMinHero) return;
    CGFloat overscroll = topOverscrollFor(container);
    setFrame(hero, CGRectMake(0, -overscroll, container.bounds.size.width, height + overscroll));
    hero.fieldColor = SGRArtistFieldColor(container);
    [hero followArtwork:photoIn(artwork)];
    [hero followArtistVideo:artist];
}

#pragma mark - the header's pass

static void applyHeader(UIView *header);

// Spotify's navigation bar, the one part of the header kept: collapsed, it is where the name is. Its gradient
// is a flat dark band over the field, as the album's was (Album/AlbumHeader.x); the soft top edge every
// redesigned page has keeps the name legible instead.
static UIView *keepBar(UIView *header) {
    UIView *foreground = nil;
    for (UIView *sub in header.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"HeaderForegroundView"]) foreground = sub;
    }
    if (foreground && !objc_getAssociatedObject(header, &kBarKey)) {
        SGForEachView(foreground, ^(UIView *v) {
            if ([NSStringFromClass(v.class) containsString:@"GradientView"] && !v.layer.mask) v.layer.mask = [CALayer layer];
        });
        objc_setAssociatedObject(header, &kBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return foreground;
}

static void applyHeader(UIView *header) {
    UIView *container = containerOf(header);
    UIView *artwork = SGRFindByIdentifier(header, @"Components.Header.UI.ArtworkImage", &kArtworkKey);
    UIView *page = SGRArtistPageOf(container);
    if (!container || !artwork || !page) return;
    if (!sg_artistHeaders) sg_artistHeaders = [NSHashTable weakObjectsHashTable];
    [sg_artistHeaders addObject:header];
    static dispatch_once_t logoObserver;
    dispatch_once(&logoObserver, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:SGRArtistLogoKeyDidChangeNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            for (UIView *active in sg_artistHeaders.allObjects) {
                if (!active.window) continue;
                objc_setAssociatedObject(active, &kLogoArtistKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                applyHeader(active);
            }
        }];
    });
    // The photo header the redesign lays out: the page's curtain waits for all of it (ArtistField.x put it up).
    SGRRevealHold(page, SGRRevealPage);

    UIView *bar = keepBar(header);
    for (UIView *sub in header.subviews) {
        if (sub != bar) blank(sub);
    }

    SGRHeaderInfo *info = objc_getAssociatedObject(container, &kInfoKey);
    if (!info) {
        info = [[SGRHeaderInfo alloc] initWithFrame:CGRectZero];
        // Follow's only state is its title in the app's language, so the glyph takes it from the collection.
        __weak UIView *weakPage = page;
        __weak SGRHeaderInfo *weakInfo = info;
        __weak UIView *weakHeader = header;
        info.trailingState = ^BOOL(BOOL *on) {
            UIView *more = SGRFindByIdentifier(weakHeader, @"Components.UI.ContextMenuButton*", &kMoreKey);
            return SGRArtistFollowing(weakPage, more.accessibilityIdentifier, on, ^{ [weakInfo trailingStateChanged]; });
        };
        info.trailingOffSymbol = @"person.badge.plus";
        info.trailingOnSymbol = @"person.fill.checkmark";
        objc_setAssociatedObject(container, &kInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (info.superview != container) [container addSubview:info];
    setFrame(info, container.bounds);

    UIView *title = SGRFindByIdentifier(header, @"Encore.AdaptiveTitle", &kTitleKey);
    UIView *listeners = SGRFindByIdentifier(header, @"Components.Header.UI.Metadata", &kMetaKey);
    NSString *name = firstText(title) ?: firstText(bar), *listening = firstText(listeners);
    [info showTitle:name creator:nil length:listening about:nil];
    SGRGlyphButton *artistInfo = objc_getAssociatedObject(container, &kArtistInfoButtonKey);
    if (!artistInfo) {
        artistInfo = [SGRGlyphButton buttonWithSymbol:@"info" pointSize:22 title:@"Informazioni artista"];
        objc_setAssociatedObject(container, &kArtistInfoButtonKey, artistInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:artistInfo];
    }
    SGRGlassInside(artistInfo, &kArtistInfoGlassKey, 48);
    __weak UIView *weakHeader = header;
    artistInfo.onTap = ^{
        UIView *activeTitle = SGRFindByIdentifier(weakHeader, @"Encore.AdaptiveTitle", &kTitleKey);
        showArtistInfo(firstText(activeTitle) ?: firstText(keepBar(weakHeader)) ?: @"");
    };
    artistInfo.frame = CGRectMake(round((container.bounds.size.width - 148) / 2 - 62),
                                  container.bounds.size.height - SGRHeaderInfoBottom - SGRActionHeight, 48, 48);
    NSString *logoArtist = objc_getAssociatedObject(header, &kLogoArtistKey);
    if (name.length && ![logoArtist isEqualToString:name]) {
        objc_setAssociatedObject(header, &kLogoArtistKey, [name copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [info showLogo:nil forTitle:name];
        __weak SGRHeaderInfo *weakInfo = info;
        __weak UIView *weakLogoHeader = header;
        SGRArtistLogoForArtist(name, ^(UIImage *logo) {
            [weakInfo showLogo:logo forTitle:name];
            if (logo) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * 60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView *active = weakLogoHeader;
                if (!active || ![objc_getAssociatedObject(active, &kLogoArtistKey) isEqualToString:name]) return;
                objc_setAssociatedObject(active, &kLogoArtistKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (active.window) [active setNeedsLayout];
            });
        });
    }

    UIView *shuffle = SGRFindByIdentifier(header, @"Components.UI.ShuffleButton", &kShuffleKey);
    UIView *play = SGRFindByIdentifier(header, @"header-play-button", &kPlayKey);
    UIView *follow = SGRFindByIdentifier(header, @"Curation.FollowButtonElementKit.FollowButton", &kFollowKey);
    // The reference layout puts Artist info immediately left of Play; its own button occupies that slot.
    [info showShuffle:nil play:play trailing:follow trailingFallback:nil playColor:SGRArtistFieldColor(container)];
    // The listeners are waited for with the name and Play: arriving late they pushed the name up by a line.
    if (name && play && listening) SGRRevealMark(page, SGRRevealHeader);

    // More, in the top trailing corner of the page itself rather than of the container, which scrolls away
    // with the photo: pinned there it is the same button in the same place on the album and the playlist,
    // and the page keeps it however far down the list one is (issue #57).
    UIView *more = SGRFindByIdentifier(header, @"Components.UI.ContextMenuButton*", &kMoreKey);
    SGRPinnedMore(page, &kMoreButtonKey, more);

    // Collapsing, the text would pass over Spotify's bar with the name in it: it goes over the last kFade of
    // the collapse, from the header's own height, which this pass runs on every step of. More stays: it is
    // outside the header and has nothing to pass over.
    CGFloat alpha = MAX(0, MIN(1, (header.bounds.size.height - kBar) / kFade));
    if (fabs(info.alpha - alpha) > 0.01) info.alpha = alpha;
    if (fabs(artistInfo.alpha - alpha) > 0.01) artistInfo.alpha = alpha;
    artistInfo.userInteractionEnabled = alpha > 0.02;
    artistInfo.accessibilityElementsHidden = alpha <= 0.02;

    // The picture reaches to where the content's top is at rest, plus the name. The container keeps its
    // height as the header collapses, and only ever grows as the page loads.
    CGFloat rest = MAX([objc_getAssociatedObject(container, &kContainerHeightKey) doubleValue], container.bounds.size.height);
    objc_setAssociatedObject(container, &kContainerHeightKey, @(rest), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat bottom = rest - SGRHeaderInfoBottom - [info contentHeightForWidth:container.bounds.size.width] + SGRHeaderInfoTitleRise;
    applyHero(container, artwork, bottom, name);

    // The buttons arrive after the header has laid out, in a row that keeps its size and so lays nothing out
    // again (Native/Artist/Artist.x): the row's own pass is watched, a plain UIStackView.
    UIView *row = shuffle ?: play ?: follow;
    while (row && row.superview != header) row = row.superview;
    if (row && [row class] == UIStackView.class && !objc_getAssociatedObject(row, &kRowWatchedKey)) {
        objc_setAssociatedObject(row, &kRowWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakHeader = header;
        SGRObserveLayout(row, ^(UIView *view) {
            if (weakHeader) applyHeader(weakHeader);
        });
    }

    static BOOL logged;
    if (!logged && header.window && name) {
        logged = YES;
        SGLog(@"redesign artist: own block \"%@\", \"%@\"; shuffle %@, play %@, follow %@, more %@", name,
              firstText(listeners) ?: @"no listeners", shuffle ? @"found" : @"missing", play ? @"found" : @"missing",
              follow ? @"found" : @"missing", more ? @"found" : @"missing");
    }
}

%hook _TtC35CreativeWorkPlatform_ImageHeaderKit15ImageHeaderView
- (void)layoutSubviews {
    %orig;
    applyHeader((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC35CreativeWorkPlatform_ImageHeaderKit15ImageHeaderView"]);
}
