#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
import uuid

url, protocol, device_id, artifact_path, upload_root = sys.argv[1:6]
next_id = 0
proc = None
events = None
pushes = []
hello = {"deviceId": device_id, "appVersion": "smoke-1.0", "protocolVersion": 1}


def collect(stream, event_queue, kind):
    for line in stream:
        event_queue.put((kind, line))


def close_socket():
    global proc
    if proc is None:
        return
    if proc.stdin:
        proc.stdin.close()
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    proc = None


def reconnect():
    global proc, events
    close_socket()
    proc = subprocess.Popen(
        ["websocat", "--protocol", protocol, "-n", "-t", "-B", "2000000", url],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    events = queue.Queue()
    threading.Thread(target=collect, args=(proc.stdout, events, "stdout"), daemon=True).start()
    threading.Thread(target=collect, args=(proc.stderr, events, "stderr"), daemon=True).start()
    send(hello)


def send(value):
    proc.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def exchange(requests):
    expected = {request["id"] for request in requests}
    responses = {}
    for request in requests:
        send(request)
    deadline = time.monotonic() + 15
    while expected:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("timed out waiting for websocket state")
        try:
            kind, line = events.get(timeout=remaining)
        except queue.Empty as error:
            raise RuntimeError("timed out waiting for websocket state") from error
        if kind == "stderr":
            raise RuntimeError("websocat: " + line.strip())
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("non-JSON websocket output: " + line.strip()) from error
        message_id = message.get("id")
        if message_id in expected:
            responses[message_id] = message
            expected.remove(message_id)
        else:
            pushes.append(message)
    return list(responses.values())


def call(method, params):
    global next_id
    next_id += 1
    request_id = "smoke-" + str(next_id)
    request = {"id": request_id, "method": method, "params": params}
    for message in exchange([request]):
        if message.get("id") == request_id:
            return message
    raise RuntimeError("missing websocket response for " + method)


def require_ok(response, context):
    if response.get("error") is not None or response.get("ok") is False:
        raise RuntimeError(context + ": " + json.dumps(response, sort_keys=True))
    return response.get("result", {})


def require_error_with_liveness(method, params, code, data, context):
    global next_id
    next_id += 1
    malformed_id = "smoke-" + str(next_id)
    next_id += 1
    battery_id = "smoke-" + str(next_id)
    messages = exchange([
        {"id": malformed_id, "method": method, "params": params},
        {"id": battery_id, "method": "host.battery", "params": {}},
    ])
    responses = {message.get("id"): message for message in messages if "id" in message}
    malformed = responses.get(malformed_id, {})
    actual = (malformed.get("error") or {}).get("code")
    actual_data = (malformed.get("error") or {}).get("data")
    if actual != code or actual_data != data:
        raise RuntimeError(
            f"{context}: expected code={code} data={data!r}, got {json.dumps(malformed, sort_keys=True)}"
        )
    battery = require_ok(responses.get(battery_id, {}), context + " liveness")
    if "level" not in battery and "state" not in battery:
        raise RuntimeError(context + " liveness returned malformed battery payload")


def begin(data, digest, filename, batch_id=None, file_count=1, batch_bytes=None):
    if batch_id is None:
        batch_id = str(uuid.uuid4())
    if batch_bytes is None:
        batch_bytes = len(data)
    result = require_ok(call("file.upload.begin", {
        "batch_id": batch_id,
        "filename": filename,
        "mime_type": "application/octet-stream",
        "bytes": len(data),
        "sha256": digest,
        "batch_file_count": file_count,
        "batch_bytes": batch_bytes,
    }), "upload begin")
    if result.get("batch_id") != batch_id:
        raise RuntimeError("upload begin did not echo stable batch_id")
    return result["upload_id"]


created_workspace_id = None
try:
    reconnect()
    capabilities = require_ok(call("host.capabilities", {}), "host.capabilities").get("capabilities", [])
    if capabilities != ["file.upload.v2", "terminal.artifact.v1"]:
        raise RuntimeError("unexpected relay capabilities: " + repr(capabilities))

    upload_data = (b"cmux-upload-chunk-" * 1800) + b"tail"
    upload_hash = hashlib.sha256(upload_data).hexdigest()
    upload_id = begin(upload_data, upload_hash, "smoke-upload.bin")
    offset = 0
    for raw in (upload_data[:16 * 1024], upload_data[16 * 1024:]):
        result = require_ok(call("file.upload.chunk", {
            "upload_id": upload_id,
            "offset": offset,
            "data_base64": base64.b64encode(raw).decode("ascii"),
        }), "upload chunk")
        offset = result["next_offset"]
    committed = require_ok(call("file.upload.commit", {"upload_id": upload_id}), "upload commit")
    committed_path = committed["path"]
    if committed["bytes"] != len(upload_data) or committed["sha256"] != upload_hash:
        raise RuntimeError("committed upload metadata mismatch")
    if open(committed_path, "rb").read() != upload_data:
        raise RuntimeError("committed upload bytes mismatch")

    malformed_data = b"cancel-me"
    malformed_id = begin(malformed_data, hashlib.sha256(malformed_data).hexdigest(), "cancel.bin")
    require_error_with_liveness("file.upload.chunk", {
        "upload_id": malformed_id, "offset": 0, "data_base64": "%%%",
    }, "invalid_base64", {"field": "data_base64"}, "malformed base64")
    require_error_with_liveness("file.upload.chunk", {
        "upload_id": malformed_id, "offset": 1,
        "data_base64": base64.b64encode(malformed_data).decode("ascii"),
    }, "invalid_offset", {"field": "offset"}, "wrong offset")
    require_ok(call("file.upload.cancel", {"upload_id": malformed_id}), "upload cancel")
    require_error_with_liveness("file.upload.chunk", {
        "upload_id": malformed_id, "offset": 0,
        "data_base64": base64.b64encode(malformed_data).decode("ascii"),
    }, "upload_not_found", None, "cancelled upload")

    wrong_hash_data = b"wrong-hash"
    wrong_hash_id = begin(wrong_hash_data, "0" * 64, "wrong-hash.bin")
    require_ok(call("file.upload.chunk", {
        "upload_id": wrong_hash_id, "offset": 0,
        "data_base64": base64.b64encode(wrong_hash_data).decode("ascii"),
    }), "wrong hash chunk")
    require_error_with_liveness(
        "file.upload.commit", {"upload_id": wrong_hash_id}, "hash_mismatch", None, "wrong hash"
    )

    empty_hash = hashlib.sha256(b"").hexdigest()
    reconnect_batch_id = str(uuid.uuid4())
    reconnect_committed_paths = []
    for index in range(10):
        reconnect()
        reconnect_upload_id = begin(
            b"", empty_hash, f"reconnect-{index}.bin",
            batch_id=reconnect_batch_id, file_count=10, batch_bytes=0,
        )
        reconnect_result = require_ok(call(
            "file.upload.commit", {"upload_id": reconnect_upload_id}
        ), "reconnect upload commit")
        reconnect_committed_paths.append(reconnect_result["path"])
    reconnect()
    require_error_with_liveness("file.upload.begin", {
        "batch_id": reconnect_batch_id,
        "filename": "eleventh.bin",
        "mime_type": "application/octet-stream",
        "bytes": 0,
        "sha256": empty_hash,
        "batch_file_count": 10,
        "batch_bytes": 0,
    }, "size_limit_exceeded", {"field": "batch_file_count"}, "eleventh reconnect begin")
    require_error_with_liveness("file.upload.begin", {
        "batch_id": reconnect_batch_id,
        "filename": "conflicting-total.bin",
        "mime_type": "application/octet-stream",
        "bytes": 0,
        "sha256": empty_hash,
        "batch_file_count": 9,
        "batch_bytes": 0,
    }, "upload_conflict", {"field": "batch_id"}, "conflicting batch totals")

    aggregate_batch_id = str(uuid.uuid4())
    aggregate_upload_ids = []
    for index, declared_bytes in enumerate((100 * 1024 * 1024, 100 * 1024 * 1024, 50 * 1024 * 1024)):
        reconnect()
        aggregate_result = require_ok(call("file.upload.begin", {
            "batch_id": aggregate_batch_id,
            "filename": f"aggregate-{index}.bin",
            "mime_type": "application/octet-stream",
            "bytes": declared_bytes,
            "sha256": empty_hash,
            "batch_file_count": 4,
            "batch_bytes": 250 * 1024 * 1024,
        }), "aggregate begin")
        if aggregate_result.get("batch_id") != aggregate_batch_id:
            raise RuntimeError("aggregate begin did not echo stable batch_id")
        aggregate_upload_ids.append(aggregate_result["upload_id"])
    reconnect()
    require_error_with_liveness("file.upload.begin", {
        "batch_id": aggregate_batch_id,
        "filename": "aggregate-overflow.bin",
        "mime_type": "application/octet-stream",
        "bytes": 1,
        "sha256": empty_hash,
        "batch_file_count": 4,
        "batch_bytes": 250 * 1024 * 1024,
    }, "size_limit_exceeded", {"field": "batch_bytes"}, "aggregate bytes across reconnects")
    for aggregate_upload_id in aggregate_upload_ids:
        require_ok(call("file.upload.cancel", {"upload_id": aggregate_upload_id}), "aggregate cleanup")
    print("UPLOAD_CHUNK_OK", flush=True)

    created = require_ok(call("workspace.create", {
        "title": "cmux-relay-smoke-" + uuid.uuid4().hex[:8],
    }), "workspace.create")
    workspace = created.get("workspace", created)
    workspace_id = workspace.get("id") or workspace.get("workspace_id")
    if not workspace_id:
        raise RuntimeError("workspace.create omitted workspace id: " + json.dumps(created, sort_keys=True))
    created_workspace_id = workspace_id
    surface_result = require_ok(call("surface.create", {
        "workspace_id": workspace_id, "type": "terminal", "focus": True,
    }), "surface.create")
    surface_id = surface_result.get("surface_id") or surface_result.get("surface", {}).get("id")
    if not surface_id:
        raise RuntimeError("surface.create omitted surface_id: " + json.dumps(surface_result, sort_keys=True))
    require_ok(call("surface.subscribe", {
        "workspace_id": workspace_id, "surface_id": surface_id, "lines": 200,
    }), "surface.subscribe")
    require_ok(call("surface.focus", {
        "workspace_id": workspace_id, "surface_id": surface_id,
    }), "surface.focus")
    pushes.clear()
    command = "printf '%s\\n' " + shlex.quote(artifact_path)
    require_ok(call("surface.send_text", {
        "workspace_id": workspace_id, "surface_id": surface_id, "text": command,
    }), "surface.send_text")
    require_ok(call("surface.send_key", {
        "workspace_id": workspace_id, "surface_id": surface_id, "key": "enter",
    }), "surface.send_key")
    deadline = time.monotonic() + 10
    while not any(artifact_path in json.dumps(push, ensure_ascii=False) for push in pushes):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("artifact path did not reach a pushed terminal screen row")
        try:
            kind, line = events.get(timeout=remaining)
        except queue.Empty as error:
            raise RuntimeError("timed out waiting for terminal update") from error
        if kind == "stderr":
            raise RuntimeError("websocat: " + line.strip())
        message = json.loads(line)
        if "id" not in message:
            pushes.append(message)
    scan = require_ok(call("terminal.artifact.scan", {
        "workspace_id": workspace_id, "surface_id": surface_id,
    }), "terminal.artifact.scan")
    artifacts = scan.get("artifacts", [])
    artifact = next((item for item in artifacts if item.get("filename") == os.path.basename(artifact_path)), None)
    if artifact is None:
        raise RuntimeError("terminal-visible PNG was not authorized: " + json.dumps(scan, sort_keys=True))
    artifact_id = artifact["artifact_id"]

    require_error_with_liveness(
        "terminal.artifact.stat",
        {"artifact_id": str(uuid.uuid4())},
        "forbidden",
        {"field": "artifact_id"},
        "unauthorized artifact"
    )
    stat = require_ok(call("terminal.artifact.stat", {"artifact_id": artifact_id}), "artifact stat")
    thumbnail = require_ok(call("terminal.artifact.thumbnail", {
        "artifact_id": artifact_id, "dimension": 512,
    }), "artifact thumbnail")
    thumbnail_bytes = base64.b64decode(thumbnail["data_base64"], validate=True)
    if not thumbnail_bytes.startswith(b"\xff\xd8") or thumbnail["mime_type"] != "image/jpeg":
        raise RuntimeError("artifact thumbnail was not a JPEG")
    fetched = require_ok(call("terminal.artifact.fetch", {
        "artifact_id": artifact_id, "offset": 0,
    }), "artifact fetch")
    fetched_bytes = base64.b64decode(fetched["data_base64"], validate=True)
    expected_bytes = open(artifact_path, "rb").read()
    if fetched_bytes != expected_bytes or not fetched["eof"] or stat["bytes"] != len(expected_bytes):
        raise RuntimeError("artifact fetch/stat mismatch")
    print("ARTIFACT_FALLBACK_OK", flush=True)

    os.unlink(committed_path)
    for reconnect_committed_path in reconnect_committed_paths:
        os.unlink(reconnect_committed_path)
    os.unlink(artifact_path)
    uploads = os.path.join(upload_root, ".uploads")
    if os.path.isdir(uploads) and os.listdir(uploads):
        raise RuntimeError("temporary upload residue remains: " + repr(os.listdir(uploads)))
    require_ok(call("host.battery", {}), "final liveness")
    print("SMOKE_FULL_INTEGRATION_OK", flush=True)
finally:
    if created_workspace_id is not None:
        try:
            require_ok(call("workspace.close", {"workspace_id": created_workspace_id}), "workspace.close")
        except Exception as cleanup_error:
            print("workspace cleanup failed: " + str(cleanup_error), file=sys.stderr)
    close_socket()
