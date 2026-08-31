#pragma once

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

/// Spectral noise reduction for the analog jack path.
///
/// The measured idle input on the iRig/headset-jack path is a 60 Hz buzz
/// with odd harmonics up to ~2 kHz plus a broadband switching-noise hump
/// at 3-10 kHz, riding the signal at all times. Narrow notches cannot
/// remove the dense hash, and any expander lets it back in with every
/// note. This stage learns the stationary noise magnitude per frequency
/// bin and subtracts it continuously (Wiener-style gain), which is the
/// same class of processing that makes browser apps sound quiet on the
/// same hardware.
///
/// Latency: one FFT window (512 samples, ~10.7 ms at 48 kHz).
/// All buffers are allocated in prepare(); process() never allocates.
class NoiseReduction {
public:
    static constexpr int kFFTSize = 512;
    static constexpr int kHop = 128;
    static constexpr int kBins = kFFTSize / 2 + 1;

    NoiseReduction() = default;
    ~NoiseReduction() {
        if (fftSetup)
            vDSP_destroy_fftsetup(fftSetup);
    }
    NoiseReduction(const NoiseReduction &) = delete;
    NoiseReduction &operator=(const NoiseReduction &) = delete;

    void prepare(double sr, int maxBlock) {
        sampleRate = sr > 1.0 ? sr : 48000.0;
        if (!fftSetup)
            fftSetup = vDSP_create_fftsetup(kLog2FFT, FFT_RADIX2);

        window.assign(kFFTSize, 0.0f);
        vDSP_hann_window(window.data(), kFFTSize, vDSP_HANN_DENORM);
        // Hann^2 overlap-add sum is exactly 1.5 for hop = N/4.
        olaNorm = 1.5f;

        const size_t ringSize = size_t(kFFTSize * 4 + std::max(maxBlock, kHop) * 2);
        inRing.assign(ringSize, 0.0f);
        outRing.assign(ringSize, 0.0f);
        frame.assign(kFFTSize, 0.0f);
        splitRe.assign(kFFTSize / 2, 0.0f);
        splitIm.assign(kFFTSize / 2, 0.0f);
        mag.assign(kBins, 0.0f);
        noise.assign(kBins, 0.0f);
        gain.assign(kBins, 1.0f);
        gainSmoothed.assign(kBins, 1.0f);

        // Per-bin reduction depth: protect bass fundamentals below ~220 Hz
        // (the notch bank already handles 50-120 Hz hum) and allow deep
        // reduction where the buzz harmonics and switching hash live.
        maxCut.assign(kBins, 0.1f);
        const float binHz = float(sampleRate) / float(kFFTSize);
        for (int b = 0; b < kBins; ++b) {
            const float hz = b * binHz;
            if (hz < 220.0f)
                maxCut[b] = 0.35f; // at most -9 dB where the bass lives
            else if (hz < 500.0f)
                maxCut[b] = 0.12f; // -18 dB
            else
                maxCut[b] = 0.03f; // up to -30 dB on buzz/hiss
        }

        reset();
    }

    void reset() {
        std::fill(inRing.begin(), inRing.end(), 0.0f);
        std::fill(outRing.begin(), outRing.end(), 0.0f);
        std::fill(noise.begin(), noise.end(), 0.0f);
        std::fill(gain.begin(), gain.end(), 1.0f);
        std::fill(gainSmoothed.begin(), gainSmoothed.end(), 1.0f);
        inWrite = kFFTSize; // pre-roll so the first window is available
        outRead = 0;
        outWrite = kFFTSize; // matches the one-window latency
        pendingHop = 0;
        learned = 0;
    }

    /// Latency introduced by the overlap-add pipeline, in samples.
    static int latencySamples() { return kFFTSize; }

    void process(float *buffer, int frames) {
        if (frames <= 0 || inRing.empty())
            return;
        const size_t ring = inRing.size();
        for (int i = 0; i < frames; ++i) {
            inRing[inWrite % ring] = buffer[i];
            ++inWrite;
            ++pendingHop;
            if (pendingHop >= kHop) {
                pendingHop = 0;
                stepFrame();
            }
            buffer[i] = outRing[outRead % ring];
            outRing[outRead % ring] = 0.0f;
            ++outRead;
        }
    }

private:
    static constexpr vDSP_Length kLog2FFT = 9; // 2^9 = 512

