#include "HLMSpatialAudio.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK 128
#define FFT_SIZE 256
#define LOG_FFT 8
#define LINES 8

typedef struct { float real[FFT_SIZE], imag[FFT_SIZE]; } Spectrum;
typedef struct {
    float *data;
    uint32_t length, cursor;
    float low, broad, gainLow, gainMid, gainHigh;
} DelayLine;
typedef struct {
    float *data;
    uint32_t length, cursor;
} Diffuser;

struct HLMSpatialState {
    struct HLMSpatialState *nextRetired;
    double sampleRate;
    bool enabled;
    FFTSetup fft;
    uint32_t partitions, slot, cursor;
    Spectrum *filters; // [input * 2 + ear][partition]
    Spectrum *history; // [input][partition]
    Spectrum sum, temporary;
    float input[2][BLOCK], output[2][BLOCK], overlap[2][BLOCK];
    DelayLine lines[LINES];
    Diffuser diffusers[2][3];
    float lowPole, broadPole, lateGain;
    float sourceLowPole, sourceBroadPole, sourceGains[3];
    float sourceLow[2], sourceBroad[2];
};

struct HLMSpatialRenderer {
    double sampleRate;
    HLMSpatialState *active, *fading;
    _Atomic(HLMSpatialState *) pending;
    _Atomic(HLMSpatialState *) retired;
    uint32_t fadeFrame, fadeLength;
};

static float clampf(float x, float lo, float hi) { return fminf(hi, fmaxf(lo, x)); }
static DSPSplitComplex split(Spectrum *s) {
    return (DSPSplitComplex){s->real, s->imag};
}
static void destroyState(HLMSpatialState *s) {
    if (!s) return;
    if (s->fft) vDSP_destroy_fftsetup(s->fft);
    free(s->filters);
    free(s->history);
    for (int i = 0; i < LINES; ++i) free(s->lines[i].data);
    for (int channel = 0; channel < 2; ++channel)
        for (int i = 0; i < 3; ++i) free(s->diffusers[channel][i].data);
    free(s);
}

HLMRoomDecayTimes HLMSpatialRoomDecayTimes(float width, float depth, float height, float treatment) {
    width = clampf(width, 3, 12);
    depth = clampf(depth, 3, 16);
    height = clampf(height, 2.2f, 5);
    treatment = clampf(treatment, 0, 1);
    float volume = width * depth * height;
    float surface = 2 * (width * depth + width * height + depth * height);
    return (HLMRoomDecayTimes){
        clampf(0.161f * volume / (-surface * logf(1 - (0.10f + 0.30f*treatment))), 0.12f, 1.8f),
        clampf(0.161f * volume / (-surface * logf(1 - (0.15f + 0.65f*treatment))), 0.10f, 1.5f),
        clampf(0.161f * volume / (-surface * logf(1 - (0.22f + 0.65f*treatment))), 0.08f, 1.2f)
    };
}

