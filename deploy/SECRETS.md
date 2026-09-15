# Secrets custody (ADR-0013)

Chaves protegidas em `deploy/<env>/secrets`, nunca em git. Injetadas no boot pelo Kamal.

## Inventário
- `RAILS_MASTER_KEY` — chave mestra do Rails credentials.
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` — cifra `city_channels.access_token` (plataforma), `inbound_messages.raw`, `users.otp_secret`, `conversations.phone` (bancos de cidade).
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` — cifra `conversations.phone` (deterministic).
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` — derivação de chave.
- `WHATSAPP_APP_SECRET` — HMAC de webhook.
- `ROTA_APP_PASSWORD` — senha do papel `rota_app` (banco vazio `rota_saude_no_city_selected`).
- `ROTA_PLATFORM_PASSWORD` — senha do papel `rota_platform` (banco de plataforma).
- `PROVISIONER_DATABASE_URL` — `postgres://rota_provisioner:<senha>@<host>:5432/postgres`. Só o papel **worker** recebe:
  cria e apaga banco e role de cada cidade (Plano 4). Cada cidade provisionada ganha o role `rota_city_<slug>`, dono do
  banco `rota_saude_city_<slug>`, com senha gerada no provisionamento e guardada cifrada em `cities.database_url` —
  nenhuma senha de cidade entra no cofre.
- `PLATFORM_DATABASE_URL` — banco de plataforma (catálogo de cidades, operadores, `platform_events`), fila de plataforma e Solid Cache.
- `CITY_UNSET_DATABASE_URL` — banco VAZIO que precisa existir; destino do shard `bootstrap` do `CityRecord`, faz query fora de cidade falhar fechado. Nunca apontar para o banco compartilhado.
- `GOVBR_CLIENT_ID` / `GOVBR_CLIENT_SECRET` — cliente OIDC do gov.br; a redirect_uri registrada é a ÚNICA de auth.* (`GOVBR_REDIRECT_URI`).

Em produção os valores vêm do 1Password (`deploy/production/secrets`). Itens que o
cofre `rota-saude-prod` precisa ter: `postgres-roles` (campos `rota_app`,
`rota_platform`, `provisioner_url`), `active-record-encryption` (campos `primary_key`,
`deterministic_key`, `key_derivation_salt`) e `govbr` (campos `client_id`,
`client_secret`), além dos já existentes.

## Não secretos: servidor das cidades

`CITY_DATABASE_HOST`, `CITY_DATABASE_PORT` e `CITY_DATABASE_SSLMODE` ficam em `env.clear` do `deploy.yml` (não no
cofre). A URL de cada cidade provisionada (`cities.database_url`) é montada com eles — host, porta e
`?sslmode=` — e o processo **web** precisa deles no `POST /cities`, que não recebe `PROVISIONER_DATABASE_URL`. Em
produção `CITY_DATABASE_HOST` é obrigatório (sem ele, `POST /cities` responde 503 `misconfigured`) e `sslmode` cai em
`require`.

## Papel `rota_provisioner` (uma vez por cluster)

Criado pela infra, com o superusuário do Postgres, antes do primeiro provisionamento:

    CREATE ROLE rota_provisioner LOGIN CREATEDB CREATEROLE PASSWORD '<senha do cofre>';

Nunca `SUPERUSER`. Em dev e test, `rails platform:bootstrap` cria o mesmo papel com `ROTA_PROVISIONER_PASSWORD`
(default `rota_provisioner`).

## Backup e offboarding

`CITY_BACKUP_DIR` (volume do worker) recebe os dumps de `city:backup` e o dump final de `city:offboard`. O dump contém
dados cifrados com as chaves de AR Encryption acima: guardar o dump sem as chaves não permite restaurar.

## Rotação
AR Encryption suporta lista de chaves. Para rotacionar:
1. Gerar nova chave: `bin/rails db:encryption:init`.
2. Prepend da nova nos secrets (lista YAML/JSON).
3. Re-cifrar ao longo do tempo (job de re-encryption — fora de escopo).
4. Aposentar a antiga após confirmação.

## Blast radius (aceito no piloto)
Uma chave protege secrets de TODAS as cidades. Chave por cidade está decidida (spec banco por cidade) e é do Plano 6.
