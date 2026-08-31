#pragma once

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

class CabinetIR {
public:
    CabinetIR() = default;
    ~CabinetIR() { teardown(); }

    CabinetIR(const CabinetIR &) = delete;
    CabinetIR &operator=(const CabinetIR &) = delete;

    void setIR(const float *samples, int length, double irSampleRate) {
        orig.assign(samples, samples + std::max(0, length));
        origRate = irSampleRate > 1.0 ? irSampleRate : 48000.0;
        rebuild();
    }

    void clear() {
        orig.clear();
        teardown();
        loaded = false;
    }

    void setEngineRate(double sr, int maxBlock) {
        engineRate = sr > 1.0 ? sr : 48000.0;
        maxBlockSize = std::max(32, maxBlock);
        rebuild();
    }

    bool hasIR() const { return loaded; }

    void process(const float *in, float *out, int n) {
        if (!loaded || setup == nullptr || n <= 0 || n > maxBlockSize) {
            if (in != out)
                std::memcpy(out, in, n * sizeof(float));
            return;
        }

        std::fill(timeBuf.begin(), timeBuf.end(), 0.0f);
        std::copy(in, in + n, timeBuf.begin());

        vDSP_ctoz(reinterpret_cast<const DSPComplex *>(timeBuf.data()), 2, &split, 1, fftSize / 2);
        vDSP_fft_zrip(setup, &split, 1, fftLog2, kFFTDirection_Forward);

        const float dc = split.realp[0] * irSplit.realp[0];
        const float ny = split.imagp[0] * irSplit.imagp[0];
        vDSP_zvmul(&split, 1, &irSplit, 1, &split, 1, fftSize / 2, 1);
        split.realp[0] = dc;
        split.imagp[0] = ny;

        vDSP_fft_zrip(setup, &split, 1, fftLog2, kFFTDirection_Inverse);
        vDSP_ztoc(&split, 1, reinterpret_cast<DSPComplex *>(timeBuf.data()), 2, fftSize / 2);

        // vDSP's real FFT is scaled by 2 in both forward transforms. Their
        // product therefore needs 1 / (4N), not 1 / N, after the inverse.
        // The old factor made every loaded cabinet four times too loud.
        const float scale = 1.0f / (4.0f * (float)fftSize);
        vDSP_vsmul(timeBuf.data(), 1, &scale, timeBuf.data(), 1, fftSize);

        for (int i = 0; i < n; ++i)
            out[i] = overlap[i] + timeBuf[i];

        const int remain = fftSize - n;
        for (int i = 0; i < remain; ++i)
            overlap[i] = overlap[i + n] + timeBuf[i + n];
        std::fill(overlap.begin() + remain, overlap.end(), 0.0f);
    }

private:
    bool loaded = false;
    double origRate = 48000.0;
    double engineRate = 48000.0;
    int maxBlockSize = 512;
    int fftSize = 0;
    int fftLog2 = 0;
    FFTSetup setup = nullptr;
    DSPSplitComplex split{};
    DSPSplitComplex irSplit{};
    std::vector<float> orig;
    std::vector<float> timeBuf;
    std::vector<float> overlap;

    static int nextPow2(int x) {
        int p = 1;
        while (p < x)
            p <<= 1;
        return p;
    }

    static std::vector<float> resampleLinear(const std::vector<float> &src, double srcRate, double dstRate) {
        if (src.empty())
            return {};
        if (std::fabs(srcRate - dstRate) < 0.5)
            return src;
        const int dstLen = std::max(1, (int)std::lround(src.size() * dstRate / srcRate));
        std::vector<float> dst(dstLen);
        const double step = srcRate / dstRate;
        for (int i = 0; i < dstLen; ++i) {
            const double pos = i * step;
            const int i0 = (int)pos;
            const int i1 = std::min(i0 + 1, (int)src.size() - 1);
            const float t = (float)(pos - i0);
            dst[i] = src[i0] * (1.0f - t) + src[i1] * t;
        }
        return dst;
    }

    void teardown() {
        if (setup)
            vDSP_destroy_fftsetup(setup);
        setup = nullptr;
        std::free(split.realp);
        std::free(split.imagp);
        std::free(irSplit.realp);
        std::free(irSplit.imagp);
        split = {};
        irSplit = {};
        timeBuf.clear();
        overlap.clear();
    }

    void rebuild() {
        teardown();
        loaded = false;
        if (orig.empty())
            return;

        auto ir = resampleLinear(orig, origRate, engineRate);
        if ((int)ir.size() > 16384)
            ir.resize(16384);

        // Remove DC and fade a truncated tail. Peak-normalizing an impulse
        // response in the time domain is unsafe: a resonant IR can have a
        // modest sample peak but hundreds of times gain at one frequency.
        if (ir.size() >= 32) {
            float mean = 0;
            vDSP_meanv(ir.data(), 1, &mean, ir.size());
            const float negativeMean = -mean;
            vDSP_vsadd(ir.data(), 1, &negativeMean, ir.data(), 1, ir.size());
            const int fadeLength = std::min(1024, std::max(2, (int)ir.size() / 5));
            for (int i = 0; i < fadeLength; ++i) {
                const float phase = (float)i / (float)(fadeLength - 1);
                const float fade = 0.5f * (1.0f + std::cos((float)M_PI * phase));
                ir[ir.size() - fadeLength + i] *= fade;
            }
        }

        fftSize = nextPow2((int)ir.size() + maxBlockSize);
        fftSize = std::max(fftSize, 256);
        fftLog2 = 0;
        int tmp = fftSize;
        while (tmp > 1) {
            tmp >>= 1;
            fftLog2 += 1;
        }

        setup = vDSP_create_fftsetup(fftLog2, kFFTRadix2);
        if (!setup)
            return;

        split.realp = (float *)std::calloc(fftSize / 2, sizeof(float));
        split.imagp = (float *)std::calloc(fftSize / 2, sizeof(float));
        irSplit.realp = (float *)std::calloc(fftSize / 2, sizeof(float));
        irSplit.imagp = (float *)std::calloc(fftSize / 2, sizeof(float));
        if (!split.realp || !split.imagp || !irSplit.realp || !irSplit.imagp) {
            teardown();
            return;
        }
        timeBuf.assign(fftSize, 0.0f);
        overlap.assign(fftSize, 0.0f);

        std::copy(ir.begin(), ir.end(), timeBuf.begin());
        vDSP_ctoz(reinterpret_cast<const DSPComplex *>(timeBuf.data()), 2, &irSplit, 1, fftSize / 2);
        vDSP_fft_zrip(setup, &irSplit, 1, fftLog2, kFFTDirection_Forward);

        // Normalize by the maximum frequency response, preserving the cabinet
        // shape while guaranteeing it cannot create runaway narrow-band gain.
        float maxResponse = std::max(std::fabs(irSplit.realp[0]), std::fabs(irSplit.imagp[0])) * 0.5f;
        for (int i = 1; i < fftSize / 2; ++i) {
            const float response = 0.5f * std::hypot(irSplit.realp[i], irSplit.imagp[i]);
            maxResponse = std::max(maxResponse, response);
        }
        if (maxResponse <= 1.0e-8f) {
            teardown();
            return;
        }
        // Keep the cabinet's shape with full headroom and natural unity gain
        const float responseScale = 0.90f / maxResponse;
        vDSP_vsmul(irSplit.realp, 1, &responseScale, irSplit.realp, 1, fftSize / 2);
        vDSP_vsmul(irSplit.imagp, 1, &responseScale, irSplit.imagp, 1, fftSize / 2);
        loaded = true;
    }
};
