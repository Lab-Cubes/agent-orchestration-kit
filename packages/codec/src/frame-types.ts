/**
 * Frame type codes per NPS-1 §2.3 and the frame registry.
 *
 * Range allocation:
 *   0x01-0x0F  NCP
 *   0x10-0x1F  NWP
 *   0x20-0x2F  NIP
 *   0x30-0x3F  NDP
 *   0x40-0x4F  NOP
 *   0xF0-0xFF  Reserved (includes ErrorFrame 0xFE)
 */
export const FrameType = {
  AnchorFrame: 0x01,
  DiffFrame: 0x02,
  StreamFrame: 0x03,
  CapsFrame: 0x04,
  /** @deprecated Superseded by NOP AlignStream (0x43). See NPS-1 §4.5. */
  AlignFrame: 0x05,
  HelloFrame: 0x06,
  ErrorFrame: 0xfe,
} as const;

export type FrameTypeCode = (typeof FrameType)[keyof typeof FrameType];

const NCP_RANGE_START = 0x01;
const NCP_RANGE_END = 0x0f;
const ERROR_FRAME = 0xfe;

export function isKnownFrameType(code: number): code is FrameTypeCode {
  return (
    code === FrameType.AnchorFrame ||
    code === FrameType.DiffFrame ||
    code === FrameType.StreamFrame ||
    code === FrameType.CapsFrame ||
    code === FrameType.AlignFrame ||
    code === FrameType.HelloFrame ||
    code === FrameType.ErrorFrame
  );
}

/**
 * Whether a byte is routable by this codec as an NCP frame or the shared ErrorFrame.
 * Used by parseFrame to accept unknown-but-in-range frames from newer spec revisions
 * while rejecting clearly out-of-range bytes.
 */
export function isNcpRangeOrError(code: number): boolean {
  return (code >= NCP_RANGE_START && code <= NCP_RANGE_END) || code === ERROR_FRAME;
}
