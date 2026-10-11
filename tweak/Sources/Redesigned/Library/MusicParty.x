// Music Party is a pass-and-play quiz on one device. Spotify remains the only audio player; the game
// controls the current queue through its public-to-the-tweak player bridge and uses private local history
// only to build searchable artist/album choices and distractors.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Navigation/Links.h"
#import "Headers/SPTPlayer.h"
#import "MusicUniverse.h"
#import "MusicParty.h"
#import <math.h>
#import <stdlib.h>

typedef NS_ENUM(NSInteger, SGRPartyMode) {
    SGRPartyModeSong,
    SGRPartyModeArtist,
    SGRPartyModeCover,
    SGRPartyModeTimeline,
    SGRPartyModeLyrics,
    SGRPartyModeNext,
};

static NSString *const kPartyTitle = @"title";
static NSString *const kPartyArtist = @"artist";
static NSString *const kPartyAlbum = @"album";
static NSString *const kPartyURI = @"uri";
static NSString *const kPartyArtistURI = @"artistURI";
static NSString *const kPartyTimestamp = @"timestamp";
static NSString *const kPartyTrackID = @"trackID";
static char kPartyArtistRowKey;

static NSString *partyString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *partyURIString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString];
    return nil;
}

static NSString *partyTrackID(NSString *uri) {
    NSString *prefix = @"spotify:track:";
    return [uri hasPrefix:prefix] ? [uri substringFromIndex:prefix.length] : nil;
}

static BOOL partyIsPlayerTrack(id value) {
    Class trackClass = NSClassFromString(@"SPTPlayerTrack");
    return trackClass && [value isKindOfClass:trackClass];
}

static NSDictionary *partyRecord(SPTPlayerTrack *track) {
    if (!partyIsPlayerTrack(track)) return nil;
    NSString *title = partyString(track.trackTitle);
    NSString *artist = partyString(track.artistName);
    NSString *uri = partyURIString(track.URI);
    if (!title.length || !artist.length) return nil;
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : @{};
    return @{
        kPartyTitle: title,
        kPartyArtist: artist,
        kPartyAlbum: partyString(metadata[@"album_title"]) ?: partyString(metadata[@"album_name"]) ?: @"",
        kPartyURI: uri ?: @"",
        kPartyArtistURI: partyURIString(track.artistURI) ?: @"",
        kPartyTimestamp: @0,
        kPartyTrackID: partyTrackID(uri) ?: @"",
    };
}

static NSString *partyTrackKey(NSDictionary *track) {
    NSString *uri = partyString(track[kPartyURI]);
    if (uri.length) return uri;
    return [NSString stringWithFormat:@"%@|%@", [track[kPartyTitle] lowercaseString], [track[kPartyArtist] lowercaseString]];
}

static NSString *partyNormalize(NSString *text) {
    return [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}

static NSArray *partyShuffle(NSArray *items) {
    NSMutableArray *result = [items mutableCopy];
    for (NSUInteger i = result.count; i > 1; i--) {
        [result exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    }
    return result;
}

@interface SGRMusicPartyViewController : UIViewController <SGPlayerStateObserver, UITextFieldDelegate>
@end

@implementation SGRMusicPartyViewController {
    UILabel *_sourceLabel, *_statusLabel, *_gameStatusLabel, *_promptLabel, *_clueLabel, *_scoreLabel, *_turnLabel;
    UITextField *_artistSearch;
    UITextField *_playerNameField;
    UIStackView *_artistResults, *_modeGrid, *_answers, *_playerRoster, *_playerScoreboard;
    UILabel *_playerRosterStatus;
    UISegmentedControl *_teams;
    UIButton *_startButton, *_clipButton, *_nextButton;
    UIView *_setupView, *_gameView, *_coverView, *_playersPanel;
    UIImageView *_coverImage;
    SGRPartyMode _mode;
    NSArray<NSDictionary *> *_history;
    NSArray<NSDictionary *> *_pool;
    NSArray<NSDictionary *> *_artists;
    NSArray<NSDictionary *> *_answerRecords;
    NSMutableSet<NSString *> *_usedTrackKeys;
    NSDictionary *_roundTrack;
    NSDictionary *_selectedArtist;
    NSArray<SGKaraokeLine *> *_lyricLines;
    NSString *_lyricTrackID;
    NSTimer *_clipTimer;
    NSString *_clipTrackURI;
    double _clipRestorePosition;
    BOOL _clipWasPlaying, _clipActive, _sessionActive, _roundAnswered, _waitingForLyrics;
    NSMutableArray<NSString *> *_playerNames;
    NSMutableArray<NSNumber *> *_playerScores;
    NSUInteger _round, _roundLimit, _scoreOne, _scoreTwo, _activePlayerIndex;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    _history = SGRMusicUniverseHistoryEvents();
    _usedTrackKeys = [NSMutableSet set];
    _playerNames = [NSMutableArray array];
    _playerScores = [NSMutableArray array];
    _mode = SGRPartyModeSong;
    [self buildInterface];
    [self rebuildPool];
    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lyricsChanged:)
                                               name:SGKaraokeLinesDidChangeNotification object:nil];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    return label;
}

- (UIView *)card {
    UIView *view = [UIView new];
    view.backgroundColor = SGRElevated(UIColor.blackColor);
    view.layer.cornerRadius = SGRRadiusCard;
    view.layer.borderWidth = 1;
    view.layer.borderColor = SGRHairline().CGColor;
    return view;
}

- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePadding = 7;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    configuration.baseForegroundColor = SGRPrimary();
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(11, 14, 11, 14);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildInterface {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    UIStackView *content = [UIStackView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 18;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:SGRSideMargin],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-SGRSideMargin],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-2 * SGRSideMargin],
    ]];

    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    close.tintColor = SGRPrimary();
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    close.layer.cornerRadius = 20;
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];
    UILabel *title = [self label:@"Music Party" size:30 weight:UIFontWeightBold color:SGRPrimary()];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:48],
        [close.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [close.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:40],
        [close.heightAnchor constraintEqualToConstant:40],
        [title.leadingAnchor constraintEqualToAnchor:close.trailingAnchor constant:12],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    [content addArrangedSubview:header];

    UILabel *intro = [self label:@"Un solo telefono, un solo player, tutti intorno. Passatevi il dispositivo, rispondete a turno e fate partire il quiz sulla musica che state ascoltando." size:14 weight:UIFontWeightRegular color:SGRSecondary()];
    intro.numberOfLines = 0;
    [content addArrangedSubview:intro];

    _sourceLabel = [self label:@"" size:12 weight:UIFontWeightMedium color:SGRAccent()];
    _sourceLabel.numberOfLines = 0;
    [content addArrangedSubview:_sourceLabel];

    _setupView = [UIView new];
    UIStackView *setup = [UIStackView new];
    setup.translatesAutoresizingMaskIntoConstraints = NO;
    setup.axis = UILayoutConstraintAxisVertical;
    setup.spacing = 18;
    [_setupView addSubview:setup];
    [NSLayoutConstraint activateConstraints:@[
        [setup.topAnchor constraintEqualToAnchor:_setupView.topAnchor],
        [setup.leadingAnchor constraintEqualToAnchor:_setupView.leadingAnchor],
        [setup.trailingAnchor constraintEqualToAnchor:_setupView.trailingAnchor],
        [setup.bottomAnchor constraintEqualToAnchor:_setupView.bottomAnchor],
    ]];

    UILabel *sourceHeading = [self label:@"SCEGLI CHI ENTRA NEL QUIZ" size:12 weight:UIFontWeightBold color:SGRTertiary()];
    [setup addArrangedSubview:sourceHeading];
    _artistSearch = [UITextField new];
    _artistSearch.translatesAutoresizingMaskIntoConstraints = NO;
    _artistSearch.placeholder = @"Cerca un artista (cronologia o Spotify)";
    _artistSearch.textColor = SGRPrimary();
    _artistSearch.tintColor = SGRAccent();
    _artistSearch.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _artistSearch.layer.cornerRadius = 13;
    _artistSearch.leftViewMode = UITextFieldViewModeAlways;
    UIImageView *searchIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    searchIcon.tintColor = SGRSecondary();
    searchIcon.frame = CGRectMake(0, 0, 38, 42);
    searchIcon.contentMode = UIViewContentModeCenter;
    _artistSearch.leftView = searchIcon;
    _artistSearch.clearButtonMode = UITextFieldViewModeWhileEditing;
    _artistSearch.returnKeyType = UIReturnKeySearch;
    _artistSearch.delegate = self;
    [_artistSearch addTarget:self action:@selector(searchArtistsChanged) forControlEvents:UIControlEventEditingChanged];
    [setup addArrangedSubview:_artistSearch];
    [_artistSearch.heightAnchor constraintEqualToConstant:44].active = YES;
    _artistResults = [UIStackView new];
    _artistResults.axis = UILayoutConstraintAxisVertical;
    _artistResults.spacing = 2;
    [setup addArrangedSubview:_artistResults];

    UILabel *modeHeading = [self label:@"SCEGLI LA MODALITÀ" size:12 weight:UIFontWeightBold color:SGRTertiary()];
    [setup addArrangedSubview:modeHeading];
    _modeGrid = [UIStackView new];
    _modeGrid.axis = UILayoutConstraintAxisVertical;
    _modeGrid.spacing = 8;
    [setup addArrangedSubview:_modeGrid];
    [self buildModeButtons];

    UILabel *teamHeading = [self label:@"COME GIOCATE" size:12 weight:UIFontWeightBold color:SGRTertiary()];
    [setup addArrangedSubview:teamHeading];
    _teams = [[UISegmentedControl alloc] initWithItems:@[@"Singolo", @"Squadre", @"Giocatori"]];
    _teams.selectedSegmentIndex = 0;
    _teams.selectedSegmentTintColor = [SGRAccent() colorWithAlphaComponent:0.8];
    [_teams addTarget:self action:@selector(teamModeChanged) forControlEvents:UIControlEventValueChanged];
    [setup addArrangedSubview:_teams];
    _playersPanel = [self card];
    UIStackView *playersContent = [UIStackView new];
    playersContent.translatesAutoresizingMaskIntoConstraints = NO;
    playersContent.axis = UILayoutConstraintAxisVertical;
    playersContent.spacing = 10;
    [_playersPanel addSubview:playersContent];
    [NSLayoutConstraint activateConstraints:@[
        [playersContent.topAnchor constraintEqualToAnchor:_playersPanel.topAnchor constant:14],
        [playersContent.leadingAnchor constraintEqualToAnchor:_playersPanel.leadingAnchor constant:14],
        [playersContent.trailingAnchor constraintEqualToAnchor:_playersPanel.trailingAnchor constant:-14],
        [playersContent.bottomAnchor constraintEqualToAnchor:_playersPanel.bottomAnchor constant:-14],
    ]];
    UILabel *playersTitle = [self label:@"GIOCATORI · MAX 8" size:12 weight:UIFontWeightBold color:SGRTertiary()];
    [playersContent addArrangedSubview:playersTitle];
    _playerRoster = [UIStackView new];
    _playerRoster.axis = UILayoutConstraintAxisVertical;
    _playerRoster.spacing = 6;
    [playersContent addArrangedSubview:_playerRoster];
    UIStackView *addPlayerRow = [UIStackView new];
    addPlayerRow.axis = UILayoutConstraintAxisHorizontal;
    addPlayerRow.spacing = 8;
    _playerNameField = [UITextField new];
    _playerNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _playerNameField.placeholder = @"Nome giocatore";
    _playerNameField.textColor = SGRPrimary();
    _playerNameField.tintColor = SGRAccent();
    _playerNameField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _playerNameField.layer.cornerRadius = 12;
    _playerNameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _playerNameField.returnKeyType = UIReturnKeyDone;
    _playerNameField.delegate = self;
    [addPlayerRow addArrangedSubview:_playerNameField];
    [_playerNameField.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIButton *addPlayer = [self button:@"Aggiungi" symbol:@"person.badge.plus" action:@selector(addPartyPlayer)];
    [addPlayerRow addArrangedSubview:addPlayer];
    [playersContent addArrangedSubview:addPlayerRow];
    _playerRosterStatus = [self label:@"Aggiungi almeno due nomi per attivare la sfida individuale." size:12
                                weight:UIFontWeightRegular color:SGRSecondary()];
    _playerRosterStatus.numberOfLines = 0;
    [playersContent addArrangedSubview:_playerRosterStatus];
    _playersPanel.hidden = YES;
    [setup addArrangedSubview:_playersPanel];
    [self renderPartyPlayers];
    _statusLabel = [self label:@"" size:12 weight:UIFontWeightRegular color:SGRTertiary()];
    _statusLabel.numberOfLines = 0;
    [setup addArrangedSubview:_statusLabel];
    _startButton = [self button:@"Inizia la partita" symbol:@"play.fill" action:@selector(startGame)];
    [setup addArrangedSubview:_startButton];
    [content addArrangedSubview:_setupView];

    _gameView = [UIView new];
    _gameView.hidden = YES;
    UIStackView *game = [UIStackView new];
    game.translatesAutoresizingMaskIntoConstraints = NO;
    game.axis = UILayoutConstraintAxisVertical;
    game.spacing = 14;
    [_gameView addSubview:game];
    [NSLayoutConstraint activateConstraints:@[
        [game.topAnchor constraintEqualToAnchor:_gameView.topAnchor],
        [game.leadingAnchor constraintEqualToAnchor:_gameView.leadingAnchor],
        [game.trailingAnchor constraintEqualToAnchor:_gameView.trailingAnchor],
        [game.bottomAnchor constraintEqualToAnchor:_gameView.bottomAnchor],
    ]];
    UIView *scoreCard = [self card];
    UIStackView *scoreRow = [UIStackView new];
    scoreRow.translatesAutoresizingMaskIntoConstraints = NO;
    scoreRow.axis = UILayoutConstraintAxisHorizontal;
    scoreRow.distribution = UIStackViewDistributionEqualSpacing;
    scoreRow.alignment = UIStackViewAlignmentCenter;
    UIStackView *scoreContent = [UIStackView new];
    scoreContent.translatesAutoresizingMaskIntoConstraints = NO;
    scoreContent.axis = UILayoutConstraintAxisVertical;
    scoreContent.spacing = 12;
    [scoreCard addSubview:scoreContent];
    [NSLayoutConstraint activateConstraints:@[
        [scoreContent.topAnchor constraintEqualToAnchor:scoreCard.topAnchor constant:13],
        [scoreContent.bottomAnchor constraintEqualToAnchor:scoreCard.bottomAnchor constant:-13],
        [scoreContent.leadingAnchor constraintEqualToAnchor:scoreCard.leadingAnchor constant:16],
        [scoreContent.trailingAnchor constraintEqualToAnchor:scoreCard.trailingAnchor constant:-16],
    ]];
    _turnLabel = [self label:@"ROUND 1 / 10" size:12 weight:UIFontWeightBold color:SGRAccent()];
    _scoreLabel = [self label:@"0 punti" size:14 weight:UIFontWeightSemibold color:SGRPrimary()];
    _scoreLabel.textAlignment = NSTextAlignmentRight;
    [scoreRow addArrangedSubview:_turnLabel];
    [scoreRow addArrangedSubview:_scoreLabel];
    [scoreContent addArrangedSubview:scoreRow];
    _playerScoreboard = [UIStackView new];
    _playerScoreboard.axis = UILayoutConstraintAxisVertical;
    _playerScoreboard.spacing = 4;
    _playerScoreboard.hidden = YES;
    [scoreContent addArrangedSubview:_playerScoreboard];
    [game addArrangedSubview:scoreCard];

    _coverView = [UIView new];
    _coverView.hidden = YES;
    _coverImage = [UIImageView new];
    _coverImage.translatesAutoresizingMaskIntoConstraints = NO;
    _coverImage.contentMode = UIViewContentModeScaleAspectFill;
    _coverImage.clipsToBounds = YES;
    _coverImage.layer.cornerRadius = SGRRadiusCard;
    [_coverView addSubview:_coverImage];
    [NSLayoutConstraint activateConstraints:@[
        [_coverImage.topAnchor constraintEqualToAnchor:_coverView.topAnchor],
        [_coverImage.leadingAnchor constraintEqualToAnchor:_coverView.leadingAnchor],
        [_coverImage.trailingAnchor constraintEqualToAnchor:_coverView.trailingAnchor],
        [_coverImage.bottomAnchor constraintEqualToAnchor:_coverView.bottomAnchor],
        [_coverImage.heightAnchor constraintEqualToConstant:220],
    ]];
    [game addArrangedSubview:_coverView];

    UIView *questionCard = [self card];
    UIStackView *question = [UIStackView new];
    question.translatesAutoresizingMaskIntoConstraints = NO;
    question.axis = UILayoutConstraintAxisVertical;
    question.spacing = 8;
    [questionCard addSubview:question];
    [NSLayoutConstraint activateConstraints:@[
        [question.topAnchor constraintEqualToAnchor:questionCard.topAnchor constant:18],
        [question.leadingAnchor constraintEqualToAnchor:questionCard.leadingAnchor constant:18],
        [question.trailingAnchor constraintEqualToAnchor:questionCard.trailingAnchor constant:-18],
        [question.bottomAnchor constraintEqualToAnchor:questionCard.bottomAnchor constant:-18],
    ]];
    _promptLabel = [self label:@"" size:22 weight:UIFontWeightBold color:SGRPrimary()];
    _promptLabel.numberOfLines = 0;
    _clueLabel = [self label:@"" size:14 weight:UIFontWeightRegular color:SGRSecondary()];
    _clueLabel.numberOfLines = 0;
    [question addArrangedSubview:_promptLabel];
    [question addArrangedSubview:_clueLabel];
    [game addArrangedSubview:questionCard];

    _clipButton = [self button:@"Ascolta 5 secondi" symbol:@"waveform" action:@selector(playClip)];
    _clipButton.hidden = YES;
    [game addArrangedSubview:_clipButton];
    _answers = [UIStackView new];
    _answers.axis = UILayoutConstraintAxisVertical;
    _answers.spacing = 9;
    [game addArrangedSubview:_answers];
    _statusLabel.text = @"";
    _nextButton = [self button:@"Prossimo round" symbol:@"arrow.right" action:@selector(nextRound)];
    _nextButton.hidden = YES;
    [game addArrangedSubview:_nextButton];
    _gameStatusLabel = [self label:@"" size:13 weight:UIFontWeightMedium color:SGRSecondary()];
    _gameStatusLabel.numberOfLines = 0;
    [game insertArrangedSubview:_gameStatusLabel atIndex:game.arrangedSubviews.count - 1];
    [content addArrangedSubview:_gameView];

    UILabel *privacy = [self label:@"La partita usa Spotify sul dispositivo e i dati locali importati nell'Atlante. Nessun account giocatore o servizio esterno richiesto." size:11 weight:UIFontWeightRegular color:SGRTertiary()];
    privacy.numberOfLines = 0;
    [content addArrangedSubview:privacy];
}

- (void)buildModeButtons {
    NSArray<NSDictionary *> *modes = @[
        @{@"title": @"Indovina il brano", @"symbol": @"waveform", @"mode": @(SGRPartyModeSong)},
        @{@"title": @"Indovina l'artista", @"symbol": @"person.wave.2", @"mode": @(SGRPartyModeArtist)},
        @{@"title": @"Cover alla cieca", @"symbol": @"opticaldisc", @"mode": @(SGRPartyModeCover)},
        @{@"title": @"Prima o dopo?", @"symbol": @"clock.arrow.circlepath", @"mode": @(SGRPartyModeTimeline)},
        @{@"title": @"Completa il verso", @"symbol": @"quote.bubble", @"mode": @(SGRPartyModeLyrics)},
        @{@"title": @"Prevedi il prossimo", @"symbol": @"forward.end", @"mode": @(SGRPartyModeNext)},
    ];
    for (NSUInteger rowIndex = 0; rowIndex < 3; rowIndex++) {
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 8;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger column = 0; column < 2; column++) {
            NSDictionary *entry = modes[rowIndex * 2 + column];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
            config.title = entry[@"title"];
            config.image = [UIImage systemImageNamed:entry[@"symbol"]];
            config.imagePlacement = NSDirectionalRectEdgeTop;
            config.imagePadding = 8;
            config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
            config.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            config.baseForegroundColor = SGRPrimary();
            config.contentInsets = NSDirectionalEdgeInsetsMake(12, 8, 12, 8);
            button.configuration = config;
            button.titleLabel.numberOfLines = 2;
            button.titleLabel.textAlignment = NSTextAlignmentCenter;
            button.tag = [entry[@"mode"] integerValue];
            [button addTarget:self action:@selector(modePicked:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:button];
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:82].active = YES;
        }
        [_modeGrid addArrangedSubview:row];
    }
    [self updateModeSelection];
}

