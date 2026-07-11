<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor privacy policy

Effective July 11, 2026.

Hearth Monitor does not collect, sell, share, or transmit personal data to the
developer. It contains no analytics, advertising, tracking, telemetry, crash-
reporting service, account system, or third-party SDK.

## Data that stays on your Mac

- Runner addresses, monitoring preferences, and incident history are stored in
  Hearth Monitor's private App Sandbox container.
- An optional status-only credential for a separately installed full Hearth is
  stored in your macOS Keychain. It is deleted when you disconnect full Hearth
  or remove that watched runner.
- Outage and recovery notifications are created locally through macOS.

You can delete this local data by removing watched runners in Settings, clearing
History, or quitting Hearth Monitor and deleting its
`~/Library/Containers/com.hearth.HearthMonitor` container.

## Network connections you choose

Hearth Monitor connects directly from your Mac to AI-runner and optional full
Hearth addresses that you configure. It sends runner-specific health, model-list,
and optional one-token inference requests. When you connect full Hearth, it sends
the saved bearer credential only in an authenticated `GET /status` request to the
exact configured address. These requests are not relayed through or visible to
the developer.

As with any direct network connection, the server you choose can observe the
request and your network address. Use HTTPS for untrusted networks. Hearth
Monitor refuses redirects and does not include prompts, model responses, response
bodies, or credentials in copied diagnostics or incident history.

## Full Hearth

Full Hearth is a separate product. If you configure full Hearth to use third-
party notification or webhook services, those choices are governed by that
service and are outside Hearth Monitor. The optional Monitor connection is
read-only and never sends start, stop, or restart commands.

## Contact and changes

Questions or privacy concerns can be filed through the
[Hearth support tracker](https://github.com/adamskijow/Hearth/issues). Material
changes to this policy will be published in the repository and reflected in the
policy's effective date.
