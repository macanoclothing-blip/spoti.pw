// Player redesign: the lyrics come to the player itself, the way the Music app shows them. The player
// is one screen and does not scroll (PlayerScroll.x), so the footer's lyrics glyph is the only way to
// them: it shrinks the cover into a thumbnail at the top of the artwork band, lifts the track's title
// up beside it, and fades the Apple Music style lines (Redesigned/Lyrics/SGRKaraokeView.h) into the
// room that frees between the title and the progress bar. Tapping it again, or the thumbnail, puts the
// cover back. Over a clip (PlayerAnimated.x), where the player shows no cover, the thumbnail comes up and
// goes where it sits instead.
//
// Nothing of Spotify's is taken apart for it. The cover is the Kit's now playing artwork drawn again
// in a view of the redesign's own, flown from where Spotify's cover is drawn to where the thumbnail
// belongs, while Spotify's list of covers goes to alpha 0 underneath: one view to move instead of a
// paging list of them, and the two pictures are the same one, so the swap is not seen. The title row
// is Spotify's own unit translated, the way PlayerFooter.x moves the footer's controls -- a transform
// survives the stack view laying its arranged views out again -- with a mask over it where the controls
// it moved towards begin, so a long title fades out before them instead of running under them. The row
// of chips over it (Switch to video) goes while the lines are up, since they take the room it sits in.
//
// Tree (trees/clean/player/01.txt): SPTNowPlayingView (:26) holds the content layers, the header row
// (:91), and id=npv.bottomStackView {0, 576.67, 402, 236} (:127) whose arranged views are the
// information unit {0, 0, 402, 64} (:160, the title, the artist and the add button), the duration unit
// {0, 64, 402, 40} (:209), the controls (:240) and the footer (:295). The title is
// id=now-playing-title-label and the artist id=now-playing-subtitle-label (:174, :185), both inside one
// arranged element view {12, 2.33, 304, 43.33} of the unit's row. Every measurement here is taken from
// the views themselves, since a player with a volume row or another mode's units has other numbers.
//
// The geometry is re-applied on every layout pass of the units, since a new track rebuilds the
// elements inside them, and it is undone before the player closes: the bar morphs back into a full
// size cover, which a thumbnail would not match.
//
// In portrait, with the lines up and the song playing, the controls go after a few seconds untouched
// and the lines have the player to themselves, the way the Music app leaves its lyrics alone: the header row, the
// thumbnail and the bottom stack (the lifted title row with it) fade out, and the lines' room grows
// from the band between the title row and the progress bar to the whole height of the player. The
// lines' view is laid over all of that room from the start and only its band moves
// (SGRKaraokeView's lineInsets), so the lines spring to the new anchor as they move on to a new line,
// rather than riding a view resized under them. A touch anywhere on the player brings the controls
// back, and a tap that does so does only that: it does not seek to the line under it. Pausing brings
// them back as well, and they stay while the song is paused. VoiceOver keeps them.
//
// With Sing available (Shared/Sing: switched on in Mod Settings > Karaoke, its voice model downloaded), its
// microphone (Redesigned/Lyrics/SGRSingControl.h) sits in the bottom trailing corner of the lines' band,
// opposite their own glass button, and goes down with the band when the controls go. While it is open,
// preparing or explaining itself the controls do not go, but ones that are away already stay away: a
// touch on the microphone is for it and brings nothing back, since the band it sits in would move it out
// from under the finger. The lines open with Sing available even for a song without lyrics, so the
// microphone can always be reached; switched off, or without its model, there is no microphone and a song
// without lyrics keeps its cover. Both follow the switch and the model as they change.
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#import "Redesigned/Lyrics/SGRSingControl.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Sing/SGSingController.h"
#import "Player.h"
#import "PlayerVinyl.h"
#import "PlayerOrientation.h"

static const CGFloat kThumbSide = 72;          // the portrait thumbnail once the lyrics are up
static const CGFloat kThumbGap = 16;           // between the thumbnail and the title beside it
static const CGFloat kTitleGap = 12;           // between the title and the controls at the trailing edge
static const CGFloat kTitleFade = 20;          // over how much of its end a title too long to fit fades out
static const CGFloat kThumbTop = 8;            // below the top of the artwork band
static const CGFloat kLyricsTop = 20;          // between the title row and the first line
static const CGFloat kLyricsBottom = 8;        // above the progress bar
static const CGFloat kRotateButtonSide = 44, kRotateButtonGap = 8;
static const CGFloat kLandscapeTransportScale = 0.78;
static const CGFloat kLandscapeProgressWidthScale = 0.58;
static const CGFloat kLandscapeProgressHeightScale = 0.76;
// The lines are a surface arriving, not something moving: they come up from just under full size as the
// room for them opens, and go at once when it closes. An exit the eye waits through reads as a stall.
static const CGFloat kLyricsEnterScale = 0.96;
static const NSTimeInterval kLyricsIn = 0.3, kLyricsInDelay = 0.12, kLyricsOut = 0.16;
// A track that changes while the lines are up has this long to bring its own before they are put away.
static const NSTimeInterval kLyricsGrace = 3;
// Below this the player has not laid out yet and nothing can be measured from it.
static const CGFloat kLivingHeight = 200;
// In portrait, the lines alone: this long untouched while they play, and the controls go. They go
// slowly, being nothing the eye waits for, and come back quickly, since a touch asked for them.
static const NSTimeInterval kAloneAfter = 4;
static const NSTimeInterval kAloneOut = 0.6, kAloneBack = 0.3;
// Lighter than the Kit's glyph buttons: a picture dimmed to half reads as gone, not pressed.
static const CGFloat kThumbPressScale = 0.94, kThumbPressAlpha = 0.8;
// Over a clip the thumbnail grows in from this in its place, and shrinks back to it going.
static const CGFloat kThumbAppearScale = 0.8;

static char kOverlayKey, kPlateKey, kTitleKey, kWatcherKey, kRotateGlassKey;
static char kLandscapeDurationFrameKey, kLandscapeControlsFrameKey;
static char kLandscapeDurationMovedKey, kLandscapeControlsMovedKey;
static char kLandscapeSliderFrameKey, kLandscapeTakenFrameKey, kLandscapeRemainingFrameKey;
static char kLandscapeShuffleFrameKey, kLandscapePreviousFrameKey, kLandscapePlayFrameKey;
static char kLandscapeNextFrameKey, kLandscapeRepeatFrameKey;
static char kLandscapeTitleActionFrameKey, kLandscapeTitleActionsKey;
static char kLandscapeSliderKey, kLandscapeTakenKey, kLandscapeRemainingKey;
static char kLandscapeShuffleKey, kLandscapePreviousKey, kLandscapePlayKey;
static char kLandscapeNextKey, kLandscapeRepeatKey, kLandscapeReachKey;
static BOOL sg_open;
static BOOL sg_moving;                      // the transition is in flight, so no layout pass may re-place it
static BOOL sg_alone;                       // the controls are away and the lines have the player
static BOOL sg_tapBroughtBack;              // the touch going on began with them away, so its tap seeks nowhere
static NSTimer *sg_aloneTimer;
static BOOL sg_singHeld;                    // Sing's microphone is open, preparing or explaining itself
static __weak UIView *sg_sing;              // the microphone, when Sing is on
static __weak UIView *sg_host;              // SPTNowPlayingView
static __weak UIViewController *sg_player;  // its controller
static __weak UIViewController *sg_header, *sg_info, *sg_duration, *sg_controls, *sg_footer, *sg_floating;
static __weak UIView *sg_titleElement;      // the arranged element view holding the title and the artist

static void replace(void);

static BOOL playerIsLandscape(void) {
    UIView *host = sg_host;
    return host && host.bounds.size.width > host.bounds.size.height;
}

static void syncLandscapeFooter(void) {
    UIView *footer = sg_footer.viewIfLoaded;
    if (!footer) return;
    // The landscape lyrics composition uses the lower edge for its translation and meaning controls.
    CGFloat alpha = sg_open && playerIsLandscape() ? 0 : 1;
    if (fabs(footer.alpha - alpha) > 0.01) footer.alpha = alpha;
    footer.userInteractionEnabled = alpha > 0.01;
    footer.accessibilityElementsHidden = alpha < 0.01;
}

#pragma mark - the overlay

// The thumbnail puts the cover back when tapped, the way the Music app's small artwork does. Its own
// transform is the flight, so the press goes on the face inside it.
@interface SGRPlayerLyricsThumb : UIControl
@property (nonatomic, readonly) UIView *face;        // the cover and its shadow
@end

@implementation SGRPlayerLyricsThumb {
    UIView *_face;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _face = [[UIView alloc] initWithFrame:self.bounds];
    _face.userInteractionEnabled = NO;
    [self addSubview:_face];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Hide lyrics";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (UIView *)face { return _face; }

- (void)tapped {
    SGLog(@"redesign player: the thumbnail tapped, the cover goes back");
    SGRPlayerToggleLyrics();
}

// VoiceOver's double tap, which reaches a UIControl of one's own no other way.
- (BOOL)accessibilityActivate {
    [self tapped];
    return YES;
}

// Only while it sits there with the controls: in flight, or faded out with them, a touch is not for it.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return sg_open && !sg_alone && !sg_moving && [super pointInside:point withEvent:event];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    UIView *face = _face;
    SGRAnimate(SGRMotionPress, ^{
        face.alpha = highlighted ? kThumbPressAlpha : 1;
        face.transform = highlighted ? CGAffineTransformMakeScale(kThumbPressScale, kThumbPressScale) : CGAffineTransformIdentity;
    }, nil);
}

@end

