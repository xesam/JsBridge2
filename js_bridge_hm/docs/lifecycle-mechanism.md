# Harmony Lifecycle Mechanism

## Scope

The bridge only provides a mechanism for the host to send lifecycle events to the web side through `runtime.state`.

It does not define:

- a cross-platform fixed lifecycle enum
- when a host must send lifecycle events
- what exact payload fields a host must include

## Rule

Lifecycle event timing and payload content are host-defined behavior.

The only bridge-level responsibility is:

- provide an event channel
- preserve normal bridge session and event delivery semantics

## Practical Meaning

For Harmony example code, lifecycle values such as `created`, `foreground`, `background`, and `ready` are demo choices, not protocol-mandated constants.

The same applies to Android, iOS, Flutter, and future Harmony business apps:

- the host decides when to publish lifecycle
- the host decides what state names to use
- the caller or business layer consumes those values according to its own contract
