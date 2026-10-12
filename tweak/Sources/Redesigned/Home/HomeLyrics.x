// A compact, optional Home card built from Spotify tracks seen in playlist rows and local listening
// history. Only Spotify-provided genre/mood tags are filterable; no classification is guessed.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Library/MusicUniverse.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import "Home.h"
#import <stdlib.h>

static NSString *const kLyricsEnabled = @"spotifyglass.redesign.homeLyrics";
static NSString *const kHomeLyricsSafetyResetKey = @"spotifyglass.redesign.homeLyrics.safetyReset";
static NSString *const kMoodKey = @"spotifyglass.redesign.homeLyricsMood";
static NSString *const kGenreKey = @"spotifyglass.redesign.homeLyricsGenre";
static NSNotificationName const kTracksChanged = @"spotifyglass.redesign.homeLyrics.tracksChanged";
static char kRootHomeListKey, kListStateKey;
static const CGFloat kCardHeight = 148;
static const NSUInteger kTrackLimit = 160, kTryLimit = 5;

static NSMutableDictionary<NSString *, NSDictionary *> *sg_tracks;
static BOOL sg_historyLoaded;

static NSMutableArray<NSString *> *tagsFromValue(id value) {
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    NSArray *values = [value isKindOfClass:NSArray.class] ? value : @[value ?: NSNull.null];
    for (id item in values) {
        NSString *tag = [item isKindOfClass:NSString.class] ? item :
            ([item isKindOfClass:NSDictionary.class] ? (item[@"name"] ?: item[@"title"]) : nil);
        tag = [tag isKindOfClass:NSString.class] ? [tag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
        if (tag.length && ![tags containsObject:tag]) [tags addObject:tag];
    }
    return tags;
}

static NSArray<NSString *> *tagsForMetadata(NSDictionary *metadata, NSString *needle) {
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    for (id key in metadata) {
        if (![key isKindOfClass:NSString.class] || ![[key lowercaseString] containsString:needle]) continue;
        for (NSString *tag in tagsFromValue(metadata[key])) {
            if (![tags containsObject:tag]) [tags addObject:tag];
        }
    }
    return tags;
}

static NSString *trackIDForURI(NSString *uri) {
    NSString *prefix = @"spotify:track:";
    return [uri hasPrefix:prefix] ? [uri substringFromIndex:prefix.length] : nil;
}

void SGRHomeLyricsObserveTrack(id value, NSDictionary *metadata) {
    if (!SGFlag(kLyricsEnabled, NO) || ![metadata isKindOfClass:NSDictionary.class]) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGRHomeLyricsObserveTrack(value, metadata); });
        return;
    }
    Class trackClass = NSClassFromString(@"SPTPlayerTrack");
    if (!trackClass || ![value isKindOfClass:trackClass]) return;
    SPTPlayerTrack *track = value;
    NSString *trackID = trackIDForURI(SGURIString(track.URI));
    NSString *title = [track.trackTitle isKindOfClass:NSString.class] ? track.trackTitle : nil;
    NSString *artist = [track.artistName isKindOfClass:NSString.class] ? track.artistName : nil;
    if (!trackID.length || !title.length || !artist.length) return;
    if (!sg_tracks) sg_tracks = [NSMutableDictionary dictionary];

    NSDictionary *entry = @{
        @"id": trackID,
        @"uri": SGURIString(track.URI),
        @"title": title,
        @"artist": artist,
        @"album": [metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : @"",
        @"seconds": @([metadata[@"duration"] respondsToSelector:@selector(integerValue)] ? [metadata[@"duration"] integerValue] / 1000 : 0),
        @"genres": tagsForMetadata(metadata, @"genre"),
        @"moods": tagsForMetadata(metadata, @"mood"),
    };
    if ([sg_tracks[trackID] isEqual:entry]) return;
    if (sg_tracks.count >= kTrackLimit && !sg_tracks[trackID]) [sg_tracks removeObjectForKey:sg_tracks.allKeys.firstObject];
    sg_tracks[trackID] = entry;
    [NSNotificationCenter.defaultCenter postNotificationName:kTracksChanged object:nil];
}

