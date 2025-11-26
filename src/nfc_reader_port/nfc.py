import base64
import fileinput
from sys import stdin
import time
import board
import busio
from adafruit_pn532.i2c import PN532_I2C

# Setup I2C
i2c = busio.I2C(board.SCL, board.SDA)
pn532 = PN532_I2C(i2c, debug=False)

# Init PN532
pn532.SAM_configuration()


def extract_text_from_ndef(message_bytes):
    try:
        # Look for start of NDEF text record
        if b"\xd1" in message_bytes:
            d1_index = message_bytes.index(0xD1)
            type_len = message_bytes[d1_index + 1]
            payload_len = message_bytes[d1_index + 2]
            lang_len = message_bytes[d1_index + 4]

            text_start = d1_index + 5 + lang_len
            text_end = (
                text_start + payload_len - 1 - lang_len
            )  # Adjust for header and lang code

            raw_text = message_bytes[text_start:text_end]
            return raw_text.decode("utf-8").strip()
        else:
            return "[No NDEF text record found]"
    except Exception as e:
        return f"[Error decoding: {e}]"


def read_nfc():
    while True:
        uid = pn532.read_passive_target(timeout=0.5)
        if uid is None:
            if stdin.closed:
                raise RuntimeError("stdin closed")
            time.sleep(1)
            continue

        message_bytes = bytearray()
        for page in range(4, 16):
            try:
                block = pn532.ntag2xx_read_block(page)
                if block:
                    message_bytes.extend(block)
                else:
                    print(f"Failed to read block {page}")
            except Exception:
                print(f"Failed to read block {page}")
                break

        return (uid, message_bytes)


def main():
    try:
        while True:
            cmd = input()
            match cmd:
                case "read":
                    uid, data = read_nfc()
                    print(
                        f"uid:{base64.b64encode(uid).decode()};data:{base64.b64encode(data).decode()};"
                    )
    except RuntimeError:
        exit(1)
    except KeyboardInterrupt:
        exit(0)
    except EOFError:
        exit(0)


if __name__ == "__main__":
    main()
