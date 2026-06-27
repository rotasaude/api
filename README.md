# Rota Saúde — API

## Bootstrap do banco (do zero)

`schema.rb` (Ruby) não representa RLS/ownership do ADR-0019 — eles vivem como SQL
cru. Por isso o rebuild from-zero usa `db/structure.sql` (gerado por `pg_dump`):

- `rails db:bootstrap` — cria roles e carrega `db/structure.sql` como superuser
  (`rota_saude`/`POSTGRES_PASSWORD`) na DB-alvo (`BOOTSTRAP_DATABASE` ou a do
  `RAILS_ENV`). É o que `start.sh --reset` usa.
- `rails db:bootstrap:dump` — regenera `db/structure.sql`. **Rode e commite sempre
  que uma migration mexer em estrutura/RLS** (depois de aplicar a migration no dev).
- `bin/verify-bootstrap` — valida o bootstrap from-zero num banco-rascunho.

Migrations incrementais no dev seguem via `db:migrate` (entrypoint), normalmente.
