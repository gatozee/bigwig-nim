import argparse
import strutils
import strformat
import os
import ../bigwig

type region = tuple[chrom: string, start: int, stop: int]

proc parse_region(reg:string): region =
  if reg == "": return ("", 0, -1)
  let chrom_rest = reg.split(':', maxsplit=1)
  if chrom_rest.len == 1:
    return (chrom_rest[0], 0, -1)
  doAssert chrom_rest.len == 2, ("[bigwig] invalid region:" & reg)
  var ss = chrom_rest[1].split('-')
  result.chrom = chrom_rest[0]
  result.start = max(0, parseInt(ss[0]) - 1)
  result.stop = parseInt(ss[1])
  doAssert result.stop >= result.start, ("[bigwig] invalid region:" & reg)

proc from_fai(path: string): BigWigHeader =
  ## create a bigwig header from an fai (fasta index) or a genome file
  for l in path.lines:
    let vals = l.strip().split('\t')
    result.add((name: vals[0], length: parseInt(vals[1]), tid: result.len.uint32))

proc write_region_from(ofh:File, bw:var BigWig, reg:region) =
  for iv in bw.intervals(reg.chrom, reg.start, reg.stop):
    var v = format_float(iv.value, ffDecimal, precision=5)
    v = v.strip(leading=false, chars={'0'})
    if v[v.high] == '.': v &= '0'
    ofh.write_line(&"{reg.chrom}\t{iv.start}\t{iv.stop}\t{v}")

type chunk = seq[tuple[start: int, stop:int, value:float32]]

iterator chunks(bw: var BigWig, reg: region, n:int=2048): chunk =
  var cache = newSeqOfCap[tuple[start: int, stop:int, value:float32]](n)
  for iv in bw.intervals(reg.chrom, reg.start, reg.stop):
    cache.add(iv)
    if cache.len == n:
      yield cache
      cache = newSeqOfCap[tuple[start: int, stop:int, value:float32]](n)

  if cache.len != 0:
    yield cache

proc make_interval(toks: seq[string], col: int): tuple[start: int, stop: int, value: float32] =
  return (parseInt(toks[1]), parseInt(toks[2]), parseFloat(toks[col]).float32)

iterator chunks(bed_path: string, chrom: var string, n:int=2048, value_column: int= 4): chunk =
  let col = value_column - 1

  var cache = newSeqOfCap[tuple[start: int, stop:int, value:float32]](n)
  for l in bed_path.lines:
    let toks = l.strip.split('\t')
    if toks[0] != chrom and cache.len > 0:
      yield cache
      cache = newSeqOfCap[tuple[start: int, stop:int, value:float32]](n)

    chrom = toks[0]
    var iv = make_interval(toks, col)

    cache.add(iv)
    if cache.len == n:
      yield cache
      cache = newSeqOfCap[tuple[start: int, stop:int, value:float32]](n)

  if cache.len != 0:
    yield cache


proc looks_like_single_base(chunk: chunk): bool =
  var n = chunk.len.float32
  if chunk.len < 2: return false
  var nsmall = 0
  var nskip = 0
  var last_stop = chunk[0].start
  var total_bases = 0
  for c in chunk:
    nsmall += int(c.stop - c.start <  10)
    if last_stop > c.start: return false
    nskip += c.start - last_stop
    last_stop = c.stop
    total_bases += c.stop - c.start

  return nsmall.float32 / n > 0.85 and nskip == 0

proc looks_like_fixed_span(chunk: chunk): bool =
  if chunk.len < 2: return false
  var sp = chunk[0].stop - chunk[0].start
  result = true
  for i, c in chunk:
    if likely(i < chunk.high) and c.stop - c.start != sp: return false

proc write_fixed_span(ofh: var BigWig, chunk:chunk, chrom: string, span:int) =
  var values = newSeqOfCap[float32](4096)
  for c in chunk:
    for s in c.start..c.stop:
      values.add(c.value)
  ofh.add(chrom, chunk[0].start.uint32, values, span=span.uint32)

proc write_single_base(ofh: var BigWig, chunk:chunk, chrom: string) =
  ofh.write_fixed_span(chunk, chrom, 1)