HLMSpatialState *HLMSpatialStateCreate(
    double rate, const float *ir, uint32_t frames, bool enabled,
    float width, float depth, float height, float treatment, float amount
) {
    if (!isfinite(rate) || rate < 8000 || rate > 768000 || !ir
        || frames == 0 || frames > 65536 || !isfinite(width)
        || !isfinite(depth) || !isfinite(height) || !isfinite(treatment)
        || !isfinite(amount)) return NULL;
    for (size_t i = 0; i < (size_t)frames * 4; ++i)
        if (!isfinite(ir[i]) || fabsf(ir[i]) > 32) return NULL;
    HLMSpatialState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->sampleRate = rate;
    s->enabled = enabled;
    s->sourceGains[0] = s->sourceGains[1] = s->sourceGains[2] = 1;
    if (!enabled) return s; // bypass needs only its fixed-size delay block
    s->partitions = (frames + BLOCK - 1) / BLOCK;
    s->fft = vDSP_create_fftsetup(LOG_FFT, kFFTRadix2);
    s->filters = calloc((size_t)4 * s->partitions, sizeof(Spectrum));
    s->history = calloc((size_t)2 * s->partitions, sizeof(Spectrum));
    if (!s->fft || !s->filters || !s->history) goto fail;
    for (uint32_t path = 0; path < 4; ++path) {
        for (uint32_t part = 0; part < s->partitions; ++part) {
            Spectrum *filter = &s->filters[path * s->partitions + part];
            uint32_t start = part * BLOCK;
            uint32_t count = frames - start < BLOCK ? frames - start : BLOCK;
            memcpy(filter->real, ir + path * frames + start, count * sizeof(float));
            DSPSplitComplex z = split(filter);
            vDSP_fft_zip(s->fft, &z, 1, LOG_FFT, FFT_FORWARD);
        }
    }
    width = clampf(width, 3, 12);
    depth = clampf(depth, 3, 16);
    height = clampf(height, 2.2f, 5);
    treatment = clampf(treatment, 0, 1);
    float volume = width * depth * height;
    HLMRoomDecayTimes decay = HLMSpatialRoomDecayTimes(width, depth, height, treatment);
    const int referenceDelays[LINES] = {1493, 1601, 1867, 1999, 2131, 2371, 2683, 2939};
    float scale = cbrtf(volume / 75) * (float)(rate / 48000);
    for (int i = 0; i < LINES; ++i) {
        DelayLine *d = &s->lines[i];
        d->length = (uint32_t)fmaxf(127, roundf(referenceDelays[i] * scale)) | 1;
        d->data = calloc(d->length, sizeof(float));
        if (!d->data) goto fail;
        float seconds = d->length / (float)rate;
        d->gainLow = powf(0.001f, seconds / decay.low);
        d->gainMid = powf(0.001f, seconds / decay.mid);
        d->gainHigh = powf(0.001f, seconds / decay.high);
    }
    const int diffusionDelays[2][3] = {{149, 211, 263}, {157, 223, 277}};
    for (int channel = 0; channel < 2; ++channel) {
        for (int i = 0; i < 3; ++i) {
            Diffuser *d = &s->diffusers[channel][i];
            d->length = (uint32_t)fmaxf(11, diffusionDelays[channel][i] * scale) | 1;
            d->data = calloc(d->length, sizeof(float));
            if (!d->data) goto fail;
        }
    }
    s->lowPole = 1 - expf(-2 * (float)M_PI * 350 / (float)rate);
    s->broadPole = 1 - expf(-2 * (float)M_PI * 4000 / (float)rate);
    s->lateGain = enabled ? clampf(amount, 0, 1) * 0.14f : 0;
    return s;
fail:
    destroyState(s);
    return NULL;
}

void HLMSpatialStateSetLateSourceFilter(HLMSpatialState *s, float lowFrequency,
    float highFrequency, float lowGain, float midGain, float highGain) {
    if (!s || !isfinite(lowFrequency) || !isfinite(highFrequency) ||
        !isfinite(lowGain) || !isfinite(midGain) || !isfinite(highGain) ||
        lowFrequency <= 0 || highFrequency <= lowFrequency) return;
    s->sourceLowPole = 1 - expf(-2 * (float)M_PI * lowFrequency / (float)s->sampleRate);
    s->sourceBroadPole = 1 - expf(-2 * (float)M_PI * highFrequency / (float)s->sampleRate);
    s->sourceGains[0] = clampf(lowGain, 0, 1);
    s->sourceGains[1] = clampf(midGain, 0, 1);
    s->sourceGains[2] = clampf(highGain, 0, 1);
}

HLMSpatialRenderer *HLMSpatialCreate(double sampleRate) {
    if (!isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 768000) return NULL;
    HLMSpatialRenderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    if (!atomic_is_lock_free(&r->pending) || !atomic_is_lock_free(&r->retired)) {
        free(r); return NULL;
    }
    const float identity[4] = {1, 0, 0, 1};
    r->active = HLMSpatialStateCreate(sampleRate, identity, 1, false, 5, 6, 2.7f, 0.6f, 0);
    if (!r->active) { free(r); return NULL; }
    r->sampleRate = sampleRate;
    r->fadeLength = (uint32_t)(sampleRate * 0.05); // 50 ms linear, no correlated-signal boost
    return r;
}

void HLMSpatialCollect(HLMSpatialRenderer *r) {
    HLMSpatialState *s = atomic_exchange_explicit(&r->retired, NULL, memory_order_acquire);
    while (s) {
        HLMSpatialState *next = s->nextRetired;
        destroyState(s);
        s = next;
    }
}

void HLMSpatialPublish(HLMSpatialRenderer *r, HLMSpatialState *s) {
    if (s->sampleRate != r->sampleRate) { destroyState(s); return; }
    destroyState(atomic_exchange_explicit(&r->pending, s, memory_order_acq_rel));
    HLMSpatialCollect(r);
}

