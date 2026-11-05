require "zlib"
require_relative "signature_crew"
require_relative "dev_terminology"
require_relative "care_lines_crew"

# Semente de dev do módulo 31 (ADR 0049), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `psychosocial_care` LIGADO pelo
# mantenedor de dev (com o prontuário); os CAPS "CAPS II Boa Vista" (`caps_ii`,
# classificação 001) e "CAPS AD III Centro Vida" (`caps_ad_iii`, classificação
# 001, leitos L1 a L4), ambos com CNES e telefone de dev; a equipe lotada pelos
# comandos do 10 (vínculo com o CBO real, conselho coerente, CNS com dígito
# válido; o perfil é gravado direto, ver profile!) e com vínculo no retrato do CNES da cidade, todos com TOTP fixo:
#
#   e-mail                     papel                               CBO     lotação
#   caps@curitiba.dev          psychosocial_lead (e _staff)        223505  CAPS II e AD III
#   capsmed@curitiba.dev       psychosocial_staff                  225133  CAPS II e AD III
#   capspsi@curitiba.dev       psychosocial_staff                  251510  CAPS II
#   capstec@curitiba.dev       psychosocial_staff                  322205  CAPS AD III
#
# e o cenário abaixo, TUDO pelos comandos do app (SaveBed, SaveGroup,
# CreateEnrollment, SaveCarePlan, RecordAction, UpdateMonthlyRecord,
# StartNightStay, RecordMatrixSupport e AddMatrixCase):
#
#   quem                       onde      o quê
#   Renato Alves Pereira       CAPS II   F200, PTS em dia, ações (a de hoje deixa a RAAS do mês sem pendência),
#                                        um caso compartilhado com a ESF no matriciamento de hoje
#   Luciana Rocha Mendes       CAPS II   F321, PTS com a revisão vencida há 10 dias
#   Marcos Vinícius Teixeira   CAPS AD III F102 (álcool), PTS em dia, permanência aberta no leito L2
#   Patrícia Gomes Lima        CAPS AD III F142 (cocaína e maconha), sem PTS ainda
#   grupos (CAPS II)           "Oficina de artesanato" (quarta 14:00 às 16:00, 0301080216), com uma sessão
#                              recente do Renato e da Luciana, e "Assembleia de usuários" (sexta 10:00)
#
# Pessoas: pares validados novos (CPF e CNS fictícios válidos, telefone
# +55 <ddd> 97777-NNNN), pela mesma recepção das outras sementes. Dependências:
# o db:seed roda este crew depois do CareLinesCrew (a UBS e a equipe da ESF
# para o matriciamento) e do RecordModeCrew (o retrato do CNES). Idempotente:
# unidade, leito, grupo, matrícula, PTS, ações, permanência e matriciamento são
# achados pelo que já gravaram e nunca duplicados (o que a coordenação fechou ou
# encerrou na prova não é recriado). O PTS vencido NÃO é gravado direto: o
# comando recebe o `today` de 100 dias atrás, e a `review_on` de 10 dias atrás
# passa na regra "depois de hoje". Só e-mail, papel e otpauth na saída: nunca
# CPF, CNS, nome nem CID de paciente.
class PsychosocialCrew
  UNIT = CareLinesCrew::UNIT # a UBS da ESF do matriciamento
  DEV_MAINTAINER = "dev@local".freeze
  EMAIL_DOMAIN = "dev".freeze # caps@curitiba.dev
  PHONE_PREFIX = "97777".freeze # único entre os lib/*_crew.rb
  CID10_VERSION = "dev-caps".freeze
  FEATURES = %w[clinical_record psychosocial_care].freeze
  PLAN_OVERDUE_DAYS = 10
  PLAN_AGE_DAYS = 100

  # key: o CAPS; phone: telefone da unidade (P27: 10 ou 11 dígitos, só dígitos).
  UNITS = {
    ii: { name: "CAPS II Boa Vista", modality: "caps_ii", phone: "4133334410" },
    ad: { name: "CAPS AD III Centro Vida", modality: "caps_ad_iii", phone: "41933334420" }
  }.freeze
  BEDS = %w[L1 L2 L3 L4].freeze

  # links: CAPS => CBO (o vínculo ativo em cada um).
  STAFF = {
    lead: { email_prefix: "caps", roles: %w[psychosocial_lead psychosocial_staff], name: "Beatriz Helena Cordeiro", council: "COREN",
            links: { ii: "223505", ad: "223505" },
            secret_env: "DEV_CAPS_LEAD_OTP_SECRET", default_secret: "CAPSCOORDENACAOSEMENTEDEVCWBPSI" },
    doctor: { email_prefix: "capsmed", roles: %w[psychosocial_staff], name: "Henrique Augusto Vasconcelos", council: "CRM",
              links: { ii: "225133", ad: "225133" },
              secret_env: "DEV_CAPS_DOCTOR_OTP_SECRET", default_secret: "CAPSMEDICOPSIQUIATRASEMENTEDEVCWB" },
    psychologist: { email_prefix: "capspsi", roles: %w[psychosocial_staff], name: "Camila Rodrigues Farias", council: "CRP",
                    links: { ii: "251510" },
                    secret_env: "DEV_CAPS_PSYCHOLOGIST_OTP_SECRET", default_secret: "CAPSPSICOLOGASEMENTEDEVCURITIBA" },
    technician: { email_prefix: "capstec", roles: %w[psychosocial_staff], name: "Everton Luiz Batista", council: "COREN",
                  links: { ad: "322205" },
                  secret_env: "DEV_CAPS_TECHNICIAN_OTP_SECRET", default_secret: "CAPSTECNICOENFERMAGEMSEMENTEDEV" }
  }.freeze

  CID10 = {
    "F200" => "Esquizofrenia paranoide", "F321" => "Episódio depressivo moderado",
    "F102" => "Transtornos mentais e comportamentais devidos ao uso de álcool - síndrome de dependência",
    "F142" => "Transtornos mentais e comportamentais devidos ao uso da cocaína - síndrome de dependência"
  }.freeze

  # start: dia do mês anterior em que a matrícula começou (a RAAS abre desde
  # então: mês anterior e corrente); by: quem atua (ações) e reference: o
  # técnico de referência, ambos lotados no CAPS; code: o procedimento da ação.
  PATIENTS = {
    renato: { phone: 1, name: "Renato Alves Pereira", mother: "Marlene Alves Pereira", birth: "1984-06-22", sex: "male",
              race_color: "02", zip: "80510000", street: "Rua Padre Anchieta", number: "1250", district: "Bigorrilho",
              unit: :ii, cid: "F200", substances: %w[99], origin: "02", esf: true, start: 10, reference: :psychologist,
              by: :psychologist, code: "0301080208" },
    luciana: { phone: 2, name: "Luciana Rocha Mendes", mother: "Terezinha Rocha Mendes", birth: "1992-02-09", sex: "female",
               race_color: "01", zip: "80250000", street: "Rua Bruno Filgueira", number: "480", district: "Batel",
               unit: :ii, cid: "F321", substances: %w[99], origin: "01", start: 5, reference: :lead, by: :doctor,
               code: "0301080208" },
    marcos: { phone: 3, name: "Marcos Vinícius Teixeira", mother: "Neuza Teixeira", birth: "1979-10-30", sex: "male",
              race_color: "03", zip: "80035000", street: "Rua Mateus Leme", number: "92", district: "Centro Cívico",
              unit: :ad, cid: "F102", substances: %w[01], origin: "03", start: 15, reference: :lead, by: :technician,
              code: "0301080194" },
    patricia: { phone: 4, name: "Patrícia Gomes Lima", mother: "Sueli Gomes Lima", birth: "1990-12-03", sex: "female",
                race_color: "04", zip: "80620000", street: "Rua Pedro Gusso", number: "2301", district: "Novo Mundo",
                unit: :ad, cid: "F142", substances: %w[02 04], origin: "05", start: 20, reference: :doctor, by: :lead,
                code: "0301080208" }
  }.freeze

  # Os dois PTS gravados (a Patrícia ainda não tem). review: dias até a revisão (negativo = vencida).
  PLANS = {
    renato: { review_in: 60, intensity: "semi_intensive",
              needs: "Adesão ao tratamento medicamentoso e rotina estruturada; apoio da família e reinserção em atividades de trabalho.",
              goals: [ "Manter o uso regular da medicação, com acompanhamento mensal", "Participar da oficina de artesanato toda semana" ] },
    luciana: { review_in: -PLAN_OVERDUE_DAYS, intensity: "non_intensive",
               needs: "Acompanhamento do episódio depressivo, sono regular e retomada gradual das atividades diárias.",
               goals: [ "Retomar a rotina de sono e alimentação", "Retornar às atividades do dia a dia aos poucos" ] },
    marcos: { review_in: 30, intensity: "intensive",
              needs: "Abstinência de álcool com suporte no acolhimento noturno; vínculo com a rede de apoio e plano de prevenção de recaída.",
              goals: [ "Completar o período de acolhimento noturno previsto", "Definir o plano de prevenção de recaída com a família" ] }
  }.freeze

  GROUPS = {
    workshop: { "name" => "Oficina de artesanato", "kind" => "workshop", "weekday" => 3, "starts_at" => "14:00", "ends_at" => "16:00",
                "capacity" => 12, "sigtap_code" => "0301080216", responsible: :psychologist },
    assembly: { "name" => "Assembleia de usuários", "kind" => "assembly", "weekday" => 5, "starts_at" => "10:00", "ends_at" => "11:30",
                "capacity" => 30, "sigtap_code" => "0301080267", responsible: :lead }
  }.freeze

  MATRIX_CODE = "0301080305".freeze
  MATRIX_TOPIC = "Matriciamento da ESF Jardim das Flores: manejo de pacientes com transtorno mental grave na atenção básica.".freeze
  MATRIX_CASE = "Acompanhado no CAPS II; manter a consulta mensal na UBS e avisar o CAPS se houver sinal de crise ou abandono do tratamento.".freeze
  NIGHT_STAY = { bed: "L2", started_days_ago: 2, ends_in_days: 3 }.freeze

  class << self
    # A SIGTAP de dev com os procedimentos do CAPS (mês e anterior) e os CID-10
    # dos pacientes. Uma release real ativa nunca é tocada.
    def seed_platform!
      guard_environment!
      today = Time.zone.today
      competences = [ (today << 1).strftime("%Y%m"), today.strftime("%Y%m") ]
      sigtap = DevTerminology.ensure_sigtap!(codes: SigtapSample::PSYCHOSOCIAL_CODES, competences: competences,
                                             label: "semente do CAPS: SIGTAP")
      { sigtap: sigtap, cid10: cid10! }
    end

    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] CAPS: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      city = City.find(Current.city.id)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      ubs = HealthUnit.find_by(name: UNIT) || raise("semente do CAPS: #{UNIT} ausente — rode o db:seed inteiro (CareLinesCrew) antes")
      check_terminology!

      units = UNITS.transform_values { |spec| unit!(slug, spec) }
      PsychosocialSetting.ensure_defaults!
      staff = staff!(slug, password, admin, units)
      cnes_bonds!(staff, units)
      beds = BEDS.to_h { |label| [ label, bed!(units.fetch(:ad), label, staff.fetch(:lead)) ] }
      groups = GROUPS.to_h { |key, spec| [ key, group!(units.fetch(:ii), spec, staff) ] }

      enrollments = PATIENTS.to_h do |key, person|
        patient = patient!(slug, ddd.presence || "41", key, person)
        [ key, enrollment!(units.fetch(person.fetch(:unit)), patient, person, staff, ubs) ]
      end
      PLANS.each { |key, plan| care_plan!(enrollments.fetch(key), plan, staff.fetch(PATIENTS.fetch(key).fetch(:reference)), staff) }
      PATIENTS.each { |key, person| actions!(units.fetch(person.fetch(:unit)), enrollments.fetch(key), person, staff) }
      group_session!(units.fetch(:ii), groups.fetch(:workshop), enrollments.values_at(:renato, :luciana), staff.fetch(:psychologist))
      enrollments.each_value { |enrollment| homeless!(enrollment) }
      night_stay!(units.fetch(:ad), beds.fetch(NIGHT_STAY.fetch(:bed)), enrollments.fetch(:marcos), staff.fetch(:technician))
      matrix!(units.fetch(:ii), ubs, enrollments.fetch(:renato).patient, staff)
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }

      { switch: Psychosocial::Gate.usable?(city) ? "ligado (#{Psychosocial::Gate::KEY})" : "ligado, não utilizável",
        units: units.values.map(&:name), beds: PsychosocialBed.count, groups: PsychosocialGroup.count,
        enrollments: PsychosocialEnrollment.count, care_plans: PsychosocialCarePlan.count, actions: PsychosocialAction.count,
        night_stays: PsychosocialNightStay.open_stays.count, matrix_supports: PsychosocialMatrixSupport.count,
        users: staff.map { |key, user| { email: user.email_address, role: STAFF.fetch(key).fetch(:roles).first, otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel e otpauth (nunca dado de paciente).
    def summary_lines(result, password:)
      lines = [ "[seeds] atenção psicossocial #{result[:switch]}" \
                "#{"; #{result[:units].join(' e ')}; #{result[:beds]} leitos; #{result[:groups]} grupos; #{result[:enrollments]} matrículas; " \
                   "#{result[:care_plans]} PTS; #{result[:actions]} ações; #{result[:night_stays]} permanência aberta; " \
                   "#{result[:matrix_supports]} matriciamento" if result[:units].any?}" ]
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    # CPF fictício com dígito válido, estável pela semente (a mesma conta das outras).
    def cpf_for(slug, key) = ScreeningCrew.send(:cpf_for, "#{slug}:psychosocial:#{key}")

    def phone_for(ddd, key) = format("+55%s#{PHONE_PREFIX}%04d", ddd, PATIENTS.fetch(key).fetch(:phone))

    private

    def guard_environment!
      raise "semente do CAPS: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, units: [], beds: 0, groups: 0, enrollments: 0, care_plans: 0, actions: 0, night_stays: 0, matrix_supports: 0, users: [] }

    # Nunca com dado de paciente: só o motivo e os códigos/paths da recusa.
    def check!(result, what)
      if result.failure?
        problems = Array(result.details[:problems]).map { |p| "#{p[:error]}@#{p[:path]}" }.join(",")
        raise "semente do CAPS: #{what} recusado (#{result.reason} #{result.details[:path]} #{problems})"
      end

      result
    end

    def dev_cnes(name) = format("%07d", (Zlib.crc32("health-unit:#{name}") % 9_000_000) + 1_000_000)

    # --- terminologias ----------------------------------------------------------

    # O recorte "dev-*" ativo ganha os CID-10 dos pacientes; uma release real
    # ativa nunca é tocada (só avisa).
    def cid10!
      status = DevTerminology.add_cid10!(codes: CID10.transform_values { |description| [ description, nil ] }, version: CID10_VERSION,
                                         label: "semente do CAPS: CID-10")
      warn "[seeds] CAPS: CID-10 ativa não é o recorte de dev — diagnósticos dos pacientes não republicados" if status == :real_cid10
      status
    end

    # A SIGTAP do mês tem os procedimentos do CAPS e o CID-10 tem o F200: sem
    # isso a crítica da ação recusaria (ou a matrícula), e a mensagem diz o remédio.
    def check_terminology!
      release = TerminologyRelease.active.find_by(kind: "sigtap", version: Time.zone.today.strftime("%Y%m"))
      codes = SigtapSample::PSYCHOSOCIAL_CODES
      unless release && SigtapProcedure.where(release_id: release.id, code: codes).count == codes.size
        raise "semente do CAPS: SIGTAP do mês sem os procedimentos do CAPS — rode o db:seed inteiro (PsychosocialCrew.seed_platform!) antes"
      end
      return if ClinicalTerms.find("cid10", "F200")

      raise "semente do CAPS: CID-10 sem o F200 — rode o db:seed inteiro (PsychosocialCrew.seed_platform!) antes"
    end

    # --- unidades, leitos e grupos --------------------------------------------

    def unit!(slug, spec)
      HealthUnit.find_by(name: spec.fetch(:name)) ||
        HealthUnit.create!(name: spec.fetch(:name), kind: "caps", caps_modality: spec.fetch(:modality), service_classification: "001",
                           cnes: dev_cnes(spec.fetch(:name)), phone: spec.fetch(:phone))
    end

    def bed!(unit, label, lead)
      PsychosocialBed.find_by(health_unit_id: unit.id, label: label) ||
        check!(Psychosocial::SaveBed.call(attrs: { "health_unit_id" => unit.id, "label" => label }, by: lead), "leito #{label}").payload.fetch(:bed)
    end

    def group!(unit, spec, staff)
      PsychosocialGroup.find_by(health_unit_id: unit.id, name: spec.fetch("name")) ||
        check!(Psychosocial::SaveGroup.call(attrs: spec.except(:responsible).merge("health_unit_id" => unit.id,
                                                                                    "responsible_user_id" => staff.fetch(spec.fetch(:responsible)).id),
                                            by: staff.fetch(:lead)), "grupo #{spec.fetch('name')}").payload.fetch(:group)
    end

    # --- equipe -------------------------------------------------------------------

    # { lead:, doctor:, psychologist:, technician: } => User, com papel, TOTP,
    # perfil (conselho coerente com o CBO) e vínculo ativo nos CAPS.
    def staff!(slug, password, admin, units)
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email_prefix]}@#{slug}.#{EMAIL_DOMAIN}")
        user.password = password
        user.save!
        spec.fetch(:roles).each { |role| Membership.find_or_create_by!(user: user, role: role) { |m| m.granted_at = Time.current } }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        user = user.reload
        profile!(slug, user, spec, admin)
        spec.fetch(:links).each { |unit_key, cbo| link!(user, units.fetch(unit_key), cbo, spec, admin) }
        [ key, user.reload ]
      end
    end

    def profile!(slug, user, spec, admin)
      return if user.professional

      seed = "#{slug}:psychosocial:#{spec[:email_prefix]}"
      attrs = { professional_name: spec[:name], council: spec[:council], council_state: CityProfile.current&.uf.presence || "PR",
                cns: Professionals::Cns.generate(seed), registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s,
                cpf: ScreeningCrew.send(:cpf_for, seed) }
      # Gravação direta do perfil (a validação do modelo vale: conselho, CNS, CPF). O comando
      # Professionals::Create só aceita quem tem health_professional ou lab_releaser, e a equipe
      # do CAPS NÃO recebe health_professional (ruling 7b: abriria a UBS ao psiquiatra do CAPS pela
      # leitura contextual). Os vínculos, esses sim, saem pelo Professionals::OpenLink.
      Professional.create!(user: user, **attrs)
      user.reload
    end

    def link!(user, unit, cbo, spec, admin)
      return if user.professional.links.active.exists?(health_unit_id: unit.id, cbo_code: cbo)

      check!(Professionals::OpenLink.call(professional: user.professional, health_unit_id: unit.id, cbo_code: cbo, by: admin),
             "vínculo de #{spec[:email_prefix]}")
    end

    # O CNS de cada profissional, com o CBO da lotação, no CNES de cada CAPS dele,
    # no retrato mais recente do CNES da cidade (é o que o fechamento da RAAS
    # confere). Sem retrato, grava um mínimo; com retrato, só acrescenta o que
    # falta, sem reescrevê-lo. Sem IBGE na cidade, avisa e segue.
    def cnes_bonds!(staff, units)
      ibge = CityProfile.current&.ibge_code
      if ibge.blank?
        warn "[seeds] CAPS: cidade sem IBGE — vínculos do CNES não gravados (o fechamento da RAAS vai acusar professional_not_in_cnes)"
        return
      end

      wanted = STAFF.flat_map do |key, spec|
        spec.fetch(:links).map { |unit_key, cbo| { cnes: units.fetch(unit_key).cnes, cbo_code: cbo, cns: staff.fetch(key).professional.cns, ine: nil, cpf: nil } }
      end
      snapshot = CnesSnapshot.where(ibge_code: ibge).order(competence: :desc).first
      if snapshot.nil?
        Cnes::SnapshotWriter.write!(competence: Time.zone.today.prev_month.strftime("%Y%m"), ibge_code: ibge, teams: [],
                                    establishments: units.values.map { |unit| { cnes: unit.cnes, name: unit.name.upcase, unit_type: "70" } },
                                    bonds: wanted)
        return
      end

      present = snapshot.bonds.where(cnes: units.values.map(&:cnes)).to_set { |bond| [ bond.cns.to_s.gsub(/\D/, ""), bond.cnes, bond.cbo_code ] }
      wanted.reject { |bond| present.include?([ bond[:cns], bond[:cnes], bond[:cbo_code] ]) }
            .each { |bond| CnesProfessionalBond.create!(snapshot: snapshot, **bond) }
    end

    # --- pacientes e matrículas ----------------------------------------------------

    # O par validado pela recepção (como as outras sementes), o paciente, o CNS e
    # a raça/cor e o endereço do BPA-I/RAAS. -> Patient
    def patient!(slug, ddd, key, person)
      registered = Citizens::RegisterPerson.call(phone: phone_for(ddd, key), cpf: cpf_for(slug, key),
                                                 profile: { birth_date: person[:birth], sex: person[:sex], gender_identity: nil })
      raise "semente do CAPS: pessoa #{key} recusada (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      unless citizen.verification_level_verified?
        reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
        code = Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
        verified = Citizens::Verify.call(cpf: citizen.cpf, code: code, document_checked: true, by: reception, birth_date: person[:birth],
                                         sex: person[:sex], full_name: person[:name], mother_name: person[:mother])
        raise "semente do CAPS: validação #{key} recusada (#{verified.reason})" if verified.failure?
      end
      citizen.reload
      patient = citizen.patient || Patients::Resolve.call(citizen).payload&.dig(:patient)
      raise "semente do CAPS: paciente #{key} não resolvido" unless patient

      patient.update!(cns: Professionals::Cns.generate("#{slug}:psychosocial:patient:#{key}")) if patient.cns.blank?
      demographics!(patient, person)
      patient
    end

    def demographics!(patient, person)
      return if patient.race_color.present?

      parsed = Patients::Demographics.parse("race_color" => person[:race_color], "address_zip" => person[:zip], "address_street" => person[:street],
                                            "address_number" => person[:number], "address_district" => person[:district])
      raise "semente do CAPS: demografia recusada (#{parsed.reason})" if parsed.failure?

      saved = patient.with_lock { Patients::Demographics.save!(patient, parsed.payload.fetch(:values)) }
      raise "semente do CAPS: demografia recusada (#{saved.reason})" if saved.failure?
    end

    def enrollment!(unit, patient, person, staff, ubs)
      existing = PsychosocialEnrollment.find_by(patient_id: patient.id, health_unit_id: unit.id)
      return existing if existing

      started_on = Time.zone.today.beginning_of_month.prev_month + (person.fetch(:start) - 1)
      esf = person[:esf] == true && ubs.cnes.present?
      attrs = { "patient_id" => patient.id, "started_on" => started_on.iso8601, "origin" => person.fetch(:origin), "cid_main" => person.fetch(:cid),
                "cid_secondary" => [], "substances" => person.fetch(:substances), "esf_covered" => esf,
                "reference_user_id" => staff.fetch(person.fetch(:reference)).id }
      attrs["esf_cnes"] = ubs.cnes if esf
      check!(Psychosocial::CreateEnrollment.call(attrs: attrs, unit: unit, by: staff.fetch(:lead)), "matrícula").payload.fetch(:enrollment)
    end

    # A primeira versão do PTS (a matrícula com PTS não ganha outra). Revisão no
    # passado: o `today` do comando é o de PLAN_AGE_DAYS atrás.
    def care_plan!(enrollment, spec, author, staff)
      return if PsychosocialCarePlan.exists?(psychosocial_enrollment_id: enrollment.id)

      today = Time.zone.today
      attrs = { "needs" => spec.fetch(:needs), "intensity" => spec.fetch(:intensity), "review_on" => (today + spec.fetch(:review_in)).iso8601,
                "goals" => spec.fetch(:goals).map { |text| { "text" => text, "responsible_user_id" => author.id } } }
      command_today = spec.fetch(:review_in).negative? ? today - PLAN_AGE_DAYS : today
      check!(Psychosocial::SaveCarePlan.call(enrollment: enrollment, attrs: attrs, by: author, today: command_today), "PTS")
    end

    # --- ações ---------------------------------------------------------------------

    # Duas ações individuais por matrícula: três dias depois do início (mês anterior)
    # e hoje. A de hoje fica no mês corrente, por isso a RAAS dele sai sem pendência.
    def actions!(unit, enrollment, person, staff)
      return if participant_scope(enrollment).where(psychosocial_actions: { psychosocial_group_id: nil }).exists?

      by = staff.fetch(person.fetch(:by))
      [ enrollment.started_on + 3, Time.zone.today ].each do |day|
        record!(unit, by, sigtap_code: person.fetch(:code), performed_at: moment(day), participants: [ { "enrollment_id" => enrollment.id } ])
      end
    end

    # A última oficina (quarta anterior a hoje, 14:00) com as duas matrículas.
    def group_session!(unit, group, enrollments, by)
      return if PsychosocialAction.exists?(psychosocial_group_id: group.id)

      day = Time.zone.today - 1
      day -= 1 until day.wday == group.weekday % 7
      record!(unit, by, sigtap_code: group.sigtap_code, performed_at: day.in_time_zone.change(hour: 14), group_id: group.id,
                        participants: enrollments.map { |enrollment| { "enrollment_id" => enrollment.id } })
    end

    def participant_scope(enrollment)
      PsychosocialActionParticipant.joins(:psychosocial_action).where(psychosocial_enrollment_id: enrollment.id)
    end

    # 10:00 locais do dia, ou agora se ainda não deu 10:00 (nunca no futuro).
    def moment(day) = [ day.in_time_zone.change(hour: 10), Time.current ].min

    def record!(unit, by, performed_at:, **attrs)
      body = { "place" => "caps", "quantity" => 1, "performed_at" => performed_at.iso8601 }.merge(attrs.stringify_keys)
      result = Psychosocial::RecordAction.call(attrs: body, unit: unit, by: by, link: Psychosocial::Access.link(by, unit.id))
      check!(result, "ação").payload.fetch(:action)
    end

    # Situação de rua informada (não) nos meses abertos da matrícula: a RAAS do mês sai sem pendência.
    def homeless!(enrollment)
      PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrollment.id, status: "open", homeless: nil).find_each do |record|
        check!(Psychosocial::UpdateMonthlyRecord.call(record: record, attrs: { "homeless" => false }), "situação de rua")
      end
    end

    # --- acolhimento noturno e matriciamento -----------------------------------------

    # O Marcos no leito L2 desde anteontem, saída prevista em 3 dias. Achada pela
    # matrícula (aberta ou já fechada na prova): a semente não recria a permanência.
    def night_stay!(unit, bed, enrollment, by)
      return if PsychosocialNightStay.exists?(psychosocial_enrollment_id: enrollment.id)

      today = Time.zone.today
      attrs = { "bed_id" => bed.id, "enrollment_id" => enrollment.id,
                "started_at" => (today - NIGHT_STAY.fetch(:started_days_ago)).in_time_zone.change(hour: 21).iso8601,
                "expected_end_at" => (today + NIGHT_STAY.fetch(:ends_in_days)).in_time_zone.change(hour: 8).iso8601 }
      check!(Psychosocial::StartNightStay.call(attrs: attrs, by: by, link: Psychosocial::Access.link(by, unit.id)), "permanência")
    end

    # O matriciamento de hoje com a ESF da UBS e um caso compartilhado do paciente (o Renato).
    def matrix!(unit, ubs, patient, staff)
      team = HealthTeam.where(health_unit_id: ubs.id, active: true, kind: HealthTeam::PRIMARY_CARE_KINDS).order(:created_at).first
      raise "semente do CAPS: a #{UNIT} não tem equipe da atenção primária ativa — rode o db:seed inteiro (CareLinesCrew) antes" unless team

      lead = staff.fetch(:lead)
      support = PsychosocialMatrixSupport.find_by(health_unit_id: unit.id, health_team_id: team.id)
      support ||= check!(Psychosocial::RecordMatrixSupport.call(
        attrs: { "health_team_id" => team.id, "held_on" => Time.zone.today.iso8601, "topic" => MATRIX_TOPIC, "sigtap_code" => MATRIX_CODE,
                 "participants_user_ids" => [ lead.id, staff.fetch(:psychologist).id ] },
        unit: unit, by: lead, link: Psychosocial::Access.link(lead, unit.id)
      ), "matriciamento").payload.fetch(:matrix_support)
      return if PsychosocialMatrixCase.exists?(psychosocial_matrix_support_id: support.id, patient_id: patient.id)

      check!(Psychosocial::AddMatrixCase.call(support: support, attrs: { "patient_id" => patient.id, "shared_text" => MATRIX_CASE }, by: lead),
             "caso do matriciamento")
    end
  end
end
