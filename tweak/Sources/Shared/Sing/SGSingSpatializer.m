#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "SGSingSpatializer.h"
#include "SGSingTimeline.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { kSpatialFrames = 1024 };

struct SGSingSpatializer {
    AudioUnit unit;
    AudioBufferList *output;
    float *mono, *silence, *left, *right;
    const float *input;
    uint32_t inputFrames, inputOffset;
    uint64_t sampleTime;
    BOOL initialized;
    atomic_bool enabled, ready, failed, headTrackingConfigured;
};

static OSStatus supplyVoice(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)flags; (void)time; (void)bus;
    SGSingSpatializer *s = context;
    if (!data || data->mNumberBuffers != 1 || !data->mBuffers[0].mData ||
        data->mBuffers[0].mNumberChannels != 1 || s->inputOffset > s->inputFrames ||
        frames > s->inputFrames - s->inputOffset)
        return kAudio_ParamError;
    uint32_t offset = s->inputOffset;
    for (uint32_t i = 0; i < frames; i++) {
        const float *stereo = s->input + (size_t)(offset + i) * 2;
        s->mono[offset + i] = (stereo[0] + stereo[1]) * 0.5f;
    }
    memcpy(data->mBuffers[0].mData, s->mono + offset, (size_t)frames * sizeof(float));
    data->mBuffers[0].mDataByteSize = frames * sizeof(float);
    s->inputOffset += frames;
    return noErr;
}

static BOOL setProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                        AudioUnitElement element, const void *value, UInt32 size) {
    return AudioUnitSetProperty(unit, property, scope, element, value, size) == noErr;
}

static AudioStreamBasicDescription format(UInt32 channels, BOOL nonInterleaved) {
    UInt32 bytesPerFrame = nonInterleaved ? sizeof(float) : channels * sizeof(float);
    return (AudioStreamBasicDescription){
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                        (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
        .mBytesPerPacket = bytesPerFrame,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = bytesPerFrame,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 32
    };
}

static AUSpatialMixerOutputType outputType(void) {
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs) {
        NSString *type = port.portType;
        if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
            [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE])
            return kSpatialMixerOutputType_Headphones;
        if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker] ||
            [type isEqualToString:AVAudioSessionPortBuiltInReceiver])
            return kSpatialMixerOutputType_BuiltInSpeakers;
    }
    return kSpatialMixerOutputType_ExternalSpeakers;
}

static BOOL prepareUnit(SGSingSpatializer *s) {
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_SpatialMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component || AudioComponentInstanceNew(component, &s->unit) != noErr) return NO;

    AudioStreamBasicDescription inputFormat = format(1, NO), outputFormat = format(2, YES);
    AURenderCallbackStruct callback = {.inputProc = supplyVoice, .inputProcRefCon = s};
    UInt32 algorithm = kSpatializationAlgorithm_UseOutputType;
    UInt32 sourceMode = kSpatialMixerSourceMode_PointSource;
    UInt32 selectedOutput = outputType();
    UInt32 noReverb = 0, maxFrames = kSpatialFrames;
    if (!setProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                     &inputFormat, sizeof(inputFormat)) ||
        !setProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                     &outputFormat, sizeof(outputFormat)) ||
        !setProperty(s->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                     &callback, sizeof(callback)) ||
        !setProperty(s->unit, kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0,
                     &algorithm, sizeof(algorithm)) ||
        !setProperty(s->unit, kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, 0,
                     &sourceMode, sizeof(sourceMode)) ||
        !setProperty(s->unit, kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0,
                     &selectedOutput, sizeof(selectedOutput)) ||
        !setProperty(s->unit, kAudioUnitProperty_UsesInternalReverb, kAudioUnitScope_Global, 0,
                     &noReverb, sizeof(noReverb)) ||
        !setProperty(s->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                     &maxFrames, sizeof(maxFrames)))
        return NO;

    UInt32 renderingFlags = kSpatialMixerRenderingFlags_InterAuralDelay;
    if (!setProperty(s->unit, kAudioUnitProperty_SpatialMixerRenderingFlags, kAudioUnitScope_Input, 0,
                     &renderingFlags, sizeof(renderingFlags)))
        return NO;

    if (AudioUnitSetParameter(s->unit, kSpatialMixerParam_Azimuth, kAudioUnitScope_Input, 0, 0, 0) != noErr ||
        AudioUnitSetParameter(s->unit, kSpatialMixerParam_Elevation, kAudioUnitScope_Input, 0, 0, 0) != noErr ||
        AudioUnitSetParameter(s->unit, kSpatialMixerParam_Distance, kAudioUnitScope_Input, 0, 1, 0) != noErr)
        return NO;

    UInt32 tracking = 1;
    if (@available(iOS 18.0, *)) {
        atomic_store(&s->headTrackingConfigured,
                     setProperty(s->unit, kAudioUnitProperty_SpatialMixerEnableHeadTracking,
                                 kAudioUnitScope_Global, 0, &tracking, sizeof(tracking)));
    }
    if (@available(iOS 18.0, *)) {
        UInt32 personalized = kSpatialMixerPersonalizedHRTFMode_Auto;
        AudioUnitSetProperty(s->unit, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,
                             kAudioUnitScope_Global, 0, &personalized, sizeof(personalized));
    }

    if (AudioUnitInitialize(s->unit) != noErr) return NO;
    s->initialized = YES;
    Float64 latency = 0;
    UInt32 latencySize = sizeof(latency);
    if (AudioUnitGetProperty(s->unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                             &latency, &latencySize) != noErr ||
        !isfinite(latency) || latency > 0.5 / 44100.0)
        return NO;

    struct { AudioBufferList list; AudioBuffer unused; } outputBuffers = {0};
    outputBuffers.list.mNumberBuffers = 2;
    float warmLeft[16] = {0}, warmRight[16] = {0};
    outputBuffers.list.mBuffers[0] = (AudioBuffer){1, sizeof(warmLeft), warmLeft};
    outputBuffers.list.mBuffers[1] = (AudioBuffer){1, sizeof(warmRight), warmRight};
    s->input = s->silence;
    s->inputFrames = 16;
    s->inputOffset = 0;
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time = {.mSampleTime = 0, .mFlags = kAudioTimeStampSampleTimeValid};
    OSStatus status = AudioUnitRender(s->unit, &flags, &time, 0, 16, &outputBuffers.list);
    s->input = NULL;
    if (status != noErr || s->inputOffset != 16) return NO;
    s->sampleTime = 16;
    return YES;
}

