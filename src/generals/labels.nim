## The sprite-label vocabulary contract.
##
## Every sprite this game defines carries a label from THIS list, and
## `tests/label_manifest.txt` is regenerated in the same commit as any label
## change (the starter's `test_label_contract` pattern). The labels are what
## a forensic dump of a packet reads as, so they are a contract, not a
## comment.

import std/[algorithm, strutils]
import sim_types

const
  LabelBoardBand* = "board-band"
  LabelTint* = "tint"
  LabelCityNeutral* = "city-neutral"
  LabelCityOwned* = "city-owned"
  LabelCrown* = "crown"
  LabelDigit* = "digit"
  LabelChrome* = "chrome"

proc tintLabel*(seat, level: int): string =
  LabelTint & "-" & teamText(teamOfSeat(seat)) & "-" & $level

proc cityLabel*(seat: int): string =
  if seat < 0: LabelCityNeutral
  else: LabelCityOwned & "-" & teamText(teamOfSeat(seat))

proc crownLabel*(seat: int): string =
  LabelCrown & "-" & teamText(teamOfSeat(seat))

proc digitLabel*(digit: int): string =
  LabelDigit & "-" & $digit

proc bandLabel*(band: int): string =
  LabelBoardBand & "-" & $band

proc labelVocabulary*(): seq[string] =
  ## The complete emitted vocabulary, sorted, one per line in the manifest.
  result.add(LabelChrome)
  for band in 0 ..< 4:
    result.add(bandLabel(band))
  for seat in 0 ..< Seats:
    for level in 0 ..< 5:
      result.add(tintLabel(seat, level))
    result.add(cityLabel(seat))
    result.add(crownLabel(seat))
  result.add(LabelCityNeutral)
  for digit in 0 .. 9:
    result.add(digitLabel(digit))

proc labelManifestText*(): string =
  var lines = labelVocabulary()
  lines.sort()
  lines.join("\n") & "\n"
