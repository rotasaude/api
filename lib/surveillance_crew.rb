require "active_support/testing/time_helpers"
require_relative "signature_crew"
require_relative "screening_crew"
require_relative "clinical_record_crew"
require_relative "care_lines_crew"
require_relative "territory_registry_crew"
require_relative "dev_terminology"

# Semente de dev do módulo 25 (ADR 0043), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, surveillance LIGADO pelo mantenedor
# de dev; a vigilante Patrícia Helena Duarte (vigilancia@, papel surveillance,
# OTP fixo; o usuário não tem campo de nome, o nome é o da persona do
# cenário); a doença local de dev; e as notificações abaixo, todas pelos
# comandos do app (CreateManual, Transition, SaveForm, SafetyNet,
# RecordNegative), com as mesmas validações da tela. As datas passadas vêm de
# travel_to em volta do comando (o instante da notificação e do andamento é o
# do dia, como teria nascido), sempre até um segundo antes de agora.
# Para a prova no navegador, resete e re-semeie no dia (o cenário é relativo à data da semeadura).
# A tuberculose de Benedito e a hepatite de Londrina são suspeitas hoje (semanais, vencem em 7 dias).
# Idempotente (a notificação existente de paciente × doença é retomada do
# estado em que está, nunca duplicada). Roda depois do CareLinesCrew e do
# TerritoryRegistryCrew (de quem vêm a UBS, a médica, a recepção, as pessoas e
# a Benedito, sem CPF). Exige a lista nacional carregada (db:seed, plataforma).
#
# Semanas relativas a hoje: W = a última semana epidemiológica COMPLETA
# (EpiWeek.current(hoje).pred). Em 27/10/2026 (SE 43), W = SE 42/2026 e as
# semanas anteriores são SE 38–41; é o cenário da prova.
#
# Dengue (A90), por bairro de residência × semana dos primeiros sintomas
# (o que o painel conta). Sinal no bairro da UBS, Santa Felicidade; células
# suprimidas (1–4) nos outros dois:
#
#   bairro            notificada por         W-4  W-3  W-2  W-1   W    andamento
#   Santa Felicidade  UBS Jardim das Flores    1    1    2    1   6    W-4..W-1: digitada (entered);
#                                                                      W: 2 digitadas, 4 em investigação
#   Boqueirão         UBS Vila Esperança       .    .    .    .   3    em investigação
#   Batel             UBS Vila Esperança       .    .    .    .   2    em investigação
#
#   total: 11 + 3 + 2 = 16 casos. Contrato K14: a base de 4 semanas suprimidas
#   (1, 1, 2, 1) entra como 2,5 cada, média 2,5; 6 > 2 × 2,5 → sinal em W no
#   Santa Felicidade, e só nele (célula nil não tem sinal). Os casos de Boqueirão
#   e Batel têm sintomas em W e suspeita no domingo seguinte: a UBS Vila
#   Esperança não tem caso em W (só a negativa).
#
# Fila e relatórios (resto do cenário):
#
#   agravo                    quem                       onde                andamento
#   sarampo (imediata)        pessoa nova                Centro              notificada há 30 h → VENCIDA (alerta)
#   tuberculose               José Carlos Pereira (23)   Butiatuvinha        em investigação, ficha preenchida
#   hanseníase                Osvaldo Ribeiro Nunes (23) cadastro do 23      digitada, número de 7 dígitos
#   sífilis em gestante       Ana Beatriz Souza (23)     Butiatuvinha        ENCERRADA sem número (relatório)
#   tuberculose               Benedito (24a, sem CPF)    sem bairro          notificada
#   hepatites virais          pessoa de Londrina (nova)  residência 4113700  notificada (manual, residente fora)
#   dengue (rede de segur.)   pessoa nova, consulta A90  Santa Felicidade    POSSÍVEL (só se A90 existe na CID-10)
#
#   count esperado: { overdue: 1 (o sarampo), immediate_open: 1 (o sarampo),
#   without_official_number: 1 (a sífilis) }. Nenhuma dengue passada fica em
#   possible/notified (venceria).
#
# Negativas da semana W: UBS Jardim das Flores COM caso (SE W); UBS Vila
# Esperança com a negativa gravada; UPA 24h Centro (que passa a notificar,
# como o admin faria em Unidades) PENDENTE.
#
# Doença local de dev: local_agravo_dev_pr "Agravo estadual (exemplo de dev)",
# semanal, CID R17. O contrato (K13(d)) tira X22 (escorpionismo) dela: está na
# lista nacional, em acidente_animal_peconhento. Não há lista estadual do PR
# nas fontes versionadas (vendor/surveillance), então o agravo é fictício e
# rotulado como de dev; R17 não é prefixo de nenhum CID da lista nacional,
# nem o contrário (o SaveLocalDisease confere).
#
# Telefones: +55 <ddd> 96666-NNNN a partir de 2600 (a semente do 24a vai até
# 2400; as campanhas começam em 0001). A semente só imprime e-mail, papel e o
# otpauth da vigilante: nunca dado de paciente.
class SurveillanceCrew
  UNIT = CareLinesCrew::UNIT
  SECOND_UNIT = "UBS Vila Esperança".freeze
  THIRD_UNIT = "UPA 24h Centro".freeze
  DEV_MAINTAINER = "dev@local".freeze
  PHONE_PREFIX = "96666".freeze
  PHONE_BASE = 2600
  OFFICER = { email_prefix: "vigilancia", name: "Patrícia Helena Duarte", role: "surveillance",
              secret_env: "DEV_SURVEILLANCE_OTP_SECRET", default_secret: "VIGILANCIAEPIDEMIOLOGICASEMENTE2" }.freeze
  LOCAL_DISEASE = { "code" => "local_agravo_dev_pr", "name" => "Agravo estadual (exemplo de dev)", "deadline" => "weekly",
                    "cid10" => [ "R17" ], "ciap2" => [], "repeat_after_days" => 30 }.freeze
  LONDRINA = "4113700".freeze

  # Dengue: bairro, unidade que notifica e quantos casos por semana (n semanas
  # antes de W). entered: quantos dos casos de W já foram digitados no Sinan.
  DENGUE = [
    { neighborhood: "Santa Felicidade", unit: UNIT, weeks: { 4 => 1, 3 => 1, 2 => 2, 1 => 1, 0 => 6 }, entered_in_last_week: 2 },
    { neighborhood: "Boqueirão", unit: SECOND_UNIT, weeks: { 0 => 3 }, entered_in_last_week: 0 },
    { neighborhood: "Batel", unit: SECOND_UNIT, weeks: { 0 => 2 }, entered_in_last_week: 0 }
  ].freeze
  # Dia dos primeiros sintomas dentro da semana (domingo = 0), em rodízio.
  SYMPTOM_DAYS = [ 0, 1, 2, 3, 4, 5 ].freeze

  # Pessoas novas (par validado + paciente), pelo índice: o das dengues vem
  # primeiro (0..15), depois o sarampo (16) e a consulta da rede de segurança (17).
  MEASLES_INDEX = 16
  SAFETY_NET_INDEX = 17
  BIRTHS = %w[1992-04-17 2017-09-03 1998-12-21 1973-06-30 1984-02-11 2010-07-25 1962-10-09 1995-03-28 2003-08-14 1978-01-05
              2018-05-19 1967-11-22 1989-09-09 2006-04-02 1981-07-13 1954-12-30 1996-10-26 1987-06-18].freeze
  GIVEN_F = %w[Mariana Luciana Fernanda Aline Camila Renata Bianca Simone Larissa].freeze
  GIVEN_M = %w[Carlos Rodrigo Marcelo Thiago Felipe Anderson Gustavo Leandro Wesley].freeze
  SURNAMES = %w[Oliveira Santos Pereira Ferreira Almeida Ribeiro Carvalho Gomes Martins Barbosa Rocha Dias Teixeira Moreira Cardoso
                Nogueira Pinto Araújo].freeze
  MOTHERS = [ "Maria Aparecida", "Ana Lúcia", "Terezinha", "Sônia Regina", "Rosa Maria", "Vera Lúcia", "Marlene", "Neide", "Cleusa",
              "Ivone", "Edna", "Zilda" ].freeze
  # Pessoa de Londrina, digitada na notificação manual (sem par, sem telefone).
  LONDRINA_PERSON = { "full_name" => "Eliane Cristina Brandão", "birth_date" => "1985-03-12", "sex" => "female",
                      "mother_name" => "Odete Brandão" }.freeze

  # Andamento: do estado inicial (notified) até o alvo, com o atraso de cada
  # passo depois da notificação (sobrescrito por caso em :steps).
  PATH = %w[notified investigating closed entered].freeze
  STEP_DELAY = { "investigating" => 28.hours, "closed" => 4.days, "entered" => 6.days }.freeze
  # Ficha da tuberculose (campos do Sinan; a pré-preenchida fica e estes entram).
  TUBERCULOSIS_FORM = { "pregnancy" => "6", "schooling" => "4", "residence_zone" => "1",
                        "residence_reference" => "Portão verde, perto da praça" }.freeze
  # A consulta da dengue suspeita (rede de segurança): CID-10 A90 só com a médica.
  DENGUE_VISIT = {
    "subjective" => "Febre alta há três dias, cefaleia, dor retro-orbital e mialgia. Nega sangramentos.",
    "objective" => "Febril (38,6 °C), exantema discreto, prova do laço negativa, sem sinais de alarme.",
    "assessment" => "Caso suspeito de dengue, sem sinais de alarme.",
    "plan" => "Hidratação oral, repouso e sintomáticos (sem anti-inflamatórios). Retorno se sinais de alarme.",
    "vitals" => { "systolic" => 118, "diastolic" => 76, "weight_kg" => "74.0", "height_cm" => 176 },
    "care_type" => 5, "conducts" => [ 1 ], "exam_requests" => [],
    "evaluated_problems" => [ { "terminology" => "cid10", "code" => "A90", "action" => "add" } ]
  }.freeze

  # Necessário para a prova do módulo 25: a rede de segurança da dengue lê o
  # CID-10 A90, que o recorte de dev do prontuário (ClinicalRecordCrew) não tem.
  DENGUE_CID10 = { "A90" => [ "Dengue [dengue clássico]", nil ] }.freeze
  # A release de dev que a traz (derivada da ativa, que ganha o A90 e fica como estava).
  DENGUE_TERMS_VERSION = "dev-a90".freeze

  class << self
    include ActiveSupport::Testing::TimeHelpers

    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("desligado (só Curitiba liga)") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] vigilância: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      # Pré-requisitos, antes de ligar.
      if Surveillance::Diseases.platform.empty?
        raise "semente da vigilância: lista nacional não carregada — rode o db:seed (plataforma) ou Surveillance::DiseaseList::Load"
      end

      units = [ UNIT, SECOND_UNIT, THIRD_UNIT ].to_h { |name| [ name, HealthUnit.find_by!(name: name) ] }
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: Surveillance::Gate::KEY, enabled: true, maintainer: maintainer)
      officer = officer!(password)
      local_disease!(officer)
      notifying!(units.values)

      clock = Time.current
      today = Time.zone.today
      last_week = Surveillance::EpiWeek.current(today).pred
      dengue_terms!
      safety_net = !ClinicalTerms.find("cid10", "A90").nil?
      warn "[seeds] vigilância: CID-10 A90 ausente na terminologia ativa — a possível da rede de segurança não foi semeada" unless safety_net

      citizens = (0..(safety_net ? SAFETY_NET_INDEX : MEASLES_INDEX)).to_h { |index| [ index, citizen!(slug, ddd, index) ] }
      scenario(today, last_week, clock).each { |entry| run_case!(slug, entry, citizens, officer, units, clock) }
      safety_net!(slug, units.fetch(UNIT), doctor, citizens.fetch(SAFETY_NET_INDEX)) if safety_net
      negative!(units.fetch(SECOND_UNIT), last_week, officer)

      summary(city, officer, last_week, safety_net)
    end

    # CPF da pessoa nova da semente (dígitos válidos, estáveis pela semente).
    def cpf_for(slug, index) = ScreeningCrew.send(:cpf_for, "#{slug}:surveillance:#{index}")

    # Celular da pessoa nova: +55 <ddd> 96666-NNNN.
    def phone_for(ddd, index) = format("+55%s#{PHONE_PREFIX}%04d", ddd, PHONE_BASE + index)

    # Nome, mãe, nascimento e sexo da pessoa nova (pares pelo índice).
    def person_of(index)
      female = index.even?
      given = (female ? GIVEN_F : GIVEN_M)[(index / 2) % GIVEN_F.size]
      first = SURNAMES[index % SURNAMES.size]
      second = SURNAMES[(index * 7 + 5) % SURNAMES.size]
      { name: "#{given} #{first} #{second}", mother: "#{MOTHERS[index % MOTHERS.size]} #{first}", birth: BIRTHS.fetch(index),
        sex: female ? "female" : "male" }
    end

    # As notificações do cenário, na ordem de gravação (público para o spec).
    # at: o instante em que nascem; suspected_on: o dia da suspeita; to: o
    # estado final (nil = fica notified).
    def scenario(today, last_week, clock)
      entries = dengue_entries(last_week, clock)
      entries << { who: MEASLES_INDEX, disease: "sarampo", unit: UNIT, neighborhood: "Centro", at: clock - 30.hours,
                   suspected_on: (clock - 30.hours).to_date, symptoms_on: (clock - 30.hours).to_date - 1, to: nil }
      entries << { who: :jose, disease: "tuberculose", unit: UNIT, at: day_at(today - 9), suspected_on: today - 9, symptoms_on: today - 30,
                   to: "investigating", form: TUBERCULOSIS_FORM }
      entries << { who: :osvaldo, disease: "hanseniase", unit: UNIT, at: day_at(today - 75), suspected_on: today - 75, symptoms_on: today - 120,
                   to: "entered", steps: { "closed" => 40.days, "entered" => 45.days } }
      entries << { who: :ana, disease: "sifilis_gestante", unit: UNIT, at: day_at(today - 25), suspected_on: today - 25, symptoms_on: nil,
                   to: "closed", steps: { "closed" => 12.days } }
      entries << { who: :benedito, disease: "tuberculose", unit: UNIT, at: day_at(today), suspected_on: today, symptoms_on: today - 11,
                   to: nil }
      entries << { who: :londrina, disease: "hepatites_virais", unit: UNIT, at: day_at(today), suspected_on: today, symptoms_on: today - 5,
                   to: nil, ibge: LONDRINA, new_patient: LONDRINA_PERSON }
      entries
    end

    private

    def guard_environment!
      raise "semente da vigilância: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    # Necessário para a prova do módulo 25: A90 na CID-10 ativa de dev. Só
    # republica o recorte de dev (versão "dev-*") com os códigos que ele já tem
    # mais o A90; uma release real ativa nunca é tocada (a ausência só avisa).
    # O CIAP-2 da dengue é vazio na lista (ciap2: []), então nada entra nele.
    def dengue_terms!
      DevTerminology.add_cid10!(codes: DENGUE_CID10, version: DENGUE_TERMS_VERSION, label: "semente da vigilância: CID-10 com A90")
    end

    def off(switch) = { switch: switch, notifications: 0, negatives: 0, users: [] }

    def day_at(day) = day.in_time_zone.change(hour: 9)

    # Os 16 casos de dengue, na ordem (o índice da pessoa é a posição).
    def dengue_entries(last_week, clock)
      index = -1
      serial = 0
      DENGUE.flat_map do |group|
        group[:weeks].sort_by { |ago, _| -ago }.flat_map do |ago, count|
          week = last_week - ago
          Array.new(count) do |k|
            symptoms_on = week.starts_on + SYMPTOM_DAYS[k % SYMPTOM_DAYS.size]
            # Boqueirão e Batel: sintomas em W, suspeita no domingo seguinte (a UBS Vila Esperança não tem caso em W).
            suspected_on = group[:unit] == UNIT ? symptoms_on + 1 : last_week.ends_on + 1
            entered = ago.positive? || k < group[:entered_in_last_week]
            index += 1
            serial += 1
            { who: index, disease: "dengue", unit: group[:unit], neighborhood: group[:neighborhood], at: day_at(suspected_on).change(hour: 10),
              suspected_on: suspected_on, symptoms_on: symptoms_on, to: entered ? "entered" : "investigating",
              official_number: format("%07d", 4_310_000 + serial) }
          end
        end
      end
    end

    # Vigilante: papel surveillance, TOTP fixo. Sem perfil de profissional: o
    # perfil exige o papel health_professional, que ela não tem.
    def officer!(password)
      user = User.find_or_initialize_by(email_address: "#{OFFICER[:email_prefix]}@curitiba.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: OFFICER[:role]) { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: OFFICER[:secret_env], default_secret: OFFICER[:default_secret])
      user.reload
    end

    def local_disease!(officer)
      return if LocalNotifiableDisease.exists?(code: LOCAL_DISEASE.fetch("code"))

      saved = Surveillance::SaveLocalDisease.call(attrs: LOCAL_DISEASE, by: officer)
      raise "semente da vigilância: doença local recusada (#{saved.reason} #{saved.details})" if saved.failure?
    end

    # As três unidades notificam (a UPA passa a notificar, como o admin faria).
    def notifying!(units)
      units.each { |unit| unit.update!(notifying: true) unless unit.notifying }
    end

    def at(time, clock, &) = travel_to([ time, clock - 1.second ].min, &)

    # Par validado (caminho real: RegisterPerson, Verify), pelo índice; o
    # bairro e o paciente vêm depois (patient_of_new), do caso que o usa.
    def citizen!(slug, ddd, index)
      person = person_of(index)
      registered = Citizens::RegisterPerson.call(phone: phone_for(ddd, index), cpf: cpf_for(slug, index),
                                                 profile: { birth_date: person[:birth], sex: person[:sex], gender_identity: nil })
      raise "semente da vigilância: pessoa #{index} recusada (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      unless citizen.verification_level_verified?
        reception = User.find_by!(email_address: "recepcao@#{slug}.demo")
        code = Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
        verified = Citizens::Verify.call(cpf: citizen.cpf, code: code, document_checked: true, by: reception, birth_date: person[:birth],
                                         sex: person[:sex], full_name: person[:name], mother_name: person[:mother])
        raise "semente da vigilância: validação #{index} recusada (#{verified.reason})" if verified.failure?
      end
      citizen.reload
    end

    def neighborhood!(name)
      Neighborhood.active_neighborhoods.named(name).first || raise("semente da vigilância: bairro #{name} ausente (rode Territory::Seed antes)")
    end

    # O bairro da pessoa nova (o do primeiro caso que a usa) e o paciente.
    def patient_of_new(citizen, neighborhood_name)
      if neighborhood_name && citizen.neighborhood_id != (id = neighborhood!(neighborhood_name).id)
        moved = Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: id)
        raise "semente da vigilância: bairro recusado (#{moved.reason})" if moved.failure?
      end
      resolved = Patients::Resolve.call(citizen.reload)
      raise "semente da vigilância: paciente recusado (#{resolved.reason})" if resolved.failure?

      resolved.payload.fetch(:patient)
    end

    # nil só para a pessoa de Londrina ainda não digitada.
    def patient_for(slug, entry, citizens)
      who = entry[:who]
      return patient_of_new(citizens.fetch(who), entry[:neighborhood]) if who.is_a?(Integer)
      return Patient.find_by(cpf: londrina_cpf(slug)) if who == :londrina
      return TerritoryRegistryCrew.patient_of(slug, who) || missing!(who, "TerritoryRegistryCrew") if who == :benedito

      Citizen.find_by(cpf: CareLinesCrew.cpf_for(slug, who))&.patient || missing!(who, "CareLinesCrew")
    end

    def missing!(who, crew) = raise("semente da vigilância: #{who} sem paciente — rode o #{crew} (db:seed) antes")

    def londrina_cpf(slug) = ScreeningCrew.send(:cpf_for, "#{slug}:surveillance:londrina")

    def run_case!(slug, entry, citizens, officer, units, clock)
      patient = patient_for(slug, entry, citizens)
      notification = patient && DiseaseNotification.where(patient_id: patient.id, disease_code: entry[:disease]).order(:created_at, :id).last
      notification ||= create!(slug, entry, patient, officer, units, clock)
      advance!(notification, entry, officer, clock)
    end

    def create!(slug, entry, patient, officer, units, clock)
      params = { "disease_code" => entry[:disease], "suspected_on" => entry[:suspected_on].iso8601, "unit_id" => units.fetch(entry[:unit]).id }
      params["symptoms_on"] = entry[:symptoms_on].iso8601 if entry[:symptoms_on]
      params.merge!("resident_elsewhere" => true, "residence_ibge" => entry[:ibge]) if entry[:ibge]
      params.merge!(patient ? { "patient_id" => patient.id } : { "new_patient" => entry[:new_patient].merge("cpf" => londrina_cpf(slug)),
                                                                   "duplicates_reviewed" => false })
      created = at(entry[:at], clock) { Surveillance::CreateManual.call(params: params, by: officer) }
      raise "semente da vigilância: notificação #{entry[:disease]} recusada (#{created.reason} #{created.details})" if created.failure?

      created.payload.fetch(:notification)
    end

    # Retoma do estado em que a notificação está até o alvo.
    def advance!(notification, entry, officer, clock)
      target = PATH.index(entry[:to] || "notified")
      delays = STEP_DELAY.merge(entry[:steps] || {})
      while (position = PATH.index(notification.reload.status)) < target
        to = PATH.fetch(position + 1)
        extra = case to
                when "closed" then { classification: "confirmed" }
                when "entered" then { official_number: entry[:official_number] || format("%07d", 4_300_000 + Zlib.crc32(notification.id) % 10_000) }
                else {}
                end
        moved = at(entry[:at] + delays.fetch(to), clock) do
          Surveillance::Transition.call(notification: notification, to: to, version: notification.version, by: officer, **extra)
        end
        raise "semente da vigilância: andamento #{to} recusado (#{moved.reason})" if moved.failure?
      end
      fill_form!(notification, entry, officer, clock)
    end

    def fill_form!(notification, entry, officer, clock)
      return unless entry[:form]

      notification.reload
      return unless notification.status == "investigating"
      return if entry[:form].all? { |key, value| notification.form.to_h[key] == value }

      saved = at(entry[:at] + 2.days, clock) do
        Surveillance::SaveForm.call(notification: notification, form: notification.form.to_h.merge(entry[:form]),
                                    version: notification.version, by: officer)
      end
      raise "semente da vigilância: ficha recusada (#{saved.reason} #{saved.details})" if saved.failure?
    end

    # Consulta finalizada da médica com A90; a rede de segurança roda aqui, na
    # hora (em dev o worker também a enfileira; a duplicidade o silencia).
    # Só ao criar a consulta: com a possível descartada depois, uma nova rodada
    # da semente não a recria.
    def safety_net!(slug, unit, doctor, citizen)
      patient = patient_of_new(citizen, "Santa Felicidade")
      return if patient.consultations.finalized_consultations.exists?

      attendance = ClinicalRecordCrew.send(:checked_in!, slug, unit, citizen, "vigilancia-#{citizen.id[0, 8]}")
      called = Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: doctor)
      raise "semente da vigilância: chamada recusada (#{called.reason})" if called.failure?

      started = Consultations::Start.call(attendance: attendance.reload, by: doctor)
      raise "semente da vigilância: consulta recusada (#{started.reason})" if started.failure?

      consultation = started.payload.fetch(:consultation)
      saved = Consultations::SaveDraft.call(consultation: consultation, params: DENGUE_VISIT, by: doctor)
      raise "semente da vigilância: rascunho recusado (#{saved.reason} #{saved.details})" if saved.failure?

      finalized = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
      raise "semente da vigilância: finalização recusada (#{finalized.reason} #{finalized.details})" if finalized.failure?

      Surveillance::SafetyNet.call(consultation: consultation.reload)
    end

    # Negativa da UBS Vila Esperança na semana W (sem caso nela).
    def negative!(unit, week, officer)
      return if WeeklyNegativeReport.exists?(health_unit_id: unit.id, week: week.to_s)

      recorded = Surveillance::RecordNegative.call(unit_id: unit.id, week: week.to_s, by: officer)
      raise "semente da vigilância: negativa recusada (#{recorded.reason})" if recorded.failure?
    end

    def summary(city, officer, last_week, safety_net)
      { switch: Surveillance::Gate.usable?(city) ? "ligado (surveillance)" : "ligado, não utilizável",
        week: last_week.to_s, notifications: DiseaseNotification.count, negatives: WeeklyNegativeReport.count,
        queue: Surveillance::Queue.counts, local_disease: LOCAL_DISEASE.fetch("code"),
        safety_net: safety_net ? "possível pela consulta com A90" : "sem A90 na CID-10 ativa (release real): não semeada",
        users: [ { email: officer.email_address, role: OFFICER[:role], otpauth_uri: SignatureCrew.otpauth_uri(officer) } ] }
    end
  end
end
