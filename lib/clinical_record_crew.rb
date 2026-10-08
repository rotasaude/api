require "tmpdir"
require_relative "screening_crew"

# Semente de dev do módulo 19 (spec 2026-10-07 §9). Dev é fictício mas imita o
# real: recortes de CIAP-2 e CID-10 (só se não houver release ativa); em
# Curitiba, record_mode = record e o interruptor clinical_record LIGADOS pelo
# mantenedor de dev (a spec manda — as sementes 16–18 não ligam nada); uma
# cidadã validada no balcão com nome completo e social; atendida pela médica
# da semente (profissional@, 225125) na UBS Jardim das Flores com diabetes
# (CIAP-2 T90) ativo, consulta finalizada e um adendo; e um segundo
# atendimento dela aguardando na mesma UBS, para a enfermeira (enfermeira@,
# 223505) ler o prontuário em contexto. Idempotente. Roda depois do ScreeningCrew.
class ClinicalRecordCrew
  UNIT = "UBS Jardim das Flores"
  # Prefixo do telefone dos cidadãos da semente: único entre os lib/*_crew.rb
  # (os das outras sementes não aparecem aqui, nem em comentário — as specs
  # delas varrem este arquivo).
  PHONE_PREFIX = "92222"
  CIAP2_SAMPLE = { "T90" => "Diabetes não insulino-dependente", "K86" => "Hipertensão sem complicações",
                   "R05" => "Tosse", "A03" => "Febre", "N01" => "Cefaleia" }.freeze
  CID10_SAMPLE = { "E11" => [ "Diabetes mellitus não-insulino-dependente", nil ],
                   "E119" => [ "Diabetes mellitus não-insulino-dependente - sem complicações", nil ],
                   "I10" => [ "Hipertensão essencial (primária)", nil ] }.freeze
  NAMES = { full_name: "Luiz Fernando Alves Moreira", social_name: "Luíza Alves", mother_name: "Rosana Alves" }.freeze
  PROFILE = { birth_date: "1979-04-12", sex: "male", gender_identity: "trans_woman" }.freeze
  DRAFT = {
    "subjective" => "Sede e poliúria há três meses; nega perda de peso.", "objective" => "Bom estado geral, eupneica.",
    "assessment" => "Diabetes mellitus tipo 2 recém-diagnosticado.", "plan" => "Metformina 500 mg 2x/dia; orientação alimentar; retorno em 30 dias.",
    "vitals" => { "systolic" => 132, "diastolic" => 84, "weight_kg" => "88.4", "height_cm" => 168 },
    "care_type" => 5,
    "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add",
                                "onset_on" => "2026-07-01", "onset_precision" => "month" } ],
    "conducts" => [ 1 ], "exam_requests" => []
  }.freeze

  class << self
    def seed_platform!
      { ciap2: import_unless_active("ciap2") { |dir| write_ciap2(dir) },
        cid10: import_unless_active("cid10") { |dir| write_cid10(dir) } }
    end

    def seed_current_city(slug:, ddd:)
      switch = slug == "curitiba" ? enable!(Current.city) : "desligado (só Curitiba liga)"
      unit = HealthUnit.find_by!(name: UNIT)
      citizen = ensure_citizen(slug, ddd)
      patient = citizen.patient || Patient.find_by(cpf: citizen.cpf)
      consultation = patient&.consultations&.finalized_consultations&.first
      consultation ||= (switch == "ligado" ? consult!(slug, unit, citizen) : nil)
      waiting!(slug, unit, citizen) if consultation
      { switch: switch, patient: citizen.display_name.to_s, consultation: consultation ? "finalizada com adendo" : "sem consulta" }
    end

    private

    def import_unless_active(kind)
      return false if TerminologyRelease.active.exists?(kind: kind)

      Dir.mktmpdir do |dir|
        yield Pathname(dir)
        result = Terminology::Import.call(kind: kind, version: "dev-#{Time.zone.today.year}", path: dir, by: "db:seed")
        raise "semente do prontuário: #{kind} recusada (#{result.reason} #{result.message})" if result.failure?
      end
      true
    end

    def write_ciap2(dir)
      dir.join("ciap2.csv").write("CODIGO;TITULO\n" + CIAP2_SAMPLE.map { |code, title| "#{code};#{title}" }.join("\n") + "\n")
    end

    def write_cid10(dir)
      categories = CID10_SAMPLE.select { |code, _| code.length == 3 }
      subcategories = CID10_SAMPLE.reject { |code, _| code.length == 3 }
      dir.join("CID-10-CATEGORIAS.CSV").binwrite(("CAT;DESCRICAO\n" + categories.map { |c, (d, _)| "#{c};#{d}" }.join("\n") + "\n").encode("ISO-8859-1"))
      dir.join("CID-10-SUBCATEGORIAS.CSV").binwrite(("SUBCAT;DESCRICAO;RESTRSEXO\n" +
        subcategories.map { |c, (d, s)| "#{c};#{d};#{s}" }.join("\n") + "\n").encode("ISO-8859-1"))
    end

    # Modo pelo comando do console (UpdateCityRecordSettings, com a auditoria
    # dele), relendo a linha da plataforma: Current.city pode vir do catálogo.
    def enable!(city)
      maintainer = Maintainer.find_by(email_address: "dev@local")
      unless maintainer
        warn "[seeds] prontuário: sem mantenedor de dev (dev@local) — interruptor não ligado"
        return "desligado (sem mantenedor)"
      end
      row = City.find(city.id)
      unless row.record_mode == "record"
        updated = UpdateCityRecordSettings.call(city: row, attrs: { record_mode: "record" })
        raise "semente do prontuário: modo record recusado (#{updated.reason})" if updated.failure?
      end
      Platform::Features.set!(city: row, key: "clinical_record", enabled: true, maintainer: maintainer)
      "ligado"
    end

    def ensure_citizen(slug, ddd)
      registered = Citizens::RegisterPerson.call(phone: format("+55%s#{PHONE_PREFIX}%04d", ddd, 1),
                                                 cpf: ScreeningCrew.send(:cpf_for, "#{slug}:clinical_record:1"),
                                                 profile: PROFILE)
      raise "semente do prontuário: cidadã recusada (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      return citizen if citizen.verification_level_verified?

      reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
      code = Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
      result = Citizens::Verify.call(cpf: citizen.cpf, code: code, document_checked: true, by: reception,
                                     birth_date: PROFILE[:birth_date], sex: PROFILE[:sex],
                                     gender_identity: PROFILE[:gender_identity], **NAMES)
      raise "semente do prontuário: validação recusada (#{result.reason})" if result.failure?

      citizen.reload
    end

    def checked_in!(slug, unit, citizen, step_key)
      started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version,
                                                 session_id: "seed-clinical-record")
      raise "semente do prontuário: conversa recusada (#{started.reason})" if started.failure?

      %w[true true].each_with_index do |answer, step|
        Citizens::SubmitAnswer.call(conversation: started.payload[:conversation], answer: answer,
                                    idempotency_key: "seed-clinical-#{slug}-#{step_key}-#{Time.zone.today}-#{step}")
      end
      triage = started.payload[:triage].reload
      code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
      reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
      result = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                                         by: reception)
      raise "semente do prontuário: check-in recusado (#{result.reason})" if result.failure?

      result.payload[:attendance]
    end

    def consult!(slug, unit, citizen)
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      attendance = checked_in!(slug, unit, citizen, "consulta")
      called = Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: doctor)
      raise "semente do prontuário: chamada recusada (#{called.reason})" if called.failure?

      started = Consultations::Start.call(attendance: attendance.reload, by: doctor)
      raise "semente do prontuário: consulta recusada (#{started.reason})" if started.failure?

      consultation = started.payload[:consultation]
      saved = Consultations::SaveDraft.call(consultation: consultation, params: DRAFT, by: doctor)
      raise "semente do prontuário: rascunho recusado (#{saved.reason} #{saved.details})" if saved.failure?

      finalized = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "return" }, by: doctor)
      raise "semente do prontuário: finalização recusada (#{finalized.reason} #{finalized.details})" if finalized.failure?

      addendum = Consultations::AddAddendum.call(consultation: consultation.reload, by: doctor,
                                                 reason: "resultado de glicemia trazido pela paciente",
                                                 text: "Glicemia de jejum de 168 mg/dL (laboratório externo), confirma o diagnóstico.")
      raise "semente do prontuário: adendo recusado (#{addendum.reason})" if addendum.failure?

      consultation.reload
    end

    # Um atendimento dela aguardando hoje, para a leitura em contexto da enfermeira.
    def waiting!(slug, unit, citizen)
      return if Attendance.waiting.where(citizen: citizen, health_unit: unit).exists?

      checked_in!(slug, unit, citizen, "espera")
    end
  end
end
