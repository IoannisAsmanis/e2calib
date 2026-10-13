"""Print the sensor resolution of an event file as "<height> <width>".

Exits with a non-zero status if the resolution cannot be determined
(e.g. for .h5 files, which do not store it).
"""
import argparse
import sys
from pathlib import Path


def probe_raw(path: Path, _topic: str):
    from metavision_core.event_io import RawReader
    height, width = RawReader(str(path)).get_size()
    return height, width


def probe_dat(path: Path, _topic: str):
    from conversion.prophesee_utils import parse_header
    with open(path, 'rb') as f:
        _, _, _, (height, width) = parse_header(f)
    return height, width


def probe_bag(path: Path, topic: str):
    import rosbag
    with rosbag.Bag(str(path), 'r') as bag:
        for _, msg, _ in bag.read_messages(topics=[topic]):
            return msg.height, msg.width
    raise RuntimeError(f'no messages on topic {topic} in {path}')


PROBES = {'.raw': probe_raw, '.dat': probe_dat, '.bag': probe_bag}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input_file')
    parser.add_argument('--topic', '-t', default='/dvs/events')
    args = parser.parse_args()

    path = Path(args.input_file)
    probe = PROBES.get(path.suffix)
    if probe is None:
        sys.exit(f'cannot infer resolution from {path.suffix} files')
    try:
        height, width = probe(path, args.topic)
    except Exception as e:
        sys.exit(f'failed to read resolution from {path}: {e}')
    if not height or not width:
        sys.exit(f'resolution not stored in {path}')
    print(int(height), int(width))
