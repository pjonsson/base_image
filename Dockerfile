# syntax=docker/dockerfile:1
# This file builds a Docker base image for its use in FORCE

# Copyright (C) 2020-2025 Gergely Padányi-Gulyás (github user fegyi001),
#                         David Frantz
#                         Fabian Lehmann
#                         Wilfried Weber
#                         Peter A. Jonsson

# Run "docker buildx imagetools inspect ghcr.io/osgeo/gdal:ubuntu-small-3.11.3"
# to get the sha256 of the manifest list so image is multi-arch.
FROM ghcr.io/osgeo/gdal:ubuntu-small-3.13.0@sha256:e0fedbcc5b51bd12617d6a6cf8b7c3244d98cbd29b266925fd9061f40081b351 AS internal_base

# Keep deb packages in Docker cache and increase the number of retries
# when downloading the packages.
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    echo 'Acquire::Retries "10";' > /etc/apt/apt.conf.d/80-retries

# Refresh package list & upgrade existing packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
# Disable interactive frontends.
export DEBIAN_FRONTEND=noninteractive && \
apt-get -y update && apt-get -y upgrade && \
# Install required tools.
apt-get -y install --no-install-recommends \
  # switching UID/GID inside container (for permissions)
  gosu \
  # Required by nlme \
  libblas3 \
  # Numerical library, dynamically linked in FORCE
  libgsl28 \
  # JSON parsing, dynamically linked in FORCE
  libjansson4 \
  # Required by nlme
  liblapack3 \
  # requirement for Rmarkdown
  libuv1t64 \
  # file locking, used in FORCE's bash scripts
  lockfile-progs \
  # file renaming, used in FORCE's bash scripts
  # might not be necessary anymore
  rename \
  # safeguard for Windows EOL files, used in FORCE's bash scripts
  dos2unix \
  # force-higher-level UDFs, dynamically linked in FORCE
  python3 \
  # not sure if still necessary
  python-is-python3 \
  # format conversion, required by Rmarkdown
  pandoc \
  # force-higher-level UDFs, dynamically linked in FORCE
  # standalone force-sample-size script
  # force-level2-report uses Rmarkdown
  r-base \
  # used in all multiprocessing programs
  parallel \
  # reaping of zombie processes
  tini

FROM internal_base AS opencv_builder

ARG OPENCV=https://github.com/opencv/opencv/archive/4.12.0.zip

# Install folder for custom builds.
ENV INSTALL_DIR=/opt/install/src

RUN mkdir -p $INSTALL_DIR/opencv

ADD --checksum=sha256:fa3faf7581f1fa943c9e670cf57dd6ba1c5b4178f363a188a2c8bff1eb28b7e4 --chown=root:root --chmod=644 --link $OPENCV $INSTALL_DIR/opencv

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
export DEBIAN_FRONTEND=noninteractive && \
apt-get -y update && apt-get -y upgrade && \
apt-get install -y --no-install-recommends \
  # GCC compiler etc.
  build-essential \
  # speed up building, only effective for local builds
  ccache \
  # build requirement for OpenCV
  cmake \
  # build requirement for nlme
  gfortran \
  # build requirement for nlme
  libblas-dev \
  # build requirement for nlme
  liblapack-dev \
  # build requirement for Rmarkdown
  libuv1-dev \
  ninja-build \
  # build requirement for OpenCV/FORCE
  pkgconf \
  python3-pip \
  r-cran-renv \
  zlib1g-dev

# Install Python packages
RUN --mount=type=bind,source=requirements.txt,target=requirements.txt \
# Abort build with an error if GDAL versions do not match.
[ "$(grep gdal requirements.txt | awk -F= '{print $3}')" = \
    "$(gdal-config --version)" ] || \
 (echo -n "\n\n" && \
  echo "Image and requirements.txt use different GDAL versions." && \
  echo -n "\n\n" && \
  exit 1) && \
pip3 install --root /build_thirdparty --break-system-packages --no-cache-dir -r requirements.txt

