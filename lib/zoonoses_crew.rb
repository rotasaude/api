require_relative "signature_crew"
require_relative "screening_crew"
require_relative "care_lines_crew"
require_relative "territory_registry_crew"
require_relative "home_visit_crew"
require_relative "vector_control_crew"

# Semente de dev do módulo 35b (ADR 0054; contrato §17, Q30), para a prova no
# navegador e no app. Dev é fictício mas imita o real: em Curitiba (só nela),
# `zoonoses` LIGADO pelo mantenedor de dev, sobre a UVZ, o local de insumos, a
# coordenação (endemias@), o almoxarife e o ACE (ace@) do VectorControlCrew, e
# a ouvidoria do OmbudsmanCrew. Tudo pelos comandos do módulo, com as mesmas
# validações da tela; o "hoje" é Time.zone.today da cidade.
#
#   conta                          papel          o quê
#   veterinaria@curitiba.demo      zoonoses_team  só o papel + o perfil (CBO 223305,
#                                                 CRMV-PR, número de formato válido) e o
#                                                 vínculo na "UVZ Curitiba" (Q30: sem
#                                                 health_professional)
#   zoonoses@curitiba.demo         zoonoses_team  a equipe do centro (sem perfil)
#   endemias@curitiba.demo         endemic_coordinator (já do 35a): a coordenação
#
#   roteiro (§17)                         dado semeado
#   2  animal por microchip, histórico    oito animais: cinco com tutor, um comunitário e
#                                         dois recolhidos no canil; três com microchip
#   3  posto fixo sem cadastro            campanha open "Campanha antirrábica 2026", quatro
#                                         semanas de doses (casa a casa, posto fixo com e
#                                         sem animal)
#   4  demanda de escorpião               manifestação por telefone, encaminhada sozinha à
#                                         UVZ (a demanda nasce no encaminhamento)
#   5  observação aberta                  notificação acidente_animal_raiva com o bloco do
#                                         animal; o OpenObservationJob roda inline
#   6  inquérito, DPP reagente pendente   inquérito de amostra open, três coletas (um DPP
#                                         reagente, ELISA pendente), uma coleira vencendo
#   7  canil sem eutanásia                duas estadas abertas; nenhuma eutanásia
#
# Idempotente: cada peça é achada por chave estável (nome, e-mail, microchip,
# campanha, notificação) antes de criar; semear de novo não grava nada. Roda
# depois do VectorControlCrew (UVZ, local, almoxarife, coordenação e ACE), do
# OmbudsmanCrew e do SurveillanceCrew.
class ZoonosesCrew
  UNIT = CareLinesCrew::UNIT
  TEAM_NAME = CareLinesCrew::TEAM_NAME
  DEV_MAINTAINER = "dev@local".freeze
  UVZ = VectorControlCrew::UVZ
  AREAS = VectorControlCrew::AREAS
  OFFICER = VectorControlCrew::OFFICER
  ADMIN = "admin".freeze
  OMBUDSMAN_STAFF = "ouvidoria@curitiba.dev".freeze
  # Telefone no bloco do 24a (+55 <ddd> 96666-24NN), depois do ACE (21).
  VETERINARIAN_PHONE_INDEX = 22
  TUTOR_PHONE_INDEX = 30

  STAFF = {
    veterinarian: { email_prefix: "veterinaria", secret_env: "DEV_VETERINARIAN_OTP_SECRET",
                    default_secret: "VETERINARIACENTROZOONOSESSEMENTE" },
    team: { email_prefix: "zoonoses", secret_env: "DEV_ZOONOSES_TEAM_OTP_SECRET",
            default_secret: "EQUIPEZOONOSESCENTROSEMENTEQUATR" }
  }.freeze
  VETERINARIAN = { professional_name: "Helena Cristina Vasconcelos", council_state: "PR", registration_number: "9217" }.freeze

  # Produtos de zoonoses (Q11: uma finalidade só, un e carga 1.00) e o lote de
  # cada um, por uma nota fiscal própria no local da UVZ.
  PRODUCTS = {
    vaccine: { "code" => "RAIVA-ANIM", "name" => "Vacina antirrábica animal", "unit" => "un", "charge_size" => "1.00",
               "uses" => %w[rabies_vaccine] },
    collar: { "code" => "COL-DELTA4", "name" => "Coleira deltametrina 4%", "unit" => "un", "charge_size" => "1.00", "uses" => %w[collar] }
  }.freeze
  INVOICE = { number: "000912655", supplier: "Distribuidora Veterinária Sul Paraná Ltda.", days_ago: 30 }.freeze
  LOTS = { vaccine: { lot: "RAB2611V", quantity: "400", months: 12 }, collar: { lot: "COL2610D", quantity: "40", months: 24 } }.freeze

  # Os oito animais (§17): cinco com tutor, um comunitário (sem tutor, no
  # domicílio) e dois recolhidos no canil (sem domicílio). `microchip`: 15
  # dígitos (o prefixo 900 é o de teste do ISO 11784, nunca de fabricante).
  ANIMALS = {
    thor: { household: :acacias, tutor: :jose, microchip: "900118000000001",
            attrs: { "species" => "dog", "sex" => "male", "name" => "Thor", "size" => "large", "coat" => "caramelo", "breed" => "Labrador",
                     "birth_estimate_on" => "2021-03" } },
    mel: { household: :ipe_1180, tutor: :sebastiao, microchip: "900118000000002",
           attrs: { "species" => "dog", "sex" => "female", "name" => "Mel", "size" => "small", "coat" => "branca", "breed" => "Poodle",
                    "birth_estimate_on" => "2019-08" } },
    mimi: { household: :ipe_1236, tutor: :ana,
            attrs: { "species" => "cat", "sex" => "female", "name" => "Mimi", "size" => "small", "coat" => "tricolor",
                     "birth_estimate_on" => "2022-11" } },
    duque: { household: :pedro_gusso, tutor: :daniela, microchip: "900118000000003",
             attrs: { "species" => "dog", "sex" => "male", "name" => "Duque", "size" => "medium", "coat" => "preto", "breed" => "Vira-lata",
                      "birth_estimate_on" => "2020-06" } },
    nina: { household: :pedro_gusso, tutor: :geraldo,
            attrs: { "species" => "dog", "sex" => "female", "name" => "Nina", "size" => "medium", "coat" => "marrom e branca",
                     "birth_estimate_on" => "2023-02" } },
    caramelo: { household: :ipe_1236, community: true,
                attrs: { "species" => "dog", "sex" => "male", "name" => "Caramelo da Ipê", "size" => "medium", "coat" => "caramelo",
                         "birth_estimate_on" => "2021-09" } }
  }.freeze
  SHELTER = {
    toto: { entry_kind: "collection", days_ago: 6,
            animal: { "species" => "dog", "sex" => "male", "name" => "Totó", "size" => "small", "coat" => "amarelo", "community" => true } },
    frajola: { entry_kind: "voluntary_surrender", days_ago: 2,
               animal: { "species" => "cat", "sex" => "male", "name" => "Frajola", "size" => "small", "coat" => "preto e branco",
                         "community" => true } }
  }.freeze

  # Campanha: começou há quatro semanas; uma dose casa a casa por semana a cada
  # animal vacinável com domicílio e três de posto fixo sem cadastro (§17, Q4).
  CAMPAIGN = { name: "Campanha antirrábica 2026", starts_days_ago: 27, ends_in_days: 33, goal_dogs: 800, goal_cats: 200 }.freeze
  HOUSE_DOSES = { thor: 25, mel: 25, mimi: 18, duque: 11, nina: 4 }.freeze
  POST_DOSES = [ { species: "dog", days_ago: 18 }, { species: "cat", days_ago: 11 }, { species: "dog", days_ago: 4 } ].freeze

  # Inquérito de amostra no bairro dos domicílios 245, 1180 e 1236: três
  # coletas (o DPP reagente é o da Mel, com ELISA pendente) e a coleira do Thor
  # vence dentro da janela de 15 dias.
  SURVEY = { name: "Inquérito canino de LV — Butiatuvinha", dog_population: 640, starts_days_ago: 12, ends_in_days: 30 }.freeze
  TESTS = { thor: "non_reactive", mel: "reactive", caramelo: "non_reactive" }.freeze
  COLLAR_DUE_IN_DAYS = 10

  # Notificação da mordida: o paciente é o Cláudio; o animal é um cão do
  # vizinho, observável, exposto há três dias (a observação de 10 dias segue).
  BITE = { patient: :claudio, exposure_days_ago: 3, tutor_name: "Marcelo Antônio Dutra",
           address: "Rua Visconde de Nácar, 410, casa dos fundos, Butiatuvinha" }.freeze

  DEMAND = { body: "Encontrei um escorpião-amarelo dentro de casa, perto do berço do bebê, e já é a segunda vez neste mês. " \
                   "Peço orientação e uma vistoria do centro de zoonoses.",
             name: "Rosana Beatriz Kovalski", address: "Rua das Acácias, 245, Butiatuvinha", subtype: "scorpion" }.freeze

  class << self
    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("desligado (só Curitiba liga)") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] zoonoses: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      place = prerequisites!(slug)
      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: true, maintainer: maintainer)
      CityCatalog.reset_cache!
      # Lidos fora de qualquer transação, como o controlador lê (`zoonoses_field:`).
      raise "semente de zoonoses: zoonoses ligado mas não utilizável — rode o TerritoryRegistryCrew (db:seed) antes" unless Zoonoses::Gate.usable?(city)

      field = Zoonoses::Gate.field_usable?(city)
      ombudsman = Zoonoses::Gate.ombudsman_usable?(city)
      staff = staff!(slug, ddd, password, place)
      products = products!(place, staff)
      animals = animals!(slug, place, staff)
      campaign = campaign!(place, staff, animals, products, field)
      shelter!(place, staff)
      observation = bite!(slug, ddd, place)
      survey = survey!(place, staff, animals)
      collar!(staff, animals, products)
      demand = demand!(place, ombudsman)

      summary(city, place, staff, animals, campaign, survey, observation, demand)
    end

    # Só e-mail, papel, otpauth e o microchip de dev (nunca CPF, CNS, nome de
    # tutor, telefone nem endereço).
    def summary_lines(result, password:)
      head = "[seeds] zoonoses #{result[:switch]}"
      return [ head ] unless result[:unit]

      [ "#{head}; #{result[:unit]}: #{result[:products]} produtos, #{result[:lots]} lotes com saldo",
        "[seeds]               animais #{result[:animals]} (#{result[:shelter]} no canil); campanha #{result[:campaign]}",
        "[seeds]               observação #{result[:observation]}; inquérito #{result[:survey]}; coleiras a vencer #{result[:collars_due]}",
        "[seeds]               demandas abertas #{result[:demands]}; eutanásias #{result[:euthanasias]}",
        "[seeds]               busca por microchip: #{result[:microchip]} (dev, fictício)" ] +
        result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    private

    def guard_environment!
      raise "semente de zoonoses: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch)
      { switch: switch, unit: nil, products: 0, lots: 0, animals: 0, shelter: 0, campaign: nil, observation: nil, survey: nil,
        collars_due: 0, demands: 0, euthanasias: 0, microchip: nil, users: [] }
    end

    def check!(result, what)
      raise "semente de zoonoses: #{what} recusado (#{result.reason} #{result.details})" if result.failure?

      result
    end

    # --- pré-requisitos -----------------------------------------------------------

    # A UBS, a eSF, os domicílios do 24a, as pessoas, a UVZ e o local do
    # VectorControlCrew, a coordenação, o almoxarife, a ouvidoria e a vigilante.
    def prerequisites!(slug)
      unit = HealthUnit.find_by!(name: UNIT)
      team = HealthTeam.find_by(health_unit: unit, name: TEAM_NAME, active: true) || HealthTeam.where(health_unit: unit, active: true).order(:created_at).first
      areas = team ? AREAS.to_h { |code| [ code, MicroArea.find_by(team: team, code: code) ] } : {}
      households = TerritoryRegistryCrew::HOUSEHOLDS.to_h do |key, data|
        [ key, areas[data[:area]] && household_at(areas[data[:area]], data[:address]) ]
      end
      people = %i[jose sebastiao ana daniela geraldo claudio].to_h { |key| [ key, TerritoryRegistryCrew.patient_of(slug, key) ] }
      missing = areas.select { |_, area| area.nil? }.keys + households.select { |_, h| h.nil? }.keys + people.select { |_, p| p.nil? }.keys
      if team.nil? || missing.any?
        raise "semente de zoonoses: falta o cadastro territorial (#{missing.join(', ').presence || 'equipe'}) " \
              "— rode o TerritoryRegistryCrew e o HomeVisitCrew (db:seed) antes"
      end

      uvz = HealthUnit.find_by(name: UVZ)
      location = uvz && StockLocation.find_by(health_unit_id: uvz.id, kind: "vector_control")
      raise "semente de zoonoses: sem a UVZ e o local de insumos — rode o VectorControlCrew (db:seed) antes" unless location

      { unit: unit, team: team, households: households, people: people, uvz: uvz, location: location,
        admin: User.find_by!(email_address: "#{ADMIN}@#{slug}.demo"), officer: user!("#{OFFICER}@#{slug}.demo", "a vigilante", "SurveillanceCrew"),
        coordinator: user!("#{VectorControlCrew::STAFF.dig(:coordinator, :email_prefix)}@#{slug}.demo", "a coordenação", "VectorControlCrew"),
        keeper: user!("#{VectorControlCrew::STAFF.dig(:keeper, :email_prefix)}@#{slug}.demo", "o almoxarife da UVZ", "VectorControlCrew"),
        ombudsman: user!(OMBUDSMAN_STAFF, "a ouvidoria", "OmbudsmanCrew") }
    end

    def user!(email, what, crew)
      User.find_by(email_address: email) || raise("semente de zoonoses: sem #{what} (#{email}) — rode o #{crew} (db:seed) antes")
    end

    def household_at(area, address)
      Household.where(micro_area: area).detect do |household|
        household.latest_version.address.values_at("zip", "number") == address.values_at("zip", "number")
      end
    end

    # --- pessoas ------------------------------------------------------------------

    # A veterinária e a equipe: usuário, TOTP de dev e só o papel zoonoses_team
    # (Q30). O perfil profissional é só da veterinária.
    def staff!(slug, ddd, password, place)
      staff = STAFF.to_h do |key, spec|
        user = account!("#{spec[:email_prefix]}@#{slug}.demo", password, spec)
        grant!(user, Zoonoses::Catalog::ROLE, place[:admin])
        [ key, user ]
      end
      veterinarian_profile!(slug, ddd, staff[:veterinarian], place)
      staff.merge(coordinator: place[:coordinator]).transform_values(&:reload)
    end

    def account!(email, password, spec)
      user = User.find_or_initialize_by(email_address: email)
      user.password = password
      user.save!
      SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
      user.reload
    end

    def grant!(user, role, admin)
      return if user.has_role?(role)

      check!(GrantRole.call(user_id: user.id, role: role, by: admin), "papel #{role} de #{user.email_address}")
    end

    # CRMV-PR com número de formato válido; o CBO 223305 é do vínculo na UVZ.
    def veterinarian_profile!(slug, ddd, user, place)
      professional = user.professional
      unless professional
        seed = "#{slug}:#{STAFF.dig(:veterinarian, :email_prefix)}"
        attrs = { professional_name: VETERINARIAN[:professional_name], council: "CRMV", council_state: VETERINARIAN[:council_state],
                  registration_number: VETERINARIAN[:registration_number], cns: Professionals::Cns.generate(seed),
                  cpf: ScreeningCrew.send(:cpf_for, seed), phone: TerritoryRegistryCrew.phone_for(ddd, VETERINARIAN_PHONE_INDEX) }
        professional = check!(Professionals::Create.call(user_id: user.id, attrs: attrs, by: place[:admin]), "perfil da veterinária").payload[:professional]
      end
      return if professional.links.active.exists?(health_unit: place[:uvz], cbo_code: Zoonoses::Catalog::VETERINARIAN_CBO)

      check!(Professionals::OpenLink.call(professional: professional, health_unit_id: place[:uvz].id, cbo_code: Zoonoses::Catalog::VETERINARIAN_CBO,
                                          by: place[:admin]), "vínculo da veterinária na UVZ")
    end

    # --- estoque ------------------------------------------------------------------

    # Os dois produtos (pela coordenação) e um lote de cada, por uma nota
    # fiscal do almoxarife da UVZ, uma vez por local. -> { chave => VectorProduct }
    def products!(place, _staff)
      products = PRODUCTS.transform_values do |params|
        VectorProduct.find_by("lower(code) = lower(?)", params["code"]) ||
          check!(VectorControl::SaveProduct.call(params: params, by: place[:coordinator], zoonoses: true), "produto #{params['code']}").payload[:product]
      end
      unless StockEntry.exists?(stock_location_id: place[:location].id, kind: "invoice", document_number: INVOICE[:number])
        today = Time.zone.today
        items = LOTS.map do |key, spec|
          { "vector_product_id" => products.fetch(key).id, "lot_number" => spec[:lot], "expires_on" => (today >> spec[:months]).iso8601,
            "manufacturer" => "Fornecedor do Ministério da Saúde", "quantity" => spec[:quantity] }
        end
        document = { "number" => INVOICE[:number], "supplier" => INVOICE[:supplier] }
        received_at = (today - INVOICE[:days_ago]).in_time_zone.change(hour: 10)
        check!(Pharmacy::RecordEntry.call(location: place[:location], kind: "invoice", document: document, items: items, by: place[:keeper], catalog: {},
                                          now: received_at), "nota fiscal #{INVOICE[:number]}")
      end
      products
    end

    # --- animais ------------------------------------------------------------------

    # Os seis animais de domicílio, pela equipe. Achados pelo nome e domicílio.
    # -> { chave => Animal }
    def animals!(slug, place, staff)
      ANIMALS.to_h do |key, spec|
        household = place[:households].fetch(spec[:household])
        animal = Animal.find_by(name: spec[:attrs]["name"], household_id: household.id)
        unless animal
          params = spec[:attrs].merge("household_id" => household.id)
          params["tutor_patient_id"] = place[:people].fetch(spec[:tutor]).id if spec[:tutor]
          params["community"] = true if spec[:community]
          params["microchip"] = spec[:microchip] if spec[:microchip]
          animal = check!(Zoonoses::SaveAnimal.call(params: params, by: staff[:team]), "animal #{spec[:attrs]['name']}").payload[:animal]
        end
        [ key, animal ]
      end.tap { |animals| animals.each_value { |animal| raise "semente de zoonoses: animal #{animal.name} fora de active" unless animal.status == "active" } }
    end

    # Os dois do canil: nascem na entrada (Zoonoses::EnterShelter com
    # new_animal), na UVZ; a estada aberta é a chave.
    def shelter!(place, staff)
      SHELTER.each_value do |spec|
        next if Animal.exists?(name: spec[:animal]["name"], household_id: nil)

        params = { "new_animal" => spec[:animal], "health_unit_id" => place[:uvz].id, "entry_kind" => spec[:entry_kind],
                   "entered_on" => (Time.zone.today - spec[:days_ago]).iso8601 }
        check!(Zoonoses::EnterShelter.call(params: params, by: staff[:team]), "entrada de #{spec[:animal]['name']} no canil")
      end
    end

    # --- campanha -----------------------------------------------------------------

    # A campanha open (coordenação) e as doses: casa a casa por animal com
    # domicílio e três de posto fixo sem animal (Q4). -> RabiesCampaign
    def campaign!(place, staff, animals, products, field)
      today = Time.zone.today
      coordinator = staff[:coordinator]
      campaign = RabiesCampaign.find_by(name: CAMPAIGN[:name])
      unless campaign
        params = { "name" => CAMPAIGN[:name], "starts_on" => (today - CAMPAIGN[:starts_days_ago]).iso8601,
                   "ends_on" => (today + CAMPAIGN[:ends_in_days]).iso8601, "goal_dogs" => CAMPAIGN[:goal_dogs], "goal_cats" => CAMPAIGN[:goal_cats] }
        campaign = check!(Zoonoses::SaveCampaign.call(params: params, by: coordinator), "campanha").payload[:campaign]
      end
      check!(Zoonoses::SaveCampaign.open(campaign: campaign, by: coordinator), "abertura da campanha") if campaign.stage == "planned"
      campaign.reload

      vaccine = products.fetch(:vaccine)
      HOUSE_DOSES.each do |key, days_ago|
        animal = animals.fetch(key)
        next if RabiesVaccination.exists?(campaign_id: campaign.id, animal_id: animal.id, cancelled_at: nil)

        dose!({ "modality" => "house", "campaign_id" => campaign.id, "animal_id" => animal.id, "vaccinated_on" => (today - days_ago).iso8601,
                "vector_product_id" => vaccine.id, "adverse_event" => false }, staff, field, "dose de #{animal.name}")
      end
      POST_DOSES.each do |dose|
        day = today - dose[:days_ago]
        next if RabiesVaccination.exists?(campaign_id: campaign.id, modality: "fixed_post", animal_id: nil, species: dose[:species], vaccinated_on: day,
                                          cancelled_at: nil)

        dose!({ "modality" => "fixed_post", "campaign_id" => campaign.id, "species" => dose[:species], "vaccinated_on" => day.iso8601,
                "vector_product_id" => vaccine.id, "adverse_event" => false, "health_unit_id" => place[:unit].id }, staff, field,
              "dose de posto fixo (#{dose[:species]})")
      end
      campaign
    end

    def dose!(params, staff, field, what)
      check!(Zoonoses::RecordVaccination.call(params: params, by: staff[:team], zoonoses_field: field), what)
    end

    # --- observação do animal agressor --------------------------------------------

    # A notificação de acidente com o bloco do animal, pela vigilante; o
    # consumidor roda inline (como a fila faria) e abre a observação.
    # -> BiteObservation
    def bite!(slug, ddd, place)
      today = Time.zone.today
      disease = Surveillance::Diseases.find(Zoonoses::Catalog::OBSERVATION_DISEASE)
      raise "semente de zoonoses: #{Zoonoses::Catalog::OBSERVATION_DISEASE} fora da lista nacional — rode o db:seed (plataforma)" unless disease

      patient = place[:people].fetch(BITE[:patient])
      notification = DiseaseNotification.where(patient_id: patient.id, disease_code: disease.code).order(:created_at, :id).last
      notification ||= check!(Surveillance::CreateNotification.call(
        patient: patient, disease: disease, origin: "manual", unit: place[:unit], suspected_at: (today - BITE[:exposure_days_ago]).in_time_zone.change(hour: 15),
        by: place[:officer]
      ), "notificação de acidente").payload[:notification]

      unless notification.form["animal_species"]
        block = { "animal_species" => "dog", "animal_condition" => "healthy", "animal_observable" => "true",
                  "exposure_on" => (today - BITE[:exposure_days_ago]).iso8601, "animal_tutor_name" => BITE[:tutor_name],
                  "animal_tutor_phone" => TerritoryRegistryCrew.phone_for(ddd, TUTOR_PHONE_INDEX), "animal_address" => BITE[:address] }
        check!(Surveillance::SaveForm.call(notification: notification, form: notification.form.merge(block), version: notification.version,
                                           by: place[:officer]), "bloco do animal da notificação")
        notification.reload
      end
      open_observation!(notification)
      BiteObservation.find_by!(disease_notification_id: notification.id)
    end

    # O Zoonoses::OpenObservationJob sobre o último evento da notificação,
    # inline (perform_now: o job lê o gate e abre a cidade pelo slug; nunca
    # atribui Current.city). Se a fila do dev já o consumiu (dedup), o comando
    # que ele chama é idempotente pelo único da notificação.
    def open_observation!(notification)
      return if BiteObservation.exists?(disease_notification_id: notification.id)

      event = DomainEvent.where(name: %w[disease_notification.updated disease_notification.created])
                         .where("payload->>'notification_id' = ?", notification.id).order(:occurred_at, :created_at).last
      if event
        Zoonoses::OpenObservationJob.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
      end
      return if BiteObservation.exists?(disease_notification_id: notification.id)

      Zoonoses::OpenObservation.call(notification: notification.reload, parameters: Zoonoses::Parameters.current.values)
    end

    # --- inquérito e coleira ------------------------------------------------------

    # O inquérito de amostra open nos quarteirões dos três domicílios e as três
    # coletas com o DPP (o ELISA do reagente fica pendente). -> LeishSurvey
    def survey!(place, staff, animals)
      today = Time.zone.today
      coordinator = staff[:coordinator]
      survey = LeishSurvey.find_by(name: SURVEY[:name])
      unless survey
        households = %i[acacias ipe_1180 ipe_1236].map { |key| place[:households].fetch(key) }
        blocks = HouseholdVectorProfile.where(household_id: households.map(&:id)).where.not(city_block_id: nil).pluck(:city_block_id).uniq
        raise "semente de zoonoses: os domicílios sem quarteirão — rode o VectorControlCrew (db:seed) antes" if blocks.empty?

        params = { "name" => SURVEY[:name], "kind" => "sample", "neighborhood_id" => households.first.latest_version.neighborhood_id,
                   "city_block_ids" => blocks, "dog_population" => SURVEY[:dog_population], "starts_on" => (today - SURVEY[:starts_days_ago]).iso8601,
                   "ends_on" => (today + SURVEY[:ends_in_days]).iso8601 }
        survey = check!(Zoonoses::SaveSurvey.call(params: params, by: coordinator), "inquérito").payload[:survey]
      end
      if survey.stage == "draft"
        check!(Zoonoses::SaveSurvey.transition(survey: survey, params: { "expected_version" => survey.version }, by: coordinator, from: "draft", to: "open"),
               "abertura do inquérito")
        survey.reload
      end

      TESTS.each do |key, dpp|
        animal = animals.fetch(key)
        next if LeishTest.exists?(leish_survey_id: survey.id, animal_id: animal.id)

        collected = today - 9
        params = { "leish_survey_id" => survey.id, "animal_id" => animal.id, "collected_on" => collected.iso8601, "dpp_result" => dpp,
                   "dpp_on" => (collected + 1).iso8601 }
        check!(Zoonoses::RecordLeishTest.call(params: params, by: staff[:team]), "coleta de #{animal.name}")
      end
      survey
    end

    # A coleira do Thor vence daqui a COLLAR_DUE_IN_DAYS dias (colocada há
    # collar_months − 10 dias); uma coleira ativa só por cão.
    def collar!(staff, animals, products)
      animal = animals.fetch(:thor)
      return if Collar.active.exists?(animal_id: animal.id)

      months = Zoonoses::Parameters.current.values.fetch("collar_months")
      placed_on = (Time.zone.today + COLLAR_DUE_IN_DAYS) << months
      check!(Zoonoses::PlaceCollar.call(params: { "animal_id" => animal.id, "vector_product_id" => products.fetch(:collar).id,
                                                  "placed_on" => placed_on.iso8601 }, by: staff[:team]), "coleira do Thor")
    end

    # --- demanda ------------------------------------------------------------------

    # Solicitação de escorpião registrada pela ouvidoria (telefone); o
    # Ombudsman::Register classifica e encaminha à UVZ sozinho, e a demanda
    # nasce no encaminhamento. Sem o 33 utilizável, a demanda não existe.
    def demand!(place, ombudsman)
      return nil unless ombudsman
      return ZoonosesDemand.where(subtype: DEMAND[:subtype]).order(:created_at, :id).first if ZoonosesDemand.exists?(subtype: DEMAND[:subtype])

      attrs = { "kind" => "request", "identification_mode" => "identified", "body" => DEMAND[:body], "manifestant_name" => DEMAND[:name],
                "zoonoses_subtype" => DEMAND[:subtype], "place_address" => DEMAND[:address] }
      check!(Ombudsman::Register.call(attrs: attrs, channel: "phone", by: place[:ombudsman], zoonoses: true, now: Time.current), "manifestação de escorpião")
      ZoonosesDemand.where(subtype: DEMAND[:subtype]).order(:created_at, :id).first
    end

    # --- resumo -------------------------------------------------------------------

    def summary(city, place, staff, animals, campaign, survey, observation, demand)
      lots = StockLot.where(vector_product_id: VectorProduct.where("uses && ARRAY['rabies_vaccine','collar']::text[]").select(:id))
      balances = Pharmacy::Ledger.balances(location_id: place[:location].id, lot_ids: lots.pluck(:id))
      today = Time.zone.today
      { switch: Zoonoses::Gate.usable?(city) ? "ligado (zoonoses)" : "ligado, não utilizável",
        unit: place[:uvz].name, products: lots.distinct.count(:vector_product_id), lots: balances.values.count(&:positive?),
        animals: Animal.count, shelter: ShelterStay.where(exited_on: nil).count,
        campaign: "#{campaign.stage}, #{RabiesVaccination.where(campaign_id: campaign.id, cancelled_at: nil).count} dose(s)",
        observation: "#{observation.state} até #{observation.ends_on.strftime('%d/%m')}",
        survey: "#{survey.stage} (#{survey.kind}), #{LeishTest.where(leish_survey_id: survey.id).count} teste(s), alvo #{survey.target_dogs} cães",
        collars_due: Collar.active.where(due_on: today..(today + Zoonoses::Catalog::COLLAR_DUE_WINDOW)).count,
        demands: demand ? ZoonosesDemand.where(state: %w[open scheduled inspected]).count : 0,
        euthanasias: Euthanasia.count, microchip: ANIMALS.dig(:thor, :microchip),
        users: STAFF.keys.map do |key|
          { email: staff[key].email_address, role: Zoonoses::Catalog::ROLE, otpauth_uri: SignatureCrew.otpauth_uri(staff[key]) }
        end }
    end
  end
end
