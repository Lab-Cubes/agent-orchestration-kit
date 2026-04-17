import { CodecError } from "./errors.js";
import {
  type Flags,
  decodeFlags,
  encodeFlags,
} from "./flags.js";

/**
 * Fixed header (4 bytes, default) per NPS-1 §3.1:
 *
 *   Byte 0       Byte 1     Byte 2-3
 *   ┌────────┬────────┬──────────────────────┐
 *   │ Type   │ Flags  │ Payload Length (BE)  │
 *   │ 1 byte │ 1 byte │ 2 bytes (uint16 BE)  │
 *   └────────┴────────┴──────────────────────┘
 *
 * Extended header (EXT=1) widens the length field to 4 bytes and adds 2 reserved
 * bytes. v0.1.0 reads the 4-byte fixed form only; EXT=1 frames surface as
 * NCP-FRAME-FLAGS-INVALID (deferred to v0.2.0 per the design-of-record).
 */

export const FIXED_HEADER_BYTES = 4;
export const MAX_FIXED_PAYLOAD = 0xffff; // 65,535 bytes

export interface FrameHeader {
  readonly type: number;
  readonly flags: Flags;
  readonly payloadLength: number;
}

export function encodeFixedHeader(header: FrameHeader): Uint8Array {
  if (header.type < 0 || header.type > 0xff || !Number.isInteger(header.type)) {
    throw new CodecError(
      "NCP-FRAME-UNKNOWN-TYPE",
      `Frame type out of byte range: ${header.type}`,
      { type: header.type },
    );
  }
  if (header.flags.extended) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      "Extended header (EXT=1) is not supported by v0.1.0 codec",
      { flags: header.flags },
    );
  }
  if (
    header.payloadLength < 0 ||
    header.payloadLength > MAX_FIXED_PAYLOAD ||
    !Number.isInteger(header.payloadLength)
  ) {
    throw new CodecError(
      "NCP-FRAME-PAYLOAD-TOO-LARGE",
      `Payload length ${header.payloadLength} exceeds fixed-header max of ${MAX_FIXED_PAYLOAD}`,
      { payloadLength: header.payloadLength, max: MAX_FIXED_PAYLOAD },
    );
  }
  const bytes = new Uint8Array(FIXED_HEADER_BYTES);
  const view = new DataView(bytes.buffer);
  view.setUint8(0, header.type);
  view.setUint8(1, encodeFlags(header.flags));
  view.setUint16(2, header.payloadLength, false); // false = big-endian
  return bytes;
}

export function decodeFixedHeader(input: Uint8Array): FrameHeader {
  if (input.length < FIXED_HEADER_BYTES) {
    throw new CodecError(
      "NCP-FRAME-TRUNCATED",
      `Header requires ${FIXED_HEADER_BYTES} bytes, got ${input.length}`,
      { available: input.length, required: FIXED_HEADER_BYTES },
    );
  }
  const view = new DataView(input.buffer, input.byteOffset, input.byteLength);
  const type = view.getUint8(0);
  const flagsByte = view.getUint8(1);
  const flags = decodeFlags(flagsByte);
  if (flags.extended) {
    throw new CodecError(
      "NCP-FRAME-FLAGS-INVALID",
      "Extended header (EXT=1) is not supported by v0.1.0 codec",
      { flagsByte },
    );
  }
  const payloadLength = view.getUint16(2, false);
  return { type, flags, payloadLength };
}
