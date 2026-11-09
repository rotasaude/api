# Módulo 32a (ADR 0050): cidade da urgência (prontuário, ou o faturamento com
# billing: true), UPA (`upa!`, de BillingHelpers), a equipe da UPA (recepção,
# enfermagem 2235 — só ela classifica, contrato §14 Q2 —, médico 225), o
# administrador, o protocolo de classificação ativo (gravado direto, como o
# `acolhimento!`), pacientes pelo caminho real e os passos do encontro pelos
# comandos: chegada (Task 6), classificação (Task 7), chamada (Task 8),
# consulta (Task 10) e a TV pareada (Task 12). Tudo avaliado só na chamada: os
# helpers de comandos de tasks seguintes só são chamados pelos specs delas.
module UrgencyHelpers
  LEVELS = Urgency::Catalog::COLORS.zip([ 0, 10, 60, 120, 240 ]).map { |c, m| { "color" => c, "max_wait_minutes" => m } }.freeze
  # Contrato §14 Q1/Q3: a dor é a variável `pain_scale`, fora de `vitals`.
  RULES = [
    { "id" => "spo2-critica", "when" => { "lt" => [ "vitals.spo2", 90 ] }, "color" => "red", "criterion" => "SpO2 abaixo de 90%" },
    { "id" => "dor-intensa", "when" => { "gte" => [ "pain_scale", 8 ] }, "color" => "orange", "criterion" => "Dor intensa (8 a 10)" },
    { "id" => "febre-alta", "when" => { "gte" => [ "vitals.temperature_c", 39 ] }, "color" => "yellow", "criterion" => "Febre de 39 °C ou mais" },
    { "id" => "dor-moderada", "when" => { "gte" => [ "pain_scale", 4 ] }, "color" => "green", "criterion" => "Dor moderada (4 a 7)" }
  ].freeze
  PROTOCOL_KIND = "urgency_classification".freeze
  COMPLAINT = "Dor no peito há duas horas".freeze
  # Sem protocolo (ou com a cor diferente da sugerida) o banco exige a
  # justificativa (ck_urgency_classifications_justification).
  JUSTIFICATION = "Avaliação de enfermagem na porta da UPA".freeze

  # Prontuário (clinical_city!) ou o faturamento (billing_city!), com
  # `urgency_care` e, com waiting_room: true, `waiting_room_display`.
  def urgency_city!(billing: false, waiting_room: false)
    city = billing ? billing_city! : clinical_city!
    Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: WaitingRoom::Gate::KEY, enabled: true, maintainer: ledi_maintainer!) if waiting_room
    CityCatalog.reset_cache!
    city
  end

  def urgency_seq! = (@urgency_seq = (@urgency_seq || 900) + 1)

  def upa_reception! = (@upa_reception ||= staff_with("recepcao-upa-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier"))

  # Enfermeiro(a) com vínculo ativo na UPA (o técnico 3222 NÃO classifica).
  def upa_nurse!(unit, cbo: "223505") = screener!(unit, cbo: cbo, email: "enfermagem-upa-#{SecureRandom.hex(3)}@cidade.gov.br")

  def upa_doctor!(unit, cbo: "225125") = screener!(unit, cbo: cbo, email: "medico-upa-#{SecureRandom.hex(3)}@cidade.gov.br")

  # Administrador com MFA cadastrado. O `mfa_verified_at` recente é da sessão
  # (sessions.mfa_verified_at): em request spec, `stepped_up!(urgency_admin!)`.
  def urgency_admin!
    @urgency_admin ||= step_up_enrolled!(staff_with("admin-upa-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
  end

  # Protocolo de classificação ativo, gravado direto (o caminho real é o ciclo
  # assinado do 18). Um só ativo por cidade, pelo kind (Q16): o ativo anterior
  # volta a `published`, como no Protocols::Activate.
  def urgency_protocol!(rules: RULES, levels: LEVELS, version: 1, name: "classificacao-urgencia")
    ProtocolDefinition.active.where("definition->>'kind' = ?", PROTOCOL_KIND).update_all(status: "published")
    ProtocolDefinition.create!(name: name, version: version, status: "active", activated_at: Time.current,
                               definition: { "name" => name, "version" => version, "kind" => PROTOCOL_KIND,
                                             "levels" => levels, "classification_rules" => rules })
  end

  # CPF com os dois dígitos verificadores certos, um por n (faixa própria).
  def urgency_cpf(n)
    nums = format("%09d", 521_000_000 + n).chars.map(&:to_i)
    first = CitizenIdentity::Cpf.check_digit(nums)
    (nums + [ first, CitizenIdentity::Cpf.check_digit(nums + [ first ]) ]).join
  end

  # Paciente identificado pelo caminho real (Patients::CreateTyped), com CNS
  # válido e, com cpf: true, CPF válido (sem CPF: a justificativa 3 da ficha).
  def urgency_patient!(n, cpf: true)
    attrs = { "full_name" => "Carlos Eduardo Pinto", "birth_date" => (Date.new(1980, 1, 1) + n).iso8601,
              "sex" => n.even? ? "female" : "male", "mother_name" => "Maria Pinto",
              "cns" => Professionals::Cns.generate("urgency:#{n}") }
    attrs.merge!(cpf ? { "cpf" => urgency_cpf(n) } : { "no_cpf_reason" => "3" })
    result = Patients::CreateTyped.call(attrs: attrs, by: upa_reception!)
    raise "urgency_patient! recusado: #{result.reason}" if result.failure?

    result.payload.fetch(:patient)
  end

  # Chegada pela via real (Urgency::Arrive): paciente existente ou, com
  # `unidentified: "descrição"`, o provisório. Sem nenhum dos dois, um paciente
  # novo. Devolve o encontro.
  def arrived!(unit, patient: nil, unidentified: nil, by: upa_reception!)
    patient ||= urgency_patient!(urgency_seq!) unless unidentified
    result = Urgency::Arrive.call(health_unit_id: unit.id, patient_id: patient&.id,
                                  unidentified: (unidentified && { "description" => unidentified }), by: by,
                                  waiting_room: WaitingRoom::Gate.usable?(Current.city))
    raise "arrived! recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:encounter)
  end

  # Sem `justification:` vai a padrão; `justification: nil` manda nulo (a cor
  # sugerida aceita sem justificativa).
  DEFAULT_JUSTIFICATION = Object.new.freeze

  # Classificação pela via real (Urgency::Classify), sempre com a dor
  # (`pain_scale`, obrigatória, Q22). Sem justificativa dada, vai a padrão
  # (exigida quando não há sugestão ou a cor difere dela).
  def classified!(encounter, color:, by:, vital_signs: {}, pain_scale: 0, justification: DEFAULT_JUSTIFICATION)
    justification = JUSTIFICATION if justification.equal?(DEFAULT_JUSTIFICATION)
    attrs = { "complaint" => COMPLAINT, "vital_signs" => vital_signs.deep_stringify_keys, "pain_scale" => pain_scale,
              "color" => color, "justification" => justification }
    result = Urgency::Classify.call(encounter: encounter, attrs: attrs, by: by)
    raise "classified! recusado: #{result.reason} #{result.details}" if result.failure?

    encounter.reload
  end

  # Chamada do médico pela via real (Attendances::Call), com o local opcional.
  def called!(encounter, by:, call_location: nil)
    attendance = encounter.attendance
    result = Attendances::Call.call(attendance: attendance, health_unit_id: attendance.health_unit_id, by: by,
                                    call_location_id: call_location&.id, waiting_room: WaitingRoom::Gate.usable?(Current.city))
    raise "called! recusado: #{result.reason} #{result.details}" if result.failure?

    encounter.reload
  end

  # Consulta de urgência do 19a (Consultations::Start, kind pelo encontro),
  # chamando antes, se o atendimento ainda não está com o médico.
  def urgency_consultation!(encounter, doctor:)
    called!(encounter, by: doctor) unless encounter.attendance.reload.status == "in_care"
    result = Consultations::Start.call(attendance: encounter.attendance.reload, by: doctor, kind: nil, city: Current.city)
    raise "urgency_consultation! recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:consultation)
  end

  # Consulta de urgência finalizada (SaveDraft e Finalize do 19a, sem tipo de
  # atendimento e sem desfecho: quem fecha é o Urgency::RecordOutcome).
  def finalized_urgency!(encounter, doctor:)
    consultation = Consultation.find_by(attendance_id: encounter.attendance_id) || urgency_consultation!(encounter, doctor: doctor)
    saved = Consultations::SaveDraft.call(consultation: consultation, params: draft_body.except("care_type"), by: doctor)
    raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

    result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: {}, by: doctor)
    raise "finalização recusada: #{result.reason} #{result.details}" if result.failure?

    consultation.reload
  end

  def call_location!(unit, name: "Consultório 1")
    CallLocation.create!(health_unit: unit, name: name, updated_by_user: urgency_admin!)
  end

  # TV pareada pelos comandos da Task 12: cadastro, código e pareamento.
  # Devolve [display, token].
  def paired_display!(unit, show_wait_times: true)
    saved = WaitingRoom::SaveDisplay.call(attrs: { "health_unit_id" => unit.id, "name" => "TV #{SecureRandom.hex(2)}",
                                                   "show_wait_times" => show_wait_times }, by: urgency_admin!)
    raise "paired_display! recusado: #{saved.reason} #{saved.details}" if saved.failure?

    display = saved.payload.fetch(:display)
    issued = WaitingRoom::IssuePairingCode.call(display: display, by: urgency_admin!)
    raise "paired_display! recusado: #{issued.reason}" if issued.failure?

    paired = WaitingRoom::Pair.call(code: issued.payload.fetch(:code))
    raise "paired_display! recusado: #{paired.reason}" if paired.failure?

    [ display.reload, paired.payload.fetch(:display_token) ]
  end
end

RSpec.configure { |c| c.include UrgencyHelpers }
