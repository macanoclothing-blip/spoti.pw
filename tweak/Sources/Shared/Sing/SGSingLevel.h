// The control moves from instrumental, through the original mix, to isolated vocals.
// Shared by UI, controller and mixer so touch, accessibility and programmatic changes agree.
#pragma once
#include <math.h>

#define SGSingMinimumLevel 0.0f
#define SGSingOriginalMixLevel 0.5f
static inline float SGSingClampLevel(float value) {
    return isfinite(value) ? fmaxf(SGSingMinimumLevel, fminf(1, value)) : SGSingOriginalMixLevel;
}
static inline float SGSingLevelFromPosition(float position) {
    return SGSingClampLevel(position);
}
static inline float SGSingPositionFromLevel(float level) {
    return SGSingClampLevel(level);
}
