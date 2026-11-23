declare module 'js-yaml' {
  export class Type {
    constructor(tag: string, options: { kind: 'scalar', construct: (value: string) => unknown,
      instanceOf: new (...args: never[]) => object, represent: (value: never) => string })
  }
  export interface Schema { extend(type: Type): Schema }
  export const DEFAULT_SCHEMA: Schema
  export function load(source: string, options?: { schema?: Schema }): unknown
  export function dump(value: unknown, options?: { schema?: Schema }): string
}
