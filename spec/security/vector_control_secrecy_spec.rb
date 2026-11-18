require "rails_helper"
require "prism"
require "pdf/reader"

# Módulo 35a (ADR 0054; contrato §8, §17; Q26, Q28; plano, Task 17): o sigilo
# da vigilância ambiental de endemias de ponta a ponta. Um cenário completo
# pelas rotas reais:
# - coordenação: quarteirões (criar, editar, vizinhos), atribuição e perfil
#   do imóvel, produtos, local da baixa, cadência, ciclo, parâmetros, LIRAa
#   (recusado fora da faixa, editado, sorteado e fechado), bloqueio
#   (confirmação com seen_case_ids, endereço do caso, ciclo de UBV, caso
#   movido, descarte e encerramento), tarefas, conciliação da falta,
#   relatórios JSON/CSV/PDF e as três camadas do mapa;
# - ACE: leituras, folha de vencidos, visita LIRAa com boletim completo pelo
#   dashboard, envio do app (visita de bloqueio com falta de estoque,
#   instalação e duas coletas da ovitrampa) e o download;
# - laboratório: contagem e correção, resultado de amostra e correção;
# - duas notificações de dengue (CreateNotification + o consumidor
#   ProposeBlockJob), uma da paciente com nome, CPF, CNS, telefone e endereço
#   marcados (o caso com lugar) e outra sem lugar;
# - quatro recusas forçadas (estrato fora da faixa, boletim inconsistente,
#   contagem em palheta avariada e nota curta).
# Depois, as provas de ausência: eventos (⊂ os 20 do §17 + home_visit.recorded
# + clinical_record.viewed, cada payload só com as chaves do contrato), log,
# respostas (paciente só na rota do endereço do caso; nenhum ponto do mapa
# ligado a caso), recusas e trilhas das listas com address_short.
# Fora do cenário: a query de toda rota de /vector_control, a varredura de
# fonte de DomainEvents.publish e a de Platform.audit.
#
# Constantes do cenário num módulo próprio: dentro de um bloco do RSpec elas
# cairiam em Object e colidiriam com as de outros specs na suíte. Tudo ASCII:
# a varredura compara bytes sem caixa (o PDF também pelo texto extraído), e o
# JSON não escapa nada. Cada palavra dos nomes e o logradouro são únicos, para
# a varredura também pegar o nome partido ou só o sobrenome.
module VectorControlSecrecy
  PATIENT = { full_name: "Doralice Quintaneiro Zambrotti", mother_name: "Iolanda Mafalda Zambrotti", street: "Travessa Xylandria",
              number: "77", district: "Vila Quixabeira", zip: "80020300" }.freeze
  OTHER = { full_name: "Ernesta Valquiria Trombetti", mother_name: "Mirtes Odalia Trombetti" }.freeze
  # As palavras soltas: nomes, sobrenomes, o logradouro e o bairro.
  WORDS = %w[Doralice Quintaneiro Zambrotti Iolanda Mafalda Ernesta Valquiria Trombetti Mirtes Odalia Xylandria Quixabeira].freeze
  ZIP_FORMS = [ PATIENT[:zip], "#{PATIENT[:zip][0, 5]}-#{PATIENT[:zip][5, 3]}" ].freeze
  PHONE = "41987650321".freeze
  PHONE_FORMS = [ PHONE, "(41) 98765-0321", "98765-0321" ].freeze
  # O domicílio do caso (24a): o address_short dele só sai na lista de
  # domicílios (sem caso) e na rota do endereço do caso.
  CASE_STREET = "Sigilosa do Foco".freeze
  CASE_NUMBER = "731".freeze
  TEXTS = {
    visit_note: "Reservado VC1: cachorro bravo no quintal do foco",
    bad_visit_note: "Reservado VC2: portao azul do deposito dos fundos",
    count_note: "Reservado VC3: recontagem da palheta pela bancada",
    result_note: "Reservado VC4: recontagem das larvas da amostra",
    task_note: "Reservado VC5: intensificacao feita no quarteirao",
    place_task_note: "Reservado VC6: caso sem lugar movido para o bloqueio",
    reconcile_note: "Reservado VC7: falta conferida com o almoxarifado",
    dismiss_reason: "Reservado VC8: proposta vazia depois da mudanca"
  }.freeze
  SHORT_NOTE = "Curta9 ok".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  UUID_IN_PATH = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  ADDRESS_ROUTE = "/vector_control/transmission_blocks/:id/cases/:id/address".freeze
  # §17 (e Q26(2), o 20º): os eventos do módulo e as chaves exatas de cada payload.
  PAYLOAD_KEYS = {
    "city_block.changed" => %w[city_block_id user_id],
    "household_vector_profile.changed" => %w[household_id user_id],
    "vector_stock.shortfall_recorded" => %w[vector_stock_shortfall_id],
    "vector_stock.shortfall_reconciled" => %w[vector_stock_shortfall_id user_id],
    "ovitrap.installed" => %w[ovitrap_id user_id],
    "ovitrap.collected" => %w[ovitrap_id user_id],
    "ovitrap_reading.counted" => %w[ovitrap_reading_id user_id corrected],
    "vector_task.opened" => %w[vector_task_id],
    "vector_task.closed" => %w[vector_task_id user_id],
    "liraa_survey.drawn" => %w[liraa_survey_id user_id],
    "liraa_survey.closed" => %w[liraa_survey_id user_id],
    "transmission_block.proposed" => %w[transmission_block_id],
    "transmission_block.confirmed" => %w[transmission_block_id user_id],
    "transmission_block.dismissed" => %w[transmission_block_id user_id],
    "transmission_block.closed" => %w[transmission_block_id user_id],
    "transmission_block_case.address_viewed" => %w[transmission_block_id user_id],
    "vector_sample.result_recorded" => %w[vector_sample_id user_id corrected],
    "vector_parameters.changed" => %w[version user_id],
    "vector_product.changed" => %w[vector_product_id user_id],
    "transmission_block_case.moved" => %w[transmission_block_id from_transmission_block_id user_id]
  }.freeze
  CONTRACT_EVENTS = PAYLOAD_KEYS.keys.freeze
  # A inspeção vai no home_visit.recorded do 24b (§17); as trilhas no clinical_record.viewed.
  VISIT_KEYS = %w[home_visit_id home_visit_day_id user_id].freeze
  ALLOWED_EVENTS = (CONTRACT_EVENTS + %w[home_visit.recorded clinical_record.viewed]).freeze
  # Os prefixos do módulo: um nome com eles fora dos 20 é evento não contratado.
  MODULE_EVENT = /\A(city_block|household_vector_profile|vector_stock|ovitrap|ovitrap_reading|vector_task|liraa_survey|
                     transmission_block|transmission_block_case|vector_sample|vector_parameters|vector_product)\./x
  # As trilhas (24a, 24b e a do endereço do caso): só ids, o access e o person_ref.
  TRAIL_KEYS = %w[access user_id patient_id patient_ids home_visit_ids collective_activity_ids micro_area_id household_id
                  household_ids field_device_id reason_code person_ref transmission_block_id].freeze
  # As chaves do corpo que o "Parameters:" do log mostra como [FILTERED].
  LOGGED_KEYS = %w[note count_note result_note reason].freeze
  MODULE_GLOBS = %w[
    app/**/vector_control/**/*.rb app/models/vector_*.rb app/models/city_block*.rb app/models/household_vector_profile.rb
    app/models/ovitrap*.rb app/models/liraa_*.rb app/models/transmission_block*.rb app/controllers/concerns/vector_control_gate.rb
    lib/vector_control_crew.rb
  ].freeze
  # Arquivos de outros módulos com código do 35a (boletim, app, baixa): nome
  # de evento sem resolver ou Platform.audit neles também falha. Nenhum nome
  # dinâmico conhecido (sem allow-list).
  SHARED_FILES = %w[
    app/services/field_sync/upload.rb app/services/field_sync/changes.rb app/commands/home_visits/record.rb
    app/commands/pharmacy/record_entry.rb app/services/stock/domain.rb
  ].freeze

  def self.cpf_forms(cpf) = [ cpf, "#{cpf[0, 3]}.#{cpf[3, 3]}.#{cpf[6, 3]}-#{cpf[9, 2]}" ]

  # A rota da resposta com os UUIDs no lugar de :id.
  def self.route(path) = path.gsub(UUID_IN_PATH, ":id")

  # O texto que o PDF imprime (o Prawn quebra o texto com kerning em arrays TJ).
  def self.pdf_text(raw) = PDF::Reader.new(StringIO.new(raw)).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  # Onde procurar (bytes, sem caixa): o corpo inteiro e, no PDF, também o texto extraído.
  def self.haystack(raw, media_type)
    text = raw.to_s.b
    text += " #{pdf_text(raw)}".b if media_type == "application/pdf"
    text.downcase
  end

  def self.contains?(haystack, secret) = haystack.include?(secret.to_s.b.downcase)
