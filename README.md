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
| `ROTA_APP_PASSWORD` | `rota_app` | `primary` e `city_unset` (banco vazio) |
| `ROTA_PLATFORM_PASSWORD` | `rota_platform` | `platform`, `cache` e a fila de plataforma |
| `ROTA_PROVISIONER_PASSWORD` | `rota_provisioner` | `platform:bootstrap` (cria o papel) e `CityDatabase` em dev/test |
| `PROVISIONER_DATABASE_URL` | montada a partir da anterior | papel worker: cria e apaga banco/role de cidade (obrigatória em produção) |
| `CITY_DATABASE_HOST` / `CITY_DATABASE_PORT` | `DATABASE_HOST` / `DATABASE_PORT` (em produção: host obrigatório, porta `5432`) | servidor na URL de cada cidade provisionada (`CityDatabase.url_for`); o web precisa no `POST /cities` |
| `CITY_DATABASE_SSLMODE` | vazio (sem `sslmode`; em produção `require`) | `?sslmode=` da URL da cidade e `PGSSLMODE` do `pg_dump` |
| `CITY_BACKUP_DIR` | `tmp/city_backups` | `city:backup`, `city:offboard` |
| `PUBLIC_DASHBOARD_URL` | `http://localhost:5175/dashboard/` | link do e-mail de redefinição de senha |

Bancos que precisam existir no Postgres do host:

| Banco | Dono | Quem cria |
|---|---|---|
| `rota_saude_platform_development`, `rota_saude_platform_test` | `rota_platform` | `rails platform:bootstrap` (com `RAILS_ENV=test` para o de test) |
| `rota_saude_no_city_selected` (vazio de propósito) | `rota_saude` | `rails city:test_databases` |
| `rota_saude_test_city_a`, `rota_saude_test_city_b` | `rota_saude` | `rails city:test_databases` |
| `rota_saude_city_curitiba`, `rota_saude_city_maringa` | `rota_saude` | `rails city:dev_baseline` |
| `rota_saude_city_<slug>` (cidades provisionadas) | `rota_city_<slug>` | `ProvisionCityJob` (worker), a partir de `POST /cities` |

`start.sh` chama essas tasks e `city:dev_baseline` antes do `db:seed`. Contas de dev:
`admin@curitiba.demo` e `admin@maringa.demo` (senha `dev-password`) em cada cidade, e o operador `dev@local`
(mesma senha + TOTP) no console. Hosts: `curitiba.localhost`, `maringa.localhost`, `admin.localhost`.
No navegador os frontends ainda não resolvem cidade — o proxy do Vite troca o Host por `api:3000` até o Plano 6;
para exercitar hoje, use `curl -H "Host: curitiba.localhost" http://localhost:3030/...`.

Ao puxar código que adiciona um novo diretório sob `app/` (por exemplo
`app/constraints`), reinicie o `api` (`docker compose restart api`): um
servidor já rodando só reconhece novas raízes de autoload no boot.

Em produção os mesmos nomes vêm do Kamal — ver `deploy/SECRETS.md`.

**Operador entrando numa cidade (Plano 3B).** No console (`admin.localhost`), depois do login com TOTP,
`POST /city_grants {city_slug}` devolve a URL da cidade com um grant de 60 s e uso único; a cidade o consome em
`POST /session/grant {token}`. A sessão de operador na cidade é SÓ LEITURA (painéis `/admin/api/*` e a própria sessão),
vale 1 hora e é auditada no banco de plataforma e no da cidade. Cinco códigos TOTP errados apagam a sessão pendente.

**gov.br (Plano 3B).** O login começa na cidade (`POST /auth/govbr/start`) e o callback é ÚNICO, em
`auth.<domínio>/auth/govbr/callback`, que volta para a cidade com um grant. Variáveis: `GOVBR_CLIENT_ID`,
`GOVBR_CLIENT_SECRET`, `GOVBR_REDIRECT_URI`, `GOVBR_ISSUER_URL` (default staging: `https://sso.staging.acesso.gov.br`
no deploy `development`, produção usa `https://sso.acesso.gov.br` — ver `deploy/*/deploy.yml`). Sem elas (ou vazias),
`start` responde 502.
O destino de volta usa `CITY_DASHBOARD_URL_TEMPLATE` (default `http://%{slug}.localhost:5175/dashboard/`).

## Ciclo de vida da cidade (Plano 4)

**Provisionar.** No console (`admin.*`, operador com TOTP):

- `POST /cities {slug, name, uf, ibge_code, admin_email, alert_email}` grava a cidade como `provisioning` e responde
  `202 {id}`.
- O worker (`ProvisionCityJob`) cria o role `rota_city_<slug>` e o banco dele, com `CONNECT` revogado de `PUBLIC`.
  Depois migra (subprocesso `city:migrate[slug]`), grava `city_profile`, o destinatário de alerta, o protocolo template
  em rascunho e o convite do primeiro `municipal_admin`, e marca a cidade `active`.
- O convite vai por e-mail (`?invite=<token>` no dashboard; a tela é do Plano 6).
- `GET /cities/:id` mostra o status. Repetir o POST com o mesmo slug retoma um provisionamento que falhou.
- O canal WhatsApp é outro passo: `CITY_SLUG=... PHONE_NUMBER_ID=... WABA_ID=... DISPLAY_PHONE_NUMBER=... ACCESS_TOKEN=... rails channels:register`.
- O provisionamento não semeia termo de consentimento.

