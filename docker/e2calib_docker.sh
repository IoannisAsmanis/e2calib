#!/bin/bash
# Run e2calib in a container on files from the host.
#
#   docker/e2calib_docker.sh INPUT_FILE OUTPUT_DIR [--target target.yaml] [pipeline options...]
#   docker/e2calib_docker.sh record OUTPUT.raw [--preview] [--duration S] [--biases FILE] [--save-biases FILE] [--serial S] [--triggers]
#   docker/e2calib_docker.sh devices
#
# Calibration: INPUT_FILE is mounted read-only; OUTPUT_DIR is created if needed and
# receives all results, owned by the calling user. File-path options (--target,
# --timestamps) are mounted automatically; other options are passed through.
# Recording: captures a live event camera to OUTPUT.raw. --preview shows a live view for
# tuning biases (SPACE records, q quits); otherwise it records until
# Ctrl-C or --duration. Biases used are saved as OUTPUT.bias. 'devices' lists cameras.
#
# Environment:
#   E2CALIB_IMAGE   image to run (default: e2calib:latest)
#   E2CALIB_GPU     "auto" (default), "on" or "off"
set -eo pipefail

IMAGE=${E2CALIB_IMAGE:-e2calib:latest}
GPU=${E2CALIB_GPU:-auto}

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "$*" >&2; exit 1; }

require_image() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 && return
    echo "image $IMAGE not found; build it with:" >&2
    echo "  docker build -t $IMAGE -f docker/Dockerfile $(cd "$(dirname "$0")/.." && pwd)" >&2
    exit 1
}

tty_flags=()
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

# USB passthrough: privileged container, plus a bind-mount of the bus so cameras that
# re-enumerate after the container starts stay visible.
usb_flags=(--privileged -v /dev/bus/usb:/dev/bus/usb)

# Warn early if a SilkyEvCam (USB vendor 31f7) is attached but not accessible to this user.
check_usb_permissions() {
    command -v lsusb >/dev/null || return 0
    local bus dev node
    while read -r _ bus _ dev _; do
        node="/dev/bus/usb/$bus/${dev%:}"
        if [[ -e "$node" && ! -w "$node" ]]; then
            echo "warning: SilkyEvCam found at $node but it is not writable by $(id -un)." >&2
            echo "  Install the Century Arks udev rule on the host, then re-plug the camera:" >&2
            echo "  docker run --rm --entrypoint cat $IMAGE /opt/e2calib/udev/ca_device.rules | sudo tee /etc/udev/rules.d/ca_device.rules" >&2
            echo "  sudo udevadm control --reload-rules && sudo udevadm trigger" >&2
        fi
    done < <(lsusb -d 31f7: 2>/dev/null)
}

case "$1" in
    ""|-h|--help)
        usage
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo; echo "Pipeline options:"
            docker run --rm "$IMAGE" --help | sed -n '/^Pipeline options:/,$p' | tail -n +2 | grep -vE '^ +-(i|o), '
        fi
        [[ -n "$1" ]] && exit 0
        exit 1
        ;;

    devices)
        require_image
        check_usb_permissions
        exec docker run --rm "${tty_flags[@]}" --user "$(id -u):$(id -g)" "${usb_flags[@]}" "$IMAGE" devices
        ;;

    record)
        shift
        [[ $# -ge 1 && "$1" != -* ]] || die "usage: $0 record OUTPUT.raw [--preview] [--duration S] [--biases FILE] [--save-biases FILE] [--serial S] [--triggers]"
        require_image
        out_dir=$(dirname "$1"); out_name=$(basename "$1"); shift
        mkdir -p "$out_dir"
        out_dir=$(realpath "$out_dir")
        mounts=(-v "$out_dir:/output")
        args=("/output/$out_name")
        display_flags=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --biases)
                    file=$(realpath -e "$2") || die "file not found: $2"
                    mounts+=(-v "$file:/config/$(basename "$file"):ro")
                    args+=("$1" "/config/$(basename "$file")")
                    shift 2 ;;
                --save-biases)
                    mkdir -p "$(dirname "$2")"
                    save_dir=$(realpath "$(dirname "$2")")
                    mounts+=(-v "$save_dir:/save_biases")
                    args+=("$1" "/save_biases/$(basename "$2")")
                    shift 2 ;;
                --preview)
                    [[ -n "$DISPLAY" ]] || die "--preview needs a display (DISPLAY is not set)"
                    display_flags=(-e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix:ro)
                    if [[ -n "$XAUTHORITY" && -f "$XAUTHORITY" ]]; then
                        display_flags+=(-v "$XAUTHORITY:/tmp/.Xauthority:ro" -e XAUTHORITY=/tmp/.Xauthority)
                    fi
                    args+=("$1"); shift ;;
                *)
                    args+=("$1"); shift ;;
            esac
        done
        check_usb_permissions
        exec docker run --rm "${tty_flags[@]}" \
            --user "$(id -u):$(id -g)" \
            "${usb_flags[@]}" "${display_flags[@]}" "${mounts[@]}" \
            "$IMAGE" record "${args[@]}"
        ;;
esac

# --- Calibration pipeline -----------------------------------------------------
[[ $# -ge 2 ]] || { usage; exit 1; }
require_image

input=$(realpath -e "$1") || die "input not found: $1"
mkdir -p "$2"
output=$(realpath "$2")
shift 2

mounts=(-v "$input:/input/$(basename "$input"):ro" -v "$output:/output")
args=(--input "/input/$(basename "$input")" --output /output)

# Rewrite host file paths in the pass-through options to mounted paths.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--timestamps)
            file=$(realpath -e "$2") || die "file not found: $2"
            dest="/config/${1#--}_$(basename "$file")"
            mounts+=(-v "$file:$dest:ro")
            args+=("$1" "$dest")
            shift 2 ;;
        --cpu)
            GPU=off; args+=("$1"); shift ;;
        *)
            args+=("$1"); shift ;;
    esac
done

gpu_flags=()
if [[ "$GPU" == "on" ]] || { [[ "$GPU" == "auto" ]] && docker info 2>/dev/null | grep -qiE 'runtimes:.*nvidia|cdi: nvidia.com/gpu'; }; then
    gpu_flags=(--gpus all)
fi

tty_out=()
[[ -t 1 ]] && tty_out=(-t)

exec docker run --rm "${tty_out[@]}" "${gpu_flags[@]}" \
    --user "$(id -u):$(id -g)" \
    --shm-size=2g \
    "${mounts[@]}" \
    "$IMAGE" calibrate "${args[@]}"
