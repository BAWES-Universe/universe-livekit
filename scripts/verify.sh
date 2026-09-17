#!/usr/bin/env bash
# Verifies this deployment definition before it is trusted:  ./scripts/verify.sh
#
# Static checks always run. The runtime checks need a Docker daemon and are
# skipped with a reason when there isn't one. They earn their place because file
# inspection cannot prove either artifact: a route file can be valid YAML and
# still be rejected by Traefik, and a server config can look correct and still be
# ignored by the binary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
has_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
pass=0 fail=0

echo "== definition"
# The python block prints the checks, then a tagged count line for bash to total.
out=$(python3 <<'PY'
import glob, yaml
p = f = 0
def chk(cond, good):
    global p, f
    if cond: p += 1; print(f"  \033[32mPASS\033[0m  {good}")
    else:    f += 1; print(f"  \033[31mFAIL\033[0m  {good}")

s = yaml.safe_load(open("docker-compose.yaml"))["services"]["livekit"]
env = s.get("environment", {})
chk(s.get("network_mode") == "host",  "container owns the host network, no bridge")
chk("ports" not in s,                 "no published ports (meaningless in host mode)")
chk(all("${" in v and ":?" in v for v in env.values()),
                                      "credentials are required references, never literals")
# Coolify's Compose parser takes the text after `:?` as the variable's VALUE, so a
# friendly inline message becomes the credential and crash-loops the server.
chk(all(v.strip().endswith(":?}") for v in env.values()),
                                      "required references carry no inline message")
chk(any(":ro" in str(v) for v in s.get("volumes", [])), "server config mounted read-only")
# A floating tag turns every recreation into an unplanned upgrade, so the pin is
# a property worth testing rather than a convention.
img = s.get("image", "")
chk(":" in img and not img.endswith(":latest"), f"image pinned to an exact release ({img})")

c = yaml.safe_load(open("livekit.yaml")); r = c["rtc"]
chk(r["port_range_start"] < r["port_range_end"],
                                      f"media range ordered ({r['port_range_start']}-{r['port_range_end']})")
chk(r["use_external_ip"] is True,     "external IP discovery on (needed behind NAT/cloud)")
chk(c.get("port") == 7880 and r.get("tcp_port") == 7881, "http 7880, TCP fallback 7881")
chk("keys" not in c and "password" not in c.get("redis", {}), "no credentials in the config file")

# The relay is optional; when it is on, its advertised name and its forwarding
# range are the two things that must not be left implicit.
turn = c.get("turn") or {}
if turn.get("enabled"):
    chk(bool(turn.get("domain")), "turn: the relay advertises a resolvable domain")
    lo, hi = turn.get("relay_range_start", 0), turn.get("relay_range_end", 0)
    chk(0 < lo < hi and (hi - lo) < 1000, f"turn: relay forwarding range bounded ({lo}-{hi})")

for path in glob.glob("traefik/*.yaml"):
    text = open(path).read()
    route = yaml.safe_load(text)
    # Traefik renders these as Go templates: a double brace becomes a function
    # call and the whole file fails to load, taking the route down with it.
    chk("{{" not in text,                 f"{path}: free of template syntax")
    chk(any(x.get("tls", {}).get("certResolver") for x in route["http"]["routers"].values()),
                                          f"{path}: terminates TLS with a certificate resolver")
print(f"__COUNTS__ {p} {f}")
PY
)
grep -v '^__COUNTS__' <<<"$out"
read -r p f <<<"$(sed -n 's/^__COUNTS__ //p' <<<"$out")"
pass=$((pass+p)); fail=$((fail+f))

echo "== secrets"
if grep -rInE '(LIVEKIT_KEYS|API_SECRET|API_KEY|REDIS_PASSWORD)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=_-]{12,}' \
     --exclude-dir=.git . 2>/dev/null | grep -v '\${'; then
  bad "a credential-looking value is committed"
else
  ok "no committed credentials"; pass=$((pass+1))
fi

