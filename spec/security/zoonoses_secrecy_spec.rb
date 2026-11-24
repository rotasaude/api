require "rails_helper"
require "prism"

# Módulo 35b (ADR 0054; contrato §2, §4, §5, §16; Q12, Q13, Q15, Q26, Q33;
# plano, Task 19): o sigilo do centro de zoonoses de ponta a ponta. Um cenário
# completo pelas rotas reais:
# - coordenação: domínios, parâmetros (PUT com step-up), campanha (criar,
#   editar, abrir, fechar), inquérito de leishmaniose (sugestão, criar,
#   editar, abrir, fechar) e os seis relatórios em JSON e CSV;
# - wpda: a solicitação identificada do escorpião com o endereço do local
#   marcado (lista e detalhe do cidadão) e a denúncia anônima do morcego;
# - 25: a notificação de acidente com animal (o paciente marcado; o bloco do
#   animal com o nome e o telefone do tutor e o endereço marcados) e o
#   consumidor que abre a observação;
# - equipe: busca do tutor e do adotante, o animal com tutor e microchip, o
#   gato comunitário, as três buscas, o detalhe (com e sem tutor) e a edição;
#   posto fixo com evento adverso, rotina e anulação; coleira e retirada;
#   coleta, DPP, ELISA e desfecho; a demanda do escorpião do começo ao fim
#   (fila, detalhe, agendar, vistoriar, prorrogar, fechar) e o detalhe da
#   anônima; a observação (fila, detalhe, contato, ligação e fechamento); o
#   canil (duas entradas, adoção e saída por eutanásia) e o histórico;
# - veterinária: castração e eutanásia com step-up;
# - 33: a caixa e o detalhe da equipe da ouvidoria e o inbox do ponto da UVZ;
# - app: o lote do ACE (animal, dose, coleta e coleira) e o download;
# - quatro recusas forçadas: subtipo com o gate desligado, nota curta, ELISA
#   sem DPP e eutanásia pela equipe.
# Depois, as provas de ausência: eventos (⊂ os 22 do §16 + a falta do 35a +
# clinical_record.viewed + os do 33; cada payload só com ids), as trilhas
# (uma por leitura, e nenhuma leitura do /zoonoses publica
# clinical_record.viewed além do person_lookup), log, respostas (microchip em
# nenhuma; tutor só no detalhe do animal, na busca de pessoa e no download;
# contato só na rota do contato; place_address só no detalhe da demanda e no
# da equipe da ouvidoria, Q33; o paciente da notificação em nenhuma) e
# recusas. Fora do cenário: a query de toda rota de /zoonoses, a varredura de
# fonte de DomainEvents.publish e a de Platform.audit.
#
# Constantes do cenário num módulo próprio: dentro de um bloco do RSpec elas
# cairiam em Object e colidiriam com as de outros specs na suíte. Tudo ASCII:
# a varredura compara bytes sem caixa, e o JSON não escapa nada. Cada palavra
# dos nomes e dos endereços é única, para a varredura também pegar o nome
# partido ou só o sobrenome.
module ZoonosesSecrecy
  # O tutor do animal (com cadastro individual no domicílio do ACE), o
  # adotante, o paciente da notificação do 25 e o cidadão da wpda.
  TUTOR = { full_name: "Gumercinda Xavantina Pedralva", mother_name: "Rosalvina Olimpiade Pedralva" }.freeze
  ADOPTER = { full_name: "Hermenegildo Brontaleu Sarrafeiro", mother_name: "Zuleide Prestana Sarrafeiro" }.freeze
  VICTIM = { full_name: "Leocadia Furtunata Mazzaropi", mother_name: "Eufrosina Clotilde Mazzaropi" }.freeze
  CITIZEN = { full_name: "Teodolinda Varzeana Quixotesca", phone: "+5541988771234" }.freeze
  # O bloco do animal da ficha do 25: só na rota do contato.
  CONTACT = { name: "Anacleto Borginho Vimaranes", phone: "41987650432", address: "Travessa Quintilhana, 55, fundos" }.freeze
  # O lugar da ocorrência (Q15): só no detalhe da demanda e no da equipe da ouvidoria (Q33).
  PLACE = "Rua Escorpiolandia Sigilosa, 404, terreno baldio".freeze
  ANONYMOUS_PLACE = "Beco Morcegueira Oculta, 12, forro da escola".freeze
  REFUSED_PLACE = "Viela Carrapateira Recusada, 8, canteiro".freeze
  PLACES = [ PLACE, ANONYMOUS_PLACE, REFUSED_PLACE ].freeze
  # O microchip do animal do dashboard e o do animal do app: em resposta nenhuma.
  MICROCHIPS = %w[985117700112233 985117700445566].freeze
  # As palavras soltas: nomes, sobrenomes e os logradouros.
  TUTOR_WORDS = %w[Gumercinda Xavantina Pedralva Rosalvina Olimpiade].freeze
  ADOPTER_WORDS = %w[Hermenegildo Brontaleu Sarrafeiro Zuleide Prestana].freeze
  VICTIM_WORDS = %w[Leocadia Furtunata Mazzaropi Eufrosina Clotilde].freeze
  CITIZEN_WORDS = %w[Teodolinda Varzeana Quixotesca].freeze
  CONTACT_WORDS = %w[Anacleto Borginho Vimaranes Quintilhana].freeze
  PLACE_WORDS = %w[Escorpiolandia Morcegueira Carrapateira].freeze
  TEXTS = {
    scorpion_body: "Reservado Z1: escorpioes amarelos saindo do ralo da cozinha toda noite",
    anonymous_body: "Reservado Z2: morcego caido no patio da escola vizinha ainda vivo",
    refused_body: "Reservado Z3: carrapatos no canteiro da praca do portao quebrado",
    adverse_note: "Reservado Z4: edema no ponto da aplicacao da dose",
    cancel_reason: "Reservado Z5: dose lancada no animal errado",
    inspection_note: "Reservado Z6: ninho de escorpioes no muro dos fundos",
    extend_reason: "Reservado Z7: vistoria depende do dono do terreno vizinho",
    close_text: "Reservado Z8: muro dedetizado e familia orientada sobre a limpeza",
    outcome_note: "Reservado Z9: cao saudavel ao fim dos dez dias",
    euthanasia_note: "Reservado ZA: sofrimento intenso sem tratamento possivel",
    leish_note: "Reservado ZB: tutora aceitou o tratamento com miltefosina"
  }.freeze
  SHORT_NOTE = "Curta7 ok".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  UUID_IN_PATH = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  # §16 e Q26: os 22 eventos do módulo e as chaves exatas de cada payload (só ids).
  PAYLOAD_KEYS = {
    "animal.registered" => %w[animal_id],
    "animal.changed" => %w[animal_id],
    "rabies_campaign.changed" => %w[rabies_campaign_id],
    "rabies_vaccination.recorded" => %w[rabies_vaccination_id],
    "rabies_vaccination.cancelled" => %w[rabies_vaccination_id],
    "zoonoses_demand.opened" => %w[zoonoses_demand_id],
    "zoonoses_demand.changed" => %w[zoonoses_demand_id],
    "bite_observation.opened" => %w[bite_observation_id],
    "bite_observation.closed" => %w[bite_observation_id],
    "bite_observation.contact_viewed" => %w[bite_observation_id user_id],
    "leish_survey.changed" => %w[leish_survey_id],
    "leish_test.recorded" => %w[leish_test_id],
    "leish_dog_outcome.recorded" => %w[leish_dog_outcome_id],
    "collar.placed" => %w[collar_id],
    "collar.removed" => %w[collar_id],
    "shelter_stay.opened" => %w[shelter_stay_id],
    "shelter_stay.closed" => %w[shelter_stay_id],
    "neutering.recorded" => %w[neutering_id],
    "euthanasia.recorded" => %w[euthanasia_id],
    "zoonoses_parameters.changed" => %w[zoonoses_parameter_version_id user_id],
    "animal.viewed" => %w[animal_id user_id],
    "zoonoses_demand.viewed" => %w[zoonoses_demand_id user_id]
  }.freeze
  CONTRACT_EVENTS = PAYLOAD_KEYS.keys.freeze
  # §16: a falta de insumo reaproveita o evento do 35a (só o id).
  SHORTFALL_EVENT = "vector_stock.shortfall_recorded".freeze
  SHORTFALL_KEYS = %w[vector_stock_shortfall_id].freeze
  # Os eventos do 33 que a demanda já publica (registro, encaminhamento, resposta).
  OMBUDSMAN_EVENTS = %w[
    ombudsman.manifestation_received ombudsman.forwarded ombudsman.forwarding_replied ombudsman.concluded
    ombudsman.reopened ombudsman.identity_viewed ombudsman.anonymous_cap_reached
  ].freeze
  ALLOWED_EVENTS = (CONTRACT_EVENTS + [ SHORTFALL_EVENT, "clinical_record.viewed" ] + OMBUDSMAN_EVENTS).freeze
  # As trilhas de domínio (Q26): uma por leitura, na rota dela.
  TRAILS = { "/zoonoses/animals/:id" => "animal.viewed", "/zoonoses/demands/:id" => "zoonoses_demand.viewed",
             "/zoonoses/observations/:id/contact" => "bite_observation.contact_viewed" }.freeze
  # Os prefixos do módulo: um nome com eles fora dos 22 é evento não contratado.
  MODULE_EVENT = /\A(animal|rabies_campaign|rabies_vaccination|zoonoses_demand|bite_observation|leish_survey|leish_test|
                     leish_dog_outcome|collar|shelter_stay|neutering|euthanasia|zoonoses_parameters)\./x
  # As trilhas clinical_record.viewed (24a e o download do 24b): só ids, o access e o person_ref.
  TRAIL_KEYS = %w[access user_id patient_id patient_ids household_id household_ids micro_area_id field_device_id reason_code
                  person_ref].freeze
  # As chaves do corpo que o "Parameters:" do log mostra como [FILTERED].
  LOGGED_KEYS = %w[tutor_patient_id adopter_patient_id microchip place_address body adverse_note reason inspection_note text
                   outcome_note reason_note note cpf].freeze
  # As rotas de lista (e a busca, pelo corpo): nunca tutor, contato, microchip nem place_address.
  LIST_ROUTES = [
    [ :post, "/zoonoses/animals/search" ], [ :get, "/zoonoses/campaigns" ], [ :get, "/zoonoses/vaccinations" ],
    [ :get, "/zoonoses/demands" ], [ :get, "/zoonoses/shelter_stays" ], [ :get, "/zoonoses/observations" ],
    [ :get, "/zoonoses/leish_surveys" ], [ :get, "/zoonoses/leish_tests" ], [ :get, "/zoonoses/collars" ],
    [ :get, "/ombudsman/manifestations" ], [ :get, "/ombudsman/inbox" ], [ :get, "/citizen/ombudsman/manifestations" ]
  ].freeze
  MODULE_GLOBS = %w[
    app/**/zoonoses/**/*.rb app/controllers/concerns/zoonoses_gate.rb lib/zoonoses_crew.rb
    app/models/{animal,rabies_campaign,rabies_vaccination,zoonoses_demand,zoonoses_parameter_version,bite_observation}.rb
    app/models/{leish_survey,leish_test,leish_dog_outcome,collar,shelter_stay,neutering,euthanasia}.rb
  ].freeze
  # Arquivos de outros módulos com código do 35b (registro e encaminhamento do
  # 33, envio e download do app): nome de evento sem resolver, splat ou
  # Platform.audit neles também falha.
  SHARED_FILES = %w[
    app/commands/ombudsman/register.rb app/commands/ombudsman/register_anonymous.rb app/commands/ombudsman/forward.rb
    app/services/ombudsman/forwardings.rb app/services/field_sync/upload.rb app/services/field_sync/changes.rb
  ].freeze

  def self.cpf_forms(cpf) = [ cpf, "#{cpf[0, 3]}.#{cpf[3, 3]}.#{cpf[6, 3]}-#{cpf[9, 2]}" ]
  def self.phone_forms(phone) = [ phone, phone.delete_prefix("+"), phone.delete_prefix("+55") ]

  # A rota da resposta com os UUIDs no lugar de :id.
  def self.route(path) = path.gsub(UUID_IN_PATH, ":id")

  def self.haystack(raw) = raw.to_s.b.downcase
  def self.contains?(haystack, secret) = haystack.include?(secret.to_s.b.downcase)
