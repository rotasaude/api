require Rails.root.join("lib/sigtap_sample").to_s

# Módulo 31 (ADR 0049): cidade do CAPS (prontuário, ou o faturamento com
# billing: true), SIGTAP de dev com os procedimentos do CAPS (Valor fixado 6,
# pelo caminho real: Terminology::Import do SigtapSample), CAPS, equipe lotada
# (papel do CAPS + vínculo ativo), paciente com par validado, telefone e CNS,
# matrícula (com a RAAS do mês), leito, médico da UBS e o administrador. As
# gravações são diretas no banco (os caminhos reais são os comandos das Tasks
# 3–11). Tudo avaliado só na chamada.
module PsychosocialHelpers
  # Prontuário (clinical_city!) ou, com billing: true, a cidade do faturamento
  # (billing_city!), sempre com a SIGTAP do CAPS criada ANTES (a SIGTAP ativa é
  # imutável). Liga `psychosocial_care` e garante os parâmetros (a linha que a
  # migração insere e o dump não leva).
  def psychosocial_city!(billing: false)
    psychosocial_sigtap!
    city = billing ? billing_city! : clinical_city!
    Platform::Features.set!(city: city, key: "psychosocial_care", enabled: true, maintainer: ledi_maintainer!)
    PsychosocialSetting.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  # As releases SIGTAP da competência do dia e da anterior com o recorte de
  # dev inteiro (SigtapSample: faturamento, exames, saúde bucal, regulação e o
  # CAPS — instrumento 09, quantidade máxima, permanência e atributo 036).
  # Chame antes de billing_city!/exam_city!: depois de ativa, a release não muda.
  def psychosocial_sigtap!(competences = [ Time.zone.today.strftime("%Y%m"), Time.zone.today.prev_month.strftime("%Y%m") ])
    Array(competences).map do |competence|
      existing = TerminologyRelease.active.find_by(kind: "sigtap", version: competence)
      if existing
        raise "psychosocial_sigtap! depois de billing_city!/exam_city!: chame antes" unless
          SigtapProcedure.exists?(release_id: existing.id, code: SigtapSample::PSYCHOSOCIAL_CODES.first)

        next existing
      end
      result = Dir.mktmpdir do |dir|
        Terminology::Import.call(kind: "sigtap", version: competence, path: SigtapSample.write_to(dir, competence: competence),
                                 by: "rspec")
      end
      raise "SIGTAP do CAPS recusada: #{result.reason}" if result.failure?

      result.payload[:release]
    end
  end

  def psychosocial_admin!
    @psychosocial_admin ||= step_up_enrolled!(staff_with("admin-caps-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
  end

  def caps!(modality: "caps_ii", name: "CAPS #{SecureRandom.hex(3)}", cnes: billing_cnes, service_classification: "001")
    HealthUnit.create!(name: name, kind: "caps", caps_modality: modality, service_classification: service_classification, cnes: cnes)
  end

  # Profissional lotado no CAPS: papel psychosocial_staff (ou
  # psychosocial_lead), perfil e vínculo ativo com o CBO; MFA cadastrado (o
  # step-up da sessão é do request spec: stepped_up!).
  def caps_staff!(unit, cbo: "251510", lead: false)
    role = lead ? "psychosocial_lead" : "psychosocial_staff"
    user = staff_with("caps-#{SecureRandom.hex(3)}@cidade.gov.br", role)
    link_professional!(user, unit, cbo: cbo)
    step_up_enrolled!(user)
  end

  # Paciente com par validado e telefone (exam_patient!), raça/cor e endereço
  # (faturável) e, com cns: true, um CNS válido.
  def caps_patient!(cns: true)
    patient = exam_patient!(exam_seq!).first
    patient.update!(BillingHelpers::DEMOGRAPHICS.merge(cns: (Professionals::Cns.generate(SecureRandom.uuid) if cns)))
    patient
  end

  # Matrícula aberta gravada direto (o caminho real é Psychosocial::CreateEnrollment)
  # e a RAAS do mês do início.
  def enrollment!(unit, patient: caps_patient!, reference: caps_staff!(unit), started_on: Date.current.beginning_of_month, cid: "F200")
    ApplicationRecord.transaction(requires_new: true) do
      enrollment = PsychosocialEnrollment.create!(health_unit: unit, patient: patient, started_on: started_on, origin: "01",
                                                  cid_main: cid, cid_secondary: [], substances: [], esf_covered: false,
                                                  reference_user: reference)
      PsychosocialMonthlyRecord.create!(psychosocial_enrollment: enrollment, health_unit: unit, month: started_on.beginning_of_month)
      enrollment
    end
  end

  # Ação gravada pela via real (Psychosocial::RecordAction, com o vínculo de
  # quem grava no CAPS): hoje às 10:00 locais (ou agora, se ainda não deu
  # 10:00), no CAPS, quantidade 1; `performed_at` pode ser Time (vira ISO
  # 8601). O código padrão (0301080208) é só 09: passe um participante
  # matriculado (`participants: [ { enrollment_id: } ]`), senão a crítica
  # recusa com enrollment_required. Recusa → erro com os códigos (nunca dado
  # do paciente). Devolve a PsychosocialAction.
  def record_action!(unit, by, **attrs)
    performed_at = [ Time.zone.today.in_time_zone.change(hour: 10), Time.current ].min
    attrs = { sigtap_code: "0301080208", performed_at: performed_at, place: "caps", quantity: 1, participants: [] }.merge(attrs)
    attrs[:performed_at] = attrs[:performed_at].iso8601 if attrs[:performed_at].respond_to?(:iso8601)
    result = Psychosocial::RecordAction.call(attrs: attrs.deep_stringify_keys, unit: unit, by: by,
                                             link: Psychosocial::Access.link(by, unit.id))
    raise "record_action! recusada: #{result.reason} #{Array(result.details[:problems]).map { |p| p[:error] }.join(',')}" if result.failure?

    result.payload.fetch(:action)
  end

  # Vínculo do profissional no retrato do CNES mais recente do IBGE da cidade
  # (cria o perfil com o IBGE e um retrato da competência do dia, se faltar),
  # no CNES do CAPS e com o CBO da lotação — o que o fechamento do mês confere.
  # Acrescenta ao retrato existente (cnes_snapshot! o substituiria).
  def caps_cnes_bond!(user, unit)
    profile = city_profile!
    profile.update!(ibge_code: "4106902") if profile.ibge_code.blank?
    snapshot = CnesSnapshot.where(ibge_code: profile.ibge_code).order(competence: :desc).first ||
               cnes_snapshot!(ibge_code: profile.ibge_code, competence: Time.zone.today.strftime("%Y%m"))
    CnesProfessionalBond.create!(snapshot: snapshot, cnes: unit.cnes, ine: nil, cbo_code: Psychosocial::Access.link(user, unit.id).cbo_code,
                                 cpf: nil, cns: user.professional.cns)
  end

  # RAAS do mês sem pendência: situação de rua informada (false) e uma ação
  # 0301080208 (pela via real) de um profissional lotado (`by`, ou um novo) com
  # vínculo no retrato do CNES, no último dia do mês às 10:00 locais (ou agora,
  # se ainda não chegou). O paciente precisa de CNS e telefone (caps_patient!).
  # Devolve a RAAS do mês.
  def complete_month!(enrollment, month, by: nil)
    unit = enrollment.health_unit
    by ||= caps_staff!(unit)
    caps_cnes_bond!(by, unit)
    record = Psychosocial::MonthlyRecords.ensure!(enrollment, month)
    record.update!(homeless: false)
    performed_at = [ month.to_date.end_of_month.in_time_zone.change(hour: 10), Time.current ].min
    record_action!(unit, by, performed_at: performed_at, participants: [ { enrollment_id: enrollment.id } ])
    record
  end

  # Documento do 19 da ação do CAPS gravado direto (o caminho real é
  # ClinicalDocuments::Issue com `psychosocial_action:`): sem atendimento e sem
  # cidadão, do paciente do único participante, com o autor e o CBO da ação,
  # em papel. Receita leva os itens do catálogo (`items`) na mesma transação
  # (o trigger exige); outro tipo não leva item.
  def caps_document!(action, kind: "sick_note", items: [], issued_at: Time.current)
    patient_id = action.psychosocial_action_participants.sole.patient_id
    release = MedicationCatalogRelease.current if items.any?
    ApplicationRecord.transaction(requires_new: true) do
      document = ClinicalDocument.create!(kind: kind, patient_id: patient_id, psychosocial_action: action,
                                          author_user_id: action.professional_user_id, cbo_code: action.cbo_code, issue_mode: "paper",
                                          verification_token: ClinicalDocuments::Codes.token, short_code: ClinicalDocuments::Codes.short_code,
                                          issued_at: issued_at, content: { "items" => [], "category" => "common", "sncr" => nil }.to_json)
      items.each_with_index do |catalog, index|
        PrescriptionItem.create!(clinical_document: document, position: index + 1, continuous: false, medication_catalog_item_id: catalog.id,
                                 catmat_code: catalog.catmat_code, catalog_release_id: release.id, printed_description: catalog.label,
                                 quantity: 30, quantity_unit: "comprimido", route: "oral", dosage_instructions: "1 comprimido à noite")
      end
      document
    end
  end

  def bed!(unit, label: "L1")
    PsychosocialBed.create!(health_unit: unit, label: label, updated_by_user: psychosocial_admin!)
  end

  # Médico da UBS (health_professional, vínculo 225125 na unidade).
  def ubs_doctor!(ubs)
    screener!(ubs, cbo: "225125", email: "medico-ubs-#{SecureRandom.hex(3)}@cidade.gov.br")
  end

  # Contexto de leitura do ADR 0031: atendimento in_care na unidade, chamado
  # pelo médico, do par validado do paciente (caps_patient!).
  def in_context!(doctor, unit, patient)
    consulting_attendance!(unit, citizen: Citizen.find_by!(patient_id: patient.id), doctor: doctor)
  end

  # Matriciamento de hoje (0301080305, BPA-C) do CAPS com a equipe e um caso
  # compartilhado do paciente, pelos comandos (Psychosocial::RecordMatrixSupport
  # e AddMatrixCase), por um profissional lotado no CAPS. Devolve o caso.
  def matrix_case!(caps, team, patient, text, by: caps_staff!(caps))
    support = Psychosocial::RecordMatrixSupport.call(
      attrs: { "health_team_id" => team.id, "held_on" => Time.zone.today.iso8601, "topic" => "Matriciamento de rotina",
               "participants_user_ids" => [ by.id ], "sigtap_code" => "0301080305" },
      unit: caps, by: by, link: Psychosocial::Access.link(by, caps.id)
    )
    raise "matrix_case! recusado: #{support.reason} #{Array(support.details[:problems]).map { |p| p[:error] }.join(',')}" if support.failure?

    result = Psychosocial::AddMatrixCase.call(support: support.payload.fetch(:matrix_support),
                                              attrs: { "patient_id" => patient.id, "shared_text" => text }, by: by)
    raise "matrix_case! recusado: #{result.reason}" if result.failure?

    result.payload.fetch(:matrix_case)
  end

  # Textos do cenário completo (Task 18): nenhum pode sair do CAPS.
  CAPS_SCENARIO_TEXTS = {
    referral: "Ideação persistente sem resposta ao manejo na UBS",
    reception: "Acolhimento com ideação recorrente e uso de crack",
    note: "Relata ideação suicida sem plano estruturado",
    group: "Oficina terapêutica com boa participação do grupo",
    needs: "Isolamento social e ideação recorrente desde a internação",
    goal: "Retomar a oficina de artesanato duas vezes por semana",
    night: "Retorno ao convívio familiar combinado com a equipe",
    topic: "Matriciamento de casos graves da área",
    shared: "Discutido manejo da crise com a equipe da UBS"
  }.freeze

  # Cenário completo do CAPS (Task 18; contrato §10, P21), pelas rotas reais e
  # com o relógio do exemplo: encaminhamento da UBS em contexto, acolhimento
  # com matrícula (CID F20.0 e substância 02), BPA-I do acolhimento inicial,
  # PTS, ação com evolução, ação coletiva, receita controlada da ação (papel),
  # permanência noturna (entrada e saída), matriciamento com caso e o consumidor
  # do BPA. Tudo com o log capturado e as URLs anotadas. Só em request spec
  # (usa get/json_post). Devolve os registros, o log, as URLs, os jobs
  # enfileirados no cenário e as contagens de aviso/SMS/LEDI antes dele.
  def full_caps_scenario!
    caps_cid10_release!
    city = psychosocial_city!(billing: true)
    controlled_city!(mock: true, signature: false)
    Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city_profile!
    import_test_catalog!

    caps = caps!(name: "CAPS AD III Centro Vida", modality: "caps_ad_iii").tap { |unit| unit.update!(phone: "4133334444") }
    psychiatrist = prescriber_contact!(caps_staff!(caps, cbo: "225133"))
    ubs = create_unit("UBS Boa Vista", cnes: "7654321")
    doctor = ubs_doctor!(ubs)
    team = HealthTeam.create!(health_unit: ubs, ine: "0000123456", kind: "70", name: "eSF Boa Vista")
    patient, citizen = exam_patient!(exam_seq!, full_name: "Renato Alves Pereira")
    patient.update!(BillingHelpers::DEMOGRAPHICS.merge(cns: Professionals::Cns.generate(SecureRandom.uuid)))
    other = enrollment!(caps, patient: caps_patient!, reference: psychiatrist, started_on: Date.current.beginning_of_month)
    bed = bed!(caps, label: "L1")
    fluoxetina = controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1")
    attendance = in_context!(doctor, ubs, patient)
    texts = CAPS_SCENARIO_TEXTS
    side_counts = caps_side_counts
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    paths = []
    started_at = Time.current
    record = lambda do |verb, path, body = nil|
      verb == :get ? get(path) : json_post(path, body)
      paths << request.fullpath
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.body.empty? ? {} : JSON.parse(response.body)
    end

    refs = {}
    log = capture_log do
      sign_in_as(doctor)
      refs[:referral] = record.(:post, "/psychosocial/referrals",
                                { patient_id: patient.id, health_unit_id: caps.id, reason: texts[:referral], priority: "priority" })["id"]

      sign_in_as(psychiatrist)
      reception = record.(:post, "/psychosocial/receptions",
                          { health_unit_id: caps.id, patient_id: patient.id, referral_id: refs[:referral], at: 2.hours.ago.iso8601,
                            sigtap_code: "0301080232", notes: texts[:reception], outcome: "enrolled",
                            enrollment: { started_on: (Date.current - 2).iso8601, origin: "02", cid_main: "F20.0", cid_secondary: [],
                                          substances: [ "02" ], esf_covered: false, reference_user_id: psychiatrist.id } })
      enrollment = PsychosocialEnrollment.find(reception.fetch("enrollment_id"))
      record.(:get, "/psychosocial/enrollments/#{enrollment.id}")

      # Acolhimento inicial sem a matrícula no participante: BPA-I (Desvio 3).
      refs[:bpa_i] = record.(:post, "/psychosocial/actions",
                             { health_unit_id: caps.id, sigtap_code: "0301080232", performed_at: 90.minutes.ago.iso8601, place: "caps",
                               quantity: 1, participants: [ { patient_id: patient.id } ] })["id"]
      record.(:post, "/psychosocial/enrollments/#{enrollment.id}/care_plans",
              { needs: texts[:needs], goals: [ { text: texts[:goal], responsible_user_id: psychiatrist.id } ], intensity: "intensive",
                review_on: (Date.current + 60).iso8601 })
      refs[:note] = record.(:post, "/psychosocial/actions",
                            { health_unit_id: caps.id, sigtap_code: "0301080208", performed_at: 1.hour.ago.iso8601, place: "caps",
                              quantity: 1, notes: texts[:note], participants: [ { enrollment_id: enrollment.id } ] })["id"]
      refs[:group] = record.(:post, "/psychosocial/actions",
                             { health_unit_id: caps.id, sigtap_code: "0301080216", performed_at: 50.minutes.ago.iso8601, place: "caps",
                               quantity: 1, notes: texts[:group],
                               participants: [ { enrollment_id: enrollment.id }, { enrollment_id: other.id } ] })["id"]
      document = record.(:post, "/psychosocial/actions/#{refs[:note]}/documents",
                         { kind: "prescription",
                           content: { "items" => [ { "catalog_item" => { "id" => fluoxetina.id }, "quantity" => 30, "quantity_unit" => "cápsula",
                                                     "route" => "oral", "dosage_instructions" => "1 cápsula pela manhã",
                                                     "duration_days" => 30, "continuous" => true } ],
                                      "patient_identification" => patient_identification } })
      refs[:document] = document.fetch("id")
      record.(:get, "/psychosocial/actions/#{refs[:note]}")

      stay = record.(:post, "/psychosocial/night_stays",
                     { bed_id: bed.id, enrollment_id: enrollment.id, started_at: Time.current.yesterday.change(hour: 19).iso8601,
                       expected_end_at: Time.current.change(hour: 8).iso8601 })
      record.(:post, "/psychosocial/night_stays/#{stay['id']}/close", { ended_at: Time.current.change(hour: 8).iso8601, reason: texts[:night] })

      support = record.(:post, "/psychosocial/matrix_supports",
                        { health_unit_id: caps.id, health_team_id: team.id, held_on: Date.current.iso8601, topic: texts[:topic],
                          participants_user_ids: [ psychiatrist.id ], sigtap_code: "0301080305" })
      record.(:post, "/psychosocial/matrix_supports/#{support['id']}/cases", { patient_id: patient.id, shared_text: texts[:shared] })

      # O consumidor do BPA (psychosocial.action_recorded → Billing::PsychosocialProductionJob).
      DomainEvent.where(name: "psychosocial.action_recorded").find_each do |event|
        Billing::PsychosocialProductionJob.new.perform(event_id: event.id, event_name: event.name, city_slug: city.slug, payload: event.payload)
      end
    end
    raise "BPA-I do acolhimento não gerado" unless PerformedProcedure.exists?(psychosocial_action_id: refs[:bpa_i], patient_id: patient.id)

    { city: city, caps: caps, ubs: ubs, team: team, psychiatrist: psychiatrist, ubs_doctor: doctor, attendance: attendance,
      patient: patient.reload, citizen: citizen, enrollment: PsychosocialEnrollment.find_by!(patient_id: patient.id, health_unit_id: caps.id),
      document: ClinicalDocument.find(refs[:document]), refs: refs, started_at: started_at, log: log, paths: paths,
      side_counts: side_counts, jobs: ActiveJob::Base.queue_adapter.enqueued_jobs.drop(jobs_before).map { |job| job["job_class"] } }
  end

  # A CID-10 de teste (ClinicalRecordHelpers::CID10) com o F20.0 da matrícula:
  # com release ativa, a matrícula só aceita código dela. Chame antes de
  # billing_city! (cid10_release! reaproveita a ativa; a release ativa não muda).
  def caps_cid10_release!
    TerminologyRelease.active.find_by(kind: "cid10") || begin
      release = TerminologyRelease.create!(kind: "cid10", version: "2008", source_sha256: "d" * 64,
                                           imported_by: "rspec", imported_at: Time.current, status: "importing")
      ClinicalRecordHelpers::CID10.merge("F200" => [ "Esquizofrenia paranóide", nil ]).each do |code, (description, sex)|
        Cid10Code.create!(release: release, code: code, description: description, sex_restriction: sex)
      end
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  # Avisos, SMS e LEDI: as tabelas que um aviso, uma mensagem ou uma ficha
  # gravariam (o cenário do CAPS não pode mexer em nenhuma).
  def caps_side_counts
    [ AppointmentNotice, OutboundMessage, TransportTripNotice, LabCriticalNotice, LediOutboxEntry, LediGenerationFailure ]
      .to_h { |model| [ model.name, model.count ] }
  end
end

RSpec.configure { |c| c.include PsychosocialHelpers }
