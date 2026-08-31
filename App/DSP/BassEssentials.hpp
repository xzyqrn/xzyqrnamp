#pragma once

#include <algorithm>
#include <cmath>

class BassOctaver {
public:
    void setSampleRate(double sampleRate) {
        sr = std::max(sampleRate, 8000.0);
        reset();
    }

    void reset() {
        last = 0.0f;
        polarity = 1.0f;
        envelope = 0.0f;
        sub = 0.0f;
    }

    void setMix(float value) { mix = std::clamp(value, 0.0f, 1.0f); }
    void setTone(float value) { tone = std::clamp(value, 0.0f, 1.0f); }

    void process(float *samples, int frames) {
        const float cutoff = 70.0f + tone * 520.0f;
        const float coeff = 1.0f - std::exp(-2.0f * float(M_PI) * cutoff / float(sr));
        for (int i = 0; i < frames; ++i) {
            const float dry = samples[i];
            envelope += (std::fabs(dry) - envelope) * (std::fabs(dry) > envelope ? 0.035f : 0.0025f);
            if (last <= 0.0f && dry > 0.0f && envelope > 0.002f)
                polarity = -polarity;
            last = dry;
            const float target = polarity * envelope * 1.45f;
            sub += coeff * (target - sub);
            samples[i] = dry * (1.0f - mix) + sub * mix;
        }
    }

private:
    double sr = 48000.0;
    float mix = 0.35f;
    float tone = 0.45f;
    float last = 0.0f;
    float polarity = 1.0f;
    float envelope = 0.0f;
    float sub = 0.0f;
};

class BassEnvelopeFilter {
public:
    void setSampleRate(double sampleRate) {
        sr = std::max(sampleRate, 8000.0);
        reset();
    }

    void reset() {
        envelope = 0.0f;
        low = 0.0f;
        band = 0.0f;
    }

    void setSensitivity(float value) { sensitivity = std::clamp(value, 0.0f, 1.0f); }
    void setResonance(float value) { resonance = std::clamp(value, 0.0f, 0.95f); }
    void setMix(float value) { mix = std::clamp(value, 0.0f, 1.0f); }

    void process(float *samples, int frames) {
        for (int i = 0; i < frames; ++i) {
            const float dry = samples[i];
            const float rectified = std::fabs(dry);
            envelope += (rectified - envelope) * (rectified > envelope ? 0.018f : 0.0018f);
            const float sweep = std::clamp(envelope * (8.0f + sensitivity * 52.0f), 0.0f, 1.0f);
            const float cutoff = 90.0f + sweep * (650.0f + sensitivity * 2350.0f);
            const float f = std::clamp(2.0f * std::sin(float(M_PI) * cutoff / float(sr)), 0.001f, 0.85f);
            const float q = 1.65f - resonance * 1.35f;
            low += f * band;
            const float high = dry - low - q * band;
            band += f * high;
            const float wet = band * (1.0f + resonance * 1.6f);
            samples[i] = dry * (1.0f - mix) + wet * mix;
        }
    }

private:
    double sr = 48000.0;
    float sensitivity = 0.55f;
    float resonance = 0.45f;
    float mix = 0.65f;
    float envelope = 0.0f;
    float low = 0.0f;
    float band = 0.0f;
};

class BassUtilityFilter {
public:
    void setSampleRate(double sampleRate) {
        sr = std::max(sampleRate, 8000.0);
        lowState = 0.0f;
        highState = 0.0f;
        previous = 0.0f;
    }

    void setHighPass(float hz) { highPass = std::clamp(hz, 20.0f, 180.0f); }
    void setLowPass(float hz) { lowPass = std::clamp(hz, 1200.0f, 16000.0f); }

    void process(float *samples, int frames) {
        const float lowAlpha = 1.0f - std::exp(-2.0f * float(M_PI) * lowPass / float(sr));
        const float highRC = 1.0f / (2.0f * float(M_PI) * highPass);
        const float dt = 1.0f / float(sr);
        const float highAlpha = highRC / (highRC + dt);
        for (int i = 0; i < frames; ++i) {
            const float input = samples[i];
            highState = highAlpha * (highState + input - previous);
            previous = input;
            lowState += lowAlpha * (highState - lowState);
            samples[i] = lowState;
        }
    }

private:
    double sr = 48000.0;
    float highPass = 32.0f;
    float lowPass = 12000.0f;
    float lowState = 0.0f;
    float highState = 0.0f;
    float previous = 0.0f;
};
