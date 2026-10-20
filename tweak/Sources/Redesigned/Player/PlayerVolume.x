// Place the system output-volume control in the space between the transport controls and footer.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

static const CGFloat kVolumeRowHeight = 34;
static const CGFloat kVolumeGlyphSize = 16;
static const CGFloat kVolumeGlyphGap = 8;
static const CGFloat kVolumeSideInset = 24;
static const CGFloat kVolumeControlClearance = 6;
static char kVolumeRowKey;
static char kPreviousButtonKey, kPlayButtonKey, kNextButtonKey;

static UIImage *volumeTrackImage(UIColor *color) {
    CGSize size = CGSizeMake(6, 4);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    format.opaque = NO;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
            [color setFill];
            [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size}
                                        cornerRadius:size.height / 2] fill];
        }];
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 2, 0, 2)
                                 resizingMode:UIImageResizingModeStretch];
}

static UIImage *volumeThumbImage(void) {
    CGSize size = CGSizeMake(18, 18);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
        }];
}

static UIImageView *volumeGlyph(NSString *symbol) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:kVolumeGlyphSize weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    UIImageView *view = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    view.tintColor = [UIColor colorWithWhite:1 alpha:0.72];
    view.contentMode = UIViewContentModeCenter;
    view.accessibilityElementsHidden = YES;
    return view;
}

static CGRect volumeControlsFrame(UIView *controls, UIView *stack) {
    static const void *keys[] = {&kPreviousButtonKey, &kPlayButtonKey, &kNextButtonKey};
    NSArray<NSString *> *identifiers = @[
        @"SPTNowPlayingPreviousTrackButton", @"SPTNowPlayingPlayButton", @"SPTNowPlayingNextTrackButton"
    ];
    CGRect frame = CGRectNull;
    for (NSUInteger index = 0; index < identifiers.count; index++) {
        UIView *button = SGRFindByIdentifier(controls, identifiers[index], keys[index]);
        if (!button || button.hidden || button.alpha < 0.01) continue;
        CGRect buttonFrame = [button convertRect:button.bounds toView:stack];
        frame = CGRectIsNull(frame) ? buttonFrame : CGRectUnion(frame, buttonFrame);
    }
    return CGRectIsNull(frame) ? [controls convertRect:controls.bounds toView:stack] : frame;
}

@interface SGRVolumeRow : UIView
@end

@implementation SGRVolumeRow {
    MPVolumeView *_volume;
    UIImageView *_quiet;
    UIImageView *_loud;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _volume = [MPVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _volume.showsRouteButton = NO;
#pragma clang diagnostic pop
    _volume.showsVolumeSlider = YES;
    UIImage *minimumTrack = volumeTrackImage([UIColor colorWithWhite:1 alpha:0.82]);
    UIImage *maximumTrack = volumeTrackImage([UIColor colorWithWhite:1 alpha:0.30]);
    UIImage *thumb = volumeThumbImage();
    for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled)]) {
        UIControlState controlState = state.unsignedIntegerValue;
        [_volume setMinimumVolumeSliderImage:minimumTrack forState:controlState];
        [_volume setMaximumVolumeSliderImage:maximumTrack forState:controlState];
        [_volume setVolumeThumbImage:thumb forState:controlState];
    }
    _volume.accessibilityLabel = @"iPhone volume";
    _quiet = volumeGlyph(@"speaker.fill");
    _loud = volumeGlyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_volume];
    [self addSubview:_loud];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat midY = CGRectGetMidY(bounds);
    CGFloat iconWidth = kVolumeRowHeight / 2 + kVolumeGlyphSize / 2;
    _quiet.frame = CGRectMake(0, midY - kVolumeRowHeight / 2, iconWidth, kVolumeRowHeight);
    _loud.frame = CGRectMake(CGRectGetWidth(bounds) - iconWidth, midY - kVolumeRowHeight / 2,
                             iconWidth, kVolumeRowHeight);
    CGFloat left = CGRectGetMaxX(_quiet.frame) + kVolumeGlyphGap;
    CGFloat right = CGRectGetMinX(_loud.frame) - kVolumeGlyphGap;
    CGSize fitting = [_volume sizeThatFits:CGSizeMake(MAX(0, right - left), kVolumeRowHeight)];
    CGFloat volumeHeight = fitting.height > 0 ? MIN(kVolumeRowHeight, fitting.height) : kVolumeRowHeight;
    _volume.frame = CGRectMake(left, round(midY - volumeHeight / 2),
                               MAX(0, right - left), volumeHeight);
}

@end

BOOL SGRPlayerLayoutVolume(UIView *stack, UIView *controls, UIView *footer) {
    if (!stack) return NO;
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeRowKey);
    if (!volume) {
        volume = [SGRVolumeRow new];
        objc_setAssociatedObject(stack, &kVolumeRowKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (volume.superview != stack) [stack addSubview:volume];
    if (!controls || !footer || !stack.window) {
        volume.alpha = 0;
        SGLog(@"redesign player: volume row has no window, controls or footer");
        return NO;
    }

    CGRect controlsFrame = volumeControlsFrame(controls, stack);
    CGRect footerFrame = [footer convertRect:footer.bounds toView:stack];
    CGFloat top = CGRectGetMaxY(controlsFrame) + kVolumeControlClearance;
    CGFloat bottom = CGRectGetMinY(footerFrame) - kVolumeControlClearance;
    CGFloat room = bottom - top;
    if (room < kVolumeRowHeight) {
        CGFloat shortage = kVolumeRowHeight - room;
        CGAffineTransform transform = controls.transform;
        controls.transform = CGAffineTransformMakeTranslation(transform.tx, transform.ty - shortage);
        controlsFrame = volumeControlsFrame(controls, stack);
        top = CGRectGetMaxY(controlsFrame) + kVolumeControlClearance;
        room = bottom - top;
    }

    CGFloat width = MAX(0, CGRectGetWidth(stack.bounds) - 2 * kVolumeSideInset);
    CGFloat rowHeight = MIN(kVolumeRowHeight, room);
    CGRect frame = CGRectMake(kVolumeSideInset, round((top + bottom - rowHeight) / 2),
                              width, kVolumeRowHeight);
    frame.size.height = rowHeight;
    if (CGRectIntersectsRect(frame, controlsFrame) || CGRectIntersectsRect(frame, footerFrame) || width < 1) {
        volume.alpha = 0;
        SGLog(@"redesign player: volume row cannot fit without covering controls or footer (%.0fpt)", room);
        return NO;
    }
    if (!CGRectEqualToRect(volume.frame, frame)) volume.frame = frame;
    [stack bringSubviewToFront:volume];
    if (volume.alpha != 1) volume.alpha = 1;
    return YES;
}