proc write_region_from(ofh:var BigWig, bw:var BigWig, reg:region, chunksize:int = 2048) =
  ## read from bw and write to ofh. try to do this efficiently
  ## read a chunk of a particular size and guess what the best bigwig
  ## representation might be
  for chunk in bw.chunks(reg, chunksize):
    if chunk.looks_like_single_base:
      ofh.write_single_base(chunk, reg.chrom)
    elif chunk.looks_like_fixed_span:
      ofh.write_fixed_span(chunk, reg.chrom, chunk[0].stop - chunk[0].start)
    else:
      ofh.add(reg.chrom, chunk)

proc write_from(ofh:var BigWig, bed_path: string, value_column: int, chunksize:int = 2048) =
  ## read from bw and write to ofh. try to do this efficiently
  ## read a chunk of a particular size and guess what the best bigwig
  ## representation might be
  var chrom: string
  for chunk in bed_path.chunks(chrom, n=chunksize, value_column=value_column):
    if chunk.looks_like_single_base:
      ofh.write_single_base(chunk, chrom)
    elif chunk.looks_like_fixed_span:
      ofh.write_fixed_span(chunk, chrom, chunk[0].stop - chunk[0].start)
    else:
      ofh.add(chrom, chunk)

proc isBig(path: string): bool =
  return bwIsBigWig(path, nil) == 1 or bbIsBigBed(path, nil) == 1

proc view_main*() =

  var p = newParser("bigwig view"):
    option("-r", "--region", help="optional chromosome, or chrom:start-stop region to view")
    option("-f", "--fai", help="path to fai, only used for converting BED->BigWig")
    option("-i", "--value-column", help="column-number (1-based) of the value to encode in to BigWig, only used for encoding BED->BigWig", default="4")
    option("-O", "--output-fmt", choices= @["bed", "bigwig"], default="bed", help="output format")
    option("-o", "--output-file", default="/dev/stdout", help="output bed or bigwig file")
    arg("input", nargs=1)

  var args = commandLineParams()
  if len(args) == 0: args = @["--help"]
  if args[0] == "view":
    args = args[1..args.high]

  let opts = p.parse(args)
  if opts.help:
    quit 0
  if opts.input == "":
    # TODO: check for stdin
    echo p.help
    echo "[bigwig] input file is required"
    quit 2

  if opts.input.isBig:

    var bw:BigWig
    if not bw.open(opts.input):
      quit "[bigwig] couldn't open file:" & opts.input

    if opts.output_fmt == "bed":
      #####################
      ### BigWig To BED ###
      #####################
      var ofh: File
      if not ofh.open(opts.output_file, fmWrite):
        quit "[bigwig] couldn't open output file:" & opts.output_file

      if opts.region == "":
        for chrom in bw.header:
          var reg: region = (chrom.name, 0, chrom.length)
          ofh.write_region_from(bw, reg)

      else:
        var region = opts.region.parse_region
        ofh.write_region_from(bw, region)

      ofh.close

    elif opts.output_fmt == "bigwig":
      ########################
      ### BigWig To BigWig ###
      ########################
      var ofh: BigWig
      if  not ofh.open(opts.output_file, fmWrite):
        quit "[bigwig] couldn't open output bigwig file:" & opts.output_file
      ofh.setHeader(bw.header)
      ofh.writeHeader

      if opts.region == "":
        for chrom in bw.header:
          var reg: region = (chrom.name, 0, chrom.length)
          ofh.write_region_from(bw, reg)

      else:
        var region = opts.region.parse_region
        ofh.write_region_from(bw, region)

      ofh.close
    bw.close
  else:
    if opts.fai == "":
      quit "[bigwig] --fai is required when input is not bigwig."
    if opts.region != "":
      quit "[bigwig] --region is not supported for BED input"
    var h = opts.fai.from_fai
    var ofh: BigWig
    if  not ofh.open(opts.output_file, fmWrite):
      quit "[bigwig] couldn't open output bigwig file:" & opts.output_file
    ofh.setHeader(h)
    ofh.writeHeader
    ofh.write_from(opts.input, parseInt(opts.value_column))
    ofh.close


when isMainModule:
  view_main()