end

RSpec.describe "Sigilo da vigilância ambiental de endemias (35a)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Método, e não let: o cenário roda no seed_once (before(:context)).
  def secrecy = VectorControlSecrecy

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }
  after { travel_back }

  # A linha da cidade de teste no Current, com bloco (nunca Current.city
  # solto): a requisição reseta o Current ao fim, e o preparo entre
  # requisições (lote, notificação) lê a cidade.
  def in_city(&) = Current.set(city: City.find_by!(slug: TEST_CITY_A.slug), &)

  # O consumidor do 35a sobre o disease_notification.created (o caminho do
  # IdempotentConsumer, como a fila faria).
  def propose!(notification)
    event = DomainEvent.where(name: "disease_notification.created").where("payload->>'notification_id' = ?", notification.id).sole
    VectorControl::ProposeBlockJob.perform_now(event_id: event.id, event_name: event.name, city_slug: TEST_CITY_A.slug, payload: event.payload)
  end

  def spot(n) = { "latitude" => -25.4284 - (n / 1000.0), "longitude" => -49.2733 + (n / 1000.0), "source" => "map" }

  # Cenário completo pelas rotas, com o log capturado, toda resposta guardada
  # (rota, status, corpo e Cache-Control) e as recusas forçadas.
  def secrecy_scenario!
    s = secrecy
    block_city!
    unit = care_unit!
    team = registry_team!(unit)
    ace = endemic_agent!(team: team)
    area = MicroAreaFieldAssignment.active.find_by!(professional: ace.professional).micro_area
    coordinator = endemic_coordinator!
    lab = vector_lab!
    neighborhood = Neighborhood.create!(name: "Bairro Sigilo #{SecureRandom.hex(2)}", source: "manual")
    location = vector_location!
    today = Time.zone.today

    # O domicílio do caso, noutra equipe (fora do escopo do ACE), no bairro;
    # o do ACE, no mesmo bairro. Os dois com ponto do 24c.
    case_area = registry_micro_area!(code: "01")
    case_home = registry_household_rows!(case_area, neighborhood_id: neighborhood.id, location: spot(1), contact_phone: s::PHONE,
                                         address: registry_address.merge("street" => s::CASE_STREET, "number" => s::CASE_NUMBER,
                                                                         "neighborhood_id" => neighborhood.id))
    home = registry_household_rows!(area, neighborhood_id: neighborhood.id, location: spot(2))

    # A paciente marcada, com cadastro individual ativo no domicílio do caso
    # (o celular marcado no cadastro); a outra, sem lugar. O cadastro do 24a
    # copia o endereço do domicílio para o paciente: o endereço próprio
    # marcado entra depois, para a varredura distinguir os dois.
    n = registry_seq!
    patient = Patient.create!(cpf: valid_cpf(n), cns: valid_cns(n), full_name: s::PATIENT[:full_name], mother_name: s::PATIENT[:mother_name],
                              birth_date: "1988-03-14", sex: "female", race_color: "03")
    params = registry_registration_params(case_home, patient: patient)
    params["identification"] = params["identification"].merge("telefone_celular" => s::PHONE)
    saved = TerritoryRegistry::SaveRegistration.call(params: params, by: registry_acs_of(case_home))
    raise "cadastro recusado: #{saved.reason} #{saved.details}" if saved.failure?

    patient.reload.update!(address_street: s::PATIENT[:street], address_number: s::PATIENT[:number], address_complement: nil,
                           address_district: s::PATIENT[:district], address_zip: s::PATIENT[:zip])

    other = Patient.create!(cpf: valid_cpf(registry_seq!), full_name: s::OTHER[:full_name], mother_name: s::OTHER[:mother_name],
                            birth_date: "1979-07-02", sex: "female", race_color: "03")
    registry_registration!(patient: other)
    device_token = FieldDevices::Register.call(user: ace, name: "Tablet do ACE").payload.fetch(:token)

    responses = []
    refusals = []
    send_request = lambda do |verb, path, payload, headers|
      if verb == :get
        get(path, headers: headers)
      else
        public_send(verb, path, params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }.merge(headers))
      end
      responses << { verb: verb, path: request.path, route: s.route(request.path), status: response.status, raw: response.body.dup,
                     haystack: s.haystack(response.body, response.media_type), media_type: response.media_type,
                     pdf_text: (s.pdf_text(response.body) if response.media_type == "application/pdf"),
                     cache_control: response.headers["Cache-Control"] }
    end
    req = lambda do |verb, path, payload = {}, headers: {}|
      send_request.(verb, path, payload, headers)
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.media_type == "application/json" && response.body.present? ? JSON.parse(response.body) : response.body
    end
    refuse = lambda do |label, path, payload, status:, sent:, verb: :post, headers: {}|
      send_request.(verb, path, payload, headers)
      raise "#{label}: #{path} → #{response.status} #{response.body}" unless response.status == status

      refusals << { label: label, status: response.status, raw: response.body, json: JSON.parse(response.body), sent: Array(sent) }
    end
    occurred_at = -> { [ 1.minute.ago, Time.current.beginning_of_day ].max.change(usec: 0).iso8601 }
    visit_body = lambda do |report, **over|
      { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "occurred_at" => occurred_at.call, "household_id" => home.id,
        "subject" => "none", "outcome" => 1, "reasons" => [], "shared" => false, "vector_inspection" => report }.merge(over.stringify_keys)
    end
    base = "/vector_control"
    bearer = { "Authorization" => "Bearer #{device_token}" }

    ids = {}
    setup_events = []
    # Preparo no meio do cenário (lote, notificação): os eventos dele não são do 35a.
    setup = lambda do |&work|
      before = DomainEvent.pluck(:id)
      result = in_city(&work)
      setup_events.concat(DomainEvent.pluck(:id) - before)
      result
    end
    started_at = Time.current
    platform_events_before = PlatformEvent.count
    log = capture_log do
      # Coordenação: quarteirões, vizinhos, imóveis.
      stepped_up!(coordinator)
      req.(:get, "#{base}/domains")
      ids[:b1] = req.(:post, "#{base}/blocks", { neighborhood_id: neighborhood.id, number: "001" }).fetch("id")
      ids[:b2] = req.(:post, "#{base}/blocks", { neighborhood_id: neighborhood.id, number: "002" }).fetch("id")
      ids[:b3] = req.(:post, "#{base}/blocks", { neighborhood_id: neighborhood.id, number: "003" }).fetch("id")
      req.(:patch, "#{base}/blocks/#{ids[:b3]}", { number: "003-A" })
      req.(:post, "#{base}/blocks/#{ids[:b1]}/neighbors", { neighbor_block_id: ids[:b2] })
      req.(:post, "#{base}/blocks/#{ids[:b2]}/neighbors", { neighbor_block_id: ids[:b3] })
      req.(:delete, "#{base}/blocks/#{ids[:b2]}/neighbors/#{ids[:b3]}", {})
      req.(:get, "#{base}/blocks?neighborhood_id=#{neighborhood.id}")
      req.(:post, "#{base}/households/assign_block", { household_ids: [ case_home.id ], city_block_id: ids[:b1] })
      req.(:post, "#{base}/households/assign_block", { household_ids: [ home.id ], city_block_id: ids[:b2] })
      req.(:get, "#{base}/households?neighborhood_id=#{neighborhood.id}")
      req.(:get, "#{base}/households/#{home.id}")
      req.(:patch, "#{base}/households/#{home.id}/profile", { risk_class: "red" })

      # Produtos (com o lote pelo 27a), local da baixa, cadência, ciclo, parâmetros.
      product = { unit: "g", charge_size: "2.00", uses: %w[focal], active: true }
      ids[:ppf] = req.(:post, "#{base}/products", product.merge(code: "PPF05", name: "Piriproxifeno 0,5% granulado")).fetch("id")
      ids[:spn] = req.(:post, "#{base}/products", product.merge(code: "SPN748", name: "Espinosade 7,48%", unit: "un", charge_size: "1.00"))
                     .fetch("id")
      req.(:patch, "#{base}/products/#{ids[:spn]}", { name: "Espinosade 7,48% comprimido" })
      req.(:get, "#{base}/products")
      setup.call do
        vector_lot!(location, product: VectorProduct.find(ids[:ppf]), quantity: "100")
        vector_lot!(location, product: VectorProduct.find(ids[:spn]), quantity: "1")
      end
      req.(:put, "#{base}/settings", { stock_location_id: location.id })
      req.(:get, "#{base}/settings")
      req.(:put, "#{base}/cadences", { items: [ { neighborhood_id: nil, risk_class: "red", strategic_point: false, days: 7 },
                                                { neighborhood_id: nil, risk_class: nil, strategic_point: true, days: 15 } ] })
      req.(:get, "#{base}/cadences")
      number = (today.month + 1) / 2
      starts_on = Date.new(today.year, (number * 2) - 1, 1)
      ends_on = starts_on.next_month.end_of_month
      ids[:cycle] = req.(:post, "#{base}/cycles", { year: today.year, number: number, starts_on: starts_on.iso8601,
                                                    ends_on: (ends_on - 1).iso8601 }).fetch("id")
      req.(:patch, "#{base}/cycles/#{ids[:cycle]}", { ends_on: ends_on.iso8601 })
      req.(:get, "#{base}/cycles?year=#{today.year}")
      read = req.(:get, "#{base}/parameters")
      req.(:put, "#{base}/parameters", { values: read.fetch("values").merge("ovitrap_alert_eggs" => 120),
                                         expected_version: read.fetch("version") })

      # LIRAa: standard num estrato pequeno → fora da faixa; census → sorteado.
      survey_body = lambda do |mode|
        { name: "LIRAa Sigilo", starts_on: (today - 1).iso8601, ends_on: (today + 5).iso8601,
          strata: [ { name: "Quarteirao 002", mode: mode, block_ids: [ ids[:b2] ] } ] }
      end
      ids[:survey] = req.(:post, "#{base}/liraa_surveys", survey_body.("standard")).fetch("id")
      refuse.(:stratum_out_of_range, "#{base}/liraa_surveys/#{ids[:survey]}/draw", {}, status: 422, sent: [])
      req.(:patch, "#{base}/liraa_surveys/#{ids[:survey]}", survey_body.("census"))
      req.(:post, "#{base}/liraa_surveys/#{ids[:survey]}/draw", {})
      ids[:item] = req.(:get, "#{base}/liraa_surveys/#{ids[:survey]}/items").fetch("items").sole.fetch("id")
      req.(:get, "#{base}/liraa_surveys")

      # As notificações de dengue (25) e o consumidor do 35a.
      notifications = setup.call do
        [ notification!(patient: patient), notification!(patient: other) ]
      end
      ids[:notifications] = notifications.map(&:id)
      notifications.each { |notification| propose!(notification) }
      cases = notifications.map { |notification| TransmissionBlockCase.find_by!(disease_notification_id: notification.id) }
      ids[:case], ids[:other_case] = cases.map(&:id)
      ids[:tb1], ids[:tb2] = cases.map(&:transmission_block_id)

      # Bloqueio: confirmação com os casos vistos, endereço do caso (step-up),
      # ciclo de UBV, o caso sem lugar movido e a proposta vazia descartada.
      req.(:get, "#{base}/transmission_blocks?status=proposed")
      seen = req.(:get, "#{base}/transmission_blocks/#{ids[:tb1]}").fetch("cases").map { |row| row.fetch("id") }
      req.(:post, "#{base}/transmission_blocks/#{ids[:tb1]}/confirm",
           { center_block_id: ids[:b1], block_ids: [ ids[:b1], ids[:b2] ], seen_case_ids: seen })
      ids[:address] = req.(:get, "#{base}/transmission_blocks/#{ids[:tb1]}/cases/#{ids[:case]}/address")
      req.(:post, "#{base}/transmission_blocks/#{ids[:tb1]}/cycles", { starts_on: (today - 1).iso8601, ends_on: (today + 3).iso8601 })
      req.(:post, "#{base}/transmission_blocks/#{ids[:tb2]}/cases/#{ids[:other_case]}/move", { to_transmission_block_id: ids[:tb1] })
      req.(:post, "#{base}/transmission_blocks/#{ids[:tb2]}/dismiss", { reason: s::TEXTS[:dismiss_reason] })
      # Os domicílios de novo, com o caso no bloqueio: a linha do domicílio do caso igual às outras.
      ids[:households_after] = req.(:get, "#{base}/households?neighborhood_id=#{neighborhood.id}").fetch("items")
      ids[:case_home_after] = req.(:get, "#{base}/households/#{case_home.id}")
      ids[:home_after] = req.(:get, "#{base}/households/#{home.id}")

      # ACE: leituras, vencidos, visita LIRAa pelo dashboard e a recusada.
      stepped_up!(ace)
      req.(:get, "#{base}/domains")
      req.(:get, "#{base}/parameters")
      req.(:get, "#{base}/blocks?neighborhood_id=#{neighborhood.id}")
      req.(:get, "#{base}/due?micro_area_id=#{area.id}")
      liraa = { "activity" => "liraa", "liraa_draw_item_id" => ids[:item], "work_type" => "routine", "situation" => "worked",
                "educational_action" => true,
                "deposits" => [ { "group" => "B", "existing" => 3, "with_water" => 2, "with_larvae" => 1, "eliminated" => 1, "treated" => 0 } ],
                "measures" => [ { "method" => "mechanical" }, { "method" => "focal", "vector_product_id" => ids[:ppf], "charges" => 2 } ],
                "samples" => [ { "number" => 1, "deposit_group" => "B", "larvae_collected" => 4 } ] }
      ids[:visit] = req.(:post, "/home_visits", visit_body.(liraa, note: s::TEXTS[:visit_note])).dig("visit", "id")
      # LI (o item do LIRAa já foi inspecionado: o vínculo recusaria antes dos depósitos).
      inconsistent = liraa.except("liraa_draw_item_id")
                          .merge("activity" => "li", "deposits" => [ liraa["deposits"].first.merge("with_water" => 4) ])
      refuse.(:inconsistent_report, "/home_visits", visit_body.(inconsistent, note: s::TEXTS[:bad_visit_note]), status: 422,
              sent: s::TEXTS[:bad_visit_note])

      # App: visita de bloqueio (falta de espinosade), instalação e duas coletas.
      req.(:get, "/field/v1/session", headers: bearer)
      at_now = Time.current.change(usec: 0).iso8601
      block_report = { "activity" => "transmission_block", "transmission_block_id" => ids[:tb1], "work_type" => "routine",
                       "situation" => "worked", "educational_action" => true,
                       "deposits" => [ { "group" => "A2", "existing" => 2, "with_water" => 2, "with_larvae" => 1, "eliminated" => 0,
                                         "treated" => 1 } ],
                       "measures" => [ { "method" => "focal", "vector_product_id" => ids[:spn], "charges" => 3 } ] }
      install = SecureRandom.uuid
      items = [
        { client_uuid: SecureRandom.uuid, type: "home_visit",
          body: visit_body.(block_report, occurred_at: at_now).except("client_uuid") },
        { client_uuid: install, type: "ovitrap_installation",
          body: { household_id: home.id, number: "OV-0101", consent: true, installed_on: (today - 14).iso8601 } },
        { client_uuid: SecureRandom.uuid, type: "ovitrap_collection",
          body: { ovitrap_client_uuid: install, collected_on: (today - 7).iso8601, condition: "ok", reinstall: true } },
        { client_uuid: SecureRandom.uuid, type: "ovitrap_collection",
          body: { ovitrap_client_uuid: install, collected_on: today.iso8601, condition: "damaged", reinstall: true } }
      ]
      ids[:upload] = req.(:post, "/field/v1/uploads", { items: items }, headers: bearer).fetch("results")
      travel(3.seconds) { ids[:changes] = req.(:get, "/field/v1/changes", headers: bearer) }
      dashboard = req.(:post, "#{base}/ovitraps", { client_uuid: SecureRandom.uuid, household_id: home.id, number: "OV-0102", consent: true,
                                                    installed_on: (today - 5).iso8601 })
      req.(:post, "#{base}/ovitraps/#{dashboard.fetch('id')}/collect", { collected_on: today.iso8601, condition: "lost", remove: true })
      req.(:get, "#{base}/ovitraps?micro_area_id=#{area.id}")

      # Laboratório: contagem e correção; a palheta avariada; amostra e correção.
      stepped_up!(lab)
      to_count = req.(:get, "#{base}/ovitrap_readings?state=to_count").fetch("items")
      ids[:reading] = to_count.sole.fetch("id")
      req.(:post, "#{base}/ovitrap_readings/#{ids[:reading]}/count", { egg_count: 142 })
      req.(:post, "#{base}/ovitrap_readings/#{ids[:reading]}/count", { egg_count: 150, count_note: s::TEXTS[:count_note] })
      damaged = OvitrapReading.find_by!(condition: "damaged").id
      refuse.(:damaged_count, "#{base}/ovitrap_readings/#{damaged}/count", { egg_count: 12 }, status: 422, sent: [])
      ids[:sample] = req.(:get, "#{base}/samples").fetch("items").sole.fetch("id")
      req.(:post, "#{base}/samples/#{ids[:sample]}/result", { examined_larvae: 4, aegypti_larvae: 3, albopictus_larvae: 0 })
      req.(:post, "#{base}/samples/#{ids[:sample]}/result",
           { examined_larvae: 4, aegypti_larvae: 2, albopictus_larvae: 1, result_note: s::TEXTS[:result_note] })

      # Coordenação: listas, tarefas, conciliação, fechamentos, relatórios, mapa.
      stepped_up!(coordinator)
      req.(:get, "#{base}/ovitraps?neighborhood_id=#{neighborhood.id}")
      req.(:get, "#{base}/ovitrap_readings?state=counted")
      req.(:get, "#{base}/samples?state=done")
      tasks = req.(:get, "#{base}/tasks").fetch("items")
      ids[:tasks] = tasks.map { |task| task.fetch("id") }
      tasks.each do |task|
        note = task["kind"] == "ovitrap_intensification" ? s::TEXTS[:task_note] : s::TEXTS[:place_task_note]
        req.(:post, "#{base}/tasks/#{task.fetch('id')}/close", { state: "done", note: note })
      end
      req.(:get, "#{base}/tasks?state=closed")
      ids[:shortfall] = req.(:get, "#{base}/stock_shortfalls").fetch("items").sole.fetch("id")
      refuse.(:short_note, "#{base}/stock_shortfalls/#{ids[:shortfall]}/reconcile", { note: s::SHORT_NOTE }, status: 422, sent: s::SHORT_NOTE)
      req.(:post, "#{base}/stock_shortfalls/#{ids[:shortfall]}/reconcile", { note: s::TEXTS[:reconcile_note] })
      req.(:get, "#{base}/stock_shortfalls?state=reconciled")
      req.(:post, "#{base}/liraa_surveys/#{ids[:survey]}/close", {})
      req.(:get, "#{base}/cycles/#{ids[:cycle]}")

      week = Surveillance::EpiWeek.for(today - 14).to_s
      period = "from=#{(today - 30).iso8601}&to=#{today.iso8601}"
      filters = { "situations" => "cycle_id=#{ids[:cycle]}", "strategic_points" => "cycle_id=#{ids[:cycle]}", "production" => period,
                  "consumption" => period, "ovitraps" => "epi_weeks[]=#{week}&neighborhood_ids[]=#{neighborhood.id}",
                  "liraa" => "survey_id=#{ids[:survey]}", "blocks" => period }
      filters.each do |name, query|
        ids[:"report_#{name}"] = req.(:get, "#{base}/reports/#{name}?#{query}")
        req.(:get, "#{base}/reports/#{name}.csv?#{query}")
      end
      req.(:get, "#{base}/reports/liraa.pdf?#{filters['liraa']}")
      ids[:map] = {
        risk: req.(:get, "#{base}/map_points?layer=risk&neighborhood_id=#{neighborhood.id}"),
        ovitraps: req.(:get, "#{base}/map_points?layer=ovitraps&neighborhood_id=#{neighborhood.id}&epi_week=#{week}"),
        transmission: req.(:get, "#{base}/map_points?layer=transmission&transmission_block_id=#{ids[:tb1]}")
      }
      req.(:get, "#{base}/transmission_blocks/#{ids[:tb1]}")
      req.(:post, "#{base}/transmission_blocks/#{ids[:tb1]}/close", {})
      req.(:get, "#{base}/transmission_blocks")
    end

    { ids: ids, log: log, responses: responses, refusals: refusals, started_at: started_at, setup_events: setup_events,
      platform_events: PlatformEvent.count - platform_events_before, patient: patient, other: other, case_home: case_home,
      home: home, ace: ace, device_token: device_token }
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
    let(:patient) { scenario[:patient] }
    let(:other) { scenario[:other] }
    # Nome, mãe, CPF, CNS, telefone e endereço da paciente; nome, mãe e CPF da outra.
    let(:people) do
      p = secrecy::PATIENT
      [ p[:full_name], p[:mother_name], p[:street], p[:district], "#{p[:street]}, #{p[:number]}", patient.cns,
        secrecy::OTHER[:full_name], secrecy::OTHER[:mother_name] ] + secrecy::WORDS + secrecy::ZIP_FORMS +
        secrecy.cpf_forms(patient.cpf) + secrecy.cpf_forms(other.cpf) + secrecy::PHONE_FORMS
    end
    let(:case_street) { "#{secrecy::CASE_STREET}, #{secrecy::CASE_NUMBER}" }
    let(:texts) { secrecy::TEXTS.values + [ secrecy::SHORT_NOTE ] }
    let(:events) do
      DomainEvent.where(occurred_at: scenario[:started_at]..).where.not(id: scenario[:setup_events]).order(:occurred_at, :created_at).to_a
    end
    let(:responses) { scenario[:responses] }
    let(:address_response) { responses.find { |r| r[:route] == secrecy::ADDRESS_ROUTE } }
    let(:others) { responses.reject { |r| r.equal?(address_response) } }

    it "percorreu o cenário inteiro (controle positivo)" do
      expect(TransmissionBlock.find(ids[:tb1])).to have_attributes(status: "closed", center_block_id: ids[:b1])
      expect(TransmissionBlock.find(ids[:tb2])).to have_attributes(status: "dismissed", dismissed_reason: secrecy::TEXTS[:dismiss_reason])
      expect(TransmissionBlockCase.where(id: [ ids[:case], ids[:other_case] ]).pluck(:transmission_block_id).uniq).to eq([ ids[:tb1] ])
      expect(TransmissionBlockCycle.where(transmission_block_id: ids[:tb1]).count).to eq(1)
      expect(LiraaSurvey.find(ids[:survey]).status).to eq("closed")
      expect(LiraaDrawItem.find(ids[:item]).status).to eq("inspected")
      expect(OvitrapReading.find(ids[:reading])).to have_attributes(egg_count: 150, count_note: secrecy::TEXTS[:count_note])
      expect(VectorSample.find(ids[:sample])).to have_attributes(aegypti_larvae: 2, result_note: secrecy::TEXTS[:result_note])
      expect(VectorTask.where(id: ids[:tasks]).pluck(:kind, :state))
        .to contain_exactly(%w[ovitrap_intensification done], %w[block_case_without_place done])
      expect(VectorStockShortfall.find(ids[:shortfall])).to have_attributes(cause: "insufficient_balance", reconciliation_note: secrecy::TEXTS[:reconcile_note])
      expect(VectorParameterVersion.maximum(:version)).to eq(1)
      expect(HomeVisit.find(ids[:visit]).note).to eq(secrecy::TEXTS[:visit_note])
      expect(ids[:upload].map { |r| [ r["type"], r["status"] ] })
        .to eq([ %w[home_visit accepted], %w[ovitrap_installation accepted], %w[ovitrap_collection accepted], %w[ovitrap_collection accepted] ])
      expect(ids[:changes]).to include("reset" => false)
      expect(scenario[:refusals].map { |r| r[:label] }).to eq(%i[stratum_out_of_range inconsistent_report damaged_count short_note])

      # O endereço do caso: a única resposta com o endereço da paciente, sem cache.
      expect(ids[:address]).to eq("patient_address" => "#{secrecy::PATIENT[:street]}, #{secrecy::PATIENT[:number]}, #{secrecy::PATIENT[:district]}",
                                  "household_address" => "Rua #{case_street}")
      expect(address_response[:cache_control]).to eq("no-store")

      # O relatório de produção mostra o agente (servidor), nunca cidadão.
      expect(ids[:report_production].to_json).to include(scenario[:ace].professional.professional_name)
    end

    # §17 e Q26(2): os eventos do módulo são só os 20, todos publicados no
    # cenário, e cada payload só leva as suas chaves (ids, corrected, version).
    it "os eventos publicados ⊂ os 20 do §17 + home_visit.recorded + clinical_record.viewed, cada payload só com as chaves do contrato" do
      expect(VectorControl::Catalog::DOMAIN_EVENTS).to match_array(secrecy::CONTRACT_EVENTS)
      expect(events.map(&:name).uniq - secrecy::ALLOWED_EVENTS).to be_empty
      expect(events.map(&:name).uniq).to include(*secrecy::CONTRACT_EVENTS) # o cenário passou por todos os 20

      events.each do |event|
        case event.name
        when "clinical_record.viewed"
          expect(event.payload.keys - secrecy::TRAIL_KEYS).to be_empty, "trilha #{event.payload.keys}"
        when "home_visit.recorded"
          expect(event.payload.keys).to match_array(secrecy::VISIT_KEYS)
        else
          expect(event.payload.keys).to match_array(secrecy::PAYLOAD_KEYS.fetch(event.name)), "#{event.name} publica #{event.payload.keys}"
        end
        event.payload.each do |key, value|
          case key
          when "corrected" then expect(value).to be_in([ true, false ])
          when "version" then expect(value).to be_a(Integer)
          when "access" then expect(value).to be_in(%w[territory_registry territory_map transmission_block_case field_sync home_visits])
          when "reason_code" then expect(value).to be_nil
          when "person_ref" then expect(value).to eq("patient:#{event.payload['patient_id']}")
          when /_ids\z/ then expect(value).to all(match(secrecy::UUID))
          else expect(value.to_s).to match(secrecy::UUID), "#{event.name}.#{key}"
          end
        end
      end
      expect(events.select { |e| e.name == "ovitrap_reading.counted" }.map { |e| e.payload["corrected"] }).to eq([ false, true ])
      expect(events.select { |e| e.name == "vector_sample.result_recorded" }.map { |e| e.payload["corrected"] }).to eq([ false, true ])
      expect(events.find { |e| e.name == "transmission_block_case.moved" }.payload)
        .to include("transmission_block_id" => ids[:tb1], "from_transmission_block_id" => ids[:tb2])

      payloads = events.map { |e| [ e.name, e.payload ] }.to_json.downcase
      (people + texts + [ case_street ]).each do |secret|
        expect(payloads).not_to include(secret.downcase), "evento contém #{secret.inspect}"
      end
      expect(events.flat_map { |e| e.payload.keys }.grep(/note|\Areason\z|name|cpf|cns|phone|address/)).to be_empty
    end

    it "o log do cenário não tem nome, CPF, CNS, telefone ou endereço da paciente nem as notas" do
      log = scenario[:log]
      # Controle: a captura viu as requisições e o filtro agiu.
      expect(log).to include("/vector_control/transmission_blocks", "/vector_control/reports", "/home_visits", "/field/v1/uploads",
                             "[FILTERED]")
      lowered = log.downcase
      (people + texts + [ case_street ]).each { |secret| expect(lowered).not_to include(secret.downcase), "log contém #{secret.inspect}" }

      logged = log.scan(/"(#{secrecy::LOGGED_KEYS.join('|')})"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq).to include("note", "count_note", "result_note", "reason")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    # §17 e §8: a paciente só na rota do endereço do caso (varredura do corpo
    # inteiro, JSON, CSV e PDF); o domicílio do caso só nela e na lista de
    # domicílios, que não diz qual tem caso.
    # §8 (CaseAddress): o endereço do caso só traz `{ patient_address,
    # household_address }`. Lá podem sair logradouro, número, bairro e CEP da
    # paciente e do domicílio; todo outro marcador fica de fora.
    it "a resposta do endereço do caso só traz as partes do endereço" do
      p = secrecy::PATIENT
      allowed = [ p[:street], p[:district], "#{p[:street]}, #{p[:number]}", "Xylandria", "Quixabeira", *secrecy::ZIP_FORMS,
                  secrecy::CASE_STREET, case_street ]
      expect(allowed - people - [ secrecy::CASE_STREET, case_street ]).to be_empty # só tira o que é endereço
      forbidden = (people - allowed) + texts +
                  [ patient.id, other.id, *ids[:notifications], ids[:case], ids[:other_case], scenario[:case_home].id ]
      expect(forbidden).to include(p[:full_name], p[:mother_name], "Doralice", "Zambrotti", patient.cns, *secrecy::PHONE_FORMS,
                                   *secrecy.cpf_forms(patient.cpf), secrecy::OTHER[:full_name], secrecy::OTHER[:mother_name],
                                   *secrecy.cpf_forms(other.cpf))
      expect(JSON.parse(address_response[:raw]).keys).to eq(%w[patient_address household_address])
      forbidden.each do |secret|
        expect(secrecy.contains?(address_response[:haystack], secret)).to be(false), "o endereço do caso contém #{secret.inspect}"
      end
      allowed.first(3).each { |part| expect(secrecy.contains?(address_response[:haystack], part)).to be(true) } # controle
      expect(secrecy.contains?(address_response[:haystack], case_street)).to be(true)
    end

    it "nenhuma resposta, salvo a do endereço do caso, traz nome, CPF, CNS, telefone ou endereço da paciente" do
      expect(responses.size).to be > 90
      expect(responses.map { |r| r[:route] }).to include("/vector_control/reports/liraa.pdf", "/vector_control/reports/production.csv",
                                                         "/field/v1/changes", "/home_visits")
      others.each do |r|
        people.each { |secret| expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}" }
      end
      expect(secrecy.contains?(address_response[:haystack], secrecy::PATIENT[:street])).to be(true) # controle
      # Controle do PDF: o texto extraído, sozinho, tem o que o relatório imprime (o nome do levantamento).
      pdf = responses.find { |r| r[:media_type] == "application/pdf" }
      expect(pdf[:pdf_text]).to be_present
      expect(pdf[:pdf_text].downcase).to include("liraa sigilo")
      expect(responses.select { |r| secrecy.contains?(r[:haystack], case_street) }.map { |r| r[:route] }.uniq)
        .to contain_exactly("/vector_control/households", secrecy::ADDRESS_ROUTE)
    end

    # §17 e Q28(1): nenhuma camada liga ponto a caso; o bloqueio, as tarefas e
    # os relatórios não dizem paciente, notificação nem o domicílio do caso.
    it "nenhuma camada do mapa liga ponto a caso; bloqueio, tarefas e relatórios sem paciente, notificação ou domicílio do caso" do
      map = ids[:map]
      map.each_value { |body| body.fetch("points").each { |point| expect(point.keys).to eq(%w[id latitude longitude category label]) } }
      transmission = map[:transmission].fetch("points")
      expect(transmission.map { |point| point["id"] }).to contain_exactly(scenario[:case_home].id, scenario[:home].id) # controle
      expect(transmission.map { |point| point.values_at("category", "label") }.uniq).to eq([ %w[area area] ])
      expect(map[:risk].fetch("points").map { |point| point["label"] }.uniq).to match_array(%w[001 002])
      expect(map[:ovitraps].fetch("points").map { |point| point["id"] }).to match_array(Ovitrap.active_ovitraps.pluck(:id))

      # Paciente e notificação: em nenhuma resposta (só o endereço do caso os lê).
      people_ids = [ patient.id, other.id, *ids[:notifications] ]
      expect(others.map { |r| r[:route] }).to include("/field/v1/changes", "/vector_control/due", "/vector_control/ovitraps",
                                                      "/vector_control/samples", "/home_visits", "/vector_control/households")
      others.each do |r|
        people_ids.each { |id| expect(secrecy.contains?(r[:haystack], id)).to be(false), "#{r[:verb]} #{r[:path]} contém #{id}" }
      end
      # O caso ("caso n") só nas respostas do bloqueio; nunca no app, no mapa, nas listas nem nos relatórios.
      case_ids = [ ids[:case], ids[:other_case] ]
      others.reject { |r| r[:route].start_with?("/vector_control/transmission_blocks") }.each do |r|
        case_ids.each { |id| expect(secrecy.contains?(r[:haystack], id)).to be(false), "#{r[:verb]} #{r[:path]} contém o caso #{id}" }
      end
      # O domicílio do caso: nunca ao lado do bloqueio, das tarefas nem dos relatórios.
      linked = others.select { |r| r[:route].start_with?("/vector_control/transmission_blocks", "/vector_control/tasks", "/vector_control/reports") }
      expect(linked.size).to be > 20
      linked.each do |r|
        [ scenario[:case_home].id, case_street ].each do |secret|
          expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}"
        end
      end

      # Depois da confirmação, o domicílio do caso na lista e no detalhe tem a mesma forma dos outros.
      rows = ids[:households_after].index_by { |row| row["id"] }
      expect(rows.keys).to include(scenario[:case_home].id, scenario[:home].id)
      expect(rows.fetch(scenario[:case_home].id).keys).to eq(rows.fetch(scenario[:home].id).keys)
      expect(ids[:case_home_after].keys).to eq(ids[:home_after].keys)
      expect(ids[:case_home_after]["vector"].keys).to eq(ids[:home_after]["vector"].keys)
    end

    it "toda recusa 4xx traz só error e path, sem o valor enviado" do
      expected = {
        stratum_out_of_range: %w[stratum_out_of_range strata[0]],
        inconsistent_report: %w[deposit_counts_inconsistent vector_inspection.deposits[0].with_water],
        damaged_count: [ "reading_not_countable", nil ],
        short_note: %w[invalid_request note]
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
        expect(JSON.parse(r[:raw]).keys - %w[error path]).to be_empty, "#{r[:path]}: #{r[:raw]}"
        (people + texts).each { |secret| expect(secrecy.contains?(r[:haystack], secret)).to be(false), "#{r[:path]} contém #{secret.inspect}" }
      end
    end

    # §8 e Q26(3): as listas com address_short gravam a trilha do 24a; o
    # endereço do caso grava a do prontuário e a do domicílio.
    it "as listas com address_short gravam households_listed!; o endereço do caso grava as duas trilhas" do
      listed = responses.select { |r| r[:verb] == :get }.filter_map do |r|
        rows = case r[:route]
               when "/vector_control/households" then JSON.parse(r[:raw])["items"].map { |row| row["id"] }
               when "/vector_control/due" then JSON.parse(r[:raw])["items"].map { |row| row["household_id"] }
               when "/vector_control/ovitraps", "/vector_control/liraa_surveys/:id/items"
                 JSON.parse(r[:raw])["items"].map { |row| row.dig("household", "id") }
               end
        rows && [ r[:route], rows ]
      end
      expect(listed.map(&:first).uniq).to contain_exactly("/vector_control/households", "/vector_control/due", "/vector_control/ovitraps",
                                                          "/vector_control/liraa_surveys/:id/items")
      expect(listed.flat_map(&:last).uniq).to contain_exactly(scenario[:case_home].id, scenario[:home].id)
      trail = events.select { |e| e.name == "clinical_record.viewed" && e.payload["access"] == TerritoryRegistry::Trail::ACCESS }
      trailed = trail.flat_map { |e| Array(e.payload["household_ids"]) }
      expect(trailed).to include(*listed.flat_map(&:last).uniq)

      viewed = events.select { |e| e.name == "clinical_record.viewed" && e.payload["access"] == VectorControl::Catalog::TRAIL_ACCESS }
      expect(viewed.map(&:payload)).to eq([ viewed.first.payload.merge("patient_id" => patient.id, "transmission_block_id" => ids[:tb1]) ])
      expect(trail.map(&:payload)).to include(include("household_id" => scenario[:case_home].id))
    end

    it "nenhum Platform.audit durante o cenário" do
      expect(scenario[:platform_events]).to eq(0)
    end
  end
end

# §17 (nunca em URL): toda rota de /vector_control recusa pessoa e texto na
# query (422 invalid_request), sem ecoar o valor — inclusive as que só leem e
# as de membro com id que não existe (a query antes de qualquer leitura).
RSpec.describe "Sigilo da vigilância ambiental (35a) — query de toda rota", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }

  def module_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      [ route.verb, path ] if path.match?(%r{\A/vector_control(/|\z)})
    end.uniq
  end

  it "o módulo tem as 51 rotas do contrato" do
    expect(module_routes.size).to eq(51)
  end

  it "toda rota recusa cpf e note na query (422 invalid_request, sem o valor)" do
    values = { "cpf" => "52998224725", "note" => "Texto reservado na query da rota" }
    stepped_up!(coordinator)
    failures = []
    module_routes.each do |verb, route|
      # O nome do relatório e a camada do mapa são parte da rota: inválidos dão 404/422 antes da query.
      path = route.sub(":name", "production").gsub(/:\w+/) { SecureRandom.uuid }
      prefix = route.end_with?("/map_points") ? "layer=risk&" : ""
      values.each do |key, value|
        url = "#{path}?#{prefix}#{key}=#{CGI.escape(value)}"
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

