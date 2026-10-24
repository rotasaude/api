require "active_support/testing/time_helpers"
require_relative "signature_crew"
require_relative "screening_crew"
require_relative "care_lines_crew"

# Semente de dev do módulo 24a (ADR 0042), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, territory_registry LIGADO pelo
# mantenedor de dev; na UBS Jardim das Flores, na equipe do CareLinesCrew
# (ESF JARDIM DAS FLORES — em dev, a equipe que o ExamCrew criou e o
# CareLinesCrew reaproveitou, por isso o nome é procurado primeiro e, sem
# ele, vale a mesma regra do CareLinesCrew: a única equipe ativa da UBS), a
# ACS Rosana Aparecida Moreira (acs@, CBO 515105, sem conselho, CNS válido),
# as microáreas 01 "Jardim das Flores — norte" (dela) e 02 "Jardim das Flores
# — sul" (descoberta: a enfermeira da equipe cadastra), quatro domicílios em
# bairros cobertos só pela UBS (CEP 82…, como o endereço da UBS) e os
# cadastros da tabela abaixo. Tudo pelos comandos do app (SaveMicroArea,
# SaveHousehold, SaveFamily, SaveRegistration, ExitRegistration), com as
# mesmas validações da tela. As datas passadas vêm de travel_to em volta do
# comando: a versão, o cabeçalho (registered_at) e a ficha nascem no mesmo
# instante, como teriam nascido naquele dia. Idempotente. Roda depois do
# CareLinesCrew. Não liga ledi_export (como o LediCrew): com a exportação
# utilizável, as fichas nascem na gravação e a da pessoa em situação de rua
# fica "não gerada" (patient_without_identifier); sem ela, nenhuma ficha.
#
# Tabela da prova (RegistryStatus da equipe; a contagem sai dela):
#
#   pessoa                         origem           onde                  gravado há        situação
#   José Carlos Pereira            CareLinesCrew    01 R. das Acácias     4 meses           valid
#   Osvaldo Ribeiro Nunes          CareLinesCrew    fora de área          7 meses           valid
#   Daniela Cristina Moraes        digitada, CPF    02 R. Pedro Gusso     14 meses          valid
#   Lorena Moraes Batista          digitada, CNS    02 R. Pedro Gusso     10 dias           valid (sem CPF, justificativa 3)
#   Ana Beatriz Souza              CareLinesCrew    01 R. Ipê Amarelo     24 meses − 40 d   due_soon (vence em 40 dias)
#   Sebastião Alves Rocha          CareLinesCrew    01 R. Ipê Amarelo     25 meses          expired
#   Benedito Carlos da Silva       digitado, nada   fora de área (rua)    20 dias           missing_identifier (ficha não gerada)
#   Cláudio Roberto Batista        digitado, CPF    02 R. Pedro Gusso     14 meses          refused (lista; fora da contagem)
#   Geraldo Antunes Moraes         digitado, CPF    02 R. Pedro Gusso     14 meses          exited (óbito há 20 dias)
#   Tatiane Ferreira Lopes         digitada, CPF    01 R. Ipê Amarelo     24 meses − 40 d   exited (mudou há 60 dias)
#   Miguel Oliveira Santos         CareLinesCrew    (paciente, sem cadastro)                missing
#   Maria, Rafael, Juliana         CareLinesCrew    (pares validados, sem paciente)         missing
#   Luiz/Luíza (ClinicalRecordCrew)                 (paciente da médica da equipe)          missing
#
#   contagem (só este elenco): valid 4, due_soon 1, expired 1, missing 5, missing_identifier 1.
#   Em dev, outras sementes podem pôr mais gente na população (missing).
#
# Maria, Rafael e Juliana ficam sem cadastro de propósito: cadastrar cria o
# paciente, e as provas 5–7 do módulo 23 contam com eles sem paciente. A mãe
# da recém-nascida é a Daniela (a Ana está grávida de 10 semanas na semente
# do 23). Antônio (CareLinesCrew) não tem bairro: não é da população da equipe.
class TerritoryRegistryCrew
  UNIT = CareLinesCrew::UNIT
  TEAM_NAME = CareLinesCrew::TEAM_NAME
  DEV_MAINTAINER = "dev@local".freeze
  # Telefones +55 <ddd> 96666-NNNN (Valores fixados, item 5). O CampaignCrew
  # também usa 96666, a partir de 0001: esta semente começa em 2400.
  PHONE_PREFIX = "96666".freeze
  PHONE_BASE = 2400
  ACS = { email_prefix: "acs", professional_name: "Rosana Aparecida Moreira", cbo: TerritoryRegistry::Catalog::ACS_CBO, phone: 0,
          secret_env: "DEV_ACS_OTP_SECRET", default_secret: "ACSCADASTROTERRITORIALSEMENTE234", years_in_team: 6 }.freeze
  NURSE = "enfermeira".freeze
  MICRO_AREAS = [ { code: "01", name: "Jardim das Flores — norte", acs: true },
                  { code: "02", name: "Jardim das Flores — sul", acs: false } ].freeze
  # As microáreas existem antes do domicílio mais antigo (25 meses).
  MICRO_AREAS_MONTHS_AGO = 30

  LIVING = { "localizacao" => 83, "situacao_moradia_posse_terra" => 75, "tipo_acesso_domicilio" => 89, "tipo_domicilio" => 85,
             "material_predominante_paredes_ext_domicilio" => 109, "abastecimento_agua" => 117, "agua_consumo_domicilio" => 219,
             "forma_escoamento_banheiro" => 122, "destino_lixo" => 93, "st_disponibilidade_energia_eletrica" => true,
             "tipo_origem_energia_eletrica" => 230 }.freeze

  # Domicílios (tipo 01), na ordem de gravação. at: meses/dias antes de hoje
  # (expires_in: o dia que faz o cadastro vencer em N dias, menos `days`).
  # family: o responsável (chave de PEOPLE), membros, renda, desde.
  HOUSEHOLDS = {
    acacias: { area: "01", at: { months: 4, days: 2 }, neighborhood: "Butiatuvinha", phone_of: :jose,
               address: { "zip" => "82400210", "street_type" => "081", "street" => "Rua das Acácias", "number" => "245",
                          "reference" => "Portão verde, perto da praça" },
               living: LIVING.merge("nu_comodos" => 5, "nu_moradores" => 2, "st_animais_no_domicilio" => true,
                                    "animais_no_domicilio" => [ 129 ], "quantos_animais_no_domicilio" => 1),
               family: { responsible: :jose, members: 2, income: "4", since: "2009-03" } },
    ipe_1180: { area: "01", at: { months: 25, days: 1 }, neighborhood: "Butiatuvinha", phone_of: :sebastiao,
                address: { "zip" => "82400318", "street_type" => "081", "street" => "Rua Ipê Amarelo", "number" => "1180" },
                living: LIVING.merge("material_predominante_paredes_ext_domicilio" => 113, "nu_comodos" => 4, "nu_moradores" => 2,
                                     "st_animais_no_domicilio" => false),
                family: { responsible: :sebastiao, members: 2, income: "3", since: "1988-06" } },
    ipe_1236: { area: "01", at: { expires_in: 40, days: 1 }, neighborhood: "Butiatuvinha", phone_of: :ana,
                address: { "zip" => "82400326", "street_type" => "081", "street" => "Rua Ipê Amarelo", "number" => "1236",
                           "complement" => "Apto 12" },
                living: LIVING.merge("situacao_moradia_posse_terra" => 77, "tipo_domicilio" => 86, "nu_comodos" => 3, "nu_moradores" => 3,
                                     "st_animais_no_domicilio" => true, "animais_no_domicilio" => [ 128 ], "quantos_animais_no_domicilio" => 1),
                family: { responsible: :ana, members: 2, income: "4", since: "2023-02" } },
    pedro_gusso: { area: "02", at: { months: 14, days: 1 }, neighborhood: "São João", phone_of: :daniela,
                   address: { "zip" => "82030150", "street_type" => "081", "street" => "Rua Pedro Gusso", "number" => "780",
                              "reference" => "Em frente à mercearia" },
                   living: LIVING.merge("situacao_moradia_posse_terra" => 76, "nu_comodos" => 6, "nu_moradores" => 3,
                                        "st_animais_no_domicilio" => false),
                   family: { responsible: :daniela, members: 3, income: "2", since: "2019-08" } }
  }.freeze

  NO_SEXUAL_INFO = { "status_deseja_informar_orientacao_sexual" => false, "status_deseja_informar_identidade_genero" => false }.freeze
  OFF_STREET = { "status_situacao_rua" => false }.freeze

  # Cadastros, na ordem de gravação. from: :care_lines (o paciente já existe)
  # ou new_patient (digitado no cadastro; CPF/CNS gerados pela semente).
  # household nil = fora de área (pela equipe). member: entra na família do
  # domicílio. father nil = desconhece o nome do pai. exit: saída depois.
  PEOPLE = {
    jose: { from: :care_lines, household: :acacias, responsible: true, at: { months: 4 }, race: "03", phone: 1,
            birth_city: "4106902", father: "Joaquim Pereira",
            sociodemographic: { "grau_instrucao_cidadao" => 56, "situacao_mercado_trabalho_cidadao" => 67 },
            health_conditions: { "status_tem_diabetes" => true, "status_tem_hipertensao_arterial" => true, "status_eh_fumante" => false } },
    sebastiao: { from: :care_lines, household: :ipe_1180, responsible: true, at: { months: 25 }, race: "01", phone: 2,
                 birth_city: "4119905", father: nil,
                 sociodemographic: { "grau_instrucao_cidadao" => 54, "situacao_mercado_trabalho_cidadao" => 71 },
                 health_conditions: { "status_tem_hipertensao_arterial" => true, "status_eh_fumante" => false } },
    ana: { from: :care_lines, household: :ipe_1236, responsible: true, at: { expires_in: 40 }, race: "02", phone: 3,
           birth_city: "4106902", father: "Marcos Antônio Souza",
           sociodemographic: { "grau_instrucao_cidadao" => 60, "situacao_mercado_trabalho_cidadao" => 67 },
           health_conditions: { "status_eh_fumante" => false } },
    tatiane: { new_patient: { "full_name" => "Tatiane Ferreira Lopes", "birth_date" => "1997-12-03", "sex" => "female",
                              "mother_name" => "Rosemeire Ferreira Lopes" },
               household: :ipe_1236, at: { expires_in: 40, minutes: 30 }, race: "03", phone: 4, birth_city: "4113700", father: nil,
               sociodemographic: { "grau_instrucao_cidadao" => 63, "situacao_mercado_trabalho_cidadao" => 68,
                                   "relacao_parentesco_cidadao" => 146 },
               health_conditions: {}, exit: { reason: "moved", days_ago: 60 } },
    daniela: { new_patient: { "full_name" => "Daniela Cristina Moraes", "birth_date" => "1994-02-11", "sex" => "female",
                              "mother_name" => "Neusa Aparecida Moraes" },
               household: :pedro_gusso, responsible: true, at: { months: 14 }, race: "01", phone: 5, birth_city: "4106902",
               father: "Geraldo Antunes Moraes",
               sociodemographic: { "grau_instrucao_cidadao" => 60, "situacao_mercado_trabalho_cidadao" => 69 },
               health_conditions: { "status_eh_fumante" => false } },
    geraldo: { new_patient: { "full_name" => "Geraldo Antunes Moraes", "birth_date" => "1946-05-19", "sex" => "male",
                              "mother_name" => "Olinda Antunes Moraes" },
               household: :pedro_gusso, member: true, at: { months: 14, minutes: 40 }, race: "01", phone: 6, birth_city: "4110706",
               father: nil,
               sociodemographic: { "grau_instrucao_cidadao" => 54, "situacao_mercado_trabalho_cidadao" => 71,
                                   "relacao_parentesco_cidadao" => 141 },
               health_conditions: { "status_tem_hipertensao_arterial" => true, "status_teve_doenca_cardiaca" => true,
                                    "doenca_cardiaca" => [ 24 ], "status_esta_domiciliado" => true },
               exit: { reason: "death", days_ago: 15, death_days_ago: 20, certificate: "312458769" } },
    claudio: { new_patient: { "full_name" => "Cláudio Roberto Batista", "birth_date" => "1990-09-04", "sex" => "male",
                              "mother_name" => "Marlene Batista" },
               household: :pedro_gusso, refused: true, at: { months: 14, minutes: 50 } },
    osvaldo: { from: :care_lines, household: nil, at: { months: 7 }, race: "01", phone: 7, birth_city: "4113205", father: nil,
               sociodemographic: { "grau_instrucao_cidadao" => 55, "situacao_mercado_trabalho_cidadao" => 71 },
               health_conditions: { "status_tem_hipertensao_arterial" => true, "status_teve_avc_derrame" => false } },
    lorena: { new_patient: { "full_name" => "Lorena Moraes Batista", "days_old" => 45, "sex" => "female",
                             "mother_name" => "Daniela Cristina Moraes", "no_cpf_reason" => "3", "cns" => true },
              household: :pedro_gusso, member: true, at: { days: 10 }, race: "01", phone: 5, birth_city: "4106902",
              father: "Cláudio Roberto Batista", identification: { "dnv" => "52381946027" },
              sociodemographic: { "relacao_parentesco_cidadao" => 138, "responsavel_por_crianca" => [ 1 ] },
              health_conditions: {} },
    benedito: { new_patient: { "full_name" => "Benedito Carlos da Silva", "birth_date" => "1972-07-22", "sex" => "male",
                               "no_cpf_reason" => "5" },
                household: nil, at: { days: 20 }, race: "02", phone: 8, birth_city: "2111300", father: nil,
                sociodemographic: { "grau_instrucao_cidadao" => 55, "situacao_mercado_trabalho_cidadao" => 70 },
                health_conditions: { "status_eh_fumante" => true, "status_eh_dependente_alcool" => false },
                street_situation: { "status_situacao_rua" => true, "tempo_situacao_rua" => 19, "status_recebe_beneficio" => false,
                                    "status_possui_referencia_familiar" => false, "status_visita_familiar_frequentemente" => false,
                                    "quantidade_alimentacoes_ao_dia_situacao_rua" => 35, "origem_alimento_situacao_rua" => [ 37, 38 ],
                                    "status_acompanhado_por_outra_instituicao" => true, "outra_instituicao_que_acompanha" => "Centro POP",
                                    "status_tem_acesso_higiene_pessoal_situacao_rua" => true,
                                    "higiene_pessoal_situacao_rua" => [ 42, 43 ] } }
  }.freeze

  class << self
    include ActiveSupport::Testing::TimeHelpers

    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("desligado (só Curitiba liga)") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] cadastro territorial: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      # Pré-requisitos, antes de ligar.
      profile = CityProfile.current
      unless profile&.uf.present? && profile.ibge_code.present?
        raise "semente do cadastro territorial: perfil da cidade sem UF/IBGE — rode o db:seed (city_profile)"
      end
      unit = HealthUnit.find_by!(name: UNIT)
      team = team_of(unit)
      raise "semente do cadastro territorial: sem equipe ativa na #{UNIT} — rode o CareLinesCrew (db:seed) antes" unless team

      known = PEOPLE.select { |_, person| person[:from] == :care_lines }.keys
      missing = known.reject { |key| patient_of(slug, key) }
      raise "semente do cadastro territorial: #{missing.join(', ')} sem paciente — rode o CareLinesCrew (db:seed) antes" if missing.any?

      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: TerritoryRegistry::Gate::KEY, enabled: true, maintainer: maintainer)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      acs = acs!(slug, ddd, password, admin, unit, team)
      staff = { "01" => acs, "02" => User.find_by!(email_address: "#{NURSE}@#{slug}.demo") }
      areas = micro_areas!(team, acs, admin)

      HOUSEHOLDS.each do |key, data|
        household = household!(slug, ddd, key, data, areas.fetch(data[:area]), staff.fetch(data[:area]))
        PEOPLE.select { |_, person| person[:household] == key }.each do |person_key, person|
          register!(slug, ddd, person_key, person, staff.fetch(data[:area]), household: household)
        end
      end
      PEOPLE.select { |_, person| person[:household].nil? }.each { |key, person| register!(slug, ddd, key, person, acs, team: team) }
      PEOPLE.select { |_, person| person[:exit] }.each do |key, person|
        by = person[:household] ? staff.fetch(HOUSEHOLDS.fetch(person[:household])[:area]) : acs
        exit!(slug, key, person[:exit], by)
      end

      summary(city, team, areas, acs)
    end

    # O paciente da pessoa da semente (nil se ainda não existe).
    def patient_of(slug, key)
      person = PEOPLE.fetch(key)
      return Citizen.find_by(cpf: CareLinesCrew.cpf_for(slug, key))&.patient if person[:from] == :care_lines

      typed = person.fetch(:new_patient)
      if typed["no_cpf_reason"].nil? then Patient.find_by(cpf: cpf_for(slug, key))
      elsif typed["cns"] then Patient.find_by(cns: cns_for(slug, key))
      else Patient.find_by(match_key: Patients::MatchKey.for(typed["full_name"], typed["birth_date"]))
      end
    end

    # CPF/CNS das pessoas digitadas (dígitos válidos, estáveis pela semente).
    def cpf_for(slug, key) = ScreeningCrew.send(:cpf_for, "#{slug}:territory_registry:#{key}")
    def cns_for(slug, key) = Professionals::Cns.generate("#{slug}:territory_registry:#{key}")

    # Celular sem +55 (como na ficha): <ddd>96666NNNN.
    def phone_for(ddd, index) = format("%s#{PHONE_PREFIX}%04d", ddd, PHONE_BASE + index)

    private

    def guard_environment!
      raise "semente do cadastro territorial: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, team: nil, micro_areas: [], households: 0, registrations: 0, status: nil, fichas: nil, users: [] }

    # A equipe do CareLinesCrew: pelo nome e, sem ele (em dev, a do ExamCrew,
    # reaproveitada pelo CareLinesCrew), a única equipe ativa da UBS.
    def team_of(unit)
      named = HealthTeam.find_by(health_unit: unit, name: TEAM_NAME, active: true)
      return named if named

      teams = HealthTeam.where(health_unit: unit, active: true).order(:created_at).to_a
      warn "[seeds] cadastro territorial: #{teams.size} equipes ativas na #{UNIT} — usando a primeira" if teams.size > 1
      teams.first
    end

    # Ligado não basta: o interruptor exige o prontuário utilizável.
    def switch_label(city)
      return "ligado (territory_registry)" if TerritoryRegistry::Gate.usable?(city)

      "ligado, não utilizável (falta: #{Platform::Features.missing(city, TerritoryRegistry::Gate::KEY).join(', ')})"
    end

    def summary(city, team, areas, acs)
      households = Household.where(micro_area_id: areas.values.map(&:id)).count
      exportable = Ledi::IndividualRegistrationFicha.exportable?(city)
      { switch: switch_label(city), team: team.name,
        micro_areas: areas.values.map { |a| "#{a.code} #{a.name} (#{a.acs_professional ? "ACS #{a.acs_professional.professional_name}" : 'sem ACS'})" },
        households: households, registrations: IndividualRegistration.where(team_id: team.id).count,
        status: TerritoryRegistry::RegistryStatus.count(team: team, today: Time.zone.today),
        fichas: exportable ? "geradas (ledi_export utilizável)" : "não geradas (ledi_export desligado ou não utilizável)",
        users: [ { email: acs.email_address, role: "health_professional (ACS #{ACS[:cbo]})", otpauth_uri: SignatureCrew.otpauth_uri(acs) } ] }
    end

    # Instante "N meses/dias atrás" no fuso da cidade. expires_in: o dia em
    # que o cadastro gravado vence em N dias (24 meses depois).
    def moment(at, hour:)
      today = Time.zone.today
      day = at[:expires_in] ? (today + at[:expires_in]) << TerritoryRegistry::Validity::MONTHS : today << at.fetch(:months, 0)
      (day - at.fetch(:days, 0)).in_time_zone.change(hour: hour) + at.fetch(:minutes, 0).minutes
    end

    # Grava no instante `time` (a versão, o cabeçalho e a ficha), pelo comando.
    def at(time, &) = travel_to(time, &)

    def acs!(slug, ddd, password, admin, unit, team)
      user = User.find_or_initialize_by(email_address: "#{ACS[:email_prefix]}@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: "health_professional") { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: ACS[:secret_env], default_secret: ACS[:default_secret])
      professional = user.professional || acs_profile!(slug, ddd, user, admin)
      unless professional.links.active.exists?(health_unit: unit, cbo_code: ACS[:cbo])
        opened = Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: ACS[:cbo], by: admin)
        raise "semente do cadastro territorial: vínculo da ACS recusado (#{opened.reason})" if opened.failure?
      end
      unless HealthTeamMember.active.exists?(professional: professional, health_team: team)
        HealthTeamMember.create!(professional: professional, health_team: team, cbo_code: ACS[:cbo],
                                 started_on: Time.zone.today << (12 * ACS[:years_in_team]))
      end
      user.reload
    end

    # Perfil de campo: sem conselho, UF nem registro; CNS e CPF válidos.
    def acs_profile!(slug, ddd, user, admin)
      seed = "#{slug}:#{ACS[:email_prefix]}"
      attrs = { professional_name: ACS[:professional_name], cns: Professionals::Cns.generate(seed),
                cpf: ScreeningCrew.send(:cpf_for, seed), phone: phone_for(ddd, ACS[:phone]) }
      result = Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin)
      raise "semente do cadastro territorial: perfil da ACS recusado (#{result.reason} #{result.details})" if result.failure?

      result.payload[:professional]
    end

    # { "01" => MicroArea, "02" => MicroArea } pelo SaveMicroArea (em nome do admin).
    def micro_areas!(team, acs, admin)
      MICRO_AREAS.to_h do |data|
        area = MicroArea.find_by(team: team, code: data[:code])
        unless area
          params = { "team_id" => team.id, "code" => data[:code], "name" => data[:name],
                     "acs_professional_id" => (acs.professional.id if data[:acs]) }
          saved = at(moment({ months: MICRO_AREAS_MONTHS_AGO }, hour: 8)) { TerritoryRegistry::SaveMicroArea.call(params: params, by: admin) }
          raise "semente do cadastro territorial: microárea #{data[:code]} recusada (#{saved.reason})" if saved.failure?

          area = saved.payload[:micro_area]
        end
        [ data[:code], area ]
      end
    end

    # Domicílio (achado pelo CEP e número) e a família do responsável, se ele
    # já é paciente; o responsável digitado ganha a família depois do cadastro.
    def household!(slug, ddd, key, data, area, by)
      address = data[:address]
      household = Household.where(micro_area: area).detect do |h|
        h.latest_version.address.values_at("zip", "number") == address.values_at("zip", "number")
      end
      unless household
        neighborhood = Neighborhood.active_neighborhoods.named(data[:neighborhood]).first
        params = { "micro_area_id" => area.id, "property_type" => "1", "refused" => false,
                   "contact_phone" => phone_for(ddd, PEOPLE.fetch(data[:phone_of])[:phone]),
                   "address" => address.merge("neighborhood_id" => neighborhood&.id, "district" => (data[:neighborhood] unless neighborhood)),
                   "living_conditions" => data[:living] }
        saved = at(moment(data[:at], hour: 9)) { TerritoryRegistry::SaveHousehold.call(params: params, by: by) }
        raise "semente do cadastro territorial: domicílio #{key} recusado (#{saved.reason} #{saved.details})" if saved.failure?

        household = saved.payload[:household]
      end
      responsible = patient_of(slug, data[:family][:responsible])
      family!(household, data, responsible, by, moment(data[:at], hour: 9) + 15.minutes) if responsible
      household.reload
    end

    def family!(household, data, responsible, by, time)
      return if Family.exists?(household_id: household.id, responsible_patient_id: responsible.id)

      family = data[:family]
      params = { "responsible" => { "patient_id" => responsible.id }, "members_count" => family[:members],
                 "income_band" => family[:income], "living_since" => family[:since], "version" => household.reload.version }
      saved = at(time) { TerritoryRegistry::SaveFamily.call(household: household, params: params, by: by) }
      raise "semente do cadastro territorial: família recusada (#{saved.reason} #{saved.details})" if saved.failure?
    end

    # Cadastro pelo SaveRegistration (POST); o responsável digitado ganha a
    # família logo depois e o cadastro aponta para ela (PATCH).
    def register!(slug, ddd, key, person, by, household: nil, team: nil)
      patient = patient_of(slug, key)
      registration = patient && IndividualRegistration.find_by(patient_id: patient.id)
      time = moment(person[:at], hour: 10)
      unless registration
        params = registration_params(slug, ddd, key, person, patient, household: household, team: team)
        saved = at(time) { TerritoryRegistry::SaveRegistration.call(params: params, by: by) }
        raise "semente do cadastro territorial: cadastro #{key} recusado (#{saved.reason} #{saved.details})" if saved.failure?

        registration = saved.payload[:registration]
      end
      link_family!(slug, ddd, key, person, registration, household, by, time) if person[:responsible] && household
    end

    def link_family!(slug, ddd, key, person, registration, household, by, time)
      return if registration.family_id

      data = HOUSEHOLDS.fetch(person[:household])
      family!(household, data, registration.patient, by, time + 15.minutes)
      params = registration_params(slug, ddd, key, person, registration.patient, household: household.reload)
                 .merge("version" => registration.version).except("patient_id")
      saved = at(time + 20.minutes) { TerritoryRegistry::SaveRegistration.call(params: params, by: by, registration: registration) }
      raise "semente do cadastro territorial: família do cadastro #{key} recusada (#{saved.reason} #{saved.details})" if saved.failure?
    end

    def registration_params(slug, ddd, key, person, patient, household:, team: nil)
      params = { "refused" => person[:refused] == true, "is_responsible" => person[:responsible] == true }
      if household
        params["household_id"] = household.id
        family = Family.active_families.where(household_id: household.id).order(:created_at).first
        params["family_id"] = family.id if family && (person[:member] || (person[:responsible] && family.responsible_patient_id == patient&.id))
      else
        params["team_id"] = team.id
      end
      params.merge!(patient ? { "patient_id" => patient.id } : { "new_patient" => new_patient(slug, key, person[:new_patient]) })
      return params if person[:refused] # recusa: só a pessoa e o termo

      mother = patient ? patient.mother_name.present? : person[:new_patient]["mother_name"].present?
      params.merge(
        "patient_demographics" => { "race_color" => person[:race] },
        "identification" => identification(ddd, person, mother),
        "sociodemographic" => NO_SEXUAL_INFO.merge("status_tem_alguma_deficiencia" => false).merge(person[:sociodemographic].compact),
        "health_conditions" => person[:health_conditions],
        "street_situation" => person[:street_situation] || OFF_STREET
      )
    end

    def identification(ddd, person, mother)
      values = { "nacionalidade_cidadao" => 1, "codigo_ibge_municipio_nascimento" => person[:birth_city],
                 "telefone_celular" => phone_for(ddd, person[:phone]) }
      values.merge!(person[:father] ? { "nome_pai_cidadao" => person[:father] } : { "desconhece_nome_pai" => true })
      values["desconhece_nome_mae"] = true unless mother
      values.merge(person[:identification] || {})
    end

    def new_patient(slug, key, typed)
      attrs = typed.except("days_old", "cns")
      attrs["birth_date"] = (Time.zone.today - typed["days_old"]).iso8601 if typed["days_old"]
      attrs["cpf"] = cpf_for(slug, key) unless typed["no_cpf_reason"]
      attrs["cns"] = cns_for(slug, key) if typed["cns"]
      attrs
    end

    def exit!(slug, key, data, by)
      registration = IndividualRegistration.find_by!(patient_id: patient_of(slug, key).id)
      return if registration.exited?

      today = Time.zone.today
      params = { "reason" => data[:reason], "on" => (today - data[:days_ago]).iso8601 }
      params.merge!("death_on" => (today - data[:death_days_ago]).iso8601, "death_certificate" => data[:certificate]) if data[:reason] == "death"
      saved = at((today - data[:days_ago]).in_time_zone.change(hour: 11)) do
        TerritoryRegistry::ExitRegistration.call(registration: registration, params: params, by: by)
      end
      raise "semente do cadastro territorial: saída #{key} recusada (#{saved.reason} #{saved.details})" if saved.failure?
    end
  end
end