echo "== compose parser"
if has_docker; then
  LIVEKIT_KEYS="ci:ci" LIVEKIT_REDIS_PASSWORD="ci" docker compose -f docker-compose.yaml config -q 2>/dev/null \
    && { ok "docker accepts the definition"; pass=$((pass+1)); } || { bad "docker rejects the definition"; fail=$((fail+1)); }
  LIVEKIT_KEYS="" LIVEKIT_REDIS_PASSWORD="" docker compose -f docker-compose.yaml config -q 2>/dev/null \
    && { bad "empty credentials pass validation"; fail=$((fail+1)); } || { ok "empty credentials are refused"; pass=$((pass+1)); }
else
  skip "no docker daemon: compose parsing is covered by CI"
fi

echo "== runtime: route file against real Traefik"
if has_docker; then
  d=$(mktemp -d /tmp/hermes-verify-route.XXXXXX)
  sed 's/<your-domain>/livekit.localhost/' traefik/*.yaml > "$d/route.yaml"
  # No ACME resolver is configured here on purpose: this test proves the file
  # provider accepts the file and that the routers load, not that a certificate
  # can be issued. Traefik exposes its loaded configuration over the API, which
  # is a stronger assertion than grepping logs.
  cid=$(docker run -d --rm -v "$d":/etc/traefik/dynamic:ro -p 18082:8080 traefik:v3.7.13 \
    --providers.file.directory=/etc/traefik/dynamic \
    --entrypoints.http.address=:8081 --entrypoints.https.address=:8444 \
    --api.insecure=true 2>/dev/null)
  sleep 6
  routers=$(curl -s -m 10 http://127.0.0.1:18082/api/http/routers 2>/dev/null)
  logs=$(docker logs "$cid" 2>&1 | head -30)
  docker stop "$cid" >/dev/null 2>&1
  if grep -q 'Cannot start the provider\|not defined' <<<"$logs"; then
    bad "traefik rejects the route file"
    grep -i 'Cannot start the provider\|not defined' <<<"$logs" | head -2 | sed 's/^/        /'
    fail=$((fail+1))
  elif grep -q 'livekit-https@file' <<<"$routers" && grep -q 'livekit-http@file' <<<"$routers"; then
    ok "traefik loaded both routers from the route file"
    pass=$((pass+1))
  else
    bad "the route file loaded but the routers are missing"
    { sed 's/^/        routers: /' <<<"$routers" | head -2; sed 's/^/        log: /' <<<"$logs" | tail -3; }
    fail=$((fail+1))
  fi
  rm -rf "$d"
else
  skip "no docker daemon: route load unverified"
fi

echo "== runtime: config file against real LiveKit"
if has_docker; then
  d=$(mktemp -d /tmp/hermes-verify-livekit.XXXXXX)
  # Test the image this deployment actually pins, not a floating tag: verifying
  # a different build than the one that ships would be worse than not verifying.
  img=$(python3 -c "import yaml; print(yaml.safe_load(open('docker-compose.yaml'))['services']['livekit']['image'])")
  # Redis points at localhost in production; strip it so this isolated run gets
  # as far as reporting its ports.
  python3 - "$d/livekit.yaml" <<'PY'
import re, sys
open(sys.argv[1], "w").write(re.sub(r"\nredis:\n(?:  .*\n)+", "\n", open("livekit.yaml").read()))
PY
  log=$(timeout 120 docker run --rm -v "$d/livekit.yaml":/etc/livekit.yaml:ro \
    -e LIVEKIT_KEYS="dummykey: dummysecretdummysecretdummysecret" \
    "$img" --config /etc/livekit.yaml 2>&1 | head -20)
  line=$(grep -m1 'starting LiveKit server' <<<"$log")
  if [ -z "$line" ]; then
    bad "the binary did not start with this config"; tail -3 <<<"$log" | sed 's/^/        /'; fail=$((fail+1))
  elif grep -q "50000, 60000" <<<"$line"; then
    ok "$(sed 's/.*"version": "\([^"]*\)".*/v\1 applied the configured media range/' <<<"$line")"; pass=$((pass+1))
  else
    bad "the binary ignored the configured range: $(sed 's/.*portICERange/portICERange/' <<<"$line")"; fail=$((fail+1))
  fi
  rm -rf "$d"
else
  skip "no docker daemon: config application unverified"
fi

echo
printf '== %d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
