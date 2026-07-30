#import "AudioUnitUIBridge.h"
#import <AudioToolbox/AUCocoaUIView.h>
#import <stdatomic.h>

static NSError *HLMError(OSStatus status, NSString *message) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSView *HLMCreateAudioUnitView(
    AudioUnit audioUnit,
    NSSize preferredSize,
    NSError **error
) {
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus status = AudioUnitGetPropertyInfo(
        audioUnit,
        kAudioUnitProperty_CocoaUI,
        kAudioUnitScope_Global,
        0,
        &size,
        &writable
    );
    if (status != noErr) {
        if (error) *error = HLMError(status, @"Headphone Lab did not advertise a Cocoa editor.");
        return nil;
    }

    AudioUnitCocoaViewInfo *info = malloc(size);
    status = AudioUnitGetProperty(
        audioUnit,
        kAudioUnitProperty_CocoaUI,
        kAudioUnitScope_Global,
        0,
        info,
        &size
    );
    if (status != noErr) {
        free(info);
        if (error) *error = HLMError(status, @"Could not read Headphone Lab’s editor information.");
        return nil;
    }

    NSURL *bundleURL = (__bridge NSURL *)info->mCocoaAUViewBundleLocation;
    NSString *className = (__bridge NSString *)info->mCocoaAUViewClass[0];
    NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
    [bundle load];
    Class factoryClass = [bundle classNamed:className];
    id<AUCocoaUIBase> factory = [[factoryClass alloc] init];
    NSView *view = [factory uiViewForAudioUnit:audioUnit withSize:preferredSize];

    CFRelease(info->mCocoaAUViewBundleLocation);
    CFRelease(info->mCocoaAUViewClass[0]);
    free(info);

    if (!view && error) {
        *error = HLMError(-1, @"Headphone Lab could not create its editor.");
    }
    return view;
}

struct HLMRing {
    float *left;
    float *right;
    uint32_t capacity;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
};

HLMRing *HLMRingCreate(uint32_t capacityFrames) {
    if (capacityFrames == 0) return NULL;
    HLMRing *ring = calloc(1, sizeof(HLMRing));
    if (!ring) return NULL;
    ring->left = calloc(capacityFrames, sizeof(float));
    ring->right = calloc(capacityFrames, sizeof(float));
    if (!ring->left || !ring->right) {
        free(ring->left);
        free(ring->right);
        free(ring);
        return NULL;
    }
    ring->capacity = capacityFrames;
    return ring;
}

void HLMRingDestroy(HLMRing *ring) {
    if (!ring) return;
    free(ring->left);
    free(ring->right);
    free(ring);
}

void HLMRingWrite(HLMRing *ring, const AudioBufferList *buffers, uint32_t frames) {
    if (!ring || !buffers || buffers->mNumberBuffers == 0) return;
    uint64_t write = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    if (write + frames - read > ring->capacity) {
        read = write + frames - ring->capacity;
        atomic_store_explicit(&ring->readIndex, read, memory_order_release);
    }
    const float *left = buffers->mBuffers[0].mData;
    const float *right = buffers->mNumberBuffers > 1
        ? buffers->mBuffers[1].mData
        : NULL;
    for (uint32_t frame = 0; frame < frames; frame++) {
        uint32_t slot = (uint32_t)((write + frame) % ring->capacity);
        if (right) {
            ring->left[slot] = left ? left[frame] : 0;
            ring->right[slot] = right[frame];
        } else {
            ring->left[slot] = left ? left[frame * 2] : 0;
            ring->right[slot] = left ? left[frame * 2 + 1] : 0;
        }
    }
    atomic_store_explicit(&ring->writeIndex, write + frames, memory_order_release);
}

void HLMRingRead(HLMRing *ring, AudioBufferList *buffers, uint32_t frames) {
    if (!ring || !buffers || buffers->mNumberBuffers == 0) return;
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    float *left = buffers->mBuffers[0].mData;
    float *right = buffers->mNumberBuffers > 1
        ? buffers->mBuffers[1].mData
        : NULL;
    for (uint32_t frame = 0; frame < frames; frame++) {
        float l = 0, r = 0;
        if (read < write) {
            uint32_t slot = (uint32_t)(read % ring->capacity);
            l = ring->left[slot];
            r = ring->right[slot];
            read++;
        }
        if (right) {
            left[frame] = l;
            right[frame] = r;
        } else {
            left[frame * 2] = l;
            left[frame * 2 + 1] = r;
        }
    }
    atomic_store_explicit(&ring->readIndex, read, memory_order_release);
}
