/** Postgres via Bun's built-in client. Tables are created at startup so a
 * fresh deploy needs no migration step. */
import { SQL } from "bun";

export const sql = new SQL(process.env.DATABASE_URL ?? "postgres://localhost:5432/mylinux");

export async function ensureSchema() {
  await sql`
    CREATE TABLE IF NOT EXISTS users (
      id text PRIMARY KEY,
      created_at timestamptz NOT NULL DEFAULT now()
    )`;
  await sql`
    CREATE TABLE IF NOT EXISTS machines (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name text NOT NULL,
      config jsonb NOT NULL DEFAULT '{}'::jsonb,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (user_id, name)
    )`;
  await sql`
    CREATE TABLE IF NOT EXISTS api_tokens (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name text NOT NULL,
      prefix text NOT NULL,
      token_hash text NOT NULL UNIQUE,
      created_at timestamptz NOT NULL DEFAULT now(),
      last_used_at timestamptz
    )`;
}

export async function ensureUser(id: string) {
  await sql`INSERT INTO users (id) VALUES (${id}) ON CONFLICT DO NOTHING`;
}