    void stepFrame() {
        const size_t ring = inRing.size();
        // Assemble the newest kFFTSize samples ending at inWrite.
        const uint64_t start = inWrite - kFFTSize;
        for (int n = 0; n < kFFTSize; ++n)
            frame[n] = inRing[(start + n) % ring] * window[n];

        DSPSplitComplex split{splitRe.data(), splitIm.data()};
        vDSP_ctoz(reinterpret_cast<const DSPComplex *>(frame.data()), 2, &split, 1, kFFTSize / 2);
        vDSP_fft_zrip(fftSetup, &split, 1, kLog2FFT, FFT_FORWARD);

        // Magnitudes. Bin 0 (DC) and Nyquist are packed in re[0]/im[0].
        mag[0] = std::fabs(splitRe[0]);
        mag[kBins - 1] = std::fabs(splitIm[0]);
        for (int b = 1; b < kFFTSize / 2; ++b)
            mag[b] = std::sqrt(splitRe[b] * splitRe[b] + splitIm[b] * splitIm[b]);

        // Track the stationary noise magnitude per bin. Small fluctuations
        // (buzz and hiss breathing around the estimate) are followed in both
        // directions so the estimate sits at the noise mean, but a bin that
        // jumps far above it is a played note and must not be learned.
        const bool learning = learned < kLearnFrames;
        for (int b = 0; b < kBins; ++b) {
            if (mag[b] < noise[b])
                noise[b] += 0.05f * (mag[b] - noise[b]);
            else if (learning)
                noise[b] += 0.08f * (mag[b] - noise[b]);
            else if (mag[b] < 4.0f * noise[b])
                noise[b] += 0.02f * (mag[b] - noise[b]);
            else
                noise[b] += 0.0002f * (mag[b] - noise[b]);
        }
        if (learning)
            ++learned;

        // Wiener-style gain with over-subtraction, clamped per band.
        for (int b = 0; b < kBins; ++b) {
            const float m = mag[b] + 1.0e-9f;
            const float g = 1.0f - kOverSubtract * (noise[b] / m);
            gain[b] = std::clamp(g, maxCut[b], 1.0f);
        }

        // Smooth across frequency (3-bin) to avoid musical noise. Kept
        // gentle so the skirt bins of a played note are not trimmed.
        float prev = gain[0];
        for (int b = 1; b < kBins - 1; ++b) {
            const float cur = gain[b];
            gain[b] = 0.15f * prev + 0.7f * cur + 0.15f * gain[b + 1];
            prev = cur;
        }

        // Smooth across time: open fast on note attacks, close slower so
        // sustain is not chopped.
        for (int b = 0; b < kBins; ++b) {
            const float target = gain[b];
            const float coeff = target > gainSmoothed[b] ? 0.6f : 0.25f;
            gainSmoothed[b] += coeff * (target - gainSmoothed[b]);
        }

        splitRe[0] *= gainSmoothed[0];
        splitIm[0] *= gainSmoothed[kBins - 1];
        for (int b = 1; b < kFFTSize / 2; ++b) {
            splitRe[b] *= gainSmoothed[b];
            splitIm[b] *= gainSmoothed[b];
        }

        vDSP_fft_zrip(fftSetup, &split, 1, kLog2FFT, FFT_INVERSE);
        vDSP_ztoc(&split, 1, reinterpret_cast<DSPComplex *>(frame.data()), 2, kFFTSize / 2);

        // vDSP forward+inverse real FFT scales by 2*N; fold into OLA gain.
        const float scale = 1.0f / (2.0f * float(kFFTSize) * olaNorm);
        for (int n = 0; n < kFFTSize; ++n)
            outRing[(outWrite + n) % ring] += frame[n] * window[n] * scale;
        outWrite += kHop;
    }

    static constexpr float kOverSubtract = 2.0f;
    static constexpr int kLearnFrames = 40; // ~0.1 s of fast adaptation

    double sampleRate = 48000.0;
    FFTSetup fftSetup = nullptr;
    float olaNorm = 1.5f;

    std::vector<float> window;
    std::vector<float> inRing;
    std::vector<float> outRing;
    std::vector<float> frame;
    std::vector<float> splitRe;
    std::vector<float> splitIm;
    std::vector<float> mag;
    std::vector<float> noise;
    std::vector<float> gain;
    std::vector<float> gainSmoothed;
    std::vector<float> maxCut;

    uint64_t inWrite = 0;
    uint64_t outRead = 0;
    uint64_t outWrite = 0;
    int pendingHop = 0;
    int learned = 0;
};
