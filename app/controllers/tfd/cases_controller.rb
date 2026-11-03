# Processo de TFD (contrato §6; §14 T8, T9; plano, Desvios 10–12, 18):
#   POST  /tfd/cases             laudo em rascunho (médico 225*) → 201 <tfd-case>
#   PATCH /tfd/cases/:id         substitui o laudo (só o autor, draft/returned) → <tfd-case>
#   POST  /tfd/cases/:id/submit  envio à comissão (recusas todas juntas) → <tfd-case>
#   GET   /tfd/cases?status=&before=   fila da comissão, sem dado clínico
#   GET   /tfd/my_cases          os pedidos do médico autor, sem dado clínico
#   POST  /tfd/cases/:id/read    <tfd-case> nominal com trilha (comissão ou autor)
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

    before_action :load_case, only: %i[update submit read]

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

    private

    def load_case
      @tfd_case = uuid?(params[:id]) ? TfdCase.find_by(id: params[:id]) : nil
      not_found unless @tfd_case
    end
  end
end
