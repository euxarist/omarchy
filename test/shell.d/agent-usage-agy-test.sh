#!/bin/bash

# Antigravity collector fallback to retrieveUserQuota when
# retrieveUserQuotaSummary omits the Gemini group (as Google AI Ultra does).

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"

agent_sandbox

python3 - <<'PY'
from agent_usage_fixtures import *
import re

TIER = "v1internal:loadCodeAssist"
SUMMARY = "v1internal:retrieveUserQuotaSummary"
QUOTA = "v1internal:retrieveUserQuota"
ME = jwt({"email": "me@example.com"})
REAL_PATH = os.environ["PATH"]


def machine():
  sandbox()
  stub = home() / "bin" / "secret-tool"
  stub.parent.mkdir(parents=True, exist_ok=True)
  stub.write_text('#!/bin/bash\ncat "$HOME/keyring.json" 2>/dev/null\n')
  stub.chmod(0o755)
  os.environ["PATH"] = f"{stub.parent}:{REAL_PATH}"
  os.environ["AGY_DIR"] = str(home() / "agy")
  write_json(home() / "keyring.json", {
    "auth_method": "consumer",
    "id_token": ME,
    "token": {"access_token": "token-main", "refresh_token": "refresh-main", "expiry": iso_in(3600)},
  })


def agy(routes):
  with FakeHttp(routes) as http:
    return collect("agy", "--force"), http


# Ultra summary has only Claude/GPT; fallback reads Gemini's 5-hour bucket from
# retrieveUserQuota and ignores Claude/GPT and tab_* entries.
machine()
reset_early = iso_in(2 * 3600)
reset_late = iso_in(4 * 3600)
record, http = agy({
  TIER: {"paidTier": {"id": "g1-ultra-tier", "name": "Google AI Ultra"}, "cloudaicompanionProject": "aicode-consumers"},
  SUMMARY: {"groups": [{"displayName": "Claude and GPT models", "buckets": [
    {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1.0},
    {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.9},
  ]}]},
  QUOTA: {"buckets": [
    {"modelId": "claude-opus-5-5-high", "remainingFraction": 0.2, "resetTime": reset_early},
    {"modelId": "tab_flash_lite_preview", "remainingFraction": 0.1, "resetTime": reset_early},
    {"modelId": "gemini-2.5-flash", "remainingFraction": 0.93, "resetTime": reset_late},
    {"modelId": "gemini-4-hydrogen-sonar", "remainingFraction": 0.85, "resetTime": reset_early},
    {"modelId": "models/gemini-2.5-pro", "remainingFraction": 0.85, "resetTime": reset_late},
  ]},
})
expect("Ultra falls back to retrieveUserQuota for Gemini and puts Session ahead of scoped 3P limits",
       [(w["title"], round(w["percent"], 2), w["resetsAt"]) for w in record["limits"]],
       [("Session", 0.15, reset_early), ("Claude/GPT Weekly", 0.1, "")], record)
expect("fallback sends the project from loadCodeAssist",
       [json.loads(r["data"]) for r in http.requests if r["url"].endswith(QUOTA)],
       [{"project": "aicode-consumers"}], http.requests)

# A transient 500 on retrieveUserQuota preserves the cached Gemini limit as
# stale rather than overwriting it with empty limits.
record, _ = agy({
  TIER: {"paidTier": {"id": "g1-ultra-tier", "name": "Google AI Ultra"}},
  SUMMARY: {"groups": [{"displayName": "Claude and GPT models", "buckets": [{"window": "5h", "remainingFraction": 1.0}]}]},
  QUOTA: 500,
})
expect("transient 500 on retrieveUserQuota keeps cached limits stale",
       (record["limitsStale"], [round(w["percent"], 2) for w in record["limits"]]),
       (True, [0.15, 0.1]), record)

