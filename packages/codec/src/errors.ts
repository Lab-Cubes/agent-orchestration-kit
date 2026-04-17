/**
 * Error codes surfaced by this codec.
 *
 * `NCP-*` codes are spec-defined in NPS-1 §6 and MAY be serialized into an
 * ErrorFrame on the wire. `CODEC-*` codes are local diagnostic codes for
 * failures that the spec does not enumerate (buffer truncation, payload
 * malformation); they MUST NOT cross the wire as NCP error codes.
 */
export type NcpErrorCode =
  | "NCP-FRAME-UNKNOWN-TYPE"
  | "NCP-FRAME-PAYLOAD-TOO-LARGE"
  | "NCP-FRAME-FLAGS-INVALID"
  | "NCP-ENCODING-UNSUPPORTED"
  | "CODEC-FRAME-TRUNCATED"
  | "CODEC-PAYLOAD-NOT-JSON";

export class CodecError extends Error {
  readonly code: NcpErrorCode;
  readonly details: Readonly<Record<string, unknown>>;

  constructor(
    code: NcpErrorCode,
    message: string,
    details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "CodecError";
    this.code = code;
    this.details = Object.freeze({ ...details });
  }
}