- (void)updateModeSelection {
    for (UIStackView *row in _modeGrid.arrangedSubviews) {
        for (UIButton *button in row.arrangedSubviews) {
            UIButtonConfiguration *config = button.configuration;
            BOOL selected = button.tag == _mode;
            config.baseBackgroundColor = selected ? [SGRAccent() colorWithAlphaComponent:0.25] : [UIColor colorWithWhite:1 alpha:0.08];
            config.baseForegroundColor = selected ? SGRPrimary() : SGRSecondary();
            button.configuration = config;
            button.layer.borderWidth = selected ? 1 : 0;
            button.layer.borderColor = SGRAccent().CGColor;
        }
    }
    [self refreshStatus];
}

- (void)modePicked:(UIButton *)sender {
    _mode = (SGRPartyMode)sender.tag;
    [self updateModeSelection];
}

- (void)teamModeChanged {
    _playersPanel.hidden = _teams.selectedSegmentIndex != 2;
    [self refreshStatus];
}

- (void)addPartyPlayer {
    NSString *name = [_playerNameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) {
        _playerRosterStatus.text = @"Scrivi un nome prima di aggiungerlo.";
        _playerRosterStatus.textColor = UIColor.systemOrangeColor;
        return;
    }
    if (_playerNames.count >= 8) {
        _playerRosterStatus.text = @"Puoi aggiungere al massimo 8 giocatori.";
        _playerRosterStatus.textColor = UIColor.systemOrangeColor;
        return;
    }
    for (NSString *existing in _playerNames) {
        if ([partyNormalize(existing) isEqualToString:partyNormalize(name)]) {
            _playerRosterStatus.text = @"Questo nome è già nella partita.";
            _playerRosterStatus.textColor = UIColor.systemOrangeColor;
            return;
        }
    }
    [_playerNames addObject:name];
    _playerNameField.text = @"";
    _playerRosterStatus.textColor = SGRSecondary();
    [self renderPartyPlayers];
    [self refreshStatus];
}

- (void)removePartyPlayer:(UIButton *)sender {
    if (sender.tag >= _playerNames.count) return;
    [_playerNames removeObjectAtIndex:sender.tag];
    _playerRosterStatus.textColor = SGRSecondary();
    [self renderPartyPlayers];
    [self refreshStatus];
}

