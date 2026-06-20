# Admin Console — Reconcile (brief vs schema real) e notas de PR

> Fase 1 read-only. Endpoints sob `/admin/api/*`. Brief: `apps/dashboard/design_handoff_admin_console 4/00_PROMPT_CLAUDE_CODE.md`.
> Critérios de aceite atendidos: §10.

## Resumo

- **13 rotas GET** registradas em `config/routes.rb` sob o namespace `Admin::Api::`.
- **Nenhuma rota de escrita** (validado por teste — `smoke_test.rb`).
- **Allowlist LGPD** verificada por teste com sentinelas em `inbound_messages.raw`,
  `triagens.answers` e `consents.evidence` (validado por teste — `lgpd_allowlist_test.rb`,
  66 assertivas em 11 endpoints).
- **Auth real** via cookie de sessão HttpOnly (ADR-0022). User + Session
  models, `SessionsController` JSON-only. Stub `Author.token` extinto neste
  namespace.
- Suite: `4 runs, 114 assertions, 0 failures, 0 errors`.

## Como rodar

```bash
docker compose exec -e RAILS_ENV=test \
  -e DATABASE_URL='postgres://rota_saude:postgres@host.docker.internal:5432/rota_saude_test' \
  api bin/rails test
```

## Decisões honestas — brief assume colunas que não existem

