# Secrets custody (ADR-0013)

Chaves protegidas em `deploy/<env>/secrets`, nunca em git. Injetadas no boot pelo Kamal.

## Inventário
- `RAILS_MASTER_KEY` — chave mestra do Rails credentials.
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` — cifra `city_channels.access_token` (plataforma), `inbound_messages.raw`, `users.otp_secret`, `conversations.phone` (bancos de cidade).
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` — cifra `conversations.phone` (deterministic).
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` — derivação de chave.
- `WHATSAPP_APP_SECRET` — HMAC de webhook.
- `ROTA_APP_PASSWORD` / `ROTA_ADMIN_PASSWORD` — senhas dos papéis Postgres (`rota_admin` só para fila/cache até o Plano 5).
- `ROTA_PLATFORM_PASSWORD` — senha do papel `rota_platform` (banco de plataforma).
- `DATABASE_URL` — banco compartilhado (fila e cache).
- `PLATFORM_DATABASE_URL` — banco de plataforma (catálogo de cidades, operadores, `platform_events`).
- `CITY_UNSET_DATABASE_URL` — banco VAZIO que precisa existir; destino do shard `bootstrap` do `CityRecord`, faz query fora de cidade falhar fechado. Nunca apontar para o banco compartilhado.
- `GOVBR_CLIENT_ID` / `GOVBR_CLIENT_SECRET` — cliente OIDC do gov.br; a redirect_uri registrada é a ÚNICA de auth.* (`GOVBR_REDIRECT_URI`).

Em produção os valores vêm do 1Password (`deploy/production/secrets`). Itens que o
cofre `rota-saude-prod` precisa ter: `postgres-roles` (campos `rota_app`,
`rota_admin`, `rota_platform`), `active-record-encryption` (campos `primary_key`,
`deterministic_key`, `key_derivation_salt`) e `govbr` (campos `client_id`,
`client_secret`), além dos já existentes.

## Rotação
AR Encryption suporta lista de chaves. Para rotacionar:
1. Gerar nova chave: `bin/rails db:encryption:init`.
2. Prepend da nova nos secrets (lista YAML/JSON).
3. Re-cifrar ao longo do tempo (job de re-encryption — fora de escopo).
4. Aposentar a antiga após confirmação.

## Blast radius (aceito no piloto)
Uma chave protege secrets de TODAS as cidades. Chave por cidade está decidida (spec banco por cidade) e é do Plano 6.
