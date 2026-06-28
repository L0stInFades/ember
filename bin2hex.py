#!/usr/bin/env python3
import sys
data = open(sys.argv[1], "rb").read()
while len(data) % 4: data += b"\x00"
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        w = data[i] | (data[i+1] << 8) | (data[i+2] << 16) | (data[i+3] << 24)
        f.write("%08x\n" % w)
