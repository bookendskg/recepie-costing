import { useRef, useState } from "react";
import { Upload, FileSpreadsheet, Download, CheckCircle2, Loader2 } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { parseSpreadsheet, downloadTemplate, downloadFailedRows } from "@/lib/import/parseFile";
import type { ImportConfig, ImportMode, ImportSummary, RawRow } from "@/lib/import/importTypes";
import { toast } from "@/components/ui/use-toast";

const MODE_LABEL: Record<ImportMode, string> = {
  add: "Add new only",
  update: "Update matching",
  upsert: "Add & update",
};

/** Reusable CSV/XLSX import flow: upload → preview + validate → mode → summary. */
export function ImportDialog<T>({
  open,
  onOpenChange,
  config,
  onDone,
}: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  config: ImportConfig<T>;
  onDone?: () => void;
}) {
  const [step, setStep] = useState<"upload" | "preview" | "summary">("upload");
  const [fileName, setFileName] = useState("");
  const [valid, setValid] = useState<T[]>([]);
  const [errors, setErrors] = useState<{ row: number; message: string }[]>([]);
  const [previewRows, setPreviewRows] = useState<RawRow[]>([]);
  const [mode, setMode] = useState<ImportMode>("upsert");
  const [busy, setBusy] = useState(false);
  const [summary, setSummary] = useState<ImportSummary | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const modes = config.modes ?? ["upsert", "add", "update"];

  const reset = () => {
    setStep("upload");
    setFileName("");
    setValid([]);
    setErrors([]);
    setPreviewRows([]);
    setSummary(null);
    setBusy(false);
    setMode("upsert");
  };
  const close = () => {
    onOpenChange(false);
    setTimeout(reset, 200);
  };

  const onFile = async (file: File) => {
    try {
      const rows = await parseSpreadsheet(file);
      if (!rows.length) {
        toast.error("That file has no data rows.");
        return;
      }
      const v: T[] = [];
      const errs: { row: number; message: string }[] = [];
      rows.forEach((r, i) => {
        const res = config.parseRow(r, i + 2); // +2: row 1 is the header
        if ("value" in res) v.push(res.value);
        else errs.push({ row: i + 2, message: res.error });
      });
      setFileName(file.name);
      setPreviewRows(rows.slice(0, 8));
      setValid(v);
      setErrors(errs);
      setStep("preview");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not read that file.");
    }
  };

  const doImport = async () => {
    setBusy(true);
    try {
      const s = await config.run(mode, valid);
      setSummary(s);
      setStep("summary");
      onDone?.();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Import failed.");
    } finally {
      setBusy(false);
    }
  };

  const headers = previewRows[0] ? Object.keys(previewRows[0]).slice(0, 6) : [];

  return (
    <Dialog open={open} onOpenChange={(o) => !o && close()}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{config.title}</DialogTitle>
          <DialogDescription>
            CSV or XLSX. Columns: {config.columns.map((c) => c.label + (c.required ? "*" : "")).join(", ")}.
          </DialogDescription>
        </DialogHeader>

        {step === "upload" && (
          <div className="space-y-3">
            <button
              type="button"
              onClick={() => inputRef.current?.click()}
              className="flex w-full flex-col items-center gap-2 rounded-lg border-2 border-dashed p-8 text-muted-foreground transition-colors hover:bg-muted/50"
            >
              <Upload className="h-7 w-7" />
              <span className="text-sm">Click to choose a .csv or .xlsx file</span>
            </button>
            <input
              ref={inputRef}
              type="file"
              accept=".csv,.xlsx,.xls"
              className="hidden"
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) void onFile(f);
                e.target.value = "";
              }}
            />
            <Button
              variant="outline"
              size="sm"
              onClick={() => downloadTemplate(`${config.title.replace(/\s+/g, "_")}_template.xlsx`, config.sample)}
            >
              <Download className="h-4 w-4" /> Download template
            </Button>
          </div>
        )}

        {step === "preview" && (
          <div className="space-y-3">
            <div className="flex items-center gap-2 text-sm">
              <FileSpreadsheet className="h-4 w-4 text-muted-foreground" /> {fileName}
            </div>
            <div className="flex flex-wrap gap-2 text-sm">
              <span className="rounded bg-emerald-500/10 px-2 py-1 font-medium text-emerald-700 dark:text-emerald-400">
                {valid.length} valid
              </span>
              {errors.length > 0 && (
                <span className="rounded bg-red-500/10 px-2 py-1 font-medium text-red-600 dark:text-red-400">
                  {errors.length} invalid
                </span>
              )}
            </div>
            {headers.length > 0 && (
              <div className="max-h-44 overflow-auto rounded border text-xs">
                <table className="w-full">
                  <thead className="sticky top-0 bg-muted">
                    <tr>{headers.map((h) => <th key={h} className="px-2 py-1 text-left font-medium">{h}</th>)}</tr>
                  </thead>
                  <tbody>
                    {previewRows.map((r, i) => (
                      <tr key={i} className="border-t">
                        {headers.map((h) => <td key={h} className="px-2 py-1">{String(r[h] ?? "")}</td>)}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {errors.length > 0 && (
              <div className="space-y-0.5 rounded border border-red-500/30 bg-red-500/5 p-2 text-xs text-red-600 dark:text-red-400">
                {errors.slice(0, 5).map((e) => <div key={e.row}>Row {e.row}: {e.message}</div>)}
                {errors.length > 5 && <div>+{errors.length - 5} more…</div>}
              </div>
            )}
            <div>
              <p className="mb-1.5 text-sm font-medium">Import mode</p>
              <div className="flex flex-wrap gap-2">
                {modes.map((m) => (
                  <button
                    key={m}
                    type="button"
                    onClick={() => setMode(m)}
                    className={cn(
                      "rounded-full border px-3 py-1 text-sm transition-colors",
                      mode === m ? "border-primary bg-primary/10 font-medium text-primary" : "text-muted-foreground hover:bg-muted",
                    )}
                  >
                    {MODE_LABEL[m]}
                  </button>
                ))}
              </div>
            </div>
          </div>
        )}

        {step === "summary" && summary && (
          <div className="space-y-3">
            <div className="flex items-center gap-2 text-sm font-medium text-emerald-700 dark:text-emerald-400">
              <CheckCircle2 className="h-5 w-5" /> Import complete
            </div>
            <div className="grid grid-cols-3 gap-2 text-sm sm:grid-cols-5">
              <Stat label="Total" value={summary.total} />
              <Stat label="Added" value={summary.imported} />
              <Stat label="Updated" value={summary.updated} />
              <Stat label="Skipped" value={summary.skipped} />
              <Stat label="Failed" value={summary.failed} bad />
            </div>
            {summary.errors.length > 0 && (
              <Button variant="outline" size="sm" onClick={() => downloadFailedRows("import_errors.xlsx", summary.errors)}>
                <Download className="h-4 w-4" /> Download {summary.errors.length} failed rows
              </Button>
            )}
          </div>
        )}

        <DialogFooter>
          {step === "preview" ? (
            <>
              <Button variant="outline" onClick={() => setStep("upload")}>Back</Button>
              <Button variant="accent" onClick={doImport} disabled={busy || valid.length === 0}>
                {busy && <Loader2 className="h-4 w-4 animate-spin" />}
                Import {valid.length}
              </Button>
            </>
          ) : (
            <Button variant="outline" onClick={close}>{step === "summary" ? "Done" : "Cancel"}</Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Stat({ label, value, bad }: { label: string; value: number; bad?: boolean }) {
  return (
    <div className="rounded-md bg-muted/50 p-2">
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={cn("text-lg font-bold", bad && value > 0 && "text-red-600 dark:text-red-400")}>{value}</p>
    </div>
  );
}
