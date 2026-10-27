#import <UIKit/UIKit.h>

// Lightweight view of local audio files in Spotify's Documents folder, grouped into record sleeves.
@interface SGLocalTrack : NSObject
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) NSInteger seconds;
@end

@interface SGLocalAlbum : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSArray<SGLocalTrack *> *tracks;
@property (nonatomic, strong) NSDate *added;
@property (nonatomic) NSInteger year;
@property (nonatomic) NSInteger seconds;
@end

extern NSNotificationName const SGLocalAlbumsDidChangeNotification;
NSArray<SGLocalAlbum *> *SGLocalAlbums(void);
void SGLocalAlbumsRefresh(void (^done)(void));
void SGLocalAlbumCover(SGLocalAlbum *album, CGFloat side, void (^done)(UIImage *cover));
UIViewController *SGRLocalAlbumPageNew(SGLocalAlbum *album);
