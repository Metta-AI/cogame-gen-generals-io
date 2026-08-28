## Prints `wire_constants.js` on stdout. `Dockerfile.replay-viewer` pipes it
## into the bundle and asserts both emitted lines.

import generals/wire_constants

when isMainModule:
  stdout.write(wireConstantsJs())
