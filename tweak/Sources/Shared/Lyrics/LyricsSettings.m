// The Lyrics page's parts; App/Pages.m assembles the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Lyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyricsVideo.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Shared/LyricsSources/LyricsSources.h"

SGModSection *SGLyricsSourcesSection(BOOL namingSource) {
    SGModRow *sources = SGPageRow(@"Sources", ^UIViewController *{ return SGLyricsSourcesPage(); });
    sources.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in SGLyricsOrder()) [names addObject:SGLyricsProviderFor(key).name];
        return names.count ? [names componentsJoinedByString:@", "] : @"Off";
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:sources,
        SGOptionRow(@"Lyrics for every track", @"Even where Spotify has none", SGKeyLyricsAllTracks), nil];
    if (namingSource) [rows addObject:SGOptionRow(@"Show source", nil, SGKeyLyricsCredit)];
    if (!SGLyricsEeveeReplaces()) return SGSection(@"Sources", rows);
    return SGNotedSection(@"Sources", rows, @"EeveeSpotify is replacing lyrics, so these sources stay off. To use them, "
                          "turn on Do Not Replace Lyrics in EeveeSpotify's lyrics settings and restart Spotify.");
}

SGModRow *SGLockScreenLyricsRow(void) {
    return SGOptionRow(@"Lock screen lyrics", @"Current line in place of the artist", SGKeyLockScreenLyrics);
}

SGModRow *SGLockScreenLyricsArtworkRow(void) {
    SGModRow *row = SGOptionRow(@"Lyrics as lock screen artwork",
        @"Tap the lock-screen star to replace Canvas or the cover with synced lyrics. Requires iOS 26 and a Spotify restart; the star replaces Like/dislike while enabled.",
        SGKeyLockScreenLyricsArtwork);
    row.visible = ^BOOL{ return SGAnimatedArtworkAvailable(); };
    return row;
}

static NSInteger selectedLockScreenLyricsStyle(void) {
    NSInteger style = SGInt(SGKeyLockScreenLyricsArtworkStyle, SGLockScreenLyricsArtworkStyleDefault);
    return style >= SGLockScreenLyricsArtworkStyleDefault && style <= SGLockScreenLyricsArtworkStyleBlueprint
        ? style : SGLockScreenLyricsArtworkStyleDefault;
}

static NSString *lockScreenLyricsStyleName(NSInteger style) {
    switch (style) {
        case SGLockScreenLyricsArtworkStyleWordCollage: return @"Word collage";
        case SGLockScreenLyricsArtworkStyleEditorial: return @"Editorial";
        case SGLockScreenLyricsArtworkStyleReceipt: return @"Receipt";
        case SGLockScreenLyricsArtworkStyleSocialPost: return @"Social post";
        case SGLockScreenLyricsArtworkStyleRetroTV: return @"Retro TV";
        case SGLockScreenLyricsArtworkStyleNeon: return @"Neon";
        case SGLockScreenLyricsArtworkStyleVHS: return @"VHS";
        case SGLockScreenLyricsArtworkStyleBlueprint: return @"Blueprint";
        default: return @"Default";
    }
}

static UIViewController *lockScreenLyricsStylePage(void);

SGModRow *SGLockScreenLyricsArtworkStyleRow(void) {
    SGModRow *row = SGPageRow(@"Style", ^UIViewController *{ return lockScreenLyricsStylePage(); });
    row.subtitle = @"Choose how synced lyrics look on the Lock Screen";
    row.value = ^NSString *{ return lockScreenLyricsStyleName(selectedLockScreenLyricsStyle()); };
    row.visible = ^BOOL{
        return SGHidden(SGKeyLockScreenLyricsArtwork) && SGAnimatedArtworkAvailable();
    };
    return row;
}

@interface SGLockScreenLyricsStylePreviewView : UIView
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *eyebrowLabel;
@property (nonatomic, strong) UILabel *styleLabel;
@property (nonatomic, strong) UILabel *descriptionLabel;
@end

