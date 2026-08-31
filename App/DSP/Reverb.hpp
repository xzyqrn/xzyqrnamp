#pragma once

#include "BiquadEQ.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

/// Studio bass reverb with Mono-Sub Lock (crossover split at 180 Hz).
/// Sub-bass frequencies (< 180 Hz) remain dry and punchy while mids/highs
/// receive rich room diffusion.
class Reverb {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        const float scale = float(sampleRate / 44100.0);
        const int combBase[4] = {1116, 1188, 1277, 1356};
        const int apBase[2] = {225, 556};
        for (int i = 0; i < 4; ++i)
            combs[i].allocate(std::max(32, int(combBase[i] * scale * 2.2f)));
        for (int i = 0; i < 2; ++i)
            allpass[i].allocate(std::max(16, int(apBase[i] * scale * 2.2f)));
        lowFilter.set(Biquad::Type::LowPass, 180.0f, 0.0f, 0.707f, sampleRate);
        highFilter.set(Biquad::Type::HighPass, 180.0f, 0.0f, 0.707f, sampleRate);
        refreshLengths();
    }

    void setSize(float v) {
        size = std::clamp(v, 0.0f, 1.0f);
        refreshLengths();
    }
    void setDamp(float v) { damp = std::clamp(v, 0.0f, 1.0f); }
    void setMix(float v) { mix = std::clamp(v, 0.0f, 1.0f); }

    void reset() {
        for (int i = 0; i < 4; ++i)
            combs[i].clear();
        for (int i = 0; i < 2; ++i)
            allpass[i].clear();
        lowFilter.reset();
        highFilter.reset();
    }

    inline void process(float *buffer, int frames) {
        const float feedback = 0.72f + 0.26f * size;
        const float dampAmt = 0.15f + 0.7f * damp;
        const float wetMix = mix;
        const float dryMix = 1.0f - mix * 0.7f;

        for (int i = 0; i < frames; ++i) {
            const float x = buffer[i];
            const float low = lowFilter.tick(x);
            const float high = highFilter.tick(x);

            float acc = 0;
            acc += combs[0].process(high, feedback, dampAmt);
            acc += combs[1].process(high, feedback, dampAmt);
            acc += combs[2].process(high, feedback, dampAmt);
            acc += combs[3].process(high, feedback, dampAmt);
            acc *= 0.25f;
            acc = allpass[0].process(acc);
            acc = allpass[1].process(acc);

            const float reverbedHigh = high * dryMix + acc * wetMix;
            buffer[i] = low + reverbedHigh;
        }
    }

private:
    struct Comb {
        std::vector<float> buf;
        int cap = 0;
        int len = 1;
        int idx = 0;
        float filter = 0;

        void allocate(int n) {
            cap = std::max(32, n);
            buf.assign(cap, 0.0f);
            idx = 0;
            filter = 0;
            len = cap;
        }
        void setLength(int n) {
            len = std::clamp(n, 1, std::max(1, cap));
            if (idx >= len)
                idx = 0;
        }
        void clear() {
            std::fill(buf.begin(), buf.end(), 0.0f);
            idx = 0;
            filter = 0;
        }
        inline float process(float input, float fb, float dampAmt) {
            if (buf.empty())
                return 0;
            float y = buf[idx];
            if (std::fabs(y) < 1.0e-15f)
                y = 0.0f;
            filter += (1.0f - dampAmt) * (y - filter);
            if (std::fabs(filter) < 1.0e-15f)
                filter = 0.0f;
            buf[idx] = input + filter * fb;
            if (++idx >= len)
                idx = 0;
            return y;
        }
    };

    struct Allpass {
        std::vector<float> buf;
        int cap = 0;
        int len = 1;
        int idx = 0;

        void allocate(int n) {
            cap = std::max(16, n);
            buf.assign(cap, 0.0f);
            idx = 0;
            len = cap;
        }
        void setLength(int n) {
            len = std::clamp(n, 1, std::max(1, cap));
            if (idx >= len)
                idx = 0;
        }
        void clear() {
            std::fill(buf.begin(), buf.end(), 0.0f);
            idx = 0;
        }
        inline float process(float input) {
            if (buf.empty())
                return input;
            const float bufout = buf[idx];
            // Standard Schroeder allpass: y[n] = -g * x[n] + w[n-D], w[n] = x[n] + g * w[n-D]
            const float y = -0.5f * input + bufout;
            buf[idx] = input + bufout * 0.5f;
            if (++idx >= len)
                idx = 0;
            return y;
        }
    };

    Comb combs[4];
    Allpass allpass[2];
    double sampleRate = 48000.0;
    float size = 0.4f;
    float damp = 0.45f;
    float mix = 0.2f;
    Biquad lowFilter;
    Biquad highFilter;

    void refreshLengths() {
        const float scale = float(sampleRate / 44100.0);
        const float span = 0.55f + 0.7f * size;
        const int combBase[4] = {1116, 1188, 1277, 1356};
        const int apBase[2] = {225, 556};
        for (int i = 0; i < 4; ++i)
            combs[i].setLength(std::max(32, int(combBase[i] * scale * span)));
        for (int i = 0; i < 2; ++i)
            allpass[i].setLength(std::max(16, int(apBase[i] * scale * span)));
    }
};
