# Rota Saúde — API

## Bootstrap do banco (do zero)

`schema.rb` (Ruby) não representa RLS/ownership do ADR-0019 — eles vivem como SQL
cru. Por isso o rebuild from-zero usa `db/structure.sql` (gerado por `pg_dump`):

- `rails db:bootstrap` — cria roles e carrega `db/structure.sql` como superuser
  (`rota_saude`/`POSTGRES_PASSWORD`) na DB-alvo (`BOOTSTRAP_DATABASE` ou a do
  `RAILS_ENV`). É o que `start.sh --reset` usa.
- `rails db:bootstrap:dump` — regenera `db/structure.sql`. **Rode e commite sempre
  que uma migration mexer em estrutura/RLS** (depois de aplicar a migration no dev).
  Mantenha `db/migrate/*.rb` e `db/structure.sql` sincronizados: o bootstrap stamps
  `schema_migrations` pelos nomes dos arquivos em `db/migrate/`, então não delete
  migrations sem re-gerar `structure.sql`.
- `bin/verify-bootstrap` — valida o bootstrap from-zero num banco-rascunho.

> **Precondição:** `db:bootstrap` exige a DB-alvo **vazia** (o load usa `CREATE TABLE`
> sem `IF NOT EXISTS`). `start.sh --reset` e `verify-bootstrap` já garantem isso.
>
> **Versão do psql:** `db/structure.sql` é gerado pelo `pg_dump` do container e usa
> meta-comandos `\restrict`/`\unrestrict` (pg_dump recente). Carregue-o sempre com um
> `psql` de versão **≥** a que gerou o dump (dentro do container é garantido; cuidado
> ao carregar de um cliente antigo no host ou em prod).

Migrations incrementais no dev seguem via `db:migrate` (entrypoint), normalmente.
