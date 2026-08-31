#include "AmpProcessor.h"
#include "BassEssentials.hpp"

#include "BassBand.hpp"
#include "BiquadEQ.hpp"
#include "CabinetIR.hpp"
#include "Chorus.hpp"
#include "CleanAmp.hpp"
#include "Compressor.hpp"
#include "Delay.hpp"
#include "Drive.hpp"
#include "NoiseGate.hpp"
#include "NoiseReduction.hpp"
#include "Resampler.hpp"
#include "Reverb.hpp"
#include "Tuner.hpp"

#include "NAM/activations.h"
#include "NAM/dsp.h"
#include "NAM/get_dsp.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace {

float dbToLin(float db) { return std::pow(10.0f, db / 20.0f); }

} // namespace

constexpr int kMaxRenderFrames = 4096;
constexpr int kWorkCapacity = kMaxRenderFrames * 4;

// Three-slot publication so the audio thread never skips a block while a
// model loads, and so destructors always run on the thread that publishes
// (main / tests), never inside the render callback.
template <typename T>
struct TripleSlot {
    std::shared_ptr<T> slots[3];
    std::atomic<int> published{0};
    std::atomic<int> inUse{0};

    T *acquire() {
        const int i = published.load(std::memory_order_acquire);
        inUse.store(i, std::memory_order_release);
        return slots[i].get();
    }

    T *peek() const {
        const int i = published.load(std::memory_order_acquire);
        return slots[i].get();
    }

    void publish(std::shared_ptr<T> next) {
        const int pub = published.load(std::memory_order_relaxed);
        const int use = inUse.load(std::memory_order_acquire);
        int idx = 0;
        while (idx == pub || idx == use)
            ++idx;
        slots[idx] = std::move(next);
        published.store(idx, std::memory_order_release);
    }

    void resetEngine(double sampleRate, int maxBlock) {
        if (T *item = peek())
            item->resetEngine(sampleRate, maxBlock);
    }
};

struct PreparedNAM {
    std::unique_ptr<nam::DSP> dsp;
    CubicResampler toNam;
    CubicResampler fromNam;
    double expectedRate = -1.0;
    std::vector<float> namFloatIn;
    std::vector<float> namFloatOut;
    std::vector<NAM_SAMPLE> namIn;
    std::vector<NAM_SAMPLE> namOut;

    void allocate(int cap) {
        namFloatIn.assign(cap, 0.0f);
        namFloatOut.assign(cap, 0.0f);
        namIn.assign(cap, NAM_SAMPLE(0));
        namOut.assign(cap, NAM_SAMPLE(0));
    }

    void resetEngine(double engineRate, int maxBlock) {
        if (!dsp)
            return;
        const double modelRate = dsp->GetExpectedSampleRate() > 0 ? dsp->GetExpectedSampleRate() : engineRate;
        expectedRate = dsp->GetExpectedSampleRate();
        toNam.setRates(engineRate, modelRate);
        fromNam.setRates(modelRate, engineRate);
        toNam.reset();
        fromNam.reset();
        dsp->Reset(modelRate, std::max(maxBlock * 4, kWorkCapacity));
    }

    bool canRender(int frames) const {
        return dsp && frames > 0 && frames <= (int)namFloatIn.size() && frames <= (int)namIn.size();
    }
};

void renderNAM(PreparedNAM &nam, float *buffer, int frames) {
    if (!nam.canRender(frames))
        return;
    NAM_SAMPLE *inPtr = nam.namIn.data();
    NAM_SAMPLE *outPtr = nam.namOut.data();
    if (nam.toNam.needsConvert()) {
        const int namTarget = std::min(nam.toNam.calcOutFrames(frames), (int)nam.namFloatIn.size());
        const int namFrames = nam.toNam.process(buffer, frames, nam.namFloatIn.data(), namTarget);
        const int safe = std::min(namFrames, (int)nam.namIn.size());
        for (int i = 0; i < safe; ++i)
            nam.namIn[i] = (NAM_SAMPLE)nam.namFloatIn[i];
        nam.dsp->process(&inPtr, &outPtr, safe);
        for (int i = 0; i < safe; ++i)
            nam.namFloatOut[i] = (float)nam.namOut[i];
        nam.fromNam.process(nam.namFloatOut.data(), safe, buffer, frames);
    } else {
        for (int i = 0; i < frames; ++i)
            nam.namIn[i] = (NAM_SAMPLE)buffer[i];
        nam.dsp->process(&inPtr, &outPtr, frames);
        for (int i = 0; i < frames; ++i)
            buffer[i] = (float)nam.namOut[i];
    }
}

struct PreparedCabinet {
    CabinetIR cabinet;

    void resetEngine(double sampleRate, int maxBlock) {
        cabinet.setEngineRate(sampleRate, maxBlock);
    }
};

struct AmpAudioFIFOImpl {
    explicit AmpAudioFIFOImpl(int requestedCapacity)
        : capacity(static_cast<uint64_t>(std::max(requestedCapacity, 2))),
          samples(static_cast<size_t>(capacity), 0.0f) {}

    const uint64_t capacity;
    std::vector<float> samples;
    std::atomic<uint64_t> readPosition{0};
    std::atomic<uint64_t> writePosition{0};
    std::atomic<uint64_t> writtenFrames{0};
    std::atomic<uint64_t> readFrames{0};
    std::atomic<uint64_t> overflowFrames{0};
    std::atomic<uint64_t> underflowFrames{0};
};

