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
| `CITY_PUBLIC_BASE_TEMPLATE` | `http://%{slug}.localhost:5175` | host público de cada cidade: dashboard, wpda e link de reset de senha |

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
(mesma senha + TOTP) no console. Hosts de dev: `curitiba.localhost:5175`, `maringa.localhost:5175` (dashboard), `admin.localhost:5174` (console),
`curitiba.localhost:5176` (wpda). O proxy do Vite repassa o Host (Plano 6), então o Rails resolve a cidade pelo
subdomínio como em produção. `*.localhost` resolve para 127.0.0.1 no Chrome e no Firefox sem `/etc/hosts`; no Safari,
acrescente uma linha por cidade.

Em desenvolvimento o dev server do Vite responde CORS por conta própria pra qualquer origem `.localhost` — um teste de
CORS pelo browser nas portas 5174/5175/5176 não prova nada sobre a política do Rails. Para testar a política de
verdade, chame a API direto: `curl -H "Host: <slug>.localhost:5175" -H "Origin: http://<slug>.localhost:5175" http://localhost:3030/session`. Sem equivalente em produção (um host só serve API e proxy).

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
O destino de volta usa `CITY_PUBLIC_BASE_TEMPLATE` (default `http://%{slug}.localhost:5175`), com `/dashboard/`.

## Hosts publicados (Plano 6)

O proxy do Kamal publica quatro hosts: o da API (`api.*`), o console (`admin.*`), o callback do gov.br (`auth.*`) e o
curinga das cidades (`*.<domínio>`). Uma cidade provisionada passa a atender sem deploy novo — quem decide é o
`CityCatalog`, pelo Host da requisição.

**Gate de go-live (o deploy FALHA até isso ser resolvido).** Com `ssl: true` e a entrada `*.<domínio>` em
`proxy.hosts`, o kamal-proxy tenta emitir certificado Let's Encrypt para o nome literal do curinga via HTTP-01 a cada
deploy — e o Let's Encrypt só emite curinga por DNS-01. O deploy não degrada em silêncio: ele quebra com erro de ACME.
Duas saídas, escolha antes do primeiro deploy de produção:

1. **Sem curinga:** tire a linha `"*.<domínio>"` e liste cada host de cidade explicitamente em `proxy.hosts`. Cada
   cidade nova exige editar o arquivo e rodar `kamal proxy reboot` — simples, mas o provisionamento deixa de ser
   self-service.
2. **Com curinga:** emita o certificado curinga por fora (DNS-01, no provedor de DNS), monte-o no kamal-proxy e
   desligue o ACME para esses hosts. O provisionamento segue sem deploy, ao custo de renovação própria do certificado.

O registro DNS `*.<domínio>` apontando para os hosts web é necessário nos dois casos.

**O que esses hosts servem hoje.** O proxy do Kamal publica esses hosts para a aplicação Rails, que serve só a API —
não há pipeline de build nem servidor para as três SPAs (`apps/admin`, `apps/dashboard`, `apps/wpda`). Em produção,
`admin.<domínio>/admin/` e `<slug>.<domínio>/dashboard/` (e `/wpda/`) não têm nada atrás deles ainda. O Plano 6 faz a
jornada funcionar em desenvolvimento (Vite serve os três, o proxy do Vite repassa o Host); servir os frontends em
produção continua em aberto.

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

**Primeiro corte do Plano 5 (runbook único).** Este é o corte que troca o worker compartilhado por `bin/city_workers`
e aposenta o banco compartilhado. Ordem obrigatória:

