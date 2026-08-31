#include "AmpProcessor.h"
#include "json.hpp"

#include <algorithm>
#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace {

using json = nlohmann::json;

template <typename T>
T value(const json &preset, const char *key, T fallback) {
    const auto found = preset.find(key);
    return found == preset.end() || found->is_null() ? fallback : found->get<T>();
}

uint16_t readU16(const unsigned char *p) {
    return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1] << 8);
}

uint32_t readU32(const unsigned char *p) {
    return static_cast<uint32_t>(p[0])
        | (static_cast<uint32_t>(p[1]) << 8)
        | (static_cast<uint32_t>(p[2]) << 16)
        | (static_cast<uint32_t>(p[3]) << 24);
}

bool loadWavMono(const std::filesystem::path &path, std::vector<float> &samples, double &sampleRate) {
    std::ifstream stream(path, std::ios::binary);
    unsigned char riff[12]{};
    if (!stream.read(reinterpret_cast<char *>(riff), sizeof(riff))
        || std::memcmp(riff, "RIFF", 4) != 0 || std::memcmp(riff + 8, "WAVE", 4) != 0)
        return false;

    uint16_t format = 0;
    uint16_t channels = 0;
    uint16_t bits = 0;
    std::vector<unsigned char> audio;
    while (stream) {
        unsigned char header[8]{};
        if (!stream.read(reinterpret_cast<char *>(header), sizeof(header)))
            break;
        const uint32_t size = readU32(header + 4);
        std::vector<unsigned char> chunk(size);
        if (!stream.read(reinterpret_cast<char *>(chunk.data()), size))
            return false;
        if (std::memcmp(header, "fmt ", 4) == 0 && size >= 16) {
            format = readU16(chunk.data());
            channels = readU16(chunk.data() + 2);
            sampleRate = readU32(chunk.data() + 4);
            bits = readU16(chunk.data() + 14);
        } else if (std::memcmp(header, "data", 4) == 0) {
            audio = std::move(chunk);
        }
        if (size & 1)
            stream.ignore(1);
    }
    if (format != 1 || channels == 0 || bits != 16 || audio.empty())
        return false;

    const int frameBytes = channels * 2;
    const int frames = static_cast<int>(audio.size()) / frameBytes;
    samples.assign(frames, 0.0f);
    for (int frame = 0; frame < frames; ++frame) {
        float sum = 0;
        for (int channel = 0; channel < channels; ++channel) {
            const auto *p = audio.data() + frame * frameBytes + channel * 2;
            const int16_t pcm = static_cast<int16_t>(readU16(p));
            sum += pcm / 32768.0f;
        }
        samples[frame] = sum / channels;
    }
    return true;
}

bool testModel(void *processor, const char *path) {
    char error[512]{};
    if (!AmpProcessorLoadNAM(processor, path, error, sizeof(error))) {
        std::fprintf(stderr, "FAIL: could not load %s: %s\n", path, error);
        return false;
    }
    if (!AmpProcessorHasNAM(processor)) {
        std::fprintf(stderr, "FAIL: model did not become active: %s\n", path);
        return false;
    }

    constexpr int block = 128;
    constexpr int blocks = 240;
    std::vector<float> input(block);
    std::vector<float> output(block);
    double energy = 0;
    bool finite = true;
    for (int b = 0; b < blocks; ++b) {
        for (int i = 0; i < block; ++i) {
            const int frame = b * block + i;
            input[i] = 0.12f * std::sin(2.0 * M_PI * 110.0 * frame / 48000.0)
                + 0.025f * std::sin(2.0 * M_PI * 440.0 * frame / 48000.0);
        }
        AmpProcessorProcess(processor, input.data(), output.data(), block);
        if (b > 20) {
            for (float sample : output) {
                finite = finite && std::isfinite(sample);
                energy += static_cast<double>(sample) * sample;
            }
        }
    }
    AmpProcessorUnloadNAM(processor);
    if (!finite || energy < 1.0e-6) {
        std::fprintf(stderr, "FAIL: model produced invalid or silent audio: %s\n", path);
        return false;
    }
    std::printf("NAM model passed: %s\n", path);
    return true;
}

