#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
test_build=$(mktemp -d "${TMPDIR:-/tmp}/xzyqrn-audio-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT

cd "$project_root"

xcrun clang++ -std=c++20 -O2 -Wall -Wextra \
    -I App/DSP \
    Tests/DSPComponentTests.cpp \
    -framework Accelerate \
    -o "$test_build/dsp-components"
"$test_build/dsp-components"

xcrun clang++ -std=c++20 -O2 \
    -DNAM_ENABLE_A2_FAST=1 -DEIGEN_DONT_PARALLELIZE=1 -DEIGEN_MPL2_ONLY=1 \
    -I App/DSP \
    -I Vendor/NeuralAmpModelerCore \
    -I Vendor/NeuralAmpModelerCore/NAM \
    -I Vendor/NeuralAmpModelerCore/Dependencies/eigen \
    -I Vendor/NeuralAmpModelerCore/Dependencies/nlohmann \
    Tests/NAMModelTests.cpp \
    App/DSP/AmpProcessor.cpp \
    Vendor/NeuralAmpModelerCore/NAM/*.cpp \
    Vendor/NeuralAmpModelerCore/NAM/wavenet/*.cpp \
    -framework Accelerate \
    -o "$test_build/nam-models"
"$test_build/nam-models" \
    App/Resources/Presets/factory-presets.json \
    App/Resources \
    App/Resources/Models/community-*.nam

jq -e '
    length >= 16
    and any(.id == "raw-di")
    and any(.id == "vintage-clean")
    and (map(select(.id == "practice")) | .[0] | .namOn == false and .irOn == false and .gateOn == false and .expanderOn == true and .eqOn == false and (.cleanAmpOn != true))
    and (map(.id) | unique | length == length)
    and all(.[];
        (.inputGainDb >= -12 and .inputGainDb <= 24)
        and (.outputGainDb >= -24 and .outputGainDb <= 18)
        and (.gateThresholdDb >= -80 and .gateThresholdDb <= -20)
        and (.bassDb >= -12 and .bassDb <= 12)
        and (.midDb >= -12 and .midDb <= 12)
        and (.trebleDb >= -12 and .trebleDb <= 12)
        and (.midFreqIndex >= 0 and .midFreqIndex <= 4)
        and ((.octaverMix // 0.35) >= 0 and (.octaverMix // 0.35) <= 1)
        and ((.envelopeSensitivity // 0.55) >= 0 and (.envelopeSensitivity // 0.55) <= 1)
        and ((.highPassHz // 32) >= 20 and (.highPassHz // 32) <= 180)
        and ((.lowPassHz // 12000) >= 1200 and (.lowPassHz // 12000) <= 16000)
    )
' App/Resources/Presets/factory-presets.json >/dev/null

jq -e '
    length >= 25
    and (map(.id) | unique | length == length)
    and all(.[]; (.pedal | type == "string") and (.name | length > 0))
' App/Resources/Presets/pedal-factory.json >/dev/null

[[ $(find App/Resources/Beats -type f -name '*.wav' | wc -l | tr -d ' ') -ge 36 ]]
[[ -s App/Resources/AlphaTab/alphaTab.min.js ]]
[[ -s App/Resources/AlphaTab/viewer.html ]]
[[ -s App/Resources/AlphaTab/font/Bravura.woff2 ]]
[[ -s App/Resources/AlphaTab/LICENSE-MPL-2.0.txt ]]
[[ -s App/Resources/AlphaTab/font/Bravura-OFL.txt ]]

while IFS= read -r resource; do
    afinfo "$resource" >/dev/null
done < <(find App/Resources/Beats App/Resources/IRs -type f -name '*.wav' | sort)

while IFS= read -r referenced; do
    [[ -z "$referenced" ]] && continue
    if [[ "$referenced" == *.nam ]]; then
        [[ -f "App/Resources/Models/$referenced" ]]
    else
        [[ -f "App/Resources/IRs/$referenced" ]]
    fi
done < <(jq -r '.[] | .namFile, .irFile' App/Resources/Presets/factory-presets.json | sort -u)

echo "Factory preset and audio resource tests passed"
