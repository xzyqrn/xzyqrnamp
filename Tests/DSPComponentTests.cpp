#include "BassBand.hpp"
#include "BassEssentials.hpp"
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

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

namespace {

constexpr double kSampleRate = 48000.0;
constexpr int kFrames = 48000;
int failures = 0;

void expect(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ++failures;
    }
}

bool finite(const std::vector<float> &samples) {
    return std::all_of(samples.begin(), samples.end(), [](float x) { return std::isfinite(x); });
}

double rms(const std::vector<float> &samples, int start = 0) {
    double energy = 0;
    int count = 0;
    for (int i = std::max(0, start); i < static_cast<int>(samples.size()); ++i) {
        energy += static_cast<double>(samples[i]) * samples[i];
        ++count;
    }
    return count > 0 ? std::sqrt(energy / count) : 0;
}

double differenceRms(const std::vector<float> &a, const std::vector<float> &b, int start = 0) {
    const int count = std::min(a.size(), b.size());
    double energy = 0;
    int used = 0;
    for (int i = std::max(0, start); i < count; ++i) {
        const double d = static_cast<double>(a[i]) - b[i];
        energy += d * d;
        ++used;
    }
    return used > 0 ? std::sqrt(energy / used) : 0;
}

std::vector<float> bassSignal(float level = 0.16f) {
    std::vector<float> result(kFrames);
    for (int i = 0; i < kFrames; ++i) {
        const double t = i / kSampleRate;
        const double attack = std::min(1.0, i / 480.0);
        result[i] = static_cast<float>(attack * level
            * (std::sin(2.0 * M_PI * 110.0 * t)
                + 0.35 * std::sin(2.0 * M_PI * 220.0 * t)
                + 0.16 * std::sin(2.0 * M_PI * 880.0 * t)));
    }
    return result;
}

template <typename Effect>
void processInBlocks(Effect &effect, std::vector<float> &samples, int block = 128) {
    for (int offset = 0; offset < static_cast<int>(samples.size()); offset += block) {
        const int count = std::min(block, static_cast<int>(samples.size()) - offset);
        effect.process(samples.data() + offset, count);
    }
}

void testToneEQ() {
    const auto dry = bassSignal();
    auto wet = dry;
    ToneEQ eq;
    eq.setSampleRate(kSampleRate);
    eq.setBass(6.0f);
    eq.setMid(-4.0f);
    eq.setTreble(5.0f);
    eq.setMidFreqIndex(2);
    eq.process(wet.data(), wet.size());
    expect(finite(wet), "EQ output must remain finite");
    expect(differenceRms(dry, wet, 2048) > 0.002, "EQ controls must alter the signal");
}

void testNoiseGate() {
    auto loud = bassSignal(0.20f);
    NoiseGate gate;
    gate.setSampleRate(kSampleRate);
    gate.setThresholdDb(-45.0f);
    gate.reset();
    processInBlocks(gate, loud);
    expect(rms(loud, 4096) > 0.03, "gate must open for a played bass note");

    std::vector<float> quiet(kFrames, 1.0e-5f);
    gate.reset();
    processInBlocks(gate, quiet);
    expect(rms(quiet, 4096) < 1.0e-7, "gate must close on idle noise");
}

double binMagnitude(const std::vector<float> &samples, double hz, int start) {
    double sine = 0;
    double cosine = 0;
    int count = 0;
    for (int i = std::max(0, start); i < static_cast<int>(samples.size()); ++i) {
        const double t = i / kSampleRate;
        sine += samples[i] * std::sin(2.0 * M_PI * hz * t);
        cosine += samples[i] * std::cos(2.0 * M_PI * hz * t);
        ++count;
    }
    if (count <= 0)
        return 0;
    return 2.0 * std::sqrt(sine * sine + cosine * cosine) / count;
}

