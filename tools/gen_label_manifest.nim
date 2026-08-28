## Regenerates `tests/label_manifest.txt`, the sprite-label vocabulary
## contract, in the same commit as any label change:
##   nim r --path:src tools/gen_label_manifest.nim > tests/label_manifest.txt

import generals/labels

when isMainModule:
  stdout.write(labelManifestText())
