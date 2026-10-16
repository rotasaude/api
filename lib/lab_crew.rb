require "tmpdir"
require Rails.root.join("lib/sigtap_sample").to_s
require_relative "signature_crew"
require_relative "digital_signature_crew"

# Semente de dev do módulo 21b (ADR 0037). Dev é fictício mas imita o real:
# SIGTAP e LOINC reais; o "Laboratório Municipal Central" (do ExamCrew) vira o
# laboratório municipal de Curitiba, com endereço e telefone; a UBS Jardim das
# Flores coleta e a UBS Vila Esperança não; os 16 exames do catálogo-base
# adotados, com versão 2 (códigos de aparelho, limites de digitação e
# críticos); seis motivos de rejeição; tecnica-lab@ (lab_staff),
# biomedica@ (CRBM, RT) e patologista@ (CRM, substituto: só ICP — o vínculo
# do certificado do PSC simulado é feito no navegador, como no 19b, porque a
# chave da folha só existe na memória do fake-psc); token do middleware
# simulado (FAKE_MIDDLEWARE_TOKEN; só o hash vai à cidade, nunca impresso).
# Só Curitiba (modo record). Idempotente. Roda depois do ExamCrew.
class LabCrew
  DEV_MAINTAINER = "dev@local".freeze
  LAB = "Laboratório Municipal Central".freeze
  ADDRESS = "Rua Doutor Faivre, 1200 — Centro — Curitiba/PR".freeze
  PHONE = "4133501200".freeze
  COLLECTING_UNIT = "UBS Jardim das Flores".freeze
  OTHER_UNIT = "UBS Vila Esperança".freeze
  SWITCHES = %w[municipal_lab lab_hl7_inbound fake_middleware].freeze
  FAKE_MIDDLEWARE_TOKEN_ENV = "FAKE_MIDDLEWARE_TOKEN".freeze
  DEFAULT_FAKE_MIDDLEWARE_TOKEN = "dev-fake-middleware-token-0123456789abcdef01".freeze
  BENCHES = { "hematology" => "Hematologia 1", "biochemistry" => "Bioquímica 1", "immunology" => "Imunologia 1",
              "urinalysis" => "Uroanálise", "parasitology" => "Parasitologia" }.freeze
  DELIVERY_DAYS = { "hematology" => 1, "biochemistry" => 2, "immunology" => 5, "urinalysis" => 2, "parasitology" => 3 }.freeze
  INSTRUMENT_CODES = { "0202020380" => "HEM", "0202010473" => "GLI", "0202010503" => "A1C", "0202010295" => "COL", "0202010279" => "HDL",
                       "0202010287" => "LDL", "0202010678" => "TRI", "0202010317" => "CRE", "0202010694" => "URE", "0202010643" => "TGO",
                       "0202010651" => "TGP", "0202060250" => "TSH", "0202060381" => "T4L", "0202060217" => "HCG" }.freeze
  # Limites de digitação e críticos de partida (RT ajusta): chave → [entry_min, entry_max, critical_low, critical_high].
  LIMITS = { "glicose" => [ 10, 1500, 40, 400 ], "hemoglobina" => [ 1, 25, 7, 20 ], "plaquetas" => [ 1, 2000, 20, 1000 ],
             "leucocitos" => [ 0.1, 200, 1, 50 ], "creatinina" => [ 0.1, 30, nil, 7.4 ], "tsh" => [ 0.001, 150, nil, nil ] }.freeze
  REASONS = [ "Amostra hemolisada", "Amostra lipêmica", "Amostra coagulada", "Sem identificação", "Volume insuficiente",
              "Recipiente inadequado" ].freeze
  USERS = [
    { prefix: "tecnica-lab", role: "lab_staff", secret_env: "DEV_LAB_STAFF_OTP_SECRET", default_secret: "ORSWG3TJMNQS23DBMIWWIZLWEEQSCIJB" },
    { prefix: "biomedica", role: "lab_releaser", secret_env: "DEV_LAB_BIOMEDICAL_OTP_SECRET", default_secret: "MJUW63LFMRUWGYJNMRSXMIJBEEQSCIJB",
      profile: { professional_name: "Mariana Albuquerque Teles", council: "CRBM" }, lead: true },
    { prefix: "patologista", role: "lab_releaser", secret_env: "DEV_LAB_PATHOLOGIST_OTP_SECRET", default_secret: "OBQXI33MN5TWS43UMEWWIZLWEEQSCIJB",
      profile: { professional_name: "Otávio Lacerda Pires", council: "CRM" }, deputy: true }
  ].freeze

  class << self
    # Catálogo-base na plataforma. Republica o recorte SIGTAP de dev quando
    # ele não tem os códigos do catálogo (SIGTAP real nunca é tocada).
    def seed_platform!
      guard_environment!
      competence = Time.zone.today.strftime("%Y%m")
      release = Terminology::Sigtap.release_for(competence)
      codes = Lab::Templates::Load.sigtap_codes
      have = release ? SigtapProcedure.where(release_id: release.id, code: codes).count : 0
      if have < codes.size && !real_sigtap_active?
        Dir.mktmpdir do |dir|
          imported = Terminology::Import.call(kind: "sigtap", version: competence, path: SigtapSample.write_to(dir, competence: competence), by: "db:seed")
          raise "semente do laboratório: SIGTAP recusada (#{imported.reason})" if imported.failure?
        end
      end
      Lab::Templates::Load.call.merge(sigtap: competence)
    end

    def seed_current_city(slug:, password:, admin:)
      guard_environment!
      return { switch: "desligado (só Curitiba liga)", exams: 0, users: [] } unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      return { switch: "desligado (sem mantenedor #{DEV_MAINTAINER})", exams: 0, users: [] } unless maintainer

      city = City.find(Current.city.id)
      SWITCHES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      lab = laboratory!
      units!
      exams = catalog!(lab, admin)
      reasons!(lab)
      users = USERS.map { |spec| ensure_user(spec, slug: slug, password: password, admin: admin, lab: lab) }
      token!(lab)
      missing = SWITCHES.flat_map { |key| Platform::Features.missing(city, key) }
      { switch: missing.empty? ? "ligado (#{SWITCHES.join(', ')})" : "ligado, falta: #{missing.join(', ')}", exams: exams, users: users }
    end

    private

    def guard_environment!
      raise "semente do laboratório: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def real_sigtap_active?
      TerminologyRelease.active.where(kind: "sigtap").pluck(:id).any? do |id|
        SigtapProcedure.where(release_id: id).count > SigtapSample::PROCEDURES.size
      end
    end

    def laboratory!
      lab = ExamProvider.find_by!(name: LAB)
      lab.update!(uses_municipal_lab: true, address: ADDRESS, phone: PHONE) unless lab.uses_municipal_lab && lab.phone == PHONE
      lab
    end

    def units!
      HealthUnit.find_by!(name: COLLECTING_UNIT).then { |u| u.update!(collects_samples: true) unless u.collects_samples }
      HealthUnit.find_by!(name: OTHER_UNIT).then { |u| u.update!(collects_samples: false) if u.collects_samples }
    end

    # Adota os 16 e cria a versão 2 com código de aparelho e limites (uma vez).
    def catalog!(lab, admin)
      LabExamTemplate.where(active: true).includes(:analytes).order(:name).count do |template|
        next false if LabExam.exists?(exam_provider_id: lab.id, sigtap_code: template.sigtap_code)

        adopted = Lab::AdoptExam.call(provider: lab, template_id: template.id, sector: template.sector, bench: BENCHES[template.sector],
                                      delivery_days: DELIVERY_DAYS.fetch(template.sector, 3), by: admin)
        raise "semente do laboratório: adoção de #{template.sigtap_code} recusada (#{adopted.reason})" if adopted.failure?

        exam = adopted.payload[:exam]
        v1 = exam.current_version
        analytes = v1.analytes.map do |a|
          min, max, low, high = LIMITS[a["key"]]
          a.merge("entry_min" => min, "entry_max" => max, "critical_low" => low, "critical_high" => high)
        end
        version = Lab::CreateVersion.call(exam: exam, by: admin, params: { "method" => v1.analysis_method, "material" => v1.material,
                                                                           "container" => v1.container,
                                                                           "instrument_test_code" => INSTRUMENT_CODES[template.sigtap_code],
                                                                           "analytes" => analytes })
        raise "semente do laboratório: versão de #{template.sigtap_code} recusada (#{version.reason})" if version.failure?

        true
      end
    end

    def reasons!(lab)
      REASONS.each do |name|
        next if LabRejectionReason.where(exam_provider_id: lab.id).where("lower(name) = lower(?)", name).exists?

        Lab::SaveRejectionReason.call({ "provider_id" => lab.id, "name" => name, "active" => true })
      end
    end

    def ensure_user(spec, slug:, password:, admin:, lab:)
      user = User.find_or_initialize_by(email_address: "#{spec[:prefix]}@#{slug}.demo")
      user.password = password if user.new_record?
      user.save!
      Membership.find_or_create_by!(user: user, role: spec[:role], revoked_at: nil) { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
      if spec[:profile]
        profile!(user, spec, slug, admin)
        unless LabReleaser.active.exists?(user_id: user.id, exam_provider_id: lab.id)
          assigned = Lab::AssignReleaser.call(user_id: user.id, provider: lab, technical_lead: spec.fetch(:lead, false),
                                              technical_deputy: spec.fetch(:deputy, false), by: admin)
          raise "semente do laboratório: liberador #{spec[:prefix]} recusado (#{assigned.reason})" if assigned.failure?
        end
      end
      { email: user.email_address, role: spec[:role], otpauth_uri: SignatureCrew.otpauth_uri(user) }
    end

    def profile!(user, spec, slug, admin)
      return user.professional if user.professional

      seed = "#{slug}:#{spec[:prefix]}"
      attrs = spec[:profile].merge(council_state: CityProfile.current&.uf.presence || "PR", cns: Professionals::Cns.generate(seed),
                                   registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s)
      created = Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin)
      raise "semente do laboratório: perfil de #{spec[:prefix]} recusado (#{created.reason})" if created.failure?

      professional = created.payload[:professional]
      professional.update!(cpf: DigitalSignatureCrew.free_cpf_for(slug, professional))
      professional
    end

    def token!(lab)
      digest = LabMiddlewareToken.digest(ENV.fetch(FAKE_MIDDLEWARE_TOKEN_ENV, DEFAULT_FAKE_MIDDLEWARE_TOKEN))
      return if LabMiddlewareToken.active.exists?(exam_provider_id: lab.id, token_digest: digest)

      Lab::RotateMiddlewareToken.call(provider: lab, by: nil, simulated: true,
                                      token: ENV.fetch(FAKE_MIDDLEWARE_TOKEN_ENV, DEFAULT_FAKE_MIDDLEWARE_TOKEN))
    end
  end
end
