ARG BUILDER_IMAGE=ghcr.io/btbn/ffmpeg-builds/base-win64@sha256:80f095930d8ec013bbc5205522a7ba0dc45e4c554e9f2b4b1e0818c1876e5e87
FROM ${BUILDER_IMAGE} AS build

ARG BUILD_JOBS=4
ARG FFMPEG_COMMIT
ARG FFMPEG_CONFIGURE_FLAGS
ARG FFMPEG_VERSION
ARG SOURCE_DATE_EPOCH

ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

WORKDIR /work
COPY ffmpeg-source.tar.gz /work/ffmpeg-source.tar.gz

RUN set -eux; \
    mkdir /work/ffmpeg; \
    tar -xzf /work/ffmpeg-source.tar.gz --strip-components=1 -C /work/ffmpeg

WORKDIR /work/ffmpeg
RUN set -eux; \
    ./configure \
        --prefix=/opt/transvortex-ffmpeg \
        ${FFBUILD_TARGET_FLAGS} \
        ${FFMPEG_CONFIGURE_FLAGS} \
        --cc="${CC}" \
        --cxx="${CXX}" \
        --ar="${AR}" \
        --ranlib="${RANLIB}" \
        --nm="${NM}" \
        --extra-cflags="${CFLAGS}" \
        --extra-cxxflags="${CXXFLAGS}" \
        --extra-ldflags="${LDFLAGS} -Wl,--no-insert-timestamp"

RUN set -eux; \
    make -j"${BUILD_JOBS}"; \
    make install

RUN set -eux; \
    mkdir -p /export/bin /export/licenses /export/build-info; \
    cp /opt/transvortex-ffmpeg/bin/ffmpeg.exe /export/bin/; \
    cp /opt/transvortex-ffmpeg/bin/ffprobe.exe /export/bin/; \
    cp /opt/transvortex-ffmpeg/bin/*.dll /export/bin/; \
    cp /work/ffmpeg/COPYING.LGPLv3 /export/licenses/FFmpeg-LICENSE.txt; \
    cp /work/ffmpeg/COPYING.GPLv3 /export/licenses/FFmpeg-GPLv3.txt; \
    cp /work/ffmpeg/LICENSE.md /export/licenses/FFmpeg-LICENSE-SUMMARY.md; \
    printf '%s\n' "${FFMPEG_COMMIT}" > /export/build-info/ffmpeg-commit.txt; \
    printf '%s\n' "${FFMPEG_VERSION}" > /export/build-info/ffmpeg-version.txt; \
    printf '%s\n' "${SOURCE_DATE_EPOCH}" > /export/build-info/source-date-epoch.txt; \
    printf '%s\n' "${FFMPEG_CONFIGURE_FLAGS}" > /export/build-info/configure-flags.txt; \
    "${CC}" --version > /export/build-info/toolchain.txt; \
    for binary in /export/bin/*.exe /export/bin/*.dll; do \
        printf '===== %s =====\n' "$(basename "${binary}")"; \
        "${FFBUILD_TOOLCHAIN}-objdump" -p "${binary}" | sed -n 's/^[[:space:]]*DLL Name: /DLL Name: /p'; \
    done > /export/build-info/pe-imports.txt

FROM scratch AS export
COPY --from=build /export/ /
