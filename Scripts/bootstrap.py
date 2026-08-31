#!/usr/bin/env python3
"""Generate the cabinet IR, app icon, and Xcode project."""

from __future__ import annotations

import math
import os
import struct
import subprocess
import sys
import wave
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def write_wav():
    sr = 48000
    n = 4096

    def biquad(kind, frequency, q=0.707, gain_db=0.0):
        w0 = 2.0 * math.pi * frequency / sr
        cos_w0 = math.cos(w0)
        sin_w0 = math.sin(w0)
        alpha = sin_w0 / (2.0 * q)
        a = 10.0 ** (gain_db / 40.0)
        if kind == "highpass":
            b0 = (1.0 + cos_w0) / 2.0
            b1 = -(1.0 + cos_w0)
            b2 = b0
            a0 = 1.0 + alpha
            a1 = -2.0 * cos_w0
            a2 = 1.0 - alpha
        elif kind == "lowpass":
            b0 = (1.0 - cos_w0) / 2.0
            b1 = 1.0 - cos_w0
            b2 = b0
            a0 = 1.0 + alpha
            a1 = -2.0 * cos_w0
            a2 = 1.0 - alpha
        else:
            b0 = 1.0 + alpha * a
            b1 = -2.0 * cos_w0
            b2 = 1.0 - alpha * a
            a0 = 1.0 + alpha / a
            a1 = -2.0 * cos_w0
            a2 = 1.0 - alpha / a
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0, 0.0, 0.0]

    # A broad, minimum-phase bass cabinet curve. The previous asset was a
    # bank of long sine resonators; it rang like a pitch shifter and obscured
    # the played fundamental. This cascade shapes a DI without adding tones.
    filters = [
        biquad("highpass", 38.0, 0.707),
        biquad("peak", 95.0, 0.85, 2.0),
        biquad("peak", 650.0, 0.9, -1.5),
        biquad("lowpass", 4200.0, 0.65),
        biquad("lowpass", 6500.0, 0.707),
    ]
    samples = []
    for i in range(n):
        value = 1.0 if i == 0 else 0.0
        for state in filters:
            b0, b1, b2, a1, a2, z1, z2 = state
            output = b0 * value + z1
            state[5] = b1 * value - a1 * output + z2
            state[6] = b2 * value - a2 * output
            value = output
        samples.append(value)

    peak = max(abs(x) for x in samples) or 1.0
    samples = [max(-1.0, min(1.0, x / peak * 0.9)) for x in samples]

    path = ROOT / "App/Resources/IRs/bass-4x10.wav"
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(b"".join(struct.pack("<h", int(x * 32767)) for x in samples))
    print("wrote", path)


class _Noise:
    def __init__(self, seed: int):
        self.s = seed & 0x7FFFFFFF

    def __call__(self) -> float:
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s / 1073741824.0 - 1.0


def _highpass(samples, sr, hz):
    rc = 1.0 / (2.0 * math.pi * hz)
    dt = 1.0 / sr
    a = rc / (rc + dt)
    prev_x = 0.0
    prev_y = 0.0
    out = []
    for x in samples:
        y = a * (prev_y + x - prev_x)
        out.append(y)
        prev_x = x
        prev_y = y
    return out


def _kick(sr, n):
    samples = []
    for i in range(n):
        t = i / sr
        env = math.exp(-t * 16.0)
        freq = 42.0 + 90.0 * math.exp(-t * 28.0)
        click = math.exp(-t * 80.0) * 0.35
        samples.append(math.sin(2.0 * math.pi * freq * t) * env + click * (1.0 if i == 0 else math.sin(2.0 * math.pi * 1800 * t)))
    return samples


def _snare(sr, n, noise: _Noise, bright=1.0):
    samples = []
    for i in range(n):
        t = i / sr
        env = math.exp(-t * 18.0)
        tone = math.sin(2.0 * math.pi * 180.0 * t) * math.exp(-t * 22.0)
        samples.append((noise() * 0.72 * bright + tone * 0.45) * env)
    return _highpass(samples, sr, 500.0)


def _hat(sr, n, noise: _Noise, open_hat=False):
    decay = 22.0 if open_hat else 55.0
    samples = []
    for i in range(n):
        t = i / sr
        env = math.exp(-t * decay)
        samples.append(noise() * env)
    return _highpass(samples, sr, 6000.0)


