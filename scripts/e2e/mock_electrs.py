#!/usr/bin/env python3
"""A tiny electrs stand-in for the E2E test.

Script hashes are computed here, independently of the Swift code. Every method received is logged,
and anything beyond what electrs-watch should send gets an error.
Reply shapes follow electrs 0.12.0 src/electrum.rs. This is not a substitute for testing real electrs (M6).
"""
import asyncio
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from txfixtures import HEADERS, HISTORY, LEGACY, SEGWIT, TRANSACTIONS

def scripthash(script_hex):
    return hashlib.sha256(bytes.fromhex(script_hex)).digest()[::-1].hex()

# Balances agree with the transactions, which the app checks.
WALLET = {
    scripthash(LEGACY): ({"confirmed": 123456789, "unconfirmed": 0}, HISTORY[LEGACY]),
    scripthash(SEGWIT): ({"confirmed": 50000, "unconfirmed": -1000}, HISTORY[SEGWIT]),
}
log_path = sys.argv[2]

def handle(method, params, subscribed):
    if method == "server.version":
        return ["electrs/0.12.0", "1.4"]
    if method == "blockchain.headers.subscribe":
        return {"height": 900000, "hex": "00" * 80}
    if method == "blockchain.scripthash.subscribe":
        WALLET[params[0]]
        subscribed.add(params[0])
        return "cd" * 32
    # Real electrs answers these but logs a notice about the extra work. Failing here catches a regression.
    if method in ("blockchain.scripthash.get_balance", "blockchain.scripthash.get_history") and params[0] not in subscribed:
        raise ValueError("queried before subscribing")
    if method == "blockchain.scripthash.get_balance":
        return WALLET[params[0]][0]
    if method == "blockchain.scripthash.get_history":
        return WALLET[params[0]][1]
    # Only the plain form: the app checks raw bytes against the ID and never asks for verbose output.
    if method == "blockchain.transaction.get" and len(params) == 1:
        return TRANSACTIONS[params[0]]
    if method == "blockchain.block.header" and len(params) == 1:
        return HEADERS[params[0]]
    raise ValueError("method not allowed")

async def client(reader, writer):
    subscribed = set()
    while line := await reader.readline():
        request = json.loads(line)
        with open(log_path, "a") as log:
            log.write(request["method"] + " " + ",".join(map(str, request["params"])) + "\n")
        reply = {"id": request["id"], "jsonrpc": "2.0"}
        try:
            reply["result"] = handle(request["method"], request["params"], subscribed)
        except (ValueError, KeyError, IndexError):
            reply["error"] = {"code": 1, "message": "rejected by mock"}
        writer.write(json.dumps(reply).encode() + b"\n")
        await writer.drain()
    writer.close()

async def main():
    server = await asyncio.start_server(client, "127.0.0.1", int(sys.argv[1]))
    async with server:
        await server.serve_forever()

asyncio.run(main())
