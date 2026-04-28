"""Placeholder Lambda handler for quickship apps.

Auth-naive: the request is guaranteed authenticated by the platform's
chain-of-trust (Cloudflare Access → Transform Rule injects shared secret →
CloudFront WAF verifies → CloudFront SigV4-signs to Lambda Function URL via
OAC). By the time it reaches this code, all that's left is to read the
identity headers Cloudflare added.

Real apps replace this with a FastAPI app whose `current_user` dependency
returns the same dict via Depends. The pipeline overwrites this file on
first deploy (Step 6).
"""

from __future__ import annotations

import json
from typing import Any


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    user_email = headers.get("cf-access-authenticated-user-email", "anonymous")

    http = event.get("requestContext", {}).get("http", {})
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "ok": True,
                "from": "quickship-placeholder",
                "user": user_email,
                "path": http.get("path"),
                "method": http.get("method"),
            }
        ),
    }
