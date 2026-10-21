#import <UIKit/UIKit.h>

#define SGRKeyArtistLogoApple @"spotifyglass.redesign.artistLogo.appleMusic"

@interface SGRArtistLogoOption : NSObject
@property (nonatomic, copy, readonly) NSString *source;
@property (nonatomic, copy, readonly) NSString *selectionKey;
@property (nonatomic, strong, readonly) UIImage *image;
@end

extern NSNotificationName const SGRArtistLogoKeyDidChangeNotification;

NSString *SGRArtistLogoKeyShown(void);
NSString *SGRArtistLogoSetKey(NSString *text);
BOOL SGRArtistLogoAppleEnabled(void);
void SGRArtistLogoSetAppleEnabled(BOOL enabled);
void SGRArtistLogoForArtist(NSString *artist, void (^done)(UIImage *logo));
void SGRArtistLogoOptionsForArtist(NSString *artist, void (^done)(NSArray<SGRArtistLogoOption *> *options));
NSString *SGRArtistLogoSelectedKeyForArtist(NSString *artist);
void SGRArtistLogoSelectOption(NSString *artist, SGRArtistLogoOption *option);
void SGRArtistLogoUseAutomatic(NSString *artist);
