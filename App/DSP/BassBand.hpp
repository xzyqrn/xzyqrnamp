#pragma once

#include <algorithm>
#include <cmath>

/// Envelope detector optimized for bass guitar.
/// Passes all bass fundamentals (25 Hz - 3.5 kHz) while rejecting subsonic thumps and ultra-high hiss.
class BassBand {
public:
    void setSampleRate(double sr) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        const float s = float(sampleRate);
        hpCoeff = 1.0f - std::exp(-2.0f * float(M_PI) * 25.0f / s);
        lpCoeff = 1.0f - std::exp(-2.0f * float(M_PI) * 3500.0f / s);
        attackCoeff = 1.0f - std::exp(-1.0f / (0.005f * s));
        releaseCoeff = 1.0f - std::exp(-1.0f / (0.060f * s));
    }

    void reset() {
        hpState = 0.0f;
        lpState = 0.0f;
        env = 0.0f;
    }

    inline float tick(float x) {
        // High-pass at 25 Hz (removes DC/subsonic rumble, keeps Low B0 at 30.87 Hz)
        hpState += hpCoeff * (x - hpState);
        if (std::fabs(hpState) < 1.0e-15f) hpState = 0.0f;
        const float hpOut = x - hpState;

        // Low-pass at 3.5 kHz (removes hiss, keeps all bass harmonics)
        lpState += lpCoeff * (hpOut - lpState);
        if (std::fabs(lpState) < 1.0e-15f) lpState = 0.0f;

        const float det = std::fabs(lpState);
        if (det > env)
            env += attackCoeff * (det - env);
        else
            env += releaseCoeff * (det - env);

        if (std::fabs(env) < 1.0e-15f) env = 0.0f;
        return env;
    }

    float envelope() const { return env; }

    static float toMeter(float linear) {
        const float db = 20.0f * std::log10(linear + 1.0e-6f);
        // Map -60 dBFS to 0 dBFS smoothly across 0.0 to 1.0
        return std::clamp((db + 60.0f) / 60.0f, 0.0f, 1.0f);
    }

private:
    double sampleRate = 48000.0;
    float hpCoeff = 0.003f;
    float lpCoeff = 0.35f;
    float attackCoeff = 0.15f;
    float releaseCoeff = 0.02f;
    float hpState = 0.0f;
    float lpState = 0.0f;
    float env = 0.0f;
};

