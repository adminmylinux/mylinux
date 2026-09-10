/** Persistence for machines and tokens. Limits are enforced inside the same transaction as the
 * insert, so concurrent requests can not exceed them, and every creation path goes through here. */
import { sql } from "./db";
import type { MachineConfig } from "./ini";

export type Machine = { id: string; name: string; config: MachineConfig; created_at: string; updated_at: string };
export const MAX_MACHINES = 50;
export const MAX_TOKENS = 20;

export class LimitError extends Error {}
export class ConflictError extends Error {}

export interface Store {
  listMachines(userId: string): Promise<Machine[]>;
  findMachine(userId: string, idOrName: string): Promise<Machine | null>;
  /** Create only; ConflictError when the name exists, LimitError at the cap. */
  createMachine(userId: string, name: string, config: MachineConfig): Promise<Machine>;
  /** Create or replace by name; LimitError only when it would create beyond the cap. */
  upsertMachine(userId: string, name: string, config: MachineConfig): Promise<Machine>;
  updateMachine(userId: string, id: string, name: string, config: MachineConfig): Promise<Machine | null>;
  deleteMachine(userId: string, id: string): Promise<boolean>;
  listTokens(userId: string): Promise<unknown[]>;
  createToken(userId: string, name: string, prefix: string, hash: string): Promise<{ id: string; created_at: string }>;
  deleteToken(userId: string, id: string): Promise<void>;
}

const isUuid = (s: string) => /^[0-9a-f-]{36}$/i.test(s);
const COLS = sql`id, name, config, created_at, updated_at`;

export const pgStore: Store = {
  listMachines: (userId) => sql<Machine[]>`SELECT ${COLS} FROM machines WHERE user_id = ${userId} ORDER BY name`,

  async findMachine(userId, idOrName) {
    const rows = isUuid(idOrName)
      ? await sql<Machine[]>`SELECT ${COLS} FROM machines WHERE user_id = ${userId} AND id = ${idOrName}`
      : await sql<Machine[]>`SELECT ${COLS} FROM machines WHERE user_id = ${userId} AND name = ${idOrName}`;
    return rows[0] ?? null;
  },

  createMachine: (userId, name, config) => insertMachine(userId, name, config, false),
  upsertMachine: (userId, name, config) => insertMachine(userId, name, config, true),

  async updateMachine(userId, id, name, config) {
    const rows = await sql<Machine[]>`
      UPDATE machines SET name = ${name}, config = ${config}::jsonb, updated_at = now()
      WHERE id = ${id} AND user_id = ${userId} RETURNING ${COLS}`;
    return rows[0] ?? null;
  },

  async deleteMachine(userId, id) {
    const rows = await sql<{ id: string }[]>`DELETE FROM machines WHERE id = ${id} AND user_id = ${userId} RETURNING id`;
    return rows.length > 0;
  },

  listTokens: (userId) =>
    sql`SELECT id, name, prefix, created_at, last_used_at FROM api_tokens WHERE user_id = ${userId} ORDER BY created_at DESC`,

  createToken: (userId, name, prefix, hash) =>
    sql.begin(async (tx) => {
      // row lock on the user serializes concurrent token creation for that account
      await tx`SELECT id FROM users WHERE id = ${userId} FOR UPDATE`;
      const count = await tx<{ n: number }[]>`SELECT count(*)::int AS n FROM api_tokens WHERE user_id = ${userId}`;
      if (count[0].n >= MAX_TOKENS) throw new LimitError(`at most ${MAX_TOKENS} tokens per account`);
      const rows = await tx<{ id: string; created_at: string }[]>`
        INSERT INTO api_tokens (user_id, name, prefix, token_hash) VALUES (${userId}, ${name}, ${prefix}, ${hash})
        RETURNING id, created_at`;
      return rows[0];
    }),

  async deleteToken(userId, id) {
    await sql`DELETE FROM api_tokens WHERE user_id = ${userId} AND id = ${id}`;
  },
};

function insertMachine(userId: string, name: string, config: MachineConfig, upsert: boolean): Promise<Machine> {
  return sql.begin(async (tx) => {
    await tx`SELECT id FROM users WHERE id = ${userId} FOR UPDATE`;
    const existing = await tx<Machine[]>`SELECT ${COLS} FROM machines WHERE user_id = ${userId} AND name = ${name}`;
    if (existing.length && !upsert) throw new ConflictError("a machine with that name already exists");
    if (!existing.length) {
      const count = await tx<{ n: number }[]>`SELECT count(*)::int AS n FROM machines WHERE user_id = ${userId}`;
      if (count[0].n >= MAX_MACHINES) throw new LimitError(`at most ${MAX_MACHINES} machines per account`);
    }
    const rows = await tx<Machine[]>`
      INSERT INTO machines (user_id, name, config) VALUES (${userId}, ${name}, ${config}::jsonb)
      ON CONFLICT (user_id, name) DO UPDATE SET config = EXCLUDED.config, updated_at = now()
      RETURNING ${COLS}`;
    return rows[0];
  });
}