struct AmpRecorderStateImpl {
    std::atomic<bool> armed{false};
    std::atomic<bool> recordBassOnly{false};
    std::atomic<bool> writing{false};
    std::atomic<bool> capturingSystemOutput{false};
    std::atomic<int64_t> recordedFrames{0};
    std::atomic<float> peak{0.0f};
};

class InputConditioner {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        refresh();
    }
    void reset() {
        subsonicFilter.reset();
        for (auto &notch : humNotch)
            notch.reset();
    }
    inline void process(float *buffer, int frames) {
        for (int i = 0; i < frames; ++i) {
            float x = buffer[i];
            x = subsonicFilter.tick(x);
            for (auto &notch : humNotch)
                x = notch.tick(x);
            buffer[i] = x;
        }
    }
private:
    double sampleRate = 48000.0;
    Biquad subsonicFilter;
    Biquad humNotch[4];
    void refresh() {
        subsonicFilter.set(Biquad::Type::HighPass, 18.0f, 0.0f, 0.7071f, sampleRate);
        // Narrow notches so A (55 Hz) and B (61.7 Hz) stay, while analog
        // jack mains hum at 50/60 Hz and their first harmonics do not.
        constexpr float freqs[4] = {50.0f, 60.0f, 100.0f, 120.0f};
        for (int i = 0; i < 4; ++i)
            humNotch[i].set(Biquad::Type::Notch, freqs[i], 0.0f, 28.0f, sampleRate);
    }
};

struct AmpProcessorImpl {

    TripleSlot<PreparedNAM> namSlot;
    TripleSlot<PreparedCabinet> cabinetSlot;
    std::atomic<double> namExpectedRate{-1.0};

    NoiseGate gate;
    ToneEQ eq;
    Tuner tuner;
    Compressor compressor;
    Drive drive;
    BassOctaver octaver;
    BassEnvelopeFilter envelopeFilter;
    BassUtilityFilter utilityFilter;
    CleanAmp cleanAmp;
    BassBand inBand;
    BassBand outBand;
    Chorus chorus;
    DelayFX delay;
    Reverb reverb;
    InputConditioner inputConditioner;
    NoiseReduction noiseReduction;

    std::vector<float> work;

    double engineRate = 48000.0;
    int maxBlock = 512;
    int maxRenderFrames = kMaxRenderFrames;

    std::atomic<float> inputGain{1.0f};
    std::atomic<float> outputGain{1.0f};
    std::atomic<float> gateThresholdDb{-40.0f};
    std::atomic<float> bassDb{0.0f};
    std::atomic<float> midDb{0.0f};
    std::atomic<float> trebleDb{0.0f};
    std::atomic<int> midFreqIndex{1}; // 450 Hz default
    std::atomic<bool> ultraLoOn{false};
    std::atomic<bool> ultraHiOn{false};
    std::atomic<bool> gateOn{false};
    std::atomic<bool> expanderOn{false};
    std::atomic<bool> nrOn{false};
    std::atomic<bool> namOn{false};
    std::atomic<bool> cleanAmpOn{false};
    std::atomic<bool> irOn{false};
    std::atomic<bool> eqOn{false};
    std::atomic<bool> bypass{false};
    std::atomic<bool> tunerMute{false};

    std::atomic<bool> compOn{false};
    std::atomic<float> compThresholdDb{-24.0f};
    std::atomic<float> compRatio{4.0f};
    std::atomic<float> compMakeupDb{2.0f};

    std::atomic<bool> driveOn{false};
    std::atomic<float> driveAmount{0.35f};
    std::atomic<float> driveTone{0.5f};
    std::atomic<float> driveMix{0.55f};

    std::atomic<bool> octaverOn{false};
    std::atomic<float> octaverMix{0.35f};
    std::atomic<float> octaverTone{0.45f};

    std::atomic<bool> envelopeOn{false};
    std::atomic<float> envelopeSensitivity{0.55f};
    std::atomic<float> envelopeResonance{0.45f};
    std::atomic<float> envelopeMix{0.65f};

    std::atomic<bool> utilityFilterOn{true};
    std::atomic<float> highPassHz{32.0f};
    std::atomic<float> lowPassHz{12000.0f};

    std::atomic<bool> chorusOn{false};
    std::atomic<float> chorusRate{0.8f};
    std::atomic<float> chorusDepth{0.4f};
    std::atomic<float> chorusMix{0.35f};

    std::atomic<bool> delayOn{false};
    std::atomic<float> delayTimeMs{180.0f};
    std::atomic<float> delayFeedback{0.28f};
    std::atomic<float> delayMix{0.22f};

    std::atomic<bool> reverbOn{false};
    std::atomic<float> reverbSize{0.4f};
    std::atomic<float> reverbDamp{0.45f};
    std::atomic<float> reverbMix{0.2f};

    std::atomic<float> inputPeak{0};
    std::atomic<float> outputPeak{0};
    std::atomic<float> inputRmsDb{-120.0f};
    std::atomic<float> inputPeakDb{-120.0f};
    std::atomic<float> noiseFloorDb{-120.0f};
    std::atomic<bool> inputClip{false};
    std::atomic<bool> outputClip{false};

