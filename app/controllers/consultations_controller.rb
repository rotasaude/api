# Consulta da APS (ADR 0031; spec §4; contratos §4/§9). Interruptor clinical_record
# utilizável e papel health_professional em toda rota (a recepção recebe 403);
# vínculo, CBO e autoria nos comandos. Ler a consulta deixa trilha. A autora
# lê e imprime a finalizada a qualquer momento; impresso e adendo são só dela
# (decisão do usuário 2026-10-09).
class ConsultationsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ClinicalRecordGate
  include ReportPeriod

  wrap_parameters false

  ERROR_STATUS = {
    missing_role: :forbidden, missing_link: :forbidden, cbo_not_allowed: :forbidden, not_author: :forbidden,
    out_of_context: :forbidden, feature_disabled: :forbidden,
    not_in_care: :conflict, not_caller: :conflict, already_exists: :conflict, citizen_not_verified: :conflict,
    not_draft: :conflict, not_finalized: :conflict, already_closed: :conflict, consultation_in_progress: :conflict
  }.freeze
  DRAFT_KEYS = (Consultation::TEXT_FIELDS + %w[vitals care_type evaluated_problems conducts exam_requests]).freeze

  before_action :require_clinical_record!
  before_action :require_professional, except: :options
  before_action :require_options_reader, only: :options
  before_action :set_consultation, except: %i[options create mine]

  # cid10_allowed_for_cbo: QUALQUER vínculo ativo permitido do usuário com CBO
  # de médico (contrato §9; physicians_only), não só o primeiro. Quem só é admin
  # municipal (sem health_professional) lê os rótulos, com cid10 false.
  def options
    cid10 = CitizenVerificationPolicy.new(Current.user, nil).care? &&
            Consultations::Authorization.allowed_links(user: Current.user)
                                        .any? { |link| Ledi::ConsultationMapping.cid10_allowed?(link.cbo_code) }
    # Contrato §4: o código vai como string.
    as_strings = ->(rows) { rows.map { |row| row.merge(code: row[:code].to_s) } }
    render json: { care_types: as_strings.(Ledi::ConsultationMapping.care_types),
                   conducts: as_strings.(Ledi::ConsultationMapping.conducts), cid10_allowed_for_cbo: cid10 }
  end

  # Minhas consultas: as finalizadas da autora, sem conteúdo clínico e sem
  # trilha (só a leitura da consulta publica clinical_record.viewed).
  def mine
    from, to = period
    return render_invalid_period if invalid_period?(from, to)

    list = Consultation.finalized_list(author_user_id: Current.user.id, from: from, to: to)
    render json: { consultations: list.map { |c| Consultations::Json.list_item(c) } }
  end

  def create
    attendance = Attendance.find_by(id: params[:id])
    return not_found unless attendance

    result = Consultations::Start.call(attendance: attendance, by: Current.user)
    return failure(result) if result.failure?

    render json: Consultations::Json.consultation(result.payload[:consultation]), status: :created
  end

  def show
    return forbid("not_author") if @consultation.draft? && @consultation.author_user_id != Current.user.id

    grant = read_grant
    return forbid(grant.reason.to_s) unless grant.allowed?

    ClinicalRecord::Trail.viewed!(patient: @consultation.patient, user: Current.user, grant: grant)
    render json: Consultations::Json.consultation(@consultation)
  end

  def update
    result = Consultations::SaveDraft.call(consultation: @consultation, params: body.slice(*DRAFT_KEYS), by: Current.user)
    respond(result)
  end

  def finalize
    outcome = body["outcome"].is_a?(Hash) ? body["outcome"] : {}
    respond(Consultations::Finalize.call(consultation: @consultation, outcome_params: outcome, by: Current.user))
  end

  def addenda
    # `opening_id` (do dashboard antigo) é aceito e ignorado: o adendo é só da autora.
    result = Consultations::AddAddendum.call(consultation: @consultation, by: Current.user, reason: body["reason"],
                                             text: body["text"], changes: body["changes"])
    return failure(result) if result.failure?

    render json: Consultations::Json.addendum(result.payload[:addendum]), status: :created
  end

  # Spec §4: PDF na hora, nunca gravado nem em cache; o nome do arquivo não
  # leva dado da pessoa. Só da autora (não revela o estado a quem não é).
  def print
    return forbid("not_author") if @consultation.author_user_id != Current.user.id
    return render(json: { error: "not_finalized" }, status: :conflict) unless @consultation.finalized?

    grant = read_grant
    return forbid(grant.reason.to_s) unless grant.allowed?
    return render(json: { error: "patient_name_missing" }, status: :conflict) if @consultation.patient.full_name.blank?

    ClinicalRecord::Trail.viewed!(patient: @consultation.patient, user: Current.user, grant: grant)
    response.headers["Cache-Control"] = "no-store"
    send_data Consultations::Print.call(@consultation), type: "application/pdf", disposition: "inline", filename: "consulta.pdf"
  end

  private

  # Dado estático (sem conteúdo clínico, sem trilha): profissional OU admin municipal.
  def require_options_reader
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid("missing_role") unless policy.care? || policy.manage?
  end

  def set_consultation
    @consultation = Consultation.find_by(id: params[:id])
    not_found unless @consultation
  end

  # Rascunho: só o autor chega aqui, e ele está em contexto (o rascunho só
  # existe com o atendimento in_care chamado por ele). Finalizada: a autora
  # (:author), senão contexto ou abertura (ClinicalRecord::Access.for_consultation).
  def read_grant
    return ClinicalRecord::Access::Grant.new(kind: :in_context, opening: nil, reason: nil) if @consultation.draft?

    ClinicalRecord::Access.for_consultation(user: Current.user, consultation: @consultation)
  end

  def respond(result)
    return failure(result) if result.failure?

    render json: Consultations::Json.consultation(result.payload[:consultation].reload)
  end

  def failure(result)
    return render(json: { error: "feature_disabled", feature: ClinicalRecord::Gate::KEY }, status: :forbidden) if result.reason == :feature_disabled

    render_failure(result, ERROR_STATUS)
  end

  def body = params.to_unsafe_h.except("controller", "action", "id")

  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
