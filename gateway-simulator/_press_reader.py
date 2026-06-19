import serial, sys
PORT = sys.argv[1] if len(sys.argv) > 1 else '/dev/cu.usbserial-D306E89K'
s = serial.Serial(PORT, 9600, bytesize=8, parity='N', stopbits=1, timeout=1)
buf = bytearray()
while True:
    b = s.read(64)
    if not b:
        continue
    buf += b
    while b'\r' in buf:
        i = buf.find(b'\r'); fr = bytes(buf[:i]); del buf[:i+1]
        t = fr.decode('ascii', 'replace').strip()
        if t:
            print(t, flush=True)
