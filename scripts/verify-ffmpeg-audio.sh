#!/usr/bin/env bash
# Inspect the exact library that will be archived, then encode on native runners.
set -euo pipefail
native_run=${1:?native execution flag required}
platform=${2:?platform name required}
mkdir -p build/verification
exec > >(tee build/verification/audio-check.log) 2>&1

# Read checkout metadata without changing Git's ownership/trust configuration.
# Container runners can own a checkout differently from the shell user.
read_checkout_head() {
    local metadata=$1 directory head common reference
    if [ -f "$metadata" ]; then
        directory=$(sed -n 's/^gitdir: //p' "$metadata" | tr -d '\r')
        case "$directory" in
            /*|?:/*) ;;
            *) directory="$(dirname "$metadata")/$directory" ;;
        esac
    else
        directory=$metadata
    fi
    head=$(tr -d '\r\n' < "$directory/HEAD")
    case "$head" in
        'ref: '*)
            reference=${head#ref: }
            common=$directory
            if [ -f "$directory/commondir" ]; then
                common="$directory/$(tr -d '\r\n' < "$directory/commondir")"
            fi
            if [ -f "$common/$reference" ]; then
                head=$(tr -d '\r\n' < "$common/$reference")
            else
                head=$(awk -v ref="$reference" '$2 == ref {print $1}' "$common/packed-refs")
            fi
            ;;
    esac
    if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Invalid checkout HEAD in $metadata" >&2
        return 1
    fi
    printf '%s\n' "$head"
}
source_commit=$(read_checkout_head .git)
test "$source_commit" = "${GITHUB_SHA:-$source_commit}"
printf '%s\n' "$source_commit" > build/verification/source-commit.txt
pins_text=$(tr -d '\r' < tests/ffmpeg-submodule-pins.txt)
test -n "$pins_text"
while read -r expected module; do
    actual=$(read_checkout_head "$module/.git")
    test "$actual" = "$expected"
    printf '%s %s\n' "$actual" "$module"
done <<< "$pins_text" > build/verification/submodule-commits.txt
printf 'platform=%s\nrun_id=%s\nattempt=%s\n' "$platform" "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}" > build/verification/build.txt
cp build/FFmpeg/FFmpeg/ffbuild/config.mak build/verification/
cp build/FFmpeg/FFmpeg/libavcodec/codec_list.c build/verification/

library="$PWD/build/dist/ffmpeg/lib/libavcodec.a"
mkdir -p build/verification/registry
# Native MinGW ar stdout is text-mode: use extraction, never binary redirection.
(cd build/verification/registry && "${CCPREFIX:-}ar" x "$library" allcodecs.o)
mv build/verification/registry/allcodecs.o build/verification/allcodecs.o
"${CCPREFIX:-}nm" -u build/verification/allcodecs.o | tr -d '\r' > build/verification/registrations.txt
grep -E 'ff_ac3_encoder$' build/verification/registrations.txt
grep -E 'ff_eac3_encoder$' build/verification/registrations.txt
for encoder in libx264 libx265 libsvtav1; do
    grep -E "ff_${encoder}_encoder$" build/verification/registrations.txt
done
if [ "$platform" = Windows-AMD64 ]; then
    awk '/_encoder$/ {print $NF}' build/verification/registrations.txt | sort > build/verification/encoder-names.txt
    tr -d '\r' < tests/windows-amd64-encoders.txt > build/verification/expected-encoder-names.txt
    diff -u build/verification/expected-encoder-names.txt build/verification/encoder-names.txt
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
cflags_text=$(pkg-config --cflags libavcodec libavutil | tr -d '\r')
ldflags_text=$(pkg-config --static --libs libavcodec libavutil | tr -d '\r')
read -r -a cflags <<< "$cflags_text"
read -r -a ldflags <<< "$ldflags_text"
"${CC:-cc}" -Wall -Wextra -Werror -Ibuild/dist/ffmpeg/include "${cflags[@]}" tests/native-audio-encoders.c "$library" build/dist/ffmpeg/lib/libavutil.a "${ldflags[@]}" -o build/verification/audio-check
./build/verification/audio-check
