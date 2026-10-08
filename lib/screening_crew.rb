require_relative "triage_catalog_crew"

# Semente de dev do módulo 18 (spec 2026-10-07 §10). Dev é fictício mas imita
# o real: regras iniciais baseadas no CAB 28 (ponto de partida; a cidade
# revisa e assina), em Curitiba assinadas de verdade pelo elenco do
# SignatureCrew e ativas; nas demais, só o rascunho. A UBS da semente fica em
# walk_in; a técnica de enfermagem (tecnico@, CBO 322205) ganha vínculo nela
# (a enfermeira já tem); dois cidadãos de demanda espontânea com perfil,
# triagem e check-in de hoje aguardam a escuta. Idempotente. Roda depois do
# SchedulingCrew.
class ScreeningCrew
  UNIT = "UBS Jardim das Flores"
  NAME = Protocols::Validation::Screening::NAME
  RULES = [
    { "when" => { "any" => [ { "gte" => ["vitals.systolic", 180] }, { "gte" => ["vitals.diastolic", 120] },
                             { "lt" => ["vitals.spo2", 90] }, { "gte" => ["vitals.respiratory_rate", 30] },
                             { "gte" => ["vitals.heart_rate", 130] }, { "lt" => ["vitals.capillary_glucose", 50] } ] },
      "color" => "red" },
    { "when" => { "any" => [ { "gte" => ["vitals.temperature_c", 39] }, { "gte" => ["vitals.capillary_glucose", 300] },
                             { "gte" => ["vitals.systolic", 160] }, { "lt" => ["vitals.spo2", 94] },
                             { "gte" => ["vitals.pain_score", 8] } ] },
      "color" => "yellow" },
    { "when" => { "any" => [ { "gte" => ["vitals.temperature_c", 37.8] }, { "gte" => ["vitals.pain_score", 4] } ] },
      "color" => "green" }
  ].freeze
  WALK_INS = [ [ "1958-03-14", "female" ], [ "1991-11-02", "male" ] ].freeze
  # Prefixo do telefone dos cidadãos da semente: único entre os lib/*_crew.rb
  # (96666 é do CampaignCrew, 97777 do TerritoryCrew).
  PHONE_PREFIX = "98888"

  # Pasta (o OfficialArchive aceita pasta ou ZIP) com o recorte de dev do CIAP-2.
  CIAP2_DEV_DIR = Rails.root.join("db/seeds/terminology/ciap2")
  CIAP2_DEV_VERSION = "dev-seed-2026-10"

  class << self
    # Plataforma: garante UMA release CIAP-2 ativa (qualquer versão basta; nada
    # a fazer se já houver). Entra pelo caminho real, Terminology::Import.
    def seed_platform!
      if (active = TerminologyRelease.active.find_by(kind: "ciap2"))
        return { ciap2: active.version, imported: false }
      end

      result = Terminology::Import.call(kind: "ciap2", version: CIAP2_DEV_VERSION, path: CIAP2_DEV_DIR, by: "db:seed")
      raise "semente: CIAP-2 recusado (#{result.reason} #{result.message})" if result.failure?

      { ciap2: CIAP2_DEV_VERSION, imported: true }
    end

    def seed_current_city(slug:, ddd:)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      unit = HealthUnit.find_by!(name: UNIT)
      unit.update!(screening_scope: "walk_in") unless unit.screening_scope == "walk_in"
      link = ensure_technician_link(slug, unit, admin)
      protocol = slug == "curitiba" ? ensure_active!(slug) : ensure_draft!(slug)
      walk_ins = WALK_INS.each_with_index.count { |(birth, sex), i| ensure_walk_in(slug, ddd, unit, i, birth, sex) }
      { protocol: "#{protocol.name} v#{protocol.version} (#{protocol.status})", technician_link: link.cbo_code,
        walk_ins: walk_ins }
    end

    private

    def definition(version) = { "name" => NAME, "version" => version, "kind" => "screening", "risk_rules" => RULES.map(&:deep_dup) }

    def ensure_technician_link(slug, unit, admin)
      professional = User.find_by!(email_address: "tecnico@#{slug}.demo").professional
      existing = professional.links.active.find_by(health_unit: unit, cbo_code: "322205")
      return existing if existing

      result = Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: "322205", by: admin)
      raise "semente do acolhimento: vínculo da técnica recusado (#{result.reason})" if result.failure?

      result.payload[:link]
    end

    # Curitiba: a versão ativa com as regras; retoma uma pendente com as mesmas.
    def ensure_active!(slug)
      active = ProtocolDefinition.find_by(name: NAME, status: "active")
      return active if active && active.definition["risk_rules"] == RULES

      versions = ProtocolDefinition.where(name: NAME)
      pending = versions.where.not(status: %w[active retired]).find { |v| v.definition["risk_rules"] == RULES }
      version = pending&.version || ((versions.maximum(:version) || 0) + 1)
      TriageCatalogCrew.run_cycle!(slug, NAME, version, definition(version))
    end

    def ensure_draft!(slug)
      existing = ProtocolDefinition.where(name: NAME).order(:version).last
      return existing if existing

      author = User.find_by!(email_address: "autor@#{slug}.demo")
      result = Protocols::SaveDraft.call(definition: definition(1), by: author)
      raise "semente do acolhimento: rascunho recusado (#{result.reason})" if result.failure?

      result.payload[:protocol_definition]
    end

    # true quando fez o check-in agora; quem já está aguardando hoje fica.
    def ensure_walk_in(slug, ddd, unit, index, birth, sex)
      registered = Citizens::RegisterPerson.call(phone: format("+55%s#{PHONE_PREFIX}%04d", ddd, index + 1),
                                                 cpf: cpf_for("#{slug}:screening:#{index}"),
                                                 profile: { birth_date: birth, sex: sex, gender_identity: nil })
      raise "semente do acolhimento: cidadão recusado (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      return false if Attendance.waiting.where(citizen: citizen, health_unit: unit).exists?

      started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version,
                                                 session_id: "seed-screening")
      raise "semente do acolhimento: conversa recusada (#{started.reason})" if started.failure?

      %w[true true].each_with_index do |answer, step|
        Citizens::SubmitAnswer.call(conversation: started.payload[:conversation], answer: answer,
                                    idempotency_key: "seed-screening-#{slug}-#{index}-#{Time.zone.today}-#{step}")
      end
      triage = started.payload[:triage].reload
      code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
      reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
      result = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                                         by: reception)
      raise "semente do acolhimento: check-in recusado (#{result.reason})" if result.failure?

      true
    end

    def cpf_for(seed)
      base = Digest::SHA256.hexdigest(seed).scan(/\d/).join[0, 9].ljust(9, "7")
      nums = base.chars.map(&:to_i)
      first = CitizenIdentity::Cpf.check_digit(nums)
      "#{base}#{first}#{CitizenIdentity::Cpf.check_digit(nums + [ first ])}"
    end
  end
end
