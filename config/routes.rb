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
    end
  end

  # Callback único do gov.br (auth.*, Plano 3B). A cidade vem do state assinado,
  # não do host. Antes das rotas de cidade: a primeira rota que casa vence.
  constraints(PlatformAuthHost) do
    get "/auth/govbr/callback", to: "govbr/callbacks#show"
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
    get  "/memberships",                 to: "setup#list_memberships"
    post "/memberships/:id/revoke",      to: "setup#revoke_membership"
    post "/users/:id/deactivate",        to: "setup#deactivate_user"
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
