#pragma once

#include "BassBand.hpp"

#include <algorithm>
#include <cmath>

/// Opens when bass energy is present. Hard-gate mode is for high-gain
/// presets. Expander mode is a split-band hiss cut: analog static lives in
/// the highs, so those stay down even while a bass note is passing.
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

    void setExpander(bool on) { expanderMode = on; }

    void setNoiseFloorDb(float db) {
        noiseFloorDb = std::clamp(db, -120.0f, 0.0f);
    }

    void reset() {
        band.reset();
        gain = expanderMode ? kIdleLow : 0.0f;
        lowGain = expanderMode ? kIdleLow : 0.0f;
        highGain = expanderMode ? kIdleHigh : 0.0f;
        isOpen = false;
        holdRemaining = 0;
        hfState = 0.0f;
        hfEnv = 0.0f;
        lpState = 0.0f;
    }

    inline void process(float *buffer, int frames) {
        if (expanderMode)
            processExpander(buffer, frames);
        else
            processGate(buffer, frames);
    }

private:
    static constexpr float kIdleLow = 0.018f;   // -35 dB
    static constexpr float kIdleHigh = 0.012f;  // -38 dB
    static constexpr float kPlayHigh = 0.10f;   // -20 dB of hiss while playing

    double sampleRate = 48000.0;
    float thresholdDb = -40.0f;
    float threshold = dbToLin(-40.0f);
    float noiseFloorDb = -90.0f;
    float gain = 0;
    float lowGain = 0;
    float highGain = 0;
    float gainAttack = 0.02f;
    float gainRelease = 0.001f;
    float expandAttack = 0.01f;
    float expandRelease = 0.0004f;
    float hfCoeff = 0.25f;
    float hfAttack = 0.04f;
    float hfRelease = 0.01f;
    float xoverCoeff = 0.23f;
    float hfState = 0.0f;
    float hfEnv = 0.0f;
    float lpState = 0.0f;
    bool expanderMode = false;
    bool isOpen = false;
    int holdSamples = 2000;
    int holdRemaining = 0;
    BassBand band;

    void updateCoeffs() {
        gainAttack = 1.0f - std::exp(-1.0f / (float)(0.0015 * sampleRate));
        gainRelease = 1.0f - std::exp(-1.0f / (float)(0.025 * sampleRate));
        expandAttack = 1.0f - std::exp(-1.0f / (float)(0.006 * sampleRate));
        expandRelease = 1.0f - std::exp(-1.0f / (float)(0.045 * sampleRate));
        hfCoeff = 1.0f - std::exp(-2.0f * float(M_PI) * 2200.0f / float(sampleRate));
        hfAttack = 1.0f - std::exp(-1.0f / (float)(0.004 * sampleRate));
        hfRelease = 1.0f - std::exp(-1.0f / (float)(0.040 * sampleRate));
        xoverCoeff = 1.0f - std::exp(-2.0f * float(M_PI) * 2000.0f / float(sampleRate));
        holdSamples = std::max(1, (int)(0.08 * sampleRate));
    }

    static float dbToLin(float db) { return std::pow(10.0f, db / 20.0f); }

    inline void processGate(float *buffer, int frames) {
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

    inline void processExpander(float *buffer, int frames) {
        if (lowGain + highGain < 1.0e-5f) {
            lowGain = kIdleLow;
            highGain = kIdleHigh;
        }

        for (int i = 0; i < frames; ++i) {
            const float x = buffer[i];
            const float lf = band.tick(x);

            hfState += hfCoeff * (x - hfState);
            const float hfDet = std::fabs(x - hfState);
            if (hfDet > hfEnv)
                hfEnv += hfAttack * (hfDet - hfEnv);
            else
                hfEnv += hfRelease * (hfDet - hfEnv);

            // Analog hiss and ADC hash are broadband. A bass note is
            // low-band dominant. Do not treat cable noise as a held note.
            const float tot = lf + hfEnv + 1.0e-8f;
            bool note = lf > 0.012f && (lf / tot) > 0.55f;
            if (note) {
                holdRemaining = holdSamples;
            } else if (holdRemaining > 0) {
                --holdRemaining;
                note = true;
            }

            lpState += xoverCoeff * (x - lpState);
            const float hp = x - lpState;
            const float lowTarget = note ? 1.0f : kIdleLow;
            const float highTarget = note ? kPlayHigh : kIdleHigh;
            const float lowCoeff = lowTarget > lowGain ? expandAttack : expandRelease;
            const float highCoeff = highTarget > highGain ? expandAttack : expandRelease;
            lowGain += lowCoeff * (lowTarget - lowGain);
            highGain += highCoeff * (highTarget - highGain);
            buffer[i] = lpState * lowGain + hp * highGain;
        }
    }
};
