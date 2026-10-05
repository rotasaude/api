Rails.application.routes.default_url_options = {
  host:     ENV.fetch("PUBLIC_HOST", "localhost"),
  port:     ENV.fetch("PUBLIC_PORT", "3000"),
  protocol: ENV.fetch("PUBLIC_PROTOCOL", "http")
}

Rails.application.routes.draw do
  # Console de plataforma (admin.*): operador autentica contra Operator, no banco
  # de plataforma (Operators::SessionsController). Mesmos caminhos da sessão da
  # cidade, para o frontend do admin não mudar de rota. PRECISA vir antes das
  # rotas de cidade: a primeira rota que casa vence.
  constraints(PlatformConsoleHost) do
    scope module: :operators, as: :operator do
      resource :session, only: %i[create show destroy]
      post "/session/challenge", to: "sessions#challenge_totp"
      resources :city_grants, only: :create
      # Provisionamento em duas fases (Plano 4).
      resources :cities, only: %i[index create show]
      # Canal do WhatsApp da cidade (Plano 8). O canal mora na PLATAFORMA e é
      # passo à parte do provisionamento (Plano 4): entra quando a Meta libera o
      # número. Sem ele, Whatsapp::Ingest não acha a cidade pelo phone_number_id.
      resources :cities, only: [] do
        resource :channel, only: :create, controller: "city_channels"
      end
      # Números sem CityChannel vistos pelo webhook (F-01.5): leitura para o
      # operador diagnosticar. Só metadado de roteamento, nunca payload.
      resources :unknown_channels, only: :index
      # Indicadores publicados das cidades (ADR 0025; contratos §2). Só plataforma.
      get "/city_analytics", to: "city_analytics#index"
    end
  end

  # Callback único do gov.br (auth.*, Plano 3B). A cidade vem do state assinado,
  # não do host. Antes das rotas de cidade: a primeira rota que casa vence.
  constraints(PlatformAuthHost) do
    get "/auth/govbr/callback", to: "govbr/callbacks#show"
  end

  # API de manutenção (spec da API de manutenção §3/§5). A rota SÓ existe em
  # development e staging com MAINTENANCE_API_ENABLED=true — e em test, onde os
  # request specs vivem. Em produção não é desenhada, e a chave ligada derruba o
  # boot (config/initializers/01_maintenance_api.rb). PRECISA vir antes das
  # rotas de cidade, como os blocos acima: a primeira rota que casa vence, e
  # /session da cidade não tem constraint de host.
  if MaintenanceApi.enabled?
    constraints(MaintenanceApiHost) do
      scope module: :maintenance, as: :maintenance do
        resource :session, only: %i[create show destroy]
        post "/session/challenge", to: "sessions#challenge_totp"
        post "/invitations/enroll", to: "invitations#enroll"
        post "/invitations/accept", to: "invitations#accept"
        post "/graphql", to: "graphql#execute"
      end
    end
  end

  # Sessão de usuário da cidade (ADR-0011). Operador: bloco do console, acima.
  resource :session, only: %i[create show destroy]

  # Entrada na cidade por grant assinado (Plano 3B): operador vindo do console ou
  # usuário vindo do callback do gov.br.
  post "/session/grant", to: "sessions#grant"

  # Reset de senha (F-06.2, ADR-0011). JSON-only, sem autenticação.
  resources :passwords, only: %i[create update], param: :token

  # MFA — ADR-0011
  post "/mfa/enroll",  to: "mfa#enroll"
  post "/mfa/confirm",   to: "mfa#confirm"
  post "/mfa/step_up",  to: "mfa#step_up"

  # gov.br (ADR-0011): o login começa na cidade; o callback é o de auth.*, acima.
  post "/auth/govbr/start", to: "sessions#govbr_start"

  # Setup multi-tenant — write endpoints (ADR-0012/0013). Não confundir com
  # /admin/api/* que é read-only por critério §10 do brief.
  scope "/setup" do
    post "/invitations",                 to: "setup#invite_member"
    post "/accept_invitation",           to: "setup#accept_invitation"
    post "/memberships",                 to: "setup#grant_role"
    get  "/memberships",                 to: "setup#list_memberships"
    post "/memberships/:id/revoke",      to: "setup#revoke_membership"
    post "/users/:id/deactivate",        to: "setup#deactivate_user"
  end

  # Balcão da UBS: validação presencial do cidadão (spec 2026-09-24). Escrita
  # de servidor da cidade — fora de /admin/api, que é só leitura.
  scope "/attendance" do
    post "lookup",                   to: "attendance#lookup"
    post "verifications",            to: "attendance#verify"
    post "verifications/search",     to: "attendance#search"
    post "verifications/:id/revoke", to: "attendance#revoke"

    # Exclusão do cadastro no balcão (ADR 0026): pedido por um servidor,
    # confirmação por outro, com step-up. O CPF vai no corpo, nunca na URL.
    get  "erasure_requests",             to: "erasure_requests#index"
    post "erasure_requests",             to: "erasure_requests#create"
    post "erasure_requests/:id/confirm", to: "erasure_requests#confirm"
    post "erasure_requests/:id/reject",  to: "erasure_requests#reject"

    # Unidades de saúde e check-in (spec 2026-09-24-citizen-attendance-check-in
    # §4). `units/all` PRECISA vir antes de `units/:id`: a primeira rota que
    # casa vence.
    get  "units",                   to: "health_units#index"
    get  "units/all",               to: "health_units#all"
    post "units",                   to: "health_units#create"
    post "units/:id",               to: "health_units#update"
    post "units/:id/deactivate",    to: "health_units#deactivate"
    post "units/:id/activate",      to: "health_units#activate"
    post "units/:id/drain",         to: "health_units#drain"
    get  "units/:id/queue",           to: "attendances#queue"
    post "units/:id/call_next",       to: "attendances#call_next"
    post "attendances/:id/call",      to: "attendances#call"
    post "check_ins/lookup",        to: "check_ins#lookup"
    post "check_ins",               to: "check_ins#create"
    post "check_ins/search",        to: "check_ins#search"
    post "check_ins/exception",     to: "check_ins#exception"
    post "attendances/:id/close",   to: "attendances#close"

    # Pedidos de agendamento, marcação e agenda do dia (spec 2026-09-25 §4).
    get  "units/:id/requests",         to: "appointment_requests#index"
    get  "units/:id/agenda",           to: "appointment_requests#agenda"
    post "requests/:id/appointments",  to: "appointment_requests#schedule"
    post "requests/:id/dismiss",       to: "appointment_requests#dismiss"
  end

  # Profissionais (ADR 0021; spec 2026-09-27-module-10-professionals §4.1).
  # Prefixo único: uma entrada só no proxy de dev do dashboard. As rotas
  # literais (me, pending, cbo, links, shifts) PRECISAM vir antes de `:id`.
  scope "/professionals" do
    get  "",        to: "professionals#index"
    post "",        to: "professionals#create"
    get  "pending", to: "professionals#pending"
    get  "me",      to: "professionals#me"
    post "me",      to: "professionals#update_me"
    get  "cbo",     to: "professionals#cbo"
    post "links/:id/end", to: "professional_links#end_link"
    post "links/:id/shifts",  to: "professional_shifts#create"
    post "shifts/:id/cancel", to: "professional_shifts#cancel"
    get  ":id",     to: "professionals#show"
    post ":id",     to: "professionals#update"
    post ":id/links",     to: "professional_links#create"
    get  ":id/shifts",        to: "professional_shifts#index"
  end

  # Território (ADR 0023; spec 2026-09-28-module-11-territory §4.1). Prefixo
  # único: uma entrada só no proxy de dev do dashboard.
  scope "/territory" do
    get  "neighborhoods",                to: "territory#index"
    post "neighborhoods",                to: "territory#create"
    post "neighborhoods/:id",            to: "territory#update"
    post "neighborhoods/:id/deactivate", to: "territory#deactivate"
    post "neighborhoods/:id/activate",   to: "territory#activate"
    post "neighborhoods/:id/coverage",   to: "territory#coverage"
  end

  # Campanhas (ADR 0024; spec 2026-09-29 §6.1). Prefixo único: uma entrada só
  # no proxy de dev do dashboard. Rotas literais (options, preview,
  # sms_setting) ANTES de ":id".
  get  "/campaigns", to: "campaigns#index"
  post "/campaigns", to: "campaigns#create"
  scope "/campaigns" do
    get   "options", to: "campaigns#options"
    post  "preview", to: "campaigns#preview"
    get   "sms_setting", to: "campaign_sms_settings#show"
    put   "sms_setting", to: "campaign_sms_settings#update"
    get   ":id",     to: "campaigns#show"
    patch ":id",     to: "campaigns#update"
    post  ":id/send",       to: "campaigns#send_now"
    post  ":id/schedule",   to: "campaigns#schedule"
    post  ":id/unschedule", to: "campaigns#unschedule"
    post  ":id/cancel",     to: "campaigns#cancel"
  end

  # Catálogo de triagens da cidade (ADR 0027; contratos §4). Prefixo próprio:
  # /protocols/:name já captura qualquer segmento.
  get "/triage_catalog",                to: "triage_catalog#index"
  put "/triage_catalog/:protocol_name", to: "triage_catalog#update"

  # Healthcheck — usado pelo Kamal (ADR-0001).
  get "up", to: ->(_env) { [200, {}, ["ok"]] }

  # Webhook do WhatsApp (ADR-0007)
  scope "/webhooks" do
    get  "whatsapp", to: "webhooks/whatsapp#verify"
    post "whatsapp", to: "webhooks/whatsapp#create"
  end

  # Relatório público (ADR-0010)
  get "/r/:token", to: "reports#show", as: :report

  # Canal web do cidadão (spec 2026-09-22-web-citizen-channel). Servido no host
  # da cidade, como o relatório; sessão própria por cookie `citizen_session`.
  scope "/citizen", module: "citizen_api", as: "citizen" do
    post   "otp",     to: "otps#create"
    post   "session", to: "sessions#create"
    get    "session", to: "sessions#show"
    delete "session", to: "sessions#destroy"

    get  "consent_term",               to: "consent_terms#show"
    get  "people",                     to: "people#index"
    post "people",                     to: "people#create"
    post "people/:id/profile",         to: "people#profile"
    get  "people/:id/catalog",         to: "people#catalog"
    post "people/:id/neighborhood",    to: "people#neighborhood"
    get  "neighborhoods",              to: "neighborhoods#index"
    post "conversations",              to: "conversations#create"
    post "conversations/:id/answers",  to: "conversations#answer"
    post "conversations/:id/undo",     to: "conversations#undo"
    get  "triages",                    to: "triages#index"
    get  "triages/:id",                to: "triages#show"
    post "triages/:id/revoke_consent", to: "triages#revoke_consent"
    post "triages/:id/check_in_code",  to: "check_in_codes#create"
    post "verification_codes",         to: "verification_codes#create"

    get  "appointments",                   to: "appointments#index"
    post "appointments/:id/confirm",       to: "appointments#confirm"
    post "appointments/:id/cancel",        to: "appointments#cancel"
    post "appointments/:id/check_in_code", to: "appointments#check_in_code"

    get  "notices",          to: "notices#index"
    post "notices/:id/read", to: "notices#read"

    get "contact_preferences",             to: "contact_preferences#index"
    put "contact_preferences/:citizen_id", to: "contact_preferences#update"
  end

  # Autoria/preview de protocolos (ADR-0009)
  scope "/protocols" do
    get  ":name",         to: "protocols#show",    as: :protocol
    post ":name/preview", to: "protocols#preview", as: :protocol_preview
    post ":name/gate",    to: "protocols#gate",    as: :protocol_gate
  end

  # Autoria de protocolo (editor do dashboard) — sessão municipal + banco da cidade + author.
  # Escrita NÃO entra em /admin/api (read-only §10). Ver F-03.12.
  scope "/authoring/protocols" do
    get  "definition", to: "authoring/protocols#definition"
    post "gate",    to: "authoring/protocols#gate"
    post "preview", to: "authoring/protocols#preview"
    post "draft",   to: "authoring/protocols#draft"
    post "simulate_offer", to: "authoring/protocols#simulate_offer"
  end

  # Publicação de protocolo — exige step-up MFA (ADR-0011 + ADR-0009)
  post "/protocols/:version/publish", to: "publications#create"

  # Ciclo de vida com assinaturas (spec de assinaturas, ADR-0016). `name` vai no corpo.
  constraints(version: /\d+/) do
    post "/protocols/:version/submit",     to: "protocol_lifecycle#submit"
    post "/protocols/:version/signatures", to: "protocol_lifecycle#sign"
    post "/protocols/:version/activate",   to: "protocol_lifecycle#activate"
    post "/protocols/:version/retire",     to: "protocol_lifecycle#retire"
  end
  post "/protocols/revert", to: "protocol_lifecycle#revert"

  # Tela de manutenção: lista a configuração de todas as cidades registradas,
  # SEM autenticar ninguém. Ferramenta de desenvolvimento e teste.
  #
  # O `if` é a guarda inteira, e é de propósito que ele esteja AQUI e não num
  # before_action: fora de development a rota não é desenhada, então o Rails
  # responde 404 no roteador, sem depender de nenhum controller lembrar de
  # negar. Uma rota que existe e recusa está a um refactor de distância de uma
  # rota que existe e aceita — um skip_before_action mal colocado, uma troca de
  # superclasse. Uma rota que não existe não tem esse caminho.
  #
  # spec/architecture/maintenance_route_spec.rb prova a ausência em test.
  if Rails.env.development?
    get "/maintenance", to: "maintenance#index"

    # Abre sessão de municipal_admin da cidade do host, SEM credencial, e manda
    # para o dashboard. Casada com a tela acima, que é quem oferece o link.
    #
    # Fica no host da CIDADE (nenhuma constraint de host aqui, então o
    # CityResolution do ApplicationController resolve pelo subdomínio), porque o
    # cookie de sessão é host-only: gravado em localhost não valeria em
    # curitiba.localhost. Ver Dev::ImpersonationsController.
    #
    # GET por ser um link clicável na tela — o que é aceitável SÓ porque a rota
    # não existe fora de development. A ação checa Rails.env.development? de
    # novo: se esta linha um dia escapar do `if`, a segunda guarda ainda recusa.
    get "/dev/impersonate", to: "dev/impersonations#create"

    # Impersonate de OPERADOR, no host do console. Constrained a admin.* porque
    # é lá que o cookie de operador precisa ser gravado — e porque a rota não
    # tem o que fazer num subdomínio de cidade.
    #
    # Mais forte que o de cidade: carimba mfa_verified_at sem TOTP nenhum. Além
    # desta constraint e do `if` acima, Operators::BaseController ainda recusa
    # host que não seja o console, e a ação checa o ambiente de novo.
    constraints(PlatformConsoleHost) do
      get "/dev/impersonate_operator", to: "dev/operator_impersonations#create"
    end
  end

  # Admin Console — namespace read-only (ADR-0002, brief §6).
  # NENHUMA rota de escrita pode ser adicionada aqui (critério §10).
  namespace :admin do
    namespace :api do
      get "overview",        to: "overview#show"
      get "ingestion",       to: "ingestion#show"
      get "conversations",   to: "conversations#show"
      get "consent",         to: "consent#show"
      get "triages",         to: "triages#show"
      get "triages/:id/trail", to: "triages#trail"
      get "reports",         to: "reports#show"
      get "classification",  to: "classification#show"
      get "protocols",       to: "protocols#index"
      get "protocols/:id",   to: "protocols#show"
      get "queues",          to: "queues#show"
      get "events",          to: "events#show"
      get "health",          to: "health#show"
      get "municipalities",  to: "municipalities#index"
      get "neighborhoods",   to: "neighborhoods#index"
      # Analytics (ADR 0025; contratos §1): só leitura, sem grant de operador.
      get "analytics/:front", to: "analytics#show", constraints: { front: /demand|quality|calibration|epidemiology/ }
    end
  end
end
