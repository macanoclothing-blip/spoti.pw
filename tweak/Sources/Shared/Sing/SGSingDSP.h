#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "SGSingLevel.h"

typedef struct {
    float level, targetLevel, step;
    uint32_t remaining;
    double sampleRate;
} SGSingMixer;
// One render-thread owner. Control requests must be delivered atomically by the caller.
void SGSingMixerInit(SGSingMixer *mixer, double sampleRate, float level);
void SGSingMixerSetLevel(SGSingMixer *mixer, float level); // a 30 ms ramp to the new level
// Stereo interleaved. Original and vocals must have identical generation, format and source index.
// Bottom is instrumental, center is original, top is vocals.
void SGSingMixerProcess(SGSingMixer *mixer, const float *original, const float *vocals, float *output, uint32_t frames);
// A 120 ms ramp to the aligned original mix, no clock change: SGSingReserveFrames at 44.1 kHz.
void SGSingMixerBypass(SGSingMixer *mixer);
