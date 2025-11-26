from threading import Timer
import time
import weakref
from gpiozero import InputDevice, OutputDevice, HoldMixin, CompositeDevice
from gpiozero.threads import GPIOThread

KEYMAP = [
    ["1", "2", "3", "A"],
    ["4", "5", "6", "B"],
    ["7", "8", "9", "C"],
    ["*", "0", "#", "D"],
]

ROWS = [6, 13, 19, 26]  # BCM for R1..R4 (phys 31,33,35,37)
COLS = [12, 16, 20, 21]  # BCM for C1..C4 (phys 32,36,38,40)

DEBOUNCE_WINDOW = 0.01


class Keypad(HoldMixin, CompositeDevice):
    def __init__(
        self, rows, cols, *, hold_time=1, hold_repeat=False, pin_factory=None
    ) -> None:
        self.col_pins = [
            InputDevice(p, pull_up=True, pin_factory=pin_factory) for p in cols
        ]
        self.row_pins = [
            OutputDevice(p, initial_value=True, pin_factory=pin_factory) for p in rows
        ]
        self.held_keys = set()
        self.buffer = []
        self.poll_thread = PollThread(self)
        self.flush_timer = Timer(interval=DEBOUNCE_WINDOW, function=self.flush)

        super().__init__(*self.col_pins, *self.row_pins, pin_factory)
        self._fire_events(self.pin_factory.ticks(), self.is_active)  # pyright: ignore[reportOptionalMemberAccess]
        self.hold_time = hold_time
        self.hold_repeat = hold_repeat

    def scan_gpio(self):
        pressed: set[str] = set()
        for i, row in enumerate(self.row_pins):
            row.off()
            for j, col in enumerate(self.col_pins):
                if col.is_active:
                    pressed.add(KEYMAP[i][j])
            row.on()
        return pressed

    def scan(self):
        keys = self.scan_gpio()
        released = self.held_keys.difference(keys)
        pressed = keys.difference(self.held_keys)

        for key in released:
            self.buffer.append((False, key))

        for key in pressed:
            self.buffer.append((True, key))

        if len(released) != 0 and len(pressed) != 0:
            self.flush_timer.cancel()
            self.flush_timer.start()

    def flush(self):
        events = dedupe_events(self.buffer)
        for e in events:
            print(e)


class PollThread(GPIOThread):
    def __init__(self, parent: Keypad):
        super().__init__(target=self.poll, args=weakref.proxy(parent))
        self.start()

    def poll(self, parent: Keypad):
        try:
            while not self.stopping.is_set():
                parent.scan()
                time.sleep(0.002)
        except ReferenceError:
            pass
        pass


def dedupe_events(events: list[tuple[bool, str]]):
    res: list[tuple[bool, str]] = []
    for type, key in events:
        if next(filter(lambda v: v[0] != type, res), None) is None:
            res.append((type, key))
        else:
            res.remove((not type, key))

    return res