# Install R packages.
WORKDIR /work
RUN mkdir renv

# Packages installed: rmarkdown, echarts4r, snow, snowfall, getopt
#
# Updating the packages in the lock file:
# Rscript -e 'renv::update()' && \
# Rscript -e 'renv::snapshot()'
#
# Bootstrapping renv to generate the first renv.lock & settings:
# Rscript -e 'renv::init(); renv::settings$snapshot.type("all")' && \
# Rscript -e 'install.packages("package", Ncpus = parallel::detectCores(), repos="https://cloud.r-project.org"); if (!library(package, logical.return=T)) quit(save="no", status=10) && \
# Rscript -e 'renv::snapshot()'

COPY --link .Rprofile renv.lock ./
COPY --link renv/activate.R renv/activate.R
COPY --link renv/settings.json renv/settings.json

# Ccache size set from "ccache -s -v" after built from an empty cache.
# Other ccache settings from https://dirk.eddelbuettel.com/blog/2017/11/27/.
RUN --mount=type=cache,id=force-base-renv,target=/root/.cache \
export RENV_PATHS_LIBRARY=/usr/local/lib/R && \
export RENV_CONFIG_CACHE_SYMLINKS=FALSE && \
mkdir -p $HOME/.R $HOME/.config/ccache && \
echo -n "CCACHE=ccache\nCC=\$(CCACHE) gcc\nCXX=\$(CCACHE) g++\nCXX11=\$(CCACHE) g++\nCXX14=\$(CCACHE) g++\nCXX17=\$(CCACHE) g++\nFC=\$(CCACHE) gfortran\nF77=\$(CCACHE) gfortran\n" > $HOME/.R/Makevars && \
echo 'MAKEFLAGS = -j$(shell nproc)' >> $HOME/.R/Makevars && \
echo -n "max_size = 200M\nsloppiness = include_file_ctime\nhash_dir = false\n" > $HOME/.config/ccache/ccache.conf && \
R -s -e 'renv::restore()' && \
rm -rf $HOME/.R $HOME/.config/ccache

# Build OpenCV from source, only include the required parts.
RUN --mount=type=cache,id=force-base-opencv,target=/root/.cache \
ccache -M 20M && \
cd $INSTALL_DIR/opencv && \
unzip -q 4.12.0.zip && \
mkdir -p $INSTALL_DIR/opencv/opencv-4.12.0/build && \
cd $INSTALL_DIR/opencv/opencv-4.12.0/build && \
cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_LIST=ml,imgproc\
  -DWITH_GTK=OFF \
  -DWITH_V4L=OFF \
  -DWITH_ADE=OFF \
  -DWITH_PNG=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_TIFF=OFF \
  -DWITH_WEBP=OFF \
  -DWITH_OPENJPEG=OFF \
  -DWITH_JASPER=OFF \
  -DWITH_OPENEXR=OFF \
  -DWITH_IMGCODEC_HDR=OFF \
  -DWITH_IMGCODEC_SUNRASTER=OFF \
  -DWITH_IMGCODEC_PFM=OFF \
  -DWITH_IMGCODEC_PXM=OFF \
  -DWITH_IMGCODEC_GIF=OFF \
  -DOPENCV_GENERATE_PKGCONFIG=ON \
  .. \
  && ninja \
  && DESTDIR=/build_thirdparty ninja install

FROM internal_base AS builder

# Add login-script for UID/GID-remapping.
COPY --chown=root:root --link remap-user.sh /usr/local/bin/remap-user.sh

COPY --from=opencv_builder --link  /usr/local/lib/R/R-*/* /usr/local/lib/R/site-library/
COPY --from=opencv_builder --link  /build_thirdparty/usr/ /usr/

# De-sudo this image
ENV HOME=/home/ubuntu

# Use this user by default
USER ubuntu

WORKDIR /home/ubuntu

USER root

ENTRYPOINT ["/usr/local/bin/remap-user.sh"]
