"""Record a live event camera (any OpenEB/Metavision-supported camera) to a .raw file.

Without --preview, recording starts immediately and runs until --duration elapses or
Ctrl-C is pressed. With --preview, a live window is shown where the camera biases can
be tuned before recording:

    n / p        select next / previous bias (also Down / Up, Tab)
    + / -        increase / decrease the selected bias (also Right / Left, keypad +/-)
    ] / [        larger / smaller step size
    r            reset all biases to their initial values
    s            save the current biases (to --save-biases, default <output>.bias)
    SPACE        start recording (biases are locked); SPACE again stops and exits
    q / ESC      quit

The biases in effect are always written next to the recording as <output>.bias
(Metavision bias file format), so they can be reused with --biases.
"""
import argparse
import os
import signal
import sys
import time

import numpy as np


# Preview key bindings (GTK keysyms: arrows 0xFF51-0xFF54, keypad +/- 0xFFAB/0xFFAD).
KEYS_INC = {ord('+'), ord('='), 0xFFAB, 0xFF53}    # + = keypad+ Right
KEYS_DEC = {ord('-'), ord('_'), 0xFFAD, 0xFF51}    # - _ keypad- Left
KEYS_NEXT = {ord('n'), ord('\t'), 0xFF54}          # n Tab Down
KEYS_PREV = {ord('p'), 0xFF52}                     # p Up
KEYS_QUIT = {ord('q'), 27}


def list_cameras():
    from metavision_hal import DeviceDiscovery
    return list(DeviceDiscovery.list())


def read_bias_file(bias_file):
    """Parse a Metavision bias file ("<value> % <name>" per line)."""
    values = {}
    with open(bias_file) as f:
        for line in f:
            line = line.split('#')[0].strip()
            if not line:
                continue
            value, name = (s.strip() for s in line.split('%'))
            values[name] = int(value)
    return values


def write_bias_file(path, values):
    with open(path, 'w') as f:
        for name, value in sorted(values.items()):
            f.write(f'{value:<6d}% {name}\n')


def event_frame(evs, height, width):
    img = np.full((height, width), 128, dtype=np.uint8)
    on = evs['p'] == 1
    img[evs['y'][on], evs['x'][on]] = 255
    img[evs['y'][~on], evs['x'][~on]] = 0
    return img