end

RSpec.describe "Sigilo do centro de zoonoses (35b)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Método, e não let: o cenário roda no seed_once (before(:context)).
  def secrecy = ZoonosesSecrecy

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }
  after { travel_back }

  # A linha da cidade de teste no Current, com bloco (nunca Current.city
  # solto): a requisição reseta o Current ao fim, e o preparo entre
  # requisições (interruptor, notificação) lê a cidade.
  def in_city(&) = Current.set(city: City.find_by!(slug: TEST_CITY_A.slug), &)

  def zoonoses_gate!(enabled)
    Platform::Features.set!(city: City.find_by!(slug: TEST_CITY_A.slug), key: Zoonoses::Gate::KEY, enabled: enabled,
                            maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  def marked_patient!(names)
    n = registry_seq!
    Patient.create!(cpf: valid_cpf(n), cns: valid_cns(n), full_name: names[:full_name], mother_name: names[:mother_name],
                    birth_date: (Time.zone.today - 40.years - n.days).iso8601, sex: "female", race_color: "03")
  end

  # Cenário completo pelas rotas, com o log capturado, toda resposta guardada
  # (rota, status, corpo e os eventos publicados por ela) e as recusas forçadas.
  def secrecy_scenario!
    s = secrecy
    texts = s::TEXTS
    zoonoses_city!
    ombudsman_city!(anonymous: true)
    Surveillance::DiseaseList::Load.call unless Surveillance::Diseases.find(Zoonoses::Catalog::OBSERVATION_DISEASE)
    today = Time.zone.today

    uvz = uvz_unit!
    team_user = zoonoses_team!
    coordinator = zoonoses_coordinator!
    vet = veterinarian!(unit: uvz)
    field_team = registry_team!
    ace = endemic_agent!(team: field_team)
    ace_area = MicroAreaFieldAssignment.active.find_by!(professional_id: ace.professional.id).micro_area
    neighborhood = Neighborhood.create!(name: "Bairro Sigilo Zoonoses #{SecureRandom.hex(2)}", source: "manual")
    block = city_block!(neighborhood: neighborhood, number: "035")
    home = registry_household!(micro_area: ace_area).tap { vector_profile!(_1, block: block) }

    tutor = marked_patient!(s::TUTOR)
    registry_registration!(patient: tutor, household: home)
    adopter = marked_patient!(s::ADOPTER)
    victim = marked_patient!(s::VICTIM)
    citizen = web_citizen!(phone: s::CITIZEN[:phone], full_name: s::CITIZEN[:full_name])
    vaccine = zoonoses_product!(code: "RABSIG")
    collar_product = zoonoses_product!(use: "collar", code: "COLSIG")
    tech = ombudsman_staff!
    uvz_responder = responder!(uvz)
    officer = surveillance_officer!
    device_token = FieldDevices::Register.call(user: ace, name: "Tablet do ACE").payload.fetch(:token)

    responses = []
    refusals = []
    send_request = lambda do |verb, path, payload, headers|
      before = DomainEvent.pluck(:id)
      if verb == :get
        get(path, headers: headers)
      else
        public_send(verb, path, params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers))
      end
      published = DomainEvent.where.not(id: before).order(:occurred_at, :created_at).to_a
      responses << { verb: verb, path: request.path, route: s.route(request.path), status: response.status, raw: response.body.dup,
                     haystack: s.haystack(response.body), media_type: response.media_type, events: published,
                     cache_control: response.headers["Cache-Control"] }
    end
    req = lambda do |verb, path, payload = {}, headers: {}|
      send_request.(verb, path, payload, headers)
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.media_type == "application/json" && response.body.present? ? JSON.parse(response.body) : response.body
    end
    refuse = lambda do |label, path, payload, status:, sent:, verb: :post|
      send_request.(verb, path, payload, {})
      raise "#{label}: #{path} → #{response.status} #{response.body}" unless response.status == status

      refusals << { label: label, status: response.status, raw: response.body, json: JSON.parse(response.body), sent: Array(sent) }
    end
    ids = {}
    setup_events = []
    setup_platform_events = 0
    # Preparo no meio do cenário (interruptor, notificação): os eventos dele não são do 35b.
    setup = lambda do |&work|
      before = DomainEvent.pluck(:id)
      platform_before = PlatformEvent.count
      result = in_city(&work)
      setup_events.concat(DomainEvent.pluck(:id) - before)
      setup_platform_events += PlatformEvent.count - platform_before
      result
    end
    z = "/zoonoses"
    bearer = { "Authorization" => "Bearer #{device_token}" }
    started_at = Time.current
    platform_events_before = PlatformEvent.count

    log = capture_log do
      # Coordenação: domínios, parâmetros, campanha e inquérito.
      stepped_up!(coordinator)
      req.(:get, "#{z}/domains")
      read = req.(:get, "#{z}/parameters")
      req.(:put, "#{z}/parameters", { values: read.fetch("values").merge("dog_population_estimate" => 1200, "cat_population_estimate" => 400),
                                     expected_version: read.fetch("version") })
      campaign = req.(:post, "#{z}/campaigns", { name: "Campanha Sigilo", starts_on: (today - 5).iso8601, ends_on: (today + 20).iso8601,
                                                goal_dogs: 10, goal_cats: 5 })
      ids[:campaign] = campaign.fetch("id")
      req.(:patch, "#{z}/campaigns/#{ids[:campaign]}", { name: "Campanha Sigilo 2026", expected_version: campaign.fetch("version") })
      req.(:post, "#{z}/campaigns/#{ids[:campaign]}/open", {})
      req.(:get, "#{z}/campaigns")
      req.(:post, "#{z}/leish_surveys/suggest", { kind: "sample", neighborhood_id: neighborhood.id })
      survey = req.(:post, "#{z}/leish_surveys", { name: "Inquerito Sigilo", kind: "sample", neighborhood_id: neighborhood.id,
                                                  city_block_ids: [ block.id ], dog_population: 600, starts_on: (today - 1).iso8601,
                                                  ends_on: (today + 60).iso8601 })
      ids[:survey] = survey.fetch("id")
      survey = req.(:patch, "#{z}/leish_surveys/#{ids[:survey]}", { dog_population: 650, expected_version: survey.fetch("version") })
      survey = req.(:post, "#{z}/leish_surveys/#{ids[:survey]}/open", { expected_version: survey.fetch("version") })
      req.(:get, "#{z}/leish_surveys")
      req.(:get, "#{z}/leish_surveys/#{ids[:survey]}")

      # wpda: a solicitação identificada do escorpião e a denúncia anônima do
      # morcego; a lista e o detalhe do cidadão. A recusa: subtipo com o
      # zoonoses desligado.
      sign_in_citizen(s::CITIZEN[:phone])
      ids[:scorpion_manifestation] = req.(:post, "/citizen/ombudsman/manifestations",
                                          { citizen_id: citizen.id, kind: "request", identification_mode: "identified",
                                            body: texts[:scorpion_body], zoonoses_subtype: "scorpion", place_address: s::PLACE }).fetch("id")
      req.(:get, "/citizen/ombudsman/manifestations")
      req.(:get, "/citizen/ombudsman/manifestations/#{ids[:scorpion_manifestation]}")
      req.(:post, "/citizen/ombudsman/anonymous_reports", { body: texts[:anonymous_body], zoonoses_subtype: "bat",
                                                           place_address: s::ANONYMOUS_PLACE })
      setup.call { zoonoses_gate!(false) }
      refuse.(:subtype_gate_off, "/citizen/ombudsman/anonymous_reports",
              { body: texts[:refused_body], zoonoses_subtype: "tick", place_address: s::REFUSED_PLACE }, status: 422,
              sent: [ texts[:refused_body], s::REFUSED_PLACE ])
      setup.call { zoonoses_gate!(true) }
      ids[:demands] = ZoonosesDemand.order(:created_at).pluck(:id)
      ids[:scorpion_demand], ids[:anonymous_demand] = ids[:demands]

      # 25: a notificação de acidente com animal (o paciente marcado; o bloco
      # do animal com o contato marcado) e o consumidor do 35b.
      notification = setup.call do
        created = notification!(patient: victim, disease_code: Zoonoses::Catalog::OBSERVATION_DISEASE, by: officer)
        form = created.form.merge("animal_species" => "dog", "animal_condition" => "suspect", "animal_observable" => "true",
                                  "exposure_on" => (today - 12).iso8601, "animal_tutor_name" => s::CONTACT[:name],
                                  "animal_tutor_phone" => s::CONTACT[:phone], "animal_address" => s::CONTACT[:address])
        saved = Surveillance::SaveForm.call(notification: created, form: form, version: created.version, by: officer)
        raise "ficha recusada: #{saved.reason} #{saved.details}" if saved.failure?

        created.reload
      end
      ids[:notification] = notification.id
      event = DomainEvent.where(name: "disease_notification.updated").where("payload->>'notification_id' = ?", notification.id)
                         .order(:occurred_at, :created_at).last
      Zoonoses::OpenObservationJob.perform_now(event_id: event.id, event_name: event.name, city_slug: TEST_CITY_A.slug, payload: event.payload)
      ids[:observation] = BiteObservation.find_by!(disease_notification_id: notification.id).id

      # Equipe: busca de pessoa, animais, buscas, detalhes e edição.
      sign_in_as(team_user)
      req.(:get, "#{z}/domains")
      ids[:tutor_lookup] = req.(:post, "#{z}/person_lookup", { cpf: tutor.cpf })
      ids[:adopter_lookup] = req.(:post, "#{z}/person_lookup", { cpf: adopter.cpf })
      dog = req.(:post, "#{z}/animals", { species: "dog", sex: "female", name: "Pipoca", coat: "Caramelo", microchip: s::MICROCHIPS[0],
                                         registry_number: "UVZ-SIG-1", household_id: home.id, tutor_patient_id: tutor.id,
                                         community: false })
      ids[:dog] = dog.fetch("id")
      ids[:cat] = req.(:post, "#{z}/animals", { species: "cat", sex: "female", community: true }).fetch("id")
      req.(:post, "#{z}/animals/search", { microchip: s::MICROCHIPS[0] })
      req.(:post, "#{z}/animals/search", { tutor_patient_id: tutor.id })
      req.(:post, "#{z}/animals/search", { household_id: home.id })
      req.(:get, "#{z}/animals/#{ids[:dog]}")
      req.(:get, "#{z}/animals/#{ids[:cat]}")
      req.(:patch, "#{z}/animals/#{ids[:dog]}", { coat: "Caramelo claro", expected_version: dog.fetch("version") })

      # Vacinação: posto fixo com evento adverso, rotina, nota curta e anulação.
      req.(:post, "#{z}/vaccinations", { modality: "fixed_post", campaign_id: ids[:campaign], animal_id: ids[:dog],
                                        vaccinated_on: today.iso8601, vector_product_id: vaccine.id, adverse_event: true,
                                        adverse_note: texts[:adverse_note] })
      routine = req.(:post, "#{z}/vaccinations", { modality: "routine", animal_id: ids[:cat], vaccinated_on: today.iso8601,
                                                  vector_product_id: vaccine.id, adverse_event: false })
      refuse.(:short_note, "#{z}/vaccinations/#{routine.fetch('id')}/cancel", { reason: s::SHORT_NOTE }, status: 422, sent: s::SHORT_NOTE)
      req.(:post, "#{z}/vaccinations/#{routine.fetch('id')}/cancel", { reason: texts[:cancel_reason] })
      req.(:get, "#{z}/vaccinations?campaign_id=#{ids[:campaign]}")
      req.(:get, "#{z}/vaccinations?modality=routine")

      # Coleira: colocação, retirada e a lista de vencimento.
      collar = req.(:post, "#{z}/collars", { animal_id: ids[:dog], vector_product_id: collar_product.id, placed_on: today.iso8601 })
      req.(:post, "#{z}/collars/#{collar.fetch('id')}/remove", { reason: "lost" })
      req.(:post, "#{z}/collars", { animal_id: ids[:dog], vector_product_id: collar_product.id, placed_on: today.iso8601 })
      req.(:get, "#{z}/collars?due=1")

      # Leishmaniose: coleta com DPP, ELISA sem DPP recusado, ELISA e desfecho.
      test = req.(:post, "#{z}/leish_tests", { leish_survey_id: ids[:survey], animal_id: ids[:dog], collected_on: today.iso8601,
                                              dpp_result: "reactive", dpp_on: today.iso8601 })
      refuse.(:elisa_without_dpp, "#{z}/leish_tests", { animal_id: ids[:dog], collected_on: today.iso8601, elisa_result: "reactive",
                                                       elisa_on: today.iso8601 }, status: 422, sent: [])
      req.(:patch, "#{z}/leish_tests/#{test.fetch('id')}", { elisa_result: "reactive", elisa_on: today.iso8601, elisa_request: "GAL-SIG-1",
                                                           expected_version: test.fetch("version") })
      req.(:get, "#{z}/leish_tests?pending=outcome")
      req.(:post, "#{z}/leish_outcomes", { leish_test_id: test.fetch("id"), decision: "tutor_treatment", decided_on: today.iso8601,
                                          note: texts[:leish_note] })
      req.(:get, "#{z}/leish_tests?survey_id=#{ids[:survey]}")

      # A demanda do escorpião: fila, detalhe, agendar, vistoriar, prorrogar;
      # o detalhe da anônima; o inbox do ponto da UVZ e as leituras da
      # equipe da ouvidoria antes do fechamento.
      req.(:get, "#{z}/demands")
      demand = req.(:get, "#{z}/demands/#{ids[:scorpion_demand]}")
      demand = req.(:post, "#{z}/demands/#{ids[:scorpion_demand]}/schedule", { scheduled_on: (today + 1).iso8601,
                                                                              expected_version: demand.fetch("version") })
      demand = req.(:post, "#{z}/demands/#{ids[:scorpion_demand]}/inspect", { inspected_on: today.iso8601,
                                                                             inspection_note: texts[:inspection_note],
                                                                             expected_version: demand.fetch("version") })
      demand = req.(:post, "#{z}/demands/#{ids[:scorpion_demand]}/extend", { reason: texts[:extend_reason],
                                                                            expected_version: demand.fetch("version") })
      req.(:get, "#{z}/demands/#{ids[:anonymous_demand]}")
      sign_in_as(uvz_responder)
      req.(:get, "/ombudsman/inbox")
      sign_in_as(tech)
      req.(:get, "/ombudsman/manifestations")
      req.(:get, "/ombudsman/manifestations/#{ids[:scorpion_manifestation]}")
      sign_in_as(team_user)
      req.(:post, "#{z}/demands/#{ids[:scorpion_demand]}/close", { outcome: "resolved", text: texts[:close_text],
                                                                  expected_version: demand.fetch("version") })
      req.(:get, "#{z}/demands?state=closed")

      # A observação do animal agressor: fila, detalhe, contato, ligação e fechamento.
      req.(:get, "#{z}/observations")
      observation = req.(:get, "#{z}/observations/#{ids[:observation]}")
      ids[:contact] = req.(:get, "#{z}/observations/#{ids[:observation]}/contact")
      observation = req.(:post, "#{z}/observations/#{ids[:observation]}/link_animal", { animal_id: ids[:dog],
                                                                                       expected_version: observation.fetch("version") })
      req.(:post, "#{z}/observations/#{ids[:observation]}/close", { outcome: "healthy", outcome_on: today.iso8601,
                                                                   outcome_note: texts[:outcome_note],
                                                                   expected_version: observation.fetch("version") })
      req.(:get, "#{z}/observations?state=closed")

      # Canil: duas entradas de animais novos; a eutanásia pela equipe recusada.
      stray = req.(:post, "#{z}/shelter_stays", { new_animal: { species: "dog", sex: "male" }, health_unit_id: uvz.id,
                                                 entry_kind: "collection" })
      ids[:adopted], ids[:adopted_stay] = stray.dig("animal", "id"), stray.fetch("id")
      stray = req.(:post, "#{z}/shelter_stays", { new_animal: { species: "dog", sex: "female" }, health_unit_id: uvz.id,
                                                 entry_kind: "voluntary_surrender" })
      ids[:euthanized], ids[:euthanized_stay] = stray.dig("animal", "id"), stray.fetch("id")
      req.(:get, "#{z}/shelter_stays?open=1")
      stepped_up!(team_user)
      euthanasia = { animal_id: ids[:euthanized], performed_on: today.iso8601, reason: "untreatable_suffering",
                     reason_note: texts[:euthanasia_note], legal_basis: %w[cfmv_1000_2012], shelter_stay_id: ids[:euthanized_stay] }
      refuse.(:euthanasia_by_team, "#{z}/euthanasias", euthanasia, status: 403, sent: texts[:euthanasia_note])

      # Veterinária: castração e eutanásia (step-up).
      stepped_up!(vet)
      req.(:post, "#{z}/neuterings", { animal_id: ids[:adopted], performed_on: today.iso8601, shelter_stay_id: ids[:adopted_stay] })
      req.(:post, "#{z}/euthanasias", euthanasia)

      # Equipe: a adoção (o adotante da busca de pessoa), a saída por
      # eutanásia, a lista do canil e o histórico do animal com tutor.
      sign_in_as(team_user)
      versions = req.(:get, "#{z}/shelter_stays?open=1").fetch("items").to_h { [ _1.fetch("id"), _1.fetch("version") ] }
      req.(:post, "#{z}/shelter_stays/#{ids[:adopted_stay]}/exit", { exit_kind: "adopted", adopter_patient_id: adopter.id,
                                                                    expected_version: versions.fetch(ids[:adopted_stay]) })
      req.(:post, "#{z}/shelter_stays/#{ids[:euthanized_stay]}/exit", { exit_kind: "euthanasia",
                                                                       expected_version: versions.fetch(ids[:euthanized_stay]) })
      req.(:get, "#{z}/shelter_stays")
      ids[:history] = req.(:get, "#{z}/animals/#{ids[:dog]}")

      # App do ACE: o lote (animal com tutor e microchip, dose, coleta e
      # coleira, citando o animal do lote) e o download.
      req.(:get, "/field/v1/session", headers: bearer)
      app_animal = SecureRandom.uuid
      items = [
        { client_uuid: app_animal, type: "animal",
          body: { household_id: home.id, species: "dog", sex: "male", community: false, name: "Toto", microchip: s::MICROCHIPS[1],
                  tutor_patient_id: tutor.id } },
        { client_uuid: SecureRandom.uuid, type: "rabies_vaccination",
          body: { animal_client_uuid: app_animal, campaign_id: ids[:campaign], vaccinated_on: today.iso8601,
                  vector_product_id: vaccine.id, adverse_event: false } },
        { client_uuid: SecureRandom.uuid, type: "leish_collection",
          body: { leish_survey_id: ids[:survey], animal_client_uuid: app_animal, collected_on: today.iso8601,
                  dpp_result: "non_reactive", dpp_on: today.iso8601 } },
        { client_uuid: SecureRandom.uuid, type: "collar",
          body: { animal_client_uuid: app_animal, vector_product_id: collar_product.id, placed_on: today.iso8601 } }
      ]
      ids[:upload] = req.(:post, "/field/v1/uploads", { items: items }, headers: bearer).fetch("results")
      travel(3.seconds) { ids[:changes] = req.(:get, "/field/v1/changes", headers: bearer) }

      # Coordenação: os fechamentos e os seis relatórios em JSON e CSV.
      stepped_up!(coordinator)
      survey = req.(:get, "#{z}/leish_surveys/#{ids[:survey]}")
      req.(:post, "#{z}/leish_surveys/#{ids[:survey]}/close", { expected_version: survey.fetch("version") })
      req.(:post, "#{z}/campaigns/#{ids[:campaign]}/close", {})
      period = "from=#{(today - 30).iso8601}&to=#{today.iso8601}"
      Zoonoses::Catalog::REPORTS.each do |name|
        ids[:"report_#{name}"] = req.(:get, "#{z}/reports/#{name}?#{period}")
        req.(:get, "#{z}/reports/#{name}.csv?#{period}")
      end
    end

    { ids: ids, log: log, responses: responses, refusals: refusals, started_at: started_at, setup_events: setup_events,
      platform_events: PlatformEvent.count - platform_events_before - setup_platform_events, tutor: tutor, adopter: adopter,
      victim: victim, citizen: citizen, home: home, team_user: team_user, ace: ace }
  end

  describe "cenário" do
    # O cenário roda uma vez por arquivo (api#159); cada exemplo parte do
    # estado que ele deixou e abre a sua própria sessão de requisição. O
    # before(type: :request) do harness não roda aqui: o host vem à mão, e os
    # dublês vivem num escopo temporário (rspec-mocks fora de exemplo).
    seed_once do
      use_test_city_host!
      RSpec::Mocks.with_temporary_scope do
        allow(Ledi::DeliverJob).to receive(:perform_later)
        @scenario = secrecy_scenario!
      end
    ensure
      travel_back
    end
    let(:scenario) { @scenario }
    let(:ids) { scenario[:ids] }
    let(:tutor) { scenario[:tutor] }
    let(:adopter) { scenario[:adopter] }
    let(:victim) { scenario[:victim] }
    let(:responses) { scenario[:responses] }
    let(:events) do
      DomainEvent.where(occurred_at: scenario[:started_at]..).where.not(id: scenario[:setup_events]).order(:occurred_at, :created_at).to_a
    end
    # O que nunca sai em resposta nenhuma: o documento do tutor e do adotante,
    # o paciente da notificação inteiro e a própria notificação.
    # O cadastro individual do tutor (24a: o nome da mãe) só no download do
    # app do ACE do domicílio, que é do 24b (fora do módulo).
    let(:tutor_registration) { [ secrecy::TUTOR[:mother_name] ] }
    let(:never) do
      tutor_registration + secrecy.cpf_forms(tutor.cpf) + [ tutor.cns ] + secrecy.cpf_forms(adopter.cpf) + [ adopter.cns, victim.cns ] +
        secrecy.cpf_forms(victim.cpf) +
        [ victim.id, ids[:notification], secrecy::VICTIM[:full_name], secrecy::VICTIM[:mother_name], secrecy::ADOPTER[:mother_name] ] +
        secrecy::VICTIM_WORDS + secrecy::MICROCHIPS
    end
    def never_in(r) = r[:route] == "/field/v1/changes" ? never - tutor_registration : never
    let(:tutor_marks) { [ secrecy::TUTOR[:full_name], *secrecy::TUTOR_WORDS, tutor.id ] }
    let(:adopter_marks) { [ secrecy::ADOPTER[:full_name], *secrecy::ADOPTER_WORDS, adopter.id ] }
    let(:contact) { secrecy::CONTACT.values + secrecy::CONTACT_WORDS + secrecy.phone_forms("+55#{secrecy::CONTACT[:phone]}") }
    let(:citizen_marks) do
      [ secrecy::CITIZEN[:full_name], *secrecy::CITIZEN_WORDS, *secrecy.phone_forms(secrecy::CITIZEN[:phone]),
        *secrecy.cpf_forms(scenario[:citizen].cpf) ]
    end
    let(:places) { secrecy::PLACES + secrecy::PLACE_WORDS }
    let(:texts) { secrecy::TEXTS.values + [ secrecy::SHORT_NOTE ] }
    let(:people) { never + tutor_marks + adopter_marks + contact + citizen_marks }

    def routed(verb, route) = responses.select { |r| r[:verb] == verb && r[:route] == route }

    it "percorreu o cenário inteiro (controle positivo)" do
      expect(responses.size).to be > 90
      expect(scenario[:refusals].map { |r| r[:label] }).to eq(%i[subtype_gate_off short_note elisa_without_dpp euthanasia_by_team])
      expect(ids[:demands].size).to eq(2)
      expect(ZoonosesDemand.find(ids[:scorpion_demand])).to have_attributes(subtype: "scorpion", state: "closed", outcome: "resolved",
                                                                              inspection_note: secrecy::TEXTS[:inspection_note])
      expect(OmbudsmanManifestation.find(ids[:scorpion_manifestation]).place_address).to eq(secrecy::PLACE)
      expect(BiteObservation.find(ids[:observation])).to have_attributes(state: "closed", animal_id: ids[:dog], outcome: "healthy")
      dog = Animal.find(ids[:dog])
      expect(dog).to have_attributes(tutor_patient_id: tutor.id, microchip: secrecy::MICROCHIPS[0], version: 2)
      expect(Animal.find(ids[:adopted])).to have_attributes(tutor_patient_id: adopter.id, neutered: true)
      expect(Animal.find(ids[:euthanized]).status).to eq("deceased")
      expect(RabiesVaccination.where(animal_id: ids[:cat]).sole.cancel_reason).to eq(secrecy::TEXTS[:cancel_reason])
      expect(LeishDogOutcome.where(animal_id: ids[:dog]).sole.note).to eq(secrecy::TEXTS[:leish_note])
      expect(RabiesCampaign.find(ids[:campaign]).stage).to eq("closed")
      expect(LeishSurvey.find(ids[:survey]).stage).to eq("closed")
      expect(ZoonosesParameterVersion.maximum(:version)).to eq(1)
      expect(ids[:upload].map { |r| [ r["type"], r["status"] ] })
        .to eq([ %w[animal accepted], %w[rabies_vaccination accepted], %w[leish_collection accepted], %w[collar accepted] ])
      expect(Animal.find(ids[:upload].first.fetch("id")).microchip).to eq(secrecy::MICROCHIPS[1])
      expect(VectorStockShortfall.pluck(:source).tally).to include("vaccination" => 3, "collar" => 3)

      # A busca de pessoa: o tutor com o domicílio; o adotante sem.
      expect(ids[:tutor_lookup]).to eq("patient" => { "id" => tutor.id, "display_name" => tutor.display_name },
                                       "household" => { "id" => scenario[:home].id,
                                                        "address_short" => ids[:tutor_lookup].dig("household", "address_short") })
      expect(ids[:adopter_lookup]).to eq("patient" => { "id" => adopter.id, "display_name" => adopter.display_name }, "household" => nil)
      # O contato: a única resposta com ele, sem cache.
      expect(ids[:contact]).to eq("animal_tutor_name" => secrecy::CONTACT[:name], "animal_tutor_phone" => secrecy::CONTACT[:phone],
                                  "animal_address" => secrecy::CONTACT[:address])
      expect(routed(:get, "/zoonoses/observations/:id/contact").sole[:cache_control]).to eq("no-store")
      # O histórico do animal com tutor: o tutor só { id, display_name }, has_microchip sem o número.
      expect(ids[:history]).to include("tutor" => { "id" => tutor.id, "display_name" => tutor.display_name }, "has_microchip" => true)
      expect(ids[:history].keys).not_to include("microchip", "tutor_patient_id")
      expect(ids[:history].values_at("vaccinations", "observations", "tests", "collars").map(&:size)).to eq([ 1, 1, 1, 2 ])
      # O download: os dois cães do domicílio com o tutor só { patient_id, display_name }.
      animals = ids[:changes].fetch("items").select { |item| item["type"] == "animal" }
      expect(animals.map { |item| item["id"] }).to contain_exactly(ids[:dog], ids[:upload].first.fetch("id"))
      expect(animals.map { |item| item.dig("body", "tutor") }.uniq).to eq([ { "patient_id" => tutor.id, "display_name" => tutor.display_name } ])
      expect(animals.map { |item| item.dig("body", "has_microchip") }.uniq).to eq([ true ])
    end

    # §16 e Q26: os eventos do módulo são só os 22, todos publicados no
    # cenário, cada payload só com as chaves dele (ids).
    it "os eventos publicados ⊂ os 22 do §16 + a falta do 35a + clinical_record.viewed + os do 33, cada payload só com ids" do
      expect(Zoonoses::Catalog::DOMAIN_EVENTS).to eq(secrecy::CONTRACT_EVENTS) # §16 na ordem, 21 e 22 no fim (Q26)
      expect(Zoonoses::Catalog::DOMAIN_EVENTS).to include("bite_observation.contact_viewed")
      expect(events.map(&:name).uniq - secrecy::ALLOWED_EVENTS).to be_empty
      expect(events.map(&:name).uniq).to include(*secrecy::CONTRACT_EVENTS, secrecy::SHORTFALL_EVENT) # o cenário passou por todos

      events.each do |event|
        case event.name
        when "clinical_record.viewed"
          expect(event.payload.keys - secrecy::TRAIL_KEYS).to be_empty, "trilha #{event.payload.keys}"
        when secrecy::SHORTFALL_EVENT
          expect(event.payload.keys).to eq(secrecy::SHORTFALL_KEYS)
        when *secrecy::CONTRACT_EVENTS
          expect(event.payload.keys).to match_array(secrecy::PAYLOAD_KEYS.fetch(event.name)), "#{event.name} publica #{event.payload.keys}"
        else next # os do 33 têm o próprio spec de sigilo
        end
        event.payload.each do |key, value|
          case key
          when "access" then expect(value).to be_in([ Zoonoses::Trail::ACCESS, TerritoryRegistry::Trail::ACCESS, HomeVisits::Catalog::FIELD_TRAIL_ACCESS ])
          when "reason_code" then expect(value).to be_nil
          when "person_ref" then expect(value).to eq("patient:#{event.payload['patient_id']}")
          when /_ids\z/ then expect(value).to all(match(secrecy::UUID))
          else expect(value.to_s).to match(secrecy::UUID), "#{event.name}.#{key}"
          end
        end
      end

      payloads = events.map { |e| [ e.name, e.payload ] }.to_json.downcase
      (people - [ tutor.id, adopter.id ] + places + texts).each do |secret|
        expect(payloads).not_to include(secret.downcase), "evento contém #{secret.inspect}"
      end
      # O tutor e o adotante: o id só nas trilhas do 24a/24b (person_ref, patient_ids), nunca num evento do módulo.
      module_payloads = events.select { |e| e.name.match?(secrecy::MODULE_EVENT) }.map(&:payload).to_json
      [ tutor.id, adopter.id ].each { |id| expect(module_payloads).not_to include(id) }
      expect(events.flat_map { |e| e.payload.keys }.grep(/note|\Areason\z|name|cpf|cns|phone|address|microchip|tutor|adopter/)).to be_empty
    end

    # Q26: as três trilhas são eventos de domínio, uma por leitura; nenhuma
    # leitura do /zoonoses publica clinical_record.viewed, salvo a busca de
    # pessoa (a do 24a, com a do domicílio mostrado); o download do app grava a
    # do 24b com o tutor em patient_ids.
    it "as três trilhas, uma por leitura; clinical_record.viewed só na busca de pessoa e no app" do
      reads = responses.select { |r| r[:verb] == :get && r[:route].start_with?("/zoonoses/") }
      expect(reads.size).to be > 25
      reads.each do |r|
        expected =
          case r[:route]
          when "/zoonoses/animals/:id"
            r[:path].end_with?(ids[:dog]) ? [ "animal.viewed" ] : [] # Q26: só com tutor (o gato comunitário não)
          when *secrecy::TRAILS.keys then [ secrecy::TRAILS.fetch(r[:route]) ]
          else []
          end
        expect(r[:events].map(&:name)).to eq(expected), "GET #{r[:route]} publicou #{r[:events].map(&:name)}"
      end
      expect(routed(:get, "/zoonoses/animals/:id").size).to eq(3) # controle: o cão duas vezes, o gato uma

      viewer = scenario[:team_user].id
      expect(events.select { |e| e.name == "animal.viewed" }.map(&:payload))
        .to eq([ { "animal_id" => ids[:dog], "user_id" => viewer } ] * 2)
      expect(events.select { |e| e.name == "zoonoses_demand.viewed" }.map(&:payload))
        .to eq([ ids[:scorpion_demand], ids[:anonymous_demand] ].map { { "zoonoses_demand_id" => _1, "user_id" => viewer } })
      expect(events.select { |e| e.name == "bite_observation.contact_viewed" }.map(&:payload))
        .to eq([ { "bite_observation_id" => ids[:observation], "user_id" => viewer } ])

      # Toda escrita e toda leitura do /zoonoses, fora o person_lookup: sem clinical_record.viewed.
      responses.select { |r| r[:route].start_with?("/zoonoses/") && r[:route] != "/zoonoses/person_lookup" }.each do |r|
        expect(r[:events].map(&:name)).not_to include("clinical_record.viewed"), "#{r[:verb]} #{r[:route]}"
      end
      lookups = routed(:post, "/zoonoses/person_lookup")
      expect(lookups.map { |r| r[:events].map { |e| [ e.payload["access"], e.payload["patient_id"], e.payload["household_id"] ] } })
        .to eq([ [ [ Zoonoses::Trail::ACCESS, tutor.id, nil ], [ TerritoryRegistry::Trail::ACCESS, nil, scenario[:home].id ] ],
                 [ [ Zoonoses::Trail::ACCESS, adopter.id, nil ] ] ])
      # Fora do /zoonoses, a trilha só no app (o download, com o tutor).
      trails = responses.reject { |r| r[:route].start_with?("/zoonoses/") }
                        .flat_map { |r| r[:events].select { |e| e.name == "clinical_record.viewed" }.map { |e| [ r[:route], e ] } }
      expect(trails.map(&:first).uniq).to eq([ "/field/v1/changes" ])
      expect(trails.map(&:last).flat_map { |e| Array(e.payload["patient_ids"]) }).to include(tutor.id)
      expect(trails.map(&:last).map { |e| e.payload["access"] }.uniq).to eq([ HomeVisits::Catalog::FIELD_TRAIL_ACCESS ])
      # E nenhuma trilha fora de requisição (o consumidor do 25 só abre a observação).
      in_requests = responses.flat_map { |r| r[:events].map(&:id) }
      expect(events.reject { |e| in_requests.include?(e.id) }.map(&:name)).to eq([ "bite_observation.opened" ])
    end

    it "o log do cenário não tem tutor, adotante, paciente, contato, telefone, endereço, place_address, microchip nem as notas" do
      log = scenario[:log]
      # Controle: a captura viu as requisições e o filtro agiu.
      expect(log).to include("/zoonoses/animals", "/zoonoses/demands", "/citizen/ombudsman/manifestations", "/field/v1/uploads",
                             "[FILTERED]")
      lowered = log.downcase
      (people - [ tutor.id, adopter.id, victim.id, ids[:notification] ] + places + texts).each do |secret|
        expect(lowered).not_to include(secret.downcase), "log contém #{secret.inspect}"
      end

      # O "Parameters:" da requisição: as chaves de pessoa e de texto filtradas
      # e o id do tutor e do adotante em nenhuma (o SQL só leva o id na linha do bind).
      parameters = log.lines.grep(/Parameters:/)
      expect(parameters.size).to be > 40
      [ tutor.id, adopter.id ].each { |id| expect(parameters.join).not_to include(id), "Parameters: com o id #{id}" }
      logged = parameters.join.scan(/"(#{secrecy::LOGGED_KEYS.join('|')})"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq).to include("tutor_patient_id", "adopter_patient_id", "microchip", "place_address", "body",
                                                  "adverse_note", "reason", "inspection_note", "text", "outcome_note", "reason_note",
                                                  "note", "cpf")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    # §16: o microchip em resposta nenhuma; o documento do tutor e do adotante
    # e o paciente da notificação em resposta nenhuma (JSON e CSV).
    it "nenhuma resposta traz microchip, CPF ou CNS, nem o paciente da notificação" do
      expect(responses.map { |r| r[:media_type] }.uniq).to include("application/json", "text/csv")
      changes = routed(:get, "/field/v1/changes").sole
      expect(secrecy.contains?(changes[:haystack], secrecy::TUTOR[:mother_name])).to be(true) # controle: o cadastro do 24a
      responses.each do |r|
        never_in(r).each { |secret| expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}" }
      end
    end

    # §16 e Q25: o tutor só no detalhe do animal, na busca de pessoa e no
    # download do app (o 24b); o adotante só na busca de pessoa; o contato só
    # na rota do contato; o cidadão da wpda nunca no /zoonoses nem no app.
    it "tutor, adotante, contato e cidadão só nas rotas deles" do
      only = lambda do |marks, allowed|
        found = responses.select { |r| marks.any? { |secret| secrecy.contains?(r[:haystack], secret) } }.map { |r| r[:route] }.uniq
        expect(found).to match_array(allowed), "#{marks.first}: #{found}"
      end
      only.(tutor_marks, [ "/zoonoses/person_lookup", "/zoonoses/animals/:id", "/field/v1/changes" ])
      only.(adopter_marks, [ "/zoonoses/person_lookup" ])
      only.(contact, [ "/zoonoses/observations/:id/contact" ])
      zoonoses = responses.select { |r| r[:route].start_with?("/zoonoses/", "/field/") }
      expect(zoonoses.size).to be > 80
      zoonoses.each do |r|
        citizen_marks.each { |secret| expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:path]} contém #{secret.inspect}" }
      end
      # O detalhe do animal sem tutor (o gato) também não traz o tutor.
      cat = routed(:get, "/zoonoses/animals/:id").find { |r| r[:path].end_with?(ids[:cat]) }
      tutor_marks.each { |secret| expect(secrecy.contains?(cat[:haystack], secret)).to be(false) }
    end

    # Q13, Q15 e Q33: o place_address só no detalhe da demanda e no da equipe
    # da ouvidoria; nunca na lista, no inbox do 33, no JSON do cidadão nem em
    # CSV.
    it "o place_address só no detalhe da demanda e no da equipe da ouvidoria" do
      found = responses.select { |r| places.any? { |secret| secrecy.contains?(r[:haystack], secret) } }.map { |r| r[:route] }.uniq
      expect(found).to contain_exactly("/zoonoses/demands/:id", "/ombudsman/manifestations/:id")
      expect(responses.map { |r| r[:route] }).to include("/ombudsman/inbox", "/citizen/ombudsman/manifestations/:id",
                                                         "/citizen/ombudsman/manifestations", "/zoonoses/reports/demands.csv")
      details = routed(:get, "/zoonoses/demands/:id")
      expect(details.map { |r| JSON.parse(r[:raw])["place_address"] }).to eq([ secrecy::PLACE, secrecy::ANONYMOUS_PLACE ])
      expect(JSON.parse(routed(:get, "/ombudsman/manifestations/:id").sole[:raw])["place_address"]).to eq(secrecy::PLACE)
      # A resposta da escrita da demanda também não (só o detalhe).
      responses.select { |r| r[:verb] == :post && r[:route].start_with?("/zoonoses/demands/") }.each do |r|
        expect(JSON.parse(r[:raw]).keys).not_to include("place_address", "extract")
      end
    end

    it "nenhuma resposta de lista (nem a busca, nem os relatórios) traz tutor, contato, microchip, place_address, o texto ou as notas" do
      lists = responses.select do |r|
        secrecy::LIST_ROUTES.include?([ r[:verb], r[:route] ]) || r[:route].start_with?("/zoonoses/reports/")
      end
      expect(lists.map { |r| r[:route] }.uniq.size).to eq(secrecy::LIST_ROUTES.size + (Zoonoses::Catalog::REPORTS.size * 2))
      # As vistas do 33 seguem as regras do 33: o inbox do ponto e a caixa
      # mostram o extrato, que é o texto do cidadão (Q13); o endereço, nunca (Q33).
      lists.each do |r|
        marks = r[:route].start_with?("/zoonoses/") ? people + places + texts : people - citizen_marks + places
        marks.each do |secret|
          expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}"
        end
      end
      %w[tutor tutor_patient_id adopter_patient_id microchip place_address extract animal_tutor_name].each do |key|
        lists.select { |r| r[:media_type] == "application/json" && r[:route].start_with?("/zoonoses/") }.each do |r|
          expect(r[:raw]).not_to include("\"#{key}\""), "#{r[:path]} traz a chave #{key}"
        end
      end
    end

    it "toda recusa 4xx traz só error e path, sem o valor enviado" do
      expected = {
        subtype_gate_off: %w[invalid_request zoonoses_subtype],
        short_note: %w[invalid_request reason],
        elisa_without_dpp: %w[elisa_without_reactive_dpp elisa_result],
        euthanasia_by_team: [ "veterinarian_required", nil ]
      }
      scenario[:refusals].each do |refusal|
        expect(refusal[:json].values_at("error", "path")).to eq(expected.fetch(refusal[:label])), "#{refusal[:label]}: #{refusal[:json]}"
        refusal[:sent].each do |sent|
          expect(secrecy.contains?(refusal[:raw].downcase, sent)).to be(false), "#{refusal[:label]} ecoa o valor enviado"
        end
      end
      failures = responses.select { |r| r[:status].between?(400, 499) }
      expect(failures.size).to eq(scenario[:refusals].size)
      failures.each do |r|
        json = JSON.parse(r[:raw])
        if r[:route].start_with?("/zoonoses/")
          expect(json.keys - %w[error path]).to be_empty, "#{r[:path]}: #{r[:raw]}"
        else # o formato uniforme do 33: problems só repete error e path
          expect(json.keys - %w[error path problems]).to be_empty, "#{r[:path]}: #{r[:raw]}"
          expect(Array(json["problems"])).to all(eq(json.slice("error", "path")))
        end
        (people + places + texts).each { |secret| expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:path]} contém #{secret.inspect}" }
      end
      # Nenhuma recusa deixou rastro: nem a manifestação do gate desligado, nem a eutanásia da equipe.
      expect(OmbudsmanManifestation.where(place_address: secrecy::REFUSED_PLACE)).to be_empty
      expect(Euthanasia.count).to eq(1)
    end

    it "nenhum Platform.audit durante o cenário" do
      expect(scenario[:platform_events]).to eq(0)
    end
  end
