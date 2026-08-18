import json
import time
import sys

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("pyserial is required. Install it with: pip install pyserial")
    sys.exit(1)


def detect_port():
    ports = list(serial.tools.list_ports.comports())
    if not ports:
        print("No serial ports found.")
        sys.exit(1)

    for p in ports:
        print(f"Found: {p.device} - {p.description}")

    for p in ports:
        if "USB" in p.description or "UART" in p.description or "CH340" in p.description or "CP210" in p.description:
            return p.device

    return ports[0].device


def send_payload(ser, payload):
    data = json.dumps(payload) + "\n"
    ser.write(data.encode("utf-8"))
    print(f"Sent: {data.strip()}")


def main():
    port = detect_port()
    print(f"Using port: {port}")

    try:
        ser = serial.Serial(port, 115200, timeout=1)
    except serial.SerialException as e:
        print(f"Failed to open {port}: {e}")
        sys.exit(1)

    time.sleep(2)
    print("Connected. Cycling through test payloads...\n")

    try:
        while True:
            print("1. Idle (breathing cyan)")
            send_payload(ser, {
                "total_leds": 24,
                "segments": []
            })
            time.sleep(5)

            print("2. One session - pulse")
            send_payload(ser, {
                "total_leds": 24,
                "segments": [
                    {"start": 0, "end": 11, "color": [99, 102, 241], "dotColor": [255, 255, 255], "animation": "pulse"}
                ]
            })
            time.sleep(5)

            print("3. Two sessions - bounce")
            send_payload(ser, {
                "total_leds": 24,
                "segments": [
                    {"start": 0, "end": 11, "color": [99, 102, 241], "dotColor": [255, 220, 0], "animation": "bounce"},
                    {"start": 12, "end": 23, "color": [245, 158, 11], "dotColor": [255, 255, 255], "animation": "bounce"}
                ]
            })
            time.sleep(5)

            print("4. Solid fill")
            send_payload(ser, {
                "total_leds": 24,
                "segments": [
                    {"start": 0, "end": 23, "color": [16, 185, 129], "dotColor": [0, 0, 0], "animation": "solid"}
                ]
            })
            time.sleep(5)

    except KeyboardInterrupt:
        print("\nExiting...")
    finally:
        ser.close()


if __name__ == "__main__":
    main()