void testExpander() {
    NoiseGate expander;
    expander.setSampleRate(kSampleRate);
    expander.setExpander(true);
    expander.setNoiseFloorDb(-48.0f);
    expander.reset();

    std::vector<float> hiss(kFrames);
    for (int i = 0; i < kFrames; ++i)
        hiss[i] = 0.012f * std::sin(2.0 * M_PI * 12000.0 * i / kSampleRate);
    processInBlocks(expander, hiss);
    expect(rms(hiss, 12000) < 0.004, "expander must duck idle analog hiss");

    expander.reset();
    std::vector<float> noise(kFrames);
    uint32_t rng = 1;
    for (int i = 0; i < kFrames; ++i) {
        rng = rng * 1664525u + 1013904223u;
        noise[i] = (static_cast<int32_t>(rng) / 2147483648.0f) * 0.04f;
    }
    processInBlocks(expander, noise);
    expect(rms(noise, 12000) < 0.008, "expander must duck broadband analog hiss");

    auto note = bassSignal(0.20f);
    expander.reset();
    processInBlocks(expander, note);
    expect(finite(note), "expander output must remain finite");
    expect(rms(note, 4096) > 0.03, "expander must pass a played bass note");

    expander.reset();
    std::vector<float> mixed(kFrames);
    for (int i = 0; i < kFrames; ++i) {
        const double t = i / kSampleRate;
        mixed[i] = static_cast<float>(
            0.20 * std::sin(2.0 * M_PI * 110.0 * t)
            + 0.03 * std::sin(2.0 * M_PI * 12000.0 * t));
    }
    processInBlocks(expander, mixed);
    expect(binMagnitude(mixed, 110.0, 12000) > 0.10, "expander must keep a bass note while hiss is present");
    expect(binMagnitude(mixed, 12000.0, 12000) < 0.012, "expander must keep analog hiss down while playing");
}

void testNoiseReduction() {
    // Stationary analog-jack noise as it reaches this stage: 60 Hz buzz
    // harmonics plus broadband hiss. The 50/60/100/120 Hz fundamentals are
    // already removed by the notch bank ahead of it, so start at the third
    // harmonic, matching the measured iRig/headset-jack floor.
    auto makeNoise = [](int frames) {
        std::vector<float> result(frames);
        uint32_t rng = 7;
        for (int i = 0; i < frames; ++i) {
            const double t = i / kSampleRate;
            double buzz = 0.0;
            for (int h = 3; h <= 33; h += 2)
                buzz += std::sin(2.0 * M_PI * 60.0 * h * t) / h;
            rng = rng * 1664525u + 1013904223u;
            const float hiss = (static_cast<int32_t>(rng) / 2147483648.0f) * 0.008f;
            result[i] = static_cast<float>(0.02 * buzz) + hiss;
        }
        return result;
    };

    NoiseReduction nr;
    nr.prepare(kSampleRate, 512);

    auto idle = makeNoise(kFrames * 2);
    const double idleInRms = rms(idle, kFrames);
    processInBlocks(nr, idle);
    const double idleOutRms = rms(idle, kFrames);
    expect(finite(idle), "noise reduction output must remain finite");
    expect(idleOutRms < idleInRms * 0.35,
           "noise reduction must cut stationary buzz and hiss by at least 9 dB");

    // A bass note starting after the noise profile is learned must pass
    // nearly untouched while the noise between its harmonics stays down.
    nr.reset();
    auto mixed = makeNoise(kFrames * 2);
    for (int i = kFrames; i < kFrames * 2; ++i) {
        const double t = (i - kFrames) / kSampleRate;
        const double attack = std::min(1.0, (i - kFrames) / 480.0);
        mixed[i] += static_cast<float>(attack * 0.16
            * (std::sin(2.0 * M_PI * 110.0 * t) + 0.35 * std::sin(2.0 * M_PI * 220.0 * t)));
    }
    processInBlocks(nr, mixed);
    expect(finite(mixed), "noise reduction must stay finite with a note present");
    const double noteMag = binMagnitude(mixed, 110.0, kFrames + 12000);
    expect(noteMag > 0.10, "noise reduction must pass a played bass note");

    // Silence must stay silent and never generate output on its own.
    nr.reset();
    std::vector<float> silence(kFrames, 0.0f);
    processInBlocks(nr, silence);
    expect(finite(silence), "noise reduction must remain finite on silence");
    expect(rms(silence, 4096) < 1.0e-6, "noise reduction must not generate noise from silence");
}

