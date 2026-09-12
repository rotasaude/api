# Rota Saúde — API

## Bootstrap do banco (do zero)

Desde o Plano 2 ("banco por cidade", Task 4) o domínio (conversas, triagens,
protocolos, usuários municipais etc.) não mora mais no banco compartilhado —
cada cidade tem seu próprio banco Postgres, sem RLS e sem split de ownership.
`db:bootstrap`, `db:bootstrap:dump`, `bin/verify-bootstrap` e `db/structure.sql`
não existem mais; o RLS que eles reproduziam saiu junto com o domínio.

- **Banco de cidade** — schema em `db/city_migrate/` (uma migration só,
  `create_city_schema`), dump em `db/city_schema.rb`. Carregue num banco de
  cidade com `rails city:load_schema[nome_ou_url]` (`lib/tasks/city.rake`) —
  a task se recusa a rodar fora de development/test e a atingir o banco de
  `primary`/`admin`/`queue`/`cache`/`platform`/`city_unset`, em qualquer
  ambiente. `rails city:test_databases` provisiona os dois bancos de cidade
  usados pelos specs de isolamento.
- **Banco compartilhado** — só guarda Solid Queue e Solid Cache até o Plano 5
  (`db/queue_schema.rb`, `db/cache_schema.rb`; `db/schema.rb`, de `primary`,
  fica vazio de propósito). `start.sh` garante os roles `rota_app`/`rota_admin`
  e carrega esses dois schemas por nome (`db:schema:load:primary`,
  `:queue`, `:cache`) — nunca `db:prepare`/`db:schema:load` "puros", que
  varreriam também `admin` (cujo dump, `db/admin_schema.rb`, ainda é o
  schema antigo completo até o Plano 5 remover o papel `admin`).
- `config.active_record.dump_schema_after_migration` é `false` em
  development (igual a test/production): como primary/admin/queue/cache
  compartilham o mesmo banco físico, um dump automático depois de
  `db:migrate`/`db:prepare` reintroduziria toda tabela de domínio nesses
  quatro arquivos de schema. Rode `db:schema:dump:<config>` explicitamente
  quando precisar regenerar um deles (`primary`, `admin`, `queue` ou `cache`).
  **`platform` é afetado pelo mesmo flag, mas por um motivo diferente:** o
  banco de plataforma é próprio, nunca foi contaminado por domínio — só
  parou de se auto-regenerar. Depois de qualquer migration em
  `db/platform_migrate/`, rode `bin/rails db:schema:dump:platform` e
  commite `db/platform_schema.rb` manualmente (era automático via
  `db:migrate:platform` antes desta mudança — Task 3 contava com isso).

Migrations incrementais no dev seguem via `db:migrate` (entrypoint), normalmente
— `db/migrate/` fica vazio de propósito (só domínio de cidade mudava esse
diretório, e esse domínio saiu).
