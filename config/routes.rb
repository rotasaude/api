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
    get  "verifications",            to: "attendance#index"
    post "verifications/:id/revoke", to: "attendance#revoke"
  end

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
    post "conversations",              to: "conversations#create"
    post "conversations/:id/answers",  to: "conversations#answer"
    post "conversations/:id/undo",     to: "conversations#undo"
    get  "triages",                    to: "triages#index"
    get  "triages/:id",                to: "triages#show"
    post "triages/:id/revoke_consent", to: "triages#revoke_consent"
    post "verification_codes",         to: "verification_codes#create"
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
    end
  end
end