end

# §16 (nunca em URL): toda rota de /zoonoses recusa microchip, cpf e
# place_address na query (422 invalid_request), sem ecoar o valor —
# inclusive as que só leem e as de membro com id que não existe (a query
# antes de qualquer leitura).
RSpec.describe "Sigilo do centro de zoonoses (35b) — query de toda rota", type: :request do
  let!(:city) do
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end
  let(:coordinator) { zoonoses_coordinator! }

  def module_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      [ route.verb, path ] if path.match?(%r{\A/zoonoses(/|\z)})
    end.uniq
  end

  it "o módulo tem as 44 rotas do contrato (§10, Q28)" do
    expect(module_routes.size).to eq(44)
  end

  it "toda rota recusa microchip, cpf e place_address na query (422 invalid_request, sem o valor)" do
    values = { "microchip" => "985112345678903", "cpf" => "52998224725", "place_address" => "Rua Reservada da Query, 99" }
    stepped_up!(coordinator)
    failures = []
    module_routes.each do |verb, route|
      # O nome do relatório e o passo da demanda são parte da rota: inválidos dão 404 antes da query.
      path = route.sub(":name", "rabies_weekly").sub(":step", "schedule").gsub(/:\w+/) { SecureRandom.uuid }
      values.each do |key, value|
        url = "#{path}?#{key}=#{CGI.escape(value)}"
        headers = { "CONTENT_TYPE" => "application/json" }
        verb == "GET" ? get(url, headers: headers) : public_send(verb.downcase, url, params: "{}", headers: headers)
        json = JSON.parse(response.body) rescue {}
        # query_only! recusa sem path; qualquer outro 422 é de outra regra, que leu a URL antes.
        refused = response.status == 422 && json["error"] == "invalid_request" && json["path"].nil? && (json.keys - %w[error path]).empty?
        failures << "#{verb} #{route}?#{key} → #{response.status} #{response.body[0, 120]}" unless refused
        failures << "#{verb} #{route}?#{key} ecoa o valor" if response.body.downcase.include?(value.downcase)
      end
    end
    expect(failures).to be_empty, failures.join("\n")
  end
