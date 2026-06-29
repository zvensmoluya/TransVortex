from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path
from typing import Any

from .app.desktop_api import DesktopApi, DesktopApiError
from .protocol.errors import classify_exception
from .protocol.redaction import redact


JSONRPC_VERSION = "2.0"


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="transvortex.app_service")
    parser.add_argument("--root", default=".", help="Project root")
    parser.add_argument("--providers-file", default=None, help="Optional providers config file path")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    providers_file = Path(args.providers_file).resolve() if args.providers_file else None
    service = DesktopApi(root_dir=root, providers_file=providers_file)
    serve(service, root_dir=root)


def serve(service: DesktopApi, *, root_dir: Path) -> None:
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        response = handle_line(service, line, root_dir=root_dir)
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def handle_line(service: DesktopApi, line: str, *, root_dir: Path) -> dict[str, Any]:
    request_id: Any = None
    try:
        request = json.loads(line)
        if not isinstance(request, dict):
            raise DesktopApiError("invalid_request", "request must be an object")
        request_id = request.get("id")
        method = request.get("method")
        if not isinstance(method, str) or not method:
            raise DesktopApiError("invalid_request", "method is required")
        params = request.get("params") or {}
        if not isinstance(params, dict):
            raise DesktopApiError("invalid_request", "params must be an object")
        result = service.dispatch(method, params)
        return {
            "jsonrpc": JSONRPC_VERSION,
            "id": request_id,
            "result": redact(result, root_dir=root_dir),
        }
    except json.JSONDecodeError as exc:
        return _error_response(None, "parse_error", f"Invalid JSON: {exc.msg}", root_dir=root_dir)
    except DesktopApiError as exc:
        return _error_response(request_id, exc.code, exc.message, details=exc.details, root_dir=root_dir)
    except Exception as exc:  # noqa: BLE001 - sidecar must never crash on handler errors
        print(traceback.format_exc(), file=sys.stderr, flush=True)
        err = classify_exception(exc)
        return _error_response(
            request_id,
            str(err.get("code") or "internal_error"),
            str(err.get("message") or exc),
            details={"error_info": err},
            root_dir=root_dir,
        )


def _error_response(
    request_id: Any,
    code: str,
    message: str,
    *,
    details: dict[str, Any] | None = None,
    root_dir: Path,
) -> dict[str, Any]:
    return {
        "jsonrpc": JSONRPC_VERSION,
        "id": request_id,
        "error": redact(
            {
                "code": code,
                "message": message,
                "details": details or {},
            },
            root_dir=root_dir,
        ),
    }


if __name__ == "__main__":
    main()
