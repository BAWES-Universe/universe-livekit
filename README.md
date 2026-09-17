# Deployment for a self-hosted LiveKit node that owns its host's network stack.

This repository holds the two files that define a LiveKit deployment using **host
networking**, plus the reverse-proxy route that keeps the client-facing domain
working when the container has no Docker bridge address.

It exists because a container on a Docker bridge with nothing published cannot
serve WebRTC media reliably: connections end up depending on NAT traversal
succeeding, with no fallback. Media either connects or it doesn't, per call.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.yaml` | The deployment: LiveKit with `network_mode: host`, config mounted read-only. |
| `livekit.yaml` | LiveKit server configuration. **The source of truth for every setting LiveKit does not accept via environment variables.** |
| `traefik/livekit-dynamic.yaml` | Traefik file-provider route, for proxies that terminate TLS in front of the node. |

## Why host networking

WebRTC media needs a range of UDP ports to be directly reachable. The usual
alternative on Docker is publishing that range, but Docker creates **one helper
process per published port** - a 10,000-port range means ~10,000 processes and a
container that takes many minutes to start or stop. Docker's own docs and
LiveKit's deployment guide both point at host networking instead, which removes
port publishing, NAT and per-port proxying entirely. It also costs nothing: this
box runs only LiveKit.

## Why the settings live in `livekit.yaml`, not in environment variables

LiveKit does not recognise per-field `rtc.*` environment variables. A variable
like `LIVEKIT_RTC_UDP_PORT` is accepted silently and ignored, leaving the server
on its defaults - which is a genuinely confusing failure mode to debug. Anything
under `rtc:`, plus `port`, `log_level` and `redis.address`, belongs in the config
file. The two things LiveKit *does* honour from the environment are the API keys
(`LIVEKIT_KEYS`) and the Redis password (`LIVEKIT_REDIS_PASSWORD`); both are
injected by the platform and never committed.

## Ports

| Port | Protocol | Exposure | Notes |
| --- | --- | --- | --- |
| 7880 | TCP | internal only | HTTP/WebSocket signalling. Put it behind a TLS terminator; browsers reach it on 443. |
| 7881 | TCP | **public** | ICE over TCP, for clients that cannot use UDP. Cannot sit behind a TLS terminator. |
| 50000-60000 | UDP | **public** | Media. Both ends of the range must be reachable. |

Only 7881 and the UDP range need opening in a firewall. If a cloud firewall sits
in front of the host, those two rules are the whole list.

## Deploying

1. Create a resource from this repository.
   - Platform: Coolify (or any Docker host).
   - Build pack: **Docker Compose**.
   - Enable **Raw Compose Deployment** - this deployment supplies its own
     networking, and the normal path would try to manage it.
   - Enable **Preserve Repository During Deployment**, otherwise the bind-mounted
     `livekit.yaml` is not available when the container starts.
   - Leave the Domains field empty when using the file-provider route; routing is
     owned by `traefik/livekit-dynamic.yaml`.
2. Set two environment variables on the resource:
   - `LIVEKIT_KEYS` — `"<api-key>: <api-secret>"`
   - `LIVEKIT_REDIS_PASSWORD`
3. Supply Redis. The config expects it on `127.0.0.1:6379`. Setting Redis is what
   makes LiveKit distributed - clients may connect to any node and are routed to
   the node hosting their room.
4. Install the proxy route: copy `traefik/livekit-dynamic.yaml` into the proxy's
   dynamic configuration directory and replace `<your-domain>`.
5. Open 7881/tcp and 50000-60000/udp on any firewall in front of the host.

## Verifying a deployment

Do not trust a green container - verify the media path end to end:

- The server's own startup log must show the HTTP port, the TCP port and the ICE
  range you configured, plus a Redis connection.
- A token minted with the configured API key must validate:
  `https://<your-domain>/rtc/validate?access_token=<jwt>` returns `success`.
- A real client must connect and exchange media. Status codes are not proof:
  signalling can be healthy while no media ever flows.

## Scaling out

A node is this repository plus a Redis address. To add capacity:

1. Deploy a second node with the same API keys, pointed at the same Redis.
2. Put the same hostname in front of both nodes for signalling.
3. Each node keeps its own public IP for media.

No client-side change is needed: clients keep using one URL and the same keys.

## Security

- Never commit credentials. API keys and the Redis password come from the
  platform's environment. Redis should not be exposed publicly.
- The proxy route file contains no secrets, only a hostname and the bridge
  gateway address.
- CI validates the compose file and the config, and fails on anything that looks
  like a committed secret.

## Licence

MIT — see `LICENSE`.