    float inEnv = 0;
    float outEnv = 0;
    float noiseFloorLinear = 0;

    bool buffersReady(int frames) const {
        return frames > 0 && frames <= maxRenderFrames && (int)work.size() >= frames;
    }

    void applyReset() {
        maxRenderFrames = std::max(kMaxRenderFrames, maxBlock);
        const int cap = std::max(maxRenderFrames * 4, kWorkCapacity);
        work.assign(cap, 0.0f);
        gate.setSampleRate(engineRate);
        gate.reset();
        eq.setSampleRate(engineRate);
        eq.reset();
        tuner.setSampleRate(engineRate);
        tuner.reset();
        compressor.setSampleRate(engineRate);
        compressor.reset();
        drive.setSampleRate(engineRate);
        drive.reset();
        octaver.setSampleRate(engineRate);
        envelopeFilter.setSampleRate(engineRate);
        utilityFilter.setSampleRate(engineRate);
        cleanAmp.setSampleRate(engineRate);
        cleanAmp.reset();
        inBand.setSampleRate(engineRate);
        inBand.reset();
        outBand.setSampleRate(engineRate);
        outBand.reset();
        chorus.setSampleRate(engineRate);
        chorus.reset();
        delay.setSampleRate(engineRate);
        delay.reset();
        reverb.setSampleRate(engineRate);
        reverb.reset();
        inputConditioner.setSampleRate(engineRate);
        inputConditioner.reset();
        noiseReduction.prepare(engineRate, maxRenderFrames);
        cabinetSlot.resetEngine(engineRate, maxRenderFrames);
        namSlot.resetEngine(engineRate, maxRenderFrames);
        if (PreparedNAM *nam = namSlot.peek())
            namExpectedRate.store(nam->expectedRate, std::memory_order_relaxed);
        else
            namExpectedRate.store(-1.0, std::memory_order_relaxed);
        inEnv = outEnv = 0;
        inputPeak.store(0, std::memory_order_relaxed);
        outputPeak.store(0, std::memory_order_relaxed);
        inputRmsDb.store(-120.0f, std::memory_order_relaxed);
        inputPeakDb.store(-120.0f, std::memory_order_relaxed);
        noiseFloorDb.store(-120.0f, std::memory_order_relaxed);
        inputClip.store(false, std::memory_order_relaxed);
        outputClip.store(false, std::memory_order_relaxed);
        noiseFloorLinear = 0;
    }
};

static AmpProcessorImpl *asProc(void *p) { return static_cast<AmpProcessorImpl *>(p); }

void *AmpProcessorShared(void) {
    static AmpProcessorImpl *instance = [] {
        nam::activations::Activation::enable_fast_tanh();
        auto *p = new AmpProcessorImpl();
        p->applyReset();
        return p;
    }();
    return instance;
}

bool AmpProcessorLoadNAM(void *opaque, const char *path, char *err, int errLen) {
    auto *p = asProc(opaque);
    if (!p || !path) {
        if (err && errLen > 0)
            std::snprintf(err, errLen, "Invalid path");
        return false;
    }
    try {
        nam::DspLoadOptions options;
        options.prewarm = true;
        auto loaded = nam::get_dsp(std::filesystem::path(path), options);
        if (!loaded)
            throw std::runtime_error("NAM loader returned null");
        if (loaded->NumInputChannels() != 1 || loaded->NumOutputChannels() != 1)
            throw std::runtime_error("This capture is not a mono amp model");

        auto prepared = std::make_shared<PreparedNAM>();
        prepared->dsp = std::move(loaded);
        prepared->allocate(std::max(p->maxRenderFrames * 4, kWorkCapacity));
        prepared->resetEngine(p->engineRate, p->maxRenderFrames);
        p->namExpectedRate.store(prepared->expectedRate, std::memory_order_relaxed);
        p->namSlot.publish(std::move(prepared));
        return true;
    } catch (const std::exception &e) {
        if (err && errLen > 0)
            std::snprintf(err, errLen, "%s", e.what());
        return false;
    }
}

void AmpProcessorUnloadNAM(void *opaque) {
    auto *p = asProc(opaque);
    if (!p)
        return;
    p->namSlot.publish(nullptr);
    p->namExpectedRate.store(-1.0, std::memory_order_relaxed);
}

bool AmpProcessorHasNAM(void *opaque) {
    auto *p = asProc(opaque);
    return p && p->namSlot.peek() != nullptr;
}

double AmpProcessorNAMSampleRate(void *opaque) {
    auto *p = asProc(opaque);
    if (!p)
        return -1.0;
    return p->namExpectedRate.load(std::memory_order_relaxed);
}

bool AmpProcessorLoadIR(void *opaque, const float *samples, int length, double sampleRate) {
    auto *p = asProc(opaque);
    if (!p || !samples || length <= 0)
        return false;
    auto prepared = std::make_shared<PreparedCabinet>();
    prepared->cabinet.setIR(samples, length, sampleRate);
    prepared->cabinet.setEngineRate(p->engineRate, p->maxRenderFrames);
    if (!prepared->cabinet.hasIR())
        return false;
    p->cabinetSlot.publish(std::move(prepared));
    return true;
}

