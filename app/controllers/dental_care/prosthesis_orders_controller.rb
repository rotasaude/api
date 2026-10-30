# Pedidos de prótese e laboratórios (ADR 0046; Desvio 12; contrato §16 O10,
# O27). Corpo JSON; nada de paciente, laboratório ou motivo na URL. A lista é
# nominal: por paciente, o acesso é o do prontuário; por unidade, o vínculo
# odontológico nela — nos dois casos uma trilha por paciente mostrado.
module DentalCare
  class ProsthesisOrdersController < BaseController
    LIST_GRANT = ClinicalRecord::Access::Grant.new(kind: :prosthesis_unit_list, opening: nil, reason: nil)
    ADMIN_GRANT = ClinicalRecord::Access::Grant.new(kind: :administrative, opening: nil, reason: nil)
    PRELOAD = [ :patient, :health_unit, :care_provider, { stages: { by_user: :professional } } ].freeze

    def create
      result = CreateProsthesisOrder.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: present(result.payload.fetch(:order)), status: :created
    end

    def stage
      order = uuid?(params[:id]) ? DentalProsthesisOrder.find_by(id: params[:id]) : nil
      return not_found unless order

      result = ChangeProsthesisStage.call(order: order, stage: body["stage"], reason: body["reason"], by: Current.user)
      return render_failure(result) if result.failure?

      shown = result.payload.fetch(:order)
      Trail.viewed!(patient: shown.patient, user: Current.user, grant: Current.user.has_role?("municipal_admin") ? ADMIN_GRANT : LIST_GRANT)
      render json: present(shown)
    end

    def index
      patient_id = params[:patient_id].presence
      unit_id = params[:health_unit_id].presence
      return render_refusal("health_unit_id") unless patient_id || unit_id
      return render_refusal("patient_id") if patient_id && !uuid?(patient_id)
      return render_refusal("health_unit_id") if unit_id && !uuid?(unit_id)

      stage = params[:stage].presence
      return render_refusal("stage") if stage && !Catalog::PROSTHESIS_STAGES.include?(stage.to_s)

      limit = page_limit or return
      cursor = params.key?(:before) ? Pharmacy::Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      grant = patient_id ? patient_grant(patient_id) : unit_grant(unit_id)
      return unless grant

      scope = DentalProsthesisOrder.all
      scope = scope.where(patient_id: patient_id) if patient_id
      scope = scope.where(health_unit_id: unit_id) if unit_id
      scope = scope.where(stage: stage) if stage
      scope = scope.where("(dental_prosthesis_orders.created_at, dental_prosthesis_orders.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(*PRELOAD).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      page.map(&:patient).uniq.each { |patient| Trail.viewed!(patient: patient, user: Current.user, grant: grant) }
      names = Json.procedure_names(page.map(&:procedure_code))
      render json: { orders: page.map { |order| Json.prosthesis_order(order, names: names) },
                     next_before: rows.size > limit ? Pharmacy::Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    def laboratories
      return forbid if Consultations::Authorization.allowed_links(user: Current.user, kind: "dental").empty?

      providers = CareProvider.active_providers.order(:name, :id).pluck(:id, :name)
      render json: { laboratories: providers.map { |id, name| { id: id, name: name } } }
    end

    private

    # Por paciente: acesso do prontuário (404 se não existe). Responde e devolve nil na recusa.
    def patient_grant(id)
      patient = Patient.find_by(id: id)
      return not_found && nil unless patient

      grant = ClinicalRecord::Access.call(user: Current.user, patient: patient)
      return forbid(grant.reason.to_s) && nil unless grant.allowed?

      grant
    end

    # Por unidade: vínculo ativo de papel odontológico nela.
    def unit_grant(unit_id)
      status, = Consultations::Authorization.link_for(user: Current.user, health_unit_id: unit_id, kind: "dental")
      return forbid && nil unless status == :ok

      LIST_GRANT
    end

    def present(order)
      order = DentalProsthesisOrder.includes(*PRELOAD).find(order.id)
      Json.prosthesis_order(order, names: Json.procedure_names([ order.procedure_code ]))
    end
  end
end
