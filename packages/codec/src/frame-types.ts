/**
 * Frame type codes per NPS-0 §6 (namespace) + the frame registry.
 *
 * Range allocation:
 *   0x01-0x0F  NCP  (wire format, schema anchoring)
 *   0x10-0x1F  NWP  (web node access)
 *   0x20-0x2F  NIP  (identity, trust, revocation)
 *   0x30-0x3F  NDP  (node discovery)
 *   0x40-0x4F  NOP  (orchestration)
 *   0xF0-0xFF  System (ErrorFrame 0xFE; others reserved)
 *
 * This codec builds and parses any frame in the 0x01-0x4F + 0xFE range as a
 * Tier-1 JSON envelope. Per-frame semantic validation (fields, invariants)
 * belongs to the sub-protocol package consuming the parsed payload.
 */
export const FrameType = {
  // NCP (NPS-1)
  AnchorFrame: 0x01,
  DiffFrame: 0x02,
  StreamFrame: 0x03,
  CapsFrame: 0x04,
  /** @deprecated Superseded by NOP AlignStream (0x43). See NPS-1 §4.5. */
  AlignFrame: 0x05,
  HelloFrame: 0x06,
  // NIP (NPS-3)
  IdentFrame: 0x20,
  TrustFrame: 0x21,
  RevokeFrame: 0x22,
  // System
  ErrorFrame: 0xfe,
} as const;

export type FrameTypeCode = (typeof FrameType)[keyof typeof FrameType];

const NPS_RANGE_START = 0x01;
const NPS_RANGE_END = 0x4f;
const ERROR_FRAME = 0xfe;

export function isKnownFrameType(code: number): code is FrameTypeCode {
  return (
    code === FrameType.AnchorFrame ||
    code === FrameType.DiffFrame ||
    code === FrameType.StreamFrame ||
    code === FrameType.CapsFrame ||
    code === FrameType.AlignFrame ||
    code === FrameType.HelloFrame ||
    code === FrameType.IdentFrame ||
    code === FrameType.TrustFrame ||
    code === FrameType.RevokeFrame ||
    code === FrameType.ErrorFrame
  );
}

/**
 * Whether a byte is routable by this codec: any NPS sub-protocol frame
 * (0x01-0x4F per NPS-0 §6) or the shared ErrorFrame (0xFE).
 *
 * Accepts unknown-but-in-range frames from newer spec revisions (Postel);
 * rejects clearly out-of-range bytes.
 */
export function isValidFrameType(code: number): boolean {
  return (code >= NPS_RANGE_START && code <= NPS_RANGE_END) || code === ERROR_FRAME;
}