void testCompressor() {
    auto dry = bassSignal(0.75f);
    auto wet = dry;
    Compressor compressor;
    compressor.setSampleRate(kSampleRate);
    compressor.setThresholdDb(-28.0f);
    compressor.setRatio(8.0f);
    compressor.setMakeupDb(0.0f);
    compressor.reset();
    processInBlocks(compressor, wet);
    expect(finite(wet), "compressor output must remain finite");
    expect(rms(wet, 12000) < rms(dry, 12000) * 0.85, "compressor must reduce sustained peaks");
}

void testDrive() {
    const auto dry = bassSignal(0.25f);
    auto wet = dry;
    Drive drive;
    drive.setSampleRate(kSampleRate);
    drive.setAmount(0.75f);
    drive.setTone(0.65f);
    drive.setMix(0.70f);
    drive.reset();
    processInBlocks(drive, wet);
    expect(finite(wet), "drive output must remain finite");
    expect(differenceRms(dry, wet, 2048) > 0.005, "drive must add audible coloration");
}

void testBassOctaver() {
    const auto dry = bassSignal(0.22f);
    auto wet = dry;
    BassOctaver octaver;
    octaver.setSampleRate(kSampleRate);
    octaver.setMix(0.72f);
    octaver.setTone(0.5f);
    processInBlocks(octaver, wet);
    expect(finite(wet), "octaver output must remain finite");
    expect(rms(wet, 4096) > 0.005, "octaver must preserve an audible bass signal");
    expect(differenceRms(dry, wet, 4096) > 0.01, "octaver must generate a distinct sub-octave voice");
}

void testEnvelopeFilter() {
    const auto dry = bassSignal(0.25f);
    auto wet = dry;
    BassEnvelopeFilter filter;
    filter.setSampleRate(kSampleRate);
    filter.setSensitivity(0.75f);
    filter.setResonance(0.55f);
    filter.setMix(0.8f);
    processInBlocks(filter, wet);
    expect(finite(wet), "envelope-filter output must remain finite");
    expect(rms(wet, 4096) > 0.002, "envelope filter must preserve an audible signal");
    expect(differenceRms(dry, wet, 4096) > 0.01, "envelope filter must sweep the bass tone");
}

void testUtilityFilter() {
    std::vector<float> dry(kFrames);
    for (int i = 0; i < kFrames; ++i) {
        const double t = i / kSampleRate;
        dry[i] = static_cast<float>(0.18 * std::sin(2.0 * M_PI * 35.0 * t)
            + 0.14 * std::sin(2.0 * M_PI * 110.0 * t)
            + 0.10 * std::sin(2.0 * M_PI * 12000.0 * t));
    }
    auto wet = dry;
    BassUtilityFilter filter;
    filter.setSampleRate(kSampleRate);
    filter.setHighPass(55.0f);
    filter.setLowPass(4500.0f);
    processInBlocks(filter, wet);
    expect(finite(wet), "utility-filter output must remain finite");
    expect(rms(wet, 4096) > 0.01, "utility filter must retain the bass fundamentals");
    expect(differenceRms(dry, wet, 4096) > 0.04, "utility filter must remove out-of-band energy");
}

void testCleanAmp() {
    const auto dry = bassSignal();
    auto wet = dry;
    CleanAmp amp;
    amp.setSampleRate(kSampleRate);
    amp.reset();
    processInBlocks(amp, wet);
    expect(finite(wet), "clean amp output must remain finite");
    expect(rms(wet, 4096) > 0.01, "clean amp must not mute the instrument");
    expect(differenceRms(dry, wet, 4096) > 0.001, "clean amp must shape the signal");
}

void testChorus() {
    const auto dry = bassSignal();
    auto wet = dry;
    Chorus chorus;
    chorus.setSampleRate(kSampleRate);
    chorus.setRate(0.8f);
    chorus.setDepth(0.7f);
    chorus.setMix(0.5f);
    chorus.reset();
    processInBlocks(chorus, wet);
    expect(finite(wet), "chorus output must remain finite");
    expect(differenceRms(dry, wet, 4096) > 0.001, "chorus must modulate the upper bass signal");
}

