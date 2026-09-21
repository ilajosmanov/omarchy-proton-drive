"""Wait for Secret Service metadata, without reading secrets or prompting."""
import asyncio
import os
import sys

from dbus_next import Message, MessageType
from dbus_next.aio import MessageBus
from dbus_next.errors import DBusError

SERVICE = "org.freedesktop.secrets"


async def ready(bus):
    reply = await bus.call(Message(
        destination=SERVICE, path="/org/freedesktop/secrets",
        interface="org.freedesktop.Secret.Service", member="ReadAlias",
        signature="s", body=["default"],
    ))
    if reply.message_type != MessageType.METHOD_RETURN or reply.signature != "o":
        return False
    collection = reply.body[0]
    # A fresh account may have no collection yet. Let interactive CLI login
    # create one; waiting here would prevent first-time setup.
    if collection == "/":
        return True
    reply = await bus.call(Message(
        destination=SERVICE, path=collection,
        interface="org.freedesktop.DBus.Properties", member="Get",
        signature="ss", body=["org.freedesktop.Secret.Collection", "Locked"],
    ))
    return (reply.message_type == MessageType.METHOD_RETURN
            and reply.signature == "v" and reply.body[0].signature == "b"
            and reply.body[0].value is False)


async def wait_ready(timeout=30.0, interval=0.5, attempt_timeout=2.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        bus = None
        try:
            async def attempt():
                nonlocal bus
                bus = await MessageBus().connect()
                return await ready(bus)
            if await asyncio.wait_for(attempt(), min(attempt_timeout, deadline - loop.time())):
                return True
        except (OSError, EOFError, DBusError, asyncio.TimeoutError):
            pass
        finally:
            if bus is not None:
                bus.disconnect()
        await asyncio.sleep(max(0, min(interval, deadline - loop.time())))
    return False


def main():
    if os.environ.get("OMARCHY_DRIVE_PROVIDER") != "proton-cli":
        return 0
    if asyncio.run(wait_ready()):
        return 0
    print("Secret Service is unavailable or locked; retrying daemon startup.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
