#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

class Tuner {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        downsample = std::max(1, (int)std::lround(sampleRate / 6000.0));
        dsRate = sampleRate / downsample;
        hop = 256;
        minLag = std::max(4, (int)(dsRate / 450.0));
        maxLag = std::min(kSize / 2 - 2, (int)(dsRate / 24.0));
    }

    void reset() {
        write = 0;
        dsHold = 0;
        dsAcc = 0;
        dsCount = 0;
        filled = false;
        samplesSince = 0;
        quietSamples = 0;
        std::fill(buf.begin(), buf.end(), 0.0f);
        std::fill(ordered.begin(), ordered.end(), 0.0f);
        std::fill(correlations.begin(), correlations.end(), 0.0f);
        hz.store(0.0f);
        confidence.store(0.0f);
    }

    void feed(const float *x, int n) {
        float peak = 0.0f;
        for (int i = 0; i < n; ++i) {
            peak = std::max(peak, std::fabs(x[i]));
            dsAcc += x[i];
            dsCount += 1;
            if (dsCount >= downsample) {
                buf[write] = dsAcc / (float)dsCount;
                write = (write + 1) & (kSize - 1);
                if (write == 0)
                    filled = true;
                dsAcc = 0;
                dsCount = 0;
                samplesSince += 1;
            }
        }
        if (peak < kSilencePeak) {
            quietSamples += n;
            if (quietSamples >= (int)(sampleRate * 0.12)) {
                hz.store(0.0f, std::memory_order_relaxed);
                confidence.store(0.0f, std::memory_order_relaxed);
            }
        } else {
            quietSamples = 0;
        }
        if (filled && samplesSince >= hop) {
            samplesSince = 0;
            analyze();
        }
    }

    float frequency() const { return hz.load(std::memory_order_relaxed); }
    float conf() const { return confidence.load(std::memory_order_relaxed); }

private:
    static constexpr int kSize = 1024;
    static constexpr float kSilencePeak = 0.001f;
    double sampleRate = 48000.0;
    double dsRate = 6000.0;
    int downsample = 8;
    int hop = 256;
    int minLag = 13;
    int maxLag = 250;
    int write = 0;
    int samplesSince = 0;
    int quietSamples = 0;
    int dsCount = 0;
    float dsAcc = 0;
    int dsHold = 0;
    bool filled = false;
    std::vector<float> buf = std::vector<float>(kSize, 0.0f);
    std::vector<float> ordered = std::vector<float>(kSize, 0.0f);
    std::vector<float> correlations = std::vector<float>(kSize / 2, 0.0f);
    std::atomic<float> hz{0};
    std::atomic<float> confidence{0};

    void analyze() {
        for (int i = 0; i < kSize; ++i)
            ordered[i] = buf[(write + i) & (kSize - 1)];

        float mean = 0;
        for (float sample : ordered)
            mean += sample;
        mean /= (float)kSize;

        float energy0 = 0;
        for (int i = 0; i < kSize; ++i) {
            ordered[i] -= mean;
            energy0 += ordered[i] * ordered[i];
        }
        if (energy0 < (float)kSize * 1.0e-6f) {
            hz.store(0);
            confidence.store(0);
            return;
        }

        float bestCorr = 0;
        int bestLag = 0;
        for (int lag = minLag; lag < maxLag; ++lag) {
            float acc = 0;
            float energyA = 0;
            float energyB = 0;
            const int count = kSize - lag;
            const float *a = ordered.data();
            const float *b = ordered.data() + lag;
            for (int i = 0; i < count; ++i) {
                acc += a[i] * b[i];
                energyA += a[i] * a[i];
                energyB += b[i] * b[i];
            }
            const float denom = std::sqrt(energyA * energyB);
            const float corr = denom > 1.0e-12f ? acc / denom : 0.0f;
            correlations[lag] = corr;
            if (corr > bestCorr) {
                bestCorr = corr;
                bestLag = lag;
            }
        }

        if (bestLag <= 0 || bestCorr < 0.52f) {
            hz.store(0);
            confidence.store(bestCorr);
            return;
        }

        // Prefer earliest strong local peak to avoid octave-down subharmonic locks
        const float peakFloor = std::max(0.52f, bestCorr * 0.88f);
        for (int lag = minLag + 1; lag + 1 < maxLag; ++lag) {
            if (correlations[lag] >= peakFloor
                && correlations[lag] >= correlations[lag - 1]
                && correlations[lag] >= correlations[lag + 1]) {
                bestLag = lag;
                bestCorr = correlations[lag];
                break;
            }
        }

        float refined = (float)bestLag;
        if (bestLag > minLag && bestLag + 1 < maxLag) {
            const float ym1 = correlations[bestLag - 1];
            const float y0 = correlations[bestLag];
            const float yp1 = correlations[bestLag + 1];
            const float denom = (ym1 - 2.0f * y0 + yp1);
            if (std::fabs(denom) > 1.0e-12f)
                refined += 0.5f * (ym1 - yp1) / denom;
        }

        hz.store((float)(dsRate / refined));
        confidence.store(std::clamp(bestCorr, 0.0f, 1.0f));
    }
};