1. Rode `bin/migrate` ANTES do `kamal deploy` e exija saída `0`. Se alguma cidade falhar a migração, suspenda essa
   cidade (`rails 'city:suspend[slug]'`) antes de seguir com o deploy.
   - Por quê: o webhook do WhatsApp (`Whatsapp::Ingest`) já tem guarda de schema atrasado — uma cidade cujo
     `CitySchema.behind?` for verdadeiro não grava nada (nem `InboundMessage`, nem enqueue), e o POST inteiro responde
     `503 city_schema_behind`, levando a Meta a reentregar o lote dentro da janela limitada de reentrega da Meta. O
     gate de `bin/migrate` continua obrigatório mesmo assim: uma cidade que fica atrasada além dessa janela perde as
     mensagens em vez de simplesmente estar em dia.
   - Uma cidade `suspended` já é descartada silenciosamente pelo mesmo `Whatsapp::Ingest.route` (200, sem gravar) —
     comportamento existente, não deste corte.
2. Drene a fila compartilhada aposentada antes da virada:
   - pare de mandar tráfego novo para o worker antigo, ou deixe-o ocioso;
   - espere o banco compartilhado antigo zerar as três tabelas de execução pendente (leitura, no banco
     `rota_saude_<env>` antigo):
     ```sql
     select count(*) from solid_queue_ready_executions;
     select count(*) from solid_queue_scheduled_executions;
     select count(*) from solid_queue_claimed_executions;
     ```
   - só com as três em `0`, substitua o worker antigo por `bin/city_workers`.
3. Rollback: uma imagem anterior ao Plano 5 só sobe se os secrets `DATABASE_URL` e `ROTA_ADMIN_PASSWORD` forem
   restaurados (nomes das variáveis — nunca os valores aqui).

**Suspender, backup, desligar** (rake; em produção no papel worker):

- `rails 'city:suspend[slug]'` → o host responde 403 em até 30 s. `rails 'city:resume[slug]'` desfaz.
- `rails 'city:backup[slug]'` → `pg_dump` da cidade em `CITY_BACKUP_DIR`. **Não** é restaurável sozinho com
  `pg_restore --no-owner` desde a chave de cifra por cidade (Plano 7) — o dump carrega ciphertext derivado do
  `encryption_key` da cidade no momento do dump; ver o aviso "Restaurar um dump" na seção do Plano 7 abaixo antes de
  restaurar qualquer coisa.
- `CONFIRM=<slug> rails 'city:offboard[slug]'` (IRREVERSÍVEL, só cidade suspensa) → dump final, canais inativos,
  `archived`, `DROP DATABASE` e `DROP ROLE`. Recusa (`suspension_too_recent`) até 60 s depois do `city:suspend` — duas
  vezes o TTL de 30 s do cache do catálogo, para os outros processos pararem de servir a cidade antes do dump. Se a
  cidade for retomada durante o dump, nada é apagado (`invalid_status`) e o dump fica.
- `curitiba` e `maringa` (criadas por `city:dev_up`, banco do superusuário) não são apagáveis pelo `rota_provisioner`.

**Purga.** Diariamente, `PurgePlatformAccessJob` apaga grants vencidos há mais de 1 dia e sessões de operador que não
autenticam mais. `PurgeOperatorCitySessionsJob` apaga, em cada cidade, as sessões de operador por grant além de 1 hora.

## Chave de cifra por cidade (Plano 7)

Cada cidade cifra os próprios dados com uma chave **derivada** de `chave da plataforma + cities.encryption_key`.

- **Dá:** ciphertext de uma cidade não é legível nem comparável com o de outra; um dump roubado sozinho não abre nada;
  o mesmo telefone em duas cidades tem ciphertext diferente em cada uma.
- **Não dá:** isolamento contra quem tem a chave da plataforma — ela deriva todas. `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
  e `..._DETERMINISTIC_KEY` são os segredos de maior valor do sistema: custódia separada, rotação própria, acesso restrito.

Atributos determinísticos (`Conversation#phone`, `Author#token`) usam `CityDeterministicKeyProvider`, que resolve a chave
pela cidade em `Current.city` a cada operação — o contexto de cifra do Rails não alcança esse caso. Ler ou escrever esses
atributos fora de `CityConnection.with` levanta `CityEncryption::MissingKey`, de propósito. Colunas de plataforma
(`City#database_url`, `City#encryption_key`, `CityChannel#access_token`, `Operator#otp_secret`) ficam fixas na chave
global (`key_provider: PlatformKeyProvider.new`) e o contexto de uma cidade não as alcança.

