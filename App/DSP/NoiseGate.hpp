#pragma once

#include "BassBand.hpp"

#include <algorithm>
#include <cmath>

/// Opens when bass energy is present, stays shut on hiss and jack hum.
class NoiseGate {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        updateCoeffs();
        band.setSampleRate(sampleRate);
    }

    void setThresholdDb(float db) {
        if (thresholdDb != db) {
            thresholdDb = db;
            threshold = dbToLin(db);
        }
    }

    void reset() {
        band.reset();
        gain = 0;
        isOpen = false;
        holdRemaining = 0;
    }

    inline void process(float *buffer, int frames) {
        for (int i = 0; i < frames; ++i) {
            const float x = buffer[i];
            const float env = band.tick(x);

            if (env >= threshold) {
                isOpen = true;
                holdRemaining = holdSamples;
            } else if (isOpen) {
                if (env >= threshold * 0.55f) {
                    holdRemaining = holdSamples;
                } else if (holdRemaining > 0) {
                    --holdRemaining;
                } else {
                    isOpen = false;
                }
            }

            const float target = isOpen ? 1.0f : 0.0f;
            const float coeff = target > gain ? gainAttack : gainRelease;
            gain += coeff * (target - gain);
            if (gain < 1.0e-4f)
                gain = 0.0f;
            buffer[i] = x * gain;
        }
    }

private:
    double sampleRate = 48000.0;
    float thresholdDb = -40.0f;
    float threshold = dbToLin(-40.0f);
    float gain = 0;
    float gainAttack = 0.02f;
    float gainRelease = 0.001f;
    bool isOpen = false;
    int holdSamples = 2000;
    int holdRemaining = 0;
    BassBand band;

    void updateCoeffs() {
        gainAttack = 1.0f - std::exp(-1.0f / (float)(0.0015 * sampleRate));
        gainRelease = 1.0f - std::exp(-1.0f / (float)(0.025 * sampleRate));
        holdSamples = std::max(1, (int)(0.08 * sampleRate));
    }

    static float dbToLin(float db) { return std::pow(10.0f, db / 20.0f); }
};