static BOOL addHistoryTracks(void) {
    if (!sg_tracks) sg_tracks = [NSMutableDictionary dictionary];
    if (sg_historyLoaded) return NO;
    NSArray<NSDictionary *> *events = SGRMusicUniverseHistoryEvents();
    if (!events.count) return NO;
    sg_historyLoaded = YES;
    BOOL added = NO;
    for (NSDictionary *event in events) {
        NSString *uri = [event[@"trackURI"] isKindOfClass:NSString.class] ? event[@"trackURI"] : nil;
        NSString *trackID = trackIDForURI(uri);
        NSString *title = [event[@"track"] isKindOfClass:NSString.class] ? event[@"track"] : nil;
        NSString *artist = [event[@"artist"] isKindOfClass:NSString.class] ? event[@"artist"] : nil;
        if (!trackID.length || !title.length || !artist.length || sg_tracks[trackID]) continue;
        if (sg_tracks.count >= kTrackLimit) break;
        sg_tracks[trackID] = @{
            @"id": trackID, @"uri": uri, @"title": title, @"artist": artist,
            @"album": [event[@"album"] isKindOfClass:NSString.class] ? event[@"album"] : @"",
            @"seconds": @0, @"genres": @[], @"moods": @[],
        };
        added = YES;
    }
    return added;
}

static NSArray<NSString *> *choicesForTag(NSString *key) {
    NSMutableSet<NSString *> *all = [NSMutableSet set];
    for (NSDictionary *track in sg_tracks.allValues) [all addObjectsFromArray:track[key] ?: @[]];
    return [[all allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

NSArray<NSString *> *SGRHomeLyricsMoodChoices(void) { return choicesForTag(@"moods"); }
NSArray<NSString *> *SGRHomeLyricsGenreChoices(void) { return choicesForTag(@"genres"); }
NSString *SGRHomeLyricsMoodFilter(void) {
    NSString *mood = [NSUserDefaults.standardUserDefaults stringForKey:kMoodKey];
    return mood.length && [SGRHomeLyricsMoodChoices() containsObject:mood] ? mood : @"Tutti";
}
NSString *SGRHomeLyricsGenreFilter(void) {
    NSString *genre = [NSUserDefaults.standardUserDefaults stringForKey:kGenreKey];
    return genre.length && [SGRHomeLyricsGenreChoices() containsObject:genre] ? genre : @"Tutti";
}
void SGRHomeLyricsSetMoodFilter(NSString *mood) {
    [NSUserDefaults.standardUserDefaults setObject:mood ?: @"Tutti" forKey:kMoodKey];
    [NSNotificationCenter.defaultCenter postNotificationName:kTracksChanged object:nil];
}
void SGRHomeLyricsSetGenreFilter(NSString *genre) {
    [NSUserDefaults.standardUserDefaults setObject:genre ?: @"Tutti" forKey:kGenreKey];
    [NSNotificationCenter.defaultCenter postNotificationName:kTracksChanged object:nil];
}

static NSArray<NSDictionary *> *filteredTracks(void) {
    addHistoryTracks();
    NSString *mood = SGRHomeLyricsMoodFilter(), *genre = SGRHomeLyricsGenreFilter();
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *track in sg_tracks.allValues) {
        if (![mood isEqualToString:@"Tutti"] && ![track[@"moods"] containsObject:mood]) continue;
        if (![genre isEqualToString:@"Tutti"] && ![track[@"genres"] containsObject:genre]) continue;
        [matches addObject:track];
    }
    return matches;
}

static NSArray<NSDictionary *> *shuffled(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSDictionary *> *result = [items mutableCopy];
    for (NSUInteger index = result.count; index > 1; index--) {
        [result exchangeObjectAtIndex:index - 1 withObjectAtIndex:arc4random_uniform((uint32_t)index)];
    }
    return result;
}

@interface SGRHomeLyricsCard : UIView <SGPlayerStateObserver>
@property (nonatomic, copy) NSDictionary *selectedTrack;
@property (nonatomic, strong) SGKaraokeLine *selectedLine;
- (void)refreshRandom;
- (void)tracksChanged;
- (void)historyTracksDidLoad;
- (void)setPlayButtonTitle:(NSString *)title image:(UIImage *)image;
- (void)stopPlayback;
@end

@implementation SGRHomeLyricsCard {
    UILabel *_eyebrow, *_lineLabel, *_trackLabel;
    UIButton *_refreshButton, *_playButton;
    UIActivityIndicatorView *_spinner;
    NSArray<NSDictionary *> *_queue;
    NSMutableSet<NSString *> *_tried;
    NSUInteger _nextCandidate;
    NSTimer *_snippetTimer;
    BOOL _loading, _waitingForPlayer, _playingSnippet;
    NSUInteger _generation;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.055];
    self.layer.cornerRadius = 20;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.09].CGColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self build];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(tracksChanged)
                                               name:kTracksChanged object:nil];
    SGAddPlayerStateObserver(self);
    SPTPlayerTrack *playing = SGPlayerState().track;
    if (playing) SGRHomeLyricsObserveTrack(playing, playing.metadata);
    [self refreshRandom];
    return self;
}

- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

- (void)build {
    _eyebrow = [self label:11 weight:UIFontWeightBold color:SGRAccent()];
    _eyebrow.text = @"LYRICS · CASUALE";
    _eyebrow.adjustsFontForContentSizeCategory = YES;
    [self addSubview:_eyebrow];

    _refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_refreshButton setImage:[UIImage systemImageNamed:@"shuffle"] forState:UIControlStateNormal];
    _refreshButton.tintColor = SGRSecondary();
    _refreshButton.accessibilityLabel = @"Scegli un altro verso";
    [_refreshButton addTarget:self action:@selector(refreshRandom) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_refreshButton];

    _lineLabel = [self label:16 weight:UIFontWeightSemibold color:SGRPrimary()];
    _lineLabel.numberOfLines = 2;
    _lineLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _lineLabel.adjustsFontForContentSizeCategory = YES;
    [self addSubview:_lineLabel];

    _trackLabel = [self label:12 weight:UIFontWeightRegular color:SGRSecondary()];
    _trackLabel.numberOfLines = 1;
    _trackLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _trackLabel.adjustsFontForContentSizeCategory = YES;
    [self addSubview:_trackLabel];

    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _playButton.translatesAutoresizingMaskIntoConstraints = NO;
    _playButton.backgroundColor = [SGRAccent() colorWithAlphaComponent:0.18];
    _playButton.layer.cornerRadius = 12;
    _playButton.tintColor = SGRAccent();
    _playButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self setPlayButtonTitle:@"Ascolta il frammento" image:[UIImage systemImageNamed:@"play.fill"]];
    [_playButton addTarget:self action:@selector(playSnippet) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_playButton];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.color = SGRAccent();
    [self addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_eyebrow.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [_eyebrow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_refreshButton.centerYAnchor constraintEqualToAnchor:_eyebrow.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
        [_refreshButton.widthAnchor constraintEqualToConstant:44],
        [_refreshButton.heightAnchor constraintEqualToConstant:44],
        [_lineLabel.topAnchor constraintEqualToAnchor:_eyebrow.bottomAnchor constant:7],
        [_lineLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_lineLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_trackLabel.topAnchor constraintEqualToAnchor:_lineLabel.bottomAnchor constant:4],
        [_trackLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_trackLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_playButton.leadingAnchor constant:-8],
        [_trackLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-15],
        [_playButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_playButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
        [_playButton.heightAnchor constraintEqualToConstant:44],
        [_spinner.centerYAnchor constraintEqualToAnchor:_lineLabel.centerYAnchor],
        [_spinner.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
    ]];
}

- (void)tracksChanged {
    if (!_selectedTrack && !_loading && !_playingSnippet) [self refreshRandom];
    else if (_selectedTrack) {
        NSString *mood = SGRHomeLyricsMoodFilter(), *genre = SGRHomeLyricsGenreFilter();
        if (![mood isEqualToString:@"Tutti"] && ![_selectedTrack[@"moods"] containsObject:mood]) [self refreshRandom];
        else if (![genre isEqualToString:@"Tutti"] && ![_selectedTrack[@"genres"] containsObject:genre]) [self refreshRandom];
    }
}

- (void)setPlayButtonTitle:(NSString *)title image:(UIImage *)image {
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;
    configuration.image = image;
    configuration.imagePlacement = NSDirectionalRectEdgeLeading;
    configuration.imagePadding = 8;
    configuration.baseForegroundColor = SGRAccent();
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
    configuration.background.backgroundColor = [SGRAccent() colorWithAlphaComponent:0.18];
    configuration.background.cornerRadius = 12;
    _playButton.configuration = configuration;
}

- (void)historyTracksDidLoad {
    if (!_selectedTrack && !_playingSnippet) [self refreshRandom];
}

- (void)showMessage:(NSString *)message {
    self.selectedTrack = nil;
    self.selectedLine = nil;
    _lineLabel.text = message;
    _trackLabel.text = @"";
    _playButton.hidden = YES;
}

- (void)refreshRandom {
    _generation++;
    [self stopPlayback];
    _tried = [NSMutableSet set];
    _queue = shuffled(filteredTracks());
    _nextCandidate = 0;
    if (!_queue.count) {
        _loading = NO;
        [_spinner stopAnimating];
        NSString *mood = SGRHomeLyricsMoodFilter(), *genre = SGRHomeLyricsGenreFilter();
        [self showMessage:(![mood isEqualToString:@"Tutti"] || ![genre isEqualToString:@"Tutti"])
            ? @"Nessun brano trovato con questi filtri." : @"Apri una playlist: cercherò versi tra i brani disponibili."];
        return;
    }
    _loading = YES;
    [_spinner startAnimating];
    _playButton.hidden = YES;
    _lineLabel.text = @"Cerco un verso sincronizzato…";
    _trackLabel.text = @"";
    [self tryNextCandidate];
}

- (void)tryNextCandidate {
    if (_nextCandidate >= _queue.count || _tried.count >= kTryLimit) {
        _loading = NO;
        [_spinner stopAnimating];
        [self showMessage:@"Non ho trovato lyrics sincronizzate nei brani disponibili."];
        return;
    }
    NSDictionary *track = _queue[_nextCandidate++];
    NSString *trackID = track[@"id"];
    if (!trackID.length || [_tried containsObject:trackID]) {
        [self tryNextCandidate];
        return;
    }
    [_tried addObject:trackID];
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = _generation;
    SGLyricsFetchForTrack(trackID, track[@"title"], track[@"artist"], track[@"album"], [track[@"seconds"] integerValue],
                          ^(SGLyricsResult *result) {
        typeof(self) self = weakSelf;
        if (!self || generation != self->_generation) return;
        if (SGKaraokeLinesTiming(result.karaokeLines) == SGKaraokeTimingNone) {
            [self tryNextCandidate];
            return;
        }
        NSMutableArray<SGKaraokeLine *> *eligible = [NSMutableArray array];
        for (SGKaraokeLine *line in result.karaokeLines) {
            NSString *text = SGKaraokeLineText(line);
            NSInteger end = SGKaraokeSungEnd(line);
            NSInteger length = end - line.start;
            if (text.length && line.start >= 0 && length >= 1200 && length <= 12000 &&
                line.timing != SGKaraokeTimingNone) [eligible addObject:line];
        }
        if (!eligible.count) {
            [self tryNextCandidate];
            return;
        }
        NSUInteger index = arc4random_uniform((uint32_t)eligible.count);
        self.selectedTrack = track;
        self.selectedLine = eligible[index];
        self->_loading = NO;
        [self->_spinner stopAnimating];
        self->_lineLabel.text = SGKaraokeLineText(eligible[index]);
        self->_trackLabel.text = [NSString stringWithFormat:@"%@ · %@", track[@"title"], track[@"artist"]];
        self->_playButton.hidden = NO;
    });
}

- (void)beginSnippetForCurrentTrack {
    if (!self.selectedTrack || !self.selectedLine) return;
    NSString *targetURI = self.selectedTrack[@"uri"];
    NSString *currentURI = SGURIString(SGPlayerState().track.URI);
    if (![currentURI isEqualToString:targetURI]) {
        _waitingForPlayer = YES;
        [_snippetTimer invalidate];
        __weak typeof(self) weakSelf = self;
        _snippetTimer = [NSTimer scheduledTimerWithTimeInterval:10 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            typeof(self) self = weakSelf;
            if (!self || !self->_waitingForPlayer) return;
            self->_waitingForPlayer = NO;
            self->_snippetTimer = nil;
            [self showMessage:@"Spotify non ha avviato il brano in tempo."];
            SGLog(@"home lyrics: timed out waiting for %@", targetURI);
        }];
        id player = SGKaraokePlayer();
        if ([player respondsToSelector:@selector(playContext:options:)]) {
            id result = [(id<SPTPlayer>)player playContext:[NSURL URLWithString:targetURI] options:nil];
            SGLog(@"home lyrics: play %@ -> %@", targetURI, result);
        } else if (SGOpenSpotifyURI([NSURL URLWithString:targetURI])) {
            SGLog(@"home lyrics: Spotify player unavailable, opened %@ through the link dispatcher", targetURI);
        } else {
            _waitingForPlayer = NO;
            [_snippetTimer invalidate];
            _snippetTimer = nil;
            [self showMessage:@"Spotify non è pronto a riprodurre questo brano."];
            SGLog(@"home lyrics: no Spotify player or link dispatcher for %@", targetURI);
        }
        return;
    }
    [_snippetTimer invalidate];
    _snippetTimer = nil;
    id player = SGKaraokePlayer();
    if (![player respondsToSelector:@selector(seekTo:)] || ![player respondsToSelector:@selector(resume:)]) {
        [self showMessage:@"Il player Spotify non è disponibile al momento."];
        SGLog(@"home lyrics: Spotify player cannot seek/resume");
        return;
    }
    SGKaraokeSeek(self.selectedLine.start);
    [(id<SPTPlayer>)player resume:nil];
    _waitingForPlayer = NO;
    _playingSnippet = YES;
    [self setPlayButtonTitle:@"Frammento in riproduzione" image:[UIImage systemImageNamed:@"speaker.wave.2.fill"]];
    [_snippetTimer invalidate];
    NSTimeInterval duration = (SGKaraokeSungEnd(self.selectedLine) - self.selectedLine.start) / 1000.0;
    _snippetTimer = [NSTimer scheduledTimerWithTimeInterval:duration repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [self stopPlayback];
    }];
}

