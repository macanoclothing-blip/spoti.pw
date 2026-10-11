#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct SGSingSpatializer SGSingSpatializer;

SGSingSpatializer *SGSingSpatializerCreate(void);
void SGSingSpatializerDestroy(SGSingSpatializer *spatializer); // call after the render endpoint has detached
bool SGSingSpatializerPrepare(SGSingSpatializer *spatializer); // serialized control queue only
bool SGSingSpatializerSetEnabled(SGSingSpatializer *spatializer, bool enabled); // lock-free, any thread
bool SGSingSpatializerReady(const SGSingSpatializer *spatializer);
bool SGSingSpatializerFailed(const SGSingSpatializer *spatializer);
bool SGSingSpatializerHeadTrackingConfigured(const SGSingSpatializer *spatializer);
bool SGSingSpatializerRender(void *context, const float *inputStereo, float *outputStereo,
                             uint32_t frames, uint64_t sourceFrame);
