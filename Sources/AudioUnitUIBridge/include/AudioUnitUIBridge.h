#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct HLMRing HLMRing;

HLMRing * _Nullable HLMRingCreate(uint32_t capacityFrames);
void HLMRingDestroy(HLMRing *ring);
void HLMRingWrite(HLMRing *ring, const AudioBufferList *buffers, uint32_t frames);
void HLMRingWriteAnalyzed(HLMRing *ring, const AudioBufferList *buffers, uint32_t frames);
void HLMRingRead(HLMRing *ring, AudioBufferList *buffers, uint32_t frames);
uint32_t HLMRingAvailable(const HLMRing *ring);
uint32_t HLMRingReadMono(HLMRing *ring, float *samples, uint32_t maximumFrames);
float HLMRingTakePeak(HLMRing *ring);

NS_ASSUME_NONNULL_END
