#import "Core/SGCore.h"
#import "SGRTokens.h"
#import <objc/runtime.h>

static char kRestingTransformKey;

%hook UIButton

- (void)setHighlighted:(BOOL)highlighted {
    BOOL wasHighlighted = self.isHighlighted;
    %orig(highlighted);
    if (wasHighlighted == highlighted) return;

    Method buttonImplementation = class_getInstanceMethod(UIButton.class, @selector(setHighlighted:));
    Method classImplementation = class_getInstanceMethod(self.class, @selector(setHighlighted:));
    if (classImplementation != buttonImplementation) return;

    if (highlighted) {
        if (!self.enabled) return;
        CGAffineTransform restingTransform = self.transform;
        objc_setAssociatedObject(self, &kRestingTransformKey,
                                 [NSValue valueWithCGAffineTransform:restingTransform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRAnimate(SGRMotionPress, ^{
            self.transform = CGAffineTransformScale(restingTransform, 0.97, 0.97);
        }, nil);
        return;
    }

    NSValue *restingValue = objc_getAssociatedObject(self, &kRestingTransformKey);
    if (!restingValue) return;
    CGAffineTransform restingTransform = restingValue.CGAffineTransformValue;
    objc_setAssociatedObject(self, &kRestingTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRAnimate(SGRMotionPress, ^{
        self.transform = restingTransform;
    }, nil);
}

%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
