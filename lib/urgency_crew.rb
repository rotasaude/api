require "zlib"
require_relative "signature_crew"
require_relative "triage_catalog_crew"
require_relative "care_lines_crew"
require_relative "screening_crew"

# Semente de dev do módulo 32a (ADR 0050), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `urgency_care` e `waiting_room_display`
# LIGADOS pelo mantenedor de dev (com o prontuário); a "UPA 24h Centro" (do
# ProfessionalCrew) com prefixo de senha "U" e tempos na TV; a equipe pelos
# comandos do 10 (perfil e vínculo com o CBO real, conselho coerente, CNS com
# dígito válido), todos com TOTP fixo:
#
#   e-mail                     papel                CBO     função
#   upa@curitiba.dev           citizen_verifier     -       recepção (chegada)
#   upaenf@curitiba.dev        health_professional  223505  classifica (2235* é quem classifica)
#   upamed@curitiba.dev        health_professional  225125  atende e dá o desfecho (225*)
#
# (a médica 225124 e a técnica 322205 do ProfessionalCrew seguem lá: a técnica
# não classifica.) O protocolo `classificacao-urgencia` v1 passa pelo ciclo
# assinado de verdade (TriageCatalogCrew.run_cycle!), com os 5 níveis padrão e
# regras de EXEMPLO DE DEV: não é o Manchester; revisão clínica antes de uma
# cidade real. Os locais "Classificação de risco", "Consultório 1",
# "Consultório 2" e "Sala de medicação"; a "TV da recepção" (com tempos) e um
# código de pareamento NOVO a cada semente.
#
# Cenário, TUDO pelos comandos do app (Urgency::Arrive com `new_patient`,
# Classify, Attendances::Call, Consultations, RecordOutcome), com as chegadas
# escalonadas para a fila mostrar espera e um estouro:
#
#   quem                       chegou      o quê
#   Francisco das Chagas Lima  40 min      81 anos, febre 39,2: amarelo (dentro do limite)
#   Roberto Carlos Nogueira    25 min      66 anos, dor torácica, PA 182/104, dor 8: laranja ESTOURADO (limite 10)
#   Ana Beatriz Souza          15 min      28 anos, febre 38,4, dor 3: verde
#   Juliana Martins Prado       5 min      34 anos, azul reclassificada para verde (com justificativa)
#   não identificado            2 min      aguardando classificação (descrição do provisório)
#   José Carlos Pereira        ontem       paciente do CareLinesCrew com equipe da ESF: consulta de urgência
#                                          finalizada pela upamed, alta para a UBS com retorno em 7 dias
#                                          (contrarreferência da UBS e "Meu histórico")
#
# Dependências: o db:seed roda este crew depois do CareLinesCrew (a UBS, a equipe
# e o José com a consulta da médica) e do ProfessionalCrew (a UPA). Os comandos
# de chamada, consulta e fechamento não aceitam `now:`; o encontro de ontem usa
# travel_to em volta de cada passo, como os outros crews. Idempotente: tudo é
# achado pelo que já gravou (paciente pelo CPF, encontro pelo paciente na UPA,
# local e TV pelo nome) e o que já foi feito nunca se repete. Só e-mail, papel,
# otpauth e o código da TV na saída: nunca CPF, CNS, nome nem descrição de paciente.
class UrgencyCrew
  UNIT = "UPA 24h Centro".freeze
  DEV_MAINTAINER = "dev@local".freeze
  EMAIL_DOMAIN = "dev".freeze # upa@curitiba.dev
  FEATURES = %w[clinical_record urgency_care waiting_room_display].freeze
  PROTOCOL = "classificacao-urgencia".freeze
  TICKET_PREFIX = "U".freeze
  DISPLAY = "TV da recepção".freeze
  LOCATIONS = [ "Classificação de risco", "Consultório 1", "Consultório 2", "Sala de medicação" ].freeze
  DESK = "Consultório 1".freeze
  UNIDENTIFIED = "Homem, aparenta 40 anos, encontrado na rodoviária, confuso".freeze

  STAFF = {
    reception: { email_prefix: "upa", roles: %w[citizen_verifier], name: nil, council: nil, cbo: nil,
                 secret_env: "DEV_UPA_RECEPTION_OTP_SECRET", default_secret: "UPARECEPCAOSEMENTEDEVCURITIBA234" },
    nurse: { email_prefix: "upaenf", roles: %w[health_professional], name: "Fernanda Lima Carvalho", council: "COREN", cbo: "223505",
             secret_env: "DEV_UPA_NURSE_OTP_SECRET", default_secret: "UPAENFERMAGEMSEMENTEDEVCURITIBA2" },
    doctor: { email_prefix: "upamed", roles: %w[health_professional], name: "Rodrigo Menezes Albuquerque", council: "CRM", cbo: "225125",
              secret_env: "DEV_UPA_DOCTOR_OTP_SECRET", default_secret: "UPAMEDICINASEMENTEDEVCURITIBA234" }
  }.freeze

  # Níveis padrão (limite de espera em minutos por cor).
  LEVELS = [ [ "red", 0 ], [ "orange", 10 ], [ "yellow", 60 ], [ "green", 120 ], [ "blue", 240 ] ]
           .map { |color, minutes| { "color" => color, "max_wait_minutes" => minutes } }.freeze

  # EXEMPLO DE DEV, não é o Manchester; revisão clínica antes de cidade real.
  # A dor é a variável `pain_scale` (fora de `vitals`); vale a cor mais grave que casar.
  def self.rule(id, color, criterion, op, variable, value) = { "id" => id, "when" => { op => [ variable, value ] }, "color" => color, "criterion" => criterion }
  RULES = [
    rule("spo2-critica", "red", "Saturação de oxigênio abaixo de 90%", "lt", "vitals.spo2", 90),
    rule("pas-critica", "red", "Pressão sistólica de 200 mmHg ou mais", "gte", "vitals.systolic", 200),
    rule("fr-critica", "red", "Frequência respiratória de 30 ou mais", "gte", "vitals.respiratory_rate", 30),
    rule("dor-intensa", "orange", "Dor intensa (8 a 10)", "gte", "pain_scale", 8),
    rule("pas-muito-alta", "orange", "Pressão sistólica de 180 mmHg ou mais", "gte", "vitals.systolic", 180),
    rule("fc-muito-alta", "orange", "Frequência cardíaca de 130 ou mais", "gte", "vitals.heart_rate", 130),
    rule("glicemia-baixa", "orange", "Glicemia capilar abaixo de 60 mg/dL", "lt", "vitals.capillary_glucose", 60),
    rule("febre-alta", "yellow", "Temperatura de 39 °C ou mais", "gte", "vitals.temperature_c", 39),
    rule("dor-moderada", "yellow", "Dor moderada (5 a 7)", "gte", "pain_scale", 5),
    rule("febre", "green", "Temperatura de 37,8 °C ou mais", "gte", "vitals.temperature_c", 37.8),
    rule("dor-leve", "green", "Dor leve (2 a 4)", "gte", "pain_scale", 2)
  ].freeze

  # arrived: minutos atrás; classifications: cada uma `after` minutos depois da chegada.
  PEOPLE = {
    francisco: { name: "Francisco das Chagas Lima", mother: "Josefa das Chagas Lima", age: 81, sex: "male", arrived: 40,
                 classifications: [ { after: 2, color: "yellow", complaint: "Febre alta, tosse com catarro e cansaço há três dias",
                                      vitals: { "temperature_c" => "39.2", "respiratory_rate" => 22, "spo2" => 94, "heart_rate" => 104 }, pain: 4 } ] },
    roberto: { name: "Roberto Carlos Nogueira", mother: "Maria Aparecida Nogueira", age: 66, sex: "male", arrived: 25,
               classifications: [ { after: 1, color: "orange", complaint: "Dor no peito em aperto há 40 minutos, com irradiação para o braço esquerdo",
                                    vitals: { "systolic" => 182, "diastolic" => 104, "heart_rate" => 96, "spo2" => 96 }, pain: 8 } ] },
    ana: { name: "Ana Beatriz Souza", mother: "Cláudia Regina Souza", age: 28, sex: "female", arrived: 15,
           classifications: [ { after: 2, color: "green", complaint: "Febre e dor de garganta desde ontem",
                                vitals: { "temperature_c" => "38.4", "heart_rate" => 92 }, pain: 3 } ] },
    juliana: { name: "Juliana Martins Prado", mother: "Sandra Martins Prado", age: 34, sex: "female", arrived: 5,
               classifications: [ { after: 1, color: "blue", complaint: "Dor de garganta leve, sem febre, há três dias",
                                    vitals: { "temperature_c" => "36.6", "heart_rate" => 76 }, pain: 0,
                                    justification: "Sinais vitais normais e dor ausente; queixa leve." },
                                  { after: 3, color: "green", complaint: "Dor de garganta com piora e febre baixa",
                                    vitals: { "temperature_c" => "37.9", "heart_rate" => 88 }, pain: 3,
                                    justification: "Reavaliada: surgiu febre baixa e dor ao engolir." } ] }
  }.freeze
  UNIDENTIFIED_ARRIVED = 2

  # O paciente do CareLinesCrew com equipe (consulta `general` da médica da UBS):
  # a alta com retorno cai na contrarreferência da UBS dele.
  RETURN_PATIENT = :jose
  RETURN_DAYS = 7
  RETURN_REASON = "Reavaliar a dor lombar e ajustar o analgésico na UBS.".freeze
  YESTERDAY = {
    classification: { color: "green", complaint: "Dor lombar após esforço, sem fraqueza nas pernas",
                      vitals: { "systolic" => 138, "diastolic" => 86, "heart_rate" => 78 }, pain: 4 },
    draft: { "subjective" => "Dor lombar há dois dias após carregar peso, sem irradiação nem alteração urinária.",
             "objective" => "Bom estado geral, sem déficit neurológico.", "assessment" => "Lombalgia mecânica.",
             "plan" => "Analgesia e repouso relativo; retornar à UBS em 7 dias.", "conducts" => [ 1 ], "exam_requests" => [] }.freeze,
    # Dor lombar (CIAP-2 L03); a CIAP-2 de dev é um recorte, então vale a A01 (dor generalizada) se a L03 não existir.
    problem_codes: %w[L03 A01].freeze
  }.freeze

  class << self
    include ActiveSupport::Testing::TimeHelpers

    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] urgência: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      city = City.find(Current.city.id)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      unit = HealthUnit.find_by(name: UNIT) || raise("semente da urgência: #{UNIT} ausente — rode o db:seed inteiro (ProfessionalCrew) antes")
      unit.update!(ticket_prefix: TICKET_PREFIX, show_wait_times: true) unless unit.ticket_prefix == TICKET_PREFIX && unit.show_wait_times
      jose = Patient.find_by(cpf: CareLinesCrew.cpf_for(slug, RETURN_PATIENT)) ||
             raise("semente da urgência: #{RETURN_PATIENT} ausente — rode o CareLinesCrew (db:seed inteiro) antes")

      staff = staff!(slug, password, admin, unit)
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      protocol = protocol!(slug)
      locations = LOCATIONS.to_h { |name| [ name, location!(unit, name, admin) ] }
      display = display!(unit, admin)
      code = WaitingRoom::IssuePairingCode.call(display: display, by: admin)
      raise "semente da urgência: código da TV recusado (#{code.reason})" if code.failure?

      context = { slug: slug, unit: unit, staff: staff, locations: locations, clock: Time.current,
                  waiting_room: WaitingRoom::Gate.usable?(city) }
      PEOPLE.each { |key, person| person!(context, key, person) }
      unidentified!(context)
      yesterday!(context, jose)

      { switch: Urgency::Gate.usable?(city) ? "ligado (#{Urgency::Gate::KEY} e #{WaitingRoom::Gate::KEY})" : "ligado, não utilizável",
        unit: unit.name, protocol: "#{protocol.name} v#{protocol.version}", locations: locations.size,
        encounters: UrgencyEncounter.joins(:attendance).where(attendances: { health_unit_id: unit.id }).count,
        tv_code: code.payload.fetch(:code), tv_ttl_minutes: (WaitingRoom::IssuePairingCode::TTL / 60).to_i,
        users: staff.map { |key, user| { email: user.email_address, role: STAFF.fetch(key).fetch(:roles).first, otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel, otpauth e o código da
    # TV (nunca dado de paciente).
    def summary_lines(result, password:)
      head = "[seeds] urgência #{result[:switch]}"
      head += "; #{result[:unit]}; protocolo #{result[:protocol]}; #{result[:locations]} locais; #{result[:encounters]} encontros" if result[:unit]
      lines = [ head ]
      lines << "[seeds]               TV: código #{result[:tv_code]}, vale #{result[:tv_ttl_minutes]} min" if result[:tv_code]
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    # CPF fictício com dígito válido, estável pela semente.
    def cpf_for(slug, key) = ScreeningCrew.cpf_for("#{slug}:urgency:#{key}")

    private

    def guard_environment!
      raise "semente da urgência: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, unit: nil, protocol: nil, locations: 0, encounters: 0, tv_code: nil, users: [] }

    # Nunca com dado de paciente: só o motivo e os paths da recusa.
    def check!(result, what)
      if result.failure?
        problems = Array(result.details[:problems]).map { |p| "#{p[:error]}@#{p[:path]}" }.join(",")
        raise "semente da urgência: #{what} recusado (#{result.reason} #{result.details[:path]} #{problems})"
      end

      result
    end

    # --- equipe -------------------------------------------------------------------

    # { reception:, nurse:, doctor: } => User, com papel, TOTP e, para os clínicos,
    # perfil (conselho coerente com o CBO) e vínculo ativo na UPA.
    def staff!(slug, password, admin, unit)
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email_prefix]}@#{slug}.#{EMAIL_DOMAIN}")
        user.password = password
        user.save!
        spec.fetch(:roles).each { |role| Membership.find_or_create_by!(user: user, role: role) { |m| m.granted_at = Time.current } }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        user = user.reload
        if spec[:cbo]
          profile!(slug, user, spec, admin)
          link!(user, unit, spec, admin)
        end
        [ key, user.reload ]
      end
    end

    def profile!(slug, user, spec, admin)
      return if user.professional

      seed = "#{slug}:urgency:#{spec[:email_prefix]}"
      attrs = { professional_name: spec[:name], council: spec[:council], council_state: CityProfile.current&.uf.presence || "PR",
                cns: Professionals::Cns.generate(seed), registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s,
                cpf: ScreeningCrew.cpf_for(seed) }
      check!(Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin), "perfil de #{spec[:email_prefix]}")
      user.reload
    end

    def link!(user, unit, spec, admin)
      return if user.professional.links.active.exists?(health_unit_id: unit.id, cbo_code: spec[:cbo])

      check!(Professionals::OpenLink.call(professional: user.professional, health_unit_id: unit.id, cbo_code: spec[:cbo], by: admin),
             "vínculo de #{spec[:email_prefix]}")
    end

    # --- protocolo, locais e TV ---------------------------------------------------

    # O protocolo de urgência ativo da cidade (qualquer nome) vale; senão, o ciclo
    # assinado de verdade, retomando a versão que já existe, sem tocar nas outras.
    def protocol!(slug)
      active = ProtocolDefinition.urgency_protocols.find_by(status: "active")
      return active if active

      pending = ProtocolDefinition.where(name: PROTOCOL).where.not(status: %w[active retired]).order(:version).last
      version = pending&.version || ((ProtocolDefinition.where(name: PROTOCOL).maximum(:version) || 0) + 1)
      definition = { "name" => PROTOCOL, "version" => version, "kind" => "urgency_classification",
                     "levels" => LEVELS.deep_dup, "classification_rules" => RULES.deep_dup }
      TriageCatalogCrew.run_cycle!(slug, PROTOCOL, version, definition)
    end

    def location!(unit, name, admin)
      CallLocation.where(health_unit_id: unit.id).find_by("lower(name) = ?", name.downcase) ||
        check!(WaitingRoom::SaveCallLocation.call(attrs: { "health_unit_id" => unit.id, "name" => name }, by: admin), "local #{name}")
        .payload.fetch(:call_location)
    end

    def display!(unit, admin)
      WaitingRoomDisplay.find_by(health_unit_id: unit.id, name: DISPLAY) ||
        check!(WaitingRoom::SaveDisplay.call(attrs: { "health_unit_id" => unit.id, "name" => DISPLAY, "show_wait_times" => true }, by: admin),
               "TV").payload.fetch(:display)
    end

    # --- pessoas e encontros -------------------------------------------------------

    def encounter_of(unit, patient)
      UrgencyEncounter.joins(:attendance).find_by(attendances: { health_unit_id: unit.id, patient_id: patient.id })
    end

    def birth_of(person) = (Date.current.years_ago(person.fetch(:age)) - 40).iso8601

    # Chegada (paciente novo, conferência de duplicado revisada) e as classificações
    # que faltam, cada uma na hora escalonada.
    def person!(context, key, person)
      slug, unit, staff = context.values_at(:slug, :unit, :staff)
      patient = Patient.find_by(cpf: cpf_for(slug, key))
      encounter = patient && encounter_of(unit, patient)
      arrived_at = context[:clock] - person.fetch(:arrived).minutes
      encounter ||= begin
        typed = { "full_name" => person.fetch(:name), "birth_date" => birth_of(person), "sex" => person.fetch(:sex),
                  "mother_name" => person.fetch(:mother), "cpf" => cpf_for(slug, key),
                  "cns" => Professionals::Cns.generate("#{slug}:urgency:patient:#{key}") }
        arrive!(context, arrived_at, patient_id: patient&.id, new_patient: patient ? nil : typed)
      end
      classify_all!(context, encounter, person.fetch(:classifications), arrived_at)
    end

    def unidentified!(context)
      unit = context.fetch(:unit)
      provisional = Patient.where(unidentified: true).find { |patient| patient.unidentified_description == UNIDENTIFIED }
      return if provisional && encounter_of(unit, provisional)

      arrive!(context, context.fetch(:clock) - UNIDENTIFIED_ARRIVED.minutes, unidentified: { "description" => UNIDENTIFIED })
    end

    def arrive!(context, at, patient_id: nil, new_patient: nil, unidentified: nil)
      result = Urgency::Arrive.call(health_unit_id: context.fetch(:unit).id, by: context.dig(:staff, :reception), patient_id: patient_id,
                                    new_patient: new_patient, unidentified: unidentified, duplicates_reviewed: (true if new_patient),
                                    waiting_room: context.fetch(:waiting_room), now: at)
      check!(result, "chegada").payload.fetch(:encounter)
    end

    def classify_all!(context, encounter, steps, arrived_at)
      steps.each_with_index do |step, index|
        next if encounter.classifications.count > index

        attrs = { "complaint" => step.fetch(:complaint), "vital_signs" => step.fetch(:vitals), "pain_scale" => step.fetch(:pain),
                  "color" => step.fetch(:color), "justification" => step[:justification] }
        check!(Urgency::Classify.call(encounter: encounter, attrs: attrs, by: context.dig(:staff, :nurse), now: arrived_at + step.fetch(:after).minutes),
               "classificação")
        encounter.reload
      end
    end

    # O encontro de ontem do paciente da ESF: chegada, classificação, chamada do
    # médico, consulta de urgência finalizada e a alta para a UBS com retorno em
    # 7 dias. Cada passo roda ontem (travel_to), só os que faltam.
    def yesterday!(context, patient)
      unit, staff = context.values_at(:unit, :staff)
      return if encounter_of(unit, patient)&.closed?

      start = context.fetch(:clock) - 1.day
      encounter = encounter_of(unit, patient) || at(start, context) { arrive!(context, start, patient_id: patient.id) }
      classify_yesterday!(context, encounter, start)
      attendance = encounter.attendance.reload
      desk = context.fetch(:locations).fetch(DESK)
      doctor = staff.fetch(:doctor)
      consultation = Consultation.find_by(attendance_id: attendance.id)
      unless consultation
        at(start + 20.minutes, context) do
          check!(Attendances::Call.call(attendance: attendance, health_unit_id: attendance.health_unit_id, by: doctor, call_location_id: desk.id,
                                        waiting_room: context.fetch(:waiting_room)), "chamada do médico") if attendance.reload.status == "waiting"
          started = Consultations::Start.call(attendance: attendance.reload, by: doctor, kind: nil, city: Current.city)
          consultation = check!(started, "consulta de urgência").payload.fetch(:consultation)
        end
      end
      finalize_yesterday!(context, consultation, start + 40.minutes)
      outcome_yesterday!(context, encounter, patient, start + 45.minutes)
    end

    def classify_yesterday!(context, encounter, start)
      return if encounter.classifications.any?

      at(start + 3.minutes, context) { classify_all!(context, encounter, [ YESTERDAY.fetch(:classification).merge(after: 0) ], Time.current) }
    end

    def finalize_yesterday!(context, consultation, time)
      return unless consultation.reload.draft?

      doctor = context.dig(:staff, :doctor)
      at(time, context) do
        code = YESTERDAY.fetch(:problem_codes).find { |c| ClinicalTerms.find("ciap2", c) } || YESTERDAY.fetch(:problem_codes).first
        draft = YESTERDAY.fetch(:draft).merge("evaluated_problems" => [ { "terminology" => "ciap2", "code" => code, "action" => "add" } ])
        check!(Consultations::SaveDraft.call(consultation: consultation, params: draft, by: doctor), "rascunho da consulta")
        check!(Consultations::Finalize.call(consultation: consultation.reload, outcome_params: {}, by: doctor), "finalização da consulta")
      end
    end

    def outcome_yesterday!(context, encounter, patient, time)
      return if encounter.reload.closed?

      team_id = CareLines::TeamPopulation.patient_teams([ patient.id ])[patient.id]
      team = team_id && HealthTeam.find_by(id: team_id)
      raise "semente da urgência: o paciente da alta não tem equipe da ESF — rode o CareLinesCrew (db:seed inteiro) antes" unless team

      attrs = { "kind" => "discharged_to_primary_care", "return_guidance" => { "days" => RETURN_DAYS, "reason" => RETURN_REASON } }
      at(time, context) { check!(Urgency::RecordOutcome.call(encounter: encounter, attrs: attrs, by: context.dig(:staff, :doctor), team: team), "desfecho") }
    end

    # travel_to nunca passa de um segundo antes de agora.
    def at(time, context, &) = travel_to([ time, context.fetch(:clock) - 1.second ].min, &)
  end
end
