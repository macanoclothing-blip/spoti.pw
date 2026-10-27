#import <UIKit/UIKit.h>

@class SGKaraokeLine, SGKaraokeWord;

// Builds the background once so each timed video frame only needs to redraw the lyrics.
UIImage *SGLockScreenLyricsPreparedBackgroundFrame(UIImage *source, NSInteger style, CGSize size);
UIImage *SGLockScreenLyricsFrameOnBackground(UIImage *background, NSInteger positionMs,
                                             NSString *currentLine, NSString *currentTranslation, NSString *nextLine,
                                             NSString *title, NSString *artist, NSInteger style,
                                             NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex,
                                             NSArray<SGKaraokeLine *> *lyricsLines, NSInteger activeLineIndex, CGSize size);
// Builds one lyric card from the current Canvas frame or album art.
UIImage *SGLockScreenLyricsFrame(NSURL *canvas, NSInteger positionMs, UIImage *cover,
                                NSString *currentLine, NSString *currentTranslation, NSString *nextLine,
                                NSString *title, NSString *artist, NSInteger style,
                                NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex,
                                NSArray<SGKaraokeLine *> *lyricsLines, NSInteger activeLineIndex, CGSize size);
UIImage *SGLockScreenLyricsStylePreviewFrame(NSInteger style, CGSize size);
// Encodes timed word-highlight frames as an H.264 asset for MPMediaItemAnimatedArtwork.
BOOL SGLockScreenLyricsMovie(NSUInteger frameCount, NSInteger frameRate, NSURL *destination,
                             UIImage *(^frameAtIndex)(NSUInteger index));
