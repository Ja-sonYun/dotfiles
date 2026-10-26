export {};

declare global {
  type RequestInfo = Parameters<typeof fetch>[0];
  type HeadersInit = NonNullable<RequestInit["headers"]>;
}