end

# §16: a varredura de fonte (Prism) — todo DomainEvents.publish em app/ e
# lib/ com nome do módulo usa um dos 22, com nome resolvido e só as chaves do
# contrato; nos arquivos do módulo, só os 22, a falta do 35a e a trilha da
# busca de pessoa (só ids). DomainEvents.publish( é multilinha: o nó da
# chamada inteira, nunca a linha.
RSpec.describe "Sigilo do centro de zoonoses (35b) — DomainEvents.publish na fonte" do
  # O valor de uma constante escrita no arquivo: o literal, ou a constante de
  # outro módulo que ela copia (SHORTFALL_EVENT = VectorControl::ApplyStock::SHORTFALL_EVENT).
  def constant_value(node)
    node = node.receiver if node.is_a?(Prism::CallNode) && node.name == :freeze
    case node
    when Prism::StringNode then node.unescaped
    when Prism::ConstantPathNode, Prism::ConstantReadNode
      value = Object.const_get(node.full_name) rescue nil
      value if value.is_a?(String)
    end
  end

  # Nome do evento: literal, ou a constante escrita no próprio arquivo; nil quando dinâmico.
  def event_name(call, constants)
    arg = call.arguments&.arguments&.first
    case arg
    when Prism::StringNode then arg.unescaped
    when Prism::ConstantReadNode then constants[arg.name]
    when Prism::ConstantPathNode then constant_value(arg)
    end
  end

  def publish_calls
    @publish_calls ||= Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].flat_map do |file|
      constants = {}
      found = []
      walk = lambda do |node|
        constants[node.name] = constant_value(node.value) if node.is_a?(Prism::ConstantWriteNode)
        if node.is_a?(Prism::CallNode) && node.name == :publish && node.receiver.respond_to?(:full_name) &&
           node.receiver.full_name.delete_prefix("::") == "DomainEvents"
          found << node
        end
        node.compact_child_nodes.each { |child| walk.call(child) }
      end
      walk.call(Prism.parse_file(file).value)
      found.map { |call| [ file, call, event_name(call, constants) ] }
    end
  end

  def keys_of(call)
    call.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .map { |assoc| assoc.key.respond_to?(:unescaped) ? assoc.key.unescaped : assoc.key.slice }
  end

  def module_files = ZoonosesSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.to_set

  def shared_files = ZoonosesSecrecy::SHARED_FILES.map { |path| Rails.root.join(path).to_s }.to_set

  # `**payload` (ou um hash com splat) esconde as chaves da varredura, em
  # qualquer ponto da árvore dos argumentos.
  def splats(call)
    found = []
    walk = lambda do |node|
      found << node if node.is_a?(Prism::AssocSplatNode)
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(call.arguments) if call.arguments
    found
  end

  def where(file, call) = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"

  it "só os 22 nomes do §16 (Q26), com as chaves exatas do contrato" do
    calls = publish_calls
    expect(calls.size).to be > 300 # controle: a varredura achou as chamadas do app

    contracted = calls.select { |_, _, name| name&.match?(ZoonosesSecrecy::MODULE_EVENT) }
    contracted.each do |file, call, name|
      expect(ZoonosesSecrecy::CONTRACT_EVENTS).to include(name), "#{where(file, call)}: #{name} fora do contrato"
      expect(keys_of(call)).to match_array(ZoonosesSecrecy::PAYLOAD_KEYS.fetch(name)), "#{where(file, call)}: chaves #{keys_of(call)}"
    end
    expect(contracted.map(&:last).uniq).to match_array(ZoonosesSecrecy::CONTRACT_EVENTS)
  end

  it "nos arquivos do módulo e nos compartilhados, todo publish tem nome resolvido e chaves explícitas" do
    files = module_files
    shared = shared_files
    expect(shared.select { |file| File.exist?(file) }.size).to eq(ZoonosesSecrecy::SHARED_FILES.size)
    calls = publish_calls
    (calls.select { |file, _, _| files.include?(file) || shared.include?(file) }).each do |file, call, name|
      expect(name).to be_present, "#{where(file, call)}: o nome do evento deve ser literal ou constante do arquivo"
      expect(splats(call)).to be_empty, "#{where(file, call)}: payload com **splat"
    end
  end

  it "nos arquivos do módulo, todo publish é um dos 22, a falta do 35a ou a trilha da busca de pessoa (só ids)" do
    files = module_files
    module_calls = publish_calls.select { |file, _, _| files.include?(file) }
    expect(module_calls.size).to be >= 26 # controle: os 22, a falta e a trilha
    allowed = ZoonosesSecrecy::CONTRACT_EVENTS + [ ZoonosesSecrecy::SHORTFALL_EVENT, "clinical_record.viewed" ]
    module_calls.each do |file, call, name|
      expect(allowed).to include(name), "#{where(file, call)}: #{name}"
      expect(keys_of(call)).to eq(ZoonosesSecrecy::SHORTFALL_KEYS) if name == ZoonosesSecrecy::SHORTFALL_EVENT
      next unless name == "clinical_record.viewed"

      expect(keys_of(call) - ZoonosesSecrecy::TRAIL_KEYS).to be_empty, "#{where(file, call)}: trilha com #{keys_of(call)}"
    end
    # A trilha clinical_record.viewed do módulo mora só no Zoonoses::Trail (a busca de pessoa, Q25).
    trail_files = module_calls.select { |_, _, name| name == "clinical_record.viewed" }.map { |file, _, _| file }.uniq
    expect(trail_files).to eq([ Rails.root.join("app/services/zoonoses/trail.rb").to_s ])
  end
