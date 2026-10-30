export type TokenMeta = { name?: string; attributes: Record<string, string> };

/** Decodes a `data:application/json` token URI (base64 or utf8) into its name and trait values. */
export function parseTokenUri(uri: string): TokenMeta | null {
  const m = /^data:application\/json(?:;(base64|utf8))?(?:;charset=[^,;]+)?,(.*)$/s.exec(uri);
  if (!m) return null;
  try {
    const body = m[1] === "base64" ? Buffer.from(m[2]!, "base64").toString("utf8") : decodeURIComponentSafe(m[2]!);
    const json = JSON.parse(body) as { name?: string; attributes?: { trait_type?: string; value?: unknown }[] };
    const attributes: Record<string, string> = {};
    for (const a of json.attributes ?? []) if (a.trait_type !== undefined) attributes[a.trait_type] = String(a.value);
    return { name: json.name, attributes };
  } catch {
    return null;
  }
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}