@implementation SGLockScreenLyricsStylePreviewView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _artworkView = [UIImageView new];
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.clipsToBounds = YES;
    _artworkView.layer.cornerRadius = 14;
    _artworkView.layer.borderWidth = 1;
    _artworkView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    _artworkView.accessibilityLabel = @"Preview of lyrics lock-screen artwork";
    [self addSubview:_artworkView];

    _eyebrowLabel = [UILabel new];
    _eyebrowLabel.text = @"PREVIEW";
    _eyebrowLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _eyebrowLabel.textColor = [UIColor secondaryLabelColor];
    [self addSubview:_eyebrowLabel];

    _styleLabel = [UILabel new];
    _styleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _styleLabel.textColor = UIColor.labelColor;
    [self addSubview:_styleLabel];

    _descriptionLabel = [UILabel new];
    _descriptionLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _descriptionLabel.textColor = [UIColor secondaryLabelColor];
    _descriptionLabel.numberOfLines = 0;
    _descriptionLabel.text = @"A sample of how synced lyrics will look on the Lock Screen.";
    [self addSubview:_descriptionLabel];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updatePreview)
                                               name:SGLockScreenLyricsArtworkStyleDidChangeNotification object:nil];
    [self updatePreview];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = 16;
    CGFloat posterHeight = MIN(self.bounds.size.height - inset * 2, 152);
    CGFloat posterWidth = posterHeight * 3.0 / 4.0;
    self.artworkView.frame = CGRectMake(inset, (self.bounds.size.height - posterHeight) / 2,
                                        posterWidth, posterHeight);
    CGFloat textX = CGRectGetMaxX(self.artworkView.frame) + 16;
    CGFloat textWidth = MAX(0, self.bounds.size.width - textX - inset);
    self.eyebrowLabel.frame = CGRectMake(textX, 31, textWidth, 16);
    self.styleLabel.frame = CGRectMake(textX, 53, textWidth, 24);
    self.descriptionLabel.frame = CGRectMake(textX, 83, textWidth, 54);
}

- (void)updatePreview {
    NSInteger selected = selectedLockScreenLyricsStyle();
    self.styleLabel.text = lockScreenLyricsStyleName(selected);
    self.artworkView.image = SGLockScreenLyricsStylePreviewFrame(selected, CGSizeMake(240, 320));
}
@end

static UIViewController *lockScreenLyricsStylePage(void) {
    NSArray<NSString *> *styles = @[@"Default", @"Word collage", @"Editorial", @"Receipt", @"Social post", @"Retro TV",
                                    @"Neon", @"VHS", @"Blueprint"];
    NSArray<NSString *> *notes = @[
        @"Centered lyrics over a softly blurred album cover.",
        @"Colored word tiles over the album cover.",
        @"Serif lyrics with an editorial artist and track heading.",
        @"Monospaced lyrics on a warm paper receipt.",
        @"A social-feed post highlighting the current lyric.",
        @"A glowing CRT television with retro RGB lyrics.",
        @"Bright neon lettering with colored glow over a night-darkened cover.",
        @"Camcorder playback graphics, scanlines and cinematic subtitles.",
        @"A technical lyric card with cyan grid lines and precise typography.",
    ];
    SGModRow *preview = SGViewRow([[SGLockScreenLyricsStylePreviewView alloc] initWithFrame:CGRectZero], 184);
    NSArray<SGModRow *> *choices = SGChoiceListRows(SGKeyLockScreenLyricsArtworkStyle, styles, notes,
        SGLockScreenLyricsArtworkStyleDefault, ^(NSInteger index) { SGLockScreenLyricsArtworkStyleDidChange(); });
    return [[SGModPage alloc] initWithTitle:@"Style" intro:nil
        sections:@[SGSection(nil, @[preview]), SGSection(@"Available styles", choices)]
        footer:@"The preview uses sample lyrics. The album cover appears behind lyrics; the original Canvas returns when lyrics are hidden."];
}

SGModRow *SGLyricsTranslationLanguageRow(void) {
    SGModRow *row = SGChoiceRow(@"Translation language", nil, SGKeyLyricsTranslationLanguage, SGLyricsTranslationLanguageNames(), 0);
    row.choiceFooter = @"Used when the lyrics come with translations. Any shows the first.";
    return row;
}

// Only the redesign's lyrics view sweeps words.
SGModRow *SGLyricsWordTimingRow(void) {
    return SGOptionRow(@"Simulate word timing", nil, SGKeyLyricsSimulateWords);
}
