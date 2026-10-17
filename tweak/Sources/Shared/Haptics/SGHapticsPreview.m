#import "Core/SGCore.h"
#import "SGHapticsPreview.h"
#import "Haptics.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIAccessibility.h>

@interface SGHapticsPreview ()
@property (nonatomic) NSArray<CAShapeLayer *> *rings;
@property (nonatomic) CAShapeLayer *ripple;
@property (nonatomic) CAShapeLayer *centerDot;
@property (nonatomic) UILabel *caption;
@end

@implementation SGHapticsPreview

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Tap to feel Controls";
    self.accessibilityHint = @"Double-tap to feel the Controls feedback";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(sg_tapped) forControlEvents:UIControlEventTouchUpInside];

    NSMutableArray<CAShapeLayer *> *rings = [NSMutableArray array];
    for (NSUInteger index = 0; index < 8; index++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.fillColor = UIColor.clearColor.CGColor;
        ring.strokeColor = UIColor.tertiaryLabelColor.CGColor;
        ring.lineWidth = 2;
        ring.lineDashPattern = @[@1, @5];
        ring.opacity = 0.62;
        [self.layer addSublayer:ring];
        [rings addObject:ring];
    }
    _rings = rings;

    _ripple = [CAShapeLayer layer];
    _ripple.fillColor = UIColor.clearColor.CGColor;
    _ripple.strokeColor = UIColor.systemGreenColor.CGColor;
    _ripple.lineWidth = 2;
    _ripple.opacity = 0;
    [self.layer addSublayer:_ripple];

    _centerDot = [CAShapeLayer layer];
    _centerDot.fillColor = UIColor.systemGreenColor.CGColor;
    [self.layer addSublayer:_centerDot];

    _caption = [UILabel new];
    _caption.text = @"Tap to feel Controls";
    _caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _caption.adjustsFontForContentSizeCategory = YES;
    _caption.numberOfLines = 0;
    _caption.textColor = UIColor.secondaryLabelColor;
    _caption.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_caption];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sg_motionChanged)
        name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        for (CAShapeLayer *ring in self.rings) ring.strokeColor = UIColor.tertiaryLabelColor.CGColor;
        self.ripple.strokeColor = UIColor.systemGreenColor.CGColor;
        self.centerDot.fillColor = UIColor.systemGreenColor.CGColor;
        self.caption.textColor = UIColor.secondaryLabelColor;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat captionHeight = MAX(20, [self.caption sizeThatFits:
        CGSizeMake(MAX(0, CGRectGetWidth(self.bounds) - 16), CGFLOAT_MAX)].height);
    CGFloat side = MIN(CGRectGetWidth(self.bounds), MAX(0, CGRectGetHeight(self.bounds) - captionHeight - 14));
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), side / 2);
    CGFloat maxRadius = side * 0.43;
    for (NSUInteger index = 0; index < self.rings.count; index++) {
        CGFloat radius = maxRadius * (CGFloat)(index + 1) / (CGFloat)self.rings.count;
        CAShapeLayer *ring = self.rings[index];
        ring.frame = self.bounds;
        ring.path = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2)].CGPath;
    }
    CGFloat rippleRadius = MAX(1, maxRadius / 8);
    self.ripple.frame = self.bounds;
    self.ripple.path = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - rippleRadius, center.y - rippleRadius, rippleRadius * 2, rippleRadius * 2)].CGPath;
    self.centerDot.frame = self.bounds;
    self.centerDot.path = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - 4, center.y - 4, 8, 8)].CGPath;
    self.caption.frame = CGRectMake(8, CGRectGetMaxY(self.bounds) - captionHeight,
                                    MAX(0, CGRectGetWidth(self.bounds) - 16), captionHeight);
}

- (void)sg_tapped {
    SGPlayFeedbackPreview(SGFeedbackAdd);
    [self sg_animateRipple];
}

- (BOOL)accessibilityActivate {
    [self sg_tapped];
    return YES;
}

- (void)sg_motionChanged {
    if (UIAccessibilityIsReduceMotionEnabled()) [self.ripple removeAllAnimations];
}

- (void)sg_animateRipple {
    [self.ripple removeAllAnimations];
    self.ripple.transform = CATransform3DIdentity;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CFTimeInterval duration = reduceMotion ? 0.24 : 0.72;
    self.ripple.opacity = 0;
    if (!reduceMotion) {
        self.ripple.transform = CATransform3DMakeScale(7, 7, 1);
    }

    CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacity.fromValue = @0.9;
    opacity.toValue = @0;
    opacity.duration = duration;

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1;
    scale.toValue = @(reduceMotion ? 1 : 7);
    scale.duration = duration;

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = reduceMotion ? @[opacity] : @[opacity, scale];
    group.duration = duration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.ripple addAnimation:group forKey:@"sg.preview.ripple"];
}
@end
