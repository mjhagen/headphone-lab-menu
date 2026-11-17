#ifndef HLM_LIVE_AUDIO_H
#define HLM_LIVE_AUDIO_H
#include "HLMSpatialAudio.h"
#include <stdint.h>

#define HLM_LIVE_SCOPE_BINS 32

typedef struct HLMLiveMonitor HLMLiveMonitor;
typedef struct {
    uint64_t endFrame;
    uint32_t generation;
    uint32_t frameCount;
    float inputRMS[2];
    float inputBandRMS[2][3]; // 125 Hz, 1 kHz, 4 kHz bandpass analysis centers
    float outputRMS[2];
    float outputPeak[2];
    float outputMinimum[2][HLM_LIVE_SCOPE_BINS];
    float outputMaximum[2][HLM_LIVE_SCOPE_BINS];
} HLMLiveAudioFrame;

HLMLiveMonitor * _Nullable HLMLiveMonitorCreate(double sampleRate);
// Stop audio before destroying. SetEnabled and Read have one UI/control caller.
void HLMLiveMonitorDestroy(HLMLiveMonitor * _Nullable monitor);
void HLMLiveMonitorSetEnabled(HLMLiveMonitor * _Nonnull monitor, bool enabled);
uint32_t HLMLiveMonitorGeneration(const HLMLiveMonitor * _Nonnull monitor);
uint64_t HLMLiveMonitorCurrentFrame(const HLMLiveMonitor * _Nonnull monitor);
uint32_t HLMLiveMonitorRead(HLMLiveMonitor * _Nonnull monitor,
                          HLMLiveAudioFrame * _Nonnull frames, uint32_t capacity);
// Replaces HLMSpatialProcess at the source node. Bounded stack storage, no locks
// or allocations. When disabled it goes directly through HLMSpatialProcess.
void HLMLiveMonitorProcess(HLMLiveMonitor * _Nonnull monitor,
                           HLMSpatialRenderer * _Nonnull renderer,
                           AudioBufferList * _Nonnull buffers, uint32_t frames);
#endif