void testDelay() {
    std::vector<float> impulse(kFrames, 0.0f);
    impulse[0] = 1.0f;
    DelayFX delay;
    delay.setSampleRate(kSampleRate);
    delay.setTimeMs(50.0f);
    delay.setFeedback(0.0f);
    delay.setMix(1.0f);
    delay.reset();
    processInBlocks(delay, impulse);
    const int echo = static_cast<int>(kSampleRate * 0.050);
    expect(finite(impulse), "delay output must remain finite");
    expect(std::fabs(impulse[echo]) > 0.8f, "delay must emit an echo at the selected time");
}

void testReverb() {
    std::vector<float> impulse(kFrames, 0.0f);
    impulse[0] = 1.0f;
    Reverb reverb;
    reverb.setSampleRate(kSampleRate);
    reverb.setSize(0.7f);
    reverb.setDamp(0.35f);
    reverb.setMix(0.6f);
    reverb.reset();
    processInBlocks(reverb, impulse);
    expect(finite(impulse), "reverb output must remain finite");
    expect(rms(impulse, 2000) > 1.0e-4, "reverb must create a decaying tail");
}

void testCabinetIR() {
    std::vector<float> ir(128, 0.0f);
    ir[0] = 1.0f;
    CabinetIR cabinet;
    cabinet.setEngineRate(kSampleRate, 512);
    cabinet.setIR(ir.data(), ir.size(), kSampleRate);
    auto signal = bassSignal();
    for (int offset = 0; offset < static_cast<int>(signal.size()); offset += 128) {
        const int count = std::min(128, static_cast<int>(signal.size()) - offset);
        cabinet.process(signal.data() + offset, signal.data() + offset, count);
    }
    expect(cabinet.hasIR(), "cabinet must accept a valid impulse response");
    expect(finite(signal), "cabinet output must remain finite");
    expect(rms(signal, 4096) > 0.005, "cabinet convolution must not mute the signal");
}

void testTuner() {
    auto signal = bassSignal(0.2f);
    Tuner tuner;
    tuner.setSampleRate(kSampleRate);
    tuner.reset();
    for (int offset = 0; offset < kFrames; offset += 128)
        tuner.feed(signal.data() + offset, std::min(128, kFrames - offset));
    expect(std::fabs(tuner.frequency() - 110.0f) < 2.0f, "tuner must identify A2 near 110 Hz");
    expect(tuner.conf() > 0.5f, "tuner must report useful confidence");
}

void testResampler() {
    auto input = bassSignal();
    CubicResampler resampler;
    resampler.setRates(48000.0, 44100.0);
    const int expected = resampler.calcOutFrames(input.size());
    std::vector<float> output(expected);
    const int produced = resampler.process(input.data(), input.size(), output.data(), output.size());
    expect(produced == expected, "resampler must produce the calculated frame count");
    expect(finite(output), "resampler output must remain finite");
    expect(rms(output, 4096) > 0.005, "resampler must preserve an audible signal");

    // One second split into normal render callbacks must produce the same
    // number of frames as a one-shot conversion. This catches per-block
    // rounding drift that eventually fills one of the streaming queues.
    resampler.setRates(48000.0, 44100.0);
    std::vector<float> block(128, 0.1f);
    std::vector<float> converted(128, 0.0f);
    int streamingFrames = 0;
    for (int i = 0; i < 375; ++i) {
        const int target = resampler.calcOutFrames(block.size());
        streamingFrames += resampler.process(block.data(), block.size(), converted.data(), target);
    }
    expect(streamingFrames == 44100, "streaming resampler must preserve the exact long-run sample-rate ratio");
}

} // namespace

int main() {
    testToneEQ();
    testNoiseGate();
    testExpander();
    testNoiseReduction();
    testCompressor();
    testDrive();
    testBassOctaver();
    testEnvelopeFilter();
    testUtilityFilter();
    testCleanAmp();
    testChorus();
    testDelay();
    testReverb();
    testCabinetIR();
    testTuner();
    testResampler();

    if (failures == 0) {
        std::puts("DSP component tests passed");
        return EXIT_SUCCESS;
    }
    std::fprintf(stderr, "%d DSP component test(s) failed\n", failures);
    return EXIT_FAILURE;
}
