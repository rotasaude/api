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
    # Módulo 32a (contrato §6 e §14 Q7): "chamar de novo", na UPA e na UBS.
    post "attendances/:id/recall",    to: "attendances#recall"
    # Módulo 32a (contrato §8 e §14 Q7): locais de chamada da unidade; a
    # lista (com location_required) lê quem chama, a escrita é do admin.
    get   "call_locations",           to: "call_locations#index"
    post  "call_locations",           to: "call_locations#create"
    patch "call_locations/:id",       to: "call_locations#update"
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
    # Módulo 25 (contrato §4, K4): sugestão de notificação da consulta (autora, sem trilha).
    get   "consultations/:id/notification_suggestions", to: "surveillance/consultation_suggestions#index"
    # Módulo 26a (ADR 0044; contrato §3): pedido de regulação em rascunho na consulta (autora; promovido na finalização).
    get    "consultations/:id/regulation_requests",      to: "care_regulation/consultation_requests#index"
    post   "consultations/:id/regulation_requests",      to: "care_regulation/consultation_requests#create"
    patch  "consultations/:id/regulation_requests/:rid", to: "care_regulation/consultation_requests#update"
    delete "consultations/:id/regulation_requests/:rid", to: "care_regulation/consultation_requests#destroy"
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

  # Módulo 22 (ADR 0039; contrato §3–§6): procedimentos e faturamento BPA.
  # Prefixo único (uma entrada no proxy de dev do dashboard). Literais antes de `:id`.
  scope "/billing", module: :billing, as: :billing do
    get  "sigtap/search",         to: "sigtap#search"
    post "patient_lookup",        to: "lookups#patient"
    get  "establishments",        to: "lookups#establishments"
    get  "professionals",         to: "lookups#professionals"
    get  "procedures",            to: "procedures#index"
    post "procedures",            to: "procedures#create"
    post "procedures/:id/cancel", to: "procedures#cancel"
    get  "periods",              to: "periods#index"
    get  "periods/:id/pending",  to: "periods#pending"
    post "periods/:id/close",    to: "periods#close"
    post "periods/:id/reopen",   to: "periods#reopen"
    get  "periods/:id/exports",  to: "exports#index"
    get  "exports/:id/file",     to: "exports#file"
    get  "settings",             to: "settings#show"
    put  "settings",             to: "settings#update"
    patch "patients/:id/demographics", to: "patients#demographics"
  end

  # Módulo 25 (ADR 0043; contrato §3): vigilância epidemiológica, sessão do
  # dashboard. Prefixo único (uma entrada no proxy de dev do dashboard).
  scope "/surveillance", module: :surveillance, as: :surveillance do
    get   "diseases",                  to: "diseases#index"
    post  "notifications",             to: "notifications#create"
    # Fila, detalhe, ficha e contadores (contrato §5): `count` (literal) antes de `:id`.
    get   "notifications",             to: "notifications#index"
    get   "notifications/count",       to: "notifications#count"
    get   "notifications/:id",         to: "notifications#show"
    patch "notifications/:id",         to: "notifications#update"
    # Andamento (contrato §5, K6): transição linear e descarte da `possible`.
    post  "notifications/:id/transition", to: "transitions#transition"
    post  "notifications/:id/dismiss",    to: "transitions#dismiss"
    get   "units",                     to: "units#index"
    # Saídas (contrato §7): a ficha no formato do Sinan e o CSV da semana.
    get   "notifications/:id/form.pdf", to: "exports#form", format: false
    get   "exports/week.csv",          to: "exports#week", format: false
    # Painel por bairro × semana epidemiológica (contrato §8, K7).
    get   "panel",                     to: "panel#index"
    # Negativa semanal por unidade (contrato K7).
    get   "weekly_negatives",          to: "weekly_negatives#index"
    post  "weekly_negatives",          to: "weekly_negatives#create"
    post  "person_lookup",             to: "person_lookups#create"
    post  "patients/duplicates",       to: "duplicates#create"
    get   "admin/local_diseases",      to: "local_diseases#index"
    post  "admin/local_diseases",      to: "local_diseases#create"
    patch "admin/local_diseases/:id",  to: "local_diseases#update"
  end

  # Módulo 26a (ADR 0044; contrato §3–§8): regulação municipal, sessão do
  # dashboard. Prefixo único (uma entrada no proxy de dev do dashboard).
  scope "/regulation", module: :care_regulation, as: :regulation do
    get    "targets",              to: "targets#index"
    # A fila do regulador (contrato §4): a rota literal `count` vem antes de `:id`.
    get    "requests",             to: "requests#index"
    get    "requests/count",       to: "requests#count"
    get    "requests/:id",         to: "requests#show"
    # A guia de encaminhamento em PDF (contrato §3): `format: false` para o
    # `.pdf` ficar no segmento literal e `:id` receber só o id.
    get    "requests/:id/guide.pdf", to: "guides#show", format: false
    post   "requests/:id/authorize", to: "decisions#authorize"
    post   "requests/:id/return",  to: "decisions#return_request"
    post   "requests/:id/deny",    to: "decisions#deny"
    post   "requests/:id/cancel",  to: "decisions#cancel"
    # Prestador externo e sistema do estado (contrato §7, §8).
    post   "requests/:id/external", to: "decisions#external"
    post   "requests/:id/schedule", to: "decisions#schedule"
    post   "requests/:id/outcome", to: "decisions#outcome"
    get    "exports/state.csv",    to: "exports#state"
    # A unidade solicitante (contrato §5): devolvidos e complemento.
    post   "requests/:id/complement", to: "decisions#complement"
    get    "returned",             to: "returned#index"
    get    "admin/deadlines",      to: "admin/deadlines#show"
    patch  "admin/deadlines",      to: "admin/deadlines#update"
    get    "admin/nurse_items",    to: "admin/nurse_items#index"
    post   "admin/nurse_items",    to: "admin/nurse_items#create"
    delete "admin/nurse_items",    to: "admin/nurse_items#destroy"
    get    "admin/providers",      to: "admin/providers#index"
    post   "admin/providers",      to: "admin/providers#create"
    patch  "admin/providers/:id",  to: "admin/providers#update"
    get    "admin/offers",         to: "admin/offers#index"
    post   "admin/offers",         to: "admin/offers#create"
    patch  "admin/offers/:id",     to: "admin/offers#update"
  end

  # Módulo 28 (ADR 0046; contrato §16 O1): saúde bucal, sessão do dashboard.
  # Prefixo único (uma entrada no proxy de dev do dashboard).
  scope "/dental", module: :dental_care, as: :dental do
    get "admin/ceo_profiles",                   to: "admin/ceo_profiles#index"
    get "admin/ceo_profiles/:health_unit_id",   to: "admin/ceo_profiles#show"
    put "admin/ceo_profiles/:health_unit_id",   to: "admin/ceo_profiles#update"
    get "admin/auxiliary_procedures",           to: "admin/auxiliary_procedures#show"
    put "admin/auxiliary_procedures",           to: "admin/auxiliary_procedures#update"
    # Associação da eSB à eSF/eAP (Desvio 13, D7; O11).
    get "admin/oral_health_teams",              to: "admin/oral_health_teams#index"
    put "admin/oral_health_teams/:id",          to: "admin/oral_health_teams#update"
    # Busca de procedimento da consulta (contrato §16 O5; termo no corpo).
    post "procedures/search",                   to: "procedures#search"
    # Leitura nominal do paciente (O1, O13): só o id na URL; filtro de dente na tela.
    get "patients/:id/dental_chart",            to: "charts#show"
    get "patients/:id/dental_chart/events",     to: "charts#events"
    get "patients/:id/dental_plans",            to: "plans#index"
    get "patients/:id/endodontic_treatments",   to: "endodontics#index"
    # Prótese e laboratório (Desvio 12; O10, O27).
    get  "laboratories",                        to: "prosthesis_orders#laboratories"
    get  "prosthesis_orders",                   to: "prosthesis_orders#index"
    post "prosthesis_orders",                   to: "prosthesis_orders#create"
    post "prosthesis_orders/:id/stages",        to: "prosthesis_orders#stage"
    # Painel do CEO (F-28.8; contrato §10, O15/O24): só contagens, sem trilha.
    get  "ceo_goals",                           to: "ceo_goals#show"
    # Indicadores B1/B2 da eSB e o seletor das eSB (F-28.8; O11, O15, O23).
    get  "indicators",                          to: "indicators#show"
    get  "teams",                               to: "teams#index"
  end

  # Módulo 27a (ADR 0045; contrato §3, §13): farmácia e almoxarifado, sessão do
  # dashboard. Prefixo único (uma entrada no proxy de dev do dashboard).
  scope "/pharmacy", module: :pharmacy, as: :pharmacy do
    # Administração (municipal_admin; escrita com step-up): locais, equipe e parâmetros.
    get    "admin/locations",           to: "admin/locations#index"
    post   "admin/locations",           to: "admin/locations#create"
    patch  "admin/locations/:id",       to: "admin/locations#update"
    post   "admin/locations/:id/staff", to: "admin/staff#create"
    delete "admin/locations/:id/staff", to: "admin/staff#destroy"
    get    "admin/settings",            to: "admin/settings#show"
    patch  "admin/settings",            to: "admin/settings#update"
    # Meus locais, mínimos por local e busca de item no catálogo.
    get    "locations",                 to: "locations#index"
    get    "locations/:id/minimums",    to: "minimums#show"
    put    "locations/:id/minimums",    to: "minimums#update"
    post   "items/search",              to: "items#search"
    # Entradas por nota ou doação e inventário de abertura (Task 5).
    post   "receipts",                  to: "entries#receipt"
    post   "openings",                  to: "entries#opening"
    # Transferência do central para a unidade, em dois passos (Task 6).
    post   "transfers",                 to: "transfers#create"
    get    "transfers",                 to: "transfers#index"
    get    "transfers/:id",             to: "transfers#show"
    post   "transfers/:id/receive",     to: "transfers#receive"
    # Inventário, perdas e vencimentos, com step-up e aprovação por outro (Task 7).
    # Faltas de estoque da checagem da UPA e a conciliação (módulo 32b, Task 11).
    get    "urgency_shortfalls",          to: "urgency_shortfalls#index"
    post   "urgency_shortfalls/:id/reconcile", to: "urgency_shortfalls#reconcile"
    post   "adjustments",               to: "adjustments#create"
    get    "adjustments",               to: "adjustments#index"
    get    "adjustments/:id",           to: "adjustments#show"
    post   "adjustments/:id/approve",   to: "adjustments#approve"
    post   "adjustments/:id/reject",    to: "adjustments#reject"
    # Posição, extrato do lote e alertas: leitura sem trilha e sem dado pessoal (Task 8).
    get    "positions",                 to: "positions#index"
    get    "lots/:id/movements",        to: "statements#index"
    get    "alerts",                    to: "alerts#show"
    # Receita para a farmácia: busca por código ou paciente, busca de pessoa e
    # duplicados, nominais e com trilha (Task 9).
    post   "prescriptions/lookup",      to: "prescriptions#lookup"
    post   "person_lookup",             to: "person_lookups#create"
    post   "patients/duplicates",       to: "duplicates#create"
    # Receita externa digitada na farmácia, com trilha por pessoa (Task 10).
    post   "external_prescriptions",    to: "external_prescriptions#create"
    # Dispensação pela receita, histórico de retiradas do paciente (nominal, com
    # trilha) e devolução ao lote (Task 11).
    post   "dispensations",             to: "dispensations#create"
    get    "dispensations",             to: "dispensations#index"
    post   "returns",                   to: "returns#create"
  end

  # Módulo 30 (ADR 0048; contrato §3): transporte sanitário e TFD, sessão do
  # dashboard. Prefixo único por área.
  scope "/transport", module: :transport, as: :transport do
    get   "vehicles",            to: "vehicles#index"
    post  "vehicles",            to: "vehicles#create"
    get   "vehicles/:id",        to: "vehicles#show"
    patch "vehicles/:id",        to: "vehicles#update"
    get   "drivers",             to: "drivers#index"
    post  "drivers",             to: "drivers#create"
    get   "drivers/:id",         to: "drivers#show"
    patch "drivers/:id",         to: "drivers#update"
    get   "driver_candidates",   to: "drivers#candidates"
    get   "health_units",        to: "health_units#index"
    get   "destinations",        to: "destinations#index"
    post  "destinations",        to: "destinations#create"
    get   "destinations/:id",    to: "destinations#show"
    patch "destinations/:id",    to: "destinations#update"
    # Viagens da central (§4; T4, T19).
    get   "trips",               to: "trips#index"
    post  "trips",               to: "trips#create"
    patch "trips/:id",           to: "trips#update"
    post  "trips/:id/confirm",   to: "trips#confirm"
    post  "trips/:id/cancel",    to: "trips#cancel"
    post  "trips/:id/attendance_correction", to: "trips#attendance_correction"
    get   "trips/:id/manifest.pdf", to: "manifests#show", format: false
    get   "no_shows",            to: "no_shows#index"
    get   "dashboard",           to: "dashboard#show"
    # Passageiros e atendimentos marcados (§4; T5, T19); busca de pessoa e
    # duplicados (T2), dado só no corpo.
    post   "trips/:id/passengers",                to: "passengers#create"
    delete "trips/:id/passengers/:passenger_id",  to: "passengers#destroy"
    post   "scheduled_care",                      to: "scheduled_care#create"
    post   "person_lookup",                       to: "person_lookups#create"
    post   "patients/duplicates",                 to: "duplicates#create"
    # Séries recorrentes e pendências do job (§4; T6).
    get   "series",              to: "series#index"
    post  "series",              to: "series#create"
    get   "series/:id",          to: "series#show"
    patch "series/:id",          to: "series#update"
    post  "series/:id/suspend",  to: "series#suspend"
    get   "pending",             to: "pending#index"
    # Tela do motorista (§5; T19): só as próprias viagens.
    get   "my_trips",                 to: "my_trips#index"
    post  "my_trips/:id/start",       to: "my_trips#start"
    post  "my_trips/:id/attendance",  to: "my_trips#attendance"
    post  "my_trips/:id/close",       to: "my_trips#close"
    get   "admin/settings", to: "admin/settings#show"
    patch "admin/settings", to: "admin/settings#update"
  end

  # Módulo 30 (ADR 0048; contrato §6; §14 T7, T8, T9): TFD, sessão do
  # dashboard. Laudo do médico, fila da comissão, leitura nominal com trilha e
  # as escritas da comissão (decisão, atendimento, internação, cancelamento).
  scope "/tfd", module: :tfd, as: :tfd do
    get   "options",           to: "options#show"
    get   "prefill",           to: "prefill#show"
    get   "my_cases",          to: "cases#mine"
    get   "cases",             to: "cases#index"
    post  "cases",             to: "cases#create"
    patch "cases/:id",         to: "cases#update"
    post  "cases/:id/submit",  to: "cases#submit"
    post  "cases/:id/read",    to: "cases#read"
    post  "cases/:id/decide",       to: "cases#decide"
    post  "cases/:id/appointment",  to: "cases#appointment"
    post  "cases/:id/inpatient",    to: "cases#inpatient"
    post  "cases/:id/cancel",       to: "cases#cancel"
    post  "cases/:id/payments",     to: "cases#payments"
    post  "cases/:id/accountability",     to: "cases#accountability"
    post  "cases/:id/accountability/url", to: "cases#accountability_url"
    get   "files/:token",           to: "files#show"
    post  "cases/:id/legs",         to: "legs#create"
    get   "cases/:id/allowances",   to: "legs#allowances"
    post  "legs/:id/done",          to: "legs#done"
  end

  # Módulo 31 (ADR 0049; contrato §3, §4, P4, P33): atenção psicossocial
  # (CAPS), sessão do dashboard. Dado do paciente só no corpo; ids na URL.
  scope "/psychosocial", module: :psychosocial, as: :psychosocial do
    # Leitura: CAPS de lotação (ou todos) e as opções das telas do CAPS.
    get   "units",               to: "units#index"
    get   "options",             to: "options#show"
    # Administração: parâmetros (leitura também da coordenação) e leitos.
    get   "settings",            to: "settings#show"
    patch "settings",            to: "settings#update"
    get   "beds",                to: "beds#index"
    post  "beds",                to: "beds#create"
    patch "beds/:id",            to: "beds#update"
    # Busca de paciente (P30) e pré-preenchimento da ESF (P4), sem trilha clínica.
    post  "person_lookup",       to: "person_lookups#create"
    post  "patients/duplicates", to: "duplicates#create"
    get   "prefill",             to: "prefill#show"
    # Encaminhamento da UBS, acolhimento e matrícula (§4, P5, P7, P13).
    post  "referrals",           to: "referrals#create"
    get   "referrals",           to: "referrals#index"
    get   "referrals/:id",       to: "referrals#show"
    post  "receptions",          to: "receptions#create"
    get   "enrollments",         to: "enrollments#index"
    post  "enrollments",         to: "enrollments#create"
    get   "enrollments/:id",     to: "enrollments#show"
    patch "enrollments/:id",     to: "enrollments#update"
    post  "enrollments/:id/close", to: "enrollments#close"
    # PTS com versões e as revisões vencidas (§4, P4, P16).
    get   "enrollments/:id/care_plans", to: "care_plans#index"
    post  "enrollments/:id/care_plans", to: "care_plans#create"
    get   "care_plans/due",      to: "care_plans#due"
    # Linha do tempo restrita do CAPS (§10, P18): só a equipe lotada.
    get   "enrollments/:id/timeline", to: "timelines#show"
    # Grade de grupos e o "Hoje no CAPS" (§4).
    get   "groups",              to: "groups#index"
    post  "groups",              to: "groups#create"
    patch "groups/:id",          to: "groups#update"
    get   "today",               to: "today#show"
    # Ações com a crítica SIGTAP na hora e o cancelamento (§4, P23).
    get   "actions",             to: "actions#index"
    post  "actions",             to: "actions#create"
    get   "actions/:id",         to: "actions#show"
    post  "actions/:id/cancel",  to: "actions#cancel"
    # Receita, Notificação e atestado do 19 a partir da ação (§4, §9, P4, P8).
    get   "actions/:id/documents", to: "documents#index"
    post  "actions/:id/documents", to: "documents#create"
    # Acolhimento noturno: mapa dos leitos, entrada, detalhe e saída (§5).
    get   "beds/board",          to: "beds#board"
    post  "night_stays",         to: "night_stays#create"
    get   "night_stays/:id",     to: "night_stays#show"
    post  "night_stays/:id/close", to: "night_stays#close"
    # RAAS do mês: situação de rua, pendências, fechamento e reabertura (§6, P6, P14, P24).
    patch "monthly_records/:id", to: "monthly_records#update"
    get   "months/:month",       to: "months#show"
    post  "months/:month/close", to: "months#close"
    post  "months/:month/reopen", to: "months#reopen"
    # Remessa RAAS atrás do layout (gate) e a ficha espelho em PDF (§6, P4, P15).
    get   "raas_exports",        to: "raas_exports#index"
    post  "raas_exports",        to: "raas_exports#create"
    get   "raas_exports/:id/file", to: "raas_exports#file"
    get   "months/:month/sheets.pdf", to: "sheets#show", format: false
    # Matriciamento com a atenção básica, caso compartilhado (§7, P4) e o
    # vínculo com o CAPS visto pela UBS (P10).
    get   "matrix_supports",     to: "matrix_supports#index"
    post  "matrix_supports",     to: "matrix_supports#create"
    get   "matrix_supports/:id", to: "matrix_supports#show"
    post  "matrix_supports/:id/cases", to: "matrix_supports#add_case"
    get   "patients/:id/link",   to: "links#show"
    # Painel do CAPS: só contagens, com "lt5" para 1 a 4 (§11, P11).
    get   "dashboard",           to: "dashboard#show"
  end

  # Módulo 33 (ADR 0051; contrato §7): setores da secretaria — tabela genérica,
  # sem o portão da ouvidoria (Q12); leitura do administrador, do técnico e do ouvidor.
  get   "departments",     to: "departments#index"
  post  "departments",     to: "departments#create"
  patch "departments/:id", to: "departments#update"

  # Módulo 33 (ADR 0051): ouvidoria do SUS municipal, sessão do dashboard, atrás
  # do interruptor `ombudsman`. Texto e dado de pessoa só no corpo; ids na URL.
  scope "/ombudsman", module: :ombudsman, as: :ombudsman do
    # Configuração (§7): respondentes, assuntos, prazos e as listas das telas.
    get   "responders",           to: "responders#index"
    post  "responders",           to: "responders#create"
    patch "responders/:id",       to: "responders#update"
    get   "responder_candidates", to: "responder_candidates#index"
    get   "subjects",             to: "subjects#index"
    post  "subjects",             to: "subjects#create"
    patch "subjects/:id",         to: "subjects#update"
    get   "settings",             to: "settings#show"
    patch "settings",             to: "settings#update"
    get   "options",              to: "options#show"
    # Anexos (§5; Q2, Q14): upload da equipe, link curto e o download pelo token.
    post  "attachments",          to: "attachments#create"
    post  "attachments/:id/link", to: "attachments#link"
    get   "files/:token",         to: "files#show", format: false, constraints: { token: %r{[^/]+} }
    # Registro pela equipe (§5; Q6): busca do cidadão pelo CPF (POST: o CPF só no corpo),
    # registro presencial/telefone/OuvidorSUS e o comprovante.
    post  "person_lookup",        to: "person_lookups#create"
    post  "manifestations",       to: "manifestations#create"
    get   "manifestations/:id/receipt", to: "manifestations#receipt"
    # Caixa e detalhe da equipe (§5; Q23: filtros repetidos e cursor `before`)
    # e a identidade preservada (§8): justificativa e consentimento só no corpo.
    get   "manifestations",       to: "manifestations#index"
    get   "manifestations/:id",   to: "manifestations#show"
    post  "manifestations/:id/identity",         to: "identities#create"
    post  "manifestations/:id/identity_consent", to: "identities#consent"
    # Ações da equipe (§2; preflight F-11): uma rota explícita por ação, cada
    # uma com `expected_state` no corpo; o cancelamento do encaminhamento leva
    # o `expected_state` do encaminhamento (Q33).
    post  "manifestations/:id/classify", to: "actions#classify"
    post  "manifestations/:id/forward",  to: "actions#forward"
    post  "manifestations/:id/request_complement", to: "actions#request_complement"
    post  "manifestations/:id/complement",         to: "actions#complement"
    post  "manifestations/:id/extend",             to: "actions#extend_deadline"
    post  "manifestations/:id/interim_response",   to: "actions#interim_response"
    post  "manifestations/:id/final_response",     to: "actions#final_response"
    post  "manifestations/:id/change_resolution",  to: "actions#change_resolution"
    post  "manifestations/:id/archive",            to: "actions#archive"
    post  "manifestations/:id/reopen",             to: "actions#reopen"
    post  "reopen_requests/:id/decide",            to: "reopen_requests#decide"
    post  "forwardings/:id/cancel",      to: "forwardings#cancel"
    # Ponto de resposta (§6; Q23, Q48): o inbox do respondente e as ações dele.
    get   "inbox",             to: "inbox#index"
    post  "inbox/:id/reply",   to: "inbox#reply"
    post  "inbox/:id/decline", to: "inbox#decline"
    post  "inbox/:id/extend",  to: "inbox#extend_forwarding"
    # Painel e relatório de gestão anual (§11; Q28, Q35): o painel (técnico e
    # ouvidor), por profissional (ouvidor) e o relatório do ano (ouvidor).
    get   "dashboard",                    to: "dashboard#show"
    get   "dashboard/professionals",      to: "dashboard#professionals"
    get   "annual_reports/:year",         to: "annual_reports#show"
    patch "annual_reports/:year",         to: "annual_reports#update"
    post  "annual_reports/:year/publish", to: "annual_reports#publish"
  end

  # Módulo 32a (ADR 0050; contrato §4): urgência (UPA), sessão do dashboard.
  # Dado do paciente só no corpo (a busca de pessoa é POST); ids na URL.
  scope "/urgency", module: :urgency, as: :urgency do
    # Leitos da observação (§3; Q1): cadastro do municipal_admin, escrita com step-up.
    resources :beds, only: %i[index create update]
    # Recepção: busca de pessoa e chegada com senha ou paciente provisório (§4, Q4).
    post  "person_lookup",       to: "person_lookups#create"
    post  "arrivals",            to: "arrivals#create"
    # Enfermagem (2235): classificação e reclassificação; prévia da cor sem gravar (§5, Q1).
    post  "encounters/:id/classifications", to: "classifications#create", as: :encounter_classifications
    post  "suggest",             to: "suggestions#create"
    # Fila por cor (§6, Q6; sem trilha) e a chamada para a classificação (§6, Q7).
    get   "queue",               to: "queue#show"
    post  "encounters/:id/call_for_classification", to: "encounters#call_for_classification",
                                                    as: :encounter_call_for_classification
    # Recepção: identificação do provisório, uma vez só (§4, R4; Q5, Q17, Q23).
    post  "encounters/:id/identify", to: "encounters#identify", as: :encounter_identify
    # Recepção: os provisórios a identificar, abertos ou fechados há até 7 dias (Q29; trilha).
    get   "provisional_encounters", to: "provisional_encounters#index"
    # Desfecho (médico; recepção e enfermagem só a evasão e o registro por
    # engano) e os retornos pedidos à UBS (§7, Q10, Q11, Q20, Q25).
    post  "encounters/:id/outcome", to: "encounters#outcome", as: :encounter_outcome
    get   "counter_referrals",   to: "counter_referrals#index"
    # Detalhe do encontro (§14 Q6, Q19; trilha) e o painel do gestor (§11,
    # Q15, Q25; só contagens, sem trilha).
    get   "encounters/:id",      to: "encounters#show", as: :encounter
    get   "dashboard",           to: "dashboard#show"
    # Módulo 32b (§4, Q2, Q3): o mapa da observação (polling, sem trilha), a
    # entrada ou troca de leito e a saída sem desfecho (2235*/225*).
    get   "observation",         to: "observations#show"
    post  "encounters/:id/observation",     to: "observations#create", as: :encounter_observation
    post  "encounters/:id/observation/end", to: "observations#finish", as: :encounter_observation_end
    # Prescrição interna do médico, em versões, e a busca de medicamento dela
    # (§5, P1, Q4; a busca pelo corpo, sem clinical_documents).
    post  "encounters/:id/prescriptions",   to: "prescriptions#create", as: :encounter_prescriptions
    post  "prescriptions/:id/suspend",      to: "prescriptions#suspend", as: :prescription_suspend
    post  "medication_search",              to: "medication_searches#create"
    # Aprazamento calculado na leitura (§5, Q5; trilha medication_schedule).
    get   "encounters/:id/medication_schedule", to: "medication_schedules#show", as: :encounter_medication_schedule
    # A checagem de um horário (§6, Q5, Q6): imutável; o item só do corpo.
    post  "administrations",                to: "administrations#create"
  end

  # Módulo 32a (ADR 0050; contrato §8 e §14 Q8): TV da sala de espera. As
  # TVs (admin, sessão do dashboard com step-up); o pareamento e o painel sem
  # sessão, com o token no cabeçalho X-Display-Token.
  scope "/waiting_room", module: :waiting_room, as: :waiting_room do
    get   "displays",                   to: "displays#index"
    post  "displays",                   to: "displays#create"
    patch "displays/:id",               to: "displays#update"
    post  "displays/:id/pairing_code",  to: "displays#pairing_code", as: :display_pairing_code
    post  "displays/:id/revoke",        to: "displays#revoke", as: :display_revoke
    post  "pair",                       to: "pairings#create"
    get   "board",                      to: "boards#show"
  end

  # Módulo 29 (ADR 0047; contrato §15): sala de vacina, sessão do dashboard.
  scope "/vaccination", module: :vaccination, as: :vaccination do
    # Administração (municipal_admin; escrita com step-up): salas, equipe, rede de frio e go-live.
    get    "admin/rooms",                 to: "admin/rooms#index"
    post   "admin/rooms",                 to: "admin/rooms#create"
    patch  "admin/rooms/:id",             to: "admin/rooms#update"
    post   "admin/rooms/:id/staff",       to: "admin/room_staff#create"
    delete "admin/rooms/:id/staff",       to: "admin/room_staff#destroy"
    post   "admin/cold_chain_central",    to: "admin/cold_chain_central#create"
    get    "admin/settings",              to: "admin/settings#show"
    patch  "admin/settings",              to: "admin/settings#update"
    # Locais da pessoa (salas com o papel; rede de frio).
    get    "my_locations",                to: "locations#index"
    # Catálogo, terminologias e calendário (§4; sem trilha).
    get    "catalog",                     to: "catalog#show"
    # Sala: busca de pessoa, caderneta e conferência (§5; §15 V3; nominais, com trilha).
    post   "rooms/:room_id/person_lookup", to: "person_lookups#create"
    post   "rooms/:room_id/patients/duplicates", to: "duplicates#create"
    post   "rooms/:room_id/card",          to: "cards#create"
    post   "rooms/:room_id/checks",        to: "checks#create"
    # Frascos multidose (§3; §15 V14).
    post   "rooms/:room_id/vials",         to: "vials#create"
    get    "rooms/:room_id/vials",         to: "vials#index"
    post   "vials/:id/close_out",          to: "vials#close_out"
    # Dose aplicada (§5; §15 V5, V6) e a leitura nominal da dose (§15 V10; com trilha).
    post   "rooms/:room_id/immunizations", to: "immunizations#create"
    get    "immunizations/:id",            to: "immunizations#show"
    # Transcrição, cancelamento com substituição (§5; §15 V6, V7) e pendências do envio (§15 V8).
    post   "rooms/:room_id/transcriptions", to: "transcriptions#create"
    post   "immunizations/:id/cancel",     to: "immunizations#cancel"
    # ESAVI a partir da dose (Desvio 17; §15 V12): abre (ou devolve) a notificação do módulo 25.
    post   "immunizations/:id/esavi",      to: "immunizations#esavi"
    get    "rooms/:room_id/pending",       to: "pending#index"
    # Painel da vacinação (§15 V14 = D13): contagens, sem trilha.
    get    "dashboard",                    to: "dashboard#show"
    # Resumo mensal de imunobiológicos (§7; §15 V14 = D8): contagens, sem trilha.
    get    "rooms/:room_id/monthly_summary",      to: "summaries#room"
    get    "cold_chain_central/monthly_summary",  to: "summaries#cold_chain"
    # Cadeia de frio (§8; §15 V14 = D9 do dashboard).
    get    "cold_chain/equipments",              to: "cold_chain#index"
    post   "cold_chain/equipments",              to: "cold_chain#create"
    patch  "cold_chain/equipments/:id",          to: "cold_chain#update"
    post   "cold_chain/equipments/:id/readings", to: "cold_chain#readings"
    post   "cold_chain/excursions/:id/decide",   to: "cold_chain#decide"
    get    "cold_chain/status",                  to: "cold_chain#status"
  end

  # Módulo 23 (ADR 0040; contrato §3–§6): linhas de cuidado, sessão do dashboard.
  scope "/care_lines", module: "care_lines", as: "care_lines" do
    get   "admin/templates", to: "admin#templates"
    get   "admin/lines",     to: "admin#index"
    post  "admin/lines",     to: "admin#create"
    patch "admin/lines/:id", to: "admin#update"
    get   "lines",           to: "lookups#lines"
    get   "teams",           to: "lookups#teams"
    # Painel, sugestões e busca ativa (contrato §4–§5; §11 T3). As rotas
    # literais (count, overdue/count) vêm antes de `:id`.
    get   "suggestions",               to: "suggestions#index"
    get   "suggestions/count",         to: "suggestions#count"
    post  "suggestions/:id/accept",    to: "suggestions#accept"
    post  "suggestions/:id/dismiss",   to: "suggestions#dismiss"
    get   "enrollments",               to: "enrollments#index"
    get   "enrollments/overdue/count", to: "enrollments#overdue_count"
    post  "enrollments",               to: "enrollments#create"
    get   "enrollments/:id",           to: "enrollments#show"
    post  "enrollments/:id/end",       to: "enrollments#end_enrollment"
    post  "enrollments/:id/contacts",  to: "enrollments#contacts"
    post  "enrollments/:id/appointment_request", to: "enrollments#appointment_request"
    post  "person_lookup",             to: "person_lookups#create"
    get   "preview",                   to: "previews#show"
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

  # Módulo 24a (ADR 0042; contrato §3, §14 L2): cadastro territorial, sessão do
  # dashboard. As rotas do 11 (/territory/neighborhoods) seguem no TerritoryController.
  scope "/territory", module: "territory_registry", as: "territory_registry" do
    get   "admin/teams",           to: "admin_teams#index"
    get   "admin/micro_areas",     to: "micro_areas#index"
    post  "admin/micro_areas",     to: "micro_areas#create"
    patch "admin/micro_areas/:id", to: "micro_areas#update"
    get   "households",              to: "households#index"
    post  "households",              to: "households#create"
    get   "households/:id",          to: "households#show"
    patch "households/:id",          to: "households#update"
    post  "households/:id/families", to: "families#create"
    patch "families/:id",            to: "families#update"
    post  "families/:id/replace_responsible", to: "families#replace_responsible"
    get   "teams",                   to: "teams#index"
    post  "person_lookup",           to: "person_lookups#create"
    post  "patients/duplicates",     to: "duplicates#create"
    get   "registrations",           to: "registrations#index"
    post  "registrations",           to: "registrations#create"
    get   "registrations/:id",       to: "registrations#show"
    patch "registrations/:id",       to: "registrations#update"
    post  "registrations/:id/exit",  to: "registrations#exit"
    get   "registry_status",         to: "registry_status#index"
    get   "registry_status/count",   to: "registry_status#count"
  end

  # Módulo 24b (ADR 0052; contrato §6): visita domiciliar, sessão do dashboard,
  # gate `home_visits`. Rotas de membro só com id UUID (ruling A9); dado de
  # pessoa e texto só no corpo.
  scope "/home_visits", module: :home_visits, as: :home_visits do
    member_id = { id: /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/ }
    get  "context",                 to: "context#show"
    get  "assignments",             to: "assignments#index"
    post "assignments",             to: "assignments#create"
    post "assignments/:id/end",     to: "assignments#end_assignment", constraints: member_id
    post "people/lookup",           to: "people#lookup"
    post "people/duplicates",       to: "people#duplicates"
    get  "days/today",              to: "days#today"
    get  "days",                    to: "days#index"
    get  "days/:id",                to: "days#show", constraints: member_id
    post "days/:id/close",          to: "days#close", constraints: member_id
    get  "count",                   to: "visits#count"
    get  "",                        to: "visits#index"
    post "",                        to: "visits#create"
    get  ":id",                     to: "visits#show", constraints: member_id
    post ":id/withdraw",            to: "visits#withdraw", constraints: member_id
  end

  # Módulo 24b (ADR 0052; contrato §7): atividade coletiva, sessão do
  # dashboard, gate `collective_activities`. Dado de pessoa e texto só no corpo.
  scope "/collective_activities", module: :collective_activities, as: :collective_activities do
    post "people/lookup",           to: "people#lookup"
    post "people/duplicates",       to: "people#duplicates"
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

    # Linhas de cuidado (ADR 0040; contrato §7). A condição só no corpo (§11 T1).
    get    "declared_conditions", to: "declared_conditions#index"
    post   "declared_conditions", to: "declared_conditions#create"
    delete "declared_conditions", to: "declared_conditions#destroy"
    get    "care",                to: "care#show"

    # Meus encaminhamentos (ADR 0044; contrato §9, G3): citizen_id, par validado.
    get "regulation_requests", to: "regulation_requests#index"

    # Caderneta de vacinação (ADR 0047; contrato §9, W1): citizen_id, par validado.
    get "vaccinations", to: "vaccinations#index"

    # Minhas viagens (ADR 0048; contrato §8, §14 T14): citizen_id, par validado.
    get "trips", to: "trips#index"

    # Ouvidoria (ADR 0051; contrato §3): o anexo do cidadão sobe, não baixa
    # (Q14); "Minhas manifestações" e o registro (Task 8). Contrato §4 (Task
    # 9): a configuração pública e a denúncia anônima, sem sessão.
    scope "ombudsman", module: "ombudsman", as: "ombudsman" do
      post "attachments",        to: "attachments#create"
      get  "manifestations",     to: "manifestations#index"
      get  "manifestations/:id", to: "manifestations#show"
      post "manifestations",     to: "manifestations#create"
      post "manifestations/:id/complement",     to: "manifestations#complement"
      post "manifestations/:id/reopen_request", to: "manifestations#reopen_request"
      post "manifestations/:id/satisfaction",   to: "manifestations#satisfaction"
      get  "public_config",      to: "public_configs#show"
      # Sem sufixo de formato (Q60): `.json` não casa, e a máscara do IP no log vale só para o caminho exato.
      post "anonymous_reports",  to: "anonymous_reports#create", format: false
    end
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