- (void)renderPartyPlayers {
    for (UIView *view in _playerRoster.arrangedSubviews) {
        [_playerRoster removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSUInteger index = 0; index < _playerNames.count; index++) {
        NSString *name = _playerNames[index];
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8;
        row.layoutMargins = UIEdgeInsetsMake(4, 10, 4, 4);
        row.layoutMarginsRelativeArrangement = YES;
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.055];
        row.layer.cornerRadius = 12;
        UILabel *nameLabel = [self label:name size:15 weight:UIFontWeightSemibold color:SGRPrimary()];
        [row addArrangedSubview:nameLabel];
        UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
        [remove setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        remove.tintColor = SGRSecondary();
        remove.accessibilityLabel = [NSString stringWithFormat:@"Rimuovi %@", name];
        remove.tag = index;
        [remove addTarget:self action:@selector(removePartyPlayer:) forControlEvents:UIControlEventTouchUpInside];
        [remove.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [remove.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [row addArrangedSubview:remove];
        [_playerRoster addArrangedSubview:row];
    }
    _playerRosterStatus.text = _playerNames.count < 2
        ? @"Aggiungi almeno due nomi per attivare la sfida individuale."
        : [NSString stringWithFormat:@"%lu giocatori · turno a rotazione · punto a ogni risposta esatta.",
           (unsigned long)_playerNames.count];
    _playerRosterStatus.textColor = SGRSecondary();
}

- (void)rebuildPool {
    NSMutableDictionary<NSString *, NSDictionary *> *tracks = [NSMutableDictionary dictionary];
    for (NSDictionary *event in _history) {
        NSString *title = partyString(event[@"track"]);
        NSString *artist = partyString(event[@"artist"]);
        if (!title.length || !artist.length) continue;
        NSString *uri = partyString(event[@"trackURI"]) ?: @"";
        NSMutableDictionary *record = [@{
            kPartyTitle: title,
            kPartyArtist: artist,
            kPartyAlbum: partyString(event[@"album"]) ?: @"",
            kPartyURI: uri,
            kPartyArtistURI: partyString(event[@"artistURI"]) ?: @"",
            kPartyTimestamp: event[@"timestamp"] ?: @0,
            kPartyTrackID: partyTrackID(uri) ?: @"",
        } mutableCopy];
        NSString *key = partyTrackKey(record);
        NSDictionary *existing = tracks[key];
        if (!existing || [record[kPartyTimestamp] compare:existing[kPartyTimestamp]] == NSOrderedDescending) tracks[key] = record;
    }
    SPTPlayerState *state = SGPlayerState();
    NSMutableArray *queue = [NSMutableArray array];
    if (partyIsPlayerTrack(state.track)) [queue addObject:state.track];
    for (id track in [state.future isKindOfClass:NSArray.class] ? state.future : @[]) {
        if (partyIsPlayerTrack(track)) [queue addObject:track];
    }
    for (id track in [state.reverse isKindOfClass:NSArray.class] ? state.reverse : @[]) {
        if (partyIsPlayerTrack(track)) [queue addObject:track];
    }
    for (SPTPlayerTrack *track in queue) {
        NSDictionary *record = partyRecord(track);
        if (record) {
            NSString *key = partyTrackKey(record);
            NSMutableDictionary *enriched = [record mutableCopy];
            if (tracks[key]) {
                NSDictionary *event = tracks[key];
                if (![enriched[kPartyAlbum] length]) enriched[kPartyAlbum] = event[@"album"] ?: @"";
                enriched[kPartyTimestamp] = event[@"timestamp"] ?: @0;
            }
            tracks[key] = enriched;
        }
    }
    _pool = tracks.allValues;
    NSMutableDictionary<NSString *, NSDictionary *> *artists = [NSMutableDictionary dictionary];
    for (NSDictionary *track in _pool) {
        NSString *name = partyString(track[kPartyArtist]);
        NSString *key = partyNormalize(name);
        if (!key.length) continue;
        NSMutableDictionary *artist = [artists[key] mutableCopy] ?: [@{
            kPartyArtist: name,
            kPartyArtistURI: partyString(track[kPartyArtistURI]) ?: @"",
            kPartyTimestamp: @0,
        } mutableCopy];
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[track[kPartyTimestamp] doubleValue]];
        NSDate *current = [NSDate dateWithTimeIntervalSince1970:[artist[kPartyTimestamp] doubleValue]];
        if ([date compare:current] == NSOrderedDescending) artist[kPartyTimestamp] = track[kPartyTimestamp];
        if (![artist[kPartyArtistURI] length] && [track[kPartyArtistURI] length]) artist[kPartyArtistURI] = track[kPartyArtistURI];
        artists[key] = artist;
    }
    _artists = [artists.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [partyNormalize(a[kPartyArtist]) compare:partyNormalize(b[kPartyArtist])];
    }];
    [self renderArtistResults];
    [self refreshSource];
    [self refreshStatus];
}

- (NSArray<NSDictionary *> *)eligibleTracks {
    if (!_selectedArtist) return _pool ?: @[];
    NSString *artist = partyNormalize(_selectedArtist[kPartyArtist]);
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *track in _pool) {
        if ([partyNormalize(track[kPartyArtist]) isEqualToString:artist]) [matches addObject:track];
    }
    return matches;
}

- (void)refreshSource {
    SPTPlayerState *state = SGPlayerState();
    NSString *context = partyURIString(state.contextURI);
    NSString *source = context.length ? [context stringByReplacingOccurrencesOfString:@"spotify:" withString:@""] : @"coda Spotify";
    NSString *artistFilter = _selectedArtist
        ? [NSString stringWithFormat:@" · artista quiz: %@", _selectedArtist[kPartyArtist]]
        : @"";
    _sourceLabel.text = [NSString stringWithFormat:@"SPOTIFY · %@%@ · %lu brani nel catalogo",
                         source, artistFilter, (unsigned long)[self eligibleTracks].count];
}

- (void)refreshStatus {
    SPTPlayerState *state = SGPlayerState();
    BOOL hasCurrent = partyIsPlayerTrack(state.track);
    BOOL ready = YES;
    NSString *message = _teams.selectedSegmentIndex == 1
        ? @"Squadre A e B si alternano: passatevi il telefono dopo ogni round."
        : (_teams.selectedSegmentIndex == 2
           ? @"I giocatori si alternano automaticamente: passate il telefono a chi è indicato nel turno."
           : @"Partita singola da 10 round sullo stesso iPhone.");
    if (_mode == SGRPartyModeSong && !hasCurrent) {
        message = @"Per la modalità audio, fai partire Spotify da una playlist, un album o la radio di un artista e torna qui.";
        ready = NO;
    } else if (_mode == SGRPartyModeSong && _pool.count < 2) {
        message = @"Servono almeno due brani per creare le risposte: avvia una coda Spotify più ampia o importa la cronologia.";
        ready = NO;
    } else if (_mode == SGRPartyModeCover) {
        NSDictionary *current = partyRecord(state.track);
        NSString *album = partyString(current[kPartyAlbum]) ?: @"";
        for (NSDictionary *candidate in _pool) {
            if ([partyTrackKey(candidate) isEqualToString:partyTrackKey(current)] && [candidate[kPartyAlbum] length]) {
                album = candidate[kPartyAlbum];
                break;
            }
        }
        if (!hasCurrent || !SGRNowPlayingArtwork(NULL, NULL) || !album.length) {
            message = @"Avvia un brano con copertina e album disponibili: la cover verrà nascosta durante il quiz.";
            ready = NO;
        }
    } else if (_mode == SGRPartyModeLyrics && !hasCurrent) {
        message = @"Serve un brano in riproduzione; le lyrics disponibili verranno caricate da spoti.pw.";
        ready = NO;
    } else if (_mode == SGRPartyModeArtist && !_artists.count) {
        message = @"Avvia un brano o importa la cronologia per avere artisti da usare nel quiz.";
        ready = NO;
    } else if (_mode == SGRPartyModeArtist && _artists.count < 2) {
        message = @"Per creare le risposte alternative servono almeno due artisti tra coda e cronologia.";
        ready = NO;
    } else if (_mode == SGRPartyModeTimeline) {
        NSMutableSet *datedArtists = [NSMutableSet set];
        for (NSDictionary *track in _pool) {
            if ([track[kPartyTimestamp] doubleValue] > 0) {
                NSString *artist = partyNormalize(track[kPartyArtist]);
                if (artist.length) [datedArtists addObject:artist];
            }
        }
        if (datedArtists.count < 2) {
            message = @"Servono ascolti datati di almeno due artisti: importa la Cronologia di ascolto estesa.";
            ready = NO;
        }
    } else if (_mode == SGRPartyModeNext) {
        BOOL hasNext = NO;
        for (id track in [state.future isKindOfClass:NSArray.class] ? state.future : @[]) {
            if (partyIsPlayerTrack(track)) { hasNext = YES; break; }
        }
        if (!hasNext) {
            message = @"Aggiungi almeno un brano alla coda futura di Spotify per usare questa modalità.";
            ready = NO;
        }
    }
    if (_teams.selectedSegmentIndex == 2 && _playerNames.count < 2) {
        message = @"Aggiungi almeno due giocatori nella lista qui sopra per iniziare la sfida.";
        ready = NO;
    }
    _statusLabel.text = message;
    _startButton.enabled = ready;
    _startButton.alpha = _startButton.enabled ? 1 : 0.45;
}

