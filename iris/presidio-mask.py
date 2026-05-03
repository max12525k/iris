#!/usr/bin/env python3
"""Presidio-backed PII masker for Hermes/Claude-Code hooks.

stdin:  {"text": "...", "mode": "mask" | "block-on-match"}
stdout: {"text": "...masked..."}    on success
exit:   0 = ok (masked or no PII found)
        1 = BLOCK entity matched and mode == "block-on-match"
        2 = Presidio unreachable / config error
"""
import json
import os
import sys
import requests

ANALYZER = os.environ.get("PRESIDIO_ANALYZER_API_BASE", "http://presidio-analyzer:3000")
ANONYMIZER = os.environ.get("PRESIDIO_ANONYMIZER_API_BASE", "http://presidio-anonymizer:3000")

BLOCK_ENTITIES = {"CREDIT_CARD", "US_SSN", "IBAN_CODE"}
MASK_ENTITIES = {"EMAIL_ADDRESS", "PHONE_NUMBER"}
ALL_ENTITIES = sorted(BLOCK_ENTITIES | MASK_ENTITIES)


def main() -> int:
    payload = json.load(sys.stdin)
    text = payload.get("text", "")
    mode = payload.get("mode", "mask")
    if not text:
        json.dump({"text": text}, sys.stdout)
        return 0

    try:
        spans = requests.post(
            f"{ANALYZER}/analyze",
            json={"text": text, "language": "en", "entities": ALL_ENTITIES},
            timeout=10,
        ).json()
    except Exception as e:
        sys.stderr.write(f"presidio-mask: analyzer unreachable: {e}\n")
        return 2

    if mode == "block-on-match":
        for s in spans:
            if s.get("entity_type") in BLOCK_ENTITIES:
                sys.stderr.write(
                    f"presidio-mask: BLOCK on {s['entity_type']} "
                    f"(start={s['start']}, end={s['end']})\n"
                )
                return 1

    try:
        result = requests.post(
            f"{ANONYMIZER}/anonymize",
            json={
                "text": text,
                "analyzer_results": spans,
                "anonymizers": {
                    e: {"type": "replace", "new_value": f"<{e}>"} for e in ALL_ENTITIES
                },
            },
            timeout=10,
        ).json()
    except Exception as e:
        sys.stderr.write(f"presidio-mask: anonymizer unreachable: {e}\n")
        return 2

    json.dump({"text": result.get("text", text)}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
