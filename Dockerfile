FROM ghcr.io/sdr-enthusiasts/docker-baseimage:mlatclient AS buildimage

SHELL ["/bin/bash", "-x", "-o", "pipefail", "-c"]
RUN \
    --mount=type=bind,source=./,target=/app/ \
    # this baseimage has build-essential installed, no need to install it
    #apt-get update -q -y && \
    #apt-get install -o Dpkg::Options::="--force-confnew" -y --no-install-recommends -q \
    #    build-essential && \
    gcc -static /app/downloads/distance-in-meters.c -o /distance -lm -O2

FROM ghcr.io/sdr-enthusiasts/docker-baseimage:mlatclient AS readsbcustom

SHELL ["/bin/bash", "-x", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008,SC2086,DL4006,SC2039
RUN \
  apt-get update -q -y && \
  apt-get install -o Dpkg::Options::="--force-confnew" -y --no-install-recommends -q \
  librtlsdr-dev \
  && \
  # custom readsb (zulufoxtrot fork, adds local-aircraft.json + ICAO suppress filter)
  # pinned to a specific commit so layer cache is busted on every fork update
  git clone \
  --branch "dev" \
  --depth 1 \
  --single-branch \
  'https://github.com/zulufoxtrot/readsb.git' \
  '/src/readsb' \
  && \
  pushd /src/readsb && \
  git checkout b71be29 && \
  make \
  RTLSDR=yes \
  AIRCRAFT_HASH_BITS=14 \
  DISABLE_RTLSDR_ZEROCOPY_WORKAROUND=yes \
  -j "$(nproc)" \
  && \
  cp readsb /usr/local/bin/ && \
  /usr/local/bin/readsb --version && \
  popd && \
  true

FROM ghcr.io/sdr-enthusiasts/docker-tar1090:latest

LABEL org.opencontainers.image.source="https://github.com/zulufoxtrot/docker-adsb-ultrafeeder"

# DL3064 matches on the variable *name* containing "PRIVATE", regardless of its
# value. PRIVATE_MLAT is a boolean toggle for the mlat-client privacy flag, not
# a credential, so this is a false positive.
# hadolint ignore=DL3064
ENV \
    PRIVATE_MLAT="false" \
    MLAT_INPUT_TYPE="auto"

ARG VERSION_REPO="zulufoxtrot/docker-adsb-ultrafeeder" \
    VERSION_BRANCH="##BRANCH##"

SHELL ["/bin/bash", "-x", "-o", "pipefail", "-c"]
RUN \
    --mount=type=bind,from=buildimage,source=/,target=/buildimage/ \
    --mount=type=bind,from=readsbcustom,source=/,target=/readsbcustom/ \
    TEMP_PACKAGES=() && \
    KEPT_PACKAGES=() && \
    # packages needed for debugging - these can stay out in production builds:
    #KEPT_PACKAGES+=(procps nano aptitude psmisc) && \
    KEPT_PACKAGES+=(libjemalloc2) && \
    # Install all these packages:
    apt-get update -q -y && \
    apt-get install -o Dpkg::Options::="--force-confnew" -y --no-install-recommends -q \
        "${KEPT_PACKAGES[@]}" \
        "${TEMP_PACKAGES[@]}" && \
    # Get distance binary
    cp -f  /buildimage/distance /usr/local/bin/distance && \
    # Overlay custom readsb binary (zulufoxtrot fork with dedup features)
    cp -f /readsbcustom/usr/local/bin/readsb /usr/local/bin/readsb && \
    /usr/local/bin/readsb --version && \
    # Add Container Version
    { [[ "${VERSION_BRANCH:0:1}" == "#" ]] && VERSION_BRANCH="main" || true; } && \
    echo "$(TZ=UTC date +%Y%m%d-%H%M%S)_$(curl -ssL "https://api.github.com/repos/$VERSION_REPO/commits/$VERSION_BRANCH" | awk '{if ($1=="\"sha\":") {print substr($2,2,7); exit}}')_$VERSION_BRANCH" > /.CONTAINER_VERSION && \
    # Clean up:
    apt-get autoremove -q -o APT::Autoremove::RecommendsImportant=0 -o APT::Autoremove::SuggestsImportant=0 -y "${TEMP_PACKAGES[@]}" && \
    apt-get clean -q -y && \
    rm -rf /src /tmp/* /var/lib/apt/lists/* /git /var/cache/* && \
    bash /scripts/clean-build.sh && \
    #
    # Do some stuff for kx1t's convenience:
    echo "alias dir=\"ls -alsv\"" >> /root/.bashrc && \
    echo "alias nano=\"nano -l\"" >> /root/.bashrc

COPY rootfs/ /
