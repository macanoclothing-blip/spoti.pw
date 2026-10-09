// Vinyl mode: overlays the Canvas or Fluid field with the bundled marbled disc texture, tinted from
// the cover palette, and the bundled tonearm image. The disc sits left of centre (partly cropped),
// shows the current cover in its label and spins only during playback. The player's header (close + ⋯)
// is kept intact; everything else — artwork, controls, footer — is hidden and replaced with four
// tappable pill buttons (Play/Pause, Lyrics, Prev, Next).
//
// When Lyrics are open, the redesigned lyrics view stays interactive, and the album cover thumbnail
// in the top-left is replaced by a mini spinning vinyl disc. Tapping it returns to the vinyl view.
// Dragging the full-size disc pauses playback and repeats the bundled scratch sound with haptics
// every half-second; playback resumes on release only if it was playing before the gesture.
//
// The switch is spotifyglass.redesign.vinyl, read at launch, restart required.
// PlayerVinyl.x: the vinyl overlay view, mini disc and all hooks.

#import <UIKit/UIKit.h>

#define SGRKeyPlayerVinyl @"spotifyglass.redesign.vinyl"

// The rows added to the player's settings page (NowPlayingBarSettings.m).
@class SGModSection;
SGModSection *SGRVinylSection(void);

// Called by PlayerLyrics.x (setOpen) to install/remove the mini spinning vinyl on the lyrics thumbnail.
// `face` is SGRPlayerLyricsThumb.face; `cover` is the UIImageView inside it to hide.
// Call with nil,nil to just refresh artwork on an already-installed mini disc.
void SGRVinylInstallMiniDisc(UIView *face, UIImageView *cover);
void SGRVinylRemoveMiniDisc(void);

// Returns the thumbnail transform that carries the mini disc into the full-size disc on lyrics close.
BOOL SGRVinylLyricsClosingTransform(UIView *thumbnail, CGAffineTransform *transform);

// Called every display-link tick to keep the vinyl and lyrics thumbnail at the same rotation.
void SGRVinylUpdateMiniDisc(CGFloat angle);

// Keeps Spotify's title row available beside the mini disc while lyrics are open and animates the
// full-size disc/tonearm away with that transition.
void SGRVinylLyricsDidChange(BOOL open, UIView *informationUnit);

// Keeps the Vinyl transport buttons in sync with the lyrics page's auto-hidden controls.
void SGRVinylLyricsControlsDidChange(CGFloat alpha);

// Spotify's artwork collection must remain hidden after the lyrics transition finishes in Vinyl mode.
void SGRVinylLyricsDidSettleClosed(void);
