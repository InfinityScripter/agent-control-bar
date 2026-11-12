import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar


SERVER = r'''
import json, sys, time

mode, requests = sys.argv[1:]
for line in sys.stdin:
    request = json.loads(line)
    with open(requests, "a") as fh:
        fh.write(json.dumps(request) + "\n")
    method = request["method"]
    if method == "notifications/initialized":
        continue
    reply = {"jsonrpc": "2.0", "id": request["id"]}
    if method == "initialize":
        reply["result"] = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                           "serverInfo": {"name": "pagination-test", "version": "1"}}
    elif not request["params"].get("cursor"):
        reply["result"] = {"tools": [{"name": "first", "inputSchema": {"type": "object"}}]}
        if mode != "single":
            reply["result"]["nextCursor"] = "page-two"
    else:
        assert request["params"]["cursor"] == "page-two"
        if mode == "eof":
            break
        if mode == "timeout":
            time.sleep(30)
            break
        if mode == "error":
            reply["error"] = {"code": -32603, "message": "Page unavailable"}
        elif mode == "missing-tools":
            reply["result"] = {}
        elif mode == "invalid-tools":
            reply["result"] = {"tools": {}}
        else:
            reply["result"] = {"tools": [] if mode == "empty" else [
                {"name": "second", "inputSchema": {"type": "object"}}]}
    print(json.dumps(reply), flush=True)
'''


class MCPToolPagination(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.requests = os.path.join(self.directory.name, "requests.jsonl")

    def config(self, mode):
        return {"command": "/usr/bin/python3", "args": ["-u", "-c", SERVER, mode, self.requests]}

    def test_complete_results_include_all_pages(self):
        for mode, names in (("single", ["first"]), ("complete", ["first", "second"]),
                            ("empty", ["first"])):
            with self.subTest(mode=mode):
                result = mcpbar.ask_server_for_tools("test", self.config(mode), timeout=5)
                self.assertEqual([tool["name"] for tool in result], names)

    def test_failed_later_page_does_not_return_partial_tools(self):
        for mode in ("error", "eof", "timeout", "missing-tools", "invalid-tools"):
            with self.subTest(mode=mode):
                with open(self.requests, "w"):
                    pass
                result = mcpbar.ask_server_for_tools("test", self.config(mode), timeout=2)
                with open(self.requests) as fh:
                    requests = [json.loads(line) for line in fh]
                self.assertEqual([r.get("params") for r in requests if r["method"] == "tools/list"],
                                 [{}, {"cursor": "page-two"}])
                self.assertIsNone(result)

    def test_refresh_retries_incomplete_list_after_failure_interval(self):
        root = self.directory.name
        paths = {name: os.path.join(root, name.lower() + ".json")
                 for name in ("CONFIG", "SETTINGS", "DESCRIPTIONS")}
        with open(paths["CONFIG"], "w") as fh:
            json.dump({"mcpServers": {"test": self.config("error")}}, fh)
        with open(paths["SETTINGS"], "w") as fh:
            json.dump({}, fh)
        with mock.patch.multiple(mcpbar, **paths):
            mcpbar.refresh_descriptions()
            with open(paths["DESCRIPTIONS"]) as fh:
                entry = json.load(fh)["test"]
        self.assertEqual(entry["tools"], [])
        next_probe = entry["ts"] + mcpbar.DESCRIPTIONS_TTL
        self.assertAlmostEqual(next_probe - time.time(), mcpbar.FAILED_PROBE_RETRY, delta=5)


if __name__ == "__main__":
    unittest.main()
