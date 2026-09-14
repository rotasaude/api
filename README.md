# Rota Saúde — API

## Ambiente de desenvolvimento (monorepo)

`docker-compose.yml` e `start.sh` ficam na raiz do monorepo, **fora de qualquer
repositório git**. Esta seção é o registro versionado do que eles precisam; se
você montar o ambiente em outra máquina, confira contra ela.

Variáveis que o container `api` (e o `worker`) precisam receber — o
`config/database.yml` avalia o ERB de **todos** os ambientes no boot, então
faltar uma delas quebra até rodando os specs:

| Variável | Default de dev | Usada por |
|---|---|---|
| `DATABASE_HOST` / `DATABASE_PORT` | `host.docker.internal` / `5432` | todas as conexões |
| `POSTGRES_PASSWORD` | `postgres` | tasks de bootstrap (superuser `rota_saude`) |
| `ROTA_APP_PASSWORD` | `rota_app` | `primary`, `city_unset` e bancos de cidade |
| `ROTA_ADMIN_PASSWORD` | `rota_admin` | `queue`, `cache` (até o Plano 5) |
| `ROTA_PLATFORM_PASSWORD` | `rota_platform` | `platform` |
| `PUBLIC_DASHBOARD_URL` | `http://localhost:5175/dashboard/` | link do e-mail de redefinição de senha |

Bancos que precisam existir no Postgres do host:

| Banco | Dono | Quem cria |
|---|---|---|
| `rota_saude_development`, `rota_saude_test` | `rota_saude` | `start.sh` |
| `rota_saude_platform_development`, `rota_saude_platform_test` | `rota_platform` | `rails platform:bootstrap` (com `RAILS_ENV=test` para o de test) |
| `rota_saude_no_city_selected` (vazio de propósito) | `rota_saude` | `rails city:test_databases` |
| `rota_saude_test_city_a`, `rota_saude_test_city_b` | `rota_saude` | `rails city:test_databases` |

`start.sh` chama as três tasks antes do `db:seed`. Estado conhecido ao fim do
Plano 2: nenhuma cidade fica servível em dev (`city:create` só registra a cidade
como `provisioning`); o baseline de duas cidades é do Plano 3.

Em produção os mesmos nomes vêm do Kamal — ver `deploy/SECRETS.md`.

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
  `primary`/`queue`/`cache`/`platform`/`city_unset`, em qualquer
  ambiente. `rails city:test_databases` provisiona os dois bancos de cidade
  usados pelos specs de isolamento.
- **Banco compartilhado** — só guarda Solid Queue e Solid Cache até o Plano 5
  (`db/queue_schema.rb`, `db/cache_schema.rb`; `db/schema.rb`, de `primary`,
  fica vazio de propósito). `start.sh` garante os roles `rota_app`/`rota_admin`
  e carrega esses dois schemas por nome (`db:schema:load:primary`,
  `:queue`, `:cache`) — nunca `db:prepare`/`db:schema:load` "puros", que
  varreriam todos os configs do ambiente de uma vez. O config `admin` e o
  `db/admin_schema.rb` saíram no corte do Plano 2 (Task 5): o domínio roda por
  conexão de cidade (`CityRecord`), sem RLS.
- `config.active_record.dump_schema_after_migration` é `false` em
  development (igual a test/production): como primary/queue/cache
  compartilham o mesmo banco físico, um dump automático de qualquer um deles
  gravaria também as tabelas dos outros (e qualquer tabela antiga de domínio
  que um banco de dev anterior ao corte ainda tenha) no seu arquivo de schema.
  Rode `db:schema:dump:<config>` explicitamente quando precisar regenerar um
  deles (`primary`, `queue` ou `cache`).
  **`platform` é afetado pelo mesmo flag, mas por um motivo diferente:** o
  banco de plataforma é próprio, nunca foi contaminado por domínio — só
  parou de se auto-regenerar. Depois de qualquer migration em
  `db/platform_migrate/`, rode `bin/rails db:schema:dump:platform` e
  commite `db/platform_schema.rb` manualmente (era automático via
  `db:migrate:platform` antes desta mudança — Task 3 contava com isso).

Migrations incrementais no dev seguem via `db:migrate` (entrypoint), normalmente
— `db/migrate/` fica vazio de propósito (só domínio de cidade mudava esse
diretório, e esse domínio saiu).
