#import "AudioUnitUIBridge.h"
#import <math.h>
#import <stdatomic.h>
#import <string.h>

struct HLMRing {
    float *left;
    float *right;
    uint32_t capacity;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint32_t peakBits;
};

static void HLMRingRecordPeak(HLMRing *ring, float peak) {
    uint32_t candidate;
    memcpy(&candidate, &peak, sizeof(candidate));
    uint32_t current = atomic_load_explicit(&ring->peakBits, memory_order_relaxed);
    float currentPeak;
    memcpy(&currentPeak, &current, sizeof(currentPeak));
    while (peak > currentPeak
           && !atomic_compare_exchange_weak_explicit(
               &ring->peakBits,
               &current,
               candidate,
               memory_order_release,
               memory_order_relaxed)) {
        memcpy(&currentPeak, &current, sizeof(currentPeak));
    }
}

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
    uint64_t used = write - read;
    uint32_t available = used < ring->capacity
        ? ring->capacity - (uint32_t)used
        : 0;
    uint32_t framesToWrite = frames < available ? frames : available;
    if (framesToWrite == 0) return;
    const float *left = buffers->mBuffers[0].mData;
    const float *right = buffers->mNumberBuffers > 1
        ? buffers->mBuffers[1].mData
        : NULL;
    for (uint32_t frame = 0; frame < framesToWrite; frame++) {
        uint32_t slot = (uint32_t)((write + frame) % ring->capacity);
        if (right) {
            ring->left[slot] = left ? left[frame] : 0;
            ring->right[slot] = right[frame];
        } else {
            ring->left[slot] = left ? left[frame * 2] : 0;
            ring->right[slot] = left ? left[frame * 2 + 1] : 0;
        }
    }
    atomic_store_explicit(&ring->writeIndex, write + framesToWrite, memory_order_release);
}

void HLMRingWriteAnalyzed(
    HLMRing *ring,
    const AudioBufferList *buffers,
    uint32_t frames
) {
    if (!ring || !buffers || buffers->mNumberBuffers == 0) return;
    const float *inputLeft = buffers->mBuffers[0].mData;
    const float *inputRight = buffers->mNumberBuffers > 1
        ? buffers->mBuffers[1].mData
        : NULL;
    float peak = 0;
    for (uint32_t frame = 0; frame < frames; frame++) {
        float left = inputLeft
            ? inputLeft[inputRight ? frame : frame * 2]
            : 0;
        float right = inputRight
            ? inputRight[frame]
            : (inputLeft ? inputLeft[frame * 2 + 1] : 0);
        peak = fmaxf(peak, fmaxf(fabsf(left), fabsf(right)));
    }
    HLMRingRecordPeak(ring, peak);
    HLMRingWrite(ring, buffers, frames);
}

uint32_t HLMRingAvailable(const HLMRing *ring) {
    if (!ring) return 0;
    uint64_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint64_t available = write - read;
    return available < ring->capacity ? (uint32_t)available : ring->capacity;
}

uint32_t HLMRingReadMono(HLMRing *ring, float *samples, uint32_t maximumFrames) {
    if (!ring || !samples || maximumFrames == 0) return 0;
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint64_t available = write - read;
    uint32_t frames = available < maximumFrames ? (uint32_t)available : maximumFrames;
    for (uint32_t frame = 0; frame < frames; frame++) {
        uint32_t slot = (uint32_t)((read + frame) % ring->capacity);
        samples[frame] = (ring->left[slot] + ring->right[slot]) * 0.5f;
    }
    atomic_store_explicit(&ring->readIndex, read + frames, memory_order_release);
    return frames;
}

float HLMRingTakePeak(HLMRing *ring) {
    if (!ring) return 0;
    uint32_t bits = atomic_exchange_explicit(&ring->peakBits, 0, memory_order_acq_rel);
    float peak;
    memcpy(&peak, &bits, sizeof(peak));
    return peak;
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
