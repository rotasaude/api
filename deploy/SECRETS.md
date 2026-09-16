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
- `report_signing_key` — NÃO fica em `deploy/<env>/secrets`: mora em `config/credentials.yml.enc`, protegido pelo
  `RAILS_MASTER_KEY` acima. Desde a Task 6 (Plano 8), a chave HMAC efetiva do token de relatório (`ReportSnapshot.sign`)
  é DERIVADA deste valor global com o `cities.encryption_key` da cidade (`CityEncryption.report_signing_key`) — a
  mesma composição usada para cifra (ver README.md § Material de cifra). Quem restaura um dump de cidade precisa dos
  dois: este valor global **e** o `cities.encryption_key` daquela cidade **da época do dump** — sem os dois juntos,
  as assinaturas dos `report_snapshots` do dump não conferem contra a derivação atual. Diferente de dado cifrado
  (ciphertext errado decifra em lixo, sem erro), uma assinatura HMAC com chave errada simplesmente NÃO confere —
  falha fechada, visível — mas ainda assim invalida o link de relatório do cidadão até alguém rodar
  `city:resign_reports` (ou equivalente) com o material certo. **Ressalva temporária:** enquanto durar a transição
  aberta pela migração desta chave, `ReportSnapshot.signature_matches?` ainda aceita a assinatura LEGADA — só o
  valor global, sem derivar com `cities.encryption_key` (`app/models/report_snapshot.rb:30`,
  `CityEncryption.legacy_report_signing_key`). Então um snapshot antigo de um dump pode conferir com só o valor
  global, mesmo sem o `encryption_key` certo da cidade — mas só enquanto esse fallback existir. Ele está documentado
  para sair de cena (ver `report_snapshot.rb`) depois que todo snapshot vivo tiver sido re-assinado com a chave por
  cidade; a partir daí, os dois materiais (global + `encryption_key` da época) voltam a ser estritamente
  necessários, sem essa via alternativa.

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
dados cifrados com as chaves de AR Encryption acima **e** com o `cities.encryption_key` daquela cidade (chave por
cidade, Plano 7 — ver README.md): as duas coisas são necessárias para restaurar, não só as chaves de AR Encryption.
Desde a Task 6 (Plano 8), o mesmo par vale para as assinaturas de `report_snapshots` do dump: `report_signing_key`
(item acima, em `config/credentials.yml.enc`) **e** o `cities.encryption_key` da cidade daquela época são os dois
necessários para que os links de relatório do dump voltem a conferir depois de uma restauração. Guardar o dump sem as
chaves de AR Encryption OU sem o `encryption_key` da cidade não permite restaurar — e, se o
`encryption_key` da cidade já tiver mudado (rekey/rotação depois do dump), restaurar devolve dado ilegível **sem
erro nenhum** (ver "Restaurar um dump" em README.md).

## Rotação

**O procedimento abaixo NÃO se aplica mais e não deve ser tentado a partir deste documento.** Ele descrevia rotação
de chave de plataforma por lista (`config.previous`/prior_keys) — válido antes da chave por cidade (Plano 7). Desde
Plano 7, `CityEncryption` monta o provider de cada cidade a partir de **uma única** chave de plataforma
(`config.active_record.encryption.primary_key`/`deterministic_key`, sem lista) derivada com o `cities.encryption_key`
daquela cidade; o código nunca consulta `config.previous`. Prepender uma chave nova nos secrets, como o passo 2 abaixo
descrevia, mudaria a derivação de TODAS as cidades ao mesmo tempo e tornaria toda linha cifrada existente ilegível
imediatamente — e `ReencryptionJob` (re-cifra sob a chave atual, não entre duas chaves) não conseguiria ler o
ciphertext antigo para migrar nada. Rotação da chave de plataforma agora exige uma passagem de rekey por cidade
(`CityRekey`, `city:rotate_key`/uma variante equivalente por cidade) — desenhar esse procedimento é um plano futuro,
não este documento.

Passos históricos (pré-Plano-7, nenhum vale mais — mantidos só como referência do que este documento chegou a dizer):
1. ~~Gerar nova chave: `bin/rails db:encryption:init`.~~
2. ~~Prepend da nova nos secrets (lista YAML/JSON).~~
3. ~~Re-cifrar ao longo do tempo (job de re-encryption — fora de escopo).~~
4. ~~Aposentar a antiga após confirmação.~~

## Blast radius (aceito no piloto)
Uma chave protege secrets de TODAS as cidades. Chave por cidade está decidida (spec banco por cidade) e foi
implementada no Plano 7 (`cities.encryption_key` por cidade, derivação em `CityEncryption` — ver README.md).
