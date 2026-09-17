#!/usr/bin/env python3
"""Publish a real 440 Hz tone into the test room, so the browser has something to
subscribe to. Runs for SECS seconds. Dev credentials only."""
import asyncio, os, sys, wave, math, struct, io

from livekit import rtc

URL = os.environ.get("LK_URL", "ws://127.0.0.1:7880")
TOKEN = open(os.environ.get("LK_TOKEN_FILE", "/tmp/lkclient-page/token.txt")).read().strip()
SECS = float(os.environ.get("SECS", "35"))


def tone_chunk(frames: int, rate: int = 48000, freq: float = 440.0, amp: int = 9000) -> bytes:
    buf = bytearray()
    for i in range(frames):
        v = int(amp * math.sin(2 * math.pi * freq * (i / rate)))
        buf += struct.pack("<h", v)
    return bytes(buf)


async def main() -> int:
    room = rtc.Room()
    await room.connect(URL, TOKEN)
    print(f"publisher connected as {room.local_participant.identity}", flush=True)

    source = rtc.AudioSource(48000, 1)
    track = rtc.LocalAudioTrack.create_audio_track("py-tone", source)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )
    print("published py-tone", flush=True)

    chunk = tone_chunk(480)          # 10 ms of 48 kHz mono
    sent = 0
    for _ in range(int(SECS * 100)):
        frame = rtc.AudioFrame(data=chunk, sample_rate=48000, num_channels=1, samples_per_channel=480)
        await source.capture_frame(frame)
        sent += 1
        await asyncio.sleep(0.01)
    print(f"sent {sent} frames", flush=True)
    await room.disconnect()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
