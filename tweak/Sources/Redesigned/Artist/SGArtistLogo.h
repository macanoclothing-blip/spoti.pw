#import <UIKit/UIKit.h>

#define SGRKeyArtistLogoApple @"spotifyglass.redesign.artistLogo.appleMusic"

extern NSNotificationName const SGRArtistLogoKeyDidChangeNotification;

NSString *SGRArtistLogoKeyShown(void);
NSString *SGRArtistLogoSetKey(NSString *text);
BOOL SGRArtistLogoAppleEnabled(void);
void SGRArtistLogoSetAppleEnabled(BOOL enabled);
void SGRArtistLogoForArtist(NSString *artist, void (^done)(UIImage *logo));
