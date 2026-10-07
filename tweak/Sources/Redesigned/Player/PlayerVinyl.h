// Vinyl mode: replaces the player's content area with a spinning vinyl record whose cover art is shown
// in the centre hole, and a tonearm that tracks song progress. The player's header (close + ⋯) is kept
// intact; everything else — artwork, controls, footer — is hidden and replaced with three pill buttons
// (Play/Pause, Prev, Next). The Canvas or Fluid field stays in the background, below the vinyl.
//
// The switch is spotifyglass.redesign.vinyl, read at launch, restart required.
// PlayerVinyl.x: the vinyl overlay view and all hooks.

#define SGRKeyPlayerVinyl @"spotifyglass.redesign.vinyl"

// The rows added to the player's settings page (NowPlayingBarSettings.m).
@class SGModSection;
SGModSection *SGRVinylSection(void);
