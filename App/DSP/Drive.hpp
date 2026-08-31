#pragma once

#include "BiquadEQ.hpp"

#include <algorithm>
#include <cmath>

/// Bi-amp crossover overdrive for bass (Darkglass / SansAmp style).
/// Keeps sub/low bass clean and punchy while saturating mids and highs.
class Drive {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        dirty = true;
    }

    void setAmount(float v) { amount = std::clamp(v, 0.0f, 1.0f); }
    void setTone(float v) {
        tone = std::clamp(v, 0.0f, 1.0f);
        dirty = true;
    }
    void setMix(float v) { mix = std::clamp(v, 0.0f, 1.0f); }

    void reset() {
        lowFilter.reset();
        highFilter.reset();
        toneFilter.reset();
        dirty = true;
    }

    inline void process(float *buffer, int frames) {
        if (dirty)
            refresh();

        const float driveGain = 1.0f + amount * 18.0f;
        const float wetMix = mix;
        const float dryMix = 1.0f - wetMix;

        for (int i = 0; i < frames; ++i) {
            const float dry = buffer[i];

            // Crossover split at ~280 Hz
            const float low = lowFilter.tick(dry);
            const float high = highFilter.tick(dry);

            // Low end remains clean & solid with subtle soft saturation
            const float lowProcessed = std::tanh(low * 1.15f) * 0.95f;

            // High end gets overdriven and tone-filtered
            const float highDist = std::tanh(high * driveGain);
            const float highShaped = toneFilter.tick(highDist);

            const float wet = lowProcessed + highShaped;
            buffer[i] = dry * dryMix + wet * wetMix;
        }
    }

private:
    double sampleRate = 48000.0;
    float amount = 0.35f;
    float tone = 0.5f;
    float mix = 0.55f;
    bool dirty = true;

    Biquad lowFilter;
    Biquad highFilter;
    Biquad toneFilter;

    void refresh() {
        const float crossoverHz = 280.0f;
        lowFilter.set(Biquad::Type::LowPass, crossoverHz, 0.0f, 0.7071f, sampleRate);
        highFilter.set(Biquad::Type::HighPass, crossoverHz, 0.0f, 0.7071f, sampleRate);

        const float toneCutoff = 1200.0f + 6800.0f * (tone * tone);
        toneFilter.set(Biquad::Type::LowPass, toneCutoff, 0.0f, 0.7071f, sampleRate);
        dirty = false;
    }
};

