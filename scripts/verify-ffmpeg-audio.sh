#!/usr/bin/env bash
# Inspect the exact library that will be archived, then encode on native runners.
set -euo pipefail
native_run=${1:?native execution flag required}
platform=${2:?platform name required}
mkdir -p build/verification
exec > >(tee build/verification/audio-check.log) 2>&1

git rev-parse HEAD > build/verification/source-commit.txt
git submodule status --recursive > build/verification/submodule-commits.txt
printf 'platform=%s\nrun_id=%s\nattempt=%s\n' "$platform" "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}" > build/verification/build.txt
cp build/FFmpeg/FFmpeg/ffbuild/config.mak build/verification/
cp build/FFmpeg/FFmpeg/libavcodec/codec_list.c build/verification/

library="$PWD/build/dist/ffmpeg/lib/libavcodec.a"
"${CCPREFIX:-}ar" p "$library" allcodecs.o > build/verification/allcodecs.o
"${CCPREFIX:-}nm" -u build/verification/allcodecs.o > build/verification/registrations.txt
grep -E 'ff_ac3_encoder$' build/verification/registrations.txt
grep -E 'ff_eac3_encoder$' build/verification/registrations.txt
for encoder in libx264 libx265 libsvtav1; do
    grep -E "ff_${encoder}_encoder$" build/verification/registrations.txt
done
if [ "$platform" = Windows-AMD64 ]; then
    awk '/_encoder$/ {print $NF}' build/verification/registrations.txt | sort > build/verification/encoder-names.txt
    diff -u tests/windows-amd64-encoders.txt build/verification/encoder-names.txt
fi
grep -E -- '--disable-all' build/verification/config.mak
if grep -E -- '--enable-nonfree|--enable-encoders([[:space:]]|$)' build/verification/config.mak; then
    echo 'Unexpected broad encoder or nonfree option' >&2
    exit 1
fi

if [ "$native_run" != 1 ]; then
    echo 'Cross target: compiled encoder registrations verified; native runtime test deferred.'
    exit 0
fi

export PKG_CONFIG_PATH="$PWD/build/FFmpeg/lib/pkgconfig:$PWD/build/dist/ffmpeg/lib/pkgconfig:$PWD/build/x264/lib/pkgconfig:$PWD/build/usr/local/lib/pkgconfig:$PWD/build/libva/lib/pkgconfig:$PWD/build/vulkan/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
# Intentional splitting: pkg-config emits shell compiler/linker arguments.
cflags_text=$(pkg-config --cflags libavcodec libavutil)
ldflags_text=$(pkg-config --static --libs libavcodec libavutil)
read -r -a cflags <<< "$cflags_text"
read -r -a ldflags <<< "$ldflags_text"
"${CC:-cc}" -Wall -Wextra -Werror -Ibuild/dist/ffmpeg/include "${cflags[@]}" tests/native-audio-encoders.c "$library" build/dist/ffmpeg/lib/libavutil.a "${ldflags[@]}" -o build/verification/audio-check
./build/verification/audio-check