def _mix_hit(dest, src, at, gain):
    end = min(len(dest), at + len(src))
    for i in range(at, end):
        dest[i] += src[i - at] * gain


def write_beats():
    sr = 48000
    styles = {
        "rock": {
            "kick": [(0, 1.0), (8, 1.0)],
            "snare": [(4, 1.0), (12, 1.0)],
            "hat": [(i, 0.55 if i % 2 == 0 else 0.28) for i in range(0, 16, 1) if i % 2 == 0],
        },
        "funk": {
            "kick": [(0, 1.0), (3, 0.7), (10, 0.85)],
            "snare": [(4, 1.0), (12, 1.0), (14, 0.28)],
            "hat": [(i, 0.42 if i % 2 == 0 else 0.22) for i in range(16)],
        },
        "hiphop": {
            "kick": [(0, 1.0), (7, 0.55), (10, 0.9)],
            "snare": [(4, 1.0), (12, 1.0)],
            "hat": [(i, 0.38) for i in range(0, 16, 2)] + [(15, 0.22)],
        },
        "latin": {
            "kick": [(0, 1.0), (6, 0.7), (9, 0.55)],
            "snare": [(4, 0.85), (12, 0.9)],
            "hat": [(0, 0.5), (2, 0.28), (3, 0.45), (6, 0.5), (8, 0.28), (10, 0.45), (11, 0.3), (14, 0.4)],
        },
        "blues": {
            "kick": [(0, 1.0), (6, 0.55), (10, 0.78)],
            "snare": [(4, 0.95), (12, 1.0)],
            "hat": [(0, 0.48), (3, 0.28), (6, 0.45), (8, 0.38), (11, 0.26), (14, 0.45)],
        },
        "soul": {
            "kick": [(0, 1.0), (7, 0.42), (10, 0.76)],
            "snare": [(4, 0.92), (12, 1.0), (15, 0.22)],
            "hat": [(i, 0.38 if i % 4 == 0 else 0.20) for i in range(0, 16, 2)],
        },
        "reggae": {
            "kick": [(0, 0.88), (10, 0.72)],
            "snare": [(4, 0.30), (8, 1.0), (12, 0.30)],
            "hat": [(2, 0.40), (6, 0.40), (10, 0.40), (14, 0.48)],
        },
        "disco": {
            "kick": [(0, 1.0), (4, 0.96), (8, 1.0), (12, 0.96)],
            "snare": [(4, 0.90), (12, 0.96)],
            "hat": [(i, 0.34 if i % 2 == 0 else 0.22) for i in range(16)],
        },
        "metal": {
            "kick": [(0, 1.0), (2, 0.78), (6, 0.82), (8, 1.0), (10, 0.78), (14, 0.84)],
            "snare": [(4, 1.0), (12, 1.0)],
            "hat": [(i, 0.46 if i % 4 == 0 else 0.30) for i in range(16)],
        },
        "jazz": {
            "kick": [(0, 0.62), (10, 0.42)],
            "snare": [(4, 0.34), (7, 0.22), (12, 0.46), (15, 0.24)],
            "hat": [(0, 0.34), (3, 0.46), (6, 0.28), (8, 0.34), (11, 0.46), (14, 0.28)],
        },
        "pop": {
            "kick": [(0, 1.0), (8, 0.92), (10, 0.55)],
            "snare": [(4, 1.0), (12, 1.0)],
            "hat": [(i, 0.40 if i % 4 == 0 else 0.24) for i in range(0, 16, 2)],
        },
        "electronic": {
            "kick": [(0, 1.0), (4, 0.92), (8, 1.0), (12, 0.92)],
            "snare": [(4, 0.82), (12, 0.88)],
            "hat": [(i, 0.38 if i in (2, 6, 10, 14) else 0.20) for i in range(16)],
        },
    }
    tempos = [80, 100, 120]
    out_dir = ROOT / "App/Resources/Beats"
    out_dir.mkdir(parents=True, exist_ok=True)

    for style, pattern in styles.items():
        for bpm in tempos:
            bar = int(sr * 60.0 / bpm * 4.0)
            buf = [0.0] * bar
            step = bar / 16.0
            noise = _Noise(hash((style, bpm)) & 0x7FFFFFFF)
            kick = _kick(sr, int(sr * 0.45))
            snare = _snare(sr, int(sr * 0.28), noise, bright=1.05 if style == "latin" else 1.0)
            hat = _hat(sr, int(sr * 0.12), noise)
            open_hat = _hat(sr, int(sr * 0.28), noise, open_hat=True)
            for step_i, gain in pattern["kick"]:
                _mix_hit(buf, kick, int(step_i * step), gain * 0.95)
            for step_i, gain in pattern["snare"]:
                _mix_hit(buf, snare, int(step_i * step), gain * 0.72)
            for step_i, gain in pattern["hat"]:
                sample = open_hat if (style == "hiphop" and step_i == 14) else hat
                _mix_hit(buf, sample, int(step_i * step), gain * 0.42)
            peak = max(abs(x) for x in buf) or 1.0
            buf = [max(-1.0, min(1.0, x / peak * 0.86)) for x in buf]
            # Loop seam
            fade = min(64, bar // 8)
            for i in range(fade):
                g = i / fade
                buf[i] *= g
                buf[bar - 1 - i] *= g
                buf[i] += buf[bar - 1 - i] * (1 - g) * 0.0
            path = out_dir / f"{style}-{bpm}.wav"
            with wave.open(str(path), "w") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(sr)
                wf.writeframes(b"".join(struct.pack("<h", int(x * 32767)) for x in buf))
            print("wrote", path)


def png_chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_png(path: Path, size: int, pixel_at):
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            r, g, b, a = pixel_at(x, y, size)
            raw.extend((r, g, b, a))
    data = zlib.compress(bytes(raw), 9)
    buf = b"\x89PNG\r\n\x1a\n"
    buf += png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    buf += png_chunk(b"IDAT", data)
    buf += png_chunk(b"IEND", b"")
    path.write_bytes(buf)


def icon_pixel(x, y, size):
    nx = (x + 0.5) / size
    ny = (y + 0.5) / size
    cx, cy = nx - 0.5, ny - 0.5
    r = math.hypot(cx, cy)

    # graphite chassis
    shade = 1.0 - 0.35 * r
    cr = int(14 * shade)
    cg = int(16 * shade)
    cb = int(20 * shade)

    # lime knob arc
    ang = math.atan2(cy, cx)
    ring = abs(r - 0.30)
    gap = ang > 1.15 and ang < 1.99  # bottom gap
    if ring < 0.034 and not gap:
        t = 1.0 - ring / 0.034
        cr = int(184 * t + cr * (1 - t))
        cg = int(247 * t + cg * (1 - t))
        cb = int(71 * t + cb * (1 - t))

    # inner disc
    if r < 0.18:
        cr, cg, cb = 28, 32, 38
        pointer_ang = math.atan2(cy, cx)
        if abs(pointer_ang + 1.1) < 0.11 and r < 0.16:
            cr, cg, cb = 184, 247, 71

    # waveform
    wave = 0.52 + 0.07 * math.sin(nx * 22.0)
    if 0.18 < nx < 0.82 and abs(ny - wave) < 0.012:
        cr, cg, cb = 184, 247, 71

    # power LED
    jr = math.hypot(nx - 0.5, ny - 0.80)
    if jr < 0.045:
        glow = 1.0 - jr / 0.045
        cr = int(80 + 104 * glow)
        cg = int(40 + 207 * glow)
        cb = int(20 + 51 * glow)

    cr = max(0, min(255, cr))
    cg = max(0, min(255, cg))
    cb = max(0, min(255, cb))
    inset = 0.07
    ax = min(nx, 1 - nx)
    ay = min(ny, 1 - ny)
    alpha = 255
    if ax < inset and ay < inset:
        corner = math.hypot(inset - ax, inset - ay)
        if corner > inset:
            alpha = 0
    return cr, cg, cb, alpha


def write_icons():
    iconset = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    master = iconset / "icon_1024.png"
    write_png(master, 1024, icon_pixel)
    sizes = {
        "icon_16.png": 16,
        "icon_16@2x.png": 32,
        "icon_32.png": 32,
        "icon_32@2x.png": 64,
        "icon_128.png": 128,
        "icon_128@2x.png": 256,
        "icon_256.png": 256,
        "icon_256@2x.png": 512,
        "icon_512.png": 512,
        "icon_512@2x.png": 1024,
    }
    for name, px in sizes.items():
        dest = iconset / name
        if px == 1024:
            dest.write_bytes(master.read_bytes())
        else:
            subprocess.check_call(["sips", "-z", str(px), str(px), str(master), "--out", str(dest)], stdout=subprocess.DEVNULL)
    master.unlink(missing_ok=True)
    (iconset / "Contents.json").write_text(
        """{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
    )
    print("wrote app icons")


PBX = r"""// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		A11000000000000000000001 /* Accelerate.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A12000000000000000000001 /* Accelerate.framework */; };
		A11000000000000000000002 /* AudioToolbox.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A12000000000000000000002 /* AudioToolbox.framework */; };
		A11000000000000000000003 /* AudioUnit.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A12000000000000000000003 /* AudioUnit.framework */; };
		A11000000000000000000004 /* AVFoundation.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A12000000000000000000004 /* AVFoundation.framework */; };
		A11000000000000000000005 /* CoreAudio.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A12000000000000000000005 /* CoreAudio.framework */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A12000000000000000000001 /* Accelerate.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Accelerate.framework; path = System/Library/Frameworks/Accelerate.framework; sourceTree = SDKROOT; };
		A12000000000000000000002 /* AudioToolbox.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AudioToolbox.framework; path = System/Library/Frameworks/AudioToolbox.framework; sourceTree = SDKROOT; };
		A12000000000000000000003 /* AudioUnit.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AudioUnit.framework; path = System/Library/Frameworks/AudioUnit.framework; sourceTree = SDKROOT; };
		A12000000000000000000004 /* AVFoundation.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AVFoundation.framework; path = System/Library/Frameworks/AVFoundation.framework; sourceTree = SDKROOT; };
		A12000000000000000000005 /* CoreAudio.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreAudio.framework; path = System/Library/Frameworks/CoreAudio.framework; sourceTree = SDKROOT; };
		A13000000000000000000001 /* xzyqrn amp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "xzyqrn amp.app"; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		A14000000000000000000001 /* Exceptions for App */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				Amplifier.entitlements,
				Amplifier-Bridging-Header.h,
			);
			target = A16000000000000000000001 /* XzyqrnAmp */;
		};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		A15000000000000000000001 /* App */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				A14000000000000000000001 /* Exceptions for App */,
			);
			path = App;
			sourceTree = "<group>";
		};
		A15000000000000000000002 /* NAM */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Vendor/NeuralAmpModelerCore/NAM;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		A17000000000000000000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A11000000000000000000001 /* Accelerate.framework in Frameworks */,
				A11000000000000000000002 /* AudioToolbox.framework in Frameworks */,
				A11000000000000000000003 /* AudioUnit.framework in Frameworks */,
				A11000000000000000000004 /* AVFoundation.framework in Frameworks */,
				A11000000000000000000005 /* CoreAudio.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A18000000000000000000001 = {
			isa = PBXGroup;
			children = (
				A15000000000000000000001 /* App */,
				A15000000000000000000002 /* NAM */,
				A18000000000000000000002 /* Frameworks */,
				A18000000000000000000003 /* Products */,
			);
			sourceTree = "<group>";
		};
		A18000000000000000000002 /* Frameworks */ = {
			isa = PBXGroup;
			children = (
				A12000000000000000000001 /* Accelerate.framework */,
				A12000000000000000000002 /* AudioToolbox.framework */,
				A12000000000000000000003 /* AudioUnit.framework */,
				A12000000000000000000004 /* AVFoundation.framework */,
				A12000000000000000000005 /* CoreAudio.framework */,
			);
			name = Frameworks;
			sourceTree = "<group>";
		};
		A18000000000000000000003 /* Products */ = {
			isa = PBXGroup;
			children = (
				A13000000000000000000001 /* xzyqrn amp.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A16000000000000000000001 /* XzyqrnAmp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A19000000000000000000001 /* Build configuration list for PBXNativeTarget "XzyqrnAmp" */;
			buildPhases = (
				A17000000000000000000002 /* Sources */,
				A17000000000000000000001 /* Frameworks */,
				A17000000000000000000003 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				A15000000000000000000001 /* App */,
				A15000000000000000000002 /* NAM */,
			);
			name = XzyqrnAmp;
			productName = XzyqrnAmp;
			productReference = A13000000000000000000001 /* xzyqrn amp.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A1A000000000000000000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2630;
				LastUpgradeCheck = 2630;
				TargetAttributes = {
					A16000000000000000000001 = {
						CreatedOnToolsVersion = 26.3;
					};
				};
			};
			buildConfigurationList = A19000000000000000000002 /* Build configuration list for PBXProject "Amplifier" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A18000000000000000000001;
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = A18000000000000000000003 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A16000000000000000000001 /* XzyqrnAmp */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		A17000000000000000000003 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		A17000000000000000000002 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		A1B000000000000000000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_CXX_LANGUAGE_STANDARD = "c++20";
				CLANG_CXX_LIBRARY = "libc++";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				COPY_PHASE_STRIP = NO;
				DEAD_CODE_STRIPPING = YES;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 2;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
					"NAM_ENABLE_A2_FAST=1",
					"EIGEN_DONT_PARALLELIZE=1",
					"EIGEN_MPL2_ONLY=1",
				);
				GCC_WARN_ABOUT_RETURN_TYPE = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES;
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore",
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore/NAM",
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore/Dependencies/eigen",
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore/Dependencies/nlohmann",
					"$(SRCROOT)/App/DSP",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		A1B000000000000000000002 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_CXX_LANGUAGE_STANDARD = "c++20";
				CLANG_CXX_LIBRARY = "libc++";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				COPY_PHASE_STRIP = NO;
				DEAD_CODE_STRIPPING = YES;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 3;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"$(inherited)",
					"NAM_ENABLE_A2_FAST=1",
					"EIGEN_DONT_PARALLELIZE=1",
					"EIGEN_MPL2_ONLY=1",
					"NDEBUG=1",
				);
				GCC_WARN_ABOUT_RETURN_TYPE = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES;
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore",
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore/NAM",
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore/Dependencies/eigen",
					"$(SRCROOT)/Vendor/NeuralAmpModelerCore/Dependencies/nlohmann",
					"$(SRCROOT)/App/DSP",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			};
			name = Release;
		};
		A1B000000000000000000003 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = App/Amplifier.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_USER_SELECTED_FILES = readwrite;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "xzyqrn amp";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.music";
				INFOPLIST_KEY_NSHumanReadableCopyright = "Local bass amp. NAM engine by Steven Atkinson.";
				INFOPLIST_KEY_NSMicrophoneUsageDescription = "xzyqrn amp needs the microphone / iRig input so it can hear your bass.";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.herojay.Amplifier;
				PRODUCT_NAME = "xzyqrn amp";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_OBJC_BRIDGING_HEADER = "App/Amplifier-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		A1B000000000000000000004 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = App/Amplifier.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_USER_SELECTED_FILES = readwrite;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "xzyqrn amp";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.music";
				INFOPLIST_KEY_NSHumanReadableCopyright = "Local bass amp. NAM engine by Steven Atkinson.";
				INFOPLIST_KEY_NSMicrophoneUsageDescription = "xzyqrn amp needs the microphone / iRig input so it can hear your bass.";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.herojay.Amplifier;
				PRODUCT_NAME = "xzyqrn amp";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_OBJC_BRIDGING_HEADER = "App/Amplifier-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A19000000000000000000001 /* Build configuration list for PBXNativeTarget "XzyqrnAmp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A1B000000000000000000003 /* Debug */,
				A1B000000000000000000004 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		A19000000000000000000002 /* Build configuration list for PBXProject "Amplifier" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A1B000000000000000000001 /* Debug */,
				A1B000000000000000000002 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = A1A000000000000000000001 /* Project object */;
}
"""

SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2630"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "A16000000000000000000001"
               BuildableName = "xzyqrn amp.app"
               BlueprintName = "XzyqrnAmp"
               ReferencedContainer = "container:Amplifier.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A16000000000000000000001"
            BuildableName = "xzyqrn amp.app"
            BlueprintName = "XzyqrnAmp"
            ReferencedContainer = "container:Amplifier.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A16000000000000000000001"
            BuildableName = "xzyqrn amp.app"
            BlueprintName = "XzyqrnAmp"
            ReferencedContainer = "container:Amplifier.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_project():
    # Fix accidental typo if present
    pbx = PBX.replace(" mar\t\t\tname = Debug;", "\t\t\tname = Debug;")
    proj = ROOT / "Amplifier.xcodeproj"
    proj.mkdir(parents=True, exist_ok=True)
    (proj / "project.pbxproj").write_text(pbx)
    scheme_dir = proj / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / "XzyqrnAmp.xcscheme").write_text(SCHEME)
    legacy = scheme_dir / "Amplifier.xcscheme"
    if legacy.exists():
        legacy.unlink()
    print("wrote Xcode project")


if __name__ == "__main__":
    write_wav()
    write_beats()
    if "--ir-only" not in sys.argv:
        write_icons()
        write_project()