bool testFIFO() {
    void *fifo = AmpAudioFIFOCreate(8);
    float input[10] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
    float output[8]{};
    const int written = AmpAudioFIFOWrite(fifo, input, 10);
    const int read = AmpAudioFIFORead(fifo, output, 8);
    const auto stats = AmpAudioFIFOGetStats(fifo);
    AmpAudioFIFODestroy(fifo);
    const bool ordered = std::equal(output, output + 8, input);
    if (written != 8 || read != 8 || !ordered || stats.overflowFrames != 2) {
        std::fprintf(stderr, "FAIL: audio FIFO regression\n");
        return false;
    }
    std::puts("Audio FIFO test passed");
    return true;
}

bool testPreset(void *processor, const json &preset, const std::filesystem::path &resourceRoot) {
    AmpProcessorReset(processor, 48000.0, 1024);
    AmpProcessorSetInputGainDb(processor, value<float>(preset, "inputGainDb", 0.0f));
    AmpProcessorSetOutputGainDb(processor, value<float>(preset, "outputGainDb", 0.0f));
    AmpProcessorSetGateThresholdDb(processor, value<float>(preset, "gateThresholdDb", -40.0f));
    AmpProcessorSetBassDb(processor, value<float>(preset, "bassDb", 0.0f));
    AmpProcessorSetMidDb(processor, value<float>(preset, "midDb", 0.0f));
    AmpProcessorSetTrebleDb(processor, value<float>(preset, "trebleDb", 0.0f));
    AmpProcessorSetMidFreqIndex(processor, value<int>(preset, "midFreqIndex", 1));
    AmpProcessorSetUltraLoOn(processor, value<bool>(preset, "ultraLoOn", false));
    AmpProcessorSetUltraHiOn(processor, value<bool>(preset, "ultraHiOn", false));
    AmpProcessorSetGateOn(processor, value<bool>(preset, "gateOn", false));
    AmpProcessorSetNAMOn(processor, value<bool>(preset, "namOn", true));
    AmpProcessorSetIROn(processor, value<bool>(preset, "irOn", true));
    AmpProcessorSetEQOn(processor, value<bool>(preset, "eqOn", true));
    AmpProcessorSetBypass(processor, false);
    AmpProcessorSetCompOn(processor, value<bool>(preset, "compOn", false));
    AmpProcessorSetCompThresholdDb(processor, value<float>(preset, "compThresholdDb", -24.0f));
    AmpProcessorSetCompRatio(processor, value<float>(preset, "compRatio", 4.0f));
    AmpProcessorSetCompMakeupDb(processor, value<float>(preset, "compMakeupDb", 2.0f));
    AmpProcessorSetDriveOn(processor, value<bool>(preset, "driveOn", false));
    AmpProcessorSetDriveAmount(processor, value<float>(preset, "driveAmount", 0.35f));
    AmpProcessorSetDriveTone(processor, value<float>(preset, "driveTone", 0.5f));
    AmpProcessorSetDriveMix(processor, value<float>(preset, "driveMix", 0.55f));
    AmpProcessorSetOctaverOn(processor, value<bool>(preset, "octaverOn", false));
    AmpProcessorSetOctaverMix(processor, value<float>(preset, "octaverMix", 0.35f));
    AmpProcessorSetOctaverTone(processor, value<float>(preset, "octaverTone", 0.45f));
    AmpProcessorSetEnvelopeOn(processor, value<bool>(preset, "envelopeOn", false));
    AmpProcessorSetEnvelopeSensitivity(processor, value<float>(preset, "envelopeSensitivity", 0.55f));
    AmpProcessorSetEnvelopeResonance(processor, value<float>(preset, "envelopeResonance", 0.45f));
    AmpProcessorSetEnvelopeMix(processor, value<float>(preset, "envelopeMix", 0.65f));
    AmpProcessorSetChorusOn(processor, value<bool>(preset, "chorusOn", false));
    AmpProcessorSetChorusRate(processor, value<float>(preset, "chorusRate", 0.8f));
    AmpProcessorSetChorusDepth(processor, value<float>(preset, "chorusDepth", 0.4f));
    AmpProcessorSetChorusMix(processor, value<float>(preset, "chorusMix", 0.35f));
    AmpProcessorSetDelayOn(processor, value<bool>(preset, "delayOn", false));
    AmpProcessorSetDelayTimeMs(processor, value<float>(preset, "delayTimeMs", 180.0f));
    AmpProcessorSetDelayFeedback(processor, value<float>(preset, "delayFeedback", 0.28f));
    AmpProcessorSetDelayMix(processor, value<float>(preset, "delayMix", 0.22f));
    AmpProcessorSetReverbOn(processor, value<bool>(preset, "reverbOn", false));
    AmpProcessorSetReverbSize(processor, value<float>(preset, "reverbSize", 0.4f));
    AmpProcessorSetReverbDamp(processor, value<float>(preset, "reverbDamp", 0.45f));
    AmpProcessorSetReverbMix(processor, value<float>(preset, "reverbMix", 0.2f));
    AmpProcessorSetUtilityFilterOn(processor, value<bool>(preset, "utilityFilterOn", true));
    AmpProcessorSetHighPassHz(processor, value<float>(preset, "utilityHighPassHz", 32.0f));
    AmpProcessorSetLowPassHz(processor, value<float>(preset, "utilityLowPassHz", 12000.0f));

    const std::string namFile = value<std::string>(preset, "namFile", "");
    if (!namFile.empty()) {
        char error[512]{};
        const auto path = resourceRoot / "Models" / namFile;
        if (!AmpProcessorLoadNAM(processor, path.c_str(), error, sizeof(error))) {
            std::fprintf(stderr, "FAIL: preset %s could not load NAM: %s\n",
                value<std::string>(preset, "name", "unnamed").c_str(), error);
            return false;
        }
    } else {
        AmpProcessorUnloadNAM(processor);
    }

    const std::string irFile = value<std::string>(preset, "irFile", "");
    if (!irFile.empty()) {
        std::vector<float> ir;
        double rate = 0;
        if (!loadWavMono(resourceRoot / "IRs" / irFile, ir, rate)
            || !AmpProcessorLoadIR(processor, ir.data(), ir.size(), rate)) {
            std::fprintf(stderr, "FAIL: preset %s could not load cabinet IR\n",
                value<std::string>(preset, "name", "unnamed").c_str());
            return false;
        }
    } else {
        AmpProcessorUnloadIR(processor);
    }

    constexpr int block = 128;
    std::vector<float> input(block);
    std::vector<float> output(block);
    double energy = 0;
    bool finite = true;
    for (int b = 0; b < 375; ++b) {
        for (int i = 0; i < block; ++i) {
            const int frame = b * block + i;
            const float envelope = std::min(1.0f, frame / 480.0f);
            input[i] = envelope * (0.16f * std::sin(2.0 * M_PI * 110.0 * frame / 48000.0)
                + 0.035f * std::sin(2.0 * M_PI * 440.0 * frame / 48000.0));
        }
        AmpProcessorProcess(processor, input.data(), output.data(), block);
        if (b > 40) {
            for (float sample : output) {
                finite = finite && std::isfinite(sample);
                energy += static_cast<double>(sample) * sample;
            }
        }
    }
    AmpProcessorUnloadNAM(processor);
    AmpProcessorUnloadIR(processor);
    if (!finite || energy < 1.0e-6) {
        std::fprintf(stderr, "FAIL: preset %s produced invalid or silent audio\n",
            value<std::string>(preset, "name", "unnamed").c_str());
        return false;
    }
    std::printf("Factory preset passed: %s\n", value<std::string>(preset, "name", "unnamed").c_str());
    return true;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s factory-presets.json resource-root model.nam [...]\n", argv[0]);
        return EXIT_FAILURE;
    }
    void *processor = AmpProcessorShared();
    AmpProcessorReset(processor, 48000.0, 512);
    AmpProcessorSetGateOn(processor, false);
    AmpProcessorSetIROn(processor, false);
    AmpProcessorSetEQOn(processor, false);
    AmpProcessorSetCompOn(processor, false);
    AmpProcessorSetDriveOn(processor, false);
    AmpProcessorSetOctaverOn(processor, false);
    AmpProcessorSetEnvelopeOn(processor, false);
    AmpProcessorSetChorusOn(processor, false);
    AmpProcessorSetDelayOn(processor, false);
    AmpProcessorSetReverbOn(processor, false);
    AmpProcessorSetUtilityFilterOn(processor, false);
    AmpProcessorSetNAMOn(processor, true);
    AmpProcessorSetInputGainDb(processor, 0.0f);
    AmpProcessorSetOutputGainDb(processor, 0.0f);

    bool passed = testFIFO();
    for (int i = 3; i < argc; ++i)
        passed = testModel(processor, argv[i]) && passed;

    std::ifstream presetStream(argv[1]);
    json presets;
    try {
        presetStream >> presets;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: could not parse factory presets: %s\n", error.what());
        return EXIT_FAILURE;
    }
    for (const auto &preset : presets)
        passed = testPreset(processor, preset, argv[2]) && passed;
    return passed ? EXIT_SUCCESS : EXIT_FAILURE;
}