void HLMSpatialDestroy(HLMSpatialRenderer *r) {
    if (!r) return;
    destroyState(atomic_load_explicit(&r->pending, memory_order_relaxed));
    destroyState(r->active);
    destroyState(r->fading);
    HLMSpatialCollect(r);
    free(r);
}

static void retire(HLMSpatialRenderer *r, HLMSpatialState *s) {
    HLMSpatialState *head = atomic_load_explicit(&r->retired, memory_order_relaxed);
    do { s->nextRetired = head; }
    while (!atomic_compare_exchange_weak_explicit(&r->retired, &head, s,
                                                 memory_order_release, memory_order_relaxed));
}

static void convolve(HLMSpatialState *s) {
    for (uint32_t input = 0; input < 2; ++input) {
        Spectrum *x = &s->history[input * s->partitions + s->slot];
        memset(x, 0, sizeof(*x));
        memcpy(x->real, s->input[input], BLOCK * sizeof(float));
        DSPSplitComplex z = split(x);
        vDSP_fft_zip(s->fft, &z, 1, LOG_FFT, FFT_FORWARD);
    }
    for (uint32_t ear = 0; ear < 2; ++ear) {
        memset(&s->sum, 0, sizeof(s->sum));
        DSPSplitComplex sum = split(&s->sum);
        for (uint32_t input = 0; input < 2; ++input) {
            for (uint32_t part = 0; part < s->partitions; ++part) {
                uint32_t slot = (s->slot + s->partitions - part) % s->partitions;
                DSPSplitComplex x = split(&s->history[input * s->partitions + slot]);
                DSPSplitComplex h = split(&s->filters[(input*2 + ear) * s->partitions + part]);
                DSPSplitComplex tmp = split(&s->temporary);
                vDSP_zvmul(&x, 1, &h, 1, &tmp, 1, FFT_SIZE, 1);
                vDSP_zvadd(&sum, 1, &tmp, 1, &sum, 1, FFT_SIZE);
            }
        }
        vDSP_fft_zip(s->fft, &sum, 1, LOG_FFT, FFT_INVERSE);
        float scale = 1.0f / FFT_SIZE;
        vDSP_vsmul(s->sum.real, 1, &scale, s->sum.real, 1, FFT_SIZE);
        vDSP_vadd(s->sum.real, 1, s->overlap[ear], 1, s->output[ear], 1, BLOCK);
        memcpy(s->overlap[ear], s->sum.real + BLOCK, BLOCK * sizeof(float));
    }
    s->slot = (s->slot + 1) % s->partitions;
}

static float diffuse(HLMSpatialState *s, int channel, float x) {
    for (int i = 0; i < 3; ++i) {
        Diffuser *d = &s->diffusers[channel][i];
        float y = d->data[d->cursor] - 0.6f*x;
        float stored = x + 0.6f*y;
        d->data[d->cursor] = fabsf(stored) < 1e-20f ? 0 : stored;
        d->cursor = (d->cursor + 1) % d->length;
        x = y;
    }
    return x;
}

static float lateSource(HLMSpatialState *s, int channel, float x) {
    // Complementary bands, independent state for stereo / side-only input.
    if (s->sourceLowPole == 0) return x;
    s->sourceLow[channel] += s->sourceLowPole * (x - s->sourceLow[channel]);
    s->sourceBroad[channel] += s->sourceBroadPole * (x - s->sourceBroad[channel]);
    if (fabsf(s->sourceLow[channel]) < 1e-20f) s->sourceLow[channel] = 0;
    if (fabsf(s->sourceBroad[channel]) < 1e-20f) s->sourceBroad[channel] = 0;
    return s->sourceLow[channel]*s->sourceGains[0] +
        (s->sourceBroad[channel]-s->sourceLow[channel])*s->sourceGains[1] +
        (x-s->sourceBroad[channel])*s->sourceGains[2];
}

