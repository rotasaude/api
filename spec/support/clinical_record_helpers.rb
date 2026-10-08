# Módulo 19 (ADR 0031): terminologias da plataforma (CID-10 e SIGTAP mínimas),
# a cidade com o prontuário ligado, pares validados com nome e o caminho até a
# consulta. Cenário de teste: os caminhos reais são Terminology::Import,
# Citizens::Verify e Attendances::Call.
module ClinicalRecordHelpers
  CID10 = {
    "E119" => [ "Diabetes mellitus não-insulino-dependente - sem complicações", nil ],
    "I10" => [ "Hipertensão essencial (primária)", nil ],
    "N390" => [ "Infecção do trato urinário de localização não especificada", nil ],
    "C61" => [ "Neoplasia maligna da próstata", "M" ]
  }.freeze
  SIGTAP = {
    "0202010503" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA",
    "0202010317" => "DOSAGEM DE CREATININA",
    "0301010064" => "CONSULTA MEDICA EM ATENCAO PRIMARIA"
  }.freeze

  def cid10_release!
    TerminologyRelease.active.find_by(kind: "cid10") || begin
      release = TerminologyRelease.create!(kind: "cid10", version: "2008", source_sha256: "d" * 64,
                                           imported_by: "rspec", imported_at: Time.current, status: "importing")
      CID10.each { |code, (description, sex)| Cid10Code.create!(release: release, code: code, description: description, sex_restriction: sex) }
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  def sigtap_release!(competence = Time.zone.today.strftime("%Y%m"))
    TerminologyRelease.active.find_by(kind: "sigtap", version: competence) || begin
      release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "e" * 64,
                                           imported_by: "rspec", imported_at: Time.current, status: "importing")
      SIGTAP.each { |code, name| SigtapProcedure.create!(release: release, code: code, name: name) }
      release.update!(status: "active", activated_at: Time.current)
      release
    end
  end

  # A linha da TEST_CITY_A na plataforma (mesma chave de cifra do banco de
  # teste, como use_test_city_host!), com o modo e o interruptor pedidos.
  # Também vira a Current.city: o before global atribui TEST_CITY_A, um
  # City.new sem id, e ClinicalRecord::Gate.usable? precisa da linha
  # persistida (só spec; app/ e lib/ nunca atribuem Current.city).
  def clinical_city!(record_mode: "record", enabled: true)
    city = City.find_by(slug: TEST_CITY_A.slug) ||
           City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active", time_zone: "America/Sao_Paulo",
                        database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                        schema_version: CitySchema.expected_version.to_s)
    city.update!(record_mode: record_mode)
    Platform::Features.set!(city: city, key: "clinical_record", enabled: enabled, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    Current.city = city
    city
  end

  def verifier! = (@verifier ||= staff_with("validador-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier"))

  # Par validado com nome (o caminho real é Citizens::Verify).
  def verified_citizen!(n, full_name: "Maria Aparecida da Silva", social_name: nil, mother_name: "Joana da Silva",
                        age: 40 + n, sex: "female")
    citizen = screening_citizen!(n, age: age, sex: sex)
    CitizenVerification.create!(citizen: citizen, verified_by_user: verifier!, verified_at: Time.current)
    citizen.update!(verification_level: "verified", profile_source: "verified", full_name: full_name,
                    social_name: social_name, mother_name: mother_name)
    citizen
  end

  def doctor!(unit, cbo: "225125") = screener!(unit, cbo: cbo)

  def consulting_attendance!(unit, citizen:, doctor:)
    in_care!(walk_in_attendance!(unit, citizen: citizen), by: doctor)
  end

  def started_consultation!(unit:, doctor:, citizen:)
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    result = Consultations::Start.call(attendance: attendance, by: doctor)
    raise "consulta não iniciou: #{result.reason}" if result.failure?

    result.payload.fetch(:consultation)
  end

  def draft_body(**over)
    { "subjective" => "Refere sede e poliúria há dois meses", "objective" => "Bom estado geral",
      "assessment" => "Diabetes mellitus tipo 2", "plan" => "Metformina 500 mg; retorno em 30 dias",
      "vitals" => { "systolic" => 130, "diastolic" => 85, "weight_kg" => "82.5", "height_cm" => 170 },
      "care_type" => 5,
      "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add",
                                  "onset_on" => "2025-08-01", "onset_precision" => "month" } ],
      "conducts" => [ 1 ], "exam_requests" => [ { "sigtap_code" => "0202010503" } ] }.merge(over.transform_keys(&:to_s))
  end

  def finalized_consultation!(unit:, doctor:, citizen:, outcome: { "outcome" => "discharged" }, **over)
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    saved = Consultations::SaveDraft.call(consultation: consultation, params: draft_body(**over), by: doctor)
    raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

    result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: outcome, by: doctor)
    raise "finalização recusada: #{result.reason} #{result.details}" if result.failure?

    consultation.reload
  end

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end
end

RSpec.configure { |c| c.include ClinicalRecordHelpers }
