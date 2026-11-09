import { z } from "zod";

/** Preserve PATCH semantics: omitted fields must never acquire create defaults. */
export function partialUpdateSchema<T extends z.ZodRawShape>(schema: z.ZodObject<T>) {
  const partial = schema.partial();
  return z.unknown().transform((input, ctx) => {
    const parsed = partial.safeParse(input);
    if (!parsed.success) {
      for (const issue of parsed.error.issues) ctx.addIssue({ ...issue });
      return z.NEVER;
    }
    const result = parsed.data;
    const source = input as Record<string, unknown>;
    for (const key of Object.keys(result)) {
      if (!Object.prototype.hasOwnProperty.call(source, key)) delete (result as Record<string, unknown>)[key];
      else if (source[key] === undefined) (result as Record<string, unknown>)[key] = undefined;
    }
    return result;
  });
}
