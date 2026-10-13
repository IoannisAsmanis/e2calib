# e2calib: event-camera calibration in one image.
#
#   events (.raw/.dat/.bag/.h5) --convert--> h5 --E2VID--> frames --> rosbag --Kalibr--> calibration
#
# Contents:
#   * ROS Noetic (rosbag I/O for .bag input/output)
#   * Kalibr (ethz-asl) for image-based camera calibration
#   * E2VID reconstruction (PyTorch, isolated venv) + pretrained weights
#   * OpenEB (open-source Metavision SDK): Prophesee .raw/.dat input and live recording
#     [WITH_METAVISION=1], optionally with the Century Arks SilkyEvCam plugin overlay
#
# Build (from the repository root):
#   docker build -t e2calib:latest -f docker/Dockerfile .
#
# With SilkyEvCam support, pass the plugin source for the matching OpenEB version
# ("SilkyEvCam_plugin_Source_for_MV462" from Century Arks) as a named build context:
#   docker build -t e2calib:latest -f docker/Dockerfile \
#       --build-context silkyevcam=/path/to/SilkyEvCam_plugin_Source_for_MV462 .
#
# Kalibr only supports ROS1, which pins the base to Ubuntu 20.04 / Python 3.8.
# Layers are ordered slowest-changing first: Kalibr and PyTorch are cached while OpenEB
# (and its camera plugins) can be rebuilt in a few minutes.

ARG ROS_DISTRO=noetic

# Empty default for the SilkyEvCam plugin source; replaced by --build-context silkyevcam=DIR.
FROM scratch AS silkyevcam

FROM ros:${ROS_DISTRO}-ros-base-focal

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Number of parallel compile jobs (Kalibr is memory hungry; keep this moderate).
ARG BUILD_JOBS=8

# ---------------------------------------------------------------------------
# Common system dependencies
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git wget curl unzip ca-certificates pkg-config \
        python3-dev python3-pip python3-venv python3-numpy python3-h5py \
        python3-opencv python3-tqdm python3-yaml \
        python3-catkin-tools python3-osrf-pycommon \
        ros-${ROS_DISTRO}-rosbag ros-${ROS_DISTRO}-sensor-msgs ros-${ROS_DISTRO}-cv-bridge \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Kalibr
