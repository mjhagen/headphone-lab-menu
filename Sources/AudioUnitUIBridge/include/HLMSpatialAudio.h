#ifndef HLM_SPATIAL_AUDIO_H
#define HLM_SPATIAL_AUDIO_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HLMSpatialRenderer HLMSpatialRenderer;
typedef struct HLMSpatialState HLMSpatialState;

typedef struct { float low, mid, high; } HLMRoomDecayTimes;
// Shared Eyring model used by the FDN and its visualization, in seconds.
HLMRoomDecayTimes HLMSpatialRoomDecayTimes(float width, float depth,
                                         float height, float treatment);

// All construction, publication, collection, and destruction are control-thread
// operations. One serialized producer; one audio consumer. Stop audio before
// destroying the renderer. Publish transfers state ownership to the renderer.
HLMSpatialRenderer * _Nullable HLMSpatialCreate(double sampleRate);
void HLMSpatialDestroy(HLMSpatialRenderer * _Nullable renderer);
HLMSpatialState * _Nullable HLMSpatialStateCreate(
    double sampleRate, const float * _Nonnull matrixIR, uint32_t frames,
    bool enabled, float width, float depth, float height,
    float treatment, float roomAmount);
// Optional diffuse-field source-power approximation. Call only on an unpublished
// state, on the control thread. Defaults to unity for callers supplying raw IRs.
void HLMSpatialStateSetLateSourceFilter(HLMSpatialState * _Nonnull state,
    float lowFrequency, float highFrequency, float lowGain, float midGain, float highGain);
void HLMSpatialPublish(HLMSpatialRenderer * _Nonnull renderer,
                       HLMSpatialState * _Nonnull state);
void HLMSpatialCollect(HLMSpatialRenderer * _Nonnull renderer);

// In-place, allocation-free, lock-free processing. Exactly 128 frames of
// algorithmic latency, also in bypass, so live transitions stay time-aligned.
void HLMSpatialProcess(HLMSpatialRenderer * _Nonnull renderer,
                       AudioBufferList * _Nonnull buffers, uint32_t frames);
void HLMSpatialProcessPlanar(HLMSpatialRenderer * _Nonnull renderer,
                             float * _Nonnull left, float * _Nonnull right,
                             uint32_t frames);
uint32_t HLMSpatialLatencyFrames(void);

#ifdef __cplusplus
}
#endif
#endif
