#include "HLMLiveAudio.h"
#include <float.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define QUEUE_SIZE 128
#define CHUNK 128

typedef struct { float b0,b2,a1,a2,x1,x2,y1,y2; } Bandpass;
struct HLMLiveMonitor {
    double sampleRate;
    uint32_t quantum, bucketCount, lastGeneration;
    uint64_t audioClock;
    _Atomic bool enabled;
    _Atomic uint32_t generation;
    _Atomic uint64_t currentFrame, readIndex, writeIndex;
    Bandpass filters[2][3];
    double inputEnergy[2], bandEnergy[2][3], outputEnergy[2];
    HLMLiveAudioFrame bucket;
    HLMLiveAudioFrame queue[QUEUE_SIZE];
};

static float finiteSample(float x) { return isfinite(x) ? fmaxf(-1e6f,fminf(1e6f,x)) : 0; }
static float filter(Bandpass *b, float x) {
    float y = b->b0*x+b->b2*b->x2-b->a1*b->y1-b->a2*b->y2;
    if (fabsf(y)<1e-20f) y = 0;
    b->x2=b->x1; b->x1=x; b->y2=b->y1; b->y1=y;
    return y;
}
static void clearBucket(HLMLiveMonitor *m) {
    memset(&m->bucket,0,sizeof(m->bucket));
    memset(m->inputEnergy,0,sizeof(m->inputEnergy));
    memset(m->bandEnergy,0,sizeof(m->bandEnergy));
    memset(m->outputEnergy,0,sizeof(m->outputEnergy));
    for(int ear=0;ear<2;++ear)
        for(int bin=0;bin<HLM_LIVE_SCOPE_BINS;++bin) {
            m->bucket.outputMinimum[ear][bin]=FLT_MAX;
            m->bucket.outputMaximum[ear][bin]=-FLT_MAX;
        }
    m->bucketCount=0;
}
HLMLiveMonitor *HLMLiveMonitorCreate(double rate) {
    if(!isfinite(rate)||rate<8000||rate>768000) return NULL;
    HLMLiveMonitor *m=calloc(1,sizeof(*m));
    if(!m) return NULL;
    m->sampleRate=rate;
    m->quantum=(uint32_t)llround(rate*0.01);
    atomic_init(&m->enabled,false);
    atomic_init(&m->generation,0);
    atomic_init(&m->currentFrame,0);
    atomic_init(&m->readIndex,0);
    atomic_init(&m->writeIndex,0);
    if(!atomic_is_lock_free(&m->enabled)||!atomic_is_lock_free(&m->currentFrame)
       ||!atomic_is_lock_free(&m->readIndex)||!atomic_is_lock_free(&m->writeIndex)
       ||!atomic_is_lock_free(&m->generation)) { free(m); return NULL; }
    const float frequencies[3]={125,1000,4000};
    for(int channel=0;channel<2;++channel)
        for(int band=0;band<3;++band) {
            float frequency=fminf(frequencies[band],(float)rate*0.4f);
            float omega=2*(float)M_PI*frequency/(float)rate;
            float alpha=sinf(omega)/(2*0.70710678f);
            Bandpass *b=&m->filters[channel][band];
            b->b0=alpha/(1+alpha); b->b2=-b->b0;
            b->a1=-2*cosf(omega)/(1+alpha); b->a2=(1-alpha)/(1+alpha);
        }
    clearBucket(m);
    return m;
}
void HLMLiveMonitorDestroy(HLMLiveMonitor *m) { free(m); }
void HLMLiveMonitorSetEnabled(HLMLiveMonitor *m,bool enabled) {
    if(enabled) {
        if(atomic_load_explicit(&m->enabled,memory_order_relaxed)) return;
        // This is also the queue's sole consumer. Discard hidden-window backlog.
        uint64_t w=atomic_load_explicit(&m->writeIndex,memory_order_acquire);
        atomic_store_explicit(&m->readIndex,w,memory_order_release);
        atomic_fetch_add_explicit(&m->generation,1,memory_order_release);
    }
    atomic_store_explicit(&m->enabled,enabled,memory_order_release);
}
uint32_t HLMLiveMonitorGeneration(const HLMLiveMonitor *m) {
    return atomic_load_explicit(&m->generation,memory_order_acquire);
}
uint64_t HLMLiveMonitorCurrentFrame(const HLMLiveMonitor *m) {
    return atomic_load_explicit(&m->currentFrame,memory_order_acquire);
}
uint32_t HLMLiveMonitorRead(HLMLiveMonitor *m,HLMLiveAudioFrame *frames,uint32_t capacity) {
    uint64_t r=atomic_load_explicit(&m->readIndex,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&m->writeIndex,memory_order_acquire);
    uint32_t count=(uint32_t)fmin((double)(w-r),(double)capacity);
    for(uint32_t i=0;i<count;++i) frames[i]=m->queue[(r+i)%QUEUE_SIZE];
    atomic_store_explicit(&m->readIndex,r+count,memory_order_release);
    return count;
}
static void record(HLMLiveMonitor *m,float il,float ir,float ol,float oright) {
    float input[2]={finiteSample(il),finiteSample(ir)};
    float output[2]={finiteSample(ol),finiteSample(oright)};
    uint32_t bin=m->bucketCount*HLM_LIVE_SCOPE_BINS/m->quantum;
    if(bin>=HLM_LIVE_SCOPE_BINS) bin=HLM_LIVE_SCOPE_BINS-1;
    for(int c=0;c<2;++c) {
        m->inputEnergy[c]+=(double)input[c]*input[c];
        m->outputEnergy[c]+=(double)output[c]*output[c];
        m->bucket.outputPeak[c]=fmaxf(m->bucket.outputPeak[c],fabsf(output[c]));
        m->bucket.outputMinimum[c][bin]=fminf(m->bucket.outputMinimum[c][bin],output[c]);
        m->bucket.outputMaximum[c][bin]=fmaxf(m->bucket.outputMaximum[c][bin],output[c]);
        for(int band=0;band<3;++band) {
            float y=filter(&m->filters[c][band],input[c]);
            m->bandEnergy[c][band]+=(double)y*y;
        }
    }
    ++m->audioClock;
    if(++m->bucketCount<m->quantum) return;
    m->bucket.endFrame=m->audioClock;
    m->bucket.generation=m->lastGeneration;
    m->bucket.frameCount=m->bucketCount;
    for(int c=0;c<2;++c) {
        m->bucket.inputRMS[c]=(float)sqrt(m->inputEnergy[c]/m->bucketCount);
        m->bucket.outputRMS[c]=(float)sqrt(m->outputEnergy[c]/m->bucketCount);
        for(int band=0;band<3;++band)
            m->bucket.inputBandRMS[c][band]=(float)sqrt(m->bandEnergy[c][band]/m->bucketCount);
    }
    uint64_t w=atomic_load_explicit(&m->writeIndex,memory_order_relaxed);
    uint64_t r=atomic_load_explicit(&m->readIndex,memory_order_acquire);
    if(w-r<QUEUE_SIZE) {
        m->queue[w%QUEUE_SIZE]=m->bucket;
        atomic_store_explicit(&m->writeIndex,w+1,memory_order_release);
    }
    clearBucket(m);
}
void HLMLiveMonitorProcess(HLMLiveMonitor *m,HLMSpatialRenderer *renderer,
                           AudioBufferList *buffers,uint32_t frames) {
    if(!atomic_load_explicit(&m->enabled,memory_order_acquire)) {
        HLMSpatialProcess(renderer,buffers,frames);
        m->audioClock+=frames;
        atomic_store_explicit(&m->currentFrame,m->audioClock,memory_order_release);
        return;
    }
    uint32_t generation=atomic_load_explicit(&m->generation,memory_order_acquire);
    if(generation!=m->lastGeneration) {
        clearBucket(m);
        for(int c=0;c<2;++c) for(int b=0;b<3;++b) {
            Bandpass *f=&m->filters[c][b]; f->x1=f->x2=f->y1=f->y2=0;
        }
        m->lastGeneration=generation;
    }
    if(!buffers||!buffers->mNumberBuffers||!buffers->mBuffers[0].mData) return;
    float *l=buffers->mBuffers[0].mData;
    float *r=buffers->mNumberBuffers>=2?buffers->mBuffers[1].mData:NULL;
    bool interleaved=!r&&buffers->mBuffers[0].mNumberChannels==2;
    if(!r&&!interleaved) { HLMSpatialProcess(renderer,buffers,frames); return; }
    float inputL[CHUNK],inputR[CHUNK],outputL[CHUNK],outputR[CHUNK];
    for(uint32_t offset=0;offset<frames;offset+=CHUNK) {
        uint32_t count=frames-offset<CHUNK?frames-offset:CHUNK;
        for(uint32_t i=0;i<count;++i) {
            inputL[i]=interleaved?l[2*(offset+i)]:l[offset+i];
            inputR[i]=interleaved?l[2*(offset+i)+1]:r[offset+i];
            outputL[i]=inputL[i]; outputR[i]=inputR[i];
        }
        HLMSpatialProcessPlanar(renderer,outputL,outputR,count);
        for(uint32_t i=0;i<count;++i) {
            record(m,inputL[i],inputR[i],outputL[i],outputR[i]);
            if(interleaved) { l[2*(offset+i)]=outputL[i]; l[2*(offset+i)+1]=outputR[i]; }
            else { l[offset+i]=outputL[i]; r[offset+i]=outputR[i]; }
        }
    }
    atomic_store_explicit(&m->currentFrame,m->audioClock,memory_order_release);
}