void AmpProcessorUnloadIR(void *opaque) {
    auto *p = asProc(opaque);
    if (p)
        p->cabinetSlot.publish(nullptr);
}

bool AmpProcessorHasIR(void *opaque) {
    auto *p = asProc(opaque);
    if (!p)
        return false;
    if (PreparedCabinet *cabinet = p->cabinetSlot.peek())
        return cabinet->cabinet.hasIR();
    return false;
}

void AmpProcessorReset(void *opaque, double sampleRate, int maxBlock) {
    auto *p = asProc(opaque);
    if (!p)
        return;
    p->engineRate = sampleRate > 1.0 ? sampleRate : 48000.0;
    p->maxBlock = std::max(32, maxBlock);
    p->applyReset();
}

void AmpProcessorProcess(void *opaque, const float *input, float *output, int frames) {
    auto *p = asProc(opaque);
    if (!p || frames <= 0)
        return;
    if (!input || !output) {
        if (output && frames > 0)
            std::memset(output, 0, frames * sizeof(float));
        return;
    }

    if (!p->buffersReady(frames)) {
        // Never allocate on the render path. Pass through or mute if a
        // callback is larger than the preallocated workspace.
        if (output) {
            if (input)
                std::memcpy(output, input, frames * sizeof(float));
            else
                std::memset(output, 0, frames * sizeof(float));
        }
        return;
    }
    float *work = p->work.data();
    std::memcpy(work, input, frames * sizeof(float));

    for (int i = 0; i < frames; ++i) {
        if (!std::isfinite(work[i]))
            work[i] = 0.0f;
    }

    p->inputConditioner.process(work, frames);

    float peakIn = 0.0f;
    vDSP_maxmgv(work, 1, &peakIn, frames);
    float rmsIn = 0.0f;
    vDSP_rmsqv(work, 1, &rmsIn, frames);
    const float rmsDb = 20.0f * std::log10(std::max(rmsIn, 1.0e-6f));
    p->inputRmsDb.store(std::max(-120.0f, rmsDb), std::memory_order_relaxed);
    const float peakDb = 20.0f * std::log10(std::max(peakIn, 1.0e-6f));
    p->inputPeakDb.store(std::max(-120.0f, peakDb), std::memory_order_relaxed);

    // Estimate the idle analog noise floor only while no strong note is
    // present. It falls quickly after playing stops and rises slowly so a
    // single note cannot masquerade as cable noise.
    if (peakIn < 0.05f) {
        if (p->noiseFloorLinear <= 0.0f) {
            p->noiseFloorLinear = rmsIn;
        } else {
            const float coeff = rmsIn < p->noiseFloorLinear ? 0.12f : 0.0025f;
            p->noiseFloorLinear += coeff * (rmsIn - p->noiseFloorLinear);
        }
        const float floorDb = 20.0f * std::log10(std::max(p->noiseFloorLinear, 1.0e-6f));
        p->noiseFloorDb.store(std::max(-120.0f, floorDb), std::memory_order_relaxed);
    }
    float inBandEnv = 0.0f;
    for (int i = 0; i < frames; ++i)
        inBandEnv = p->inBand.tick(work[i]);
    const float inMeterVal = BassBand::toMeter(inBandEnv);
    if (inMeterVal > p->inEnv)
        p->inEnv = inMeterVal;
    else
        p->inEnv += 0.08f * (inMeterVal - p->inEnv);
    p->inputPeak.store(p->inEnv, std::memory_order_relaxed);
    if (peakIn >= 0.98f)
        p->inputClip.store(true, std::memory_order_relaxed);

    auto silenceOutput = [&]() {
        std::memset(output, 0, frames * sizeof(float));
        p->outEnv += 0.12f * (0.0f - p->outEnv);
        p->outputPeak.store(p->outEnv, std::memory_order_relaxed);
    };

    if (p->bypass.load(std::memory_order_relaxed)) {
        p->tuner.feed(work, frames);
        if (p->tunerMute.load(std::memory_order_relaxed)) {
            silenceOutput();
            return;
        }
        std::memcpy(output, work, frames * sizeof(float));
        float bypassBand = 0.0f;
        for (int i = 0; i < frames; ++i)
            bypassBand = p->outBand.tick(work[i]);
        const float bypassMeterVal = BassBand::toMeter(bypassBand);
        if (bypassMeterVal > p->outEnv)
            p->outEnv = bypassMeterVal;
        else
            p->outEnv += 0.08f * (bypassMeterVal - p->outEnv);
        p->outputPeak.store(p->outEnv, std::memory_order_relaxed);
        if (peakIn >= 0.98f)
            p->outputClip.store(true, std::memory_order_relaxed);
        return;
    }

    // Continuous spectral noise reduction. The analog jack path carries a
    // 60 Hz buzz comb and broadband switching hash at all times; a gate or
    // expander lets it back in with every note, so it has to be subtracted
    // from the spectrum instead. Never runs on Raw DI (bypass above).
    if (p->nrOn.load(std::memory_order_relaxed))
        p->noiseReduction.process(work, frames);

    // Input trim is part of the preamp and must precede the gate detector.
    // With trim after the gate, quiet passive basses could never open the
    // gate no matter how far the Gain control was turned up.
    const float inG = p->inputGain.load(std::memory_order_relaxed);
    vDSP_vsmul(work, 1, &inG, work, 1, frames);

    if (p->gateOn.load(std::memory_order_relaxed)) {
        p->gate.setExpander(false);
        p->gate.setThresholdDb(p->gateThresholdDb.load(std::memory_order_relaxed));
        p->gate.process(work, frames);
    } else if (p->expanderOn.load(std::memory_order_relaxed)) {
        p->gate.setExpander(true);
        p->gate.setNoiseFloorDb(p->noiseFloorDb.load(std::memory_order_relaxed));
        p->gate.process(work, frames);
    }

    // Tune the signal that is actually allowed through the rig. Feeding the
    // raw jack input made mains hum look like a permanently held bass note
    // even while the gate had correctly silenced it.
    p->tuner.feed(work, frames);

    if (p->tunerMute.load(std::memory_order_relaxed)) {
        silenceOutput();
        return;
    }

    if (p->compOn.load(std::memory_order_relaxed)) {
        p->compressor.setThresholdDb(p->compThresholdDb.load(std::memory_order_relaxed));
        p->compressor.setRatio(p->compRatio.load(std::memory_order_relaxed));
        p->compressor.setMakeupDb(p->compMakeupDb.load(std::memory_order_relaxed));
        p->compressor.process(work, frames);
    }

    if (p->octaverOn.load(std::memory_order_relaxed)) {
        p->octaver.setMix(p->octaverMix.load(std::memory_order_relaxed));
        p->octaver.setTone(p->octaverTone.load(std::memory_order_relaxed));
        p->octaver.process(work, frames);
    }

    if (p->envelopeOn.load(std::memory_order_relaxed)) {
        p->envelopeFilter.setSensitivity(p->envelopeSensitivity.load(std::memory_order_relaxed));
        p->envelopeFilter.setResonance(p->envelopeResonance.load(std::memory_order_relaxed));
        p->envelopeFilter.setMix(p->envelopeMix.load(std::memory_order_relaxed));
        p->envelopeFilter.process(work, frames);
    }

    if (p->driveOn.load(std::memory_order_relaxed)) {
        p->drive.setAmount(p->driveAmount.load(std::memory_order_relaxed));
        p->drive.setTone(p->driveTone.load(std::memory_order_relaxed));
        p->drive.setMix(p->driveMix.load(std::memory_order_relaxed));
        p->drive.process(work, frames);
    }

    if (p->namOn.load(std::memory_order_relaxed)) {
        if (PreparedNAM *nam = p->namSlot.acquire()) {
            renderNAM(*nam, work, frames);
        } else if (p->cleanAmpOn.load(std::memory_order_relaxed)) {
            p->cleanAmp.process(work, frames);
        }
    }

    if (p->irOn.load(std::memory_order_relaxed)) {
        if (PreparedCabinet *cabinet = p->cabinetSlot.acquire()) {
            if (cabinet->cabinet.hasIR())
                cabinet->cabinet.process(work, work, frames);
        }
    }

    if (p->eqOn.load(std::memory_order_relaxed)) {
        p->eq.setBass(p->bassDb.load(std::memory_order_relaxed));
        p->eq.setMid(p->midDb.load(std::memory_order_relaxed));
        p->eq.setTreble(p->trebleDb.load(std::memory_order_relaxed));
        p->eq.setMidFreqIndex(p->midFreqIndex.load(std::memory_order_relaxed));
        p->eq.setUltraLo(p->ultraLoOn.load(std::memory_order_relaxed));
        p->eq.setUltraHi(p->ultraHiOn.load(std::memory_order_relaxed));
        p->eq.process(work, frames);
    }

    if (p->chorusOn.load(std::memory_order_relaxed)) {
        p->chorus.setRate(p->chorusRate.load(std::memory_order_relaxed));
        p->chorus.setDepth(p->chorusDepth.load(std::memory_order_relaxed));
        p->chorus.setMix(p->chorusMix.load(std::memory_order_relaxed));
        p->chorus.process(work, frames);
    }

    if (p->delayOn.load(std::memory_order_relaxed)) {
        p->delay.setTimeMs(p->delayTimeMs.load(std::memory_order_relaxed));
        p->delay.setFeedback(p->delayFeedback.load(std::memory_order_relaxed));
        p->delay.setMix(p->delayMix.load(std::memory_order_relaxed));
        p->delay.process(work, frames);
    }

    if (p->reverbOn.load(std::memory_order_relaxed)) {
        p->reverb.setSize(p->reverbSize.load(std::memory_order_relaxed));
        p->reverb.setDamp(p->reverbDamp.load(std::memory_order_relaxed));
        p->reverb.setMix(p->reverbMix.load(std::memory_order_relaxed));
        p->reverb.process(work, frames);
    }

    if (p->utilityFilterOn.load(std::memory_order_relaxed)) {
        p->utilityFilter.setHighPass(p->highPassHz.load(std::memory_order_relaxed));
        p->utilityFilter.setLowPass(p->lowPassHz.load(std::memory_order_relaxed));
        p->utilityFilter.process(work, frames);
    }

    const float outG = p->outputGain.load(std::memory_order_relaxed);
    vDSP_vsmul(work, 1, &outG, work, 1, frames);

    float peakBeforeLimit = 0;
    for (int i = 0; i < frames; ++i) {
        if (!std::isfinite(work[i])) {
            work[i] = 0.0f;
            p->outputClip.store(true, std::memory_order_relaxed);
            continue;
        }
        peakBeforeLimit = std::max(peakBeforeLimit, std::fabs(work[i]));
        // Stay bit-transparent at normal playing levels, then enter a
        // continuous soft knee. Applying tanh to the entire waveform added
        // unwanted saturation even when the signal was nowhere near clipping.
        const float magnitude = std::fabs(work[i]);
        if (magnitude > 0.90f) {
            const float limited = 0.90f + 0.08f * std::tanh((magnitude - 0.90f) / 0.08f);
            work[i] = std::copysign(limited, work[i]);
        }
    }

    float peakOut = 0.0f;
    vDSP_maxmgv(work, 1, &peakOut, frames);
    float outBandEnv = 0.0f;
    for (int i = 0; i < frames; ++i)
        outBandEnv = p->outBand.tick(work[i]);
    const float outMeterVal = BassBand::toMeter(outBandEnv);
    if (outMeterVal > p->outEnv)
        p->outEnv = outMeterVal;
    else
        p->outEnv += 0.08f * (outMeterVal - p->outEnv);
    p->outputPeak.store(p->outEnv, std::memory_order_relaxed);
    if (peakBeforeLimit >= 0.98f)
        p->outputClip.store(true, std::memory_order_relaxed);

    std::memcpy(output, work, frames * sizeof(float));
}

void AmpProcessorSetInputGainDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->inputGain.store(dbToLin(db));
}
void AmpProcessorSetOutputGainDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->outputGain.store(dbToLin(db));
}
void AmpProcessorSetGateThresholdDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->gateThresholdDb.store(db);
}
void AmpProcessorSetBassDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->bassDb.store(db);
}
void AmpProcessorSetMidDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->midDb.store(db);
}
void AmpProcessorSetTrebleDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->trebleDb.store(db);
}
void AmpProcessorSetMidFreqIndex(void *opaque, int index) {
    if (auto *p = asProc(opaque))
        p->midFreqIndex.store(std::clamp(index, 0, 4));
}
void AmpProcessorSetUltraLoOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->ultraLoOn.store(on);
}
void AmpProcessorSetUltraHiOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->ultraHiOn.store(on);
}
void AmpProcessorSetGateOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->gateOn.store(on);
}
void AmpProcessorSetNROn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->nrOn.store(on);
}
void AmpProcessorSetExpanderOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->expanderOn.store(on);
}
void AmpProcessorSetNAMOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->namOn.store(on);
}
void AmpProcessorSetCleanAmpOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->cleanAmpOn.store(on);
}
bool AmpProcessorCleanAmpOn(void *opaque) {
    auto *p = asProc(opaque);
    return p && p->cleanAmpOn.load(std::memory_order_relaxed);
}
void AmpProcessorSetIROn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->irOn.store(on);
}
void AmpProcessorSetEQOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->eqOn.store(on);
}
void AmpProcessorSetBypass(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->bypass.store(on);
}
void AmpProcessorSetTunerMute(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->tunerMute.store(on);
}

void AmpProcessorSetCompOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->compOn.store(on);
}
void AmpProcessorSetCompThresholdDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->compThresholdDb.store(db);
}
void AmpProcessorSetCompRatio(void *opaque, float ratio) {
    if (auto *p = asProc(opaque))
        p->compRatio.store(ratio);
}
void AmpProcessorSetCompMakeupDb(void *opaque, float db) {
    if (auto *p = asProc(opaque))
        p->compMakeupDb.store(db);
}

void AmpProcessorSetDriveOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->driveOn.store(on);
}
void AmpProcessorSetDriveAmount(void *opaque, float amount) {
    if (auto *p = asProc(opaque))
        p->driveAmount.store(amount);
}
void AmpProcessorSetDriveTone(void *opaque, float tone) {
    if (auto *p = asProc(opaque))
        p->driveTone.store(tone);
}
void AmpProcessorSetDriveMix(void *opaque, float mix) {
    if (auto *p = asProc(opaque))
        p->driveMix.store(mix);
}

void AmpProcessorSetOctaverOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque)) p->octaverOn.store(on);
}
void AmpProcessorSetOctaverMix(void *opaque, float mix) {
    if (auto *p = asProc(opaque)) p->octaverMix.store(mix);
}
void AmpProcessorSetOctaverTone(void *opaque, float tone) {
    if (auto *p = asProc(opaque)) p->octaverTone.store(tone);
}
void AmpProcessorSetEnvelopeOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque)) p->envelopeOn.store(on);
}
void AmpProcessorSetEnvelopeSensitivity(void *opaque, float sensitivity) {
    if (auto *p = asProc(opaque)) p->envelopeSensitivity.store(sensitivity);
}
void AmpProcessorSetEnvelopeResonance(void *opaque, float resonance) {
    if (auto *p = asProc(opaque)) p->envelopeResonance.store(resonance);
}
void AmpProcessorSetEnvelopeMix(void *opaque, float mix) {
    if (auto *p = asProc(opaque)) p->envelopeMix.store(mix);
}
void AmpProcessorSetUtilityFilterOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque)) p->utilityFilterOn.store(on);
}
void AmpProcessorSetHighPassHz(void *opaque, float hz) {
    if (auto *p = asProc(opaque)) p->highPassHz.store(hz);
}
void AmpProcessorSetLowPassHz(void *opaque, float hz) {
    if (auto *p = asProc(opaque)) p->lowPassHz.store(hz);
}

void AmpProcessorSetChorusOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->chorusOn.store(on);
}
void AmpProcessorSetChorusRate(void *opaque, float hz) {
    if (auto *p = asProc(opaque))
        p->chorusRate.store(hz);
}
void AmpProcessorSetChorusDepth(void *opaque, float depth) {
    if (auto *p = asProc(opaque))
        p->chorusDepth.store(depth);
}
void AmpProcessorSetChorusMix(void *opaque, float mix) {
    if (auto *p = asProc(opaque))
        p->chorusMix.store(mix);
}

void AmpProcessorSetDelayOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->delayOn.store(on);
}
void AmpProcessorSetDelayTimeMs(void *opaque, float ms) {
    if (auto *p = asProc(opaque))
        p->delayTimeMs.store(ms);
}
void AmpProcessorSetDelayFeedback(void *opaque, float feedback) {
    if (auto *p = asProc(opaque))
        p->delayFeedback.store(feedback);
}
void AmpProcessorSetDelayMix(void *opaque, float mix) {
    if (auto *p = asProc(opaque))
        p->delayMix.store(mix);
}

void AmpProcessorSetReverbOn(void *opaque, bool on) {
    if (auto *p = asProc(opaque))
        p->reverbOn.store(on);
}
void AmpProcessorSetReverbSize(void *opaque, float size) {
    if (auto *p = asProc(opaque))
        p->reverbSize.store(size);
}
void AmpProcessorSetReverbDamp(void *opaque, float damp) {
    if (auto *p = asProc(opaque))
        p->reverbDamp.store(damp);
}
void AmpProcessorSetReverbMix(void *opaque, float mix) {
    if (auto *p = asProc(opaque))
        p->reverbMix.store(mix);
}

AmpMeterState AmpProcessorGetMeters(void *opaque) {
    AmpMeterState s{};
    auto *p = asProc(opaque);
    if (!p)
        return s;
    s.inputPeak = p->inputPeak.load();
    s.outputPeak = p->outputPeak.load();
    s.inputRmsDb = p->inputRmsDb.load();
    s.inputPeakDb = p->inputPeakDb.load();
    s.noiseFloorDb = p->noiseFloorDb.load();
    s.inputClip = p->inputClip.load();
    s.outputClip = p->outputClip.load();
    s.tunerHz = p->tuner.frequency();
    s.tunerConfidence = p->tuner.conf();
    return s;
}

void AmpProcessorClearClips(void *opaque) {
    auto *p = asProc(opaque);
    if (!p)
        return;
    p->inputClip.store(false);
    p->outputClip.store(false);
}

void *AmpAudioFIFOCreate(int capacity) {
    try {
        return new AmpAudioFIFOImpl(capacity);
    } catch (...) {
        return nullptr;
    }
}

void AmpAudioFIFODestroy(void *opaque) {
    delete static_cast<AmpAudioFIFOImpl *>(opaque);
}

void AmpAudioFIFOClear(void *opaque) {
    auto *fifo = static_cast<AmpAudioFIFOImpl *>(opaque);
    if (!fifo)
        return;
    fifo->readPosition.store(0, std::memory_order_relaxed);
    fifo->writePosition.store(0, std::memory_order_relaxed);
    fifo->writtenFrames.store(0, std::memory_order_relaxed);
    fifo->readFrames.store(0, std::memory_order_relaxed);
    fifo->overflowFrames.store(0, std::memory_order_relaxed);
    fifo->underflowFrames.store(0, std::memory_order_relaxed);
}

int AmpAudioFIFOWrite(void *opaque, const float *input, int frames) {
    auto *fifo = static_cast<AmpAudioFIFOImpl *>(opaque);
    if (!fifo || !input || frames <= 0)
        return 0;

    const uint64_t write = fifo->writePosition.load(std::memory_order_relaxed);
    const uint64_t read = fifo->readPosition.load(std::memory_order_acquire);
    const uint64_t used = std::min(write - read, fifo->capacity);
    const int count = static_cast<int>(std::min<uint64_t>(static_cast<uint64_t>(frames), fifo->capacity - used));
    for (int i = 0; i < count; ++i)
        fifo->samples[static_cast<size_t>((write + static_cast<uint64_t>(i)) % fifo->capacity)] = input[i];
    fifo->writePosition.store(write + static_cast<uint64_t>(count), std::memory_order_release);
    fifo->writtenFrames.fetch_add(static_cast<uint64_t>(count), std::memory_order_relaxed);
    fifo->overflowFrames.fetch_add(static_cast<uint64_t>(frames - count), std::memory_order_relaxed);
    return count;
}

