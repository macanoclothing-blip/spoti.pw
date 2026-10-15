#import <UIKit/UIKit.h>

extern NSNotificationName const SGLocalArtworkDidChangeNotification;
extern NSNotificationName const SGLocalArtworkMatchDidChangeNotification;

BOOL SGLocalArtworkIsLocalTrack(NSString *uri);
NSDictionary<NSString *, id> *SGLocalArtworkMatch(NSString *localURI);
NSString *SGLocalArtworkSpotifyURI(NSString *localURI);
NSString *SGLocalArtworkCoverURL(NSString *localURI);
NSString *SGLocalArtworkTitle(NSString *localURI);
NSString *SGLocalArtworkArtist(NSString *localURI);
UIImage *SGLocalArtworkCachedCover(NSString *localURI);
void SGLocalArtworkLoadCover(NSString *localURI, void (^completion)(UIImage *image));
BOOL SGLocalArtworkHasCustomCover(NSString *localURI);
BOOL SGLocalArtworkSaveCustomCover(NSString *localURI, UIImage *image, NSError **error);
BOOL SGLocalArtworkRemoveCustomCover(NSString *localURI, NSError **error);
void SGLocalArtworkSaveNames(NSString *localURI, NSString *title, NSString *artist);
void SGLocalArtworkSaveMatch(NSString *localURI, NSDictionary<NSString *, id> *match);
void SGLocalArtworkSaveSelection(NSString *localURI, NSDictionary<NSString *, id> *match,
                                 NSString *title, NSString *artist);
void SGLocalArtworkRemoveMatch(NSString *localURI);
void SGLocalArtworkPresentEditor(NSString *localURI, UIViewController *presenter);