end

# §16 (nenhum nome novo de Platform.audit): o módulo não audita na
# plataforma. Platform.audit( é multilinha: procura-se o nó da chamada
# (Prism) e o nome da chamada, que não quebra linha, em todo arquivo do
# módulo e nos compartilhados.
RSpec.describe "Sigilo do centro de zoonoses (35b) — sem Platform.audit novo" do
  def audit_calls(file)
    found = []
    walk = lambda do |node|
      if node.is_a?(Prism::CallNode) && node.name == :audit && node.receiver.respond_to?(:full_name) &&
         node.receiver.full_name.delete_prefix("::") == "Platform"
        found << node
      end
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(Prism.parse_file(file).value)
    found
  end

  it "nenhum arquivo do módulo chama Platform.audit e o R18 segue sem nome do módulo" do
    files = ZoonosesSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq
    expect(files.size).to be >= 60
    %w[app/commands/zoonoses/record_euthanasia.rb app/commands/zoonoses/apply_stock.rb app/controllers/zoonoses/person_lookups_controller.rb
       app/jobs/zoonoses/open_observation_job.rb app/services/zoonoses/trail.rb app/models/animal.rb app/models/euthanasia.rb
       lib/zoonoses_crew.rb].each do |path|
      expect(files).to include(Rails.root.join(path).to_s), "#{path} fora das globs"
    end
    files += ZoonosesSecrecy::SHARED_FILES.map { |path| Rails.root.join(path).to_s }
    expect(files.flat_map { |file| audit_calls(file) }).to be_empty
    expect(files.select { |file| File.read(file).match?(/Platform\s*\.\s*audit\b/) }).to be_empty

    app_audits = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}").to_s].sum { |file| audit_calls(file).size }
    expect(app_audits).to be > 0 # controle: a varredura acha os Platform.audit da plataforma

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include("city.feature_changed") # o que o interruptor zoonoses usa
    expect(r18.grep(ZoonosesSecrecy::MODULE_EVENT)).to be_empty
    expect(r18.grep(/zoonos|animal|rabies|leish|collar|shelter|neuter|euthan|bite_observation/)).to be_empty
    expect(Platform::Features::KEYS).to include(Zoonoses::Gate::KEY)
  end
end
