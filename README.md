# Recipe Costing & Food Cost Management System

A web app that automates recipe costing for multi-brand restaurant R&D — replacing manual Google-Sheets costing with real-time cost calculation, an approval workflow, role-based access, and PDF/Excel exports. Built to the PRD v1.0 spec.

## Status

Full **v1.0** scope (all 8 modules / 10 PRD phases) is implemented against a **mock data layer** (in-memory, persisted to `localStorage`). Every feature is wired through a typed repository interface so the backend can later be swapped for Supabase with no changes to UI, costing, validation, or permission code.

## Tech stack

React 18 · TypeScript · Vite · Tailwind · ShadCN-style UI (Radix) · TanStack Query · React Hook Form · Zod · Zustand · React Router v6 · Recharts · pdfmake · SheetJS.

## Getting started

```bash
npm install
npm run dev          # http://localhost:5173
```

### Demo accounts (password: `password123`)

| Role   | Email             | Lands on                          |
|--------|-------------------|-----------------------------------|
| Admin  | rahul@brand.com   | Full access + approvals + audit   |
| Editor | priya@brand.com   | Recipes + raw materials + reports |
| Viewer | amit@brand.com    | Assigned approved recipes only    |

The login screen has one-click buttons to fill each demo account. Use **Settings → Reset Demo Data** to restore the seed.

## Scripts

| Command | Description |
|---|---|
| `npm run dev` | Dev server |
| `npm run build` | Type-check + production build |
| `npm run test` | Unit + integration tests (Vitest) |
| `npm run test:e2e` | Playwright E2E (run `npx playwright install` once first) |
| `npm run lint` | ESLint |

## Architecture

```
src/
  lib/
    costing.ts          # PRD §10 costing formulae (pure, unit-tested)
    units.ts            # PRD §4.2 unit conversion engine
    auth/permissions.ts # PRD §7.2 / §14.2 role + view-mode matrix
    data/
      types.ts          # entity types mirroring PRD §9 schema
      mock/             # localStorage repos + price cascade + audit
      seed.ts           # seed data (reproduces PRD §4.4 worked example)
      index.ts          # active repo set (swap point for Supabase)
    validation/         # Zod schemas (PRD §12 messages)
  features/             # auth, raw-materials, recipes, costing, approvals,
                        # viewers, users, dashboard, reports, audit, settings
  components/ui/        # ShadCN-style primitives
db/migrations/          # SQL schema + RLS (PRD §9) — the contract the mock mirrors
```

### Key correctness anchors (tested)

- The seeded **Chicken Alfredo** recipe reproduces PRD §4.4: total ₹199.50, cost/portion ₹49.88, suggested ₹166.25 at 30% food cost.
- The **price cascade** (PRD §4.5): raising an ingredient price recalculates every recipe that uses it and records cost history — covered by `src/lib/data/cascade.test.ts`.

## Swapping in Supabase (future)

The mock layer lives behind `src/lib/data/index.ts`. To go live:

1. Run `db/migrations/0001_init.sql` against a Supabase project (enables RLS per PRD §9.3).
2. Add `src/lib/data/supabase/*` repos implementing the same exports as the mock repos.
3. Flip the export in `src/lib/data/index.ts` to the Supabase repos behind an env flag.

UI, costing, validation, and the permission layer remain untouched — the client-side permission checks map 1:1 to the Postgres RLS policies.
