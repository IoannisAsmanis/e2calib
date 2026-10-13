#!/bin/bash
# e2calib container entrypoint: event file -> h5 -> E2VID frames -> rosbag -> Kalibr calibration.
#
# Every stage writes to a temporary name and is renamed on success, so an existing
# output is always complete and is reused on re-runs (use --force to recompute).
set -eo pipefail

E2CALIB_ROOT=${E2CALIB_ROOT:-/opt/e2calib}
E2VID_VENV=${E2VID_VENV:-/opt/e2vid-venv}
E2VID_MODEL=${E2VID_MODEL:-$E2CALIB_ROOT/models/E2VID_lightweight.pth.tar}
KALIBR_WS=${KALIBR_WS:-/opt/kalibr_ws}
PY_SRC=$E2CALIB_ROOT/python

usage() {
    cat <<EOF
Usage: e2calib [calibrate] --input FILE [options]
       e2calib record OUTPUT.raw [--preview] [--duration S] [--biases FILE] [--save-biases FILE] [--serial S] [--triggers]
       e2calib devices                  (list connected event cameras)
       e2calib <command> [args...]      (run any command inside the image, e.g. bash)

Pipeline options:
  -i, --input FILE        Event file: .raw / .dat (Prophesee), .bag (dvs_msgs/EventArray) or .h5
  -o, --output DIR        Output directory (default: /output)
      --target FILE       Kalibr target yaml (aprilgrid/checkerboard/circlegrid).
                          Without it the pipeline stops after image reconstruction.
      --topic TOPIC       Event topic for .bag input (default: /dvs/events)
      --height H          Sensor height (auto-detected for .raw/.dat/.bag)
      --width W           Sensor width  (auto-detected for .raw/.dat/.bag)
      --freq-hz F         Reconstruction frequency of saved frames (default: 5)
      --upsample-rate U   E2VID internal upsampling factor (default: 4)
      --timestamps FILE   Reconstruct at these timestamps [us] instead of --freq-hz
      --models M          Kalibr camera model (default: pinhole-radtan)
      --image-topic T     Image topic in the generated rosbag (default: /dvs/image_reconstructed)
      --e2vid-args "..."  Extra args for offline_reconstruction.py (e.g. "--auto_hdr")
      --kalibr-args "..." Extra args for kalibr_calibrate_cameras
      --cpu               Run E2VID on the CPU even if a GPU is visible
      --force             Recompute all stages, ignoring existing outputs
  -h, --help              Show this help

Outputs (in --output):
  events.h5               Converted events (skipped for .h5 input)
  frames/e2calib/*.png    Reconstructed images, named by timestamp [ns]
  reconstruction.bag      Images as a rosbag for Kalibr
  calibration/            Kalibr camchain yaml, results txt, report pdf, log
EOF
}

log() { echo -e "\n\033[1;34m[e2calib]\033[0m $*"; }
die() { echo -e "\033[1;31m[e2calib] error:\033[0m $*" >&2; exit 1; }

run_pipeline() {
    local input="" output=/output target="" topic=/dvs/events height="" width=""
    local freq_hz=5 upsample_rate=4 timestamps="" models=pinhole-radtan
    local image_topic=/dvs/image_reconstructed e2vid_args="" kalibr_args="" use_cpu=0 force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input)        input=$2; shift 2 ;;
            -o|--output)       output=$2; shift 2 ;;
            --target)          target=$2; shift 2 ;;
            --topic)           topic=$2; shift 2 ;;
            --height)          height=$2; shift 2 ;;
            --width)           width=$2; shift 2 ;;
            --freq-hz)         freq_hz=$2; shift 2 ;;
            --upsample-rate)   upsample_rate=$2; shift 2 ;;
            --timestamps)      timestamps=$2; shift 2 ;;
            --models)          models=$2; shift 2 ;;
            --image-topic)     image_topic=$2; shift 2 ;;
            --e2vid-args)      e2vid_args=$2; shift 2 ;;
            --kalibr-args)     kalibr_args=$2; shift 2 ;;
            --cpu)             use_cpu=1; shift ;;
            --force)           force=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 die "unknown option: $1 (see --help)" ;;
        esac
    done

    [[ -n "$input" ]] || die "--input is required"
    [[ -f "$input" ]] || die "input file not found: $input"
    [[ -z "$target" || -f "$target" ]] || die "target file not found: $target"
    [[ -z "$timestamps" || -f "$timestamps" ]] || die "timestamps file not found: $timestamps"
    mkdir -p "$output"
    output=$(realpath "$output")

    local ext="${input##*.}"
    local h5file frames_dir="$output/frames" bag="$output/reconstruction.bag"
    if [[ $force -eq 1 ]]; then
        rm -rf "$output/events.h5" "$frames_dir" "$bag" "$output/calibration"
    fi

    # ROS python packages (rosbag, sensor_msgs) for the system-python stages.
    source /opt/ros/noetic/setup.bash

    # --- 1. Conversion to h5 ------------------------------------------------
    case "$ext" in
        h5)
            h5file=$input
            log "Input is already h5: $h5file"
            ;;
        raw|dat|bag)
            h5file="$output/events.h5"
            if [[ -f "$h5file" ]]; then
                log "Reusing existing $h5file"
            else
                log "Converting $input -> $h5file"
                rm -f "$output/events.tmp.h5"
                (cd "$PY_SRC" && python3 convert.py "$input" -o "$output/events.tmp.h5" -t "$topic")
                mv "$output/events.tmp.h5" "$h5file"
            fi
            ;;
        *)
            die "unsupported input format: .$ext (expected .raw, .dat, .bag or .h5)"
            ;;
    esac

    # --- 2. Sensor resolution -----------------------------------------------
    if [[ -z "$height" || -z "$width" ]]; then
        [[ "$ext" != h5 ]] || die "--height and --width are required for .h5 input"
        local res
        res=$(cd "$PY_SRC" && python3 "$E2CALIB_ROOT/docker/probe_resolution.py" "$input" -t "$topic") \
            || die "could not detect sensor resolution; pass --height and --width"
        read -r probed_h probed_w <<< "$res"
        height=${height:-$probed_h}
        width=${width:-$probed_w}
    fi
    log "Sensor resolution: ${width}x${height}"

    # --- 3. E2VID reconstruction ----------------------------------------------
    if [[ -d "$frames_dir" ]]; then
        log "Reusing existing frames in $frames_dir"
    else
        local rec_args=(--h5file "$h5file" --height "$height" --width "$width"
                        --upsample_rate "$upsample_rate" -c "$E2VID_MODEL"
                        --output_folder "$frames_dir.tmp" --dataset_name e2calib)
        if [[ -n "$timestamps" ]]; then
            rec_args+=(--timestamps_file "$timestamps")
        else
            rec_args+=(--freq_hz "$freq_hz")
        fi
        if [[ $use_cpu -eq 0 ]] && "$E2VID_VENV/bin/python" -c 'import torch,sys; sys.exit(not torch.cuda.is_available())'; then
            rec_args+=(--use_gpu)
            log "Reconstructing frames with E2VID (GPU)"
        else
            log "Reconstructing frames with E2VID (CPU - this is slow)"
        fi
        # shellcheck disable=SC2206
        rec_args+=($e2vid_args)
        rm -rf "$frames_dir.tmp"
        (cd "$PY_SRC" && "$E2VID_VENV/bin/python" offline_reconstruction.py "${rec_args[@]}")
        mv "$frames_dir.tmp" "$frames_dir"
    fi
    local n_frames
    n_frames=$(find "$frames_dir/e2calib" -maxdepth 1 -name '*.png' | wc -l)
    [[ $n_frames -gt 0 ]] || die "no frames were reconstructed"
    log "$n_frames frames in $frames_dir/e2calib"

    # --- 4. Frames to rosbag --------------------------------------------------
    if [[ -f "$bag" ]]; then
        log "Reusing existing $bag"
    else
        log "Writing frames to $bag (topic $image_topic)"
        local tmp_bag_dir="$output/.rosbag.tmp"
        rm -rf "$tmp_bag_dir"
        (cd "$PY_SRC" && python3 images_to_rosbag.py --rosbag_folder "$tmp_bag_dir" \
            --image_folder "$frames_dir/e2calib" --image_topic "$image_topic")
        mv "$tmp_bag_dir/reconstruction.bag" "$bag"
        rm -rf "$tmp_bag_dir"
    fi

    # --- 5. Kalibr calibration ------------------------------------------------
    if [[ -z "$target" ]]; then
        log "No --target given: stopping after reconstruction. Outputs are in $output"
        return 0
    fi
    local calib_dir="$output/calibration"
    mkdir -p "$calib_dir"
    cp "$target" "$calib_dir/target.yaml"
    source "$KALIBR_WS/devel/setup.bash"
    log "Calibrating with Kalibr (model: $models)"
    # Kalibr writes its results next to the bag, so run it on a link inside calib_dir.
    ln -sf "$bag" "$calib_dir/reconstruction.bag"
    # shellcheck disable=SC2086
    (cd "$calib_dir" && rosrun kalibr kalibr_calibrate_cameras \
        --bag "$calib_dir/reconstruction.bag" \
        --target "$calib_dir/target.yaml" \
        --models $models \
        --topics "$image_topic" \
        --dont-show-report \
        $kalibr_args 2>&1 | tee "$calib_dir/kalibr.log")
    rm -f "$calib_dir/reconstruction.bag"

    local camchain
    camchain=$(find "$calib_dir" -maxdepth 1 -name '*camchain.yaml' | head -1)
    [[ -n "$camchain" ]] || die "Kalibr did not produce a camchain file; see $calib_dir/kalibr.log"
    log "Calibration done: $camchain"
    cat "$camchain"
}

case "${1:-}" in
    ""|-h|--help|help) usage ;;
    calibrate)         shift; run_pipeline "$@" ;;
    record)            shift; exec python3 "$E2CALIB_ROOT/docker/record.py" "$@" ;;
    devices)           exec python3 "$E2CALIB_ROOT/docker/record.py" --list ;;
    -*)                run_pipeline "$@" ;;
    *)                 exec "$@" ;;
esac