- (void)playSnippet {
    if (_playingSnippet) {
        [self stopPlayback];
        return;
    }
    [self beginSnippetForCurrentTrack];
}

- (void)stopPlayback {
    [_snippetTimer invalidate];
    _snippetTimer = nil;
    BOOL wasPlaying = _playingSnippet;
    _playingSnippet = NO;
    _waitingForPlayer = NO;
    if (wasPlaying && [SGURIString(SGPlayerState().track.URI) isEqualToString:self.selectedTrack[@"uri"]]) {
        id player = SGKaraokePlayer();
        if ([player respondsToSelector:@selector(pause:)]) [(id<SPTPlayer>)player pause:nil];
    }
    if (self.selectedTrack && !self->_loading) {
        [self setPlayButtonTitle:@"Ascolta il frammento" image:[UIImage systemImageNamed:@"play.fill"]];
        _playButton.hidden = NO;
    }
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (_waitingForPlayer && [SGURIString(state.track.URI) isEqualToString:self.selectedTrack[@"uri"]] && !state.isLoading) {
        [self beginSnippetForCurrentTrack];
    } else if (_playingSnippet && ![SGURIString(state.track.URI) isEqualToString:self.selectedTrack[@"uri"]]) {
        [self stopPlayback];
    }
}

- (void)dealloc {
    [_snippetTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end

@interface SGRHomeLyricsListState : NSObject
@property (nonatomic, strong) SGRHomeLyricsCard *card;
@property (nonatomic) UIEdgeInsets baseInset;
@property (nonatomic) UIEdgeInsets appliedInset;
@property (nonatomic) UIEdgeInsets baseIndicatorInset;
@property (nonatomic) BOOL hasInset;
@property (nonatomic) BOOL layingOut;
@end
@implementation SGRHomeLyricsListState
@end

static BOOL isHomeTab(UIViewController *page) {
    static Class homeClass;
    if (!homeClass) homeClass = NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController");
    for (UIViewController *parent = page; parent; parent = parent.parentViewController) {
        if (homeClass && [parent isKindOfClass:homeClass]) return YES;
    }
    return NO;
}

static SGRHomeLyricsListState *stateFor(UIScrollView *list) {
    SGRHomeLyricsListState *state = objc_getAssociatedObject(list, &kListStateKey);
    if (!state) {
        state = [SGRHomeLyricsListState new];
        state.baseInset = list.contentInset;
        state.appliedInset = list.contentInset;
        state.baseIndicatorInset = list.verticalScrollIndicatorInsets;
        state.hasInset = NO;
        objc_setAssociatedObject(list, &kListStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void layoutCard(UIScrollView *list) {
    SGRHomeLyricsListState *state = stateFor(list);
    if (state.layingOut) return;
    state.layingOut = YES;
    BOOL enabled = SGFlag(kLyricsEnabled, NO);
    if (!enabled) {
        BOOL wasAtTop = list.contentOffset.y <= state.appliedInset.top + 1;
        if (state.card) {
            [state.card removeFromSuperview];
            state.card = nil;
        }
        if (state.hasInset && UIEdgeInsetsEqualToEdgeInsets(list.contentInset, state.appliedInset)) {
            if (!UIEdgeInsetsEqualToEdgeInsets(list.contentInset, state.baseInset)) {
                list.contentInset = state.baseInset;
            }
            if (!UIEdgeInsetsEqualToEdgeInsets(list.verticalScrollIndicatorInsets, state.baseIndicatorInset)) {
                list.verticalScrollIndicatorInsets = state.baseIndicatorInset;
            }
            if (wasAtTop) [list setContentOffset:CGPointMake(list.contentOffset.x, -state.baseInset.top) animated:NO];
        } else if (state.hasInset && list.contentInset.top >= state.appliedInset.top - 1) {
            UIEdgeInsets inset = list.contentInset;
            inset.top = MAX(0, inset.top - kCardHeight);
            if (!UIEdgeInsetsEqualToEdgeInsets(list.contentInset, inset)) list.contentInset = inset;
            UIEdgeInsets indicators = list.verticalScrollIndicatorInsets;
            indicators.top = MAX(0, indicators.top - kCardHeight);
            if (!UIEdgeInsetsEqualToEdgeInsets(list.verticalScrollIndicatorInsets, indicators)) {
                list.verticalScrollIndicatorInsets = indicators;
            }
        }
        state.hasInset = NO;
        state.layingOut = NO;
        return;
    }
    if (addHistoryTracks() && state.card) [state.card historyTracksDidLoad];
    UIEdgeInsets currentInset = list.contentInset;
    if (state.hasInset && !UIEdgeInsetsEqualToEdgeInsets(currentInset, state.appliedInset)) {
        state.baseInset = UIEdgeInsetsMake(MAX(0, currentInset.top - kCardHeight),
            currentInset.left, currentInset.bottom, currentInset.right);
        UIEdgeInsets indicatorInset = list.verticalScrollIndicatorInsets;
        state.baseIndicatorInset = UIEdgeInsetsMake(MAX(0, indicatorInset.top - kCardHeight),
            indicatorInset.left, indicatorInset.bottom, indicatorInset.right);
    } else if (!state.hasInset) {
        state.baseInset = currentInset;
        state.baseIndicatorInset = list.verticalScrollIndicatorInsets;
    }
    if (!state.card) {
        state.card = [[SGRHomeLyricsCard alloc] initWithFrame:CGRectZero];
        [list addSubview:state.card];
    }
    CGRect cardFrame = CGRectMake(16, -kCardHeight, MAX(0, list.bounds.size.width - 32), kCardHeight);
    if (!CGRectEqualToRect(state.card.frame, cardFrame)) state.card.frame = cardFrame;
    UIEdgeInsets inset = state.baseInset;
    inset.top += kCardHeight;
    UIEdgeInsets indicatorInset = state.baseIndicatorInset;
    indicatorInset.top += kCardHeight;
    state.appliedInset = inset;
    state.hasInset = YES;
    if (!UIEdgeInsetsEqualToEdgeInsets(list.contentInset, inset)) list.contentInset = inset;
    if (!UIEdgeInsetsEqualToEdgeInsets(list.verticalScrollIndicatorInsets, indicatorInset)) {
        list.verticalScrollIndicatorInsets = indicatorInset;
    }
    BOOL atTop = list.contentOffset.y <= state.baseInset.top + 1;
    if (atTop && list.contentOffset.y > -inset.top + 1) {
        [list setContentOffset:CGPointMake(list.contentOffset.x, -inset.top) animated:NO];
    }
    [list bringSubviewToFront:state.card];
    state.layingOut = NO;
}

%hook _TtC16Home_EvoPageImpl33EvoLoadableResourceViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *page = (UIViewController *)self;
    if (!isHomeTab(page)) return;
    UICollectionView *homeList = nil;
    for (UIView *subview in page.viewIfLoaded.subviews) {
        if ([subview isKindOfClass:UICollectionView.class]) homeList = (UICollectionView *)subview;
    }
    if (homeList) {
        objc_setAssociatedObject(homeList, &kRootHomeListKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        layoutCard(homeList);
    }
}
%end

%hook _TtC16Home_CarouselKit29TouchCancellingCollectionView
- (void)layoutSubviews {
    %orig;
    if ([objc_getAssociatedObject(self, &kRootHomeListKey) boolValue]) layoutCard((UIScrollView *)self);
}
%end

%hook SPTPlayerTrack
- (NSDictionary *)metadata {
    NSDictionary *metadata = %orig;
    SGRHomeLyricsObserveTrack(self, metadata);
    return metadata;
}
%end

%ctor {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:kHomeLyricsSafetyResetKey]) {
        SGSetEnabled(kLyricsEnabled, NO);
        [defaults setBool:YES forKey:kHomeLyricsSafetyResetKey];
        [defaults synchronize];
        SGLog(@"home lyrics: disabled the saved setting once after the startup crash report");
    }
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC16Home_EvoPageImpl33EvoLoadableResourceViewController",
        @"_TtC16Home_CarouselKit29TouchCancellingCollectionView",
        @"SPTPlayerTrack",
    ]);
}
