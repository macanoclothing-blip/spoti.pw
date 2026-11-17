#import <UIKit/UIKit.h>

@class SGModSection;

#define SGRKeyMomentsEnabled @"spotifyglass.redesign.moments.enabled"

BOOL SGRMomentsEnabled(void);
NSDictionary<NSString *, id> *SGRMomentAtPosition(NSString *trackID, NSInteger positionMs);

@interface SGRMomentBubbleView : UIView
- (instancetype)initWithText:(NSString *)text;
@end

void SGRPresentMomentComposer(UIView *source);
void SGROpenSpotifyMoments(UIView *source);
UIViewController *SGRSpotifyMomentsPage(void);
SGModSection *SGRMomentsSettingsSection(void);