# §17: a varredura de fonte (Prism) — todo DomainEvents.publish em app/ e lib/
# com nome do módulo usa um dos 20, com nome literal (ou constante do arquivo)
# e só as chaves do contrato; nos arquivos do módulo, só os 20 e a trilha
# clinical_record.viewed (só ids). DomainEvents.publish( é multilinha: o nó da
# chamada inteira, nunca a linha.
RSpec.describe "Sigilo da vigilância ambiental (35a) — DomainEvents.publish na fonte" do
  # Nome do evento: literal, ou a constante escrita no próprio arquivo
  # (EVENT = "…".freeze); nil quando dinâmico.
  def event_name(call, constants)
    arg = call.arguments&.arguments&.first
    case arg
    when Prism::StringNode then arg.unescaped
    when Prism::ConstantReadNode then constants[arg.name]
    end
  end

  def publish_calls
    Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].flat_map do |file|
      constants = {}
      found = []
      walk = lambda do |node|
        if node.is_a?(Prism::ConstantWriteNode)
          value = node.value
          value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze
          constants[node.name] = value.unescaped if value.is_a?(Prism::StringNode)
        end
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

  def module_files = VectorControlSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.to_set

  def shared_files = VectorControlSecrecy::SHARED_FILES.map { |path| Rails.root.join(path).to_s }.to_set

  # `**payload` (ou um hash com splat) esconde as chaves da varredura.
  # Em qualquer ponto da árvore dos argumentos (também `payload: { **x }`).
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

  it "só os 20 nomes do §17, com as chaves exatas do contrato" do
    calls = publish_calls
    expect(calls.size).to be > 300 # controle: a varredura achou as chamadas do app

    contracted = calls.select { |_, _, name| name&.match?(VectorControlSecrecy::MODULE_EVENT) }
    contracted.each do |file, call, name|
      expect(VectorControlSecrecy::CONTRACT_EVENTS).to include(name), "#{where(file, call)}: #{name} fora do contrato"
      expect(keys_of(call)).to match_array(VectorControlSecrecy::PAYLOAD_KEYS.fetch(name)), "#{where(file, call)}: chaves #{keys_of(call)}"
    end
    expect(contracted.map(&:last).uniq).to match_array(VectorControlSecrecy::CONTRACT_EVENTS)
  end

  it "nos arquivos do módulo e nos compartilhados, todo publish tem nome resolvido e chaves explícitas" do
    files = module_files
    shared = shared_files
    expect(shared.select { |file| File.exist?(file) }.size).to eq(VectorControlSecrecy::SHARED_FILES.size)
    calls = publish_calls
    shared_calls = calls.select { |file, _, _| shared.include?(file) }
    expect(shared_calls.size).to be >= 4 # controle: a trilha do app, home_visit.recorded e o recebimento do 27a
    (calls.select { |file, _, _| files.include?(file) } + shared_calls).each do |file, call, name|
      expect(name).to be_present, "#{where(file, call)}: o nome do evento deve ser literal ou constante do arquivo"
      expect(splats(call)).to be_empty, "#{where(file, call)}: payload com **splat"
    end
  end

  it "nos arquivos do módulo, todo publish é um dos 20 ou a trilha (só ids)" do
    files = module_files
    module_calls = publish_calls.select { |file, _, _| files.include?(file) }
    expect(module_calls.size).to be >= 24 # controle: os 20 eventos e a trilha do endereço do caso
    module_calls.each do |file, call, name|
      expect(VectorControlSecrecy::CONTRACT_EVENTS + [ "clinical_record.viewed" ]).to include(name), "#{where(file, call)}: #{name}"
      next unless name == "clinical_record.viewed"

      expect(keys_of(call) - VectorControlSecrecy::TRAIL_KEYS).to be_empty, "#{where(file, call)}: trilha com #{keys_of(call)}"
    end
  end
