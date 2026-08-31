#pragma once

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

class CubicResampler {
public:
    void setRates(double inRate, double outRate) {
        const double in = inRate > 1.0 ? inRate : 48000.0;
        const double out = outRate > 1.0 ? outRate : 48000.0;
        inRate_ = in;
        outRate_ = out;
        increment = in / out;
        active = std::fabs(in - out) > 0.5;
        reset();
    }

    void reset() {
        x[0] = x[1] = x[2] = x[3] = 0.0f;
        pha = 0.0;
        outputFrameRemainder = 0.0;
        queue.assign(kQueueCap, 0.0f);
        qHead = 0;
        qTail = 0;
        qCount = 0;
        initialized = false;
    }

    bool needsConvert() const { return active; }

    int calcOutFrames(int inFrames) {
        if (!active)
            return inFrames;
        // Carry the fractional frame across callbacks. Rounding every block
        // independently creates a permanent rate mismatch (for example,
        // 128 frames at 48 kHz is 117.6 frames at 44.1 kHz, not 118 forever).
        const double exactFrames = outputFrameRemainder + inFrames * (outRate_ / inRate_);
        const int frames = std::max(1, static_cast<int>(std::floor(exactFrames + 1.0e-9)));
        outputFrameRemainder = exactFrames - frames;
        return frames;
    }

    int process(const float *in, int nIn, float *out, int maxOut) {
        if (!active) {
            const int n = std::min(nIn, maxOut);
            if (in != out && n > 0 && in && out)
                std::memcpy(out, in, n * sizeof(float));
            return n;
        }

        if (!out || maxOut <= 0)
            return 0;

        // Push new incoming samples into circular queue
        if (in && nIn > 0) {
            for (int i = 0; i < nIn; ++i) {
                if (qCount < kQueueCap) {
                    queue[qTail] = in[i];
                    qTail = (qTail + 1) & (kQueueCap - 1);
                    ++qCount;
                }
            }
        }

        // Initialize 4-point window on first run with first available sample
        if (!initialized && qCount > 0) {
            float first = queue[qHead];
            x[0] = x[1] = x[2] = x[3] = first;
            initialized = true;
        }

        int outIdx = 0;
        while (outIdx < maxOut) {
            while (pha >= 1.0) {
                if (qCount > 0) {
                    x[0] = x[1];
                    x[1] = x[2];
                    x[2] = x[3];
                    x[3] = queue[qHead];
                    qHead = (qHead + 1) & (kQueueCap - 1);
                    --qCount;
                } else {
                    // Hold last known sample if queue momentarily starved
                    x[0] = x[1];
                    x[1] = x[2];
                    x[2] = x[3];
                }
                pha -= 1.0;
            }
            out[outIdx++] = hermite(static_cast<float>(pha));
            pha += increment;
        }

        return outIdx;
    }

private:
    static constexpr int kQueueCap = 4096;
    bool active = false;
    bool initialized = false;
    double inRate_ = 48000.0;
    double outRate_ = 48000.0;
    double increment = 1.0;
    double pha = 0.0;
    double outputFrameRemainder = 0.0;
    float x[4] = {0.0f, 0.0f, 0.0f, 0.0f};

    std::vector<float> queue = std::vector<float>(kQueueCap, 0.0f);
    int qHead = 0;
    int qTail = 0;
    int qCount = 0;

    inline float hermite(float t) const {
        const float c0 = x[1];
        const float c1 = 0.5f * (x[2] - x[0]);
        const float c2 = x[0] - 2.5f * x[1] + 2.0f * x[2] - 0.5f * x[3];
        const float c3 = 0.5f * (x[3] - x[0]) + 1.5f * (x[1] - x[2]);
        return ((c3 * t + c2) * t + c1) * t + c0;
    }
};
