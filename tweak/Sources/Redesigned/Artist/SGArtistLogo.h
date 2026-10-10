#import <UIKit/UIKit.h>

extern NSNotificationName const SGRArtistLogoKeyDidChangeNotification;

NSString *SGRArtistLogoKeyShown(void);
NSString *SGRArtistLogoSetKey(NSString *text);
void SGRArtistLogoForArtist(NSString *artist, void (^done)(UIImage *logo));
