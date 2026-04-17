export type NcpErrorCode =
  | "NCP-FRAME-UNKNOWN-TYPE"
  | "NCP-FRAME-PAYLOAD-TOO-LARGE"
  | "NCP-FRAME-FLAGS-INVALID"
  | "NCP-FRAME-TRUNCATED"
  | "NCP-ENCODING-UNSUPPORTED"
  | "NCP-PAYLOAD-NOT-JSON";

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