- (void)searchArtistsChanged {
    [self renderArtistResults];
}

- (void)renderArtistResults {
    for (UIView *view in _artistResults.arrangedSubviews) {
        [_artistResults removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSString *query = partyNormalize(_artistSearch.text ?: @"");
    if (!query.length) return;
    NSUInteger shown = 0;
    for (NSDictionary *artist in _artists) {
        if ([partyNormalize(artist[kPartyArtist]) rangeOfString:query].location == NSNotFound) continue;
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        [row setTitle:[NSString stringWithFormat:@"%@%@", artist[kPartyArtist],
                       [artist[kPartyArtistURI] length] ? @"  ·  Spotify" : @"  ·  ascolti locali"]
               forState:UIControlStateNormal];
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.tintColor = SGRPrimary();
        row.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        row.accessibilityLabel = [NSString stringWithFormat:@"Usa la musica di %@", artist[kPartyArtist]];
        objc_setAssociatedObject(row, &kPartyArtistRowKey, artist, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [row addTarget:self action:@selector(artistPicked:) forControlEvents:UIControlEventTouchUpInside];
        [_artistResults addArrangedSubview:row];
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
        if (++shown == 5) break;
    }
    UIButton *spotifySearch = [self button:[NSString stringWithFormat:@"Cerca “%@” in Spotify", _artistSearch.text]
                                    symbol:@"arrow.up.right" action:@selector(searchArtistInSpotify)];
    [_artistResults addArrangedSubview:spotifySearch];
    if (!shown) {
        UILabel *none = [self label:@"Nessun artista trovato: importa la cronologia o avvia prima la sua radio in Spotify." size:12 weight:UIFontWeightRegular color:SGRTertiary()];
        none.numberOfLines = 0;
        [_artistResults addArrangedSubview:none];
    }
}

- (void)searchArtistInSpotify {
    NSString *query = [_artistSearch.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return;
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    NSString *escaped = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *uri = escaped.length ? [NSURL URLWithString:[@"spotify:search:" stringByAppendingString:escaped]] : nil;
    [self dismissViewControllerAnimated:YES completion:^{
        if (!SGOpenSpotifyURI(uri)) SGLog(@"music party: Spotify could not open artist search for %@", query);
    }];
}

- (void)artistPicked:(UIButton *)sender {
    _selectedArtist = objc_getAssociatedObject(sender, &kPartyArtistRowKey);
    [_artistSearch resignFirstResponder];
    _artistSearch.text = _selectedArtist[kPartyArtist];
    [self renderArtistResults];
    [self rebuildPool];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _playerNameField) {
        [self addPartyPlayer];
        return YES;
    }
    [textField resignFirstResponder];
    return YES;
}

- (void)startGame {
    if (!_startButton.enabled) return;
    [_usedTrackKeys removeAllObjects];
    _round = 0;
    _scoreOne = _scoreTwo = 0;
    _roundLimit = 10;
    _activePlayerIndex = 0;
    [_playerScores removeAllObjects];
    if (_teams.selectedSegmentIndex == 2) {
        NSUInteger playerCount = _playerNames.count;
        _roundLimit = ((10 + playerCount - 1) / playerCount) * playerCount;
        for (NSUInteger i = 0; i < playerCount; i++) [_playerScores addObject:@0];
    }
    _sessionActive = YES;
    _roundAnswered = NO;
    _setupView.hidden = YES;
    _gameView.hidden = NO;
    [self prepareRound];
}

- (void)prepareRound {
    [_clipTimer invalidate];
    _clipTimer = nil;
    _clipActive = NO;
    _roundAnswered = NO;
    [_nextButton removeTarget:self action:@selector(nextRound) forControlEvents:UIControlEventTouchUpInside];
    [_nextButton removeTarget:self action:@selector(returnToSetup) forControlEvents:UIControlEventTouchUpInside];
    [_nextButton addTarget:self action:@selector(nextRound) forControlEvents:UIControlEventTouchUpInside];
    UIButtonConfiguration *nextConfig = _nextButton.configuration;
    nextConfig.title = @"Prossimo round";
    nextConfig.image = [UIImage systemImageNamed:@"arrow.right"];
    _nextButton.configuration = nextConfig;
    _nextButton.hidden = YES;
    _gameStatusLabel.text = @"";
    _clipButton.hidden = _mode != SGRPartyModeSong;
    _coverView.hidden = _mode != SGRPartyModeCover;
    for (UIView *view in _answers.arrangedSubviews) {
        [_answers removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    _answerRecords = @[];
    _lyricLines = nil;
    _waitingForLyrics = NO;
    if (_round >= _roundLimit) {
        [self finishGame];
        return;
    }
    _round++;
    if (_teams.selectedSegmentIndex == 2) _activePlayerIndex = (_round - 1) % _playerNames.count;
    [self updateScore];
    if (_teams.selectedSegmentIndex == 2) {
        _gameStatusLabel.text = [NSString stringWithFormat:@"Turno di %@ · passate il telefono prima di rispondere.", _playerNames[_activePlayerIndex]];
    }
    SPTPlayerState *state = SGPlayerState();
    NSDictionary *current = partyRecord(state.track);
    NSArray<NSDictionary *> *eligible = [self eligibleTracks];
    switch (_mode) {
        case SGRPartyModeSong:
            if (!current) { _promptLabel.text = @"Nessun brano attivo in Spotify"; _clueLabel.text = @"Avvia un brano, poi riprova."; _clipButton.hidden = YES; [self showSetupRecovery]; return; }
            _roundTrack = [self enrichedCurrent:current];
            _promptLabel.text = @"Indovina il brano";
            _clueLabel.text = @"Ascolta i primi secondi e scegli titolo + artista.";
            break;
        case SGRPartyModeArtist:
            _roundTrack = [self chooseTrackFrom:eligible];
            if (!_roundTrack) { [self showSetupRecovery]; return; }
            _promptLabel.text = @"Chi canta questo brano?";
            _clueLabel.text = [NSString stringWithFormat:@"Titolo: %@%@", _roundTrack[kPartyTitle],
                               [partyString(_roundTrack[kPartyAlbum]) length] ? [NSString stringWithFormat:@"\nAlbum: %@", _roundTrack[kPartyAlbum]] : @""];
            break;
        case SGRPartyModeCover: {
            if (!current) { _promptLabel.text = @"Avvia un brano in Spotify"; _clueLabel.text = @""; [self showSetupRecovery]; return; }
            _roundTrack = [self enrichedCurrent:current];
            NSString *artURI = nil;
            UIImage *art = SGRNowPlayingArtwork(&artURI, NULL);
            if (![artURI isEqualToString:current[kPartyURI]]) art = nil;
            _coverImage.image = art;
            _promptLabel.text = @"A quale album appartiene?";
            _clueLabel.text = @"Cover del brano corrente: indovina l'album.";
            break;
        }
        case SGRPartyModeTimeline:
            [self prepareTimelineRound:_pool];
            return;
        case SGRPartyModeLyrics:
            if (!current) { _promptLabel.text = @"Avvia un brano in Spotify"; _clueLabel.text = @"Servono lyrics disponibili per il brano corrente."; [self showSetupRecovery]; return; }
            _roundTrack = [self enrichedCurrent:current];
            [self prepareLyricsRound:_roundTrack];
            return;
        case SGRPartyModeNext:
            [self prepareNextRound];
            return;
    }
    [self prepareAnswersForCurrentRound];
}

- (NSDictionary *)enrichedCurrent:(NSDictionary *)record {
    for (NSDictionary *candidate in _pool) {
        if ([partyTrackKey(candidate) isEqualToString:partyTrackKey(record)]) {
            NSMutableDictionary *result = [record mutableCopy];
            result[kPartyAlbum] = partyString(result[kPartyAlbum]).length ? result[kPartyAlbum] : candidate[kPartyAlbum] ?: @"";
            result[kPartyTimestamp] = candidate[kPartyTimestamp] ?: @0;
            if (![result[kPartyArtistURI] length]) result[kPartyArtistURI] = candidate[kPartyArtistURI] ?: @"";
            return result;
        }
    }
    return record;
}

- (NSDictionary *)chooseTrackFrom:(NSArray<NSDictionary *> *)tracks {
    NSMutableArray *available = [NSMutableArray array];
    for (NSDictionary *track in tracks) {
        NSString *key = partyTrackKey(track);
        if (![_usedTrackKeys containsObject:key]) [available addObject:track];
    }
    if (!available.count && tracks.count) {
        [_usedTrackKeys removeAllObjects];
        [available addObjectsFromArray:tracks];
    }
    if (!available.count) {
        _promptLabel.text = @"Non ci sono abbastanza brani";
        _clueLabel.text = @"Importa cronologia o scegli un artista con più ascolti.";
        return nil;
    }
    NSDictionary *chosen = available[arc4random_uniform((uint32_t)available.count)];
    [_usedTrackKeys addObject:partyTrackKey(chosen)];
    return chosen;
}

- (void)prepareTimelineRound:(NSArray<NSDictionary *> *)tracks {
    NSMutableDictionary<NSString *, NSDictionary *> *latest = [NSMutableDictionary dictionary];
    for (NSDictionary *track in tracks) {
        if ([track[kPartyTimestamp] doubleValue] <= 0) continue;
        NSString *key = partyNormalize(track[kPartyArtist]);
        NSDictionary *old = latest[key];
        if (!old || [track[kPartyTimestamp] compare:old[kPartyTimestamp]] == NSOrderedDescending) latest[key] = track;
    }
    NSArray *artists = latest.allValues;
    if (artists.count < 2) {
        _promptLabel.text = @"La timeline ha bisogno di più ascolti";
        _clueLabel.text = @"Importa almeno due artisti dalla cronologia Spotify.";
        [self showSetupRecovery];
        return;
    }
    NSArray *shuffled = partyShuffle(artists);
    NSDictionary *a = shuffled[0], *b = shuffled[1];
    BOOL aEarlier = [a[kPartyTimestamp] compare:b[kPartyTimestamp]] == NSOrderedAscending;
    NSDictionary *first = aEarlier ? a : b, *second = aEarlier ? b : a;
    _roundTrack = @{@"correct": first[kPartyArtist], @"other": second[kPartyArtist]};
    _promptLabel.text = @"Chi hai ascoltato per primo?";
    _clueLabel.text = [NSString stringWithFormat:@"Confronta %@ e %@ nella tua cronologia.", first[kPartyArtist], second[kPartyArtist]];
    [self showAnswers:@[first[kPartyArtist], second[kPartyArtist]] correct:first[kPartyArtist]];
}

- (void)prepareNextRound {
    SPTPlayerState *state = SGPlayerState();
    NSDictionary *next = state.future.firstObject;
    if (!partyIsPlayerTrack(next)) {
        _promptLabel.text = @"La coda non ha un prossimo brano";
        _clueLabel.text = @"Aggiungi brani alla coda di Spotify per giocare questa modalità.";
        [self showSetupRecovery];
        return;
    }
    NSDictionary *record = partyRecord((SPTPlayerTrack *)next);
    if (!record) { _promptLabel.text = @"Brano non utilizzabile"; _clueLabel.text = @"La traccia in coda non espone i dati necessari."; [self showSetupRecovery]; return; }
    NSArray *tracks = _pool;
    NSMutableArray *choices = [NSMutableArray arrayWithObject:record];
    for (NSDictionary *track in partyShuffle(tracks)) {
        if (![partyTrackKey(track) isEqualToString:partyTrackKey(record)]) [choices addObject:track];
        if (choices.count == 4) break;
    }
    _roundTrack = record;
    _promptLabel.text = @"Che brano arriva dopo?";
    _clueLabel.text = @"Indovina la prossima traccia della coda Spotify.";
    NSMutableArray *labels = [NSMutableArray array];
    for (NSDictionary *choice in choices) [labels addObject:[self trackAnswer:choice]];
    [self showAnswers:labels correct:[self trackAnswer:record]];
}

- (void)prepareLyricsRound:(NSDictionary *)track {
    NSString *identifier = track[kPartyTrackID];
    if (!identifier.length) {
        _promptLabel.text = @"Lyrics non disponibili per questo URI";
        _clueLabel.text = @"Avvia un brano Spotify standard e riprova.";
        [self showSetupRecovery];
        return;
    }
    _lyricTrackID = identifier;
    _lyricLines = SGKaraokeLinesForTrack(identifier);
    if (!_lyricLines) {
        _waitingForLyrics = YES;
        _promptLabel.text = @"Cerco le lyrics…";
        _clueLabel.text = @"La prima richiesta può richiedere qualche secondo.";
        SGKaraokeRequestLyrics(identifier);
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRMusicPartyViewController *self = weakSelf;
            if (!self || !self->_waitingForLyrics || ![self->_lyricTrackID isEqualToString:identifier]) return;
            self->_waitingForLyrics = NO;
            self->_gameStatusLabel.text = @"Le lyrics non sono arrivate: prova un altro brano o modalità.";
            [self showSetupRecovery];
        });
        return;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (SGKaraokeLine *line in _lyricLines) {
        NSString *text = SGKaraokeLineText(line);
        if (text.length > 12 && text.length < 100) [lines addObject:text];
    }
    if (!lines.count) {
        _promptLabel.text = @"Nessun verso utilizzabile";
        _clueLabel.text = @"Per questo brano non sono arrivate lyrics adatte al quiz.";
        [self showSetupRecovery];
        return;
    }
    NSString *line = lines[arc4random_uniform((uint32_t)lines.count)];
    NSArray<NSString *> *words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger wordIndex = words.count > 2 ? arc4random_uniform((uint32_t)words.count) : NSNotFound;
    NSString *missing = wordIndex != NSNotFound
        ? [words[wordIndex] stringByTrimmingCharactersInSet:NSCharacterSet.punctuationCharacterSet]
        : nil;
    NSMutableArray *masked = [words mutableCopy];
    if (missing.length) masked[wordIndex] = @"＿＿＿";
    _roundTrack = @{@"correct": missing ?: line, @"lyric": line};
    _promptLabel.text = @"Completa il verso";
    _clueLabel.text = [NSString stringWithFormat:@"«%@»", [masked componentsJoinedByString:@" "]];
    NSArray *options = missing ? [self wordChoicesCorrect:missing fromLines:lines] : @[line];
    [self showAnswers:options correct:missing ?: line];
}

- (NSArray<NSString *> *)wordChoicesCorrect:(NSString *)word fromLines:(NSArray<NSString *> *)lines {
    NSMutableOrderedSet<NSString *> *options = [NSMutableOrderedSet orderedSetWithObject:word];
    for (NSString *line in partyShuffle(lines)) {
        for (NSString *candidate in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
            NSString *clean = [candidate stringByTrimmingCharactersInSet:NSCharacterSet.punctuationCharacterSet];
            if (clean.length > 3 && [clean caseInsensitiveCompare:word] != NSOrderedSame) [options addObject:clean];
            if (options.count >= 4) break;
        }
        if (options.count >= 4) break;
    }
    return partyShuffle(options.array);
}

- (void)lyricsChanged:(NSNotification *)notification {
    if (!_sessionActive || !_waitingForLyrics || ![notification.object isEqualToString:_lyricTrackID]) return;
    _waitingForLyrics = NO;
    [self prepareLyricsRound:_roundTrack];
}

- (void)prepareAnswersForCurrentRound {
    NSArray<NSDictionary *> *pool = _pool;
    NSMutableArray *alternatives = [NSMutableArray array];
    NSString *correct;
    if (_mode == SGRPartyModeArtist) {
        correct = _roundTrack[kPartyArtist];
        NSMutableSet *seen = [NSMutableSet setWithObject:partyNormalize(correct)];
        for (NSDictionary *track in partyShuffle(pool)) {
            NSString *artist = track[kPartyArtist];
            NSString *key = partyNormalize(artist);
            if (key.length && ![seen containsObject:key]) { [seen addObject:key]; [alternatives addObject:artist]; }
            if (alternatives.count == 3) break;
        }
    } else if (_mode == SGRPartyModeCover) {
        correct = _roundTrack[kPartyAlbum];
        if (![correct length]) {
            _promptLabel.text = @"Nessun album associato";
            _clueLabel.text = @"I dati Spotify non riportano il nome dell'album per questo brano.";
            [self showSetupRecovery];
            return;
        }
        NSMutableSet *seen = [NSMutableSet setWithObject:partyNormalize(correct)];
        for (NSDictionary *track in partyShuffle(pool)) {
            NSString *album = track[kPartyAlbum];
            NSString *key = partyNormalize(album);
            if (key.length && ![seen containsObject:key]) { [seen addObject:key]; [alternatives addObject:album]; }
            if (alternatives.count == 3) break;
        }
    } else {
        correct = [self trackAnswer:_roundTrack];
        NSMutableSet *seen = [NSMutableSet setWithObject:partyTrackKey(_roundTrack)];
        for (NSDictionary *track in partyShuffle(pool)) {
            NSString *key = partyTrackKey(track);
            if (key.length && ![seen containsObject:key]) { [seen addObject:key]; [alternatives addObject:[self trackAnswer:track]]; }
            if (alternatives.count == 3) break;
        }
    }
    if (!correct.length) {
        _promptLabel.text = @"Domanda non disponibile";
        _clueLabel.text = @"Questa traccia non contiene i dati richiesti dalla modalità.";
        [self showSetupRecovery];
        return;
    }
    NSMutableArray *choices = [NSMutableArray arrayWithObject:correct];
    [choices addObjectsFromArray:alternatives];
    if (choices.count < 2) {
        _promptLabel.text = @"Aggiungi altri brani per giocare";
        _clueLabel.text = @"Importa la cronologia Spotify o avvia una coda più ampia.";
        [self showSetupRecovery];
        return;
    }
    _roundTrack = [_roundTrack mutableCopy];
    [(NSMutableDictionary *)_roundTrack setObject:correct forKey:@"correct"];
    [self showAnswers:partyShuffle(choices) correct:correct];
}

- (NSString *)trackAnswer:(NSDictionary *)track {
    return [NSString stringWithFormat:@"%@ — %@", track[kPartyTitle] ?: @"Brano", track[kPartyArtist] ?: @"Artista"];
}

- (void)showAnswers:(NSArray<NSString *> *)choices correct:(NSString *)correct {
    NSMutableArray *records = [NSMutableArray array];
    for (NSString *choice in choices) [records addObject:@{@"label": choice, @"correct": @([choice isEqualToString:correct])}];
    _answerRecords = records;
    if (_mode == SGRPartyModeSong) {
        _answers.hidden = YES;
        _clipButton.hidden = NO;
        UIButtonConfiguration *config = _clipButton.configuration;
        config.title = @"Ascolta 5 secondi";
        _clipButton.configuration = config;
    } else {
        _answers.hidden = NO;
        [self renderAnswerButtons];
    }
}

- (void)showSetupRecovery {
    [_nextButton removeTarget:self action:@selector(nextRound) forControlEvents:UIControlEventTouchUpInside];
    [_nextButton addTarget:self action:@selector(returnToSetup) forControlEvents:UIControlEventTouchUpInside];
    UIButtonConfiguration *config = _nextButton.configuration;
    config.title = @"Torna alla configurazione";
    config.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
    _nextButton.configuration = config;
    _nextButton.hidden = NO;
}

- (void)renderAnswerButtons {
    for (UIView *view in _answers.arrangedSubviews) {
        [_answers removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSUInteger i = 0; i < _answerRecords.count; i++) {
        NSDictionary *record = _answerRecords[i];
        UIButton *answer = [self button:record[@"label"] symbol:@"circle" action:@selector(answerPicked:)];
        answer.tag = i;
        answer.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        answer.titleLabel.numberOfLines = 2;
        answer.accessibilityLabel = [NSString stringWithFormat:@"Risposta %lu: %@", (unsigned long)i + 1, record[@"label"]];
        [_answers addArrangedSubview:answer];
    }
}

- (void)playClip {
    if (_clipActive || _roundAnswered) return;
    id player = SGKaraokePlayer();
    SPTPlayerState *state = SGPlayerState();
    if (![player respondsToSelector:@selector(seekTo:)] || ![player respondsToSelector:@selector(resume:)] ||
        ![player respondsToSelector:@selector(pause:)] || !state.track) {
        _gameStatusLabel.text = @"Non riesco a controllare il player Spotify in questo momento.";
        return;
    }
    _clipTrackURI = partyURIString(state.track.URI);
    _clipRestorePosition = state.positionAsOfTimestamp;
    _clipWasPlaying = state.isPlaying;
    _clipActive = YES;
    _answers.hidden = NO;
    [self renderAnswerButtons];
    for (UIView *view in _answers.arrangedSubviews) ((UIButton *)view).enabled = NO;
    SGKaraokeSeek(0);
    [(id<SPTPlayer>)player resume:nil];
    UIButtonConfiguration *config = _clipButton.configuration;
    config.title = @"Anteprima in riproduzione…";
    _clipButton.configuration = config;
    __weak typeof(self) weakSelf = self;
    _clipTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf finishClip];
    }];
}

- (void)finishClip {
    [_clipTimer invalidate];
    _clipTimer = nil;
    if (!_clipActive) return;
    _clipActive = NO;
    id player = SGKaraokePlayer();
    NSString *uri = partyURIString(SGPlayerState().track.URI);
    if ([_clipTrackURI isEqualToString:uri]) {
        if ([player respondsToSelector:@selector(pause:)]) [(id<SPTPlayer>)player pause:nil];
        SGKaraokeSeek((NSInteger)(_clipRestorePosition * 1000));
        if (_clipWasPlaying && [player respondsToSelector:@selector(resume:)]) [(id<SPTPlayer>)player resume:nil];
    }
    _answers.hidden = NO;
    for (UIView *view in _answers.arrangedSubviews) ((UIButton *)view).enabled = YES;
    UIButtonConfiguration *config = _clipButton.configuration;
    config.title = @"Riascolta 5 secondi";
    _clipButton.configuration = config;
}

- (void)answerPicked:(UIButton *)sender {
    if (_roundAnswered || sender.tag >= _answerRecords.count) return;
    if (_mode == SGRPartyModeSong && _clipActive) [self finishClip];
    _roundAnswered = YES;
    NSDictionary *chosen = _answerRecords[sender.tag];
    BOOL correct = [chosen[@"correct"] boolValue];
    if (correct) {
        if (_teams.selectedSegmentIndex == 2) {
            _playerScores[_activePlayerIndex] = @([_playerScores[_activePlayerIndex] unsignedIntegerValue] + 1);
        } else if (_teams.selectedSegmentIndex == 1 && (_round % 2 == 0)) {
            _scoreTwo++;
        } else {
            _scoreOne++;
        }
    }
    for (NSUInteger i = 0; i < _answers.arrangedSubviews.count; i++) {
        UIButton *button = _answers.arrangedSubviews[i];
        NSDictionary *record = _answerRecords[i];
        UIButtonConfiguration *config = button.configuration;
        config.image = [UIImage systemImageNamed:[record[@"correct"] boolValue] ? @"checkmark.circle.fill" :
                                                        (i == sender.tag ? @"xmark.circle.fill" : @"circle")];
        config.baseBackgroundColor = [record[@"correct"] boolValue]
            ? [UIColor.systemGreenColor colorWithAlphaComponent:0.2]
            : (i == sender.tag ? [UIColor.systemRedColor colorWithAlphaComponent:0.2] : [UIColor colorWithWhite:1 alpha:0.08]);
        button.configuration = config;
        button.enabled = NO;
    }
    NSString *answer = chosen[@"label"];
    NSString *scorer = _teams.selectedSegmentIndex == 2
        ? _playerNames[_activePlayerIndex]
        : (_teams.selectedSegmentIndex == 1
           ? ((_round % 2 == 0) ? @"Squadra B" : @"Squadra A")
           : nil);
    _gameStatusLabel.text = correct
        ? (scorer ? [NSString stringWithFormat:@"Esatto! %@ guadagna un punto.", scorer] : @"Esatto! Hai guadagnato un punto.")
        : (scorer ? [NSString stringWithFormat:@"%@: la risposta era %@.", scorer, answer]
                  : [NSString stringWithFormat:@"La risposta era: %@", answer]);
    [self updateScore];
    _nextButton.hidden = NO;
}

- (void)nextRound {
    if (!_sessionActive) return;
    if (_round >= _roundLimit) { [self finishGame]; return; }
    if (_mode == SGRPartyModeSong || _mode == SGRPartyModeCover || _mode == SGRPartyModeLyrics || _mode == SGRPartyModeNext) {
        id player = SGKaraokePlayer();
        if (![player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
            _gameStatusLabel.text = @"Spotify non espone il comando per passare alla traccia successiva.";
            return;
        }
        [(id<SPTPlayer>)player skipToNextTrackWithOptions:nil];
        _gameStatusLabel.text = @"Carico il prossimo brano dalla coda…";
        _nextButton.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self rebuildPool];
            [self prepareRound];
        });
    } else {
        [self prepareRound];
    }
}

