#pragma once

#include "BiquadEQ.hpp"

#include <algorithm>
#include <cmath>

/// Dynamic tube preamp & power-amp emulation with power supply sag and harmonic bloom.
class CleanAmp {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        dirty = true;
    }

    void reset() {
        hp.reset();
        lp.reset();
        warmth.reset();
        dcX = dcY = 0;
        sagEnv = 0;
        dirty = true;
    }

    inline void process(float *buffer, int frames) {
        if (dirty)
            refresh();
        const float sagAtt = sagAttackCoeff;
        const float sagRel = sagReleaseCoeff;
        float env = sagEnv;

        for (int i = 0; i < frames; ++i) {
            float x = buffer[i];
            if (!std::isfinite(x))
                x = 0.0f;

            // DC Blocker
            float y = x - dcX + dcR * dcY;
            dcX = x;
            dcY = y;

            // Band shaping: tight subsonic 30 Hz HP, gentle 4.5 kHz tube roll-off
            y = hp.tick(y);
            y = lp.tick(y);

            // Tube power supply sag envelope detector
            const float absY = std::fabs(y);
            if (absY > env)
                env += sagAtt * (absY - env);
            else
                env += sagRel * (absY - env);

            // Dynamic sag headroom: compresses peaks on loud attacks, blooms sustain
            const float sagCompression = 1.0f / (1.0f + 0.65f * env);

            // Asymmetric tube transfer function (12AX7 / 6550 tube emulation)
            // Generates warm even-order 2nd harmonic + punchy 3rd harmonic
            const float bias = 0.08f * env;
            const float v = (y + bias) * sagCompression;
            const float v2 = v * v;
            float tubeSat = v / (1.0f + std::fabs(v) + 0.12f * v2);

            // Warmth presence shaping
            tubeSat = warmth.tick(tubeSat);

            if (std::fabs(tubeSat) < 1.0e-15f)
                tubeSat = 0.0f;
            buffer[i] = tubeSat;
        }
        sagEnv = env;
    }

private:
    double sampleRate = 48000.0;
    float dcR = 0.995f;
    float dcX = 0;
    float dcY = 0;
    float sagEnv = 0;
    float sagAttackCoeff = 0.02f;
    float sagReleaseCoeff = 0.0008f;
    Biquad hp;
    Biquad lp;
    Biquad warmth;
    bool dirty = true;

    void refresh() {
        dcR = 1.0f - (float)(2.0 * M_PI * 8.0 / sampleRate);
        dcR = std::clamp(dcR, 0.90f, 0.9997f);
        hp.set(Biquad::Type::HighPass, 28.0f, 0.0f, 0.7f, sampleRate);
        lp.set(Biquad::Type::LowPass, 4600.0f, 0.0f, 0.7f, sampleRate);
        warmth.set(Biquad::Type::Peak, 220.0f, 1.2f, 0.8f, sampleRate);

        // Sag time constants: ~6 ms attack, ~120 ms release for authentic power supply bloom
        sagAttackCoeff = 1.0f - std::exp(-1.0f / (0.006f * (float)sampleRate));
        sagReleaseCoeff = 1.0f - std::exp(-1.0f / (0.120f * (float)sampleRate));
        dirty = false;
    }
};