end

# §17 (nenhum nome novo de Platform.audit): o módulo não audita na plataforma.
# Platform.audit( é multilinha: procura-se o nó da chamada (Prism) e o nome da
# chamada, que não quebra linha, em todo arquivo do módulo.
RSpec.describe "Sigilo da vigilância ambiental (35a) — sem Platform.audit novo" do
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

  it "nenhum arquivo do módulo chama Platform.audit e R18 segue sem nome do módulo" do
    files = VectorControlSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq
    expect(files.size).to be >= 90
    files += VectorControlSecrecy::SHARED_FILES.map { |path| Rails.root.join(path).to_s }
    %w[app/commands/vector_control/blocks/case_address.rb app/commands/vector_control/blocks/move_case.rb
       app/commands/vector_control/apply_stock.rb app/controllers/vector_control/transmission_blocks_controller.rb
       app/jobs/vector_control/propose_block_job.rb app/services/vector_control/map_points.rb app/models/transmission_block_case.rb
       app/models/vector_stock_shortfall.rb lib/vector_control_crew.rb].each do |path|
      expect(files).to include(Rails.root.join(path).to_s), "#{path} fora das globs"
    end
    expect(files.flat_map { |file| audit_calls(file) }).to be_empty
    expect(files.select { |file| File.read(file).match?(/Platform\s*\.\s*audit\b/) }).to be_empty

    app_audits = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}").to_s].sum { |file| audit_calls(file).size }
    expect(app_audits).to be > 0 # controle: a varredura acha os Platform.audit da plataforma

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include("city.feature_changed") # o que o interruptor vector_control usa
    expect(r18.grep(/vector|ovitrap|liraa|transmission_block|city_block|household_vector/)).to be_empty
    expect(Platform::Features::KEYS).to include(VectorControl::Gate::KEY)
  end
end
