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
#include "Resampler.hpp"
#include "Reverb.hpp"
#include "Tuner.hpp"

#include <algorithm>
#include <cmath>
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
}

} // namespace

int main() {
    testToneEQ();
    testNoiseGate();
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
