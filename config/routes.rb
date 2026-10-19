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
      # Modo de prontuário, PEC e IBGE (ADR 0028; contratos §4.1).
      patch "/cities/:id/record_settings", to: "cities#record_settings"
      # Nome do órgão de saúde e brasão (multipart).
      patch "/cities/:id/identity", to: "cities#identity"
      get "/cities/:id/coat_of_arms", to: "cities#coat_of_arms"
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
      # Produção LEDI das cidades (ADR 0028; contratos §4.3). Só plataforma.
      get "/city_production", to: "city_production#index"
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

  # Identidade pública da cidade, sem sessão (login do dashboard e wpda).
  get "/city_identity",              to: "city_identities#show"
  get "/city_identity/coat_of_arms", to: "city_identities#coat_of_arms"

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
    # CADSUS no balcão (ADR 0028; contratos §5.4), atrás do interruptor.
    post "cadsus_lookup",            to: "attendance#cadsus_lookup"
    post "verifications",            to: "attendance#verify"
    post "verifications/search",     to: "attendance#search"
    post "verifications/:id/revoke", to: "attendance#revoke"
    post "verifications/:id/names",  to: "attendance#names"

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

    # Escuta inicial (ADR 0030; contratos §3). `screenings/suggest` PRECISA vir
    # antes de `screenings/:id` (a primeira rota que casa vence).
    get  "units/:id/screening_queue",   to: "screenings#queue"
    post "attendances/:id/screening",   to: "screenings#create"
    post "screenings/suggest",          to: "screenings#suggest"
    get  "screenings/:id",              to: "screenings#show"
    post "screenings/:id/abandon",      to: "screenings#abandon"
    post "screenings/:id/complete",     to: "screenings#complete"
    post "screenings/:id/reassess",     to: "screenings#reassess"
    post "ciap2/search",                to: "ciap2_codes#search"

    # Consulta e prontuário em contexto (ADR 0031; contratos §3–§5).
    # `consultation_options` é literal: não colide com `consultations/:id`.
    get   "consultation_options",            to: "consultations#options"
    post  "attendances/:id/consultation",    to: "consultations#create"
    get   "attendances/:id/record",          to: "clinical_records#context"
    # Linha do tempo do paciente (ADR 0035; contrato §3).
    get   "timeline",                        to: "timelines#show"
    # `consultations/mine` (literal) PRECISA vir antes de `consultations/:id`.
    get   "consultations/mine",              to: "consultations#mine"
    get   "consultations/:id",               to: "consultations#show"
    patch "consultations/:id",               to: "consultations#update"
    post  "consultations/:id/finalize",      to: "consultations#finalize"
    post  "consultations/:id/addenda",       to: "consultations#addenda"
    # Adendo da própria consulta (dashboard#12): a lista de problemas do paciente, só para a autora.
    get   "consultations/:id/problems",      to: "consultations#problems"
    get   "consultations/:id/print",         to: "consultations#print"
    # Documentos clínicos e medicamentos em uso (ADR 0033; contrato §3–§4).
    get  "consultations/:id/documents",    to: "clinical_documents#index"
    # A46 nos documentos: o polling da assinatura pendente lê só o estado, sem trilha.
    get  "consultations/:id/documents/status", to: "clinical_documents#status"
    post "consultations/:id/documents",    to: "clinical_documents#create"
    get  "consultations/:id/patient_identification", to: "clinical_documents#patient_identification"
    post "attendances/:id/declarations",   to: "clinical_documents#declaration"
    # api#59: as declarações do atendimento e as do dia na unidade (só metadados).
    get  "attendances/:id/declarations",   to: "clinical_documents#attendance_declarations"
    get  "declarations",                   to: "clinical_documents#declarations"
    # Contato do prescritor (ADR 0034; contrato §5).
    get "professional_profile/contact", to: "professional_contacts#show"
    put "professional_profile/contact", to: "professional_contacts#update"
    get  "documents/:id",                  to: "clinical_documents#show"
    get  "documents/:id/print",            to: "clinical_documents#print"
    post "documents/:id/cancel",           to: "clinical_documents#cancel"
    get  "patients/:id/medications",       to: "patient_medications#index"
    post "consultations/:id/medications",  to: "patient_medications#create"
    get  "consultations/:id/renewal",      to: "patient_medications#renewal"
    post  "sigtap/search",                   to: "sigtap_procedures#search"
    # Busca no catálogo de medicamentos (ADR 0033; contrato §5).
    post  "medications/search",              to: "medication_searches#search"

    # Pedidos de agendamento, marcação e agenda do dia (spec 2026-09-25 §4).
    get  "units/:id/requests",         to: "appointment_requests#index"
    get  "units/:id/agenda",           to: "appointment_requests#agenda"
    get  "units/:id/availability",     to: "appointment_requests#availability"
    post "requests/:id/appointments",  to: "appointment_requests#schedule"
    post "requests/:id/dismiss",       to: "appointment_requests#dismiss"
    # Fila "sem unidade", detalhe e atribuição (ADR 0029; contratos §4.1).
    # `requests/unassigned` PRECISA vir antes de `requests/:id`.
    get  "requests/unassigned",        to: "appointment_requests#unassigned"
    get  "requests/:id",               to: "appointment_requests#show"
    post "requests/:id/assign_unit",   to: "appointment_requests#assign_unit"
  end

  # Prontuário fora de contexto (ADR 0031; contratos §3). Prefixo próprio no
  # proxy de dev do dashboard. A abertura exige step-up; o relatório é do
  # municipal_admin. Leitura administrativa das consultas (contrato §9):
  # municipal_admin com step-up, só leitura.
  scope "/clinical_record" do
    post "openings",     to: "clinical_record_openings#create"
    get  "openings",     to: "clinical_record_openings#index"
    get  "patients/:id", to: "clinical_records#patient"
    get  "professionals/:user_id/consultations", to: "clinical_record_consultations#index"
    get  "consultations/:id",                    to: "clinical_record_consultations#show"
    get  "consultations/:id/documents",          to: "clinical_record_documents#index"
    # Rascunho órfão (card api#51): lista, candidatos, descartar, designar.
    get  "consultation_drafts",                  to: "consultation_drafts#index"
    get  "consultation_drafts/:id/candidates",   to: "consultation_drafts#candidates"
    post "consultation_drafts/:id/discard",      to: "consultation_drafts#discard"
    post "consultation_drafts/:id/reassign",     to: "consultation_drafts#reassign"
  end

  # Documentos clínicos (ADR 0033; contrato §6): configuração da cidade (CNPJ,
  # REMUME, protocolos de enfermagem). Prefixo próprio no proxy do dashboard.
  scope "/clinical_documents", module: :clinical_documents, as: :clinical_documents do
    get "city_profile", to: "city_profiles#show"
    put "city_profile", to: "city_profiles#update"
    get    "remume",                  to: "remume#index"
    post   "remume",                  to: "remume#create"
    delete "remume/:catalog_item_id", to: "remume#destroy"
    get  "nursing_protocols",              to: "nursing_protocols#index"
    post "nursing_protocols",              to: "nursing_protocols#create"
    post "nursing_protocols/:id/versions", to: "nursing_protocols#add_version"
    # Histórico de versões (api#61): todas, com a situação de hoje.
    get  "nursing_protocols/:id/versions", to: "nursing_protocols#versions"
  end

  # Assinatura digital do prontuário (ADR 0032; contrato §3–§7).
  scope "/signature", module: :signatures, as: :signature do
    get    "certificates/current",  to: "certificates#show"
    delete "certificates/current",  to: "certificates#destroy"
    post   "certificates/discover", to: "certificates#discover"
    post   "certificates/link",     to: "certificates#link"
    post   "oauth/callback",        to: "oauth#callback"
    post   "sessions",              to: "sessions#create"
    get    "sessions/current",      to: "sessions#show"
    delete "sessions/current",      to: "sessions#destroy"
    get    "requests",              to: "requests#index"
    post   "requests/:id/return_to_paper", to: "requests#return_to_paper"
    post   "batches",               to: "batches#create"
    get    "signatures/:id",         to: "signatures#show"
    get    "signatures/:id/pdf",     to: "signatures#pdf"
    get    "signatures/:id/package", to: "signatures#package"
    post   "signatures/:id/verify",  to: "signatures#verify"
    get    "admin/overview",         to: "admin#overview"
  end

  # SNCR (ADR 0034; contrato §4, §6). Prefixo único: uma entrada no proxy de dev do dashboard.
  scope "/sncr", module: :sncr, as: :sncr do
    get  "stock",           to: "stock#show"
    post "requests",        to: "requests#create"
    post "oauth/callback",  to: "oauth#callback"
    get  "admin/overview",  to: "admin#overview"
  end

  # Rastreamento do exame (ADR 0036; contrato §3–§6). Prefixo único no proxy
  # de dev do dashboard. As rotas das Tasks 6, 9–13, 16 e 18 entram aqui.
  scope "/exams", module: :exams, as: :exams do
    post "uploads",      to: "uploads#create"
    get  "files/:token", to: "files#show", format: false, constraints: { token: %r{[^/]+} }
    get  "orders",              to: "orders#index"
    post "orders",              to: "orders#create"
    get  "orders/:id",          to: "orders#show"
    post "orders/:id/schedule", to: "order_steps#schedule"
    post "orders/:id/collect",  to: "order_steps#collect"
    post "orders/:id/cancel",   to: "order_steps#cancel"
    post "orders/:id/result",   to: "results#create"
    post "orders/:id/acknowledge", to: "acknowledgements#create"
    post "orders/:id/gal_requisition", to: "gal#create"
    post "external_results",      to: "external_results#create"
    get  "external_results",      to: "external_results#index"
    post "patient_lookup",        to: "lookups#patient"
    get  "catalog",               to: "lookups#catalog"
    get  "providers",             to: "lookups#providers"
    get  "requesters",            to: "lookups#requesters"
    get  "acknowledgements/pending", to: "acknowledgements#pending"
    get  "acknowledgements/pending/count", to: "acknowledgements#pending_count" # A46
    get  "acknowledgements/team",    to: "acknowledgements#team"
    get  "regulation/queue",      to: "regulation#queue"
    post "orders/:id/authorize",  to: "regulation#authorize"
    post "orders/:id/deny",       to: "regulation#deny"
    scope "provider", module: :provider, as: :provider do
      get  "orders",              to: "orders#index"
      post "orders/:id/schedule", to: "orders#schedule"
      post "orders/:id/collect",  to: "orders#collect"
      post "orders/:id/result",   to: "orders#result"
    end
    # O csv vem ANTES: `admin/report` aceita (.:format) e engoliria
    # `admin/report.csv` como JSON.
    get "admin/report.csv", to: "reports#csv", format: false
    get "admin/report",     to: "reports#show", format: false
    scope "admin", module: :admin, as: :admin do
      get   "catalog_items",     to: "catalog_items#index"
      post  "catalog_items",     to: "catalog_items#create"
      patch "catalog_items/:id", to: "catalog_items#update"
      get    "providers",                to: "providers#index"
      post   "providers",                to: "providers#create"
      patch  "providers/:id",            to: "providers#update"
      post   "providers/:id/fhir_token", to: "providers#rotate_token"
      delete "providers/:id/fhir_token", to: "providers#revoke_token"
      post   "providers/:id/users",      to: "providers#invite_user"
    end
  end

  # Módulo 21b (ADR 0037): laboratório municipal. As literais antes de `:id`.
  scope "/lab", module: :lab, as: :lab do
    get "context",           to: "context#show"
    get "instruments",       to: "instruments#index"
    get "rejection_reasons", to: "lookups#rejection_reasons"
    get  "candidate_orders",  to: "lookups#candidate_orders"
    get  "exams",             to: "lookups#exams"
    get  "requisitions",      to: "requisitions#index"
    post "requisitions",      to: "requisitions#create"
    get  "requisitions/:id/receipt.pdf", to: "requisitions#receipt", format: false
    get  "requisitions/:id/labels.pdf",  to: "requisitions#labels", format: false
    get  "requisitions/:id",  to: "requisitions#show"
    post "requisitions/:id/deliver", to: "requisitions#deliver"
    post "samples/collect",              to: "samples#collect"
    post "samples/:id/collect",          to: "samples#collect"
    post "samples/receive",              to: "samples#receive"
    get  "recollections",                to: "samples#pending"
    get  "shipments",                    to: "shipments#index"
    post "shipments",                    to: "shipments#create"
    post "shipments/:id/send",           to: "shipments#send_out"
    post "shipments/:id/receive",        to: "shipments#receive"
    get  "worklists.pdf",                to: "worklists#pdf", format: false
    get  "worklists",                    to: "worklists#show"
    get  "entry",                        to: "results#entry"
    post "results",                      to: "results#create"
    post "results/:id/choose",           to: "results#choose"
    get  "criticals/unnotified/count",   to: "criticals#count"
    get  "criticals/unnotified",         to: "criticals#index"
    post "criticals",                    to: "criticals#create"
    get  "releases",                     to: "releases#index"
    get  "releases/:id",                 to: "releases#show"
    post "requisitions/:id/release",     to: "releases#create"
    get  "reports/:kind.csv",            to: "production_reports#csv", format: false, constraints: { kind: /production|rejections|turnaround/ }
    get  "reports/:kind",                to: "production_reports#show", constraints: { kind: /production|rejections|turnaround/ }
    get  "reports/:id/pdf",              to: "reports#pdf", format: false
    post "reports/:id/rectify",          to: "reports#rectify"
    # Módulo 21c (ADR 0038): CIQ. As literais antes de `:id`.
    scope "qc", module: :qc, as: :qc do
      get   "materials",            to: "materials#index"
      post  "materials",            to: "materials#create"
      patch "materials/:id",        to: "materials#update"
      get   "lots",                 to: "lots#index"
      post  "lots",                 to: "lots#create"
      post  "lots/:id/close",       to: "lots#close"
      get   "targets/suggestions",        to: "targets#suggestions"
      post  "targets/suggestions/accept", to: "targets#accept"
      get   "chart",                      to: "charts#show"
      get   "targets",              to: "targets#index"
      post  "targets",              to: "targets#create"
      get   "runs",                 to: "runs#index"
      post  "runs",                 to: "runs#create"
      post  "values",               to: "values#create"
      get   "rules",                to: "rules#show"
      put   "rules",                to: "rules#update"
      get   "blocks/active/count",  to: "blocks#count"
      get   "blocks",               to: "blocks#index"
      post  "blocks/:id/corrective_action", to: "blocks#corrective_action"
      get   "exceptions",           to: "exceptions#index"
      post  "exceptions",           to: "exceptions#create"
      get   "reviews",              to: "reviews#index"
      post  "reviews/:id",          to: "reviews#decide"
    end
    # Módulo 21c (ADR 0038): CEQ. As literais antes de `:id`.
    scope "eqa", module: :eqa, as: :eqa do
      get  "summary",                      to: "rounds#summary"
      post "uploads",                      to: "rounds#upload"
      get  "rounds",                       to: "rounds#index"
      post "rounds",                       to: "rounds#create"
      get  "annual_reports",               to: "rounds#annual_reports"
      post "annual_reports",               to: "rounds#create_annual_report"
      get  "annual_reports/:id/pdf",       to: "rounds#annual_report_pdf", format: false
      get  "rounds/:id",                   to: "rounds#show"
    end
    # Módulo 21c (ADR 0038): estoque. As literais antes de `:id`.
    scope "inventory", module: :inventory, as: :inventory do
      get   "supplies",      to: "supplies#index"
      post  "supplies",      to: "supplies#create"
      patch "supplies/:id",  to: "supplies#update"
      get   "lots",          to: "lots#index"
      post  "lots",          to: "lots#create"
      get   "movements",     to: "movements#index"
      post  "movements",     to: "movements#create"
      get   "alerts",        to: "alerts#show"
      get   "in_use",               to: "in_use#index"
      post  "in_use",               to: "in_use#create"
      get   "consumption.csv",      to: "consumption#csv", format: false
      get   "consumption",          to: "consumption#show"
      get   "lots/:id/trace.csv",   to: "traces#csv", format: false
      get   "lots/:id/trace",       to: "traces#show"
    end
    scope "admin", module: :admin, as: :admin do
      get   "templates",                 to: "templates#index"
      get   "exams",                     to: "exams#index"
      post  "exams",                     to: "exams#create"
      get   "exams/:id",                 to: "exams#show"
      patch "exams/:id",                 to: "exams#update"
      post  "exams/:id/versions",        to: "exams#create_version"
      get   "rejection_reasons",         to: "rejection_reasons#index"
      post  "rejection_reasons",         to: "rejection_reasons#create"
      patch "rejection_reasons/:id",     to: "rejection_reasons#update"
      get   "instruments",               to: "instruments#index"
      post  "instruments",               to: "instruments#create"
      patch "instruments/:id",           to: "instruments#update"
      get    "releasers",                        to: "releasers#index"
      post   "releasers",                        to: "releasers#create"
      delete "releasers/:id",                    to: "releasers#destroy"
      post   "providers/:id/middleware_token",   to: "middleware_tokens#create"
      delete "providers/:id/middleware_token",   to: "middleware_tokens#destroy"
    end
  end

  # Profissionais (ADR 0021; spec 2026-09-27-module-10-professionals §4.1).
  # Prefixo único: uma entrada só no proxy de dev do dashboard. As rotas
  # literais (me, pending, cbo, links, shifts) PRECISAM vir antes de `:id`.
  scope "/professionals" do
    get  "",        to: "professionals#index"
    post "",        to: "professionals#create"
    get  "pending", to: "professionals#pending"
    get  "me",      to: "professionals#me"
    get  "me/agenda", to: "professional_agenda#show"
    post "me",      to: "professionals#update_me"
    get  "cbo",     to: "professionals#cbo"
    post "links/:id/end", to: "professional_links#end_link"
    post "links/:id/default_type", to: "professional_links#default_type"
    post "links/:id/shifts",  to: "professional_shifts#create"
    post "shifts/:id/cancel", to: "professional_shifts#cancel"
    post "shifts/:id/template", to: "professional_shifts#template"
    # Agenda dos profissionais (ADR 0029; contratos §3).
    get  "appointment_types",      to: "appointment_types#index"
    post "appointment_types",      to: "appointment_types#create"
    post "appointment_types/:key", to: "appointment_types#update"
    get  "schedule_templates",         to: "schedule_templates#index"
    post "schedule_templates",         to: "schedule_templates#create"
    post "schedule_templates/preview", to: "schedule_templates#preview"
    post "schedule_templates/:id",     to: "schedule_templates#update"
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

  # Integrações da cidade (ADR 0028; contratos §5.1). Prefixo único no proxy
  # de dev do dashboard.
  get  "/integrations", to: "integrations#show"
  put  "/integrations/credentials/:kind", to: "integrations#update"
  post "/integrations/credentials/:kind/check", to: "integrations#check"

  # Produção e-SUS (ADR 0028; contratos §5.3).
  get  "/production", to: "production#show"
  post "/production/fichas/:id/resend", to: "production#resend"
  # Fichas que não puderam ser geradas (ADR 0030; contratos §6).
  get  "/production/generation_failures",           to: "production#generation_failures"
  post "/production/generation_failures/:id/retry", to: "production#retry_generation"

  # CNES da cidade (ADR 0028; contratos §5.2).
  get  "/cnes", to: "cnes#show"
  post "/cnes/apply", to: "cnes#apply"

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

  # Conferência pública de documento clínico (ADR 0033; contrato §7). Host da
  # cidade; sem login. O token tem 22 caracteres url-safe (sem ponto).
  get  "/v",                     to: "document_verifications#form"
  post "/v/lookup",              to: "document_verifications#lookup"
  get  "/v/:token/signed.pdf",   to: "document_verifications#signed_pdf", format: false, constraints: { token: /[A-Za-z0-9_-]{22}/ }
  get  "/v/:token",              to: "document_verifications#show", constraints: { token: /[A-Za-z0-9_-]+/ }

  # Página para a tela de "sistemas externos" do e-SUS PEC (ADR 0035;
  # contrato §5). Host da cidade; sem sessão do Rota Saúde: assinatura HMAC
  # da URL, uso único e sessão curta em cabeçalho.
  get "/pec/timeline",      to: "pec_timelines#show"
  get "/pec/timeline/more", to: "pec_timelines#more"
  # "Solicitar exames" (ADR 0036; contrato §8 com A8/D8): formulário com o token da sessão curta.
  post "/pec/exams/form", to: "pec_exams#form"
  post "/pec/exams",      to: "pec_exams#create"

  # Entrada FHIR do laudo (ADR 0036; contrato §7, A7). Host da cidade, sem
  # cookie: token Bearer do prestador.
  post "/fhir/DiagnosticReport", to: "fhir/diagnostic_reports#create"
  get  "/fhir/ServiceRequest",   to: "fhir/service_requests#index"

  # Módulo 21b (ADR 0037): entrada HL7 do middleware do laboratório (token, sem cookie).
  post "/hl7/v2",                   to: "hl7/v2#create"
  get  "/lab/hl7/pending_barcodes", to: "hl7/pending_barcodes#index"

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
    post "appointments/:id/reschedule_request", to: "appointments#reschedule_request"

    get  "notices",          to: "notices#index"
    post "notices/:id/read", to: "notices#read"

    get "contact_preferences",             to: "contact_preferences#index"
    put "contact_preferences/:citizen_id", to: "contact_preferences#update"

    # Linha do tempo do cidadão (ADR 0035; contrato §4, Divergência D2: citizen_id).
    get "history",           to: "history#index"
    get "health_summary",    to: "history#health_summary"
    get "documents/:id/pdf", to: "history#document_pdf"

    # Meus exames (ADR 0036; contrato §9, A22: citizen_id).
    get "exams",         to: "exams#index"
    get "exams/:id/pdf", to: "exams#pdf"
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
    post "simulate_screening", to: "authoring/protocols#simulate_screening"
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

    # Simulador do e-SUS PEC (ADR 0035): host próprio, para o iframe da
    # cidade ser de outra origem como no PEC real. Assina URL com a chave da
    # cidade, por isso só existe aqui; spec/architecture/pec_simulator_route_spec.rb.
    constraints(->(request) { request.host == "pec-sim.localhost" }) do
      get "/pec-simulator", to: "dev/pec_simulators#show"
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
