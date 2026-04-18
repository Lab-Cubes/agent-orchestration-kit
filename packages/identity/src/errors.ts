export type NipErrorCode =
  | "NIP-KEY-GENERATION-FAILED"
  | "NIP-KEY-IMPORT-FAILED"
  | "NIP-SIGNATURE-FAILED"
  | "NIP-PUBLIC-KEY-FORMAT-INVALID"
  | "NIP-SIGNATURE-FORMAT-INVALID"
  | "NIP-NID-FORMAT-INVALID"
  | "NIP-DEV-MODE-AGENT-ID-INVALID"
  | "NIP-SCOPE-EXPANSION-DENIED";

export class NipError extends Error {
  readonly code: NipErrorCode;
  readonly details: Readonly<Record<string, unknown>>;

  constructor(
    code: NipErrorCode,
    message: string,
    details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "NipError";
    this.code = code;
    this.details = Object.freeze({ ...details });
  }
}
