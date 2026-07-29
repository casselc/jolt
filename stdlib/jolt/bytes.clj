(ns jolt.bytes
  "Checked binary scalar access over a byte-array.

  Every binary protocol reaches for the same three operations: read a
  fixed-width integer or float at an explicit offset, write one back, and move a
  range of bytes. This namespace provides them directly over the byte-array's
  storage — no buffer object, no cursor allocated per read, no shift/or chain
  written by hand in each codec.

      (require '[jolt.bytes :as b])
      (let [a (byte-array 8)]
        (b/put-u32-be! a 0 305419896)
        (b/get-u32-be! a 0))            ;=> 305419896  (in bytes: 12 34 56 78)

  All state is the caller's: a byte-array, an offset, and a value. Reads take
  `[array offset]`, writes take `[array offset value]` and return the array so
  they thread, and `copy!` takes `[src src-offset dst dst-offset size]` and
  returns the destination.

  ## Bounds

  Admission is subtraction-form. After establishing `0 <= offset <= limit`, a
  span of `size` is admitted only when `size <= limit - offset`, where `limit`
  is the array length. The familiar additive test `offset + size > limit` agrees
  with this one only while the sum cannot overflow; the subtraction form needs no
  such side condition, and it is the form the substrate's bounds proofs are
  stated in.

  Argument validation precedes range admission, and range admission precedes
  mutation. A rejected write or copy leaves the destination byte-for-byte
  unchanged — including a copy whose source range is valid and whose destination
  range is not.

  ## Values

  A value is never silently narrowed or reinterpreted. Each accessor states a
  width and a signedness, and a value outside that domain is an error rather
  than a truncation:

      (b/put-u16-le! a 0 70000)   ;=> IllegalArgumentException
      (b/put-u32-le! a 0 -1)      ;=> IllegalArgumentException
      (b/put-f64-le! a 0 1)       ;=> IllegalArgumentException (1 is not a float)

  The unsigned readers return the full unsigned value, so `get-u64-le` can return
  a number larger than a signed 64-bit maximum. The signed readers return the
  two's-complement interpretation of the same bytes. Both are available at every
  width above 8 bits so a codec states which one it means.

  Offsets and sizes must be exact integers. A float offset is rejected rather
  than truncated.

  ## Floats

  `get-f64-le` and friends read and write IEEE-754 values in place. The raw-bit
  conversions move between a float and its bit pattern as an unsigned integer:

      (b/f64-bits -0.0)    ;=> 9223372036854775808   (0x8000000000000000)
      (b/bits->f64 0x7FF8000000000001)               ; a NaN with a payload

  These are bit-exact and are deliberately not defined through numeric equality:
  `0.0` and `-0.0` are numerically equal with different bit patterns, and a NaN
  is equal to nothing at all.

  f64 is a bijection with the unsigned 64-bit domain — every pattern survives a
  round trip in either direction, NaN payloads and the signalling bit included.

  f32 is not, and this is a host representation fact rather than a policy
  choice. `bits->f32` must widen to the host float type to return a value at
  all, and re-narrowing quiets a signalling NaN: `0x7F800001` comes back as
  `0x7FC00001`. Every non-NaN pattern and every quiet-NaN payload round-trips.
  Code that must preserve an arbitrary f32 pattern verbatim carries it as u32
  and never widens it.

  ## Copying

  `copy!` has memmove semantics. Source and destination may be the same array
  with overlapping ranges in either direction, and the result is as if the
  source range had been copied to a temporary first.

  ## Exceptions

  The taxonomy is part of the contract:

  | Condition                                                    | Thrown |
  | ---                                                          | --- |
  | offset or size negative, or the span exceeds the array        | `IndexOutOfBoundsException` |
  | not a byte-array, non-integer offset, value outside the width | `IllegalArgumentException` |
  | host float representation is not IEEE-754 binary64            | `UnsupportedOperationException` |

  The last is a fail-closed gate on the raw-bit and float operations: a host that
  cannot honour the IEEE-754 claim raises rather than returning plausible wrong
  bits.

  ## Surface

  Bounds:
    `in-range?` `check-range!`

  Integers, for each of u8/i8 (no endianness) and
  u16/i16/u32/i32/u64/i64 x le/be:
    `get-u8` `get-i8` `put-u8!` `put-i8!`
    `get-u16-le` `get-u16-be` `get-i16-le` `get-i16-be`
    `put-u16-le!` `put-u16-be!` `put-i16-le!` `put-i16-be!`
    `get-u32-le` `get-u32-be` `get-i32-le` `get-i32-be`
    `put-u32-le!` `put-u32-be!` `put-i32-le!` `put-i32-be!`
    `get-u64-le` `get-u64-be` `get-i64-le` `get-i64-be`
    `put-u64-le!` `put-u64-be!` `put-i64-le!` `put-i64-be!`

  Floats:
    `get-f32-le` `get-f32-be` `get-f64-le` `get-f64-be`
    `put-f32-le!` `put-f32-be!` `put-f64-le!` `put-f64-be!`
    `f32-bits` `bits->f32` `f64-bits` `bits->f64`

  Copy:
    `copy!`

  The functions themselves are host primitives (host/chez/bytes.ss), bound into
  this namespace at runtime startup; this file carries the contract they
  implement.")
