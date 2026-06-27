// Shared types for the reusable CSV/XLSX import workflow (§35–§37). One
// ImportConfig drives the dialog for any data page that has an Export.

export type ImportMode = "add" | "update" | "upsert";

export interface ImportSummary {
  total: number;
  imported: number;
  updated: number;
  skipped: number;
  failed: number;
  errors: { row: number; message: string }[];
}

export interface ImportColumn {
  /** Header label shown in the template + matched against the file (case-insensitive). */
  label: string;
  required?: boolean;
}

export type RawRow = Record<string, unknown>;

export interface ImportConfig<T> {
  title: string;
  /** Expected columns — drives the template + the preview header hint. */
  columns: ImportColumn[];
  /** Validate + map one raw row to a typed record (rowNumber is 1-based incl. header). */
  parseRow: (row: RawRow, rowNumber: number) => { value: T } | { error: string };
  /** Persist the records in the chosen mode; returns a summary. */
  run: (mode: ImportMode, rows: T[]) => Promise<ImportSummary>;
  /** A representative sample row for the downloadable template. */
  sample: RawRow;
  /** Which modes are offered (default all three). */
  modes?: ImportMode[];
}

/** Read a field from a raw row by any of its accepted header spellings. */
export function pick(row: RawRow, labels: string[]): unknown {
  const keys = Object.keys(row);
  for (const label of labels) {
    const k = keys.find((kk) => kk.trim().toLowerCase() === label.trim().toLowerCase());
    if (k != null && row[k] !== "" && row[k] != null) return row[k];
  }
  return undefined;
}

/** Parse a spreadsheet cell to a number; "" → null, garbage → NaN. */
export function toNum(v: unknown): number | null {
  if (v == null || v === "") return null;
  const n = typeof v === "number" ? v : parseFloat(String(v).replace(/[^0-9.-]/g, ""));
  return isFinite(n) ? n : NaN;
}

export function toText(v: unknown): string {
  return v == null ? "" : String(v).trim();
}