SGSingSpatializer *SGSingSpatializerCreate(void) {
    SGSingSpatializer *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->mono = calloc(kSpatialFrames, sizeof(float));
    s->silence = calloc((size_t)kSpatialFrames * 2, sizeof(float));
    s->left = calloc(kSpatialFrames, sizeof(float));
    s->right = calloc(kSpatialFrames, sizeof(float));
    s->output = calloc(1, sizeof(*s->output));
    if (!s->mono || !s->silence || !s->left || !s->right || !s->output) {
        SGSingSpatializerDestroy(s);
        return NULL;
    }
    return s;
}

bool SGSingSpatializerPrepare(SGSingSpatializer *s) {
    if (!s || atomic_load(&s->failed)) return false;
    if (atomic_load(&s->ready)) return true;
    if (!prepareUnit(s)) {
        atomic_store(&s->failed, true);
        atomic_store(&s->enabled, false);
        return false;
    }
    atomic_store(&s->ready, true);
    return true;
}

bool SGSingSpatializerSetEnabled(SGSingSpatializer *s, bool enabled) {
    if (!s) return !enabled;
    if (!enabled) { atomic_store(&s->enabled, false); return true; }
    if (!atomic_load(&s->ready) || atomic_load(&s->failed)) return false;
    atomic_store(&s->enabled, true);
    return true;
}

bool SGSingSpatializerReady(const SGSingSpatializer *s) {
    return s && atomic_load(&s->ready);
}

bool SGSingSpatializerFailed(const SGSingSpatializer *s) {
    return s && atomic_load(&s->failed);
}

bool SGSingSpatializerHeadTrackingConfigured(const SGSingSpatializer *s) {
    return s && atomic_load(&s->headTrackingConfigured);
}

bool SGSingSpatializerRender(void *context, const float *input, float *output,
                             uint32_t frames, uint64_t sourceFrame) {
    (void)sourceFrame;
    SGSingSpatializer *s = context;
    if (!s || !input || !output || !frames || frames > kSpatialFrames ||
        !atomic_load(&s->enabled) || !atomic_load(&s->ready) || atomic_load(&s->failed))
        return false;

    s->input = input;
    s->inputFrames = frames;
    s->inputOffset = 0;
    s->output->mNumberBuffers = 2;
    s->output->mBuffers[0] = (AudioBuffer){1, frames * sizeof(float), s->left};
    s->output->mBuffers[1] = (AudioBuffer){1, frames * sizeof(float), s->right};
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time = {.mSampleTime = (Float64)s->sampleTime, .mFlags = kAudioTimeStampSampleTimeValid};
    OSStatus status = AudioUnitRender(s->unit, &flags, &time, 0, frames, s->output);
    s->sampleTime += frames;
    s->input = NULL;
    if (status != noErr || s->inputOffset != frames) {
        atomic_store(&s->failed, true);
        atomic_store(&s->enabled, false);
        return false;
    }
    for (uint32_t i = 0; i < frames; i++) {
        output[i * 2] = s->left[i];
        output[i * 2 + 1] = s->right[i];
    }
    return true;
}

void SGSingSpatializerDestroy(SGSingSpatializer *s) {
    if (!s) return;
    atomic_store(&s->enabled, false);
    if (s->unit && s->initialized) AudioUnitUninitialize(s->unit);
    if (s->unit) {
        AudioComponentInstanceDispose(s->unit);
    }
    free(s->output);
    free(s->right);
    free(s->left);
    free(s->silence);
    free(s->mono);
    free(s);
}