// The thumbnail and the lines, side by side under one view so the lines' own view has no sibling of
// ours to hide: SGRKaraokeView takes the whole of whatever it is put in and dims what is next to it.
@interface SGRPlayerLyricsOverlay : UIView
@property (nonatomic, readonly) SGRPlayerLyricsThumb *thumb;   // the cover, at full size, moved by its transform
@property (nonatomic, readonly) UIImageView *cover;
@property (nonatomic, readonly) UIView *stage;       // holds the lines' view alone
@property (nonatomic, readonly) UILabel *empty;      // Sing's "no lyrics"
@property (nonatomic, readonly) SGRKaraokeView *lyrics;
@property (nonatomic, readonly) SGRGlyphButton *rotate;
@end

@implementation SGRPlayerLyricsOverlay {
    SGRPlayerLyricsThumb *_thumb;
    UIView *_stage;
    UIImageView *_cover;
    UILabel *_empty;
    SGRKaraokeView *_lyrics;
    SGRGlyphButton *_rotate;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _thumb = [[SGRPlayerLyricsThumb alloc] initWithFrame:CGRectZero];
    _cover = [[UIImageView alloc] initWithFrame:CGRectZero];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_thumb.face addSubview:_cover];
    _stage = [[UIView alloc] initWithFrame:CGRectZero];
    // What the lines leave when a song has none, which only Sing opens them for. A sibling of the lines'
    // view, so it goes whenever they have something to show (SGRKaraokeView's syncSiblings).
    _empty = [UILabel new];
    _empty.text = @"Lyrics aren't available for this song.";
    _empty.textColor = SGRSecondary();
    _empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _empty.adjustsFontForContentSizeCategory = YES;
    _empty.textAlignment = NSTextAlignmentCenter;
    _empty.numberOfLines = 0;
    [_stage addSubview:_empty];
    [self addSubview:_stage];
    [self addSubview:_thumb];
    _rotate = [SGRGlyphButton buttonWithSymbol:@"rotate.left" pointSize:20 title:@"Rotate screen"];
    _rotate.accessibilityLabel = @"Rotate screen";
    _rotate.onTap = ^{ SGRPlayerToggleOrientation(); };
    [self addSubview:_rotate];
    return self;
}

- (SGRPlayerLyricsThumb *)thumb { return _thumb; }
- (UIImageView *)cover { return _cover; }
- (UIView *)stage { return _stage; }
- (UILabel *)empty { return _empty; }
- (SGRGlyphButton *)rotate { return _rotate; }

// The lines seek when they are tapped and the thumbnail puts the cover back, so everywhere else the
// overlay would only swallow touches: a view that takes touches does, even with nothing on it.
//
// What it hands them to instead is the title row. Translated to the top of the player it is drawn well
// outside the stack view it is arranged in, and UIKit stops looking at a view whose bounds the touch is
// not in, so the add button and the menu that rode up with it are past Spotify's own reach. Asked here
// directly, the row answers for where it is drawn.
//
// The stage is as tall as the lines' room with the controls away, and the lines take touches only in
// the part they have now, so the stage swallows none either. With the controls away the row is not
// there to be asked: a touch goes on to the player, whose watcher brings them back.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (sg_sing && sg_sing.alpha > 0.01 && sg_sing.superview == self) {
        CGPoint singPoint = [sg_sing convertPoint:point fromView:self];
        UIView *singHit = [sg_sing hitTest:singPoint withEvent:event];
        if (singHit) return singHit;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != self && hit != _stage) return hit;
    UIView *row = SGRPlayerLyricsOpen() && !sg_alone ? sg_info.viewIfLoaded : nil;
    UIView *inRow = row ? [row hitTest:[row convertPoint:point fromView:self] withEvent:event] : nil;
    return inRow == row ? nil : inRow;
}

// Made on the first tap and kept afterwards: it measures the song for its width before it can place a
// line, so a view built again on every tap would show nothing for the first frames. Out of the window
// it costs nothing -- its display link only runs while it is in one.
- (SGRKaraokeView *)lyrics {
    if (!_lyrics) {
        _lyrics = [[SGRKaraokeView alloc] initWithFrame:_stage.bounds];
        _lyrics.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _lyrics.takesTap = ^BOOL { return !sg_tapBroughtBack; };
    }
    if (_lyrics.superview != _stage) [_stage addSubview:_lyrics];
    _lyrics.frame = _stage.bounds;
    return _lyrics;
}

@end

