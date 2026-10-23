require "zlib"
require_relative "signature_crew"
require_relative "campaign_history"
require_relative "triage_catalog_crew"
require_relative "screening_crew"
require_relative "clinical_record_crew"

# Semente de dev do módulo 23 (ADR 0040). Dev é fictício mas imita o real:
# em Curitiba, care_lines LIGADO pelo mantenedor de dev; as seis linhas do
# catálogo-base (só a v1: a v2 é publicada na prova do maintenance) adotadas
# pelo admin e a linha própria "Saúde mental — acompanhamento"; na UBS Jardim
# das Flores, uma equipe com a médica, a enfermeira e uma técnica de
# enfermagem (322245, também na recepção: citizen_verifier, para o "Agendar"
# abrir a marcação) e as pessoas das provas no navegador (PEOPLE). Toda
# inscrição passa pela confirmação (AcceptSuggestion), nunca nasce direto. Só
# o histórico com data passada (a consulta de 25 meses da P18 e a triagem de
# 45 dias) é gravado direto, como lib/campaign_history.rb. Idempotente. Roda
# depois do ClinicalRecordCrew (UBS, médica, enfermeira, recepção, CIAP/CID)
# e do TriageCatalogCrew (protocolo saude-mental, repetição em 30 dias).
class CareLinesCrew
  UNIT = "UBS Jardim das Flores".freeze
  # Prefixo do telefone dos cidadãos da semente: único entre os lib/*_crew.rb.
  PHONE_PREFIX = "93333".freeze
  DEV_MAINTAINER = "dev@local".freeze
  TEAM_NAME = "ESF JARDIM DAS FLORES".freeze
  MENTAL = {
    "name" => "Saúde mental — acompanhamento", "declared_condition" => "mental_health",
    "eligibility" => { "problems" => { "ciap2" => %w[P74 P76], "cid10" => %w[F32 F33 F41] }, "declared" => %w[mental_health] },
    "practices" => [ { "key" => "sm_a", "label" => "Consulta de acompanhamento a cada 3 meses", "citizen_label" => "Consulta de acompanhamento",
                       "source" => "consultation", "anchor" => "rolling", "window_days" => 92, "min_count" => 1, "schedule" => "end_of_window",
                       "cbo_filter" => %w[2251 2235 251510] } ]
  }.freeze
  # Técnica de enfermagem da ESF (CBO 322245), na equipe; sem CBO de quem
  # confirma, vê as sugestões e não aceita. Também faz a recepção da UBS
  # (citizen_verifier): é quem marca pelo "Agendar" (can_book).
  TECHNICIAN = { email_prefix: "tecnica", professional_name: "Patrícia Gomes Ribeiro", cbo: "322245",
                 secret_env: "DEV_FAMILY_TECHNICIAN_OTP_SECRET", default_secret: "TECNICALINHASDECUIDADOSEMENTE234" }.freeze
  TECHNICIAN_ROLES = %w[health_professional citizen_verifier].freeze
  # Pessoas da semente: telefone +55 <ddd> 93333-<phone>; nascimento fixo
  # (birth) ou relativo a hoje (days_old; age em anos, 40 dias depois do
  # aniversário), para a idade da prova não mudar com o calendário.
  # verified: false = par só declarado (sem validação no balcão).
  # territory: mora no bairro coberto só pela UBS (equipe pelo território).
  PEOPLE = {
    jose: { phone: 1, name: "José Carlos Pereira", mother: "Iracema Pereira", birth: "1968-03-14", sex: "male", territory: true },
    sandra: { phone: 1, name: "Sandra Regina Pereira", birth: "1970-07-08", sex: "female", verified: false },
    ana: { phone: 2, name: "Ana Beatriz Souza", mother: "Lúcia Souza", birth: "1999-05-02", sex: "female", territory: true },
    miguel: { phone: 3, name: "Miguel Oliveira Santos", mother: "Camila Oliveira Santos", days_old: 150, sex: "male", territory: true },
    maria: { phone: 4, name: "Maria das Graças Lima", mother: "Benedita Lima", birth: "1953-08-20", sex: "female", territory: true },
    rafael: { phone: 5, name: "Rafael Costa Almeida", mother: "Sônia Costa", birth: "1991-11-03", sex: "male", territory: true },
    antonio: { phone: 6, name: "Antônio Ferreira Gomes", mother: "Aparecida Ferreira", age: 62, sex: "male", territory: false },
    juliana: { phone: 7, name: "Juliana Martins Rocha", mother: "Rosângela Martins", birth: "2001-09-17", sex: "female", territory: true },
    osvaldo: { phone: 8, name: "Osvaldo Ribeiro Nunes", mother: "Cecília Ribeiro", birth: "1958-06-25", sex: "male", territory: true },
    sebastiao: { phone: 9, name: "Sebastião Alves Rocha", mother: "Joana Alves", birth: "1955-01-30", sex: "male", territory: true }
  }.freeze
  DRAFT = {
    "subjective" => "Retorno de rotina.", "objective" => "Bom estado geral.", "assessment" => "Acompanhamento.",
    "plan" => "Retorno conforme a linha de cuidado.", "care_type" => 5, "conducts" => [ 1 ], "exam_requests" => []
  }.freeze
  # Consultas de hoje (caminho real do 19a): quem atende, problemas, sinais e
  # desfecho. O José sai com alta: sem pedido de retorno aberto na UBS, o
  # "Agendar" da linha cria o pedido care_line do módulo 17 (com um retorno
  # aberto, o api o reaproveitaria).
  CONSULTATIONS = {
    jose: { by: "profissional", problems: [ %w[ciap2 T90], %w[ciap2 K86] ], outcome: "discharged",
            vitals: { "systolic" => 148, "diastolic" => 92, "weight_kg" => "86.0", "height_cm" => 171 } },
    ana: { by: "enfermeira", problems: [ %w[ciap2 W78] ], outcome: "return",
           vitals: { "systolic" => 110, "diastolic" => 70, "weight_kg" => "62.5", "height_cm" => 163 } },
    sebastiao: { by: "profissional", problems: [ %w[ciap2 R05] ], outcome: "discharged",
                 vitals: { "systolic" => 132, "diastolic" => 80, "weight_kg" => "71.0", "height_cm" => 166 } }
  }.freeze
  # P18: última consulta finalizada há 25 meses (fora dos 24): equipe pelo território.
  P18_MONTHS_AGO = 25
  # Triagem periódica vencida (F-23.8): saude-mental repete em 30 dias.
  OVERDUE_TRIAGE_DAYS_AGO = 45
  PREGNANCY_LMP_DAYS_AGO = 70

  class << self
    def seed_platform!
      guard_environment!
      CareLines::Templates::Load.call
    end

    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("desligado (só Curitiba liga)") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] linhas de cuidado: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      # Pré-requisitos, antes de ligar: sem catálogo-base não há o que adotar.
      if CareLineTemplate.latest.empty?
        raise "semente das linhas: catálogo-base não carregado — rode bin/rails care_lines:templates:load (ou o db:seed inteiro)"
      end
      # A triagem periódica vencida (prova 10) usa o protocolo do TriageCatalogCrew.
      unless ProtocolDefinition.exists?(name: TriageCatalogCrew::MENTAL, status: "active")
        raise "semente das linhas: protocolo #{TriageCatalogCrew::MENTAL} sem versão ativa — rode o TriageCatalogCrew (db:seed) antes"
      end

      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: CareLines::Gate::KEY, enabled: true, maintainer: maintainer)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      adopt!(admin)
      unit = HealthUnit.find_by!(name: UNIT)
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      nurse = User.find_by!(email_address: "enfermeira@#{slug}.demo")
      technician = technician!(slug, password, admin, unit)
      team = team!(slug, unit, doctor, nurse, technician)
      neighborhood = neighborhood!(unit)
      people = PEOPLE.keys.to_h { |key| [ key, citizen!(slug, ddd, key, neighborhood) ] }

      staff = { "profissional" => doctor, "enfermeira" => nurse }
      CONSULTATIONS.each { |key, visit| consult!(slug, unit, staff.fetch(visit[:by]), people[key], visit) }
      past_consultation!(slug, unit, doctor, people[:osvaldo])

      accept!(people[:jose], "diabetes_c4", team, nurse)
      accept!(people[:ana], "pregnancy_c3", team, doctor, anchor_date: (Time.zone.today - PREGNANCY_LMP_DAYS_AGO).iso8601)
      accept!(people[:miguel], "child_c2", team, nurse)
      declare!(people[:rafael], "mental_health")
      declare!(people[:juliana], "pregnancy")
      %i[maria rafael juliana osvaldo sebastiao].each { |key| CareLines::Suggest.for_citizen(people[key].id) }
      overdue_triage!(people[:jose])

      { switch: switch_label(city), team: team.name, people: PEOPLE.values.map { |p| p[:name] },
        pending: CareLineSuggestion.pending_suggestions.where(team_id: team.id).count,
        users: [ { email: technician.email_address, role: TECHNICIAN_ROLES.join(" + "), otpauth_uri: SignatureCrew.otpauth_uri(technician) } ] }
    end

    # CPF da pessoa da semente (dígito válido, estável pela semente).
    def cpf_for(slug, key) = ScreeningCrew.send(:cpf_for, "#{slug}:care_lines:#{key}")

    def phone_for(ddd, key) = format("+55%s#{PHONE_PREFIX}%04d", ddd, PEOPLE.fetch(key)[:phone])

    private

    def birth_of(person)
      return person[:birth] if person[:birth]
      return (Time.zone.today - person[:days_old]).iso8601 if person[:days_old]

      (Time.zone.today - person.fetch(:age).years - 40.days).iso8601
    end

    def off(switch) = { switch: switch, team: nil, people: [], pending: 0, users: [] }

    # Ligado não basta: o interruptor exige o prontuário utilizável (record_mode e clinical_record).
    def switch_label(city)
      return "ligado (care_lines)" if CareLines::Gate.usable?(city)

      "ligado, não utilizável (falta: #{Platform::Features.missing(city, CareLines::Gate::KEY).join(', ')})"
    end

    def guard_environment!
      raise "semente das linhas de cuidado: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def adopt!(admin)
      CareLineTemplate.latest.each do |template|
        next if CareLine.exists?(template_key: template.key)

        result = CareLines::SaveLine.call(params: { "template_key" => template.key, "template_version" => template.version }, by: admin)
        raise "semente das linhas: adoção #{template.key} recusada (#{result.reason})" if result.failure?
      end
      return if CareLine.exists?(declared_condition: "mental_health")

      result = CareLines::SaveLine.call(params: MENTAL, by: admin)
      raise "semente das linhas: linha própria recusada (#{result.reason} #{result.details})" if result.failure?
    end

    def technician!(slug, password, admin, unit)
      user = User.find_or_initialize_by(email_address: "#{TECHNICIAN[:email_prefix]}@#{slug}.demo")
      user.password = password
      user.save!
      TECHNICIAN_ROLES.each { |role| Membership.find_or_create_by!(user: user, role: role) { |m| m.granted_at = Time.current } }
      SignatureCrew.ensure_totp(user, secret_env: TECHNICIAN[:secret_env], default_secret: TECHNICIAN[:default_secret])
      professional = user.professional || technician_profile!(slug, user, admin)
      unless professional.links.active.exists?(health_unit: unit, cbo_code: TECHNICIAN[:cbo])
        opened = Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: TECHNICIAN[:cbo], by: admin)
        raise "semente das linhas: vínculo da técnica recusado (#{opened.reason})" if opened.failure?
      end
      user.reload
    end

    def technician_profile!(slug, user, admin)
      seed = "#{slug}:#{TECHNICIAN[:email_prefix]}"
      attrs = { professional_name: TECHNICIAN[:professional_name], council: "COREN", council_state: CityProfile.current&.uf.presence || "PR",
                cns: Professionals::Cns.generate(seed), registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s,
                cpf: ScreeningCrew.send(:cpf_for, seed) }
      result = Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin)
      raise "semente das linhas: perfil da técnica recusado (#{result.reason} #{result.details})" if result.failure?

      result.payload[:professional]
    end

    # A equipe ativa que já existir na UBS (a do ExamCrew em dev) ou a da
    # semente. Uma só: o par sem paciente acha a equipe pela ÚNICA equipe
    # ativa das unidades do bairro; com duas, ninguém do território recebe.
    def team!(slug, unit, *users)
      teams = HealthTeam.where(health_unit: unit, active: true).order(:created_at)
      warn "[seeds] linhas de cuidado: #{teams.count} equipes ativas na #{UNIT} — o território não dá equipe" if teams.count > 1
      team = teams.first || HealthTeam.create!(health_unit: unit, kind: "70", name: TEAM_NAME,
                                               ine: Zlib.crc32("ine:#{slug}:#{TEAM_NAME}").to_s.rjust(10, "0"))
      users.each do |user|
        next if HealthTeamMember.active.exists?(professional: user.professional, health_team: team)

        link = user.professional.links.active.find_by!(health_unit: unit)
        HealthTeamMember.create!(professional: user.professional, health_team: team, cbo_code: link.cbo_code, started_on: Time.zone.today - 365)
      end
      team
    end

    # Um bairro coberto SÓ pela UBS (a equipe da pessoa sai do bairro).
    def neighborhood!(unit)
      covered = NeighborhoodCoverage.where(health_unit_id: unit.id).pluck(:neighborhood_id)
      only = NeighborhoodCoverage.where(neighborhood_id: covered).group(:neighborhood_id).having("count(*) = 1").pluck(:neighborhood_id)
      Neighborhood.where(id: only, active: true).order(:name).first ||
        Neighborhood.find_or_create_by!(name: "Jardim das Flores (linhas de cuidado)") { |n| n.source = "manual" }.tap do |n|
          NeighborhoodCoverage.find_or_create_by!(neighborhood: n, health_unit: unit)
        end
    end

    def citizen!(slug, ddd, key, neighborhood)
      person = PEOPLE.fetch(key)
      birth = birth_of(person)
      registered = Citizens::RegisterPerson.call(phone: phone_for(ddd, key), cpf: cpf_for(slug, key),
                                                 profile: { birth_date: birth, sex: person[:sex], gender_identity: nil })
      raise "semente das linhas: pessoa #{key} recusada (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      return citizen if person[:verified] == false

      unless citizen.verification_level_verified?
        reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
        code = Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
        verified = Citizens::Verify.call(cpf: citizen.cpf, code: code, document_checked: true, by: reception, birth_date: birth,
                                         sex: person[:sex], full_name: person[:name], mother_name: person[:mother])
        raise "semente das linhas: validação #{key} recusada (#{verified.reason})" if verified.failure?
      end
      if person[:territory] && citizen.reload.neighborhood_id.nil?
        moved = Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: neighborhood.id)
        raise "semente das linhas: bairro de #{key} recusado (#{moved.reason})" if moved.failure?
      end
      citizen.reload
    end

    # Consulta de hoje com os problemas (caminho real do 19a), só se a pessoa
    # ainda não tem consulta finalizada.
    def consult!(slug, unit, by, citizen, visit)
      citizen.reload
      return if citizen.patient && citizen.patient.consultations.finalized_consultations.exists?

      attendance = ClinicalRecordCrew.send(:checked_in!, slug, unit, citizen, "linhas-#{citizen.id[0, 8]}")
      called = Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: by)
      raise "semente das linhas: chamada recusada (#{called.reason})" if called.failure?

      started = Consultations::Start.call(attendance: attendance.reload, by: by)
      raise "semente das linhas: consulta recusada (#{started.reason})" if started.failure?

      consultation = started.payload.fetch(:consultation)
      draft = DRAFT.merge("vitals" => visit[:vitals],
                          "evaluated_problems" => visit[:problems].map { |t, code| { "terminology" => t, "code" => code, "action" => "add" } })
      saved = Consultations::SaveDraft.call(consultation: consultation, params: draft, by: by)
      raise "semente das linhas: rascunho recusado (#{saved.reason} #{saved.details})" if saved.failure?

      finalized = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => visit.fetch(:outcome) }, by: by)
      raise "semente das linhas: finalização recusada (#{finalized.reason} #{finalized.details})" if finalized.failure?
    end

    # P18: paciente cuja última consulta finalizada (da médica da equipe, na
    # UBS) foi há 25 meses. Histórico gravado direto, como o CampaignHistory:
    # os comandos só aceitam "agora". O banco recusa atendimento que não nasce
    # aguardando e consulta finalizada que muda: aqui ela já nasce finalizada.
    def past_consultation!(slug, unit, doctor, citizen)
      resolved = Patients::Resolve.call(citizen)
      raise "semente das linhas: paciente da P18 recusado (#{resolved.reason})" if resolved.failure?

      patient = resolved.payload.fetch(:patient)
      return if patient.consultations.exists?

      at = P18_MONTHS_AGO.months.ago.change(hour: 9, min: 30)
      link = doctor.professional.links.active.find_by!(health_unit: unit)
      reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
      ApplicationRecord.transaction do
        triage = CampaignHistory.triage!(citizen, at: at - 1.hour)
        attendance = Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: reception,
                                        checked_in_at: at - 50.minutes, check_in_method: "code")
        attendance.update!(status: "in_care", called_by_user: doctor, called_at: at - 30.minutes)
        Consultation.create!(attendance: attendance, patient: patient, author_user: doctor, professional_link: link, cbo_code: link.cbo_code,
                             status: "finalized", started_at: at - 25.minutes, finalized_at: at, created_at: at - 25.minutes, updated_at: at,
                             care_type: 5, subjective: "Rotina.", objective: "Bom estado geral.", assessment: "Sem queixas.",
                             plan: "Retorno anual.", systolic: 136, diastolic: 84, weight_kg: 74.0, height_cm: 168)
        attendance.update!(status: "closed", outcome: "discharged", closed_by_user: doctor, closed_at: at)
      end
    end

    # Sugestão do sistema → confirmação do profissional (nunca inscrição direta).
    def accept!(citizen, template_key, team, by, anchor_date: nil)
      line = CareLine.find_by!(template_key: template_key)
      citizen.reload
      return if citizen.patient_id && CareLineEnrollment.active_enrollments.exists?(patient_id: citizen.patient_id, care_line: line)

      CareLines::Suggest.for_citizen(citizen.id)
      pending = CareLineSuggestion.pending_suggestions.where(care_line: line).where.not(reason: "resolved_problem")
      suggestion = citizen.patient_id ? pending.find_by(patient_id: citizen.patient_id) : pending.find_by(citizen_id: citizen.id)
      raise "semente das linhas: sem sugestão #{template_key} para a pessoa" unless suggestion

      result = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: by, anchor_date: anchor_date)
      raise "semente das linhas: confirmação #{template_key} recusada (#{result.reason})" if result.failure?
    end

    def declare!(citizen, condition)
      result = CareLines::DeclareCondition.call(citizen: citizen, condition: condition)
      raise "semente das linhas: condição declarada recusada (#{result.reason})" if result.failure?
    end

    # Triagem saude-mental (repete em 30 dias) concluída há 45 dias: vencida
    # em "Meu acompanhamento". Gravada direto com a data passada.
    def overdue_triage!(citizen)
      name = TriageCatalogCrew::MENTAL
      protocol = ProtocolDefinition.find_by!(name: name, status: "active")
      return if Triage.joins(:conversation).where(conversations: { citizen_id: citizen.id }, protocol_name: name).exists?

      at = (Time.zone.today - OVERDUE_TRIAGE_DAYS_AGO).in_time_zone.change(hour: 10)
      conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed", created_at: at - 5.minutes)
      Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: name, status: "completed", tier: "baixa",
                     priority: 9, answers: { "humor" => "false", "interesse" => "false", "sono" => "true" },
                     created_at: at - 5.minutes, completed_at: at, neighborhood_id: citizen.neighborhood_id)
    end
  end
end
