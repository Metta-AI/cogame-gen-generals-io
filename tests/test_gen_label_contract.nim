## Test 25 — the sprite-label vocabulary contract.
##
## The starter's `test_label_contract` pattern: the labels this game emits
## with its sprites are a CONTRACT (a forensic dump of a packet reads as
## them), so `tests/label_manifest.txt` is regenerated in the same commit as
## any label change.

import std/[unittest, algorithm, os, strutils]
import generals/labels
import generals/sim_types

proc repo(name: string): string =
  if fileExists(name): readFile(name) else: readFile("../" & name)

suite "the label contract":
  test "the emitted vocabulary equals tests/label_manifest.txt":
    check labelManifestText() == repo("tests/label_manifest.txt")

  test "every label is lower-case, hyphenated and non-empty":
    for label in labelVocabulary():
      check label.len > 0
      check label == label.toLowerAscii()
      check " " notin label
      check "_" notin label

  test "the vocabulary covers every drawable the board emits":
    let vocabulary = labelVocabulary()
    check LabelChrome in vocabulary
    for seat in 0 ..< Seats:
      check tintLabel(seat, 0) in vocabulary
      check tintLabel(seat, 4) in vocabulary
      check cityLabel(seat) in vocabulary
      check crownLabel(seat) in vocabulary
    check cityLabel(-1) in vocabulary
    for digit in 0 .. 9:
      check digitLabel(digit) in vocabulary
    var sorted = labelVocabulary()
    sorted.sort()
    check sorted.len == vocabulary.len
