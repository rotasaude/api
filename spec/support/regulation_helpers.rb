# Módulo 26a (ADR 0044): cidade com o prontuário, o rastreamento de exames e a
# regulação ligados; SIGTAP com os procedimentos de regulação e os
# instrumentos de registro; regulador, prestadores, ofertas e o pedido de
# regulação pelo caminho real (CareRegulation::SaveDraft da Task 4 e a
# promoção na finalização da Task 5; avaliado só na chamada).
module RegulationHelpers
  # Códigos conferidos na SIGTAP 202610 (Task 0; vendor/regulation/2026-10-28):
  # código => [nome, instrumentos de registro]. Regra G11: grupo 02–04 com
  # BPA (01/02) é regulável; a APAC principal (06) não exclui.
  REGULATION_SIGTAP = {
    # reguláveis
    "0301010072" => [ "CONSULTA MEDICA EM ATENÇÃO ESPECIALIZADA", %w[01 02 07] ],
    "0209010037" => [ "ESOFAGOGASTRODUODENOSCOPIA", %w[02 04 06 07] ],
    "0401010074" => [ "EXERESE DE TUMOR DE PELE E ANEXOS / CISTO SEBACEO / LIPOMA", %w[01 02] ],
    # não reguláveis
    "0305010107" => [ "HEMODIÁLISE (MÁXIMO 3 SESSÕES POR SEMANA)", %w[06] ],            # só APAC
    "0101010010" => [ "ATIVIDADE EDUCATIVA / ORIENTAÇÃO EM GRUPO NA ATENÇÃO PRIMÁRIA", %w[01] ], # grupo 01
    "0407030026" => [ "COLECISTECTOMIA", %w[03] ],                                       # só AIH
    "0409050083" => [ "POSTECTOMIA", %w[03 06] ]                                         # AIH + APAC, sem BPA
  }.freeze
  # Nomes do tb_registro.txt da mesma competência.
  REGISTRIES = { "01" => "BPA (Consolidado)", "02" => "BPA (Individualizado)", "03" => "AIH (Proc. Principal)",
                 "04" => "AIH (Proc. Especial)", "06" => "APAC (Proc. Principal)", "07" => "APAC (Proc. Secundário)" }.freeze

  def regulation_city!(enabled: true)
    regulation_sigtap!
    city = exam_city!
    Platform::Features.set!(city: city, key: "care_regulation", enabled: enabled, maintainer: ledi_maintainer!)
    # O dump (db/city_schema.rb) não leva linha: os prazos padrão que a
    # migração insere entram aqui, como o seed_platform! dos tipos de agenda.
    RegulationRiskDeadline.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  # A SIGTAP é imutável depois de ativa (como billing_sigtap!): roda ANTES de
  # exam_city!, cujo sigtap_release! reaproveita as competências que já
  # existem. A competência antiga (ExamHelpers::OLD_SIGTAP_COMPETENCE) também
  # leva os códigos: pedido datado no passado (travel_to) acha o procedimento.
  def regulation_sigtap!(competences = [ Time.zone.today.strftime("%Y%m"), ExamHelpers::OLD_SIGTAP_COMPETENCE ])
    Array(competences).map do |competence|
      existing = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
      if existing
        unless SigtapProcedureInstrument.exists?(release_id: existing.id, procedure_code: REGULATION_SIGTAP.keys)
          raise "regulation_city! depois de exam_city!/billing_city!: a SIGTAP ativa é imutável; chame antes"
        end

        next existing
      end
      release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "f" * 64, imported_by: "rspec",
                                           imported_at: Time.current, status: "importing")
      ClinicalRecordHelpers::SIGTAP.merge(REGULATION_SIGTAP.transform_values(&:first)).each do |code, name|
        SigtapProcedure.create!(release: release, code: code, name: name)
      end
      REGULATION_SIGTAP.each do |code, (_name, instruments)|
        instruments.each do |reg|
          SigtapProcedureInstrument.create!(release: release, procedure_code: code, instrument_code: reg, instrument_name: REGISTRIES.fetch(reg))
        end
      end
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  # Release SIGTAP ativa de competência própria com `count` procedimentos
  # reguláveis (grupo 04, BPA individualizado) de nome "<prefix> NN", para
  # provar o corte das buscas. Use `on:` na competência (ou travel_to).
  def regulation_bulk_sigtap!(competence, count: 25, prefix: "PROCEDIMENTO REGULAVEL DE TESTE")
    release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "a" * 64, imported_by: "rspec",
                                         imported_at: Time.current, status: "importing")
    count.times do |i|
      code = format("04019%05d", i + 1)
      SigtapProcedure.create!(release: release, code: code, name: format("%s %02d", prefix, i + 1))
      SigtapProcedureInstrument.create!(release: release, procedure_code: code, instrument_code: "02", instrument_name: REGISTRIES.fetch("02"))
    end
    release.update!(status: "active", activated_at: Time.current)
    release
  end

  def care_regulator!(email = "regulacao-#{SecureRandom.hex(3)}@cidade.gov.br") = staff_with(email, "care_regulator")
  def regulation_admin! = (@regulation_admin ||= staff_with("adm-regulacao-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))

  # [paciente, par validado] (caminho real: Patients::Resolve).
  def regulation_patient!(n, **citizen_attrs) = exam_patient!(n, **citizen_attrs)

  def regulation_cnes = format("%07d", SecureRandom.random_number(9_000_000) + 1_000_000)

  # Prestador próprio: a unidade da rede, com o CNES dela (G7).
  def own_provider!(unit, name: unit.name)
    CareProvider.create!(name: name, kind: "own", health_unit: unit, cnes: unit.cnes, updated_by_user: regulation_admin!)
  end

  def external_provider!(kind: "contracted", cnes: regulation_cnes, name: "Prestador #{kind} #{cnes}")
    CareProvider.create!(name: name, kind: kind, cnes: cnes, updated_by_user: regulation_admin!)
  end

  def offer!(provider:, target_type: "specialty", target_code: "225120", quantity: 5, month: Time.zone.today.beginning_of_month)
    CareOffer.create!(care_provider: provider, target_type: target_type, target_code: target_code, month: month, quantity: quantity,
                      updated_by_user: regulation_admin!)
  end

  REGULATION_DEFAULTS = { "type" => "specialty", "target_code" => "225120", "cid10" => "I10",
                          "justification" => "Hipertensão resistente a três fármacos", "suggested_color" => "yellow" }.freeze

  # Pedido de regulação pelo caminho real: rascunho na consulta
  # (CareRegulation::SaveDraft, Task 4) e, fora de draft, a finalização da
  # consulta que o promove (Task 5). status: "draft" | "pending" | "external"
  # (este com state_regulated); as outras situações vêm dos comandos das
  # tasks seguintes (Authorize, Decide, Misses…), não de update_columns.
  # unit:, doctor: e citizen: trocam os padrões; o resto vai para o SaveDraft
  # (ciap2:, cid10: nil, target_code:…).
  def regulation_request!(status: "pending", **over)
    raise ArgumentError, "regulation_request!: status #{status.inspect} vem dos comandos" unless %w[draft pending external].include?(status)

    seq = (@regulation_request_seq = (@regulation_request_seq || 0) + 1)
    unit = over.delete(:unit) || create_unit("UBS Regulação #{seq}")
    doctor = over.delete(:doctor) || doctor!(unit)
    citizen = over.delete(:citizen) || regulation_patient!(exam_seq!).last
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    attrs = REGULATION_DEFAULTS.merge(over.transform_keys(&:to_s))
    attrs["state_regulated"] = true if status == "external"
    saved = CareRegulation::SaveDraft.call(consultation: consultation, attrs: attrs, by: doctor)
    raise "rascunho de regulação recusado: #{saved.reason} #{saved.details}" if saved.failure?

    request = saved.payload.fetch(:request)
    return request if status == "draft"

    drafted = Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: doctor)
    raise "rascunho recusado: #{drafted.reason} #{drafted.details}" if drafted.failure?

    finalized = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
    raise "finalização recusada: #{finalized.reason} #{finalized.details}" if finalized.failure?

    request.reload
    raise "pedido não promovido: #{finalized.payload[:regulation_not_sent].inspect}" unless request.status == status

    request
  end

  # --- Rede própria acompanhada pelo 17 (Task 10) -------------------------
  # Tudo pelos comandos reais: Authorize (Task 8), Appointments::Schedule
  # (dia sem turno), Confirm, Attendances::CheckIn, Appointments::Lapse (com
  # travel_to, sem bloco: o relógio fica no instante do comando) e
  # HealthUnits::Drain. Nenhum chama o AppointmentSync: o spec decide quando
  # o consumidor roda (a ordem e o redespacho são o que se prova).
  def regulation_regulator! = (@regulation_regulator ||= care_regulator!)

  # Com o relógio parado (travel_to), duas linhas de andamento gravadas no
  # mesmo instante empatam em created_at e a ordem (created_at, id) cairia no
  # uuid. Aqui cada linha nova anda 1 s antes: a ordem lida é a da gravação
  # (memória "Flakies de UUID e relógio"). Exige TimeHelpers no spec.
  def tick_regulation_events!
    allow(RegulationRequestEvent).to receive(:create!).and_wrap_original do |original, *args, **kwargs, &block|
      travel(1.second)
      original.call(*args, **kwargs, &block)
    end
  end

  # Pedido autorizado numa oferta própria: { regulation_request:,
  # appointment_request:, offer:, unit: }.
  def own_authorized_request!(color: "yellow", quantity: 5, **over)
    unit = create_unit("Centro de Especialidades #{SecureRandom.hex(3)}")
    offer = offer!(provider: own_provider!(unit), quantity: quantity)
    request = reauthorize!(regulation_request!(suggested_color: color, **over), offer: offer)
    { regulation_request: request, appointment_request: AppointmentRequest.find(request.appointment_request_id), offer: offer,
      unit: unit }
  end

  def reauthorize!(request, offer:)
    result = CareRegulation::Authorize.call(request: request, offer_id: offer.id, version: request.version, by: regulation_regulator!)
    raise "autorização recusada: #{result.reason}" if result.failure?

    request.reload
  end

  # Horário livre (legacy) pela recepção da unidade de destino.
  def schedule_regulated!(appointment_request, at:)
    result = Appointments::Schedule.call(request: appointment_request.reload, scheduled_at: at.iso8601,
                                         health_unit_id: appointment_request.target_unit_id, by: reception!)
    raise "marcação recusada: #{result.reason}" if result.failure?

    result.payload.fetch(:appointment)
  end

  # Confirma (se ainda não nasceu confirmado) antes do prazo de confirmação.
  def confirm_regulated!(appointment)
    appointment.reload
    return appointment if appointment.status == "confirmed"

    travel_to(appointment.confirmation_deadline_at - 1.hour) if Time.current >= appointment.confirmation_deadline_at
    result = Appointments::Confirm.call(appointment: appointment)
    raise "confirmação recusada: #{result.reason}" if result.failure?

    appointment.reload
  end

  # Check-in por código no dia do horário: o pedido de agendamento fecha como
  # fulfilled.
  def check_in_regulated!(appointment)
    confirm_regulated!(appointment)
    travel_to(appointment.scheduled_at - 1.hour)
    citizen = appointment.citizen
    code = Citizens::IssueAppointmentCheckInCode.call(citizen: citizen, appointment: appointment.reload).payload.fetch(:code)
    result = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: appointment.health_unit_id,
                                       document_checked: false, by: reception!)
    raise "check-in recusado: #{result.reason}" if result.failure?

    result.payload.fetch(:attendance)
  end

  # Confirmado e o dia terminou: no_show (o Lapse reabre o pedido).
  def no_show!(appointment)
    confirm_regulated!(appointment)
    travel_to(appointment.scheduled_at.in_time_zone.tomorrow.beginning_of_day + 1.hour)
    lapsed = Appointments::Lapse.call(appointment: appointment.reload, to: "no_show")
    raise "falta não registrada" if lapsed.failure? || lapsed.payload[:skipped]

    appointment.reload
  end

  # Sem confirmação até o prazo: expired (o Lapse reabre o pedido).
  def expire!(appointment)
    travel_to(appointment.confirmation_deadline_at + 1.minute)
    lapsed = Appointments::Lapse.call(appointment: appointment.reload, to: "expired")
    raise "expiração não registrada" if lapsed.failure? || lapsed.payload[:skipped]

    appointment.reload
  end

  def drain!(unit, to:)
    result = HealthUnits::Drain.call(unit: unit, target_unit_id: to.id, reason: "Unidade fechada para reforma",
                                     by: regulation_admin!)
    raise "esvaziamento recusado: #{result.reason}" if result.failure?

    result
  end

  # Escrita por cookie exige Content-Type JSON (também no DELETE). Mesmas
  # assinaturas de LabHelpers#json_patch e ClinicalDocumentHelpers#json_delete
  # (este com corpo opcional; sem corpo, o mesmo "{}").
  def json_patch(path, params = {}) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })
  def json_delete(path, params = {}) = delete(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })
end

RSpec.configure { |c| c.include RegulationHelpers }
