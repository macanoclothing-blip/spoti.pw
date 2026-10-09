// Vinyl mode: overlays the Canvas or Fluid field with the bundled marbled disc texture, tinted from
// the cover palette, and the bundled tonearm image. The disc sits left of centre (partly cropped),
// shows the current cover in its label and spins only during playback. The player's header (close + ⋯)
// is kept intact; everything else — artwork, controls, footer — is hidden and replaced with four
// tappable pill buttons (Play/Pause, Lyrics, Prev, Next).
//
// When Lyrics are open, the redesigned lyrics view is shown normally, but the album cover thumbnail
// in the top-left is replaced by a mini spinning vinyl disc. Tapping it returns to the vinyl view.
//
// The switch is spotifyglass.redesign.vinyl, read at launch, restart required.
// PlayerVinyl.x: the vinyl overlay view, mini disc and all hooks.

#define SGRKeyPlayerVinyl @"spotifyglass.redesign.vinyl"

// The rows added to the player's settings page (NowPlayingBarSettings.m).
@class SGModSection;
SGModSection *SGRVinylSection(void);

// Called by PlayerLyrics.x (setOpen) to install/remove the mini spinning vinyl on the lyrics thumbnail.
// `face` is SGRPlayerLyricsThumb.face; `cover` is the UIImageView inside it to hide.
// Call with nil,nil to just refresh artwork on an already-installed mini disc.
void SGRVinylInstallMiniDisc(UIView *face, UIImageView *cover);
void SGRVinylRemoveMiniDisc(void);

// Called every display-link tick when lyrics are open, to keep the mini disc spinning.
void SGRVinylUpdateMiniDisc(CGFloat angle);
