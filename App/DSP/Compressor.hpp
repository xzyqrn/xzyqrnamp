#pragma once

#include <algorithm>
#include <cmath>

/// Studio optical-style bass compressor with sidechain HPF to prevent low-end pumping.
class Compressor {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        attackCoeff = 1.0f - std::exp(-1.0f / (float)(0.008 * sampleRate));
        releaseCoeff = 1.0f - std::exp(-1.0f / (float)(0.080 * sampleRate));
        scHpfCoeff = 1.0f - std::exp(-2.0f * float(M_PI) * 90.0f / float(sampleRate));
    }

    void setThresholdDb(float db) { thresholdDb = std::clamp(db, -60.0f, 0.0f); }
    void setRatio(float r) { ratio = std::max(1.0f, r); }
    void setMakeupDb(float db) {
        const float clamped = std::clamp(db, 0.0f, 24.0f);
        if (makeupDb != clamped) {
            makeupDb = clamped;
            makeup = std::pow(10.0f, makeupDb / 20.0f);
        }
    }

    void reset() {
        envelopeDb = -80.0f;
        gain = 1.0f;
        scHpfState = 0.0f;
    }

    inline void process(float *buffer, int frames) {
        const float slope = 1.0f - 1.0f / ratio;
        for (int i = 0; i < frames; ++i) {
            const float x = buffer[i];

            // 90 Hz sidechain HPF to prevent heavy low-E/B fundamental from triggering excessive pumping
            scHpfState += scHpfCoeff * (x - scHpfState);
            if (std::fabs(scHpfState) < 1.0e-15f)
                scHpfState = 0.0f;
            const float scSignal = x - scHpfState;

            const float absSc = std::fabs(scSignal);
            const float detDb = absSc > 1.0e-7f ? 20.0f * std::log10(absSc) : -140.0f;
            const float coeff = detDb > envelopeDb ? attackCoeff : releaseCoeff;
            envelopeDb += coeff * (detDb - envelopeDb);

            if (envelopeDb < -120.0f)
                envelopeDb = -120.0f;

            float gainDb = 0.0f;
            if (envelopeDb > thresholdDb)
                gainDb = -slope * (envelopeDb - thresholdDb);

            const float target = std::pow(10.0f, gainDb / 20.0f) * makeup;
            gain += 0.25f * (target - gain);
            if (std::fabs(gain) < 1.0e-15f)
                gain = 0.0f;

            buffer[i] = x * gain;
        }
    }

private:
    double sampleRate = 48000.0;
    float thresholdDb = -24.0f;
    float ratio = 4.0f;
    float makeupDb = 0.0f;
    float makeup = 1.0f;
    float envelopeDb = -80.0f;
    float gain = 1.0f;
    float attackCoeff = 0.1f;
    float releaseCoeff = 0.02f;
    float scHpfCoeff = 0.012f;
    float scHpfState = 0.0f;
};
