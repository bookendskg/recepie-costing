import type { RawRow } from "./importTypes";

/** Parse the first sheet of a CSV/XLSX file into header-keyed row objects. */
export async function parseSpreadsheet(file: File): Promise<RawRow[]> {
  const XLSX = await import("xlsx");
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: "array" });
  const ws = wb.Sheets[wb.SheetNames[0]];
  if (!ws) return [];
  return XLSX.utils.sheet_to_json<RawRow>(ws, { defval: "", raw: true });
}

/** Download a one-row .xlsx template from a sample row. */
export async function downloadTemplate(filename: string, sample: RawRow): Promise<void> {
  const XLSX = await import("xlsx");
  const ws = XLSX.utils.json_to_sheet([sample]);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Template");
  XLSX.writeFile(wb, filename);
}

/** Download the failed rows + reasons as .xlsx for the user to fix and re-import. */
export async function downloadFailedRows(
  filename: string,
  errors: { row: number; message: string }[],
): Promise<void> {
  const XLSX = await import("xlsx");
  const ws = XLSX.utils.json_to_sheet(errors.map((e) => ({ Row: e.row, Error: e.message })));
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Errors");
  XLSX.writeFile(wb, filename);
}
