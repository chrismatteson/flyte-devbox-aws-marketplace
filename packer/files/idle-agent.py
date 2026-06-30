"""Idle polling agent.

Every minute, asks Flyte if any execution is in an active phase. If yes,
idle = 0. Else, idle += 1. Publishes IdleMinutes to CloudWatch. A
CloudWatch alarm on the metric drives the stop lambda.
"""
from __future__ import annotations
import asyncio, logging, os, time
from pathlib import Path
import boto3, flyte
from flyte.models import ActionPhase
from flyte.remote import Run

_ENDPOINT = os.environ.get("FLYTE_ENDPOINT", "localhost:30080")
_POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "60"))
_METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FlyteDevbox")
_INSTANCE_ID = os.environ["INSTANCE_ID"]
_REGION = os.environ["AWS_REGION"]
_STATE_FILE = Path("/var/lib/flyte-idle-agent/state")
_ACTIVE_PHASES: tuple[ActionPhase, ...] = (
    ActionPhase.QUEUED,
    ActionPhase.WAITING_FOR_RESOURCES,
    ActionPhase.INITIALIZING,
    ActionPhase.RUNNING,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("flyte-idle-agent")

def _read_state() -> int:
    try: return int(_STATE_FILE.read_text().strip())
    except (FileNotFoundError, ValueError): return 0

def _write_state(v: int) -> None:
    _STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    _STATE_FILE.write_text(str(v))

async def _any_active_runs() -> bool:
    async for _ in Run.listall.aio(in_phase=_ACTIVE_PHASES, limit=1):
        return True
    return False

def _publish(cw, idle_minutes: int) -> None:
    cw.put_metric_data(
        Namespace=_METRIC_NAMESPACE,
        MetricData=[{
            "MetricName": "IdleMinutes",
            "Dimensions": [{"Name": "InstanceId", "Value": _INSTANCE_ID}],
            "Value": float(idle_minutes),
            "Unit": "Count",
        }],
    )

async def _poll_once(cw, idle_minutes: int) -> int:
    try: active = await _any_active_runs()
    except Exception:
        log.exception("query failed; idle unchanged")
        return idle_minutes
    new_value = 0 if active else idle_minutes + max(1, _POLL_INTERVAL_SECONDS // 60)
    try: _publish(cw, new_value)
    except Exception: log.exception("publish failed")
    _write_state(new_value)
    log.info("idle_minutes=%d active=%s", new_value, active)
    return new_value

async def _main() -> None:
    flyte.init(endpoint=_ENDPOINT, insecure=True)
    cw = boto3.client("cloudwatch", region_name=_REGION)
    idle_minutes = _read_state()
    log.info("starting endpoint=%s poll=%ss state=%d", _ENDPOINT, _POLL_INTERVAL_SECONDS, idle_minutes)
    while True:
        t0 = time.monotonic()
        idle_minutes = await _poll_once(cw, idle_minutes)
        await asyncio.sleep(max(0.0, _POLL_INTERVAL_SECONDS - (time.monotonic() - t0)))

if __name__ == "__main__":
    asyncio.run(_main())