| § brief | Brief assume | Schema real (`db/schema.rb`) | Como tratamos | Candidato a |
|---|---|---|---|---|
| §4.1 | `inbound_messages.status` (ack/erro) | só `created_at,from,kind,message_id,raw` | `ack[]` aproximado por `outbound_messages.status` | projeção `ingestion_metrics` (ADR 0007) |
| §4.1 | `inbound_messages.processed`, `raw_purged_at` (backlog LGPD) | não existem | `purge.pending` = count(idade > 24h); `oldestH` = (now - min(created_at))/1h | projeção `purge_backlog` ou colunas (ADR 0011) |
| §4.1 | `dedup` count | não persistido | `dedup: null` | métrica em projeção |
| §4.2 | `conversations.status` ∈ awaiting_consent/in_progress/completed/declined/cancelled/abandoned | enum real: `greeting/awaiting_consent/consented/revoked` | funil remapeado pros estados reais; `exits` só `revoked`; `abandonRate: null` | nova FSM ou projeção |
| §4.2 | `consent_version`, `protocol_version` em conversations | não existem | omitido — dado vem por join de `consents.version` / `triagens.protocol_definition.version` | denormalização opcional |
| §4.3 | `consents.status` (given/revoked/**declined**) | só `version` + `revoked_at` | `given` = `revoked_at IS NULL`; `revoked` = `revoked_at IN período`; `declined: null` | sinal `consent.declined` em domain_events |
| §4.5 | `outcome.scoring.mode` (weighted/decision_table) | jsonb existe mas conteúdo é opcional | `byMode` lê `outcome->'scoring'->>'mode'`, vazio se não houver | nada — depende do scorer popular |
| §4.6 | `created_by`/`published_by` por versão (quatro-olhos) | `ProtocolDefinition` não tem essas colunas | lemos de `domain_events.payload['actor']` para `protocol.created`/`protocol.published`; `fourEyes: null` quando ausentes | colunas em `protocol_definitions` (ADR 0016) |
| §4.7 | nomes Solid Queue da versão | confirmados via `db/schema.rb` (`ready_executions`/`scheduled_executions`/`failed_executions`/`recurring_tasks`/`recurring_executions`) | usados via `SolidQueue::` AR models | — |
| §4.8 | `domain_events.municipality_id` | **não existe** (só `aggregate_type+aggregate_id`) | **CROSS-TENANT** até ter coluna/projeção. Documentado em `Admin::Scoped#domain_events` | coluna `municipality_id` em `domain_events` ou projeção `events_by_muni` |
| §4.1 | `inbound_messages.municipality_id` | **não existe** | **CROSS-TENANT** até ter sinal. Documentado em `Admin::Scoped#inbound_messages` | coluna ou projeção |
| §2.4 | RBAC, sessão real | ~~apenas `Author.token` (stub)~~ → **resolvido em ADR-0022** | Rails 8 native auth: `User` + `Session`, cookie HttpOnly. `Admin::Api::BaseController` inclui `Authentication` concern; `require_authentication` é before_action. | RBAC (roles) quando entrar mutação na Fase 2 |
| §2 | `current_user`, `current_municipality` | agora vivo | `current_user` via `Current.session.user`; `current_municipality` resolvido por `User#municipality` | — |
| §2 | cross-tenant superadmin (`?municipality_id=all`) | sem flag em User | `cross_tenant?` retorna `false` por enquanto → `municipality_id=all` ignorado silenciosamente | coluna/flag em User (ADR-0020 quando precisar) |

## Source por métrica (live vs proj)

Hoje **tudo é `source: "live"`** — a projeção `dashboard_metrics` existe mas
está vazia em dev e nenhum endpoint depende dela ainda. Cada KPI/painel
carrega o campo `source` no payload (parte do contrato). Quando uma
projeção for habilitada, troque para `"proj"` no query object correspondente
e adicione o `updated_at` da projeção como `as_of` do bloco.

## Índices: assumidos × faltantes

> Marcar no PR. **Não criar projeção nova aqui** — vira ADR.

| Tabela | Índice assumido pela query | Existe? | Sustenta |
|---|---|---|---|
| `triagens` | `(conversation_id, created_at)` | ✅ | join+período |
| `triagens` | `(status)` | ✅ | KPI `done`, `completion` |
| `triagens` | `(status, created_at)` | ✅ | série `done` |
| `triagens` | `(tier)` | ✅ | classification.tiers |
| `triagens` | `(priority)` | ❌ **falta** | KPI `priority` + `priorityTrend` |
| `triagens` | `(municipality_id, created_at)` (denormalizado) | ❌ — não há coluna | escopo multi-tenant via join é OK por enquanto |
| `conversations` | `(municipality_id)` | ✅ | escopo |
| `conversations` | `(state)` | ✅ | funil |
| `conversations` | `(municipality_id, state, updated_at)` | ❌ **falta** | KPI `active` (overview) |
| `consents` | `(conversation_id, revoked_at)` partial unique | ✅ | join+revogados |
| `consents` | `(given_at)` | ✅ | série `consent` |
| `consents` | `(version)` | ❌ **falta** | `byVersion` breakdown |
| `inbound_messages` | `(created_at)` | ✅ | série + purge |
| `dashboard_metrics` | `(municipality_id, dimension, period, key)` unique | ✅ | leitura projeção |
| `domain_events` | `(name)`, `(occurred_at)` | ✅ | filtro + janela |
| `domain_events` | `(aggregate_type, aggregate_id)` | ✅ | trail por triagem + protocolo |
| `protocol_definitions` | `(name, version, municipality_id)` unique | ✅ | listagem |
| `report_snapshots` | `(triagem_id)` unique | ✅ | health drift |
| `solid_queue_*` | conforme gem | ✅ (gem-provided) | queues |

**Sugestão de migration** (não incluída neste PR — agrupar em PR de índices):

```ruby
add_index :triagens, :priority, where: "priority = true"
add_index :consents, :version
add_index :conversations, [ :municipality_id, :state, :updated_at ]
```

## Limitação honesta — painel de filas (§5 do brief)

`/admin/api/queues` enxerga apenas falhas **observáveis** (`failed_executions`).
O **bug de idempotência** (§1.2/§6.1) — `processed_events` gravado **antes**
do efeito — produz no-op silencioso que **parece sucesso e nunca chega a
`failed_executions`**. **Fila verde ≠ entrega garantida.** Essa ressalva fica
no centro de notificações do frontend (`Limitações conhecidas`, sempre
visível) — não duplicada no backend.

## Dependências e riscos (carregar para frente, §9 do brief)

1. ~~ADR de auth pendente — bloqueio para produção.~~ **Resolvido em
   [ADR-0022](../../docs/adr/0022.md)**: Rails 8 native auth (User + Session,
   cookie HttpOnly). Ver `app/controllers/sessions_controller.rb` e
   `app/controllers/concerns/authentication.rb`. **Próximos**: MFA, rate
   limiting (rack-attack), reset de senha (depende de ADR de mailer).
2. **Monitoramento/alerta de fila** sem ADR (§2.2 do brief). Painel só lê;
   plantão/escalonamento é decisão à parte.
3. **Idempotência (§1.2/§6.1)** — limita o painel de filas (acima). Não
   resolvível na camada de visualização.
4. **Projeções novas = ADR de read-side (ADR 0007).** Os campos null acima
   (`dedup`, `abandonRate`, `declined`) viram projeção quando alguém
   decidir os sinais de origem.
5. **`domain_events.municipality_id`** ausente → endpoints `/events`,
   `/triages/:id/trail` e o lookup de quatro-olhos em `/protocols` ficam
   cross-tenant. Isolar por município exige coluna ou projeção.
6. **Bind mount duplicado em dev** — durante esta sessão foi descoberto que
   o `docker compose` monta `/Users/eduardovrocha/Development/ioit.solutions/rota-saude/apps/api`,
   não `/Users/eduardovrocha/rota-saude/apps/api`. A segunda cópia é stale.
   Considerar adicionar `name:` único ao compose ou consolidar repos.

## Arquivos adicionados

```
app/controllers/admin/api/
├── base_controller.rb              ← auth stub, scope, envelope { data, as_of }
├── invalid_scope.rb                ← exceção tipada
├── period.rb                       ← today/7d/30d/custom em America/Sao_Paulo + buckets
├── overview_controller.rb          ← §4.0
├── ingestion_controller.rb         ← §4.1
├── conversations_controller.rb     ← §4.2
├── consent_controller.rb           ← §4.3
├── triages_controller.rb           ← §4.4 + #trail (§4.5b)
├── classification_controller.rb    ← §4.5
├── protocols_controller.rb         ← §4.6 (#index, #show)
├── queues_controller.rb            ← §4.7
├── events_controller.rb            ← §4.8
├── health_controller.rb            ← §4.9
└── municipalities_controller.rb    ← seletor de escopo

app/queries/admin/
├── scoped.rb                       ← helpers de multi-tenancy por modelo
├── overview_query.rb
├── ingestion_query.rb
├── conversations_query.rb
├── consent_query.rb
├── triages_query.rb
├── triage_trail_query.rb
├── classification_query.rb
├── protocols_query.rb
├── queues_query.rb
├── events_query.rb
└── health_query.rb

test/
├── test_helper.rb                  ← bootstrap Minitest
└── controllers/admin/api/
    ├── smoke_test.rb               ← 3 testes (auth, envelope, sem rotas de escrita)
    └── lgpd_allowlist_test.rb      ← sentinelas em raw/answers/evidence

config/routes.rb                    ← namespace Admin::Api adicionado (somente GET)
```