# An untouched Gemini bucket (0% used) drops Google's rolling now+5h reset.
machine()
record, _ = agy({
  TIER: {"paidTier": {"id": "g1-ultra-tier", "name": "Google AI Ultra"}},
  SUMMARY: {"groups": [{"displayName": "Claude and GPT models", "buckets": [{"window": "5h", "remainingFraction": 1.0}]}]},
  QUOTA: {"buckets": [{"modelId": "gemini-3-flash", "remainingFraction": 1.0, "resetTime": iso_in(5 * 3600)}]},
})
expect("untouched Gemini fallback bucket omits synthetic reset time",
       [(w["title"], w["percent"], w["resetsAt"]) for w in record["limits"]],
       [("Session", 0.0, "")], record)

# When retrieveUserQuotaSummary already carries a Gemini group, retrieveUserQuota
# is never called.
machine()
record, http = agy({
  TIER: {"paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"}},
  SUMMARY: {"groups": [{"displayName": "Gemini Models", "buckets": [{"window": "5h", "remainingFraction": 0.75, "resetTime": reset_early}]}]},
})
expect("summary with Gemini group does not call retrieveUserQuota",
       ([w["percent"] for w in record["limits"]], [r["url"] for r in http.requests if r["url"].endswith(QUOTA)]),
       ([0.25], []), record)

# A 404 on retrieveUserQuota degrades cleanly to the summary's limits instead of
# failing the whole check.
machine()
record, _ = agy({
  TIER: {"paidTier": {"id": "g1-ultra-tier", "name": "Google AI Ultra"}},
  SUMMARY: {"groups": [{"displayName": "Claude and GPT models", "buckets": [{"window": "5h", "remainingFraction": 1.0}]}]},
  QUOTA: 404,
})
expect("404 on retrieveUserQuota degrades cleanly to summary limits",
       [record["tierLabel"], record["limits"], record["usageStatusText"]],
       ["Ultra", [], ""], record)
# On Pro, Gemini, Gemini 4 Argon, and Claude/GPT each carry their own weekly
# allowance; each is titled by its family so it gets its own meter row and reset
# clock, Argon ahead of Claude/GPT. Gemini's weekly bucket is the plan's own, so
# retrieveUserQuota is never called.
machine()
record, http = agy({
  TIER: {"paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"}},
  SUMMARY: {"groups": [
    {"displayName": "Claude and GPT models", "buckets": [{"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.75}]},
    {"displayName": "Gemini 4 Argon", "buckets": [{"bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 0.1}]},
    {"displayName": "Gemini Models", "buckets": [{"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.5}]},
  ]},
})
expect("peer weekly allowances each get a family-titled row",
       [(w["title"], round(w["percent"], 2)) for w in record["limits"]],
       [("Gemini Weekly", 0.5), ("Argon Weekly", 0.9), ("Claude/GPT Weekly", 0.25)], record)
expect("a Gemini Weekly row keeps retrieveUserQuota uncalled",
       [r["url"] for r in http.requests if r["url"].endswith(QUOTA)], [], http.requests)
expect("requests carry Antigravity's CLI User-Agent",
       all(re.fullmatch(r"antigravity/cli/\S+ \(aidev_client\)", r["headers"].get("user-agent") or "") for r in http.requests), True,
       [r["headers"] for r in http.requests])
expect("loadCodeAssist names the ANTIGRAVITY ideType",
       [json.loads(r["data"] or b"{}") for r in http.requests if r["url"].endswith(TIER)],
       [{"metadata": {"ideType": "ANTIGRAVITY"}}], http.requests)
# The User-Agent version comes from the installed agy (or AGY_CLI_VERSION).
machine()
old_env = os.environ.get("AGY_CLI_VERSION")
try:
  os.environ["AGY_CLI_VERSION"] = "2.26.0"
  _, http = agy({TIER: {"paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"}}, SUMMARY: {"groups": []}})
  expect("User-Agent version derives from the installed agy",
         {r["headers"].get("user-agent") for r in http.requests}, {"antigravity/cli/2.26.0 (aidev_client)"}, http.requests)
finally:
  if old_env is None:
    os.environ.pop("AGY_CLI_VERSION", None)
  else:
    os.environ["AGY_CLI_VERSION"] = old_env
PY
