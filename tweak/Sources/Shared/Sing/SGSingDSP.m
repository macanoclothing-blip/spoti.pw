#include "SGSingDSP.h"
#include <math.h>

static const double kLevelRampSeconds = 0.030, kBypassRampSeconds = 0.120;

static void ramp(SGSingMixer *m, float to, double seconds) {
    m->targetLevel = to;
    m->remaining = (uint32_t)fmax(1, m->sampleRate * seconds);
    m->step = (to - m->level) / m->remaining;
}
void SGSingMixerInit(SGSingMixer *m, double rate, float level) {
    float clamped = SGSingClampLevel(level);
    *m = (SGSingMixer){.level = clamped, .targetLevel = clamped,
                      .sampleRate = isfinite(rate) && rate >= 8000 && rate <= 192000 ? rate : 44100};
}
void SGSingMixerSetLevel(SGSingMixer *m, float level) {
    float target = SGSingClampLevel(level);
    if (target != m->targetLevel) ramp(m, target, kLevelRampSeconds);
}
void SGSingMixerBypass(SGSingMixer *m) { ramp(m, SGSingOriginalMixLevel, kBypassRampSeconds); }
void SGSingMixerProcess(SGSingMixer *m, const float *original, const float *vocals, float *out, uint32_t frames) {
    for (uint32_t i = 0; i < frames; i++) {
        if (m->remaining) {
            m->level += m->step;
            if (!--m->remaining) m->level = m->targetLevel;
        }
        for (unsigned c = 0; c < 2; c++) {
            size_t at = (size_t)i * 2 + c;
            float source = isfinite(original[at]) ? original[at] : 0;
            float vocal = isfinite(vocals[at]) ? vocals[at] : 0;
            float value = m->level <= SGSingOriginalMixLevel
                ? source - (1 - 2 * m->level) * vocal
                : source + (2 * m->level - 1) * (vocal - source);
            out[at] = fmaxf(-1, fminf(1, value)); // bounded peak limiter, no per-stem normalization
        }
    }
}