static void step(HLMSpatialState *s, float l, float r, float *outL, float *outR) {
    uint32_t n = s->cursor;
    *outL = s->output[0][n];
    *outR = s->output[1][n];
    if (s->lateGain > 0) {
        float feedback[LINES], wetL = 0, wetR = 0;
        float diffuseL = diffuse(s, 0, lateSource(s, 0, l)), diffuseR = diffuse(s, 1, lateSource(s, 1, r));
        // Orthogonal stereo injection/output vectors preserve side-only input.
        static const float inL[LINES] = {1,1,1,1,1,1,1,1};
        static const float inR[LINES] = {1,-1,1,-1,1,-1,1,-1};
        static const float decodeL[LINES] = {1,1,-1,-1,1,1,-1,-1};
        static const float decodeR[LINES] = {1,-1,-1,1,1,-1,-1,1};
        for (int i = 0; i < LINES; ++i) {
            DelayLine *d = &s->lines[i];
            float y = d->data[d->cursor];
            d->low += s->lowPole * (y - d->low);
            d->broad += s->broadPole * (y - d->broad);
            if (fabsf(d->low) < 1e-20f) d->low = 0;
            if (fabsf(d->broad) < 1e-20f) d->broad = 0;
            feedback[i] = d->low*d->gainLow + (d->broad-d->low)*d->gainMid
                        + (y-d->broad)*d->gainHigh;
            // Flush sub-audible tails to zero instead of entering denormal ranges.
            if (fabsf(feedback[i]) < 1e-20f) feedback[i] = 0;
            wetL += y * decodeL[i];
            wetR += y * decodeR[i];
        }
        // Dense orthogonal Hadamard mixing: every branch feeds every other
        // branch without changing energy. Input allpasses accelerate echo density.
        for (int stride = 1; stride < LINES; stride *= 2) {
            for (int base = 0; base < LINES; base += 2*stride) {
                for (int j = 0; j < stride; ++j) {
                    float a = feedback[base+j], b = feedback[base+j+stride];
                    feedback[base+j] = a+b;
                    feedback[base+j+stride] = a-b;
                }
            }
        }
        for (int i = 0; i < LINES; ++i) {
            DelayLine *d = &s->lines[i];
            d->data[d->cursor] = (feedback[i] + diffuseL*inL[i] + diffuseR*inR[i]) * 0.35355339f;
            d->cursor = (d->cursor + 1) % d->length;
        }
        *outL += wetL * s->lateGain * 0.35355339f;
        *outR += wetR * s->lateGain * 0.35355339f;
    }
    s->input[0][n] = l;
    s->input[1][n] = r;
    if (++s->cursor == BLOCK) {
        if (s->enabled) convolve(s);
        else {
            memcpy(s->output, s->input, sizeof(s->input));
        }
        s->cursor = 0;
    }
}

static void beginRender(HLMSpatialRenderer *r) {
    if (!r->fading) {
        HLMSpatialState *next = atomic_exchange_explicit(&r->pending, NULL, memory_order_acquire);
        if (next) {
            r->fading = r->active;
            r->active = next;
            r->fadeFrame = 0;
        }
    }
}

static void processSample(HLMSpatialRenderer *r, float l, float rr, float *outL, float *outR) {
    // Treat non-finite upstream samples as silence rather than poisoning tails.
    if (!isfinite(l)) l = 0;
    if (!isfinite(rr)) rr = 0;
    step(r->active, l, rr, outL, outR);
    if (r->fading) {
        float oldL, oldR;
        step(r->fading, l, rr, &oldL, &oldR);
        // Warm the new convolution for a full block before the crossfade starts.
        uint32_t elapsed = r->fadeFrame++;
        float mix = clampf(((float)elapsed - BLOCK) / r->fadeLength, 0, 1);
        *outL = oldL + (*outL - oldL)*mix;
        *outR = oldR + (*outR - oldR)*mix;
        if (elapsed >= BLOCK + r->fadeLength) {
            retire(r, r->fading);
            r->fading = NULL;
        }
    }
}

void HLMSpatialProcessPlanar(HLMSpatialRenderer *r, float *left, float *right, uint32_t frames) {
    if (frames) beginRender(r);
    for (uint32_t i = 0; i < frames; ++i) processSample(r, left[i], right[i], &left[i], &right[i]);
}

void HLMSpatialProcess(HLMSpatialRenderer *r, AudioBufferList *buffers, uint32_t frames) {
    if (!buffers || buffers->mNumberBuffers == 0 || !buffers->mBuffers[0].mData) return;
    float *left = buffers->mBuffers[0].mData;
    if (buffers->mNumberBuffers >= 2 && buffers->mBuffers[1].mData) {
        HLMSpatialProcessPlanar(r, left, buffers->mBuffers[1].mData, frames);
    } else if (buffers->mBuffers[0].mNumberChannels == 2) {
        if (frames) beginRender(r);
        for (uint32_t i = 0; i < frames; ++i)
            processSample(r, left[2*i], left[2*i+1], &left[2*i], &left[2*i+1]);
    }
}

uint32_t HLMSpatialLatencyFrames(void) { return BLOCK; }