São dois procedimentos diferentes, com ORIGENS diferentes — não confunda:

**Migrar** (uma vez por cidade, para sair da chave global): origem é a **plataforma**. Dado escrito antes deste plano está
cifrado com a chave global e, depois que o código passou a derivar por cidade, não é legível pelos modelos até a migração
rodar (provado ao vivo em `curitiba` e `maringa`: antes do `city:rekey`, `Conversation#phone` e `InboundMessage#raw`
levantavam `Errors::Decryption` sob o contexto de cidade e decifravam sob a chave global).

```bash
rails 'city:backup[slug]'
rails 'city:suspend[slug]'
rails 'city:rekey[slug]'
rails 'city:resume[slug]'
```

**Rotacionar** (vazamento suspeito ou política): origem é o **material anterior da própria cidade**, e o comando gera
material novo — grava no catálogo — antes de reescrever.

```bash
rails 'city:backup[slug]'
rails 'city:suspend[slug]'
rails 'city:rotate_key[slug]'
rails 'city:resume[slug]'
```

Ambas as tasks recusam cidade que não esteja `suspended` (`status=<status atual>` na mensagem). A cidade precisa estar
suspensa porque, entre ler uma linha com o material antigo e gravá-la com o novo, uma busca determinística de outro
processo (webhook, job) usaria a chave errada e não acharia a linha.

Suspensão sozinha **não basta**: `CityCatalog.reset_cache!` só limpa o cache deste processo, e os outros processos web
continuam servindo a cidade como ativa — com o objeto `City` de ANTES do rekey/rotação — por até
`CityCatalog::CACHE_TTL`. Por isso ambas as tasks também recusam (`aguarde <n> s depois do city:suspend`) enquanto a
suspensão for mais nova que `CityLifecycle::SuspensionGuard::QUIET_PERIOD` (o TTL duas vezes). Sem essa espera, uma
escrita determinística feita por um processo que ainda acha a cidade ativa, sob o material antigo, cria uma segunda
linha em vez de colidir com o índice único — e não levanta erro nenhum. É suspensão **mais** este período de espera
que exclui os outros processos, não a suspensão isolada.

Se a leitura da origem falhar — chave errada, cidade já migrada, dado corrompido — `CityRekey` devolve `:unreadable`
("linha ilegível com o material de origem") e a task aborta.

Se a reescrita falhar, ela falha **inteira**: `CityRekey` roda numa transação única (`ApplicationRecord.transaction`,
na conexão da própria cidade), então ou todas as linhas mudam ou nenhuma muda. É isso que torna a falha segura — e não o
fato de `city:rotate_key` devolver o material anterior ao catálogo, que é só a limpeza do ponteiro (a rotação grava o
material novo no catálogo ANTES de reescrever qualquer linha, e sem essa devolução o catálogo ficaria apontando para uma
chave que os dados não usam). Se essa devolução automática também falhar, `city:rotate_key` **não tenta de novo nem
segue em frente**: aborta com uma mensagem dizendo que os dados estão intactos (a transação já desfez tudo) mas o
catálogo aponta para o material novo — corrija o `encryption_key` da cidade manualmente antes de rodar `city:rekey` ou
`city:rotate_key` nela outra vez.

