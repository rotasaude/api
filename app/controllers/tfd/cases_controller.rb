# Processo de TFD (contrato §6; §14 T8, T9; plano, Desvios 10–12, 18):
#   POST  /tfd/cases             laudo em rascunho (médico 225*) → 201 <tfd-case>
#   PATCH /tfd/cases/:id         substitui o laudo (só o autor, draft/returned) → <tfd-case>
#   POST  /tfd/cases/:id/submit  envio à comissão (recusas todas juntas) → <tfd-case>
#   GET   /tfd/cases?status=&before=   fila da comissão, sem dado clínico
#   GET   /tfd/my_cases          os pedidos do médico autor, sem dado clínico
#   POST  /tfd/cases/:id/read    <tfd-case> nominal com trilha (comissão ou autor)
# Comissão (Task 10; contrato §6; §14 T8, T10, T12, T25), papel antes do
# step-up (outro papel → 403 missing_role; sem step-up → 401 mfa_required):
#   POST  /tfd/cases/:id/decide       { decision, reason }
#   POST  /tfd/cases/:id/appointment  { appointment_at, provider_id? }
#   POST  /tfd/cases/:id/inpatient    { from, to? }
#   POST  /tfd/cases/:id/cancel       { reason }
# Toda escrita devolve o <tfd-case> inteiro, sem trilha nova (a trilha é só do
# read). Dado do paciente e laudo só no corpo JSON.
#
# Fila: todas as situações menos `draft`, do mais antigo para o mais novo por
# (submitted_at, id), em páginas de PAGE. `next_before` é o cursor opaco do
# último item da página (nome da convenção das listas; aqui quer dizer "os
# seguintes, depois deste", na ordem crescente); nulo na última página.
module Tfd
  class CasesController < BaseController
    PAGE = 50
    MINE_LIMIT = 100
    QUEUE_STATUSES = (Catalog::STATUSES - %w[draft]).freeze
    PRELOAD = %i[patient transport_destination].freeze

    COMMITTEE_WRITES = %i[decide appointment inpatient cancel].freeze
    COMMITTEE_KEYS = { decide: %w[decision reason], appointment: %w[appointment_at provider_id],
                       inpatient: %w[from to], cancel: %w[reason] }.freeze

    before_action :require_committee!, only: COMMITTEE_WRITES
    before_action :require_step_up!, only: COMMITTEE_WRITES
    before_action :load_case, only: %i[update submit read] + COMMITTEE_WRITES
    before_action :known_keys!, only: COMMITTEE_WRITES

    def index
      return forbid unless Access.committee?(Current.user)
      return unless query_only!("status", "before")

      query = request.query_parameters
      status = query["status"]
      return render_refusal("status") if status && !QUEUE_STATUSES.include?(status)

      scope = TfdCase.where(status: status || QUEUE_STATUSES)
      if query.key?("before")
        at, id = CareRegulation::Cursor.decode_page(query["before"])
        scope = scope.where("(tfd_cases.submitted_at, tfd_cases.id) > (?, ?)", at, id)
      end
      rows = scope.includes(*PRELOAD).order(:submitted_at, :id).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      last = page.last
      render json: { items: page.map { |row| Json.list_item(row) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(last.submitted_at, last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def mine
      return unless require_physician!
      return unless query_only!

      rows = TfdCase.where(requester_user_id: Current.user.id).includes(*PRELOAD).order(updated_at: :desc, id: :desc).limit(MINE_LIMIT)
      render json: { items: rows.map { |row| Json.list_item(row) } }
    end

    def create
      return unless query_only!

      result = SaveCase.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.case(result.payload.fetch(:tfd_case).reload), status: :created
    end

    def update
      return unless query_only!

      result = SaveCase.call(attrs: body, by: Current.user, tfd_case: @tfd_case)
      return render_failure(result) if result.failure?

      render json: Json.case(result.payload.fetch(:tfd_case).reload)
    end

    def submit
      return unless query_only!

      result = SubmitCase.call(tfd_case: @tfd_case, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.case(result.payload.fetch(:tfd_case).reload)
    end

    # Comissão: qualquer processo enviado (rascunho → 404); autor: o seu, em
    # qualquer situação. Outro profissional → 404; outro papel → 403.
    def read
      return unless query_only!

      user = Current.user
      author = @tfd_case.requester_user_id == user.id
      committee = Access.committee?(user) && @tfd_case.status != "draft"
      unless author || committee
        return not_found if Access.committee?(user) || user.has_role?("health_professional")

        return forbid
      end

      Trail.person_viewed!(user: user, patient_id: @tfd_case.patient_id)
      render json: Json.case(@tfd_case)
    end

    def decide
      committee_write { DecideCase.call(tfd_case: @tfd_case, decision: body_param("decision"), reason: body_param("reason"), by: Current.user) }
    end

    def appointment
      committee_write do
        SetAppointment.call(tfd_case: @tfd_case, appointment_at: body_param("appointment_at"), provider_id: body_param("provider_id"),
                            by: Current.user)
      end
    end

    def inpatient
      committee_write { RecordInpatient.call(tfd_case: @tfd_case, from: body_param("from"), to: body_param("to"), by: Current.user) }
    end

    def cancel
      committee_write { CancelCase.call(tfd_case: @tfd_case, reason: body_param("reason"), by: Current.user) }
    end

    private

    def committee_write
      result = yield
      return render_failure(result) if result.failure?

      render json: Json.case(result.payload.fetch(:tfd_case).reload)
    end

    def require_committee!
      forbid unless Access.committee?(Current.user)
    end

    # Corpo só com as chaves da rota (nenhuma na query): a primeira de fora → 422 invalid_request.
    def known_keys!
      return unless query_only!

      unknown = (body.keys - COMMITTEE_KEYS.fetch(action_name.to_sym)).first
      render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown
    end

    # Rascunho é invisível à comissão: nas escritas dela, 404 (como no read).
    def load_case
      @tfd_case = uuid?(params[:id]) ? TfdCase.find_by(id: params[:id]) : nil
      @tfd_case = nil if @tfd_case&.status == "draft" && COMMITTEE_WRITES.include?(action_name.to_sym)
      not_found unless @tfd_case
    end
  end
end
