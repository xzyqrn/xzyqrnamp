#pragma once

#include <algorithm>
#include <cmath>

class Biquad {
public:
    enum class Type { LowShelf, Peak, HighShelf, LowPass, HighPass, Notch };

    void set(Type type, float freq, float gainDb, float q, double sampleRate) {
        const double sr = sampleRate > 1.0 ? sampleRate : 48000.0;
        const double A = std::pow(10.0, gainDb / 40.0);
        const double w0 = 2.0 * M_PI * std::clamp((double)freq, 20.0, sr * 0.45) / sr;
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double alpha = sinw / (2.0 * std::max(0.1, (double)q));
        double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;

        if (type == Type::LowShelf) {
            const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1.0) - (A - 1.0) * cosw + twoSqrtAAlpha);
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw);
            b2 = A * ((A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha);
            a0 = (A + 1.0) + (A - 1.0) * cosw + twoSqrtAAlpha;
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw);
            a2 = (A + 1.0) + (A - 1.0) * cosw - twoSqrtAAlpha;
        } else if (type == Type::HighShelf) {
            const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1.0) + (A - 1.0) * cosw + twoSqrtAAlpha);
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw);
            b2 = A * ((A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha);
            a0 = (A + 1.0) - (A - 1.0) * cosw + twoSqrtAAlpha;
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw);
            a2 = (A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha;
        } else if (type == Type::LowPass) {
            b0 = (1.0 - cosw) * 0.5;
            b1 = 1.0 - cosw;
            b2 = (1.0 - cosw) * 0.5;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosw;
            a2 = 1.0 - alpha;
        } else if (type == Type::HighPass) {
            b0 = (1.0 + cosw) * 0.5;
            b1 = -(1.0 + cosw);
            b2 = (1.0 + cosw) * 0.5;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosw;
            a2 = 1.0 - alpha;
        } else if (type == Type::Notch) {
            b0 = 1.0;
            b1 = -2.0 * cosw;
            b2 = 1.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosw;
            a2 = 1.0 - alpha;
        } else {
            b0 = 1.0 + alpha * A;
            b1 = -2.0 * cosw;
            b2 = 1.0 - alpha * A;
            a0 = 1.0 + alpha / A;
            a1 = -2.0 * cosw;
            a2 = 1.0 - alpha / A;
        }

        this->b0 = (float)(b0 / a0);
        this->b1 = (float)(b1 / a0);
        this->b2 = (float)(b2 / a0);
        this->a1 = (float)(a1 / a0);
        this->a2 = (float)(a2 / a0);
    }

    void reset() { z1 = z2 = 0; }

    inline float tick(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        if (std::fabs(z1) < 1.0e-15f)
            z1 = 0.0f;
        z2 = b2 * x - a2 * y;
        if (std::fabs(z2) < 1.0e-15f)
            z2 = 0.0f;
        return y;
    }

private:
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1 = 0, z2 = 0;
};

class ToneEQ {
public:
    static constexpr float kMidFrequencies[5] = {220.0f, 450.0f, 800.0f, 1600.0f, 3000.0f};

    void setSampleRate(double sr) {
        if (sampleRate != sr) {
            sampleRate = sr > 1.0 ? sr : 48000.0;
            dirty = true;
        }
    }
    void setBass(float db) {
        if (bassDb != db) {
            bassDb = db;
            dirty = true;
        }
    }
    void setMid(float db) {
        if (midDb != db) {
            midDb = db;
            dirty = true;
        }
    }
    void setTreble(float db) {
        if (trebleDb != db) {
            trebleDb = db;
            dirty = true;
        }
    }
    void setMidFreqIndex(int idx) {
        const int clamped = std::clamp(idx, 0, 4);
        if (midFreqIdx != clamped) {
            midFreqIdx = clamped;
            dirty = true;
        }
    }
    void setUltraLo(bool on) {
        if (ultraLo != on) {
            ultraLo = on;
            dirty = true;
        }
    }
    void setUltraHi(bool on) {
        if (ultraHi != on) {
            ultraHi = on;
            dirty = true;
        }
    }

    void reset() {
        bass.reset();
        mid.reset();
        treble.reset();
        ultraLoBoost.reset();
        ultraLoCut.reset();
        ultraHiBoost.reset();
        dirty = true;
    }

    inline void process(float *buffer, int frames) {
        if (dirty)
            refresh();
        for (int i = 0; i < frames; ++i) {
            float x = buffer[i];
            if (ultraLo) {
                x = ultraLoBoost.tick(x);
                x = ultraLoCut.tick(x);
            }
            if (ultraHi) {
                x = ultraHiBoost.tick(x);
            }
            x = bass.tick(x);
            x = mid.tick(x);
            x = treble.tick(x);
            buffer[i] = x;
        }
    }

private:
    double sampleRate = 48000.0;
    float bassDb = 0.0f, midDb = 0.0f, trebleDb = 0.0f;
    int midFreqIdx = 1; // 450 Hz default
    bool ultraLo = false;
    bool ultraHi = false;
    bool dirty = true;

    Biquad bass, mid, treble;
    Biquad ultraLoBoost, ultraLoCut;
    Biquad ultraHiBoost;

    void refresh() {
        const float midFreq = kMidFrequencies[std::clamp(midFreqIdx, 0, 4)];
        // Classic SVT Bass shelf @ 40 Hz, Treble shelf @ 4 kHz
        bass.set(Biquad::Type::LowShelf, 40.0f, bassDb, 0.7f, sampleRate);
        mid.set(Biquad::Type::Peak, midFreq, midDb, 0.9f, sampleRate);
        treble.set(Biquad::Type::HighShelf, 4000.0f, trebleDb, 0.7f, sampleRate);

        // Ultra-Lo: +2 dB boost @ 40 Hz & -10 dB scoop @ 500 Hz
        ultraLoBoost.set(Biquad::Type::LowShelf, 40.0f, 2.5f, 0.7f, sampleRate);
        ultraLoCut.set(Biquad::Type::Peak, 500.0f, -10.0f, 1.2f, sampleRate);

        // Ultra-Hi: +9 dB boost @ 8 kHz
        ultraHiBoost.set(Biquad::Type::HighShelf, 8000.0f, 9.0f, 0.7f, sampleRate);

        dirty = false;
    }
};

