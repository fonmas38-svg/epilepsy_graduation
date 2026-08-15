"""Small dependency-free request guards for the single-process MVP.

The limiter is intentionally process-local. It protects a demo or one-worker
deployment; a multi-worker production deployment must move the counter to a
shared store such as Redis.
"""
from __future__ import annotations

import json
import time
from collections import defaultdict, deque
from threading import Lock
from typing import Awaitable, Callable

from app.settings import settings

ASGIApp = Callable[[dict, Callable, Callable], Awaitable[None]]


class RequestGuardMiddleware:
    def __init__(self, app: ASGIApp):
        self.app = app
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = Lock()

    @staticmethod
    async def _json_response(send: Callable, status: int, detail: str, headers=None):
        payload = json.dumps({"detail": detail}).encode("utf-8")
        response_headers = [
            (b"content-type", b"application/json"),
            (b"content-length", str(len(payload)).encode("ascii")),
        ]
        if headers:
            response_headers.extend(headers)
        await send({
            "type": "http.response.start",
            "status": status,
            "headers": response_headers,
        })
        await send({"type": "http.response.body", "body": payload})

    def _allowed(self, key: str, now: float) -> tuple[bool, int]:
        limit = settings.rate_limit_requests
        if limit <= 0:
            return True, 0
        cutoff = now - settings.rate_limit_window_seconds
        with self._lock:
            hits = self._hits[key]
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= limit:
                retry_after = max(1, int(hits[0] + settings.rate_limit_window_seconds - now))
                return False, retry_after
            hits.append(now)
            # Avoid retaining inactive client keys forever in long-running demos.
            if len(self._hits) > 10_000:
                stale = [k for k, values in self._hits.items() if not values]
                for stale_key in stale[:1_000]:
                    self._hits.pop(stale_key, None)
            return True, 0

    async def __call__(self, scope: dict, receive: Callable, send: Callable):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "")
        client = scope.get("client") or ("unknown", 0)
        key = f"{client[0]}:{scope.get('method', 'GET')}:{path}"
        allowed, retry_after = self._allowed(key, time.monotonic())
        if not allowed:
            await self._json_response(
                send,
                429,
                "Too many requests",
                [(b"retry-after", str(retry_after).encode("ascii"))],
            )
            return

        max_bytes = settings.max_request_body_bytes
        content_length = next(
            (value for name, value in scope.get("headers", []) if name.lower() == b"content-length"),
            None,
        )
        if content_length is not None:
            try:
                if int(content_length) > max_bytes:
                    await self._json_response(send, 413, "Request body is too large")
                    return
            except ValueError:
                await self._json_response(send, 400, "Invalid Content-Length")
                return

        # Buffer at most max_bytes + 1 so chunked requests cannot bypass the
        # Content-Length check. Replay the body to FastAPI after validation.
        chunks: list[bytes] = []
        size = 0
        while True:
            message = await receive()
            if message.get("type") == "http.disconnect":
                return
            chunk = message.get("body", b"")
            size += len(chunk)
            if size > max_bytes:
                await self._json_response(send, 413, "Request body is too large")
                return
            chunks.append(chunk)
            if not message.get("more_body", False):
                break

        delivered = False

        async def replay_receive():
            nonlocal delivered
            if delivered:
                return {"type": "http.request", "body": b"", "more_body": False}
            delivered = True
            return {"type": "http.request", "body": b"".join(chunks), "more_body": False}

        await self.app(scope, replay_receive, send)