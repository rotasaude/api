Rails.application.routes.default_url_options = {
  host:     ENV.fetch("PUBLIC_HOST", "localhost"),
  port:     ENV.fetch("PUBLIC_PORT", "3000"),
  protocol: ENV.fetch("PUBLIC_PROTOCOL", "http")
}

Rails.application.routes.draw do
  # Sessão de admin (ADR-0022). Reset de senha fica para ADR de mailer.
  resource :session, only: %i[create show destroy]
  post "/session/challenge", to: "sessions#challenge_totp"

  # MFA — ADR-0022
  post "/mfa/enroll",  to: "mfa#enroll"
  post "/mfa/confirm",   to: "mfa#confirm"
  post "/mfa/step_up",  to: "mfa#step_up"

  # gov.br OIDC callback (ADR-0022). Frontend redireciona para gov.br;
  # gov.br retorna com ?code=... → trocamos e iniciamos sessão.
  get  "/auth/govbr/callback", to: "sessions#govbr_callback"

  # Setup multi-tenant — write endpoints (ADR-0023/0024). Não confundir com
  # /admin/api/* que é read-only por critério §10 do brief.
  scope "/setup" do
    post "/municipalities",              to: "setup#provision_municipality"
    post "/invitations",                 to: "setup#invite_member"
    post "/accept_invitation",           to: "setup#accept_invitation"
    get  "/memberships",                 to: "setup#list_memberships"
    post "/memberships/:id/revoke",      to: "setup#revoke_membership"
    post "/users/:id/deactivate",        to: "setup#deactivate_user"
  end

  # Healthcheck — usado pelo Kamal (ADR-0002).
  get "up", to: ->(_env) { [200, {}, ["ok"]] }

  # Webhook do WhatsApp (ADR-0010)
  scope "/webhooks" do
    get  "whatsapp", to: "webhooks/whatsapp#verify"
    post "whatsapp", to: "webhooks/whatsapp#create"
  end

  # Relatório público (ADR-0007)
  get "/r/:token", to: "reports#show", as: :report

  # Autoria/preview de protocolos (ADR-0016)
  scope "/protocols" do
    get  ":name",         to: "protocols#show",    as: :protocol
    post ":name/preview", to: "protocols#preview", as: :protocol_preview
    post ":name/gate",    to: "protocols#gate",    as: :protocol_gate
  end

  # Autoria de protocolo (editor do dashboard) — sessão municipal + RLS + author.
  # Escrita NÃO entra em /admin/api (read-only §10). Ver F-03.12.
  scope "/authoring/protocols" do
    post "gate",    to: "authoring/protocols#gate"
    post "preview", to: "authoring/protocols#preview"
  end

  # Publicação de protocolo — exige step-up MFA (ADR-0022 + ADR-0016)
  post "/protocols/:version/publish", to: "publications#create"

  # Admin Console — namespace read-only (ADR-0018, brief §6).
  # NENHUMA rota de escrita pode ser adicionada aqui (critério §10).
  namespace :admin do
    namespace :api do
      get "overview",        to: "overview#show"
      get "ingestion",       to: "ingestion#show"
      get "conversations",   to: "conversations#show"
      get "consent",         to: "consent#show"
      get "triages",         to: "triages#show"
      get "triages/:id/trail", to: "triages#trail"
      get "classification",  to: "classification#show"
      get "protocols",       to: "protocols#index"
      get "protocols/:id",   to: "protocols#show"
      get "queues",          to: "queues#show"
      get "events",          to: "events#show"
      get "health",          to: "health#show"
      get "municipalities",  to: "municipalities#index"
      get "cities",          to: "cities#index"
      get "cities/:id",      to: "cities#show"
    end
  end
end
