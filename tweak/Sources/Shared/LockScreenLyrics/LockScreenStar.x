// With the opt-in enabled, the lock-screen star becomes a reversible lyrics/artwork switch.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "LockScreenLyrics.h"
#import "Shared/Player/PlayerState.h"

static NSString *const kLikeDislikeFlag = @"ios-feature-lockscreen.like_dislike_enabled";
static MPFeedbackCommand *sg_lyricsStar;
static id sg_lyricsStarTarget;

static MPRemoteCommandHandlerStatus tapped(void) {
    if (!SGLockScreenLyricsArtworkEnabled()) return MPRemoteCommandHandlerStatusCommandFailed;
    BOOL showing = !SGLockScreenLyricsArtworkShowing();
    SGLockScreenLyricsArtworkSetShowing(showing);
    dispatch_async(dispatch_get_main_queue(), ^{ sg_lyricsStar.active = showing; });
    return MPRemoteCommandHandlerStatusSuccess;
}

static void arm(void) {
    static BOOL lastEnabled, lastShowing;
    BOOL enabled = SGLockScreenLyricsArtworkEnabled();
    BOOL showing = enabled && SGLockScreenLyricsArtworkShowing();
    if (enabled == lastEnabled && showing == lastShowing && enabled == (sg_lyricsStar != nil)) return;
    lastEnabled = enabled;
    lastShowing = showing;

    MPFeedbackCommand *like = MPRemoteCommandCenter.sharedCommandCenter.likeCommand;
    if (!enabled) {
        if (sg_lyricsStar) {
            [like removeTarget:sg_lyricsStarTarget];
            sg_lyricsStarTarget = nil;
            sg_lyricsStar = nil;
            like.enabled = NO;
            like.active = NO;
        }
        return;
    }
    if (!sg_lyricsStar) {
        [like removeTarget:nil];
        sg_lyricsStarTarget = [like addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            return tapped();
        }];
        like.localizedTitle = @"Show or hide lyrics";
        sg_lyricsStar = like;
    }
    like.enabled = YES;
    like.active = showing;
}

%hook MPRemoteCommand
- (void)setEnabled:(BOOL)enabled {
    if (!enabled && sg_lyricsStar && self == sg_lyricsStar && SGLockScreenLyricsArtworkEnabled()) enabled = YES;
    %orig(enabled);
}

- (void)removeTarget:(id)target {
    if (sg_lyricsStar && self == sg_lyricsStar && !target && target != sg_lyricsStarTarget) {
        sg_lyricsStar = nil;
        sg_lyricsStarTarget = nil;
    }
    %orig;
}
%end

@interface SGLockScreenLyricsStarObserver : NSObject <SGPlayerStateObserver>
@end
@implementation SGLockScreenLyricsStarObserver
- (void)playerStateDidChange:(SPTPlayerState *)state { arm(); }
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        BOOL enabledAtLaunch = SGHidden(SGKeyLockScreenLyricsArtwork);
        SGRegisterFlagForcer(YES, ^id(NSString *key) {
            return enabledAtLaunch && [key isEqualToString:kLikeDislikeFlag] ? @NO : nil;
        }, ^id(NSString *key) {
            return SGLockScreenLyricsArtworkEnabled() && [key isEqualToString:kLikeDislikeFlag] ? @NO : nil;
        });
        %init;
        static SGLockScreenLyricsStarObserver *observer;
        observer = [SGLockScreenLyricsStarObserver new];
        SGAddPlayerStateObserver(observer);
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ arm(); });
        }];
        arm();
    }
}
