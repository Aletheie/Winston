# Kindle Transfer Recovery Verification

This matrix verifies Winston's schema-v2 transfer journal against real Kindle
mass-storage and MTP behavior. Automated tests cover the same state transitions
with deterministic fake transports and injected journal failures. The hardware
rows below have not been run in this workspace; they require representative
devices and must not be reported as passed until each result is recorded.

## Preconditions

- Use a disposable test book with a unique title and record its exact allocated
  destination name and byte count.
- Keep a copy of the active journal after every interruption.
- Check both the device file inventory and Winston's visible recovery state.
- Repeat each scenario once after reconnect and once after relaunch.

## Manual matrix

| Scenario | Mass storage | MTP | Required observation |
| --- | --- | --- | --- |
| Disconnect after `inFlight`, before bytes are written | Not run — hardware required | Not run — hardware required | Exact destination is absent; resume may send once. |
| Disconnect during a partial write | Not run — hardware required | Not run — hardware required | Wrong-size destination stays `deliveryUnknown`; Winston does not resend. |
| Disconnect after all bytes arrive, before transport returns | Not run — hardware required | Not run — hardware required | Exact name and byte count reconcile to `payloadCommitted`; Winston does not resend. |
| Quit after `payloadCommitted`, before cover work | Not run — hardware required | Not run — hardware required | Relaunch resumes cover/cleanup/receipt only. |
| Quit after cover work, before receipt checkpoint | Not run — hardware required | Not run — hardware required | Relaunch records the receipt without repeating transport or completed cover work. |
| Reconnect a different Kindle | Not run — hardware required | Not run — hardware required | Journal remains untouched and no bytes are sent. |
| Replace the source file before reconnect | Not run — hardware required | Not run — hardware required | Frozen-generation validation fails closed and no bytes are sent. |
| Repeat Resume after successful recovery | Not run — hardware required | Not run — hardware required | No duplicate book, cover, cleanup, or receipt operation occurs. |

## Transport evidence

Both current transports verify the destination path and transferred byte count
before reporting success. Reconnect reconciliation can compare the allocated
destination name and inventory byte count. The current device inventory APIs do
not provide a content hash, so a present destination with missing or mismatched
size evidence remains unresolved. Do not infer success from basename alone.
