"""
Neptune client helper — SigV4-signed Gremlin queries for IAM-authenticated Neptune.
Used by both config_sync.py and neptune_feeder.py.
"""
import json
import os
from datetime import datetime

from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.session import Session
from urllib import request


NEPTUNE_ENDPOINT = os.environ.get("NEPTUNE_ENDPOINT", "")
NEPTUNE_PORT = os.environ.get("NEPTUNE_PORT", "8182")
REGION = os.environ.get("AWS_REGION", "eu-west-1")

_session = Session()
_credentials = _session.get_credentials()


def neptune_query(gremlin_query):
    """Execute a SigV4-signed Gremlin query against Neptune."""
    url = f"https://{NEPTUNE_ENDPOINT}:{NEPTUNE_PORT}/gremlin"
    payload = json.dumps({"gremlin": gremlin_query})

    # Sign the request with SigV4
    aws_request = AWSRequest(method="POST", url=url, data=payload, headers={
        "Content-Type": "application/json",
        "Host": f"{NEPTUNE_ENDPOINT}:{NEPTUNE_PORT}",
    })
    SigV4Auth(_credentials.get_frozen_credentials(), "neptune-db", REGION).add_auth(aws_request)

    # Execute
    req = request.Request(url, data=payload.encode(), headers=dict(aws_request.headers), method="POST")
    try:
        resp = request.urlopen(req, timeout=30)
        return json.loads(resp.read().decode())
    except Exception as e:
        if hasattr(e, 'read'):
            body = e.read().decode()
            print(f"Neptune error detail: {body[:500]}")
            print(f"Query was: {gremlin_query[:200]}")
        raise


def upsert_vertex(vertex_id, label, properties):
    """Add or update a vertex. Uses fold/coalesce pattern."""
    safe_id = vertex_id.replace("\\", "\\\\").replace("'", "\\'")
    props = ""
    for k, v in properties.items():
        if v:
            safe_v = str(v).replace("\\", "\\\\").replace("'", "\\'")
            props += f".property(single, '{k}', '{safe_v}')"
    query = (
        f"g.V().has(id, '{safe_id}').fold()"
        f".coalesce(unfold(), addV('{label}').property(id, '{safe_id}'))"
        f"{props}"
    )
    return neptune_query(query)


def upsert_edge(from_id, to_id, label, properties=None):
    """Add an edge if it doesn't exist."""
    safe_from = from_id.replace("\\", "\\\\").replace("'", "\\'")
    safe_to = to_id.replace("\\", "\\\\").replace("'", "\\'")
    query = (
        f"g.V('{safe_from}').outE('{label}').where(inV().hasId('{safe_to}')).fold()"
        f".coalesce(unfold(), "
        f"addE('{label}').from(V('{safe_from}')).to(V('{safe_to}')))"
    )
    return neptune_query(query)
