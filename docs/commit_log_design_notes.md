# The commit log (WAL): design notes

`Current.Consensus.Log` documents what the log guarantees and how it behaves.
This file records *why* it is built the way it is.

## Why segments, and not `:disk_log`'s `:wrap` or `:rotate`

`:disk_log` can bound a log's size itself, with the `:wrap` and `:rotate` types.
Neither is used, because both discard history.

- **`:wrap`** uses a fixed number of files and, when it cycles, reuses the
  oldest one. The oldest commits are overwritten.
- **`:rotate`** (newer OTP) keeps the latest `MaxNoFiles` compressed files, so
  the oldest data eventually goes. Every rotation also renames all the
  compressed files, so a file has no stable identity, and the older data is
  gzipped, so replaying it means decompressing each file first. (This is from
  the OTP docs, not from running it.)

The WAL is replayed from commit 1 on every start, and every commit's
`previous_hash` chains back to the first. Losing the oldest commits would make
startup fail validation. So the log is a series of ordinary `:halt` disk_logs,
one per segment, and nothing is ever dropped.

Both types could make sense once checkpoints exist and replay no longer begins
at commit 1. Losing the oldest segments would then be acceptable.

## Rollover and crashes

The reasoning about what a crash can leave on disk, and why the old segment is
closed before the new one is created, lives next to the code, in
`do_rollover/1` and `drop_empty_trailing_segment/1`. The tests build each of
those on-disk states and check recovery. They do not prove that a real crash
produces exactly those states.

## Single writer

Only one process may write to a given WAL path. The OTP docs for
`:disk_log.open/1` put this on the caller: with more than one writer the file
can be corrupted. The existence check before rollover protects against a
preexisting segment file, not against a concurrent writer, and is not atomic.

## `Commit.hash/1`

`Commit.hash/1` hashes `:erlang.term_to_binary(commit, [:deterministic])`. The
`:deterministic` option makes the encoding of a term stable within a given
Term format, but the OTP docs do not promise that the encoding stays
identical across releases. If a hash mismatch appears after an OTP upgrade,
check for this before treating it as corruption. Pinning the encoding further
(an explicit `minor_version`, or a separate versioned canonical encoding)
would change the hash of every commit already in an existing log, so it needs
a decision on how to handle old logs.

## First segment must be number 1

Startup replays everything, starting with commit 1, which is in segment 1. So
the first segment must be numbered 1 and none may be missing. When checkpoints
exist and replay can start partway through, this is the rule to relax.