static SGRPlayerLyricsOverlay *overlayIn(UIView *host) {
    SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(host, &kOverlayKey);
    if (!overlay) {
        overlay = [[SGRPlayerLyricsOverlay alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // On top of the player: it reaches from under the header row down to the progress bar, so it is over
    // the covers and the gradients and clear of every control. Under them instead, the mixing background
    // Spotify keeps between the two (01.txt:72) would be free to draw over the lines.
    if (overlay.superview != host) [host addSubview:overlay];
    return overlay;
}

#pragma mark - the measurements

typedef struct {
    BOOL ok;
    CGRect cover;     // where the redesign's cover starts: the large landscape cover, or Spotify's in portrait
    CGRect thumb;     // where it goes
    CGRect stage;     // where the lines go
    CGRect room;      // where they go with the controls away, which is the stage's frame throughout
    CGRect rotate;    // the orientation control, outside the lyric lines' reading area
    CGRect duration;  // landscape: progress row in the left column
    CGRect controls;  // landscape: transport row in the left column
    CGFloat lift;     // how far the title row rises
    CGFloat shift;    // how far the title slides right to clear the thumbnail, 0 when it sits under it
    CGFloat baseShift; // the title sits to the right of the large cover before lyrics open
    CGFloat titleMaxWidth;
} SGRLyricsLayout;

// What a view's frame would be with the translation this file put on it left out.
static CGRect untransformed(UIView *view, UIView *host) {
    CGRect frame = SGFrameIn(view, host);
    CGAffineTransform t = view.transform;
    return CGRectOffset(frame, -t.tx, -t.ty);
}

static SGRLyricsLayout layoutIn(UIView *host) {
    SGRLyricsLayout l = {0};
    UIView *info = sg_info.viewIfLoaded, *duration = sg_duration.viewIfLoaded, *title = sg_titleElement;
    if (!host || host.bounds.size.height < kLivingHeight || !info || !duration) return l;
    CGRect area = SGRPlayerArtworkAreaIn(host), cover = SGRPlayerCoverFrameIn(host);
    BOOL landscape = host.bounds.size.width > host.bounds.size.height;
    // Spotify's cover band can be a zero-sized/off-screen view after the player rotates. The player
    // itself is the reliable canvas in that case; lyrics and the stand-in cover must still be usable.
    if (landscape && (CGRectIsNull(area) || CGRectIsEmpty(area) || area.size.width < host.bounds.size.width * 0.6)) {
        area = host.bounds;
    }
    if (CGRectIsNull(area) || CGRectIsEmpty(area) || (!landscape && (CGRectIsNull(cover) || CGRectIsEmpty(cover)))) return l;
    CGRect row = untransformed(info, host), bar = untransformed(duration, host);
    UIEdgeInsets safe = host.window.safeAreaInsets;
    if (landscape) {
        UIView *header = sg_header.viewIfLoaded;
        CGFloat headerBottom = header ? CGRectGetMaxY(SGFrameIn(header, host)) : safe.top;
        CGFloat contentTop = MAX(safe.top + 8, headerBottom + 4);
        CGFloat contentBottom = host.bounds.size.height - safe.bottom - kLyricsBottom;
        CGFloat contentHeight = contentBottom - contentTop;
        // Keep a real left hand player column. Spotify's full width transport unit is never scaled:
        // scaling the unit also scales its text, slider and hit targets into the narrow column.
        CGFloat leftWidth = floor(area.size.width * 0.42);
        UIView *controlsView = sg_controls.viewIfLoaded;
        CGRect controlsOriginal = controlsView ? untransformed(controlsView, host) : CGRectZero;
        CGFloat controlsHeight = controlsOriginal.size.height > 0 ? MIN(60, controlsOriginal.size.height) : 56;
        CGFloat durationHeight = MIN(40, MAX(24, bar.size.height));
        CGFloat left = CGRectGetMinX(area) + SGRSideMargin;
        CGFloat controlsWidth = MAX(0, leftWidth - 2 * SGRSideMargin);
        CGFloat leftContentHeight = contentHeight - row.size.height - durationHeight - controlsHeight - 24;
        CGFloat side = MIN(140, MIN(controlsWidth - 12, leftContentHeight));
        if (side < kThumbSide) {
            // Keep a workable lyric column on compact landscape heights rather than rejecting the tap.
            side = MIN(kThumbSide, MIN(controlsWidth, MAX(64, contentHeight - row.size.height - durationHeight - controlsHeight - 16)));
        }
        if (side < 64 || controlsWidth < 64 || contentHeight < 120) return l;
        CGFloat top = contentTop;
        CGFloat sourceSide = MIN(150, MIN(controlsWidth, CGRectGetMinY(bar) - top - 8));
        sourceSide = MAX(side, sourceSide);
        l.cover = CGRectMake(left, top, sourceSide, sourceSide);
        l.thumb = CGRectMake(left, top, side, side);
        l.lift = CGRectGetMaxY(l.thumb) + 12 - CGRectGetMinY(row);
        l.titleMaxWidth = controlsWidth;
        CGRect sourceTitle = title ? untransformed(title, host) : row;
        l.baseShift = MAX(0, CGRectGetMaxX(l.cover) + kThumbGap - CGRectGetMinX(sourceTitle));
        l.shift = left - CGRectGetMinX(sourceTitle);
        l.duration = CGRectMake(left, CGRectGetMaxY(l.thumb) + 12 + row.size.height + 4,
                                controlsWidth, durationHeight);
        l.controls = CGRectMake(left, CGRectGetMaxY(l.duration) + 8, controlsWidth, controlsHeight);
        CGFloat column = CGRectGetMinX(area) + leftWidth + SGRGrid;
        l.stage = CGRectMake(column, contentTop, CGRectGetMaxX(area) - column, contentHeight);
        l.rotate = CGRectMake(CGRectGetMaxX(area) - kRotateButtonSide - kRotateButtonGap,
                              contentTop, kRotateButtonSide, kRotateButtonSide);
        CGFloat roomTop = MIN(header ? CGRectGetMinY(SGFrameIn(header, host)) : safe.top, CGRectGetMinY(l.stage));
        CGFloat roomBottom = MAX(host.bounds.size.height - safe.bottom, CGRectGetMaxY(l.stage));
        l.room = CGRectMake(column, roomTop, l.stage.size.width, roomBottom - roomTop);
        l.ok = l.titleMaxWidth >= 64 && l.stage.size.width > 140 && l.stage.size.height >= 64;
        return l;
    }
    // The thumbnail takes the title's own leading edge, so the two line up down the page.
    CGFloat leading = title ? CGRectGetMinX(untransformed(title, host)) : CGRectGetMinX(area) + SGRSideMargin;
    l.cover = cover;
    l.thumb = CGRectMake(leading, CGRectGetMinY(area) + kThumbTop, kThumbSide, kThumbSide);
    // Beside the thumbnail when the title can be moved clear of it, under it when it cannot be found.
    CGFloat top = title ? CGRectGetMidY(l.thumb) - row.size.height / 2 : CGRectGetMaxY(l.thumb) + SGRGrid;
    l.lift = top - CGRectGetMinY(row);
    l.shift = title ? kThumbSide + kThumbGap : 0;
    CGFloat lines = MAX(CGRectGetMaxY(l.thumb), top + row.size.height) + kLyricsTop;
    l.rotate = CGRectMake(CGRectGetMaxX(area) - kRotateButtonSide - kRotateButtonGap,
                          lines, kRotateButtonSide, kRotateButtonSide);
    CGFloat stageTop = lines + kRotateButtonSide + kRotateButtonGap;
    l.stage = CGRectMake(CGRectGetMinX(area), stageTop, area.size.width, CGRectGetMinY(bar) - kLyricsBottom - stageTop);
    // With the controls away: from the header row's top, just under the status bar, down to the home
    // indicator. The lines fade out at both ends, so nothing needs clearing beyond that.
    UIView *header = sg_header.viewIfLoaded;
    CGFloat roomTop = MIN(header ? CGRectGetMinY(SGFrameIn(header, host)) : safe.top, CGRectGetMinY(l.stage));
    CGFloat roomBottom = MAX(host.bounds.size.height - safe.bottom, CGRectGetMaxY(l.stage));
    l.room = CGRectMake(CGRectGetMinX(area), roomTop, area.size.width, roomBottom - roomTop);
    l.ok = l.stage.size.height > kLivingHeight / 2 && l.lift < 0;
    return l;
}

// The lines' part of the stage: the band between the title row and the progress bar while the
// controls are there, all of it while they are away.
static UIEdgeInsets bandOf(SGRLyricsLayout l, BOOL alone) {
    if (alone) return UIEdgeInsetsZero;
    return UIEdgeInsetsMake(CGRectGetMinY(l.stage) - CGRectGetMinY(l.room), 0, CGRectGetMaxY(l.room) - CGRectGetMaxY(l.stage), 0);
}

#pragma mark - the title row

// Where the row's trailing controls start, in the unit's coordinates: the nearest arranged view on the
// trailing side of the title that is still there to be seen. The title may not reach it.
static CGFloat trailingEdgeIn(UIView *info) {
    UIView *title = sg_titleElement, *row = title.superview;
    if (!title || !row) return CGFLOAT_MAX;
    CGFloat titleLeft = CGRectGetMinX(untransformed(title, info));
    CGFloat limit = CGRectGetMaxX(SGFrameIn(row, info));
    for (UIView *view in row.subviews) {
        if (view == title || view.hidden || view.alpha < 0.01 || view.bounds.size.width < 1) continue;
        CGFloat x = CGRectGetMinX(SGFrameIn(view, info));
        if (x > titleLeft && x < limit) limit = x;
    }
    return limit;
}

// The title moved right by the thumbnail would run into the add button beside it, and it cannot simply
// be narrowed: Spotify lays its marquee labels out with constraints, which put the width back the next
// time anything in the row lays out -- and a long title, being a marquee, lays out often. A mask on the
// element takes no part in that, so it holds between passes, and it fades the title out where Spotify's
// own fade would have been rather than cutting it.
static void clipTitle(UIView *element, CGFloat width) {
    CGRect bounds = element.bounds;
    if (width >= bounds.size.width - 0.5 || bounds.size.height < 1) {
        element.layer.mask = nil;
        return;
    }
    CAGradientLayer *mask = [element.layer.mask isKindOfClass:CAGradientLayer.class] ? (CAGradientLayer *)element.layer.mask : nil;
    if (!mask) {
        mask = [CAGradientLayer layer];
        mask.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
        mask.startPoint = CGPointMake(0, 0.5);
        mask.endPoint = CGPointMake(1, 0.5);
        element.layer.mask = mask;
    }
    CGFloat fade = MIN(kTitleFade, width);
    CGRect frame = CGRectMake(0, 0, MAX(0, width), bounds.size.height);
    if (CGRectEqualToRect(frame, mask.frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = frame;
    mask.locations = @[@0, @(width > 0 ? (width - fade) / width : 0), @1];
    [CATransaction commit];
}

// The unit's row lays its arranged views out after the unit's own pass, so the transforms go on after it.
static CGRect baselineFrameForUnit(UIView *unit, UIView *host, const void *key) {
    if (!unit || !host) return CGRectZero;
    NSValue *saved = objc_getAssociatedObject(unit, key);
    if (saved) return saved.CGRectValue;
    CGRect frame = SGFrameIn(unit, host);
    objc_setAssociatedObject(unit, key, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return frame;
}

static void captureUnitFrame(UIView *unit, UIView *host, const void *key) {
    if (!unit || !host || objc_getAssociatedObject(unit, key) || !CGAffineTransformIsIdentity(unit.transform)) return;
    CGRect frame = SGFrameIn(unit, host);
    objc_setAssociatedObject(unit, key, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void restoreUnitFrame(UIView *unit, UIView *host, const void *frameKey, const void *movedKey) {
    if (!unit || !host || ![objc_getAssociatedObject(unit, movedKey) boolValue]) return;
    CGRect frame = baselineFrameForUnit(unit, host, frameKey);
    unit.transform = CGAffineTransformIdentity;
    unit.center = [unit.superview convertPoint:CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)) fromView:host];
    objc_setAssociatedObject(unit, movedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(unit, frameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The stack still owns these arranged units, so keep their original size and move their centre. Their
// contents are laid out at native size inside the left column below; a scale transform here made the
// slider, labels, controls and their touch areas all collapse together.
static void moveUnit(UIView *unit, UIView *host, CGPoint origin, const void *frameKey, const void *movedKey) {
    if (!unit || !host) return;
    CGRect source = baselineFrameForUnit(unit, host, frameKey);
    if (CGRectIsEmpty(source)) return;
    unit.transform = CGAffineTransformIdentity;
    unit.center = [unit.superview convertPoint:CGPointMake(origin.x + source.size.width / 2,
                                                            origin.y + source.size.height / 2) fromView:host];
    objc_setAssociatedObject(unit, movedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGRect savedChildFrame(UIView *view, const void *key) {
    NSValue *saved = objc_getAssociatedObject(view, key);
    if (saved) return saved.CGRectValue;
    CGRect frame = view.frame;
    objc_setAssociatedObject(view, key, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return frame;
}

static void restoreChildFrame(UIView *view, const void *key) {
    if (!view) return;
    NSValue *saved = objc_getAssociatedObject(view, key);
    if (!saved) return;
    view.transform = CGAffineTransformIdentity;
    view.frame = saved.CGRectValue;
    objc_setAssociatedObject(view, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void setFrameIn(UIView *view, UIView *coordinateView, CGRect frame) {
    if (!view || !coordinateView || !view.superview) return;
    view.transform = CGAffineTransformIdentity;
    view.frame = [coordinateView convertRect:frame toView:view.superview];
}

// Encore owns these arranged views and rewrites their frames during layout. Translate the view itself
// after measuring its untransformed position; unlike assigning a frame, this survives the stack pass.
static void translateViewInHost(UIView *view, UIView *host, CGPoint origin, const void *frameKey) {
    if (!view || !host || !view.superview) return;
    savedChildFrame(view, frameKey);
    view.transform = CGAffineTransformIdentity;
    CGRect source = [view convertRect:view.bounds toView:host];
    view.transform = CGAffineTransformMakeTranslation(origin.x - CGRectGetMinX(source),
                                                       origin.y - CGRectGetMinY(source));
}

static void landscapeTransportItems(UIView *controls, UIView **shuffleOut, UIView **previousOut,
                                    UIView **playOut, UIView **nextOut, UIView **repeatOut);
static BOOL transportItemContains(UIView *item, UIView *target);

static CGRect landscapeControlGlyphFrame(UIView *control, UIView *host) {
    if (!control || !host) return CGRectNull;
    __block CGRect glyphs = CGRectNull;
    SGForEachView(control, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class] || view.hidden || view.alpha < 0.01 ||
            view.bounds.size.width < 4 || view.bounds.size.height < 4 ||
            view.bounds.size.width > 40 || view.bounds.size.height > 40) return;
        CGRect frame = [view convertRect:view.bounds toView:host];
        glyphs = CGRectIsNull(glyphs) ? frame : CGRectUnion(glyphs, frame);
    });
    return CGRectIsNull(glyphs) ? [control convertRect:control.bounds toView:host] : glyphs;
}

static void layoutLandscapeProgress(UIView *duration, UIView *controls, UIView *host, SGRLyricsLayout l) {
    if (!duration || !host) return;
    UISlider *slider = (UISlider *)SGRFindByIdentifier(duration, @"SPTNowPlayingSliderV2", &kLandscapeSliderKey);
    // Move the SPTEncoreLabels wrappers, not their nested UILabels: Encore clips and lays out the
    // internal labels at its original position on every duration-unit pass.
    UIView *taken = SGRFindByIdentifier(duration, @"now-playing-time-take-label", &kLandscapeTakenKey);
    UIView *remaining = SGRFindByIdentifier(duration, @"now-playing-time-remaning-label", &kLandscapeRemainingKey);
    CGFloat progressX = CGRectGetMinX(l.cover);
    CGFloat availableWidth = MAX(0, CGRectGetMinX(l.stage) - progressX - SGRGrid);
    UIView *shuffle = nil, *previous = nil, *play = nil, *next = nil, *repeat = nil;
    landscapeTransportItems(controls, &shuffle, &previous, &play, &next, &repeat);
    CGRect repeatGlyph = landscapeControlGlyphFrame(repeat, host);
    CGFloat fallbackWidth = l.duration.size.width * kLandscapeProgressWidthScale;
    CGFloat targetWidth = CGRectIsNull(repeatGlyph) || CGRectGetMaxX(repeatGlyph) <= progressX
        ? fallbackWidth : CGRectGetMaxX(repeatGlyph) - progressX;
    CGFloat width = floor(MIN(MAX(0, targetWidth), availableWidth));
    CGRect progressFrame = CGRectZero;
    if ([slider isKindOfClass:UISlider.class] && [slider isDescendantOfView:duration]) {
        CGRect original = savedChildFrame(slider, &kLandscapeSliderFrameKey);
        // Restore the source frame before measuring it, or repeated layout passes would compound
        // the vertical scale and progressively flatten the slider.
        slider.transform = CGAffineTransformIdentity;
        slider.frame = original;
        progressFrame = [slider convertRect:slider.bounds toView:host];
        progressFrame.origin.x = progressX;
        progressFrame.size.width = width;
        setFrameIn(slider, host, progressFrame);
        slider.transform = CGAffineTransformMakeScale(1, kLandscapeProgressHeightScale);
    }
    if (taken && [taken isDescendantOfView:duration]) {
        CGRect source = [taken convertRect:taken.bounds toView:host];
        CGPoint origin = CGPointMake(progressX, CGRectIsEmpty(progressFrame)
                                     ? CGRectGetMinY(source) : CGRectGetMaxY(progressFrame) + 4);
        translateViewInHost(taken, host, origin, &kLandscapeTakenFrameKey);
    }
    if (remaining && [remaining isDescendantOfView:duration]) {
        CGRect source = [remaining convertRect:remaining.bounds toView:host];
        CGPoint origin = CGPointMake(MAX(progressX, progressX + width - source.size.width),
                                     CGRectIsEmpty(progressFrame)
                                         ? CGRectGetMinY(source) : CGRectGetMaxY(progressFrame) + 4);
        translateViewInHost(remaining, host, origin, &kLandscapeRemainingFrameKey);
    }
}

static BOOL viewHasButtonSemantics(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;
    if ([view isKindOfClass:UIControl.class] || (view.accessibilityTraits & UIAccessibilityTraitButton)) return YES;
    NSString *className = NSStringFromClass(view.class).lowercaseString;
    NSString *identifier = view.accessibilityIdentifier.lowercaseString;
    NSString *label = view.accessibilityLabel.lowercaseString;
    for (NSString *name in @[className ?: @"", identifier ?: @"", label ?: @""]) {
        for (NSString *term in @[@"button", @"dislike", @"dismiss", @"remove", @"addto", @"add-to", @"like"]) {
            if ([name containsString:term]) return YES;
        }
    }
    for (UIView *subview in view.subviews) if (viewHasButtonSemantics(subview)) return YES;
    return NO;
}

static UIView *arrangedRowItemContaining(UIView *row, UIView *target) {
    if (!row || !target) return nil;
    for (UIView *item in row.subviews) {
        if (transportItemContains(item, target)) return item;
    }
    return nil;
}

static NSArray<UIView *> *landscapeTitleActionItems(UIView *info) {
    UIView *title = sg_titleElement;
    UIView *row = title.superview;
    if (![row isKindOfClass:UIStackView.class]) return @[];
    NSArray<UIView *> *arranged = ((UIStackView *)row).arrangedSubviews;
    NSUInteger titleIndex = [arranged indexOfObject:title];
    if (titleIndex == NSNotFound) return @[];
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    for (NSUInteger index = titleIndex + 1; index < arranged.count; index++) {
        UIView *item = arranged[index];
        if (viewHasButtonSemantics(item)) [actions addObject:item];
    }
    CGFloat titleOrigin = CGRectGetMinX(untransformed(title, info));
    for (UIView *item in row.subviews) {
        if (item == title || [item isDescendantOfView:title] || [title isDescendantOfView:item] ||
            [actions containsObject:item] || !viewHasButtonSemantics(item)) continue;
        if (CGRectGetMinX(SGFrameIn(item, info)) > titleOrigin) [actions addObject:item];
    }
    // Spotify has used different ids for the two inline actions across player modes. If their row
    // wrappers are not directly accessible, resolve the familiar identifiers and lift them to the
    // arranged item so its native gesture recognizers and target actions remain intact.
    for (NSString *identifier in @[@"SPTNowPlayingDislikeButton", @"SPTNowPlayingAddToButton",
                                    @"SPTNowPlayingAddToQueueButton", @"Components.UI.AddToButton",
                                    @"DislikeButtonNowPlayingView", @"RemoveRecommendationButton"]) {
        UIView *match = SGRFindByIdentifier(info, identifier, NULL);
        UIView *item = arrangedRowItemContaining(row, match);
        if (item && item != title && ![actions containsObject:item]) [actions addObject:item];
    }
    return actions;
}

static CGFloat landscapeTitleTextWidth(UIView *info) {
    UILabel *label = (UILabel *)SGRFindByIdentifier(info, @"now-playing-title-label", &kTitleKey);
    if (![label isKindOfClass:UILabel.class]) return CGRectGetWidth(sg_titleElement.bounds);
    if (label.attributedText.length) {
        CGRect measured = [label.attributedText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGRectGetHeight(label.bounds))
                                                             options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                             context:nil];
        if (measured.size.width > 0) return ceil(measured.size.width);
    }
    if (label.text.length && label.font) return ceil([label.text sizeWithAttributes:@{NSFontAttributeName: label.font}].width);
    return CGRectGetWidth(label.bounds);
}

static void restoreLandscapeTitleActions(UIView *info) {
    NSArray<UIView *> *actions = objc_getAssociatedObject(info, &kLandscapeTitleActionsKey);
    for (UIView *action in actions) restoreChildFrame(action, &kLandscapeTitleActionFrameKey);
    objc_setAssociatedObject(info, &kLandscapeTitleActionsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void layoutLandscapeTitleActions(UIView *info, UIView *host, SGRLyricsLayout l) {
    NSArray<UIView *> *actions = landscapeTitleActionItems(info);
    if (!actions.count || !info || !host || !sg_titleElement) return;
    objc_setAssociatedObject(info, &kLandscapeTitleActionsKey, actions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat actionWidth = 0;
    for (UIView *action in actions) {
        CGRect original = savedChildFrame(action, &kLandscapeTitleActionFrameKey);
        action.transform = CGAffineTransformIdentity;
        action.frame = original;
        actionWidth += CGRectGetWidth(action.bounds);
    }
    CGFloat gap = 8;
    CGFloat titleLimit = MAX(0, l.titleMaxWidth - actionWidth - gap * actions.count);
    CGFloat titleWidth = MIN(landscapeTitleTextWidth(info), titleLimit);
    CGRect titleFrame = [sg_titleElement convertRect:sg_titleElement.bounds toView:host];
    UILabel *label = (UILabel *)SGRFindByIdentifier(info, @"now-playing-title-label", &kTitleKey);
    CGRect labelFrame = [label isKindOfClass:UILabel.class] ? [label convertRect:label.bounds toView:host] : titleFrame;
    CGFloat x = CGRectGetMinX(titleFrame) + titleWidth + gap;
    CGFloat middleY = CGRectGetMidY(labelFrame);
    for (UIView *action in actions) {
        CGRect frame = [action convertRect:action.bounds toView:host];
        CGPoint origin = CGPointMake(x, middleY - frame.size.height / 2);
        translateViewInHost(action, host, origin, &kLandscapeTitleActionFrameKey);
        [action.superview bringSubviewToFront:action];
        x += frame.size.width + gap;
    }
}

static void placeLandscapeButton(UIView *button, UIView *host, CGFloat x, CGFloat y, CGFloat scale, const void *key) {
    if (!button || !host || !button.superview) return;
    CGRect original = savedChildFrame(button, key);
    button.transform = CGAffineTransformIdentity;
    button.bounds = (CGRect){CGPointZero, original.size};
    button.center = [button.superview convertPoint:CGPointMake(x, y) fromView:host];
    button.transform = CGAffineTransformMakeScale(scale, scale);
}

static BOOL transportItemContains(UIView *item, UIView *target) {
    return item && target && (item == target || [target isDescendantOfView:item]);
}

static UIView *arrangedItemContaining(UIStackView *stack, UIView *target) {
    for (UIView *item in stack.arrangedSubviews) {
        if (transportItemContains(item, target)) return item;
    }
    return nil;
}

// Shuffle and repeat are the outer controls in Spotify's transport stack. Find that stack from the
// three stable identifiers and keep the actual arranged views, so their native actions stay attached.
static void landscapeTransportItems(UIView *controls, UIView **shuffleOut, UIView **previousOut,
                                    UIView **playOut, UIView **nextOut, UIView **repeatOut) {
    UIView *previous = SGRFindByIdentifier(controls, @"SPTNowPlayingPreviousTrackButton", &kLandscapePreviousKey);
    UIView *play = SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kLandscapePlayKey);
    UIView *next = SGRFindByIdentifier(controls, @"SPTNowPlayingNextTrackButton", &kLandscapeNextKey);
    UIView *shuffle = nil, *repeat = nil;
    __block UIStackView *transport = nil;
    __block NSUInteger bestCount = NSUIntegerMax;
    SGForEachView(controls, ^(UIView *view) {
        if (![view isKindOfClass:UIStackView.class]) return;
        UIStackView *stack = (UIStackView *)view;
        if (stack.arrangedSubviews.count < 5 || stack.arrangedSubviews.count >= bestCount) return;
        UIView *previousItem = arrangedItemContaining(stack, previous);
        UIView *playItem = arrangedItemContaining(stack, play);
        UIView *nextItem = arrangedItemContaining(stack, next);
        if (!previousItem || !playItem || !nextItem || previousItem == playItem || playItem == nextItem || previousItem == nextItem) return;
        transport = stack;
        bestCount = stack.arrangedSubviews.count;
    });
    if (transport) {
        NSUInteger previousIndex = [transport.arrangedSubviews indexOfObject:arrangedItemContaining(transport, previous)];
        NSUInteger nextIndex = [transport.arrangedSubviews indexOfObject:arrangedItemContaining(transport, next)];
        if (previousIndex != NSNotFound && previousIndex > 0) shuffle = transport.arrangedSubviews[previousIndex - 1];
        if (nextIndex != NSNotFound && nextIndex + 1 < transport.arrangedSubviews.count) repeat = transport.arrangedSubviews[nextIndex + 1];
    }
    if (!shuffle) shuffle = SGRFindByIdentifier(controls, @"SPTNowPlayingShuffleButton", &kLandscapeShuffleKey);
    if (!shuffle) shuffle = SGRFindByIdentifier(controls, @"Components.UI.ShuffleButton", &kLandscapeShuffleKey);
    if (!repeat) repeat = SGRFindByIdentifier(controls, @"SPTNowPlayingRepeatButton", &kLandscapeRepeatKey);
    if (!repeat) repeat = SGRFindByIdentifier(controls, @"Components.UI.RepeatButton", &kLandscapeRepeatKey);
    if (shuffleOut) *shuffleOut = shuffle;
    if (previousOut) *previousOut = previous;
    if (playOut) *playOut = play;
    if (nextOut) *nextOut = next;
    if (repeatOut) *repeatOut = repeat;
}

static NSArray<UIView *> *landscapeCoreControlTargets(UIView *controls, UIView *duration) {
    UIView *shuffle = nil, *previous = nil, *play = nil, *next = nil, *repeat = nil;
    landscapeTransportItems(controls, &shuffle, &previous, &play, &next, &repeat);
    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    for (UIView *view in @[shuffle ?: NSNull.null, previous ?: NSNull.null, play ?: NSNull.null,
                           next ?: NSNull.null, repeat ?: NSNull.null,
                           SGRFindByIdentifier(duration, @"SPTNowPlayingSliderV2", &kLandscapeSliderKey) ?: NSNull.null]) {
        if ([view isKindOfClass:UIView.class] && ![targets containsObject:view]) [targets addObject:view];
    }
    return targets;
}

@interface SGRLandscapeControlsReach : UIView
@property (nonatomic, copy) NSArray<UIView *> *targets;
@end

@implementation SGRLandscapeControlsReach
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *target in self.targets) {
        if (!target.window || target.hidden || target.alpha < 0.01 || !target.userInteractionEnabled) continue;
        CGPoint local = [target convertPoint:point fromView:self];
        if (![target pointInside:local withEvent:event]) continue;
        UIView *hit = [target hitTest:local withEvent:event];
        if (hit && hit != target) return hit;
        if (hit == target && ([target isKindOfClass:UIControl.class] || target.gestureRecognizers.count ||
                              (target.accessibilityTraits & UIAccessibilityTraitButton))) return hit;
    }
    return nil;
}
@end

static NSArray<UIView *> *landscapeTransportTargets(UIView *controls, UIView *duration, UIView *info) {
    NSMutableArray<UIView *> *targets = [NSMutableArray arrayWithArray:landscapeTitleActionItems(info)];
    for (UIView *view in landscapeCoreControlTargets(controls, duration)) {
        if (![targets containsObject:view]) [targets addObject:view];
    }
    // The unit bounds still cover the native action views. Asking it directly bypasses the bottom
    // stack's old hit area, which otherwise rejects the moved shuffle and repeat buttons.
    if (controls && ![targets containsObject:controls]) [targets addObject:controls];
    if (info && ![targets containsObject:info]) [targets addObject:info];
    return targets;
}

static void layoutLandscapeReach(UIView *host, UIView *controls, UIView *duration, UIView *info, BOOL enabled) {
    if (!host) return;
    SGRLandscapeControlsReach *reach = objc_getAssociatedObject(host, &kLandscapeReachKey);
    if (!enabled) {
        [reach removeFromSuperview];
        objc_setAssociatedObject(host, &kLandscapeReachKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!reach) {
        reach = [SGRLandscapeControlsReach new];
        reach.backgroundColor = UIColor.clearColor;
        reach.userInteractionEnabled = YES;
        objc_setAssociatedObject(host, &kLandscapeReachKey, reach, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    reach.targets = landscapeTransportTargets(controls, duration, info);
    if (reach.superview != host) [host addSubview:reach];
    reach.frame = host.bounds;
    [host bringSubviewToFront:reach];
}

static void layoutLandscapeControls(UIView *controls, UIView *host, SGRLyricsLayout l) {
    UIView *shuffle = nil, *previous = nil, *play = nil, *next = nil, *repeat = nil;
    landscapeTransportItems(controls, &shuffle, &previous, &play, &next, &repeat);
    UIView *buttons[] = {shuffle, previous, play, next, repeat};
    const void *frameKeys[] = {&kLandscapeShuffleFrameKey, &kLandscapePreviousFrameKey, &kLandscapePlayFrameKey,
                               &kLandscapeNextFrameKey, &kLandscapeRepeatFrameKey};
    CGFloat sizes[5] = {0};
    CGFloat occupied = 0;
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < 5; i++) {
        if (!buttons[i]) continue;
        sizes[i] = MAX(0, CGRectGetWidth(buttons[i].bounds) * kLandscapeTransportScale);
        occupied += sizes[i];
        count++;
    }
    if (!count) return;
    CGFloat gap = count > 1 ? MIN(16, MAX(4, (l.controls.size.width - occupied) / (count - 1))) : 0;
    CGFloat x = CGRectGetMinX(l.controls);
    CGFloat y = CGRectGetMidY(l.controls);
    for (NSUInteger i = 0; i < 5; i++) {
        if (!buttons[i]) continue;
        placeLandscapeButton(buttons[i], host, x + sizes[i] / 2, y, kLandscapeTransportScale, frameKeys[i]);
        x += sizes[i] + gap;
    }
}

static void restoreLandscapeChildren(UIView *duration, UIView *controls) {
    UISlider *slider = (UISlider *)SGRFindByIdentifier(duration, @"SPTNowPlayingSliderV2", &kLandscapeSliderKey);
    restoreChildFrame(slider, &kLandscapeSliderFrameKey);
    restoreChildFrame(SGRFindByIdentifier(duration, @"now-playing-time-take-label", &kLandscapeTakenKey), &kLandscapeTakenFrameKey);
    restoreChildFrame(SGRFindByIdentifier(duration, @"now-playing-time-remaning-label", &kLandscapeRemainingKey), &kLandscapeRemainingFrameKey);
    UIView *shuffle = nil, *previous = nil, *play = nil, *next = nil, *repeat = nil;
    landscapeTransportItems(controls, &shuffle, &previous, &play, &next, &repeat);
    restoreChildFrame(shuffle, &kLandscapeShuffleFrameKey);
    restoreChildFrame(previous, &kLandscapePreviousFrameKey);
    restoreChildFrame(SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kLandscapePlayKey), &kLandscapePlayFrameKey);
    restoreChildFrame(next, &kLandscapeNextFrameKey);
    restoreChildFrame(repeat, &kLandscapeRepeatFrameKey);
}

static void placeTitleRow(SGRLyricsLayout l) {
    UIView *info = sg_info.viewIfLoaded;
    if (!info) return;
    syncLandscapeFooter();
    BOOL landscape = sg_host.bounds.size.width > sg_host.bounds.size.height;
    UIView *duration = sg_duration.viewIfLoaded;
    UIView *controls = sg_controls.viewIfLoaded;
    if (landscape && sg_open && duration && controls) {
        moveUnit(duration, sg_host, l.duration.origin, &kLandscapeDurationFrameKey, &kLandscapeDurationMovedKey);
        moveUnit(controls, sg_host, l.controls.origin, &kLandscapeControlsFrameKey, &kLandscapeControlsMovedKey);
        layoutLandscapeControls(controls, sg_host, l);
        layoutLandscapeProgress(duration, controls, sg_host, l);
        layoutLandscapeReach(sg_host, controls, duration, info, YES);
    } else {
        layoutLandscapeReach(sg_host, controls, duration, info, NO);
        restoreLandscapeTitleActions(info);
        restoreLandscapeChildren(duration, controls);
        restoreUnitFrame(duration, sg_host, &kLandscapeDurationFrameKey, &kLandscapeDurationMovedKey);
        restoreUnitFrame(controls, sg_host, &kLandscapeControlsFrameKey, &kLandscapeControlsMovedKey);
    }
    [SGRowIn(info) layoutIfNeeded];
    CGFloat lift = sg_open ? l.lift : 0, shift = sg_open ? l.shift : (landscape ? l.baseShift : 0);
    CGAffineTransform rise = CGAffineTransformMakeTranslation(0, round(lift));
    if (!CGAffineTransformEqualToTransform(info.transform, rise)) info.transform = rise;
    UIView *title = sg_titleElement;
    if (!title) return;
    CGAffineTransform slide = CGAffineTransformIdentity;
    slide.tx = round(shift);
    if (!CGAffineTransformEqualToTransform(title.transform, slide)) title.transform = slide;
    if (landscape && sg_open) layoutLandscapeTitleActions(info, sg_host, l);
    // Closed it reaches as far as Spotify meant it to; moved, only as far as the controls it moved towards.
    CGFloat room = CGFLOAT_MAX;
    if (sg_open || landscape) room = trailingEdgeIn(info) - kTitleGap - (CGRectGetMinX(untransformed(title, info)) + shift);
    if (sg_open && l.titleMaxWidth > 0) room = MIN(room, l.titleMaxWidth);
    clipTitle(title, room);
}

#pragma mark - the lines alone

// Everything the lines leave the player to: the header row, the bottom stack with the title row lifted
// out of it, and the thumbnail. Alpha on the header unit's view and the stack, never hidden: views
// inside Spotify's stacks crash when hidden, and at alpha 0 UIKit hands them no touches either.
static void showControls(CGFloat alpha, SGRPlayerLyricsOverlay *overlay) {
    sg_header.viewIfLoaded.alpha = alpha;
    UIView *stack = sg_info.viewIfLoaded.superview;
    if ([stack isKindOfClass:UIStackView.class]) stack.alpha = alpha;
    overlay.thumb.alpha = alpha;
    SGRVinylLyricsControlsDidChange(alpha);
}

static void stopAloneTimer(void) {
    [sg_aloneTimer invalidate];
    sg_aloneTimer = nil;
}

static void scheduleAlone(void);

// Sing's microphone in the corner of the band the lines have now. Held, it keeps the controls from going
// and lets the count start over once it lets go.
static void placeSing(SGRPlayerLyricsOverlay *overlay, SGRLyricsLayout l) {
    CGRect band = [overlay convertRect:sg_alone ? l.room : l.stage fromView:sg_host];
    sg_sing = SGRSingControlForPage(overlay, band, sg_alone, ^(BOOL held) {
        sg_singHeld = held;
        if (held) stopAloneTimer();
        else scheduleAlone();
    });
}

static void setAlone(BOOL alone, BOOL animated) {
    if (alone == sg_alone) return;
    UIView *host = sg_host;
    SGRPlayerLyricsOverlay *overlay = host ? objc_getAssociatedObject(host, &kOverlayKey) : nil;
    SGRLyricsLayout l = layoutIn(host);
    if (alone && (!l.ok || !overlay.superview)) return;
    sg_alone = alone;
    stopAloneTimer();
    NSTimeInterval duration = animated ? (alone ? kAloneOut : kAloneBack) : 0;
    // Without a measurement the band is put back by the next layout pass (replace).
    if (l.ok && overlay.superview) [overlay.lyrics setLineInsets:bandOf(l, alone) duration:duration];
    void (^fade)(void) = ^{
        showControls(alone ? 0 : 1, overlay);
        if (l.ok && overlay.superview) {
            placeSing(overlay, l);
            [sg_sing layoutIfNeeded];
        }
    };
    if (duration > 0) {
        [UIView animateWithDuration:duration delay:0
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:fade completion:nil];
    } else {
        fade();
    }
    SGLog(@"redesign player: the controls %@, the lines from %.0f to %.0f", alone ? @"away" : @"back",
          alone ? CGRectGetMinY(l.room) : CGRectGetMinY(l.stage), alone ? CGRectGetMaxY(l.room) : CGRectGetMaxY(l.stage));
}

// The lines on the player and the song playing, with nothing over the player and no one listening to
// its controls with VoiceOver.
static BOOL mayGoAlone(void) {
    UIView *host = sg_host;
    SGRPlayerLyricsOverlay *overlay = host ? objc_getAssociatedObject(host, &kOverlayKey) : nil;
    if (!sg_open || playerIsLandscape() || sg_moving || sg_singHeld || !host.window || !overlay.superview || overlay.lyrics.hidden) return NO;
    SPTPlayerState *state = SGPlayerState();
    if (!state || state.isPaused) return NO;
    // A sheet the player opens (the queue, the devices, the menu) is presented by its topmost controller.
    UIViewController *top = sg_player;
    while (top.parentViewController) top = top.parentViewController;
    if (top.presentedViewController) return NO;
    return !SGRPlayerIsTransitioning() && !UIAccessibilityIsVoiceOverRunning()
        && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

// Counts the time untouched from now. A timer that finds the lines not in (a track still bringing its
// own) or a sheet over the player starts over. One that finds the song paused or the app away lets it
// be, so a locked phone playing on is not woken for it: playing again starts it (SGRPlayerLyricsWatcher),
// and so does the app coming back (the %ctor).
static void scheduleAlone(void) {
    stopAloneTimer();
    if (playerIsLandscape()) {
        if (sg_alone) setAlone(NO, NO);
        return;
    }
    if (!sg_open || sg_alone) return;
    sg_aloneTimer = [NSTimer scheduledTimerWithTimeInterval:kAloneAfter repeats:NO block:^(NSTimer *timer) {
        sg_aloneTimer = nil;
        if (mayGoAlone()) setAlone(YES, YES);
        else if (sg_open && !SGPlayerState().isPaused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) scheduleAlone();
    }];
}

// A touch has begun somewhere on the player, on `view`.
static void touched(UIView *view) {
    if (sg_alone && sg_sing && [view isDescendantOfView:sg_sing]) {
        sg_tapBroughtBack = NO;
        return;
    }
    sg_tapBroughtBack = sg_alone;
    if (sg_alone) setAlone(NO, YES);
    scheduleAlone();
}

// Sees every touch that starts on the player and leaves it to whatever it was meant for: it fails as
// the touch begins, so it holds nothing up, cancels nothing and stands in no gesture's way, the pull
// that closes the player included.
@interface SGRPlayerTouchWatcher : UIGestureRecognizer
@end

@implementation SGRPlayerTouchWatcher

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    touched(touches.anyObject.view);
    self.state = UIGestureRecognizerStateFailed;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }

@end

static void watchTouches(UIView *host) {
    if (objc_getAssociatedObject(host, &kWatcherKey)) return;
    SGRPlayerTouchWatcher *watcher = [[SGRPlayerTouchWatcher alloc] initWithTarget:nil action:NULL];
    watcher.cancelsTouchesInView = NO;
    watcher.delaysTouchesEnded = NO;
    [host addGestureRecognizer:watcher];
    objc_setAssociatedObject(host, &kWatcherKey, watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - opening and closing

BOOL SGRPlayerLyricsAvailable(void) {
    NSString *track = SGKaraokePlayingTrack();
    return track != nil && (SGKaraokeLinesForTrack(track) != nil || SGSingAvailable());
}

BOOL SGRPlayerLyricsCanOpen(void) {
    // A current track is enough to open the lyrics surface and request its text on demand.
    return SGKaraokePlayingTrack() != nil;
}

BOOL SGRPlayerLyricsOpen(void) {
    return sg_open;
}

// Puts the overlay's own views where the measurements say, without animating. The thumbnail is laid out
// at the size and place Spotify draws its cover at and moved by its transform alone, so a pass that
// runs while it is up leaves it exactly where the eye has it: the two are worked out from one
// measurement. Bounds and a centre, not a frame, since both views can be under a transform.
static void place(SGRPlayerLyricsOverlay *overlay, UIView *host, SGRLyricsLayout l) {
    overlay.frame = CGRectUnion(l.cover, CGRectUnion(l.thumb, l.room));
    CGRect cover = [overlay convertRect:l.cover fromView:host], stage = [overlay convertRect:l.room fromView:host];
    overlay.thumb.bounds = (CGRect){CGPointZero, cover.size};
    overlay.thumb.center = CGPointMake(CGRectGetMidX(cover), CGRectGetMidY(cover));
    UIView *face = overlay.thumb.face;
    CGPoint middle = CGPointMake(CGRectGetMidX(overlay.thumb.bounds), CGRectGetMidY(overlay.thumb.bounds));
    face.bounds = overlay.thumb.bounds;
    face.center = middle;
    overlay.cover.frame = face.bounds;
    SGRShadowPlate *plate = SGRShadowPlateIn(face, &kPlateKey);
    plate.bounds = face.bounds;
    plate.center = middle;
    overlay.stage.bounds = (CGRect){CGPointZero, stage.size};
    overlay.stage.center = CGPointMake(CGRectGetMidX(stage), CGRectGetMidY(stage));
    overlay.empty.frame = UIEdgeInsetsInsetRect(overlay.stage.bounds, bandOf(l, NO));
    overlay.rotate.bounds = CGRectMake(0, 0, kRotateButtonSide, kRotateButtonSide);
    CGRect rotate = [overlay convertRect:l.rotate fromView:host];
    overlay.rotate.center = CGPointMake(CGRectGetMidX(rotate), CGRectGetMidY(rotate));
    SGRGlassInside(overlay.rotate, &kRotateGlassKey, kRotateButtonSide);
    overlay.rotate.accessibilityLabel = host.bounds.size.width > host.bounds.size.height
        ? @"Rotate to portrait" : @"Rotate to landscape";
    [overlay bringSubviewToFront:overlay.rotate];
}

// Where the thumbnail's view has to go to land on `l.thumb`, as a transform about its own centre: the
// shadow and the corners travel with it that way, instead of a shadow redrawn on every frame.
static CGAffineTransform thumbTransform(SGRLyricsLayout l) {
    CGFloat scale = l.cover.size.width > 0 ? l.thumb.size.width / l.cover.size.width : 1;
    CGAffineTransform move = CGAffineTransformMakeTranslation(round(CGRectGetMidX(l.thumb) - CGRectGetMidX(l.cover)),
                                                             round(CGRectGetMidY(l.thumb) - CGRectGetMidY(l.cover)));
    return CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale), move);
}

// The corners as they will be drawn: a radius under a scale is drawn scaled, so the thumbnail asks for
// the radius it wants divided by the shrink, and the two ends of the animation are 12pt and 8pt corners.
static CGFloat thumbRadius(SGRLyricsLayout l, BOOL open) {
    if (!open) return SGRRadiusArtwork;
    CGFloat scale = l.cover.size.width > 0 ? l.thumb.size.width / l.cover.size.width : 1;
    return scale > 0 ? SGRRadiusCover / scale : SGRRadiusArtwork;
}

// Keep a sharp, large cover at the left of the title while the landscape player is closed. The blurred
// artwork field beneath it still fills the whole player when a track has no live Canvas.
static void keepLandscapeCover(UIView *host, SGRLyricsLayout l) {
    if (!host || host.bounds.size.width <= host.bounds.size.height || !l.ok) return;
    UIImage *picture = SGRNowPlayingArtwork(NULL, NULL);
    if (!picture) {
        SGRPlayerSetCoverHidden(NO);
        return;
    }
    SGRPlayerLyricsOverlay *overlay = overlayIn(host);
    place(overlay, host, l);
    overlay.cover.image = picture;
    overlay.cover.layer.cornerRadius = SGRRadiusArtwork;
    overlay.thumb.transform = CGAffineTransformIdentity;
    overlay.thumb.alpha = 1;
    overlay.stage.alpha = 0;
    overlay.rotate.alpha = 0;
    SGRPlayerSetCoverHidden(YES);
}

static void restoreSpotifyCover(UIView *host) {
    SGRPlayerSetCoverHidden(NO);
    SGRPlayerCoverList().alpha = 1;
    SGRPlayerLyricsOverlay *overlay = host ? objc_getAssociatedObject(host, &kOverlayKey) : nil;
    if (overlay && !sg_open) [overlay removeFromSuperview];
}

static void setOpen(BOOL open, BOOL animated) {
    UIView *host = sg_host;
    if (open == sg_open) return;
    if (!host) {
        SGLog(@"redesign player: the lyrics were asked for before the player laid out");
        return;
    }
    SGRLyricsLayout l = layoutIn(host);
    if (open && !l.ok) {
        SGLog(@"redesign player: the lyrics have nowhere to go (stage %.0fx%.0f, lift %.0f)", l.stage.size.width, l.stage.size.height, l.lift);
        return;
    }
    // The thumbnail is the Kit's picture drawn again. If it has not loaded yet, leave Spotify's cover
    // visible and still open the lyrics; the artwork notification fills the thumbnail when it arrives.
    UIImage *picture = SGRNowPlayingArtwork(NULL, NULL);
    BOOL landscape = host.bounds.size.width > host.bounds.size.height;
    // The controls come back first: the thumbnail flying back to the cover is one of them.
    if (!open) {
        setAlone(NO, animated);
        stopAloneTimer();
    }
    sg_open = open;
    SGRPlayerLyricsChanged();
    SGRPlayerAnimatedFollowLyrics(open, animated);

    SGRPlayerLyricsOverlay *overlay = overlayIn(host);
    if (!open) SGRSingControlDismiss(overlay);
    place(overlay, host, l);
    if (open) [overlay.lyrics setFontSize:landscape ? 24 : 30];
    CGAffineTransform vinylClosingTransform = CGAffineTransformIdentity;
    BOOL vinylClosing = !open && SGRVinylLyricsClosingTransform(overlay.thumb, &vinylClosingTransform);
    CGAffineTransform away = thumbTransform(l);
    BOOL inPlace = SGRPlayerAnimatedShowing(NULL, NULL);
    CGAffineTransform small = CGAffineTransformConcat(CGAffineTransformMakeScale(kThumbAppearScale, kThumbAppearScale), away);
    CGAffineTransform full = inPlace && !landscape ? small : CGAffineTransformIdentity;
    // The state it starts from, so the animation has both ends of every value and nothing jumps into it.
    overlay.thumb.transform = open ? full : away;
    overlay.cover.layer.cornerRadius = thumbRadius(l, inPlace || !open);
    if (open) {
        SGRVinylLyricsControlsDidChange(1);
        overlay.thumb.alpha = (inPlace && !landscape) || !picture ? 0 : 1;
        overlay.cover.image = picture;
        // Vinyl mode: replace the cover thumbnail with a mini spinning vinyl disc.
        SGRVinylInstallMiniDisc(overlay.thumb.face, overlay.cover);
        overlay.stage.alpha = 0;
        overlay.stage.transform = CGAffineTransformMakeScale(kLyricsEnterScale, kLyricsEnterScale);
        [overlay.lyrics setLineInsets:bandOf(l, NO) duration:0];
        placeSing(overlay, l);
        sg_sing.alpha = 0;
        // Spotify's cover goes the moment the redesign's own takes its place: the same picture at the
        // same size with the same corners, so there is nothing to see in the swap. Coming back it waits
        // for the thumbnail to land on it, or the two would be on screen at once, one of them half size.
        if (landscape) {
            SGRPlayerSetCoverHidden(YES);
        } else {
            SGRPlayerSetCoverHidden(NO);
            if (picture) SGRPlayerCoverList().alpha = 0;
        }
    }

    void (^move)(void) = ^{
        overlay.thumb.transform = open ? away : (vinylClosing ? vinylClosingTransform : full);
        if (picture && inPlace && !vinylClosing) overlay.thumb.alpha = open ? 1 : (landscape ? 1 : 0);
        overlay.cover.layer.cornerRadius = thumbRadius(l, inPlace || open);
        SGRVinylLyricsDidChange(open, sg_info.viewIfLoaded);
        placeTitleRow(l);
        sg_floating.viewIfLoaded.alpha = open ? 0 : 1;
    };
    void (^show)(void) = ^{
        overlay.stage.alpha = open ? 1 : 0;
        overlay.stage.transform = open ? CGAffineTransformIdentity
                                       : CGAffineTransformMakeScale(kLyricsEnterScale, kLyricsEnterScale);
        overlay.rotate.alpha = open ? 1 : 0;
        sg_sing.alpha = open ? 1 : 0;
    };
    void (^settled)(BOOL) = ^(BOOL finished) {
        sg_moving = NO;
        if (sg_open) {
            replace();         // a rotation during the opening flight changes the layout's geometry
            return;
        }
        SGRVinylLyricsDidSettleClosed();
        // Vinyl mode: restore the cover thumbnail.
        SGRVinylRemoveMiniDisc();
        if (host.bounds.size.width > host.bounds.size.height) {
            SGRLyricsLayout closed = layoutIn(host);
            keepLandscapeCover(host, closed);
        } else {
            restoreSpotifyCover(host);
        }
    };

    if (!animated) {
        move();
        show();
        settled(YES);
    } else {
        sg_moving = YES;
        SGRAnimate(SGRMotionLayout, move, settled);
        // The lines come in behind the cover leaving, and go before it comes back.
        [UIView animateWithDuration:open ? kLyricsIn : kLyricsOut delay:open ? kLyricsInDelay : 0
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:show completion:nil];
    }
    if (open) scheduleAlone();
    SGLog(@"redesign player: lyrics %@%@, thumbnail %.0fx%.0f at %.0f,%.0f, title row up %.0f and right %.0f, lines %.0fx%.0f",
          open ? @"up" : @"away", inPlace ? @" in place over a clip" : @"", l.thumb.size.width, l.thumb.size.height, l.thumb.origin.x, l.thumb.origin.y,
          -l.lift, l.shift, l.stage.size.width, l.stage.size.height);
}

void SGRPlayerToggleLyrics(void) {
    if (!sg_open) {
        NSString *track = SGKaraokePlayingTrack();
        if (!track) return;
        SGKaraokeRequestLyrics(track);
    }
    setOpen(!sg_open, YES);
}

// A layout pass, a new track or a turn of the phone: the state is put back where it belongs without
// animating, since the frames it is measured from have just changed.
static void replace(void) {
    UIView *host = sg_host;
    if (!host || sg_moving) return;   // a pass in the middle of the transition would cut it short
    if (playerIsLandscape()) {
        stopAloneTimer();
        if (sg_alone) setAlone(NO, NO);
    }
    SGRLyricsLayout l = layoutIn(host);
    if (sg_open && !l.ok) {
        SGLog(@"redesign player: lyrics layout no longer fits %.0fx%.0f; restoring the player layout",
              host.bounds.size.width, host.bounds.size.height);
        setOpen(NO, NO);
        return;
    }
    placeTitleRow(l);
    sg_floating.viewIfLoaded.alpha = sg_open ? 0 : 1;
    if (!sg_open) {
        if (host.bounds.size.width > host.bounds.size.height && l.ok) keepLandscapeCover(host, l);
        else restoreSpotifyCover(host);
        return;
    }
    SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(host, &kOverlayKey);
    if (!overlay.superview) overlay = overlayIn(host);
    place(overlay, host, l);
    [overlay.lyrics setFontSize:playerIsLandscape() ? 24 : 30];
    overlay.thumb.transform = thumbTransform(l);
    overlay.cover.layer.cornerRadius = thumbRadius(l, YES);
    overlay.lyrics.frame = overlay.stage.bounds;
    [overlay.lyrics setLineInsets:bandOf(l, sg_alone) duration:0];
    if (sg_alone) showControls(0, overlay);
    placeSing(overlay, l);
    if (host.bounds.size.width > host.bounds.size.height) SGRPlayerSetCoverHidden(YES);
    else {
        SGRPlayerSetCoverHidden(NO);
        SGRPlayerCoverList().alpha = 0;
    }
}

#pragma mark - the units

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGRPlayerOrientationPlayerDidAppear((UIViewController *)self);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    UIView *duration = sg_duration.viewIfLoaded, *controls = sg_controls.viewIfLoaded;
    restoreLandscapeTitleActions(sg_info.viewIfLoaded);
    if (size.width > size.height) {
        stopAloneTimer();
        if (sg_alone) setAlone(NO, NO);
    }
    restoreLandscapeChildren(duration, controls);
    restoreUnitFrame(duration, sg_host, &kLandscapeDurationFrameKey, &kLandscapeDurationMovedKey);
    restoreUnitFrame(controls, sg_host, &kLandscapeControlsFrameKey, &kLandscapeControlsMovedKey);
    if (duration) objc_setAssociatedObject(duration, &kLandscapeDurationFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (controls) objc_setAssociatedObject(controls, &kLandscapeControlsFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    __weak UIViewController *weakPlayer = (UIViewController *)self;
    void (^reapply)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *host = weakPlayer.viewIfLoaded;
            if (!host || host != sg_host) return;
            [host setNeedsLayout];
            [host layoutIfNeeded];
            replace();
        });
    };
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            (void)context;
            reapply();
        }];
    } else {
        reapply();
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host || host.bounds.size.height < kLivingHeight) return;
    if (sg_host != host) {
        sg_host = host;
        SGLog(@"redesign player: the lyrics have the player's view %.0fx%.0f", host.bounds.size.width, host.bounds.size.height);
    }
    sg_player = (UIViewController *)self;
    watchTouches(host);
    replace();
}

// The bar morphs back out of a full size cover as the player closes, so the thumbnail is put away first.
- (void)viewWillDisappear:(BOOL)animated {
    SGRPlayerOrientationPlayerWillDisappear((UIViewController *)self);
    if (sg_open) setOpen(NO, NO);
    restoreSpotifyCover(sg_host);
    UIView *info = sg_info.viewIfLoaded, *title = sg_titleElement;
    info.transform = CGAffineTransformIdentity;
    title.transform = CGAffineTransformIdentity;
    title.layer.mask = nil;
    restoreUnitFrame(sg_duration.viewIfLoaded, sg_host, &kLandscapeDurationFrameKey, &kLandscapeDurationMovedKey);
    restoreUnitFrame(sg_controls.viewIfLoaded, sg_host, &kLandscapeControlsFrameKey, &kLandscapeControlsMovedKey);
    %orig;
}
%end

// The header row goes with the rest of the controls while the lines are alone.
static void headerLaidOut(UIViewController *unit) {
    sg_header = unit;
    if (sg_alone) sg_header.viewIfLoaded.alpha = 0;
}

static void infoLaidOut(UIViewController *unit) {
    sg_info = unit;
    UIView *host = unit.viewIfLoaded;
    // The title and the artist are two labels of one arranged element view, which is what moves.
    UIView *label = SGRFindByIdentifier(host, @"now-playing-title-label", &kTitleKey);
    UIView *element = nil;
    for (UIView *v = label; v && v != host; v = v.superview) {
        if ([v.superview isKindOfClass:UIStackView.class]) { element = v; break; }
    }
    if (element && sg_titleElement != element) {
        sg_titleElement = element;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: the title rides on %@ %@", NSStringFromClass(element.class), NSStringFromCGRect(element.frame)); });
    }
    replace();
}

static void durationLaidOut(UIViewController *unit) {
    sg_duration = unit;
    captureUnitFrame(unit.viewIfLoaded, sg_host, &kLandscapeDurationFrameKey);
    replace();
}

static void controlsLaidOut(UIViewController *unit) {
    sg_controls = unit;
    captureUnitFrame(unit.viewIfLoaded, sg_host, &kLandscapeControlsFrameKey);
    if (sg_open) replace();
}

static void footerLaidOut(UIViewController *unit) {
    sg_footer = unit;
    syncLandscapeFooter();
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    headerLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    infoLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    durationLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    controlsLaidOut((UIViewController *)self);
}
%end

// Spotify Free's player builds the same elements into units of its own (Player.h); its floating unit
// is the shared one below.
%hook _TtC32ReinventFree_ReinventFreeNpvImpl43ReinventFreeNavigationBarUnitViewController
- (void)viewDidLayoutSubviews {
    %orig;
    headerLaidOut((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl35ReinventFreeInformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    infoLaidOut((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl20DurationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    durationLaidOut((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl40ReinventFreePlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    controlsLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    footerLaidOut((UIViewController *)self);
}
%end

%hook _TtC32ReinventFree_ReinventFreeNpvImpl30ReinventFreeFooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    footerLaidOut((UIViewController *)self);
}
%end

// The chips over the title (Switch to video and whatever else a track brings) sit in the middle of the
// room the lines take, so they go while the lines are up. The row keeps its height: the rest of the
// bottom stack stays where it was, which is the whole point of lifting only the title out of it.
%hook _TtC20NowPlaying_ModesImpl20FloatingElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_floating = (UIViewController *)self;
    replace();
}
%end

#pragma mark - the track changing under them

// Lyrics arrive a moment after the track does: refresh the glyph while they are being fetched, and keep
// the lyrics surface open while sources answer. Not in the background, where Spotify may not ask until
// the app is back, so coming back starts the refresh over.
static void awaitLyrics(void) {
    for (NSNumber *delay in @[@1, @(kLyricsGrace)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            SGRPlayerLyricsChanged();
        });
    }
}

// Sing switched on or off in Mod Settings > Karaoke, or its voice model arriving or going: the lyrics' glyph and
// the microphone follow at once, and lyrics that were open only for Sing put the cover back.
static void singAvailabilityChanged(void) {
    static BOOL available;
    if (SGSingAvailable() == available) return;
    available = !available;
    SGRPlayerLyricsChanged();
    if (!sg_open) return;
    if (!SGRPlayerLyricsAvailable()) setOpen(NO, YES);
    else replace();
}

@interface SGRPlayerLyricsWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerLyricsWatcher {
    NSString *_track;
    BOOL _paused;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    // Paused, the controls come back for the play button and stay; playing again, the wait starts over.
    if (state.isPaused != _paused) {
        _paused = state.isPaused;
        if (_paused) {
            setAlone(NO, YES);
            stopAloneTimer();
        } else {
            scheduleAlone();
        }
    }
    NSString *track = SGURIString(state.track.URI);
    if (!track || [track isEqualToString:_track]) return;
    _track = track;
    SGKaraokeRequestLyrics(SGKaraokePlayingTrack());
    SGRPlayerLyricsChanged();
    awaitLyrics();
}

@end

static SGRPlayerLyricsWatcher *sg_watcher;

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_watcher = [SGRPlayerLyricsWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        SGRPlayerLyricsChanged();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGSingDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        singAvailabilityChanged();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        // Spotify's own request may have been answered with nothing while the app was away.
        SGKaraokeRequestLyrics(SGKaraokePlayingTrack());
        SGRPlayerLyricsChanged();
        awaitLyrics();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (!sg_aloneTimer) scheduleAlone();   // the wait gave up while the app was away
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (!sg_open) {
            if (sg_host.bounds.size.width > sg_host.bounds.size.height) replace();
            return;
        }
        SGRPlayerLyricsOverlay *overlay = objc_getAssociatedObject(sg_host, &kOverlayKey);
        UIImage *artwork = SGRNowPlayingArtwork(NULL, NULL);
        if (!overlay || !artwork) return;
        overlay.cover.image = artwork;
        SGRAnimate(SGRMotionFade, ^{
            overlay.thumb.alpha = 1;
            if (sg_host.bounds.size.width > sg_host.bounds.size.height) SGRPlayerSetCoverHidden(YES);
            else {
                SGRPlayerSetCoverHidden(NO);
                SGRPlayerCoverList().alpha = 0;
            }
        }, nil);
    }];
    SGRequireClasses(@[
        @"_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
        @"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        @"_TtC20NowPlaying_ModesImpl19DurationElementUnit",
        @"_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit",
        @"_TtC20NowPlaying_ModesImpl18FooterElementsUnit",
        @"_TtC20NowPlaying_ModesImpl20FloatingElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl43ReinventFreeNavigationBarUnitViewController",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl35ReinventFreeInformationElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl20DurationElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl40ReinventFreePlaybackControlsElementsUnit",
        @"_TtC32ReinventFree_ReinventFreeNpvImpl30ReinventFreeFooterElementsUnit",
    ]);
}
