#!/usr/bin/env python3
"""A tiny electrs stand-in for the E2E test.

Script hashes are computed here, independently of the Swift code. Every method received is logged,
and anything beyond what electrs-watch should send gets an error.
Reply shapes follow electrs 0.12.0 src/electrum.rs. This is not a substitute for testing real electrs (M6).
"""
import asyncio
import hashlib
import json
import sys

def scripthash(script_hex):
    return hashlib.sha256(bytes.fromhex(script_hex)).digest()[::-1].hex()

TX = "ab" * 32
WALLET = {
    # 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
    scripthash("76a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac"): (
        {"confirmed": 123456789, "unconfirmed": 0},
        [{"height": 700000, "tx_hash": TX}, {"height": 800000, "tx_hash": TX}],
    ),
    # bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
    scripthash("0014751e76e8199196d454941c45d1b3a323f1433bd6"): (
        {"confirmed": 50000, "unconfirmed": -1000},
        [{"height": 850000, "tx_hash": TX}, {"height": 0, "tx_hash": TX, "fee": 200}],
    ),
}
log_path = sys.argv[2]

def handle(method, params):
    if method == "server.version":
        return ["electrs/0.12.0", "1.4"]
    if method == "blockchain.headers.subscribe":
        return {"height": 900000, "hex": "00" * 80}
    if method == "blockchain.scripthash.get_balance":
        return WALLET[params[0]][0]
    if method == "blockchain.scripthash.get_history":
        return WALLET[params[0]][1]
    raise ValueError("method not allowed")

async def client(reader, writer):
    while line := await reader.readline():
        request = json.loads(line)
        with open(log_path, "a") as log:
            log.write(request["method"] + " " + ",".join(request["params"]) + "\n")
        reply = {"id": request["id"], "jsonrpc": "2.0"}
        try:
            reply["result"] = handle(request["method"], request["params"])
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
