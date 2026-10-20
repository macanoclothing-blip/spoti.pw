#import "Settings/SGModPage.h"

#define SGKeyMusicRecognition @"spotifyglass.musicRecognition.enabled"

SGModSection *SGMusicRecognitionSection(void);
// Starts the same explicit, time-limited listening session used by the Player settings row.
void SGMusicRecognitionStart(void);
