#pragma once

#include "BiquadEQ.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

/// Dual-voice BBD chorus with Mono-Sub Lock (crossover split at 180 Hz).
/// Sub-bass frequencies (< 180 Hz) remain rock-solid and pitch-stable while
/// highs receive lush spatial modulation.
class Chorus {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        const int n = std::max(64, (int)(sampleRate * 0.050) + 8);
        if ((int)buf.size() != n) {
            buf.assign(n, 0.0f);
            w = 0;
        }
        phase = 0;
        phase2 = float(M_PI * 2.0 / 3.0);
        lowFilter.set(Biquad::Type::LowPass, 180.0f, 0.0f, 0.707f, sampleRate);
        highFilter.set(Biquad::Type::HighPass, 180.0f, 0.0f, 0.707f, sampleRate);
    }

    void setRate(float hz) { rate = std::clamp(hz, 0.05f, 8.0f); }
    void setDepth(float v) { depth = std::clamp(v, 0.0f, 1.0f); }
    void setMix(float v) { mix = std::clamp(v, 0.0f, 1.0f); }

    void reset() {
        std::fill(buf.begin(), buf.end(), 0.0f);
        w = 0;
        phase = 0;
        phase2 = float(M_PI * 2.0 / 3.0);
        lowFilter.reset();
        highFilter.reset();
    }

    inline void process(float *buffer, int frames) {
        if (buf.empty())
            return;
        const int n = (int)buf.size();
        const float twoPi = float(2.0 * M_PI);
        const float inc = twoPi * rate / float(sampleRate);
        const float baseMs = 12.0f;
        const float extraMs = 8.0f * depth;
        const float wetMix = mix * 0.5f;
        const float dryMix = 1.0f - mix * 0.5f;

        for (int i = 0; i < frames; ++i) {
            const float x = buffer[i];
            const float low = lowFilter.tick(x);
            const float high = highFilter.tick(x);

            buf[w] = high;

            const float d1 = (baseMs + extraMs * (0.5f + 0.5f * std::sin(phase))) * 0.001f * float(sampleRate);
            const float d2 = (baseMs + 3.0f + extraMs * (0.5f + 0.5f * std::sin(phase2))) * 0.001f * float(sampleRate);
            const float a = readAt(d1, n);
            const float b = readAt(d2, n);
            const float chorusedHigh = high * dryMix + (a + b) * wetMix;

            buffer[i] = low + chorusedHigh;

            if (++w >= n)
                w = 0;
            phase += inc;
            phase2 += inc;
            if (phase > twoPi)
                phase -= twoPi;
            if (phase2 > twoPi)
                phase2 -= twoPi;
        }
    }

private:
    std::vector<float> buf;
    int w = 0;
    double sampleRate = 48000.0;
    float rate = 0.8f;
    float depth = 0.4f;
    float mix = 0.35f;
    float phase = 0;
    float phase2 = 0;
    Biquad lowFilter;
    Biquad highFilter;

    inline float readAt(float delaySamples, int n) const {
        delaySamples = std::clamp(delaySamples, 1.0f, float(n - 2));
        float pos = float(w) - delaySamples;
        while (pos < 0.0f)
            pos += float(n);
        const int i0 = (int)pos;
        const int i1 = i0 + 1 < n ? i0 + 1 : 0;
        const float frac = pos - float(i0);
        return buf[i0] + (buf[i1] - buf[i0]) * frac;
    }
};

