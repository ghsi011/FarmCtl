# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run: python tool/host_simulator/serve.py (stdin EOF stops the owned server).
"""Supervised entrypoint for the shared loopback fixture."""

import json
import sys
from threading import Thread

from gist_service import GistService


def main() -> None:
    match sys.argv[1:]:
        case []:
            server = GistService()
        case ["interrupted"]:
            from interrupted_service import InterruptedService

            server = InterruptedService()
        case _:
            raise RuntimeError("unsupported fixture profile")
    with server:
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            print(json.dumps({"port": server.server_port}), flush=True)
            # The owner holds stdin open; EOF is the cleanup signal.
            sys.stdin.read()
        finally:
            server.shutdown()
            worker.join(timeout=4)
            if worker.is_alive():
                raise RuntimeError("fixture cleanup failed")
    print("FARMCTL_SERVICE_STOPPED", flush=True)


if __name__ == "__main__":
    main()
