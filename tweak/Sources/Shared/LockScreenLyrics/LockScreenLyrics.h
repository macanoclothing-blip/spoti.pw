// The line being sung in place of the artist in the system's now playing: lock screen, Dynamic Island,
// Control Center, CarPlay. There is a Live Activity for it too (Shared/LiveActivity). The
// lines and the clock come from Karaoke.
#import <Foundation/Foundation.h>

#define SGKeyLockScreenLyrics @"spotifyglass.lockScreenLyrics"
#define SGKeyLockScreenLyricsArtwork @"spotifyglass.lockScreenLyricsArtwork"
#define SGKeyLockScreenLyricsArtworkStyle @"spotifyglass.lockScreenLyricsArtworkStyle"

typedef NS_ENUM(NSInteger, SGLockScreenLyricsArtworkStyle) {
    SGLockScreenLyricsArtworkStyleDefault = 0,
    SGLockScreenLyricsArtworkStyleWordCollage = 1,
    SGLockScreenLyricsArtworkStyleEditorial = 2,
    SGLockScreenLyricsArtworkStyleReceipt = 3,
    SGLockScreenLyricsArtworkStyleSocialPost = 4,
    SGLockScreenLyricsArtworkStyleRetroTV = 5,
    SGLockScreenLyricsArtworkStyleNeon = 6,
    SGLockScreenLyricsArtworkStyleVHS = 7,
    SGLockScreenLyricsArtworkStyleBlueprint = 8,
};

// When enabled at launch, the lock-screen star switches between the current animated artwork and
// the synced lyric line rendered as animated artwork (iOS 26+).
BOOL SGLockScreenLyricsArtworkEnabled(void);
BOOL SGLockScreenLyricsArtworkShowing(void);
void SGLockScreenLyricsArtworkSetShowing(BOOL showing);
void SGLockScreenLyricsArtworkStyleDidChange(void);
extern NSNotificationName const SGLockScreenLyricsArtworkStyleDidChangeNotification;
// The current track's local Canvas/animated-cover file, or nil while it is being looked up.
void SGLyricsArtworkSetMotion(NSString *uri, NSURL *file);
