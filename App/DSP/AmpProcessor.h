#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AmpMeterState {
    float inputPeak;
    float outputPeak;
    float inputRmsDb;
    float inputPeakDb;
    float noiseFloorDb;
    bool inputClip;
    bool outputClip;
    float tunerHz;
    float tunerConfidence;
} AmpMeterState;

typedef struct AmpAudioFIFOStats {
    uint64_t writtenFrames;
    uint64_t readFrames;
    uint64_t overflowFrames;
    uint64_t underflowFrames;
    int availableFrames;
} AmpAudioFIFOStats;

typedef struct AmpRecorderStateSnapshot {
    bool armed;
    bool recordBassOnly;
    bool writing;
    int64_t recordedFrames;
    float peak;
    bool capturingSystemOutput;
} AmpRecorderStateSnapshot;

void *AmpProcessorShared(void);

bool AmpProcessorLoadNAM(void *p, const char *path, char *err, int errLen);
void AmpProcessorUnloadNAM(void *p);
bool AmpProcessorHasNAM(void *p);
double AmpProcessorNAMSampleRate(void *p);

bool AmpProcessorLoadIR(void *p, const float *samples, int length, double sampleRate);
void AmpProcessorUnloadIR(void *p);
bool AmpProcessorHasIR(void *p);

void AmpProcessorReset(void *p, double sampleRate, int maxBlock);
void AmpProcessorProcess(void *p, const float *input, float *output, int frames);

void AmpProcessorSetInputGainDb(void *p, float db);
void AmpProcessorSetOutputGainDb(void *p, float db);
void AmpProcessorSetGateThresholdDb(void *p, float db);
void AmpProcessorSetBassDb(void *p, float db);
void AmpProcessorSetMidDb(void *p, float db);
void AmpProcessorSetTrebleDb(void *p, float db);
void AmpProcessorSetMidFreqIndex(void *p, int index);
void AmpProcessorSetUltraLoOn(void *p, bool on);
void AmpProcessorSetUltraHiOn(void *p, bool on);
void AmpProcessorSetGateOn(void *p, bool on);
void AmpProcessorSetExpanderOn(void *p, bool on);
void AmpProcessorSetNROn(void *p, bool on);
void AmpProcessorSetNAMOn(void *p, bool on);
void AmpProcessorSetCleanAmpOn(void *p, bool on);
bool AmpProcessorCleanAmpOn(void *p);
void AmpProcessorSetIROn(void *p, bool on);
void AmpProcessorSetEQOn(void *p, bool on);
void AmpProcessorSetBypass(void *p, bool on);
void AmpProcessorSetTunerMute(void *p, bool on);

void AmpProcessorSetCompOn(void *p, bool on);
void AmpProcessorSetCompThresholdDb(void *p, float db);
void AmpProcessorSetCompRatio(void *p, float ratio);
void AmpProcessorSetCompMakeupDb(void *p, float db);

void AmpProcessorSetDriveOn(void *p, bool on);
void AmpProcessorSetDriveAmount(void *p, float amount);
void AmpProcessorSetDriveTone(void *p, float tone);
void AmpProcessorSetDriveMix(void *p, float mix);

void AmpProcessorSetOctaverOn(void *p, bool on);
void AmpProcessorSetOctaverMix(void *p, float mix);
void AmpProcessorSetOctaverTone(void *p, float tone);

void AmpProcessorSetEnvelopeOn(void *p, bool on);
void AmpProcessorSetEnvelopeSensitivity(void *p, float sensitivity);
void AmpProcessorSetEnvelopeResonance(void *p, float resonance);
void AmpProcessorSetEnvelopeMix(void *p, float mix);

void AmpProcessorSetUtilityFilterOn(void *p, bool on);
void AmpProcessorSetHighPassHz(void *p, float hz);
void AmpProcessorSetLowPassHz(void *p, float hz);

void AmpProcessorSetChorusOn(void *p, bool on);
void AmpProcessorSetChorusRate(void *p, float hz);
void AmpProcessorSetChorusDepth(void *p, float depth);
void AmpProcessorSetChorusMix(void *p, float mix);

void AmpProcessorSetDelayOn(void *p, bool on);
void AmpProcessorSetDelayTimeMs(void *p, float ms);
void AmpProcessorSetDelayFeedback(void *p, float feedback);
void AmpProcessorSetDelayMix(void *p, float mix);

void AmpProcessorSetReverbOn(void *p, bool on);
void AmpProcessorSetReverbSize(void *p, float size);
void AmpProcessorSetReverbDamp(void *p, float damp);
void AmpProcessorSetReverbMix(void *p, float mix);

AmpMeterState AmpProcessorGetMeters(void *p);
void AmpProcessorClearClips(void *p);

// Lock-free single-producer/single-consumer bridge between Core Audio's
// independent input and output callbacks.
void *AmpAudioFIFOCreate(int capacity);
void AmpAudioFIFODestroy(void *fifo);
void AmpAudioFIFOClear(void *fifo);
int AmpAudioFIFOWrite(void *fifo, const float *samples, int frames);
int AmpAudioFIFORead(void *fifo, float *samples, int frames);
int AmpAudioFIFOAvailable(void *fifo);
AmpAudioFIFOStats AmpAudioFIFOGetStats(void *fifo);
// Shared-clock duplex should read 1:1. Separate devices may steal or skip
// one sample per block only after a persistent queue error; never jump by
// several percent in a single callback.
int AmpAudioFIFORequestFrames(int available, int outputFrames, int target, bool sharedClock);

// Atomics shared by the main, audio-render, and recorder-writer threads.
void *AmpRecorderStateCreate(void);
void AmpRecorderStateDestroy(void *state);
void AmpRecorderStateReset(void *state);
void AmpRecorderStateSetArmed(void *state, bool armed);
void AmpRecorderStateSetBassOnly(void *state, bool bassOnly);
void AmpRecorderStateSetWriting(void *state, bool writing);
void AmpRecorderStateSetCapturingSystemOutput(void *state, bool capturing);
void AmpRecorderStateAddFrames(void *state, int frames, float peak);
AmpRecorderStateSnapshot AmpRecorderStateGet(void *state);

#ifdef __cplusplus
}
#endif
