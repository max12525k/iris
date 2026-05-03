#!/opt/hermes/.venv/bin/python
"""Shared OpenTelemetry span emitter for iris-* wrappers.

Used by the bash wrappers (iris-learn, iris-cron, iris-skill, iris-mcp) to
record every action they take as a span. Spans flow:

    wrapper --[OTLP gRPC]--> otel-collector --[exporters]--> prometheus + loki

The collector aggregates spans into Prometheus metrics (for rate/count
dashboards) AND fans them out as Loki log lines (for text search).

Usage from bash:
    _otel_emit --category <cat> --action <act> --subject <sub> [--outcome <out>]
              [--trace-id <id>] [--cost-usd <n>] [--attr key=value]...

CLI invocation produces ONE span, exits 0. The wrapper is expected to call
this multiple times during a run (start, install, commit) so each step is
independently visible.

Environment variables consumed:
    OTEL_EXPORTER_OTLP_ENDPOINT   default http://otel-collector:4317
    OTEL_SERVICE_NAME             default "iris-${HERMES_PROFILE:-default}"
    HERMES_PROFILE                used to tag the span
    IRIS_TENANT                   optional, used in Phase 7 multi-tenant
"""
from __future__ import annotations

import argparse
import os
import sys

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode


def _build_provider() -> TracerProvider:
    profile = os.environ.get("HERMES_PROFILE", "default")
    service_name = os.environ.get("OTEL_SERVICE_NAME", f"iris-{profile}")
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")

    resource = Resource.create(
        {
            "service.name": service_name,
            "service.namespace": "iris",
            "service.instance.id": os.environ.get("HOSTNAME", "unknown"),
            "iris.profile": profile,
            "iris.tenant": os.environ.get("IRIS_TENANT", ""),
            "iris.stack_version": "v2",
        }
    )
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    return provider


def _parse_attrs(pairs: list[str]) -> dict[str, str]:
    """Parse --attr key=value pairs into a dict; values are always strings."""
    out: dict[str, str] = {}
    for p in pairs or []:
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def emit(args: argparse.Namespace) -> int:
    provider = _build_provider()
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("iris.wrapper")

    span_name = f"{args.category}.{args.action}"
    with tracer.start_as_current_span(span_name) as span:
        span.set_attribute("category", args.category)
        span.set_attribute("action", args.action)
        if args.subject:
            span.set_attribute("subject", args.subject)
        if args.outcome:
            span.set_attribute("outcome", args.outcome)
        if args.cost_usd is not None:
            span.set_attribute("cost_usd", float(args.cost_usd))
        if args.trace_id:
            span.set_attribute("iris.parent_trace_id", args.trace_id)
        for k, v in _parse_attrs(args.attr).items():
            span.set_attribute(k, v)

        # Span status reflects the wrapper's own outcome — error spans are
        # easy to filter for in dashboards.
        if (args.outcome or "").lower() in ("error", "fail", "failed", "cancelled", "timeout"):
            span.set_status(Status(StatusCode.ERROR, args.outcome))

    # Force flush before exit; otherwise the gRPC batch processor may drop
    # the span when the short-lived Python process dies.
    provider.shutdown()
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="_otel_emit", description=__doc__)
    p.add_argument("--category", required=True,
                   help="event category — one of: package | cron | skill | mcp | reconcile | tool_call")
    p.add_argument("--action", required=True,
                   help="action verb — install | uninstall | add | remove | invoke | succeed | fail | propose")
    p.add_argument("--subject", default=None, help="name/id of what was acted on")
    p.add_argument("--outcome", default="ok",
                   help="ok | error | timeout | cancelled (default: ok)")
    p.add_argument("--trace-id", default=None,
                   help="parent trace id for cross-process correlation")
    p.add_argument("--cost-usd", default=None,
                   help="cost in USD for this action, if known")
    p.add_argument("--attr", action="append", default=[],
                   help="extra attribute key=value (repeatable)")
    args = p.parse_args()

    try:
        return emit(args)
    except Exception as e:  # noqa: BLE001
        # Never let telemetry kill the wrapper. Print to stderr and return 0
        # so the caller doesn't propagate a failure that wasn't its own.
        print(f"_otel_emit: WARNING — span emission failed: {e}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
