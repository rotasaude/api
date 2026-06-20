# Secrets custody (ADR-0024)

Chaves protegidas em `deploy/<env>/secrets`, nunca em git. Injetadas no boot pelo Kamal.

## Inventário
- `RAILS_MASTER_KEY` — chave mestra do Rails credentials.
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` — cifra `municipality_channels.access_token`, `inbound_messages.raw`, `users.otp_secret`, `conversations.phone`.
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` — cifra `conversations.phone` (deterministic).
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` — derivação de chave.
- `WHATSAPP_APP_SECRET` — HMAC de webhook.
- `ROTA_APP_PASSWORD` / `ROTA_ADMIN_PASSWORD` — senhas dos papéis Postgres.

## Rotação
AR Encryption suporta lista de chaves. Para rotacionar:
1. Gerar nova chave: `bin/rails db:encryption:init`.
2. Prepend da nova nos secrets (lista YAML/JSON).
3. Re-cifrar ao longo do tempo (job de re-encryption — fora de escopo).
4. Aposentar a antiga após confirmação.

## Blast radius (aceito no piloto)
Uma chave protege secrets de TODAS as cidades. Endurecimento futuro: chave por tenant via KMS (fora deste ADR).