> **Restaurar um dump.** Não existe `city:restore` ainda. Um dump só é restaurável **na cidade de origem, com a
> `encryption_key` dela intacta** — o dump carrega ciphertext. Restaurar numa cidade cujo catálogo tem outro material
> (rotacionado depois do dump, ou de outra cidade) **devolve dado ilegível sem erro** — nada no `pg_restore` nem no
> boot avisa. Antes de restaurar, confirme que a linha do catálogo é a mesma de quando o dump foi tirado; guarde essa
> informação junto do arquivo.

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
  nova começa a processar em até 30 s; cidade suspensa, arquivada ou com schema atrasado para em até 30 s. Uma cidade
  com schema atrasado não tem supervisor: os jobs dela simplesmente esperam no banco DELA até o próximo poll depois da
  migração terminar — não é o retry de `CitySchemaBehind` (5 min × 12 tentativas = até 1 hora) que os faz esperar; esse
  retry só importa na corrida em que um job já começou a rodar entre a migração terminar e o próximo poll do gerente.
- **Falha** — supervisor que morre é reiniciado com espera de 1 s, 2 s, 4 s… até 5 min; volta a 1 s depois de 10 min
  de pé. Log em dev: `docker compose exec worker tail -f log/development.log | grep city_workers`. Em produção o log
  vai para STDOUT: `kamal app logs -r worker -f | grep city_workers`. Um filho que não sobe (banco fora do ar, cidade
  indisponível) escreve uma linha só no stderr, sem stack trace — visível em `docker compose logs worker` (dev) ou
  `kamal app logs` (produção).
- **Parada** — TERM/INT repassa TERM aos supervisores, espera `SolidQueue.shutdown_timeout` + 5 s e mata o grupo de
  processo de quem sobrar.
- **Dimensionamento** — ~6 processos por cidade (supervisor, dispatcher, scheduler e os 3 workers de
  `config/queue.yml`). `RAILS_MAX_THREADS` do worker precisa ser ≥ maior `threads` de `config/queue.yml` + 2 (Kamal:
  12). Um host de worker roda todas as cidades; mais de um host duplica supervisores por cidade (seguro, mas dobra
  processos).
  - **Orçamento de conexões por cidade** (aproximado, derivado de `config/queue.yml`, `config/puma.rb` e
    `deploy/production/deploy.yml` — não confunda com os `deploy/*/deploy.yml` em si, que este runbook não altera):
    - **Web** — cada host roda `WEB_CONCURRENCY` processos Puma (Kamal: `2`), cada um com `RAILS_MAX_THREADS` threads
      (Kamal: `5`) e pools para plataforma + cache + 2 por cidade servida (domínio e fila, via
      `CityConnection.with`): `hosts × WEB_CONCURRENCY × RAILS_MAX_THREADS × (2 + 2 × cidades)`. Com 2 hosts e as 2
      cidades ativas de hoje: `2 × 2 × 5 × (2 + 4) ≈ 120` conexões, pico.
    - **Worker por cidade** — cada um dos ~6 processos do supervisor segura, no pico, 4 pools: o padrão do
      `SolidQueue::Record` e o pool do shard do Solid Queue (os dois no banco DA CIDADE, um trocado pelo
      `CityWorkers::Child`, o outro registrado por `CityConnection.ensure_pool`), o pool do `CityRecord` (banco da
      cidade) e o pool do `PlatformRecord` (catálogo/canais). Somando as threads de produção de `config/queue.yml`
      (`urgent` 5 + `realtime,default` 10 + `reports,housekeeping` 3, mais dispatcher e scheduler) dá ~20 threads por
      cidade: `4 pools × ~20 ≈ 80` conexões por cidade ativa, pico.
    - Com as 2 cidades ativas de hoje isso já soma **~280 conexões** (web + worker) contra o `max_connections`
      DEFAULT do Postgres, que é **100**.
    - **Gate de go-live:** antes de ir para produção, dimensione o `max_connections` do acessório Postgres (e/ou um
      `CONNECTION LIMIT` por role — `rota_platform`, `rota_app`, cada `rota_city_<slug>`) para o número de cidades
      planejado. Isso exige reboot do acessório.
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
