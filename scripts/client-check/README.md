# Client compatibility check

Answers one question before adopting a new LiveKit server version: **does the
browser client the game ships still work against it?**

`./scripts/verify.sh` proves the server side of that (tokens, room APIs). This
harness proves the client side, because a token check cannot show that media
flows: the client must connect, publish and actually receive bytes.

## Running it

The harness needs a throwaway server and two identities in one room.

```bash
# 1. throwaway server, reachable from the browser on 127.0.0.1
docker run -d --name lk-check \
  -p 7880:7880 -p 7881:7881 -p 50000-50010:50000-50010/udp \
  -e LIVEKIT_KEYS="devkey: devsecret_devsecret_devsecret_devsecret" \
  livekit/livekit-server:$(grep -oP 'livekit-server:\K.*' docker-compose.yaml)

# 2. mint two tokens with the SDK the game's back-end uses (see publish-tone.py
#    for the identity split: reusing one identity makes the clients evict
#    each other from the room)

# 3. serve page.html on 127.0.0.1, alongside a token.txt, then open it
# 4. run publish-tone.py as a second participant and read the page's result
```

The page reports `MEDIA_RECEIVED` with a byte count only when real media
arrived. Note that a headless browser has no user gesture, so its *own* audio
context stays suspended: the publish path is exercised, but the audio the
browser sends is silent. Confirm audible media with a real browser and a real
microphone.

Requirements: Docker, a browser, and `pip install livekit` (or `livekit-agents`)
for the publishing participant.