**Migrar (deploy).** O boot NÃO migra. Com a imagem nova, antes de trocar o código em execução, rode `bin/migrate`
(`db:migrate` + `city:migrate:all`). Por exemplo: `kamal app exec --roles=worker --version=<nova> bin/migrate` e só
então `kamal deploy`.
- `city:migrate:all` migra toda cidade `active`/`suspended`, com lock por cidade, e sai com erro listando as que
  ficaram para trás.
- A cidade atrasada responde `503 city_schema_behind`; as outras seguem no ar.
- Toda migração destrutiva é expand/contract: o código antigo roda sobre o schema novo durante o deploy.
- Migração de cidade mora em `db/city_migrate/`, e `db/city_schema.rb` precisa acompanhar. O spec de paridade em
  `spec/services/city_schema_spec.rb` compara os dois.

**Suspender, backup, desligar** (rake; em produção no papel worker):

- `rails 'city:suspend[slug]'` → o host responde 403 em até 30 s. `rails 'city:resume[slug]'` desfaz.
- `rails 'city:backup[slug]'` → `pg_dump` da cidade em `CITY_BACKUP_DIR`, restaurável sozinho com
  `pg_restore --no-owner`.
- `CONFIRM=<slug> rails 'city:offboard[slug]'` (IRREVERSÍVEL, só cidade suspensa) → dump final, canais inativos,
  `archived`, `DROP DATABASE` e `DROP ROLE`. Recusa (`suspension_too_recent`) até 60 s depois do `city:suspend` — duas
  vezes o TTL de 30 s do cache do catálogo, para os outros processos pararem de servir a cidade antes do dump. Se a
  cidade for retomada durante o dump, nada é apagado (`invalid_status`) e o dump fica.
- `curitiba` e `maringa` (criadas por `city:dev_up`, banco do superusuário) não são apagáveis pelo `rota_provisioner`.

**Purga.** Diariamente, `PurgePlatformAccessJob` apaga grants vencidos há mais de 1 dia e sessões de operador que não
autenticam mais. `PurgeOperatorCitySessionsJob` apaga, em cada cidade, as sessões de operador por grant além de 1 hora.

## Worker por cidade (Plano 5)

`bin/city_workers` (container `worker` no dev, papel `worker` no Kamal) roda **um supervisor Solid Queue por cidade
ativa, mais o da plataforma**:

- **Fila da cidade** — no banco dela: webhook, envio de WhatsApp, alertas, relatórios, e-mails de redefinição de senha,
  tarefas recorrentes de `config/recurring.yml` (agendadas por cidade). Workers em `config/queue.yml`: `urgent`
  isolado, `realtime,default`, `reports,housekeeping`.
- **Fila de plataforma** — no banco de plataforma: `ProvisionCityJob`, e-mail do convite, `PurgePlatformAccessJob` e
  `config/recurring_platform.yml`. Só entram jobs de `PlatformQueue::JOBS`/`MAILERS`: um job de cidade enfileirado
  fora de uma cidade levanta `PlatformQueue::Misplaced`. Job novo de plataforma precisa entrar nessa lista.
- **Catálogo** — o gerente lê as cidades `active` com schema em dia a cada `CITY_WORKERS_POLL_SECONDS` (30 s): cidade
  nova começa a processar em até 30 s; cidade suspensa, arquivada ou com schema atrasado para em até 30 s (os jobs dela
  esperam: `CitySchemaBehind` reagenda por até 1 hora).
- **Falha** — supervisor que morre é reiniciado com espera de 1 s, 2 s, 4 s… até 5 min; volta a 1 s depois de 10 min
  de pé. Log: `docker compose logs -f worker | grep city_workers`.
- **Parada** — TERM/INT repassa TERM aos supervisores, espera `SolidQueue.shutdown_timeout` + 5 s e mata o grupo de
  processo de quem sobrar.
- **Dimensionamento** — ~6 processos por cidade. `RAILS_MAX_THREADS` do worker precisa ser ≥ maior `threads` de
  `config/queue.yml` + 2 (Kamal: 12). Um host de worker roda todas as cidades; mais de um host duplica supervisores por
  cidade (seguro, mas dobra processos).
- **Painéis** — `/admin/api/queues` e `/admin/api/overview` leem a fila da cidade do host.
- `SOLID_QUEUE_IN_PUMA` não existe mais: o worker é sempre `bin/city_workers`.

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
- **Banco compartilhado** — aposentado no Plano 5. `rota_saude_development` e `rota_saude_test` continuam existindo
  no Postgres de dev com dados antigos, mas nada os usa: a fila de cada cidade mora no banco dela, a fila de
  plataforma e o Solid Cache no banco de plataforma (`db/platform_migrate`), e `primary` aponta para o banco vazio
  `rota_saude_no_city_selected`. `city:load_schema` segue recusando esses nomes.
- `config.active_record.dump_schema_after_migration` é `false` em development. Depois de qualquer migration em
  `db/platform_migrate/`, rode `bin/rails db:schema:dump:platform` e commite `db/platform_schema.rb`. Depois de uma
  migration em `db/city_migrate/`, atualize `db/city_schema.rb` à mão: o spec de paridade compara os dois.
- Upgrade do Solid Queue que mude tabelas exige migration nova em `db/city_migrate/` **e** em `db/platform_migrate/`
  (as duas usam `db/solid_queue_tables.rb`).

Migrations no dev: `bin/rails db:migrate` (plataforma) e `bin/rails city:migrate:all` (cidades) — ou `bin/migrate`,
que roda os dois. `db/migrate/` fica vazio de propósito.
