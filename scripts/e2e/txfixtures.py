"""Made-up transactions for the tests, built here independently of the Swift parser.

The address page works out amounts from raw transactions, so the mock needs real serializations
whose IDs hash correctly. Scripts are public test-vector addresses. Run directly to print the vectors
that CoreTests.swift checks against.
"""
import hashlib
import struct

LEGACY = "76a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac"  # 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
SEGWIT = "0014751e76e8199196d454941c45d1b3a323f1433bd6"  # bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
STRANGER = "a914e9c3dd0c07aac76179ebc76a6c78d4d67c6c160a87"  # 3P14159f73E4gFr7JterCCQh9QjiTjiZrG


def varint(n):
    if n < 0xFD:
        return bytes([n])
    if n <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", n)
    return b"\xfe" + struct.pack("<I", n)


def tx(inputs, outputs, segwit=False):
    """inputs: [(txid display hex, vout)], outputs: [(sats, script hex)]. Returns (txid, raw hex)."""
    body = varint(len(inputs))
    for txid, vout in inputs:
        body += bytes.fromhex(txid)[::-1] + struct.pack("<I", vout) + varint(1) + b"\x51" + b"\xff\xff\xff\xff"
    body += varint(len(outputs))
    for sats, script in outputs:
        s = bytes.fromhex(script)
        body += struct.pack("<q", sats) + varint(len(s)) + s
    version, locktime = struct.pack("<i", 2), struct.pack("<I", 0)
    txid = hashlib.sha256(hashlib.sha256(version + body + locktime).digest()).digest()[::-1].hex()
    if segwit:
        witness = b"".join(varint(2) + varint(3) + b"\x01\x02\x03" + varint(0) for _ in inputs)
        raw = version + b"\x00\x01" + body + witness + locktime
    else:
        raw = version + body + locktime
    return txid, raw.hex()


def header(time):
    return (struct.pack("<i", 0x20000000) + b"\x00" * 64 + struct.pack("<I", time) + b"\xff\xff\x00\x1d" + b"\x00" * 4).hex()


# Legacy: receives 2 BTC, then spends it, sending 0.76543211 away and 1.23456789 back as change.
FUNDING_A = "11" * 32
A = tx([(FUNDING_A, 0)], [(200_000_000, LEGACY), (5_000, STRANGER)])
B = tx([(A[0], 0)], [(76_543_211, STRANGER), (123_456_789, LEGACY)])
# SegWit: receives 50,000 sats, then a pending spend sends 1,000 away and 49,000 back.
FUNDING_C = "22" * 32
C = tx([(FUNDING_C, 1)], [(50_000, SEGWIT)])
D = tx([(C[0], 0)], [(1_000, STRANGER), (49_000, SEGWIT)], segwit=True)

TRANSACTIONS = dict([A, B, C, D])
HISTORY = {
    LEGACY: [{"height": 700000, "tx_hash": A[0]}, {"height": 800000, "tx_hash": B[0]}],
    SEGWIT: [{"height": 850000, "tx_hash": C[0]}, {"height": 0, "tx_hash": D[0], "fee": 200}],
}
# Roughly the real times of these heights.
HEADERS = {700000: header(1631333672), 800000: header(1690168629), 850000: header(1719500000)}

if __name__ == "__main__":
    for name, (txid, raw) in zip("ABCD", [A, B, C, D]):
        print(name, txid, raw)
    for height, hex_ in HEADERS.items():
        print(height, hex_)
