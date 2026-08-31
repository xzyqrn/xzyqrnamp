#pragma once

#include <algorithm>
#include <cmath>
#include <vector>

class DelayFX {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        const int n = std::max(256, (int)(sampleRate * 2.0) + 8);
        if ((int)buf.size() != n) {
            buf.assign(n, 0.0f);
            w = 0;
        }
    }

    void setTimeMs(float ms) { timeMs = std::clamp(ms, 20.0f, 1800.0f); }
    void setFeedback(float v) { feedback = std::clamp(v, 0.0f, 0.92f); }
    void setMix(float v) { mix = std::clamp(v, 0.0f, 1.0f); }

    void reset() {
        std::fill(buf.begin(), buf.end(), 0.0f);
        w = 0;
    }

    inline void process(float *buffer, int frames) {
        if (buf.empty())
            return;
        const int n = (int)buf.size();
        const float delaySamp = std::clamp(timeMs * 0.001f * float(sampleRate), 1.0f, float(n - 2));
        const float fb = feedback;
        const float wetMix = mix;
        const float dryMix = 1.0f - mix;

        for (int i = 0; i < frames; ++i) {
            const float x = buffer[i];
            float delayed = readAt(delaySamp, n);
            if (std::fabs(delayed) < 1.0e-15f)
                delayed = 0.0f;
            buf[w] = x + delayed * fb;
            if (++w >= n)
                w = 0;
            buffer[i] = x * dryMix + delayed * wetMix;
        }
    }

private:
    std::vector<float> buf;
    int w = 0;
    double sampleRate = 48000.0;
    float timeMs = 180.0f;
    float feedback = 0.28f;
    float mix = 0.22f;

    inline float readAt(float delaySamples, int n) const {
        float pos = float(w) - delaySamples;
        while (pos < 0.0f)
            pos += float(n);
        const int i0 = (int)pos;
        const int i1 = i0 + 1 < n ? i0 + 1 : 0;
        const float frac = pos - float(i0);
        return buf[i0] + (buf[i1] - buf[i0]) * frac;
    }
};
