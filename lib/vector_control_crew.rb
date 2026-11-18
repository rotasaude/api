require_relative "signature_crew"
require_relative "screening_crew"
require_relative "care_lines_crew"
require_relative "territory_registry_crew"
require_relative "home_visit_crew"

# Semente de dev do módulo 35a (ADR 0054; contrato §18), para a prova no
# navegador e no app. Dev é fictício mas imita o real: em Curitiba (a cidade
# com home_visits), vector_control LIGADO pelo mantenedor de dev; na eSF do
# CareLinesCrew, o agente de combate às endemias Edson Luiz Camargo (ace@,
# CBO 515140, sem conselho, CNS e CPF válidos), atribuído pela enfermeira da
# equipe às microáreas 01 e 02; a coordenação (endemias@, endemic_coordinator)
# e o laboratório de entomologia (entomologia@, vector_lab), com a senha e o
# TOTP das outras contas. Tudo pelos comandos do app, com as mesmas validações
# da tela; o "hoje" é Time.zone.today da cidade.
#
#   UVZ Curitiba (environmental_surveillance) com o local vector_control, que
#   o vector_control_settings aponta; três produtos com cargas de catálogo
#   (dois larvicidas focais e um adulticida espacial) e um lote de cada, com
#   saldo pela abertura do 27a (o do espinosade, curto: 2 un), lançada pelo
#   almoxarife da UVZ (almoxarifado-uvz@, stock_keeper vinculado ao local pelo
#   Pharmacy::LinkStaff): o caminho local → almoxarife → entrada → baixa (Q21).
#
#   quarteirão         bairro         imóveis (perfil)                         risco
#   001                Butiatuvinha   R. das Acácias 245; borracharia (PE)     vermelho; —
#   002                Butiatuvinha   R. Ipê Amarelo 1180 e 1236               amarelo; verde
#   014                São João       R. Pedro Gusso 780                       cinza
#   015                São João       ferro-velho (PE)                         roxo
#   vizinhos: 001–002, 014–015 e 002–015 (cruza os bairros).
#   Cadência da cidade: vermelho 7 dias, amarelo 21, cinza 30, PE 15.
#
#   roteiro (§18)                      dado semeado
#   1 boletim e ficha 8                LI na R. das Acácias há 10 dias (depósito A2, mecânico, focal e amostra);
#                                      motivos 34–37 derivados; folha fechada pelo ACE
#   2 baixa e falta                    a baixa do piriproxifeno; e a falta do espinosade (insufficient_balance)
#                                      no bloqueio da R. Pedro Gusso, aberta para conciliar
#   3 vencidos por risco               R. das Acácias (vermelho, 10 dias > 7); a borracharia fechada há 2 dias (pending)
#   4 ovitrampas                       OV-0101 (Acácias) e OV-0201 (Pedro Gusso), quatro semanas contadas pela
#                                      entomologia; uma leitura de 142 ovos abre a tarefa de intensificação
#   5 LIRAa                            census no quarteirão 002, sorteado; o 1180 inspecionado, o 1236 pending
#   6 bloqueio                         dengue da Daniela (CreateNotification, ProposeBlockJob inline),
#                                      confirmado no anel do 014 e com o 1º ciclo de UBV
#   7 amostra e IIP                    a amostra do LIRAa sem resultado (a do LI também)
#   8 relatórios                       situações worked e closed, consumo e falta
#   9 app offline                      o ACE com as duas microáreas e o gate utilizável
#
# Idempotente: o client_uuid das visitas e das ovitrampas é fixo (UUID v5 da
# cidade e do cenário), e o comando devolve replayed; quarteirões, perfis,
# produtos, lotes, levantamento, ciclo e bloqueio conferem o estado antes. As
# coletas das ovitrampas são contadas a partir da instalação gravada, então
# semear noutro dia não acrescenta leitura. Roda depois do HomeVisitCrew (e do
# SurveillanceCrew, de quem vem a vigilante que notifica).
class VectorControlCrew
  UNIT = CareLinesCrew::UNIT
  TEAM_NAME = CareLinesCrew::TEAM_NAME
  DEV_MAINTAINER = "dev@local".freeze
  NURSE = "enfermeira".freeze
  ADMIN = "admin".freeze
  OFFICER = "vigilancia".freeze
  AREAS = %w[01 02].freeze
  UVZ = "UVZ Curitiba".freeze
  LOCATION_NAME = "Insumos de campo — UVZ Curitiba".freeze
  # Telefone do ACE no bloco do 24a (+55 <ddd> 96666-24NN), depois do TACS (20).
  PHONE_INDEX = 21
  ACE = { email_prefix: "ace", professional_name: "Edson Luiz Camargo", cbo: TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO,
          months_in_team: 30, secret_env: "DEV_ACE_OTP_SECRET", default_secret: "AGENTEENDEMIASSEMENTEVETORIALUMA" }.freeze
  STAFF = {
    coordinator: { email_prefix: "endemias", role: VectorControl::Access::COORDINATOR, secret_env: "DEV_ENDEMIC_COORDINATOR_OTP_SECRET",
                   default_secret: "COORDENACAOENDEMIASSEMENTEVETORX" },
    lab: { email_prefix: "entomologia", role: VectorControl::Access::LAB, secret_env: "DEV_VECTOR_LAB_OTP_SECRET",
           default_secret: "ENTOMOLOGIALABORATORIOSEMENTETRE" },
    # O almoxarife do local vector_control da UVZ (27a: stock_keeper com vínculo
    # ao local): é quem dá entrada nos lotes e pode conciliar a falta (Q21).
    keeper: { email_prefix: "almoxarifado-uvz", role: "stock_keeper", secret_env: "DEV_UVZ_STOCK_KEEPER_OTP_SECRET",
              default_secret: "ALMOXARIFADOUVZSEMENTEVETORIALQT" }
  }.freeze

  # Cargas de catálogo (o produto fixa unidade e carga; a baixa é cargas × carga).
  PRODUCTS = {
    pyriproxyfen: { "code" => "PPF05", "name" => "Piriproxifeno 0,5% granulado", "unit" => "g", "charge_size" => "2.00",
                    "uses" => %w[focal] },
    spinosad: { "code" => "SPN748", "name" => "Espinosade 7,48% comprimido", "unit" => "un", "charge_size" => "1.00", "uses" => %w[focal] },
    ubv: { "code" => "IMP-PRA", "name" => "Imidacloprida 3% + praletrina 0,75% UBV", "unit" => "ml", "charge_size" => "50.00",
           "uses" => %w[spatial] }
  }.freeze
  # Um lote de cada pela abertura do local; o do espinosade é curto de propósito (a falta do roteiro 2).
  LOTS = { pyriproxyfen: { lot: "PPF2611A", quantity: "500", months: 18 }, spinosad: { lot: "SPN2610B", quantity: "2", months: 12 },
           ubv: { lot: "IPR2609C", quantity: "4000", months: 24 } }.freeze

  # Os domicílios do TerritoryRegistryCrew (chave de HOUSEHOLDS) e os dois PE
  # novos, cadastrados pelo ACE (imóvel não residencial, Q13(1)).
  STRATEGIC_POINTS = {
    borracharia: { area: "01", neighborhood_of: :acacias,
                   address: { "zip" => "82400210", "street_type" => "081", "street" => "das Acácias", "number" => "410",
                              "reference" => "Borracharia, pneus no pátio dos fundos" } },
    ferro_velho: { area: "02", neighborhood_of: :pedro_gusso,
                   address: { "zip" => "82030150", "street_type" => "081", "street" => "Pedro Gusso", "number" => "1020",
                              "reference" => "Ferro-velho ao lado do terreno baldio" } }
  }.freeze
  # Quarteirões pelo bairro de um domicílio semeado.
  BLOCKS = { b001: { number: "001", neighborhood_of: :acacias }, b002: { number: "002", neighborhood_of: :acacias },
             s014: { number: "014", neighborhood_of: :pedro_gusso }, s015: { number: "015", neighborhood_of: :pedro_gusso } }.freeze
  NEIGHBORS = [ %i[b001 b002], %i[s014 s015], %i[b002 s015] ].freeze
  PROFILES = { acacias: { block: :b001, risk: "red" }, borracharia: { block: :b001, risk: nil },
               ipe_1180: { block: :b002, risk: "yellow" }, ipe_1236: { block: :b002, risk: "green" },
               pedro_gusso: { block: :s014, risk: "gray" }, ferro_velho: { block: :s015, risk: "purple" } }.freeze
  # Só quando a cidade ainda não tem cadência (o PUT troca a lista inteira).
  CADENCES = [ { "neighborhood_id" => nil, "risk_class" => "red", "strategic_point" => false, "days" => 7 },
               { "neighborhood_id" => nil, "risk_class" => "yellow", "strategic_point" => false, "days" => 21 },
               { "neighborhood_id" => nil, "risk_class" => "gray", "strategic_point" => false, "days" => 30 },
               { "neighborhood_id" => nil, "risk_class" => nil, "strategic_point" => true, "days" => 15 } ].freeze

  # Ovitrampas: instaladas há 4 semanas, coletadas a cada 7 dias (reinstaladas)
  # e contadas pela entomologia, uma contagem por semana.
  OVITRAPS = { "OV-0101" => { household: :acacias, eggs: [ 18, 46, 142, 71 ] },
               "OV-0201" => { household: :pedro_gusso, eggs: [ 0, 9, 23, 12 ] } }.freeze
  OVITRAP_DAYS = 7

  LIRAA = { name: "LIRAa de dev — Jardim das Flores", stratum: "Butiatuvinha — quarteirão 002", blocks: %i[b002],
            household: :ipe_1180 }.freeze

  # Dia do LI vencido (antes da cadência vermelha de 7 dias, dentro do prazo do SIAPS).
  OVERDUE_DAYS = 10
  CLOSED_DAYS = 2
  DENGUE = { patient: :daniela, suspected_days: 3, symptoms_days: 5 }.freeze

  NAMESPACE = Digest::UUID.uuid_v5(Digest::UUID::URL_NAMESPACE, "https://rotasaude.app/seeds/vector_control_crew")

  class << self
    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("desligado (só Curitiba liga)") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] controle vetorial: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      place = prerequisites!(slug)
      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: true, maintainer: maintainer)
      CityCatalog.reset_cache!
      # Lido fora de qualquer transação, como o controlador lê (`vector_control:`).
      usable = VectorControl::Gate.usable?(city)
      raise "semente do controle vetorial: vector_control ligado mas não utilizável — rode o HomeVisitCrew (db:seed) antes" unless usable

      staff = staff!(slug, ddd, password, place)
      location = stock!(staff, place[:admin])
      place[:households].merge!(strategic_points!(place, staff[:ace], usable))
      blocks = territory!(place, staff[:coordinator])
      check!(VectorControl::SaveCadences.call(items: CADENCES, by: staff[:coordinator]), "cadências") unless VectorCadence.exists?
      work_cycle!(staff[:coordinator])

      overdue!(slug, place, staff[:ace], usable)
      closed_point!(slug, place, staff[:ace], usable)
      close_past_sheets!(staff[:ace], place[:team])
      ovitraps!(slug, place, staff)
      survey = liraa!(slug, place, blocks, staff, usable)
      block = transmission_block!(place, staff)
      block_visit!(slug, place, block, staff[:ace], usable)

      summary(city, place, staff, location, blocks, survey, block)
    end

    # Só e-mail, papel e otpauth (nunca CPF, CNS, nome de paciente ou endereço de caso).
    def summary_lines(result, password:)
      head = "[seeds] controle vetorial #{result[:switch]}"
      return [ head ] unless result[:team]

      [ "#{head}; equipe #{result[:team]}; microáreas #{result[:micro_areas].join(', ')}",
        "[seeds]               #{result[:unit]}: #{result[:products]} produtos, #{result[:lots]} lotes com saldo",
        "[seeds]               território: #{result[:blocks]} quarteirões, #{result[:profiles]} perfis, #{result[:strategic_points]} PE",
        "[seeds]               ovitrampas #{result[:ovitraps]}; tarefas abertas #{result[:tasks]}",
        "[seeds]               LIRAa #{result[:liraa]}; bloqueio #{result[:block]}; faltas abertas #{result[:shortfalls]}" ] +
        result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    # client_uuid estável pela cidade e pelo cenário (sem dia: o estado manda).
    def client_uuid(slug, kind, key) = Digest::UUID.uuid_v5(NAMESPACE, "#{slug}:#{kind}:#{key}")

    private

    def guard_environment!
      raise "semente do controle vetorial: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch)
      { switch: switch, team: nil, micro_areas: [], unit: nil, products: 0, lots: 0, blocks: 0, profiles: 0, strategic_points: 0,
        ovitraps: nil, tasks: 0, liraa: nil, block: nil, shortfalls: 0, users: [] }
    end

    def check!(result, what)
      raise "semente do controle vetorial: #{what} recusado (#{result.reason} #{result.details})" if result.failure?

      result
    end

    # A UBS, a eSF, as microáreas 01 e 02, os domicílios do 24a, as pessoas e
    # quem já existe (enfermeira, administradora, vigilante).
    def prerequisites!(slug)
      unit = HealthUnit.find_by!(name: UNIT)
      team = HealthTeam.find_by(health_unit: unit, name: TEAM_NAME, active: true) ||
             HealthTeam.where(health_unit: unit, active: true).order(:created_at).first
      areas = team ? AREAS.to_h { |code| [ code, MicroArea.find_by(team: team, code: code) ] } : {}
      households = TerritoryRegistryCrew::HOUSEHOLDS.to_h do |key, data|
        [ key, areas[data[:area]] && household_at(areas[data[:area]], data[:address]) ]
      end
      people = %i[jose sebastiao daniela].to_h { |key| [ key, TerritoryRegistryCrew.patient_of(slug, key) ] }
      missing = areas.select { |_, area| area.nil? }.keys + households.select { |_, h| h.nil? }.keys + people.select { |_, p| p.nil? }.keys
      if team.nil? || missing.any?
        raise "semente do controle vetorial: falta o cadastro territorial (#{missing.join(', ').presence || 'equipe'}) " \
              "— rode o TerritoryRegistryCrew e o HomeVisitCrew (db:seed) antes"
      end
      officer = User.find_by(email_address: "#{OFFICER}@#{slug}.demo")
      raise "semente do controle vetorial: sem a vigilante #{OFFICER}@#{slug}.demo — rode o SurveillanceCrew (db:seed) antes" unless officer
      raise "semente do controle vetorial: dengue fora da lista nacional — rode o db:seed (plataforma)" unless Surveillance::Diseases.find("dengue")

      { unit: unit, team: team, areas: areas, households: households, people: people, officer: officer,
        nurse: User.find_by!(email_address: "#{NURSE}@#{slug}.demo"), admin: User.find_by!(email_address: "#{ADMIN}@#{slug}.demo") }
    end

    def household_at(area, address)
      Household.where(micro_area: area).detect do |household|
        household.latest_version.address.values_at("zip", "number") == address.values_at("zip", "number")
      end
    end

    # --- pessoas ----------------------------------------------------------------

    def staff!(slug, ddd, password, place)
      staff = STAFF.to_h do |key, spec|
        user = account!("#{spec[:email_prefix]}@#{slug}.demo", password, spec)
        grant!(user, spec[:role], place[:admin])
        [ key, user ]
      end
      staff[:ace] = ace!(slug, ddd, password, place)
      place[:areas].each_value { |area| assign!(area, staff[:ace], place[:nurse]) }
      staff
    end

    # Usuário, senha das outras contas da semente e TOTP fixo de dev.
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

    # O ACE como o TACS do 24b: usuário, papel, TOTP, perfil de campo (sem
    # conselho), vínculo 515140 na UBS e na eSF.
    def ace!(slug, ddd, password, place)
      user = account!("#{ACE[:email_prefix]}@#{slug}.demo", password, ACE)
      grant!(user, "health_professional", place[:admin])
      professional = user.professional || ace_profile!(slug, ddd, user, place[:admin])
      unless professional.links.active.exists?(health_unit: place[:unit], cbo_code: ACE[:cbo])
        opened = Professionals::OpenLink.call(professional: professional, health_unit_id: place[:unit].id, cbo_code: ACE[:cbo], by: place[:admin])
        check!(opened, "vínculo do ACE")
      end
      unless HealthTeamMember.active.exists?(professional: professional, health_team: place[:team])
        HealthTeamMember.create!(professional: professional, health_team: place[:team], cbo_code: ACE[:cbo],
                                 started_on: Time.zone.today << ACE[:months_in_team])
      end
      user.reload
    end

    def ace_profile!(slug, ddd, user, admin)
      seed = "#{slug}:#{ACE[:email_prefix]}"
      attrs = { professional_name: ACE[:professional_name], cns: Professionals::Cns.generate(seed),
                cpf: ScreeningCrew.send(:cpf_for, seed), phone: TerritoryRegistryCrew.phone_for(ddd, PHONE_INDEX) }
      check!(Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin), "perfil do ACE").payload[:professional]
    end

    # A enfermeira da equipe atribui a microárea ao ACE (uma vez).
    def assign!(area, ace, nurse)
      return if MicroAreaFieldAssignment.active.exists?(micro_area: area, professional: ace.professional)
      raise "semente do controle vetorial: a enfermeira não atribui na equipe" unless HomeVisits::Access.assigner?(nurse, area.team)

      check!(HomeVisits::AssignMicroArea.call(micro_area: area, professional_id: ace.professional.id, by: nurse), "atribuição da microárea #{area.code}")
    end

    # --- estoque ----------------------------------------------------------------

    # A UVZ (sem comando de unidade: o cadastro é do controlador, como nas outras
    # sementes), o local vector_control, o almoxarife vinculado a ele, a
    # configuração, os produtos e os lotes (a entrada é do almoxarife).
    def stock!(staff, admin)
      coordinator = staff[:coordinator]
      uvz = HealthUnit.find_or_create_by!(name: UVZ) { |unit| unit.kind = Pharmacy::Catalog::VECTOR_CONTROL_UNIT_KIND }
      location = StockLocation.find_by(health_unit_id: uvz.id, kind: "vector_control")
      location ||= check!(Pharmacy::SaveLocation.call(attrs: { "kind" => "vector_control", "name" => LOCATION_NAME, "health_unit_id" => uvz.id },
                                                       by: coordinator), "local de insumos").payload[:location]
      keeper!(location, staff[:keeper], admin)
      VectorControlSetting.ensure_defaults!
      unless VectorControlSetting.find(1).stock_location_id == location.id
        check!(VectorControl::SaveSettings.call(stock_location_id: location.id, by: coordinator), "local da baixa")
      end
      products = PRODUCTS.transform_values do |params|
        VectorProduct.find_by("lower(code) = lower(?)", params["code"]) ||
          check!(VectorControl::SaveProduct.call(params: params, by: coordinator), "produto #{params['code']}").payload[:product]
      end
      lots!(location, products, staff[:keeper])
      location
    end

    # O almoxarife no local, pela administradora (como o PharmacyCrew): uma vez.
    def keeper!(location, keeper, admin)
      return if StockLocationStaff.active.exists?(stock_location_id: location.id, user_id: keeper.id, role: "stock_keeper")

      check!(Pharmacy::LinkStaff.add(location: location, user_id: keeper.id, role: "stock_keeper", by: admin), "vínculo do almoxarife ao local")
    end

    # Abertura do local (uma por produto): só os produtos ainda sem abertura nele.
    def lots!(location, products, by)
      today = Time.zone.today
      pending = LOTS.reject { |key, _| StockOpening.exists?(stock_location_id: location.id, vector_product_id: products.fetch(key).id) }
      return if pending.empty?

      items = pending.map do |key, spec|
        { "vector_product_id" => products.fetch(key).id, "lot_number" => spec[:lot], "expires_on" => (today >> spec[:months]).iso8601,
          "manufacturer" => "Fornecedor do Ministério da Saúde", "quantity" => spec[:quantity] }
      end
      check!(Pharmacy::RecordEntry.call(location: location, kind: "opening", document: nil, items: items, by: by, catalog: {}), "abertura dos insumos")
    end

    # --- território -------------------------------------------------------------

    # Os dois PE, cadastrados pelo ACE (só imóvel não residencial). -> { chave => Household }
    def strategic_points!(place, ace, usable)
      STRATEGIC_POINTS.to_h do |key, data|
        area = place[:areas].fetch(data[:area])
        household = household_at(area, data[:address])
        unless household
          neighborhood_id = place[:households].fetch(data[:neighborhood_of]).latest_version.neighborhood_id
          params = { "micro_area_id" => area.id, "property_type" => VectorControl::Catalog::PE_PROPERTY, "refused" => false,
                     "address" => data[:address].merge("neighborhood_id" => neighborhood_id) }
          saved = check!(TerritoryRegistry::SaveHousehold.call(params: params, by: ace, vector_control: usable), "PE #{key}")
          household = saved.payload[:household]
        end
        [ key, household ]
      end
    end

    # Quarteirões, vizinhos e o perfil de todos os imóveis das duas microáreas.
    # O quarteirão e o risco só entram onde o perfil ainda não tem (a tela manda
    # depois). -> { chave => CityBlock }
    def territory!(place, coordinator)
      blocks = BLOCKS.to_h do |key, data|
        neighborhood_id = place[:households].fetch(data[:neighborhood_of]).latest_version.neighborhood_id
        block = CityBlock.where(neighborhood_id: neighborhood_id).find_by("lower(number) = lower(?)", data[:number])
        block ||= check!(VectorControl::SaveBlock.call(params: { "neighborhood_id" => neighborhood_id, "number" => data[:number] }, by: coordinator),
                         "quarteirão #{data[:number]}").payload[:block]
        [ key, block ]
      end
      NEIGHBORS.each do |one, other|
        check!(VectorControl::LinkNeighbor.add(block: blocks.fetch(one), neighbor_block_id: blocks.fetch(other).id, by: coordinator),
               "vizinho #{one}–#{other}")
      end
      PROFILES.group_by { |_, data| data[:block] }.each do |block_key, rows|
        ids = rows.map { |key, _| place[:households].fetch(key).id }
                  .reject { |id| HouseholdVectorProfile.where(household_id: id).where.not(city_block_id: nil).exists? }
        next if ids.empty?

        check!(VectorControl::AssignBlock.call(household_ids: ids, city_block_id: blocks.fetch(block_key).id, by: coordinator), "quarteirão #{block_key}")
      end
      PROFILES.each do |key, data|
        household = place[:households].fetch(key)
        next if data[:risk].nil? || HouseholdVectorProfile.find_by(household_id: household.id)&.risk_class

        check!(VectorControl::SaveProfile.call(household: household, params: { "risk_class" => data[:risk] }, by: coordinator), "risco de #{key}")
      end
      blocks
    end

    # O ciclo de trabalho bimestral de hoje, se nenhum cruza o bimestre.
    def work_cycle!(coordinator)
      today = Time.zone.today
      number = (today.month + 1) / 2
      starts_on = Date.new(today.year, (number * 2) - 1, 1)
      ends_on = starts_on.next_month.end_of_month
      return if VectorCycle.where("starts_on <= ? AND ends_on >= ?", ends_on, starts_on).exists?

      params = { "year" => today.year, "number" => number, "starts_on" => starts_on.iso8601, "ends_on" => ends_on.iso8601 }
      check!(VectorControl::SaveCycle.call(params: params, by: coordinator), "ciclo #{number}/#{today.year}")
    end

    # --- visitas com boletim ----------------------------------------------------

    # A visita do ACE pelo caminho real (HomeVisits::Record com o boletim). O
    # client_uuid fixo devolve a gravada (replayed) sem conferir de novo.
    def visit!(slug, key, ace, team, household, time, report, usable:, family: nil, outcome: 1)
      params = { "client_uuid" => client_uuid(slug, "home_visit", key), "team_id" => team.id, "occurred_at" => time.change(usec: 0).iso8601,
                 "household_id" => household.id, "outcome" => outcome, "reasons" => [], "shared" => false, "vector_inspection" => report }
      params.merge!(family ? { "subject" => "family_responsible", "family_id" => family.id } : { "subject" => "none" })
      check!(HomeVisits::Record.call(params: params, by: ace, vector_control: usable), "visita #{key}").payload[:visit]
    end

    def family_of(household, responsible) = Family.active_families.find_by!(household_id: household.id, responsible_patient_id: responsible.id)

    def today_at(ago)
      now = Time.current
      [ now - ago, now.beginning_of_day ].max
    end

    # Roteiro 1–3: LI completo na R. das Acácias (vermelho) há 10 dias, com a
    # baixa do piriproxifeno e a amostra; vence na cadência de 7 dias.
    def overdue!(slug, place, ace, usable)
      day = [ Time.zone.today - OVERDUE_DAYS, HomeVisits::Rules.min_date(Time.zone.today) ].max
      time = day.in_time_zone.change(hour: 9, min: 30)
      household = place[:households].fetch(:acacias)
      product = VectorProduct.find_by!(code: PRODUCTS.dig(:pyriproxyfen, "code"))
      report = { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => true,
                 "entered_at" => (time - 12.minutes).iso8601, "left_at" => (time + 18.minutes).iso8601,
                 "deposits" => [ { "group" => "A2", "existing" => 4, "with_water" => 3, "with_larvae" => 1, "eliminated" => 2, "treated" => 1 } ],
                 "measures" => [ { "method" => "mechanical" }, { "method" => "focal", "vector_product_id" => product.id, "charges" => 2 } ],
                 "samples" => [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 6 } ] }
      visit!(slug, :overdue_li, ace, place[:team], household, time, report, usable: usable,
             family: family_of(household, place[:people].fetch(:jose)))
    end

    # Roteiro 3: a borracharia (PE) fechada há 2 dias — fica na pendência.
    def closed_point!(slug, place, ace, usable)
      time = (Time.zone.today - CLOSED_DAYS).in_time_zone.change(hour: 14, min: 10)
      report = { "activity" => "pe", "work_type" => "routine", "situation" => "closed", "educational_action" => false }
      visit!(slug, :closed_pe, ace, place[:team], place[:households].fetch(:borracharia), time, report, usable: usable, outcome: 3)
    end

    # As folhas do ACE de dias passados fecham pelo dono (a ficha 8 nasce no
    # fechamento, se a exportação estiver utilizável); a de hoje fica aberta.
    def close_past_sheets!(ace, team)
      HomeVisitDay.where(professional: ace.professional, team: team).where("day < ?", Time.zone.today).order(:day, :sequence).each do |sheet|
        next unless sheet.open?

        check!(HomeVisits::CloseDay.call(sheet, by: ace, closed_by: "user"), "fechamento da folha")
      end
    end

    # --- ovitrampas -------------------------------------------------------------

    # Instala há 4 semanas e, a partir da instalação gravada, coleta cada
    # semana vencida (reinstalando) e conta a palheta. -> nada
    def ovitraps!(slug, place, staff)
      installed_on = Time.zone.today - (OVITRAPS.values.first[:eggs].size * OVITRAP_DAYS)
      OVITRAPS.each do |number, data|
        params = { "client_uuid" => client_uuid(slug, "ovitrap", number), "household_id" => place[:households].fetch(data[:household]).id,
                   "number" => number, "consent" => true, "installed_on" => installed_on.iso8601 }
        ovitrap = check!(VectorControl::InstallOvitrap.call(params: params, by: staff[:ace]), "ovitrampa #{number}").payload[:ovitrap]
        data[:eggs].each_with_index do |eggs, week|
          reading_on = ovitrap.installed_on + (week * OVITRAP_DAYS)
          collected_on = reading_on + OVITRAP_DAYS
          break if collected_on > Time.zone.today

          reading = ovitrap.readings.find_by(installed_on: reading_on)
          break unless reading

          if reading.collected_on.nil?
            collect = { "collected_on" => collected_on.iso8601, "condition" => "ok", "reinstall" => true }
            check!(VectorControl::CollectOvitrap.call(ovitrap: ovitrap.reload, params: collect, by: staff[:ace]), "coleta da #{number}")
            reading.reload
          end
          next unless reading.condition == "ok" && reading.egg_count.nil?

          check!(VectorControl::CountReading.call(reading: reading, egg_count: eggs, note: nil, by: staff[:lab]), "contagem da #{number}")
        end
      end
    end

    # --- LIRAa ------------------------------------------------------------------

    # Levantamento census no quarteirão 002, sorteado; a visita LIRAa no 1180
    # (com amostra, sem resultado) deixa o 1236 pending. -> LiraaSurvey
    def liraa!(slug, place, blocks, staff, usable)
      today = Time.zone.today
      survey = LiraaSurvey.find_by(name: LIRAA[:name])
      unless survey
        params = { "name" => LIRAA[:name], "starts_on" => (today - 1).iso8601, "ends_on" => (today + 5).iso8601,
                   "strata" => [ { "name" => LIRAA[:stratum], "mode" => "census", "block_ids" => LIRAA[:blocks].map { |key| blocks.fetch(key).id } } ] }
        survey = check!(VectorControl::Liraa::SaveSurvey.call(params: params, by: staff[:coordinator]), "LIRAa").payload[:survey]
      end
      check!(VectorControl::Liraa::Draw.call(survey: survey, by: staff[:coordinator]), "sorteio do LIRAa") if survey.status == "draft"

      household = place[:households].fetch(LIRAA[:household])
      item = LiraaDrawItem.joins(:liraa_stratum).find_by(liraa_strata: { liraa_survey_id: survey.id }, household_id: household.id)
      if item&.status == "pending" && survey.reload.status == "drawn"
        report = { "activity" => "liraa", "liraa_draw_item_id" => item.id, "work_type" => "routine", "situation" => "worked",
                   "educational_action" => true,
                   "deposits" => [ { "group" => "B", "existing" => 3, "with_water" => 2, "with_larvae" => 1, "eliminated" => 1, "treated" => 0 },
                                   { "group" => "D2", "existing" => 2, "with_water" => 1, "with_larvae" => 0, "eliminated" => 2, "treated" => 0 } ],
                   "measures" => [ { "method" => "mechanical" } ],
                   "samples" => [ { "number" => 1, "deposit_group" => "B", "larvae_collected" => 4 } ] }
        visit!(slug, :liraa, staff[:ace], place[:team], household, today_at(3.hours), report, usable: usable,
               family: family_of(household, place[:people].fetch(:sebastiao)))
      end
      survey.reload
    end

    # --- bloqueio de transmissão ------------------------------------------------

    # Dengue da Daniela (R. Pedro Gusso, quarteirão 014) pela vigilante; o
    # consumidor do 35a roda inline (como a fila faria) e propõe o bloqueio; a
    # coordenação confirma no anel do centro e grava o 1º ciclo de UBV.
    # -> TransmissionBlock
    def transmission_block!(place, staff)
      today = Time.zone.today
      patient = place[:people].fetch(DENGUE[:patient])
      notification = DiseaseNotification.where(patient_id: patient.id, disease_code: "dengue").order(:created_at, :id).last
      notification ||= check!(Surveillance::CreateNotification.call(
        patient: patient, disease: Surveillance::Diseases.find("dengue"), origin: "manual", unit: place[:unit],
        suspected_at: (today - DENGUE[:suspected_days]).in_time_zone, symptoms_on: today - DENGUE[:symptoms_days], by: place[:officer]
      ), "notificação de dengue").payload[:notification]

      propose!(notification) unless TransmissionBlockCase.exists?(disease_notification_id: notification.id)
      block = TransmissionBlockCase.find_by!(disease_notification_id: notification.id).transmission_block
      if block.status == "proposed"
        ring = VectorControl::Rings.around([ block.center_block_id ], rings: VectorControl::Parameters.current.values.fetch("block_radius_rings"))
        check!(VectorControl::Blocks::Confirm.call(block: block, center_block_id: block.center_block_id, block_ids: ring,
                                                   seen_case_ids: block.cases.pluck(:id), by: staff[:coordinator]), "confirmação do bloqueio")
      end
      block.reload
      if block.status == "active" && block.cycles.none?
        check!(VectorControl::Blocks::AddCycle.call(block: block, starts_on: (today - 1).iso8601, ends_on: (today + 3).iso8601, by: staff[:coordinator]),
               "ciclo de UBV")
      end
      block.reload
    end

    # O VectorControl::ProposeBlockJob sobre o evento da notificação, inline
    # (perform_now: o job lê o gate e abre a cidade pelo slug; nunca atribui
    # Current.city). Se a fila do dev já o consumiu (dedup), a proposta é a
    # mesma do comando que ele chama, idempotente sob a trava do bloqueio.
    def propose!(notification)
      event = DomainEvent.where(name: "disease_notification.created").where("payload->>'notification_id' = ?", notification.id)
                         .order(:occurred_at, :created_at).last
      if event
        VectorControl::ProposeBlockJob.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
      end
      return if TransmissionBlockCase.exists?(disease_notification_id: notification.id)

      VectorControl::Blocks::Propose.call(notification: notification.reload, parameters: VectorControl::Parameters.current.values)
    end

    # Roteiro 2 e 6: a visita de bloqueio na casa da Daniela, com o espinosade
    # acima do saldo do lote — a falta insufficient_balance fica para conciliar.
    def block_visit!(slug, place, block, ace, usable)
      return unless block.status == "active"

      household = place[:households].fetch(:pedro_gusso)
      product = VectorProduct.find_by!(code: PRODUCTS.dig(:spinosad, "code"))
      report = { "activity" => "transmission_block", "transmission_block_id" => block.id, "work_type" => "routine", "situation" => "worked",
                 "educational_action" => true,
                 "deposits" => [ { "group" => "A2", "existing" => 2, "with_water" => 2, "with_larvae" => 1, "eliminated" => 0, "treated" => 1 } ],
                 "measures" => [ { "method" => "focal", "vector_product_id" => product.id, "charges" => 3 } ] }
      visit!(slug, :transmission_block, ace, place[:team], household, today_at(1.hour), report, usable: usable,
             family: family_of(household, place[:people].fetch(DENGUE[:patient])))
    end

    # --- resumo -----------------------------------------------------------------

    def summary(city, place, staff, location, blocks, survey, block)
      households = Household.where(micro_area: place[:areas].values)
      lots = StockLot.where(vector_product_id: VectorProduct.select(:id))
      balances = Pharmacy::Ledger.balances(location_id: location.id, lot_ids: lots.pluck(:id))
      items = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: survey.id }).pluck(:status)
      { switch: VectorControl::Gate.usable?(city) ? "ligado (vector_control)" : "ligado, não utilizável",
        team: place[:team].name, micro_areas: place[:areas].values.map { |area| "#{area.code} #{area.name}" },
        unit: location.health_unit.name, products: VectorProduct.count, lots: balances.values.count(&:positive?),
        blocks: blocks.size, profiles: HouseholdVectorProfile.where(household_id: households.select(:id)).count,
        strategic_points: households.to_a.count { |household| household.latest_version.property_type == VectorControl::Catalog::PE_PROPERTY },
        ovitraps: Ovitrap.active_ovitraps.map { |ovitrap| "#{ovitrap.number} #{ovitrap.readings.where.not(egg_count: nil).count} contadas" }.sort.join(", "),
        tasks: VectorTask.open_tasks.count,
        liraa: "#{survey.status} (census): #{items.count('inspected')}/#{items.size} inspecionados",
        block: "#{block.status}, #{block.cycles.count} ciclo(s), #{block.cases.count} caso(s)",
        shortfalls: VectorStockShortfall.open_shortfalls.count,
        users: [ { email: staff[:ace].email_address, role: "health_professional (ACE #{ACE[:cbo]})", otpauth_uri: SignatureCrew.otpauth_uri(staff[:ace]) },
                 *STAFF.keys.map do |key|
                   { email: staff[key].email_address, role: STAFF[key][:role], otpauth_uri: SignatureCrew.otpauth_uri(staff[key]) }
                 end ] }
    end
  end
end