- (void)updateScore {
    _turnLabel.text = [NSString stringWithFormat:@"ROUND %lu / %lu", (unsigned long)_round, (unsigned long)_roundLimit];
    _playerScoreboard.hidden = _teams.selectedSegmentIndex != 2;
    for (UIView *view in _playerScoreboard.arrangedSubviews) {
        [_playerScoreboard removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    if (_teams.selectedSegmentIndex == 2) {
        for (NSUInteger index = 0; index < _playerNames.count; index++) {
            NSString *suffix = index == _activePlayerIndex && _round < _roundLimit ? @"  ·  TURNO" : @"";
            NSString *text = [NSString stringWithFormat:@"%@%@  —  %@ punti",
                              _playerNames[index], suffix, _playerScores[index]];
            UILabel *playerScore = [self label:text size:13 weight:index == _activePlayerIndex ? UIFontWeightSemibold : UIFontWeightRegular
                                                       color:index == _activePlayerIndex ? SGRAccent() : SGRSecondary()];
            [_playerScoreboard addArrangedSubview:playerScore];
        }
    }
    if (_teams.selectedSegmentIndex == 1) {
        _scoreLabel.text = [NSString stringWithFormat:@"A %lu  ·  B %lu", (unsigned long)_scoreOne, (unsigned long)_scoreTwo];
    } else if (_teams.selectedSegmentIndex == 2) {
        _scoreLabel.text = [NSString stringWithFormat:@"%lu giocatori", (unsigned long)_playerNames.count];
    } else {
        _scoreLabel.text = [NSString stringWithFormat:@"%lu punti", (unsigned long)_scoreOne];
    }
}

- (void)finishGame {
    _sessionActive = NO;
    _promptLabel.text = @"Partita terminata!";
    if (_teams.selectedSegmentIndex == 2) {
        NSUInteger highestScore = 0;
        NSMutableArray<NSString *> *winners = [NSMutableArray array];
        for (NSUInteger index = 0; index < _playerScores.count; index++) {
            NSUInteger score = [_playerScores[index] unsignedIntegerValue];
            if (score > highestScore) {
                highestScore = score;
                [winners removeAllObjects];
                [winners addObject:_playerNames[index]];
            } else if (score == highestScore) {
                [winners addObject:_playerNames[index]];
            }
        }
        _clueLabel.text = winners.count == 1
            ? [NSString stringWithFormat:@"%@ vince con %lu punti!", winners.firstObject, (unsigned long)highestScore]
            : [NSString stringWithFormat:@"Pareggio tra %@ con %lu punti.", [winners componentsJoinedByString:@", "], (unsigned long)highestScore];
    } else if (_teams.selectedSegmentIndex == 1) {
        _clueLabel.text = _scoreOne == _scoreTwo
            ? @"Pareggio! Rivincita?"
            : [NSString stringWithFormat:@"%@ vince!", _scoreOne > _scoreTwo ? @"Squadra A" : @"Squadra B"];
    } else {
        _clueLabel.text = [NSString stringWithFormat:@"Hai totalizzato %lu punti su 10.", (unsigned long)_scoreOne];
    }
    _clipButton.hidden = YES;
    _nextButton.hidden = YES;
    UIButton *again = [self button:@"Nuova partita" symbol:@"arrow.counterclockwise" action:@selector(returnToSetup)];
    [_answers addArrangedSubview:again];
}

- (void)returnToSetup {
    for (UIView *view in _answers.arrangedSubviews) {
        [_answers removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    _gameView.hidden = YES;
    _setupView.hidden = NO;
    _sessionActive = NO;
    [self rebuildPool];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playerStateDidChange:state]; });
        return;
    }
    if (!_sessionActive) {
        [self rebuildPool];
        return;
    }
    if (_clipActive && ![partyURIString(state.track.URI) isEqualToString:_clipTrackURI]) {
        [self finishClip];
    }
}

- (void)close {
    if (_clipActive) [self finishClip];
    _sessionActive = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [_clipTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end

static UIViewController *partyControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

void SGRMusicPartyPresentFrom(UIView *source) {
    UIViewController *owner = partyControllerForView(source);
    if (!owner) {
        SGLog(@"music party: could not find the Library's view controller");
        return;
    }
    if ([owner.presentedViewController isKindOfClass:SGRMusicPartyViewController.class]) return;
    [owner presentViewController:[SGRMusicPartyViewController new] animated:YES completion:nil];
}