class BiasTuner:
    STEPS = (1, 5, 10, 25, 50)

    def __init__(self, ll_biases):
        self.ll_biases = ll_biases
        self.initial = dict(ll_biases.get_all_biases())
        self.names, self.ranges, self.recommended = [], {}, {}
        for name in sorted(self.initial):
            try:
                info = ll_biases.get_bias_info(name)
                if not info.is_modifiable():
                    continue
                allowed = tuple(info.get_bias_allowed_range())
                recommended = tuple(info.get_bias_recommended_range())
            except Exception:  # plugin without bias metadata: let the camera validate values
                allowed, recommended = (-2**31, 2**31 - 1), ('?', '?')
            self.names.append(name)
            self.ranges[name] = allowed
            self.recommended[name] = recommended
        self.selected = 0
        self.step_idx = 2

    def values(self):
        return dict(self.ll_biases.get_all_biases())

    def select(self, delta):
        if self.names:
            self.selected = (self.selected + delta) % len(self.names)

    def change_step(self, delta):
        self.step_idx = min(max(self.step_idx + delta, 0), len(self.STEPS) - 1)

    def adjust(self, sign):
        """Step the selected bias up (sign=1) or down (sign=-1); returns a status message."""
        if not self.names:
            return 'no tunable biases'
        name = self.names[self.selected]
        lo, hi = self.ranges[name]
        current = self.ll_biases.get(name)
        value = current + sign * self.STEPS[self.step_idx]
        # Clamp to the allowed range, but never move against the requested direction
        # (a value already outside the reported range stays where it is).
        value = min(value, max(hi, current)) if sign > 0 else max(value, min(lo, current))
        if value == current:
            return f'{name} at {"max" if sign > 0 else "min"} of allowed range [{lo}, {hi}]'
        if not self.ll_biases.set(name, value):
            return f'camera rejected {name}={value}'
        actual = self.ll_biases.get(name)
        if actual != value:
            return f'{name}: set {value}, camera reports {actual}'
        return f'{name} {current} -> {actual}'

    def reset(self):
        for name in self.names:
            self.ll_biases.set(name, self.initial[name])

    def draw(self, img, locked, message=''):
        import cv2
        values = self.values()
        lines = []  # (text, color)
        for i, name in enumerate(self.names):
            lo, hi = self.recommended[name]
            selected = i == self.selected and not locked
            changed = values[name] != self.initial[name]
            color = (0, 220, 255) if selected else ((255, 170, 60) if changed else (230, 230, 230))
            lines.append((f'{">" if selected else " "} {name:<15s}{values[name]:5d} [{lo}-{hi}]', color))
        if not locked:
            lines.append((f'  step {self.STEPS[self.step_idx]}  arrows or n/p +/-  [ ] r s', (170, 170, 170)))
            if message:
                lines.append((f'  {message}', (120, 255, 120)))

        font, scale, line_h, pad = cv2.FONT_HERSHEY_PLAIN, 1.0, 17, 6
        width = max(cv2.getTextSize(text, font, scale, 1)[0][0] for text, _ in lines) if lines else 0
        x0 = img.shape[1] - width - 2 * pad - 4
        y0, y1 = 4, 4 + len(lines) * line_h + pad
        panel = img[y0:y1, x0:img.shape[1] - 4]
        panel[:] = (panel * 0.3).astype(np.uint8)
        for i, (text, color) in enumerate(lines):
            cv2.putText(img, text, (x0 + pad, y0 + (i + 1) * line_h), font, scale, color, 1, cv2.LINE_AA)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', nargs='?', help='Output .raw file')
    parser.add_argument('--serial', default='', help='Camera serial (default: first camera found). '
                        'A .raw file path replays that file instead (for testing).')
    parser.add_argument('--duration', type=float, default=0, help='Recording length in seconds (0: until stopped)')
    parser.add_argument('--preview', action='store_true', help='Show a live event view with bias tuning (needs a display)')
    parser.add_argument('--biases', help='Metavision bias file to apply at startup')
    parser.add_argument('--save-biases', help='Where "s" saves tuned biases in preview (default: <output>.bias)')
    parser.add_argument('--triggers', action='store_true',
                        help='Enable the external trigger input (for extrinsic calibration with triggers)')
    parser.add_argument('--list', action='store_true', help='List connected cameras and exit')
    parser.add_argument('--debug-keys', action='store_true', help='Show the code of unmapped keys in preview')
    args = parser.parse_args()

    if args.list:
        cameras = list_cameras()
        print('\n'.join(cameras) if cameras else 'no camera found')
        return 0 if cameras else 1

    if not args.output:
        parser.error('output .raw file is required')
    if not args.output.endswith('.raw'):
        parser.error('output must end with .raw')
    if os.path.exists(args.output):
        sys.exit(f'{args.output} already exists')
    if args.preview and not os.environ.get('DISPLAY'):
        sys.exit('--preview needs a display (DISPLAY is not set)')
    bias_out = args.output[:-len('.raw')] + '.bias'
    save_biases_path = args.save_biases or bias_out

    from metavision_core.event_io import EventsIterator
    from metavision_core.event_io.raw_reader import initiate_device

    triggers = []
    if args.triggers:
        from metavision_hal import I_TriggerIn
        triggers = [I_TriggerIn.Channel.MAIN]
    try:
        device = initiate_device(args.serial, use_external_triggers=triggers)
    except OSError as e:
        cameras = list_cameras()
        sys.exit(f'{e}\ncameras found: {cameras or "none"} '
                 '(check the USB connection, udev rules and camera plugin)')
    hw = device.get_i_hw_identification()
    if hw is not None:
        print('camera:', hw.get_serial(), hw.get_sensor_info())

    ll_biases = device.get_i_ll_biases()
    if args.biases:
        if ll_biases is None:
            sys.exit('this camera does not expose biases')
        for name, value in read_bias_file(args.biases).items():
            if not ll_biases.set(name, value):
                print(f'warning: could not set bias {name}={value}')
    tuner = BiasTuner(ll_biases) if ll_biases is not None else None
    if tuner is not None:
        print('biases (value, allowed range, recommended range):')
        for name, value in sorted(tuner.values().items()):
            print(f'  {name:<16s}{value:6d}  {tuner.ranges.get(name, "fixed")}  {tuner.recommended.get(name, "")}')

    stream = device.get_i_events_stream()
    mv_it = EventsIterator.from_device(device=device, delta_t=33333)
    height, width = mv_it.get_size()
    print(f'resolution: {width}x{height}')

    stop = False

    def on_sigint(*_):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGINT, on_sigint)
    signal.signal(signal.SIGTERM, on_sigint)

    recording = False
    t_rec_start = None

    def start_recording():
        nonlocal recording, t_rec_start
        if tuner is not None:
            write_bias_file(bias_out, tuner.values())
            print(f'biases used: {tuner.values()} (saved to {bias_out})')
        if not stream.log_raw_data(args.output):
            sys.exit(f'failed to open {args.output} for writing')
        recording, t_rec_start = True, time.monotonic()
        print(f'recording to {args.output} ...')

    if not args.preview:
        start_recording()
    else:
        import cv2
        window = 'e2calib record'
        cv2.namedWindow(window, cv2.WINDOW_NORMAL)
        print('preview running: tune biases, then press SPACE in the window to start recording')

    last_print = time.monotonic()
    message, message_until = '', 0.0
    for evs in mv_it:
        now = time.monotonic()
        elapsed = now - t_rec_start if recording else 0.0
        if recording and args.duration and elapsed >= args.duration:
            stop = True
        if args.preview:
            img = cv2.cvtColor(event_frame(evs, height, width), cv2.COLOR_GRAY2BGR)
            status = f'REC {elapsed:6.1f}s' if recording else 'PREVIEW - SPACE to record'
            cv2.putText(img, status, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                        (0, 0, 255) if recording else (0, 160, 0), 2)
            cv2.putText(img, f'{evs.size * 30 / 1e6:5.2f} Mev/s', (10, height - 15),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 0, 0), 2)
            if tuner is not None:
                tuner.draw(img, locked=recording, message=message if now < message_until else '')
            cv2.imshow(window, img)
            # GTK reports full keysyms with the modifier state in the high bits; keep the keysym.
            key = cv2.waitKeyEx(1)
            key = key & 0xFFFF if key != -1 else -1
            if key == ord(' '):
                if recording:
                    stop = True
                else:
                    start_recording()
            elif key in KEYS_QUIT:
                stop = True
            elif tuner is not None and not recording and key != -1:
                msg = None
                if key in KEYS_NEXT:
                    tuner.select(1)
                elif key in KEYS_PREV:
                    tuner.select(-1)
                elif key in KEYS_INC:
                    msg = tuner.adjust(1)
                elif key in KEYS_DEC:
                    msg = tuner.adjust(-1)
                elif key == ord(']'):
                    tuner.change_step(1)
                elif key == ord('['):
                    tuner.change_step(-1)
                elif key == ord('r'):
                    tuner.reset()
                    msg = 'biases reset'
                elif key == ord('s'):
                    write_bias_file(save_biases_path, tuner.values())
                    msg = f'saved biases to {save_biases_path}'
                elif args.debug_keys:
                    msg = f'unmapped key 0x{key:04X}'
                if msg:
                    print(msg)
                    message, message_until = msg, now + 3.0
        elif now - last_print >= 1.0:
            last_print = now
            print(f'\r  {elapsed:6.1f}s  {evs.size * 30 / 1e6:5.2f} Mev/s', end='', flush=True)
        if stop:
            break

    if recording:
        stream.stop_log_raw_data()
        size_mb = os.path.getsize(args.output) / 1e6
        print(f'\nsaved {args.output} ({time.monotonic() - t_rec_start:.1f}s, {size_mb:.1f} MB)')
    else:
        print('\nnothing recorded')
    del mv_it, device
    return 0


if __name__ == '__main__':
    sys.exit(main())
