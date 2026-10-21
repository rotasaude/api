# /billing/procedures (ADR 0039; contrato §3 com B1, B2, B5 e B12 do
# dashboard): gravar pelo atendimento ou pela consulta (paciente derivado;
# patient_id, se vier, tem de bater), avulso do profissional na própria
# unidade ou lançamento do faturista (professional_user_id e cbo_code só
# dele); listar (faturista e admin tudo; profissional os próprios por
# paciente, ou os do atendimento da unidade em que tem vínculo); cancelar
# (o profissional os próprios; o faturista qualquer um).
module Billing
  class ProceduresController < BaseController
    RECORD_KEYS = %w[performed_on sigtap_code quantity cid10 character].freeze

    def create
      clerk = Access.clerk?(Current.user)
      return forbid unless clerk || Current.user.has_role?("health_professional")
      return forbid if !clerk && (params.key?(:professional_user_id) || params.key?(:cbo_code))

      context = if params[:consultation_id].present? then consultation_context
                elsif params[:attendance_id].present? then attendance_context
                else standalone_context(clerk)
                end
      return if performed?

      result = Record.call(params: RECORD_KEYS.to_h { |key| [ key, params[key] ] }, recorded_by: Current.user, **context)
      return render_failure(result) if result.failure?

      render json: Json.procedure(result.payload[:procedure]), status: :created
    end

    def index
      scope = PerformedProcedure.includes(:patient, :health_unit, :exam_provider, professional_user: :professional)
      unless Access.reader?(Current.user)
        professional = Current.user.has_role?("health_professional")
        if uuid?(params[:attendance_id])
          attendance = Attendance.find_by(id: params[:attendance_id])
          return not_found unless attendance
          return forbid("missing_link") unless professional && Staff.linked?(Current.user, attendance.health_unit_id)
        elsif professional && uuid?(params[:patient_id])
          scope = scope.where(professional_user_id: Current.user.id)
        else
          return forbid
        end
      end
      scope = scope.where(attendance_id: params[:attendance_id]) if uuid?(params[:attendance_id])
      scope = scope.where(patient_id: params[:patient_id]) if uuid?(params[:patient_id])
      scope = filtered(scope)
      return if performed?

      cursor = Exams::Cursor.decode(params[:before])
      scope = scope.where("(performed_procedures.created_at, performed_procedures.id) < (?, ?)", *cursor) if cursor
      limit = Timeline::Query.limit(params[:limit])
      rows = scope.order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { procedures: Json.procedures(page), next_before: rows.size > limit ? Exams::Cursor.encode(page.last) : nil }
    rescue Exams::Cursor::Invalid
      render json: { error: "invalid_cursor" }, status: :unprocessable_entity
    end

    def cancel
      procedure = uuid?(params[:id]) ? PerformedProcedure.find_by(id: params[:id]) : nil
      own = procedure && procedure.professional_user_id == Current.user.id
      return not_found unless procedure && (own || Access.reader?(Current.user))
      return forbid unless own || Access.clerk?(Current.user)

      result = Cancel.call(procedure: procedure, reason: params[:reason], by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.procedure(result.payload[:procedure])
    end

    private

    def filtered(scope)
      if params[:establishment_id].present?
        key = { "health_unit" => :health_unit_id, "lab_provider" => :exam_provider_id }[params[:establishment_type]]
        return invalid_filter unless key && uuid?(params[:establishment_id])

        scope = scope.where(key => params[:establishment_id])
      end
      if params[:competence].present?
        return invalid_filter unless params[:competence].is_a?(String) && params[:competence].match?(Periods::COMPETENCE)

        scope = scope.where(billing_competence: params[:competence])
      end
      scope = scope.where(billable: params[:billable] == "true") if %w[true false].include?(params[:billable])
      if params[:reason].present?
        return invalid_filter unless Critic::REASONS.include?(params[:reason])

        scope = scope.where("? = ANY (performed_procedures.blocking_reasons)", params[:reason])
      end
      scope
    end

    def consultation_context
      consultation = uuid?(params[:consultation_id]) ? Consultation.find_by(id: params[:consultation_id]) : nil
      return not_found unless consultation
      return render_error(:invalid_patient) unless patient_matches?(consultation.patient_id)
      return forbid("not_author") unless consultation.author_user_id == Current.user.id

      unit = consultation.attendance.health_unit
      return invalid_establishment unless same_unit?(unit)

      { patient: consultation.patient, establishment: Establishment.for_unit(unit), professional: Current.user,
        cbo_code: consultation.cbo_code, source: "consultation", consultation: consultation }
    end

    # B1: o paciente vem do par do atendimento (Patients::Resolve, se o par
    # validado ainda não tem paciente).
    def attendance_context
      attendance = uuid?(params[:attendance_id]) ? Attendance.includes(:citizen, :health_unit).find_by(id: params[:attendance_id]) : nil
      return not_found unless attendance
      return forbid("missing_link") unless Current.user.has_role?("health_professional") && Staff.linked?(Current.user, attendance.health_unit_id)

      resolved = attendance.citizen.patient_id ? nil : Patients::Resolve.call(attendance.citizen)
      return render_failure(resolved) if resolved&.failure?

      patient = resolved ? resolved.payload[:patient] : Patient.find(attendance.citizen.patient_id)
      return render_error(:invalid_patient) unless patient_matches?(patient.id)
      return invalid_establishment unless same_unit?(attendance.health_unit)

      { patient: patient, establishment: Establishment.for_unit(attendance.health_unit), professional: Current.user, source: "attendance",
        attendance: attendance }
    end

    def standalone_context(clerk)
      patient = uuid?(params[:patient_id]) ? Patient.find_by(id: params[:patient_id]) : nil
      return not_found unless patient

      establishment = Establishment.find(*establishment_param)
      return invalid_establishment unless establishment
      return clerk_context(patient, establishment) if clerk
      return forbid unless establishment.type == "health_unit" && Staff.linked?(Current.user, establishment.id)

      { patient: patient, establishment: establishment, professional: Current.user, source: "manual" }
    end

    # B5: quem fez tem vínculo no estabelecimento (liberador ativo no
    # laboratório); o CBO, se vier, é um dos do vínculo.
    def clerk_context(patient, establishment)
      professional = uuid?(params[:professional_user_id]) ? User.find_by(id: params[:professional_user_id]) : nil
      return render_error(:invalid_professional) unless professional&.professional && Staff.eligible?(professional, establishment)

      cbo = params[:cbo_code].presence
      return render_error(:invalid_professional) if cbo && !Staff.cbos_for(professional, establishment).include?(cbo)

      { patient: patient, establishment: establishment, professional: professional, cbo_code: cbo, source: "manual" }
    end

    def patient_matches?(patient_id) = params[:patient_id].blank? || params[:patient_id] == patient_id

    # [type, id] do corpo; no atendimento e na consulta, se vier, tem de ser a unidade deles.
    def establishment_param
      value = params[:establishment]
      value.respond_to?(:key?) ? [ value[:type], value[:id] ] : [ nil, nil ]
    end

    def same_unit?(unit)
      type, id = establishment_param
      (type.nil? && id.nil?) || (type == "health_unit" && id == unit.id)
    end
  end
end
