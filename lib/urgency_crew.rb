require "zlib"
require_relative "signature_crew"
require_relative "triage_catalog_crew"
require_relative "care_lines_crew"
require_relative "screening_crew"
require_relative "pharmacy_crew"

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
#
# Módulo 32b (observação, prescrição e baixa de estoque), depois do PharmacyCrew:
# `urgency_stock_deduction` ligado pelo mantenedor de dev; os leitos "OBS 01" a
# "OBS 04" da UPA; a "Farmácia da UPA 24h Centro" (local `unit`, com a
# farmacêutica do PharmacyCrew vinculada) com inventário de abertura de LOSARTANA,
# DIAZEPAM (B1), PARACETAMOL e AMOXICILINA, e SEM salbutamol; a técnica 322205 do
# ProfessionalCrew (tecnico@curitiba.demo) checa a medicação. Cenário, tudo pelos
# comandos do app, sem finalizar consulta (nenhum BPA nasce daqui):
#
#   quem                     há      o quê
#   Maria Aparecida Ferreira 22 h    58 anos, crise hipertensiva com ansiedade; no OBS 01 há 20 h 30
#                                    (near_limit); prescrição v1 com um controlado; as duas doses
#                                    únicas administradas com baixa e um paracetamol recusado
#   Benedito Alves Rocha     25,5 h  72 anos, pneumonia aguardando vaga; no OBS 03 e depois no OBS 02
#                                    (over_limit); prescrição v2 (a v1 substituída) com salbutamol,
#                                    cuja checagem gera a falta insufficient_balance (sem estoque)
class UrgencyCrew
  UNIT = "UPA 24h Centro".freeze
  DEV_MAINTAINER = "dev@local".freeze
  EMAIL_DOMAIN = "dev".freeze # upa@curitiba.dev
  FEATURES = %w[clinical_record urgency_care waiting_room_display urgency_stock_deduction].freeze
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

  # --- módulo 32b ------------------------------------------------------------
  BEDS = [ "OBS 01", "OBS 02", "OBS 03", "OBS 04" ].freeze
  UPA_PHARMACY = "Farmácia da UPA 24h Centro".freeze
  PHARMACIST_EMAIL = "farmacia@%<slug>s.demo".freeze
  TECHNICIAN_EMAIL = "tecnico@%<slug>s.demo".freeze # 322205 do ProfessionalCrew (login com TOTP fixo)
  # Sem SALBUTAMOL no estoque da UPA, de propósito: a checagem dele gera a falta.
  STOCK_ITEMS = {
    losartana: { code: 268_856, lot: "UPA-LS-01", quantity: "200" },
    diazepam: { code: 267_197, lot: "UPA-DZ-01", quantity: "50" },
    paracetamol: { code: 267_778, lot: "UPA-PC-01", quantity: "300" },
    amoxicilina: { code: 271_089, lot: "UPA-AM-01", quantity: "120" },
    salbutamol: { code: 294_887 }
  }.freeze
  STOCK_OPENING_DAYS_AGO = 3
  STOCK_EXPIRES_IN_DAYS = 400

  # hours: horas atrás (para o `at` de cada passo); stays/prescriptions/checks na ordem em que acontecem.
  # `item`: dose e frequência; `first`: horas atrás da 1ª dose; `check.slot`: true = no horário da 1ª dose.
  WARD = {
    maria: { name: "Maria Aparecida Ferreira", mother: "Conceição Aparecida Ferreira", age: 58, sex: "female", arrived: 22 * 60,
             classifications: [ { after: 3, color: "yellow", complaint: "Pressão alta com dor de cabeça e muita ansiedade desde a noite",
                                  vitals: { "systolic" => 176, "diastolic" => 104, "heart_rate" => 98, "spo2" => 97 }, pain: 5 } ],
             consultation: 21.0,
             stays: [ { bed: "OBS 01", hours: 20.5 } ],
             prescriptions: [ { hours: 20.0, items: [
               { drug: :losartana, dose: "50", dose_unit: "mg", route: "oral", frequency: { "kind" => "once" } },
               { drug: :diazepam, dose: "10", dose_unit: "mg", route: "oral", frequency: { "kind" => "once" } },
               { drug: :paracetamol, dose: "500", dose_unit: "mg", route: "oral", frequency: { "kind" => "if_needed", "max_per_day" => 4 } }
             ] } ],
             checks: [ { version: 1, drug: :losartana, status: "administered", hours: 19.5, slot: true },
                       { version: 1, drug: :diazepam, status: "administered", hours: 19.5, slot: true },
                       { version: 1, drug: :paracetamol, status: "refused", hours: 10.0, reason: "Paciente recusou a dose: sem dor no momento." } ] },
    benedito: { name: "Benedito Alves Rocha", mother: "Aparecida Alves Rocha", age: 72, sex: "male", arrived: (25.5 * 60).to_i,
                classifications: [ { after: 3, color: "yellow", complaint: "Tosse com catarro, febre e falta de ar há quatro dias",
                                     vitals: { "temperature_c" => "39.0", "respiratory_rate" => 24, "spo2" => 92, "heart_rate" => 108 }, pain: 5 } ],
                consultation: 25.2,
                stays: [ { bed: "OBS 03", hours: 25.0 }, { bed: "OBS 02", hours: 12.0 } ],
                prescriptions: [
                  { hours: 24.0, items: [ { drug: :amoxicilina, dose: "500", dose_unit: "mg", route: "oral", frequency: { "kind" => "interval", "interval_hours" => 8 } } ] },
                  { hours: 5.0, items: [
                    { drug: :amoxicilina, dose: "500", dose_unit: "mg", route: "oral", frequency: { "kind" => "interval", "interval_hours" => 8 } },
                    { drug: :salbutamol, dose: "100", dose_unit: "mcg", route: "inhalation", frequency: { "kind" => "interval", "interval_hours" => 6 } }
                  ] }
                ],
                checks: [ { version: 2, drug: :salbutamol, status: "administered", hours: 4.5, slot: true } ] }
  }.freeze

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
      return draft_only(slug) unless slug == "curitiba"

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
      observation = observation!(context.merge(city: city, admin: admin))

      { switch: Urgency::Gate.usable?(city) ? "ligado (#{Urgency::Gate::KEY} e #{WaitingRoom::Gate::KEY})" : "ligado, não utilizável",
        unit: unit.name, protocol: "#{protocol.name} v#{protocol.version}", locations: locations.size,
        encounters: UrgencyEncounter.joins(:attendance).where(attendances: { health_unit_id: unit.id }).count,
        beds: observation.fetch(:beds), open_shortfalls: observation.fetch(:open_shortfalls),
        tv_code: code.payload.fetch(:code), tv_ttl_minutes: (WaitingRoom::IssuePairingCode::TTL / 60).to_i,
        users: staff.map { |key, user| { email: user.email_address, role: STAFF.fetch(key).fetch(:roles).first, otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel, otpauth e o código da
    # TV (nunca dado de paciente).
    def summary_lines(result, password:)
      head = "[seeds] urgência #{result[:switch]}"
      head += "; #{result[:protocol]}" if result[:protocol] && !result[:unit]
      head += "; #{result[:unit]}; protocolo #{result[:protocol]}; #{result[:locations]} locais; #{result[:encounters]} encontros; leitos: #{result[:beds]}; faltas abertas: #{result[:open_shortfalls]}" if result[:unit]
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

    # Fora de Curitiba só o rascunho do protocolo (como o ScreeningCrew): sem
    # interruptores, equipe, locais, TV nem pacientes. Idempotente.
    def draft_only(slug)
      existing = ProtocolDefinition.where(name: PROTOCOL).order(:version).last
      unless existing
        author = User.find_by!(email_address: "autor@#{slug}.demo")
        saved = Protocols::SaveDraft.call(definition: definition(1), by: author)
        raise "semente da urgência: rascunho recusado (#{saved.reason})" if saved.failure?

        existing = saved.payload[:protocol_definition]
      end
      off("fora").merge(protocol: "#{existing.name} v#{existing.version} (#{existing.status})")
    end

    def definition(version)
      { "name" => PROTOCOL, "version" => version, "kind" => "urgency_classification",
        "levels" => LEVELS.deep_dup, "classification_rules" => RULES.deep_dup }
    end

    def off(switch) = { switch: switch, unit: nil, protocol: nil, locations: 0, encounters: 0, beds: 0, open_shortfalls: 0, tv_code: nil, users: [] }

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
      TriageCatalogCrew.run_cycle!(slug, PROTOCOL, version, definition(version))
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

    # Determinístico: o mais antigo; `prefer_closed` põe o já fechado na frente.
    def encounter_of(unit, patient, prefer_closed: false)
      found = UrgencyEncounter.joins(:attendance).where(attendances: { health_unit_id: unit.id, patient_id: patient.id })
                              .order("urgency_encounters.created_at ASC, urgency_encounters.id ASC").to_a
      (prefer_closed && found.find(&:closed?)) || found.first
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
      return if encounter_of(unit, patient, prefer_closed: true)&.closed?

      start = context.fetch(:clock) - 1.day
      encounter = encounter_of(unit, patient, prefer_closed: true) || at(start, context) { arrive!(context, start, patient_id: patient.id) }
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

    # --- módulo 32b: observação, prescrição, checagem e baixa --------------------

    # -> { beds:, open_shortfalls: }
    def observation!(context)
      slug, unit, admin = context.values_at(:slug, :unit, :admin)
      doctor = context.dig(:staff, :doctor)
      technician = User.find_by(email_address: format(TECHNICIAN_EMAIL, slug: slug))
      pharmacist = User.find_by(email_address: format(PHARMACIST_EMAIL, slug: slug))
      unless technician&.professional&.links&.active&.exists?(health_unit_id: unit.id, cbo_code: "322205")
        raise "semente da urgência: a técnica 322205 da UPA ausente — rode o ProfessionalCrew (db:seed inteiro) antes"
      end
      raise "semente da urgência: a farmacêutica ausente — rode o PharmacyCrew (db:seed inteiro) antes" unless pharmacist

      beds = BEDS.to_h { |label| [ label, bed!(unit, label, admin) ] }
      location = upa_pharmacy!(unit, admin, pharmacist)
      items = stock_items!
      opening!(context, location, pharmacist, items)

      stock_on = Urgency::StockGate.usable?(context.fetch(:city))
      catalog = items.values.index_by(&:id)
      WARD.each do |key, person|
        person!(context, key, person)
        patient = Patient.find_by!(cpf: cpf_for(slug, key))
        encounter = encounter_of(unit, patient)
        consult!(context, encounter, person.fetch(:consultation))
        ward!(context, encounter, person, beds: beds, items: items, catalog: catalog, doctor: doctor, technician: technician, stock: stock_on)
      end
      { beds: UrgencyBed.where(health_unit_id: unit.id, label: BEDS).count,
        open_shortfalls: UrgencyStockShortfall.open_shortfalls.where(stock_location_id: location.id).count }
    end

    def bed!(unit, label, admin)
      UrgencyBed.find_by(health_unit_id: unit.id, label: label) ||
        check!(Urgency::SaveBed.call(attrs: { "health_unit_id" => unit.id, "label" => label }, by: admin), "leito #{label}").payload.fetch(:bed)
    end

    # O local `unit` da UPA, com a farmacêutica do PharmacyCrew vinculada.
    def upa_pharmacy!(unit, admin, pharmacist)
      location = StockLocation.find_by(health_unit_id: unit.id, kind: "unit") ||
                 check!(Pharmacy::SaveLocation.call(attrs: { "kind" => "unit", "name" => UPA_PHARMACY, "health_unit_id" => unit.id }, by: admin),
                        "local da farmácia da UPA").payload.fetch(:location)
      linked = Pharmacy::LinkStaff.add(location: location, user_id: pharmacist.id, role: "pharmacist", by: admin)
      check!(linked, "vínculo da farmacêutica à UPA") unless linked.ok? || linked.reason == :already_linked
      location
    end

    # { chave => MedicationCatalogItem }, lido fora da transação da cidade (como os controladores).
    def stock_items!
      STOCK_ITEMS.to_h do |key, spec|
        item = MedicationCatalogItem.prescribable.find_by(catmat_code: spec.fetch(:code)) ||
               raise("semente da urgência: item #{spec.fetch(:code)} fora do catálogo — rode o db:seed inteiro (medicamentos) antes")
        [ key, item ]
      end
    end

    # Abertura (um item por abertura): só os itens sem abertura no local. Salbutamol fica de fora.
    def opening!(context, location, pharmacist, items)
      clock = context.fetch(:clock)
      pending = STOCK_ITEMS.select { |key, spec| spec[:lot] && !StockOpening.exists?(stock_location_id: location.id, catalog_item_id: items.fetch(key).id) }
      return if pending.empty?

      rows = pending.map do |key, spec|
        { "catalog_item_id" => items.fetch(key).id, "lot_number" => spec.fetch(:lot), "expires_on" => (Time.zone.today + STOCK_EXPIRES_IN_DAYS).iso8601,
          "quantity" => spec.fetch(:quantity) }
      end
      result = at(clock - STOCK_OPENING_DAYS_AGO.days, context) do
        Pharmacy::RecordEntry.call(location: location, kind: "opening", document: nil, items: rows, by: pharmacist, catalog: items.values.index_by(&:id))
      end
      check!(result, "inventário de abertura da UPA")
    end

    # Chamada pelo médico e consulta `urgency` iniciada (sem finalizar), `hours` atrás.
    def consult!(context, encounter, hours)
      attendance = encounter.attendance.reload
      return if Consultation.exists?(attendance_id: attendance.id)

      doctor = context.dig(:staff, :doctor)
      desk = context.fetch(:locations).fetch(DESK)
      at(context.fetch(:clock) - hours.hours, context) do
        check!(Attendances::Call.call(attendance: attendance, health_unit_id: attendance.health_unit_id, by: doctor, call_location_id: desk.id,
                                      waiting_room: context.fetch(:waiting_room)), "chamada do médico") if attendance.status == "waiting"
        check!(Consultations::Start.call(attendance: attendance.reload, by: doctor, kind: nil, city: Current.city), "consulta de urgência")
      end
    end

    def ward!(context, encounter, person, beds:, items:, catalog:, doctor:, technician:, stock:)
      clock = context.fetch(:clock)
      person.fetch(:stays).each_with_index do |stay, index|
        next if encounter.bed_stays.reload.size > index

        at(clock - stay.fetch(:hours).hours, context) do
          check!(Urgency::StartObservation.call(encounter: encounter.reload, bed_id: beds.fetch(stay.fetch(:bed)).id, by: doctor, now: Time.current), "entrada no leito")
        end
      end
      person.fetch(:prescriptions).each_with_index do |plan, index|
        next if encounter.prescriptions.reload.size > index

        at(clock - plan.fetch(:hours).hours, context) do
          now = Time.current
          rows = plan.fetch(:items).map { |row| prescription_row(row, items, now) }
          check!(Urgency::IssuePrescription.call(encounter: encounter.reload, items: rows, catalog: catalog, by: doctor, now: now), "prescrição")
        end
      end
      person.fetch(:checks).each { |plan| check_dose!(context, encounter, plan, items: items, technician: technician, stock: stock) }
    end

    def prescription_row(row, items, now)
      { "catalog_item_id" => items.fetch(row.fetch(:drug)).id, "dose" => row.fetch(:dose), "dose_unit" => row.fetch(:dose_unit), "route" => row.fetch(:route),
        "frequency" => row.fetch(:frequency), "first_dose_at" => now.iso8601 }
    end

    # Uma checagem por (item, status); a das `once`/`interval` no horário da 1ª dose.
    def check_dose!(context, encounter, plan, items:, technician:, stock:)
      prescription = encounter.prescriptions.reload.find { |candidate| candidate.version == plan.fetch(:version) } ||
                     raise("semente da urgência: prescrição v#{plan.fetch(:version)} ausente")
      item = prescription.items.find { |candidate| candidate.catalog_item_id == items.fetch(plan.fetch(:drug)).id }
      return if UrgencyAdministration.exists?(urgency_prescription_item_id: item.id, status: plan.fetch(:status))

      attrs = { "prescription_item_id" => item.id, "status" => plan.fetch(:status) }
      attrs["scheduled_at"] = item.first_dose_at.iso8601 if plan[:slot]
      attrs["reason"] = plan.fetch(:reason) if plan[:reason]
      at(context.fetch(:clock) - plan.fetch(:hours).hours, context) do
        check!(Urgency::RecordAdministration.call(attrs: attrs, by: technician, stock: stock, now: Time.current), "checagem da medicação")
      end
    end

    # travel_to nunca passa de um segundo antes de agora.
    def at(time, context, &) = travel_to([ time, context.fetch(:clock) - 1.second ].min, &)
  end
end