# ---------------------------------------------------------------------------
ARG KALIBR_REF=master
ENV KALIBR_WS=/opt/kalibr_ws
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake libtool \
        python3-scipy python3-matplotlib python3-wxgtk4.0 python3-tk python3-igraph python3-pyx \
        libeigen3-dev libboost-all-dev libsuitesparse-dev libopencv-dev libpoco-dev \
        libtbb-dev libblas-dev liblapack-dev libv4l-dev \
    && mkdir -p ${KALIBR_WS}/src \
    && git clone --depth 1 --branch ${KALIBR_REF} https://github.com/ethz-asl/kalibr.git ${KALIBR_WS}/src/kalibr \
    && rosdep update --rosdistro ${ROS_DISTRO} \
    && rosdep install --from-paths ${KALIBR_WS}/src --ignore-src -r -y --rosdistro ${ROS_DISTRO} \
    && rm -rf /var/lib/apt/lists/* \
    && cd ${KALIBR_WS} \
    && catkin init \
    && catkin config --extend /opt/ros/${ROS_DISTRO} --cmake-args -DCMAKE_BUILD_TYPE=Release \
    && catkin build -j${BUILD_JOBS} --no-status --summarize \
    && catkin clean -y --build --logs

# ---------------------------------------------------------------------------
# E2VID reconstruction environment (isolated from the system/ROS python)
# ---------------------------------------------------------------------------
ARG TORCH_VERSION=2.4.1
# cu121 for NVIDIA GPUs; use "cpu" for a smaller CPU-only image.
ARG TORCH_FLAVOR=cu121
# numpy<1.24: the E2VID code uses np.int, which numpy 1.24 removed.
ENV E2VID_VENV=/opt/e2vid-venv
RUN python3 -m venv ${E2VID_VENV} \
    && ${E2VID_VENV}/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && ${E2VID_VENV}/bin/pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/${TORCH_FLAVOR} torch==${TORCH_VERSION} \
    && ${E2VID_VENV}/bin/pip install --no-cache-dir \
        "numpy==1.23.5" scipy h5py tqdm "opencv-python-headless==4.10.0.84"

ENV E2VID_MODEL=/opt/e2calib/models/E2VID_lightweight.pth.tar
RUN mkdir -p "$(dirname ${E2VID_MODEL})" \
    && wget -q -O ${E2VID_MODEL} http://rpg.ifi.uzh.ch/data/E2VID/models/E2VID_lightweight.pth.tar

# ---------------------------------------------------------------------------
# OpenEB (Prophesee .raw / .dat support, live cameras). 4.6.x is the last line supporting
# Ubuntu 20.04. If a SilkyEvCam plugin source is provided, it is overlaid onto the OpenEB
# tree before building (this is how Century Arks distributes it).
# ---------------------------------------------------------------------------
ARG WITH_METAVISION=1
ARG OPENEB_VERSION=4.6.2
ARG PYBIND11_VERSION=2.11.1
RUN if [ "${WITH_METAVISION}" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            libboost-all-dev libusb-1.0-0-dev libprotobuf-dev protobuf-compiler \
            libhdf5-dev hdf5-tools libglew-dev libglfw3-dev libopencv-dev \
            libgtest-dev libgmock-dev ffmpeg usbutils \
        && rm -rf /var/lib/apt/lists/* \
        && cd /tmp \
        && wget -q https://github.com/pybind/pybind11/archive/v${PYBIND11_VERSION}.zip \
        && unzip -q v${PYBIND11_VERSION}.zip \
        && cmake -S pybind11-${PYBIND11_VERSION} -B pybind11-build -DPYBIND11_TEST=OFF \
        && cmake --build pybind11-build --target install \
        && rm -rf /tmp/*; \
    fi
COPY --from=silkyevcam / /tmp/silkyevcam/
RUN if [ "${WITH_METAVISION}" = "1" ]; then \
        cd /tmp \
        && git clone --depth 1 --branch ${OPENEB_VERSION} https://github.com/prophesee-ai/openeb.git \
        && if [ -d /tmp/silkyevcam/hal_psee_plugins ]; then \
               echo "Applying SilkyEvCam plugin overlay" \
               && cp -rv /tmp/silkyevcam/hal /tmp/silkyevcam/hal_psee_plugins openeb/ \
               && mkdir -p /opt/e2calib/udev \
               && cp /tmp/silkyevcam/hal_psee_plugins/resources/rules/*.rules /opt/e2calib/udev/; \
           fi \
        && cmake -S openeb -B openeb/build \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTING=OFF \
            -DBUILD_SAMPLES=ON \
            -DCOMPILE_PYTHON3_BINDINGS=ON \
            -DPython3_EXECUTABLE=/usr/bin/python3 \
        && cmake --build openeb/build --config Release -- -j${BUILD_JOBS} \
        && cmake --build openeb/build --target install \
        && ldconfig \
        && mv_py=$(find /usr/local -maxdepth 6 -type d -name metavision_core -path '*-packages/*' -printf '%h\n' | head -1) \
        && echo "${mv_py}" > /usr/lib/python3/dist-packages/openeb.pth; \
    fi \
    && rm -rf /tmp/*
# OpenEB 4.x installs its python modules under /usr/local/local/...; openeb.pth above exposes
# them to the system python.
ENV MV_HAL_PLUGIN_PATH=/usr/local/lib/metavision/hal/plugins \
    HDF5_PLUGIN_PATH=/usr/local/lib/hdf5/plugin

# ---------------------------------------------------------------------------
# e2calib sources + pipeline
# ---------------------------------------------------------------------------
ENV E2CALIB_ROOT=/opt/e2calib
COPY python ${E2CALIB_ROOT}/python
RUN ${E2VID_VENV}/bin/pip install --no-cache-dir ${E2CALIB_ROOT}/python
COPY docker/entrypoint.sh docker/probe_resolution.py docker/record.py ${E2CALIB_ROOT}/docker/
RUN chmod +x ${E2CALIB_ROOT}/docker/entrypoint.sh

# Writable, user-agnostic locations (the container is usually run as the host user).
ENV HOME=/tmp \
    ROS_HOME=/tmp/.ros \
    MPLBACKEND=Agg \
    MPLCONFIGDIR=/tmp/.matplotlib \
    QT_X11_NO_MITSHM=1 \
    PYTHONUNBUFFERED=1

WORKDIR /output
ENTRYPOINT ["/opt/e2calib/docker/entrypoint.sh"]
CMD ["--help"]