int AmpAudioFIFORead(void *opaque, float *output, int frames) {
    auto *fifo = static_cast<AmpAudioFIFOImpl *>(opaque);
    if (!fifo || !output || frames <= 0)
        return 0;

    const uint64_t read = fifo->readPosition.load(std::memory_order_relaxed);
    const uint64_t write = fifo->writePosition.load(std::memory_order_acquire);
    const int count = static_cast<int>(std::min<uint64_t>(static_cast<uint64_t>(frames), write - read));
    for (int i = 0; i < count; ++i)
        output[i] = fifo->samples[static_cast<size_t>((read + static_cast<uint64_t>(i)) % fifo->capacity)];
    fifo->readPosition.store(read + static_cast<uint64_t>(count), std::memory_order_release);
    fifo->readFrames.fetch_add(static_cast<uint64_t>(count), std::memory_order_relaxed);
    fifo->underflowFrames.fetch_add(static_cast<uint64_t>(frames - count), std::memory_order_relaxed);
    return count;
}

int AmpAudioFIFOAvailable(void *opaque) {
    auto *fifo = static_cast<AmpAudioFIFOImpl *>(opaque);
    if (!fifo)
        return 0;
    const uint64_t read = fifo->readPosition.load(std::memory_order_acquire);
    const uint64_t write = fifo->writePosition.load(std::memory_order_acquire);
    return static_cast<int>(std::min(write - read, fifo->capacity));
}

AmpAudioFIFOStats AmpAudioFIFOGetStats(void *opaque) {
    AmpAudioFIFOStats stats{};
    auto *fifo = static_cast<AmpAudioFIFOImpl *>(opaque);
    if (!fifo)
        return stats;
    stats.writtenFrames = fifo->writtenFrames.load(std::memory_order_relaxed);
    stats.readFrames = fifo->readFrames.load(std::memory_order_relaxed);
    stats.overflowFrames = fifo->overflowFrames.load(std::memory_order_relaxed);
    stats.underflowFrames = fifo->underflowFrames.load(std::memory_order_relaxed);
    stats.availableFrames = AmpAudioFIFOAvailable(opaque);
    return stats;
}

int AmpAudioFIFORequestFrames(int available, int outputFrames, int target, bool sharedClock) {
    if (outputFrames <= 0)
        return 0;
    if (sharedClock)
        return outputFrames;
    const int goal = std::max(target, outputFrames);
    const int error = available - goal;
    const int deadzone = std::max(32, outputFrames / 4);
    if (std::abs(error) <= deadzone)
        return outputFrames;
    if (error > 0)
        return outputFrames + 1;
    if (available >= outputFrames)
        return std::max(2, outputFrames - 1);
    return outputFrames;
}

void *AmpRecorderStateCreate(void) {
    try {
        return new AmpRecorderStateImpl();
    } catch (...) {
        return nullptr;
    }
}

void AmpRecorderStateDestroy(void *opaque) {
    delete static_cast<AmpRecorderStateImpl *>(opaque);
}

void AmpRecorderStateReset(void *opaque) {
    auto *state = static_cast<AmpRecorderStateImpl *>(opaque);
    if (!state)
        return;
    state->armed.store(false, std::memory_order_release);
    state->writing.store(false, std::memory_order_release);
    state->capturingSystemOutput.store(false, std::memory_order_release);
    state->recordedFrames.store(0, std::memory_order_relaxed);
    state->peak.store(0.0f, std::memory_order_relaxed);
}

void AmpRecorderStateSetArmed(void *opaque, bool armed) {
    if (auto *state = static_cast<AmpRecorderStateImpl *>(opaque))
        state->armed.store(armed, std::memory_order_release);
}

void AmpRecorderStateSetBassOnly(void *opaque, bool bassOnly) {
    if (auto *state = static_cast<AmpRecorderStateImpl *>(opaque))
        state->recordBassOnly.store(bassOnly, std::memory_order_release);
}

void AmpRecorderStateSetWriting(void *opaque, bool writing) {
    if (auto *state = static_cast<AmpRecorderStateImpl *>(opaque))
        state->writing.store(writing, std::memory_order_release);
}

void AmpRecorderStateSetCapturingSystemOutput(void *opaque, bool capturing) {
    if (auto *state = static_cast<AmpRecorderStateImpl *>(opaque))
        state->capturingSystemOutput.store(capturing, std::memory_order_release);
}

void AmpRecorderStateAddFrames(void *opaque, int frames, float newPeak) {
    auto *state = static_cast<AmpRecorderStateImpl *>(opaque);
    if (!state || frames <= 0)
        return;
    state->recordedFrames.fetch_add(frames, std::memory_order_relaxed);
    float current = state->peak.load(std::memory_order_relaxed);
    while (newPeak > current
           && !state->peak.compare_exchange_weak(current, newPeak, std::memory_order_relaxed)) {
    }
}

AmpRecorderStateSnapshot AmpRecorderStateGet(void *opaque) {
    AmpRecorderStateSnapshot snapshot{};
    auto *state = static_cast<AmpRecorderStateImpl *>(opaque);
    if (!state)
        return snapshot;
    snapshot.armed = state->armed.load(std::memory_order_acquire);
    snapshot.recordBassOnly = state->recordBassOnly.load(std::memory_order_acquire);
    snapshot.writing = state->writing.load(std::memory_order_acquire);
    snapshot.recordedFrames = state->recordedFrames.load(std::memory_order_relaxed);
    snapshot.peak = state->peak.load(std::memory_order_relaxed);
    snapshot.capturingSystemOutput = state->capturingSystemOutput.load(std::memory_order_acquire);
    return snapshot;
}
