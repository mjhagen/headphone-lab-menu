#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

NSView * _Nullable HLMCreateAudioUnitView(
    AudioUnit audioUnit,
    NSSize preferredSize,
    NSError * _Nullable * _Nullable error
);

typedef struct HLMRing HLMRing;

HLMRing * _Nullable HLMRingCreate(uint32_t capacityFrames);
void HLMRingDestroy(HLMRing *ring);
void HLMRingWrite(HLMRing *ring, const AudioBufferList *buffers, uint32_t frames);
void HLMRingRead(HLMRing *ring, AudioBufferList *buffers, uint32_t frames);

NS_ASSUME_NONNULL_END
