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
    not_draft: :conflict, not_finalized: :conflict, already_closed: :conflict, consultation_in_progress: :conflict, conflict: :conflict
  }.freeze
  # Módulo 28: `dental` (<dental_fields>) só na consulta odontológica (SaveDraft).
  DRAFT_KEYS = (Consultation::TEXT_FIELDS + %w[vitals care_type evaluated_problems conducts exam_requests dental]).freeze

  before_action :require_clinical_record!
  before_action :require_professional, except: :options
  before_action :require_options_reader, only: :options
  before_action :set_consultation, except: %i[options create mine]

  # cid10_allowed_for_cbo: QUALQUER vínculo ativo permitido do usuário com CBO
  # de médico (contrato §9; physicians_only), não só o primeiro. Quem só é admin
  # municipal (sem health_professional) lê os rótulos, com cid10 false.
  # Módulo 28 (contrato §16 O4, O20): `kinds` e `dental_role` pelos CBOs dos
  # vínculos ativos e pelo interruptor dental_care; o vocabulário `dental`
  # vai sempre (a consulta retida segue legível com o interruptor desligado).
  def options
    # Desvio 9 (módulo 28): o vínculo de dentista (2232*) também permite CID-10,
    # mas só na consulta `dental` (ItemsInput) e com o interruptor dental_care
    # ligado (o mesmo `dental_role` de kinds_and_role); TSB/ASB não.
    roles = kinds_and_role
    cid10 = CitizenVerificationPolicy.new(Current.user, nil).care? &&
            (roles[:dental_role] == "dentist" ||
             Consultations::Authorization.allowed_links(user: Current.user)
                                         .any? { |link| Ledi::ConsultationMapping.cid10_allowed?(link.cbo_code) })
    # Contrato §4: o código vai como string.
    as_strings = ->(rows) { rows.map { |row| row.merge(code: row[:code].to_s) } }
    render json: { care_types: as_strings.(Ledi::ConsultationMapping.care_types),
                   conducts: as_strings.(Ledi::ConsultationMapping.conducts), cid10_allowed_for_cbo: cid10,
                   **roles, dental: DentalCare::Vocabulary.options }
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

    # Sem `kind` (ou nulo) → general, o contrato de antes do módulo 28; no
    # atendimento da UPA com encontro, urgency (módulo 32a, Desvio 14).
    result = Consultations::Start.call(attendance: attendance, by: Current.user, kind: body["kind"],
                                       baseline: body["baseline"].nil? ? false : body["baseline"])
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

  # Adendo da própria consulta (dashboard#12; decisão do usuário 2026-10-13): só a
  # lista de problemas do paciente, só para a autora da consulta finalizada, com
  # trilha author. Quem está em contexto já lê o prontuário pela rota do atendimento.
  def problems
    return forbid("not_author") if @consultation.draft?

    grant = read_grant
    return forbid(grant.reason.to_s) unless grant.allowed?
    return forbid("not_author") unless grant.kind == :author

    patient = @consultation.patient
    ClinicalRecord::Trail.viewed!(patient: patient, user: Current.user, grant: grant, consultation_id: @consultation.id)
    problems = patient.problems.order(Arel.sql("status = 'active' DESC"), :code).map { |p| ClinicalRecord::Json.problem(p) }
    render json: { problems: problems }
  end

  def update
    result = Consultations::SaveDraft.call(consultation: @consultation, params: body.slice(*DRAFT_KEYS), by: Current.user)
    respond(result)
  end

  # Módulo 26a (contrato §13 G12 #3): com o interruptor care_regulation
  # utilizável, `regulation_not_sent` (index, id, error, path; sem dado pessoal).
  def finalize
    # Como veio: o Finalize ignora o que não é objeto, e a urgência recusa
    # qualquer `outcome` (módulo 32a, Desvio 14).
    result = Consultations::Finalize.call(consultation: @consultation, outcome_params: body["outcome"], by: Current.user)
    return failure(result) if result.failure?

    render json: with_regulation(Consultations::Json.consultation(result.payload[:consultation].reload), result)
  end

  def addenda
    # `opening_id` (do dashboard antigo) é aceito e ignorado: o adendo é só da autora
    # (módulo 32b, Q8: ou de médico da UPA no encontro da urgência aberto; AddAddendum).
    result = Consultations::AddAddendum.call(consultation: @consultation, by: Current.user, reason: body["reason"],
                                             text: body["text"], changes: body["changes"])
    return failure(result) if result.failure?

    render json: with_regulation(Consultations::Json.addendum(result.payload[:addendum]), result), status: :created
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
    # ADR 0032 (Desvio 13): digital sem adendo → o próprio PAdES; senão o
    # impresso, com a seção de assinaturas quando houver pedido.
    bytes = Signatures::PrintReport.signed_pdf(@consultation) ||
            Consultations::Print.call(@consultation, report: Signatures::PrintReport.for(@consultation))
    send_data bytes, type: "application/pdf", disposition: "inline", filename: "consulta.pdf"
  end

  private

  # Dado estático (sem conteúdo clínico, sem trilha): profissional OU admin municipal.
  def require_options_reader
    policy = CitizenVerificationPolicy.new(Current.user, nil)
    forbid("missing_role") unless policy.care? || policy.manage?
  end

  # Descartada (card api#51) é casca sem conteúdo: para toda rota daqui é
  # inexistente (o mesmo 404), nunca o ramo da finalizada.
  def set_consultation
    @consultation = Consultation.where.not(status: "discarded").find_by(id: params[:id])
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

  # Módulo 32a (§14 Q10; preflight C-18): os kinds são os da tabela de CBO
  # (Cbos.kinds_for, intocada) MAIS `urgency` quando há vínculo 225* ativo numa
  # unidade `upa` com urgency_care utilizável (lido fora de transação). Nunca
  # substitui: o atendimento da UPA sem encontro (13) segue general; quem
  # escolhe o kind pelo encontro é o dashboard, e o Start impõe kind ↔ encontro.
  def kinds_and_role
    links = Consultations::Authorization.allowed_links(user: Current.user, kind: :any)
    ActiveRecord::Associations::Preloader.new(records: links, associations: :health_unit).call
    dental_care = DentalCare::Gate.usable?(Current.city)
    roles = consultation_cbos(links, dental_care).map { |cbo| Consultations::Cbos.role(cbo) }
    role = %i[dentist auxiliary].find { |r| roles.include?(r) }
    { kinds: consultation_kinds(links, dental_care), dental_role: role&.to_s }
  end

  def consultation_kinds(links, dental_care)
    cbos = consultation_cbos(links, dental_care)
    kinds = DentalCare::Catalog::KINDS.select { |kind| cbos.any? { |cbo| Consultations::Cbos.allowed?(cbo, kind: kind) } }
    kinds << "urgency" if urgency_link?(links)
    kinds
  end

  def urgency_link?(links)
    Urgency::Gate.usable?(Current.city) &&
      links.any? { |link| link.health_unit.upa? && Consultations::Cbos.allowed?(link.cbo_code, kind: "urgency") }
  end

  # Sem dental_care utilizável, os CBOs odontológicos não contam.
  def consultation_cbos(links, dental_care)
    cbos = links.map(&:cbo_code)
    dental_care ? cbos : cbos.reject { |cbo| Consultations::Cbos.role(cbo) }
  end

  def with_regulation(json, result)
    return json unless result.payload.key?(:regulation_not_sent)

    json.merge(regulation_not_sent: result.payload[:regulation_not_sent].map { |item| item.slice(:index, :id, :error, :path) })
  end

  def failure(result)
    if result.reason == :feature_disabled
      return render(json: { error: "feature_disabled", feature: result.details[:feature] || ClinicalRecord::Gate::KEY }, status: :forbidden)
    end

    render_failure(result, ERROR_STATUS)
  end

  def body = params.to_unsafe_h.except("controller", "action", "id")

  def not_found = render(json: { error: "not_found" }, status: :not_found)
end
