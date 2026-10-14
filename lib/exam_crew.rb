require "tmpdir"
require "prawn"
require Rails.root.join("lib/sigtap_sample").to_s
require_relative "clinical_record_crew"
require_relative "signature_crew"

# Semente de dev do módulo 21a (ADR 0036). Dev é fictício mas imita o real:
# SIGTAP e LOINC reais; catálogo com hemograma (laudo imediato), HbA1c (após
# ciência), anti-HIV e anatomopatológico (nunca no wpda; o anatomopatológico
# exige autorização); três prestadores (municipal, credenciado e o
# laboratório simulado, cujo token é o do compose — FAKE_LAB_TOKEN);
# laboratorio@ (portal) e regulacao@ (regulação) com TOTP fixo; três guias
# de exemplo em Curitiba (uma para o fake-lab, uma na fila de regulação,
# uma atrasada). Curitiba (record) liga exam_tracking, exam_fhir_inbound e
# fake_lab; Maringá (integrada) liga exam_tracking e exam_pec_bridge. Roda
# depois da TimelineCrew. Idempotente. O token só vai para a cidade como hash
# e nunca é impresso. Os interruptores de simulação só existem fora de
# produção (Platform::Features::SIMULATION_ENVS); em produção a semente não roda.
class ExamCrew
  DEV_MAINTAINER = "dev@local".freeze
  FAKE_LAB_TOKEN_ENV = "FAKE_LAB_TOKEN".freeze
  DEFAULT_FAKE_LAB_TOKEN = "dev-fake-lab-token-0123456789abcdef0123".freeze
  EXAM_CODES = %w[0202020380 0202010503 0202030300 0203020030].freeze
  CATALOG = [
    { sigtap_code: "0202020380", requires_authorization: false, release_policy: "immediate", result_days: 7,
      result_fields: [ { "key" => "hb", "label" => "Hemoglobina", "unit" => "g/dL", "loinc" => "718-7" },
                       { "key" => "ht", "label" => "Hematócrito", "unit" => "%", "loinc" => "4544-3" },
                       { "key" => "leuco", "label" => "Leucócitos", "unit" => "10*3/uL", "loinc" => "6690-2" },
                       { "key" => "plaq", "label" => "Plaquetas", "unit" => "10*3/uL", "loinc" => "777-3" } ] },
    { sigtap_code: "0202010503", requires_authorization: false, release_policy: "after_acknowledgement", result_days: 10,
      result_fields: [ { "key" => "hba1c", "label" => "Hemoglobina glicada", "unit" => "%", "loinc" => "4548-4" } ] },
    { sigtap_code: "0202030300", requires_authorization: false, release_policy: "never_citizen", result_days: 15,
      result_fields: [ { "key" => "anti_hiv", "label" => "Anti-HIV 1+2", "unit" => nil, "loinc" => "31201-7" } ] },
    { sigtap_code: "0203020030", requires_authorization: true, release_policy: "never_citizen", result_days: 45,
      result_fields: [ { "key" => "conclusao", "label" => "Conclusão", "unit" => nil, "loinc" => "22637-3" } ] }
  ].freeze
  PROVIDERS = [
    { name: "Laboratório Municipal Central", kind: "municipal", codes: EXAM_CODES - %w[0203020030], result_days: nil },
    { name: "Clínica Diagnóstica Credenciada", kind: "accredited", codes: %w[0203020030], result_days: 40 },
    { name: "Laboratório Simulado", kind: "accredited", codes: %w[0202020380 0202010503], result_days: 2, simulated: true }
  ].freeze
  TEAM_NURSE = "enfermeira"
  USERS = [
    { prefix: "laboratorio", role: "exam_provider", provider: "Laboratório Municipal Central",
      secret_env: "DEV_LAB_OTP_SECRET", default_secret: "NRQWE33SMF2G64TJN4WXE33UMEWXGYLV" },
    { prefix: "regulacao", role: "exam_regulator", provider: nil,
      secret_env: "DEV_REGULATOR_OTP_SECRET", default_secret: "OJSWO5LMMFRWC3ZNOJXXIYJNONQXKZDF" }
  ].freeze

  class << self
    # Só republica o recorte de dev. Se QUALQUER release SIGTAP ativa é maior
    # que o recorte (SIGTAP real, de qualquer competência), não importa nada
    # (o recorte da competência corrente a sombrearia) e avisa. `status`:
    # :complete, :republished ou :real_sigtap.
    def seed_platform!
      guard_environment!
      competence = Time.zone.today.strftime("%Y%m")
      release = Terminology::Sigtap.release_for(competence)
      have = release ? SigtapProcedure.where(release_id: release.id, code: EXAM_CODES).count : 0
      return { sigtap: competence, republished: false, status: :complete } if release&.version == competence && have == EXAM_CODES.size

      if real_sigtap_active?
        Rails.logger.warn("[exam_crew] SIGTAP real ativa; exames do 21a não verificados")
        return { sigtap: competence, republished: false, status: :real_sigtap }
      end

      Dir.mktmpdir do |dir|
        result = Terminology::Import.call(kind: "sigtap", version: competence,
                                          path: SigtapSample.write_to(dir, competence: competence), by: "db:seed")
        raise "semente de exames: SIGTAP recusada (#{result.reason} #{result.message})" if result.failure?
      end
      { sigtap: competence, republished: true, status: :republished }
    end

    def seed_current_city(slug:, ddd:, password:)
      guard_environment!

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      return { switch: "desligado (sem mantenedor #{DEV_MAINTAINER})", users: [], orders: 0 } unless maintainer

      city = City.find(Current.city.id)
      switches = city.record_mode == "integrated" ? %w[exam_tracking exam_pec_bridge] : %w[exam_tracking exam_fhir_inbound fake_lab]
      switches.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      catalog!
      providers!
      users = USERS.map { |spec| ensure_user(spec, slug: slug, password: password) }
      orders = city.record_mode == "record" ? sample_orders!(slug, ddd) : 0
      team = city.record_mode == "record" ? team!(slug) : nil
      { switch: switches.join(", "), users: users, orders: orders, team: team }
    end

    private

    def real_sigtap_active?
      TerminologyRelease.active.where(kind: "sigtap").pluck(:id).any? do |id|
        SigtapProcedure.where(release_id: id).count > SigtapSample::PROCEDURES.size
      end
    end

    def guard_environment!
      raise "semente de exames: ambiente implantado (#{Rota::DEPLOYED_ENVS.join(' ou ')}); a semente é só de dev" if Rota.deployed?
    end

    # Semente de dev: itens existentes não são atualizados (intencional).
    def catalog!
      CATALOG.each do |attrs|
        item = ExamCatalogItem.find_or_initialize_by(sigtap_code: attrs[:sigtap_code])
        item.update!(attrs.except(:sigtap_code).merge(active: true)) if item.new_record?
      end
    end

    def providers!
      PROVIDERS.each do |spec|
        provider = ExamProvider.find_or_create_by!(name: spec[:name]) do |p|
          p.kind = spec[:kind]
          p.simulated = spec.fetch(:simulated, false)
          p.cnes = format("%07d", (Zlib.crc32("exam-provider:#{spec[:name]}") % 9_000_000) + 1_000_000)
        end
        spec[:codes].each do |code|
          item = ExamCatalogItem.find_by!(sigtap_code: code)
          ExamProviderItem.find_or_create_by!(exam_provider: provider, exam_catalog_item: item) { |pi| pi.result_days = spec[:result_days] }
        end
        next unless provider.simulated

        digest = ExamProvider.digest(ENV.fetch(FAKE_LAB_TOKEN_ENV, DEFAULT_FAKE_LAB_TOKEN))
        next if provider.fhir_token_digest == digest && provider.fhir_token_revoked_at.nil?

        provider.update!(fhir_token_digest: digest, fhir_token_rotated_at: Time.current, fhir_token_revoked_at: nil)
      end
    end

    def ensure_user(spec, slug:, password:)
      user = User.find_or_initialize_by(email_address: "#{spec[:prefix]}@#{slug}.demo")
      user.password = password if user.new_record?
      user.save!
      Membership.find_or_create_by!(user: user, role: spec[:role], revoked_at: nil) { |m| m.granted_at = Time.current }
      if spec[:provider]
        ExamProviderUser.find_or_create_by!(user: user) { |pu| pu.exam_provider = ExamProvider.find_by!(name: spec[:provider]) }
      end
      SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
      { email: user.email_address, role: spec[:role], otpauth_uri: SignatureCrew.otpauth_uri(user) }
    end

    # Três guias da recepção para a cidadã da semente do prontuário, pedidas
    # pela médica da semente: (1) hemograma agendado no laboratório simulado
    # (o fake-lab devolve o laudo); (2) anatomopatológico na fila de
    # regulação; (3) HbA1c agendada há 40 dias no laboratório municipal
    # (atrasada na coleta). Datas passadas pelo `now:` dos comandos; a
    # competência SIGTAP é a corrente, explícita (a de 40 dias atrás pode
    # ser anterior à release ativa do dev).
    # Equipe de referência de dev na unidade das guias de exemplo, com a
    # enfermeira (CBO do vínculo): o resultado crítico e a ciência vencida
    # (fila da equipe, A10) têm a quem chegar. Em produção a equipe vem do
    # CNES (Cnes::Apply); aqui o INE é fictício e fixo por unidade.
    def team!(slug)
      unit = HealthUnit.find_by(name: ClinicalRecordCrew::UNIT)
      nurse = User.find_by(email_address: "#{TEAM_NURSE}@#{slug}.demo")
      link = nurse&.professional&.links&.active&.find_by(health_unit: unit)
      return nil unless unit && link

      team = HealthTeam.find_by(health_unit: unit, active: true) ||
             HealthTeam.create!(health_unit: unit, kind: "70", name: "ESF #{unit.name} (dev)",
                                ine: format("%010d", Zlib.crc32(unit.id) % 10**10))
      unless HealthTeamMember.active.exists?(professional: nurse.professional, health_team: team)
        HealthTeamMember.create!(professional: nurse.professional, health_team: team, cbo_code: link.cbo_code,
                                 started_on: Time.zone.today - 30)
      end
      team.name
    end

    def sample_orders!(slug, ddd)
      competence = Time.zone.today.strftime("%Y%m")
      citizen = ClinicalRecordCrew.send(:ensure_citizen, slug, ddd)
      patient = Patients::Resolve.call(citizen).payload.fetch(:patient)
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
      unit = HealthUnit.find_by!(name: ClinicalRecordCrew::UNIT)
      [ [ "SEED-1", "0202020380", "Laboratório Simulado", Time.current ],
        [ "SEED-2", "0203020030", nil, 2.days.ago ],
        [ "SEED-3", "0202010503", "Laboratório Municipal Central", 40.days.ago ] ].count do |reference, code, provider_name, at|
        next false if ExamOrder.exists?(external_reference: reference)

        ApplicationRecord.transaction do
          guide = Exams::Files.store(bytes: guide_pdf(reference), content_type: "application/pdf", user: reception).payload.fetch(:file)
          guide.update!(consumed_at: at)
          opened = Exams::Open.call(patient: patient, sigtap_code: code, priority: "routine", unit: unit, origin: "reception_guide",
                                    requester_user: doctor, guide_file: guide, external_reference: reference, created_by: reception,
                                    sigtap_competence: competence, now: at)
          raise "semente de exames: guia #{reference} recusada (#{opened.reason})" if opened.failure?

          order = opened.payload.fetch(:order)
          if provider_name
            provider = ExamProvider.find_by!(name: provider_name)
            scheduled = Exams::Transition.call(order: order, kind: "scheduled", actor_user: reception, now: at,
                                               changes: { exam_provider_id: provider.id, scheduled_at: at + 1.day,
                                                          scheduled_place: "#{provider_name} — recepção" })
            raise "semente de exames: agendamento de #{reference} recusado (#{scheduled.reason})" if scheduled.failure?
          end
        end
        true
      end
    end

    def guide_pdf(reference)
      Prawn::Document.new do |doc|
        doc.text "GUIA DE EXAME SIMULADA — desenvolvimento", size: 14
        doc.text "Referência #{reference}"
      end.render
    end
  end
end
