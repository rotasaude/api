require "rails_helper"
require "prism"
require "webmock/rspec"

# Módulo 27b (contrato §9; Q8, Q9, Q11, Q21, Q25, Q30, Q39; R15, R18, R32;
# plano, Task 17): o sigilo do envio à BNAFAR de ponta a ponta, contra o
# SI-BNAFAR simulado (FakeBnafar::App por WebMock#to_rack em
# http://fake-bnafar.test:8095; nenhuma URL real). Um cenário só, pelas rotas
# reais e pelos dois jobs, ao longo de seis dias e da purga:
# - D: carga OBM (importObmCatalog, com TOTP); credencial nos dois ambientes
#   (usuário e senha marcados) e testada; saldo inicial pela planilha (upload,
#   apply, revert; outro upload e discard); entrada com os campos de envio
#   (um lote "RECUSA"); complemento do lote; saída externa com o motivo
#   marcado; dispensação da paciente marcada (nome, CPF, CNS); a dose da mesma
#   paciente na sala de vacina (preparo pelo razão); leituras;
# - D+1: DailyJob monta D; DeliverJob com dois 401 (credencial recusada, o
#   envio pausa), teste da credencial de novo, aceite e RECUSA; reenvio da
#   posição; correção da saída externa (PUT); estorno da dose (preparo);
# - D+2: DailyJob fecha D (a posição recusada vira lost) e monta D+1 com o
#   DELETE da dose; setBnafarEnvironment(homologation); teste da credencial de
#   homologação; outra saída externa e outra dose;
# - D+3/D+4: o mesmo ciclo em homologação, com a evidência cURL por lote: dois
#   401 (pausa e novo teste), aceite e RECUSA, correção (PUT), estorno da dose
#   (DELETE); setBnafarEnvironment(production) com código errado e com o TOTP;
# - D+5/D+6: monta D+4 em produção e nunca envia (o fechamento a perde);
#   leituras; `bnafar` desligado (403);
# - D+32 e D+40: a purga (Q30), pelo sent_at e, no nunca enviado, pelo created_at.
# Forçadas, as recusas: senha em branco, entrada sem os campos, latin-1, lote
# com versão velha, motivo curto, nada a reenviar, correção com versão velha e
# o envio desligado. Depois, as provas de ausência (log, eventos, evidência,
# payloads decifrados e o recebido pelo simulado, respostas, recusas, CSV, purga
# e a varredura de Platform.audit).
#
# Constantes num módulo próprio (dentro de um bloco do RSpec cairiam em Object).
# Tudo ASCII, palavras únicas: a varredura compara bytes sem caixa. O token
# "marcado" é cada access_token que o simulado emitiu no cenário (lido do
# próprio simulado no fim): aleatório, nunca repetido em outro lugar.
module BnafarSecrecy
  USERNAME = "UsuarioSigiloQuartzo".freeze
  PASSWORD = "SenhaSigilosaVerbena77".freeze
  HOM_USERNAME = "UsuarioHomologaTurmalina".freeze
  HOM_PASSWORD = "SenhaHomologaGardenia88".freeze
  MAINTAINER_PASSWORD = "s3nha-forte-1".freeze
  PATIENT = { full_name: "Gumercinda Xavantina Pomperella", mother_name: "Hermenegilda Ostrogoda Pomperella" }.freeze
  WORDS = %w[Gumercinda Xavantina Pomperella Hermenegilda Ostrogoda].freeze
  REASONS = {
    exit: "Reservado BN1: doacao ao hospital filantropico do bairro",
    correction: "Reservado BN2: destino corrigido depois da conferencia",
    loan: "Reservado BN3: emprestimo ao municipio vizinho da regiao"
  }.freeze
  SHORT_REASON = "Curta9 ok".freeze
  LOT = "LOSSIGILO1".freeze
  COMPLEMENT_LOT = "LOSCOMPL2".freeze
  UNIT_LOT = "LOSUNID3".freeze
  IMPORT_LOTS = %w[IMPSIGILO1 IMPSIGILO2].freeze
  CENTRAL_CNES = "1234567".freeze
  UNIT_CNES = "7654321".freeze
  ROOM_CNES = "3333333".freeze
  DESTINATION_CNPJ = "12ABC34501DE35".freeze
  AMPP = "@brasil20038375080".freeze
  VMP = "@brasil10000001".freeze
  # O lote "RECUSA" é de outro item com VMP (paracetamol; a apresentação da amostra OBM): sem VMP
  # o lote ficaria em product_without_code e não sairia (Q15).
  REFUSED_AMPP = "@brasil20038375081".freeze
  REFUSED_ANVISA = "1023500010012".freeze
  MAINTENANCE_HOST = "maintenance-api.rotasaude.app".freeze
  FRONTEND = "https://maintenance.rotasaude.app".freeze
  OBM_MUTATION = "mutation($file: String!, $code: String!) { importObmCatalog(fileBase64: $file, code: $code) " \
                 "{ ok errors { path message } added changed deactivated vmpLinked unmatched } }".freeze
  ENV_MUTATION = "mutation($citySlug: String!, $environment: String!, $code: String) { setBnafarEnvironment(citySlug: $citySlug, " \
                 "environment: $environment, code: $code) { ok errors { path message } } }".freeze
  STATUS_QUERY = "query($citySlug: String!) { cityBnafarStatus(citySlug: $citySlug) { environment environmentEditable enabledDomains " \
                 "alert { late lost rejected lastFinishedOn } startedOn } }".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  UUID_IN_PATH = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  # §9 (e Q14, o 10º): os eventos do módulo e as chaves exatas de cada payload;
  # o recebimento do 27a e a troca da credencial (R32) também entram.
  PAYLOAD_KEYS = {
    "bnafar_submission.queued" => %w[bnafar_submission_id],
    "bnafar_submission.finished" => %w[bnafar_submission_id],
    "bnafar_submission.lost" => %w[bnafar_submission_id],
    "bnafar_record.rejected" => %w[bnafar_record_id bnafar_submission_id],
    "bnafar_record.corrected" => %w[bnafar_record_id replaces_record_id user_id],
    "bnafar_record.deleted" => %w[bnafar_record_id bnafar_batch_id],
    "stock_external_exit.recorded" => %w[stock_external_exit_id user_id],
    "stock_lot.bnafar_completed" => %w[stock_lot_id user_id],
    "opening_import.applied" => %w[opening_import_id user_id],
    "opening_import.reverted" => %w[opening_import_id user_id],
    "stock_receipt.recorded" => %w[stock_entry_id user_id],
    "integration_credential.changed" => %w[kind environment user_id]
  }.freeze
  EXTRA_EVENTS = %w[stock_receipt.recorded integration_credential.changed].freeze
  # R32: os nomes do módulo (os prefixos); a dispensação e a vacina ficam fora.
  MODULE_EVENT = /\A(bnafar_|stock_external_exit\.|stock_lot\.bnafar_|opening_import\.)/
  # R15: as únicas chaves de uma recusa 4xx.
  REFUSAL_KEYS = %w[error path problems feature next_allowed_on locations].freeze
  # §9 e R18: os quatro nomes novos da plataforma.
  R18_NAMES = %w[bnafar.credential_set obm_catalog.imported maintenance.obm_catalog.imported maintenance.bnafar.environment_changed].freeze
  MODULE_GLOBS = %w[
    app/**/bnafar/**/*.rb app/models/bnafar_*.rb app/controllers/concerns/bnafar_*.rb
    app/**/opening_imports/**/*.rb app/models/opening_import*.rb app/controllers/pharmacy/opening_imports_controller.rb
    app/models/stock_external_exit*.rb app/commands/pharmacy/record_external_exit.rb app/controllers/pharmacy/external_exits_controller.rb
    app/controllers/pharmacy/lot_complements_controller.rb app/controllers/pharmacy/obm_presentations_controller.rb
    app/controllers/pharmacy/openings_controller.rb app/models/obm_presentation.rb app/services/medications/obm_import.rb
    app/graphql/maintenance/mutations/import_obm_catalog.rb app/graphql/maintenance/mutations/set_bnafar_environment.rb
    app/graphql/maintenance/types/bnafar_alert_type.rb app/graphql/maintenance/types/city_bnafar_status_type.rb
    app/graphql/maintenance/types/obm_presentation_type.rb lib/fake_bnafar/*.rb lib/bnafar_crew.rb lib/tasks/medications.rake
  ].freeze
  # A credencial é de todas as integrações (ledi, cadsus, rnds, bnafar).
  SHARED_FILES = %w[app/commands/integrations/set_credential.rb].freeze

  def self.cpf_forms(cpf) = [ cpf, "#{cpf[0, 3]}.#{cpf[3, 3]}.#{cpf[6, 3]}-#{cpf[9, 2]}" ]

  def self.route(path) = path.gsub(UUID_IN_PATH, ":id")

  def self.contains?(text, secret) = text.to_s.b.downcase.include?(secret.to_s.b.downcase)

  # Todas as chaves de um JSON, em qualquer profundidade.
  def self.keys_of(value)
    case value
    when Hash then value.keys + value.values.flat_map { |inner| keys_of(inner) }
    when Array then value.flat_map { |inner| keys_of(inner) }
    else []
    end
  end

  # Todos os valores-folha de um JSON, em qualquer profundidade.
  def self.leaves_of(value)
    case value
    when Hash then value.values.flat_map { |inner| leaves_of(inner) }
    when Array then value.flat_map { |inner| leaves_of(inner) }
    else [ value ]
    end
  end
end

RSpec.describe "Sigilo do envio à BNAFAR (27b)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Método, e não let: o cenário roda no seed_once (before(:context)).
  def secrecy = BnafarSecrecy

  def test_city = City.find_by!(slug: TEST_CITY_A.slug)

  # A cidade no Current, com bloco (nunca Current.city solto).
  def in_city(&) = Current.set(city: test_city, &)

  def json_headers = { "CONTENT_TYPE" => "application/json" }

  def maintenance_headers = { "Origin" => secrecy::FRONTEND, "X-Rota-Maintenance" => "1" }

  # Toda resposta do cenário (cidade e manutenção): rota, status e corpo.
  def keep!(session = self)
    @responses << { verb: session.request.request_method, path: session.request.path, route: secrecy.route(session.request.path),
                    status: session.response.status, raw: session.response.body.dup, media_type: session.response.media_type }
  end

  def call_city(verb, path, body)
    verb == :get ? get(path, headers: {}) : public_send(verb, path, params: (body || {}).to_json, headers: json_headers)
    keep!
  end

  def req(verb, path, body = nil)
    call_city(verb, path, body)
    raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

    response.media_type == "application/json" && response.body.present? ? JSON.parse(response.body) : response.body
  end

  def refuse(label, verb, path, body = nil, status:, sent: [])
    call_city(verb, path, body)
    raise "#{label}: #{verb} #{path} → #{response.status} #{response.body}" unless response.status == status

    @refusals << { label: label, status: response.status, raw: response.body.dup, json: JSON.parse(response.body), sent: Array(sent) }
  end

  # O relógio anda 31 s (um TOTP vale uma vez por conta) e devolve o código do momento.
  def fresh_totp!
    travel_to(Time.current + 31.seconds)
    ROTP::TOTP.new(@maintainer.otp_secret).now.tap { |code| @codes << code }
  end

  # Sessão de integração própria do maintenance (outro host e outro cookie).
  def maintenance_login!
    session = open_session
    session.host!(secrecy::MAINTENANCE_HOST)
    session.post "/session", params: { email_address: @maintainer.email_address, password: secrecy::MAINTAINER_PASSWORD },
                             headers: maintenance_headers
    keep!(session)
    session_id = JSON.parse(session.response.body).fetch("session_id")
    session.post "/session/challenge", params: { session_id: session_id, code: fresh_totp! }, headers: maintenance_headers
    keep!(session)
    raise "login do maintenance → #{session.response.status} #{session.response.body}" unless session.response.successful?

    session
  end

  def gql!(session, query, **variables)
    session.post "/graphql", params: { query: query, variables: variables.to_json }, headers: maintenance_headers
    keep!(session)
    body = JSON.parse(session.response.body)
    raise "graphql → #{session.response.status} #{session.response.body}" unless session.response.successful? && body["errors"].nil?

    body
  end

  def mutation_ok!(body, field)
    result = body.dig("data", field)
    raise "#{field} → #{result.inspect}" unless result && result["ok"]

    result
  end

  # O preparo do envio (fora das rotas, como o bnafar_on! das specs do módulo,
  # mas com a credencial já gravada pela rota): IBGE, os ajustes e os
  # interruptores — o `bnafar`, os domínios de medicamentos e vacinas e o
  # simulado. Ligados agora: `Gate.domains_through` conta o dia.
  def enable_bnafar!(city)
    maintainer = ledi_maintainer!
    city_profile!
    BnafarSetting.ensure_defaults!
    [ Bnafar::Gate::KEY, "bnafar_medications", "bnafar_vaccines", Bnafar::Mock::KEY ].each do |key|
      Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer)
    end
    CityCatalog.reset_cache!
  end

  def run_daily! = Bnafar::DailyJob.perform_now
  def run_deliver!(times = 1) = times.times { Bnafar::DeliverJob.perform_now }

  def submission(day, subject, environment = "production")
    in_city { BnafarSubmission.find_by!(reference_on: day, subject: subject, environment: environment) }
  end

  def secrecy_scenario!
    s = secrecy
    city = pharmacy_city!
    vaccination_city!
    zone = ActiveSupport::TimeZone[city.time_zone]
    day = zone.today + 2
    at = ->(offset, hour, min = 0) { zone.local((day + offset).year, (day + offset).month, (day + offset).day, hour, min) }
    @responses = []
    @refusals = []
    @codes = []

    # Preparo (agora, antes de D): locais com CNES, equipe, o mantenedor, a
    # paciente marcada com a receita, o lote da UBS (completo) e o da sala de
    # vacina (completo; o YAML da vacina 42 com VMP e CNPJ, Q21).
    admin = pharmacy_admin!
    central = central_location!.tap { |location| location.update_columns(cnes: s::CENTRAL_CNES) }
    farmacia = unit_location!(create_unit("UBS Sigilo Farmacia", cnes: s::UNIT_CNES))
    keeper = pharmacy_staff!(central, "stock_keeper")
    pharmacist = pharmacy_staff!(farmacia, "pharmacist")
    room = vaccine_room!(create_unit("UBS Sigilo Vacina", cnes: s::ROOM_CNES))
    @maintainer = Maintainer.create!(email_address: "bnafar-sigilo-#{SecureRandom.hex(3)}@rotasaude.app", password: s::MAINTAINER_PASSWORD,
                                     otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)

    n = registry_seq!
    care = create_unit("UBS Sigilo Consulta")
    consultation = started_consultation!(unit: care, doctor: doctor!(care),
                                         citizen: verified_citizen!(n % 30 + 1, full_name: s::PATIENT[:full_name], mother_name: s::PATIENT[:mother_name]))
    patient = consultation.patient
    patient.update!(cns: valid_cns(n)) if patient.cns.blank?
    prescription = pharmacy_prescription!(consultation: consultation, items: [ { catalog: losartana } ])
    unit_lot = bnafar_complete!(stocked_lot!(farmacia, item: losartana, quantity: "40", lot_number: s::UNIT_LOT, expires_on: day + 300),
                                ampp_code: s::AMPP)
    complement_lot = stocked_lot!(central, item: losartana, quantity: "20", lot_number: s::COMPLEMENT_LOT, expires_on: day + 300)

    yaml = Vaccination::Immunobiologicals.find("42")
    maker = yaml.manufacturers.first
    allow(Vaccination::Immunobiologicals).to receive(:find).and_call_original
    allow(Vaccination::Immunobiologicals).to receive(:find).with("42")
                                                           .and_return(yaml.with(obm_vmp: "@brasil7000", manufacturers: [ maker.with(cnpj: bnafar_cnpj) ]))
    vaccine = bnafar_complete!(vaccine_lot!(room, code: "42", doses: 10, manufacturer_key: maker.key, expires_on: day + 300), ampp_code: "@brasil70001")

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_BNAFAR_URL").and_return(FAKE_BNAFAR_BASE)
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(s::FRONTEND)
    fake = fake_bnafar!
    Bnafar::Client.reset_cache!

    header = OpeningImports::Reader::HEADER.join(";")
    csv_lines = s::IMPORT_LOTS.map do |lot_number|
      [ s::CENTRAL_CNES, "medicamento", amoxicilina.catmat_code, "", lot_number, (day + 200).iso8601, "40", "1,25", bnafar_cnpj,
        "1234567890123", "AFB" ].join(";")
    end
    csvs = csv_lines.map { |line| "#{header}\r\n#{line}\r\n" }
    encoded = csvs.map { |csv| Base64.strict_encode64(csv) }
    obm = Base64.strict_encode64(Rails.root.join("spec/fixtures/obm/sample.csv").read)
    latin1 = Base64.strict_encode64(File.binread(Rails.root.join("spec/fixtures/opening_imports/latin1.csv")))

    fields = { unit_price_cents: 1990, manufacturer_cnpj: bnafar_cnpj, anvisa_registration: "1234567890123", health_program: "AFB" }
    line = lambda do |item, lot_number, **over|
      { catalog_item_id: item.id, lot_number: lot_number, expires_on: (day + 300).iso8601, manufacturer: "EMS", package: nil,
        quantity: "30" }.merge(over)
    end
    receipt = ->(items) { { location_id: central.id, document: { kind: "invoice", number: "NF-27B-#{SecureRandom.hex(2)}", supplier: "Distribuidora Sul" }, items: items } }
    exit_body = lambda do |lot, **over|
      { location_id: central.id, exit_type: "S-D", destination_kind: "cnpj", destination_code: s::DESTINATION_CNPJ, reason: s::REASONS[:exit],
        items: [ { lot_id: lot.id, quantity: 3 } ] }.merge(over)
    end

    ids = {}
    started_at = at.(0, 0)
    platform_before = PlatformEvent.pluck(:id)
    log = capture_log do
      # D 07:00 — a carga OBM pelo maintenance (fora de produção; TOTP).
      travel_to(at.(0, 7))
      maintenance = maintenance_login!
      ids[:obm] = mutation_ok!(gql!(maintenance, s::OBM_MUTATION, file: obm, code: fresh_totp!), "importObmCatalog")

      # D 07:30 — a credencial nos dois ambientes (Q9) e o teste.
      travel_to(at.(0, 7, 30))
      stepped_up!(admin)
      refuse(:blank_password, :put, "/integrations/credentials/bnafar", { username: s::USERNAME, password: " " }, status: 422, sent: [ s::USERNAME ])
      req(:put, "/integrations/credentials/bnafar", { username: s::USERNAME, password: s::PASSWORD })
      req(:put, "/integrations/credentials/bnafar", { username: s::HOM_USERNAME, password: s::HOM_PASSWORD, environment: "homologation" })
      enable_bnafar!(city)
      ids[:check] = req(:post, "/integrations/credentials/bnafar/check", {})
      req(:get, "/integrations")

      # D 08:00 — o saldo inicial pela planilha: upload, apply, revert; outro upload e discard.
      travel_to(at.(0, 8))
      stepped_up!(admin)
      refuse(:latin1, :post, "/pharmacy/opening_imports", { file_base64: latin1 }, status: 422)
      first = req(:post, "/pharmacy/opening_imports", { file_base64: encoded[0] })
      file_data_of = ->(id) { in_city { OpeningImport.find(id).file_data } }
      ids[:file_data_uploaded] = [ file_data_of.(first["id"]) ]
      req(:get, "/pharmacy/opening_imports/#{first['id']}")
      ids[:applied] = req(:post, "/pharmacy/opening_imports/#{first['id']}/apply", { expected_version: first["version"] })
      travel_to(at.(0, 8, 5))
      stepped_up!(admin)
      ids[:reverted] = req(:post, "/pharmacy/opening_imports/#{first['id']}/revert", { expected_version: ids[:applied]["version"] })
      second = req(:post, "/pharmacy/opening_imports", { file_base64: encoded[1] })
      ids[:file_data_uploaded] << file_data_of.(second["id"])
      ids[:discarded] = req(:post, "/pharmacy/opening_imports/#{second['id']}/discard", { expected_version: second["version"] })
      req(:get, "/pharmacy/opening_imports")
      req(:get, "/pharmacy/opening_imports/template.csv")
      ids[:imports] = [ first["id"], second["id"] ]

      # D 09:00 — entrada com os campos (Q7, Q15), complemento e saída externa.
      travel_to(at.(0, 9))
      stepped_up!(keeper)
      refuse(:required, :post, "/pharmacy/receipts", receipt.([ line.(losartana, "LOSFALTA9") ]), status: 422)
      refused_line = line.(catalog_item(267_778), FakeBnafar::App::REFUSED_LOT, **fields, anvisa_registration: s::REFUSED_ANVISA,
                                                                                       ampp_code: s::REFUSED_AMPP)
      req(:post, "/pharmacy/receipts", receipt.([ line.(losartana, s::LOT, **fields, ampp_code: s::AMPP), refused_line ]))
      lot = StockLot.find_by!(lot_number: s::LOT)
      req(:patch, "/pharmacy/lots/#{complement_lot.id}/bnafar", { location_id: central.id, expected_version: complement_lot.reload.bnafar_version,
                                                                  **fields, ampp_code: s::AMPP })
      refuse(:stale_lot, :patch, "/pharmacy/lots/#{complement_lot.id}/bnafar", { location_id: central.id, expected_version: 0, unit_price_cents: 2500 },
             status: 409)
      refuse(:short_reason, :post, "/pharmacy/external_exits", exit_body.(lot, reason: s::SHORT_REASON), status: 422, sent: [ s::SHORT_REASON ])
      ids[:exit] = req(:post, "/pharmacy/external_exits", exit_body.(lot))

      # D 10:00 — a dispensação da paciente marcada (nunca vai à BNAFAR) e a
      # dose dela na sala (preparo pelo razão, como o 29 grava).
      travel_to(at.(0, 10))
      sign_in_as(pharmacist)
      req(:post, "/pharmacy/dispensations", { location_id: farmacia.id, prescription: { kind: "digital", id: prescription.id },
                                              items: [ { prescription_item_id: prescription.prescription_items.first.id, lot_id: unit_lot.id, quantity: "10" } ] })
      dose = in_city { create_immunization!(room, patient: patient, stock_lot: vaccine, immunobiological_code: "42", applied_at: Time.current) }
      in_city { Pharmacy::Ledger.record!(location: room.stock_location, lot: vaccine, kind: "immunization", quantity: 1, by: admin, document: dose) }

      # D 11:00 — leituras.
      travel_to(at.(0, 11))
      stepped_up!(admin)
      req(:get, "/pharmacy/bnafar/domains")
      req(:get, "/pharmacy/bnafar/pendencies")
      req(:get, "/pharmacy/obm_presentations?vmp_code=#{CGI.escape(s::VMP)}")
      sign_in_as(keeper)
      req(:get, "/pharmacy/openings?location_id=#{central.id}")
      req(:get, "/pharmacy/external_exits?location_id=#{central.id}")
      req(:get, "/pharmacy/external_exits/#{ids[:exit]['id']}")
      req(:get, "/pharmacy/lots/#{lot.id}/movements?location_id=#{central.id}")

      # D+1 01:07 — monta D; o envio com dois 401 (token guardado: o 401 repete
      # uma vez com token novo) recusa a credencial e pausa; o teste a reabilita.
      travel_to(at.(1, 1, 7))
      run_daily!
      in_city { Bnafar::Client.for(test_city, environment: "production").token! }
      fake.failures.push(401, nil, 401)
      run_deliver!
      ids[:unauthorized] = in_city { IntegrationCredential.find_by!(kind: "bnafar", environment: "production").last_check_status }
      travel_to(at.(1, 1, 20))
      stepped_up!(admin)
      req(:post, "/integrations/credentials/bnafar/check", {})
      run_deliver!(3)

      # D+1 09:00 — reenvio da posição recusada e correção da saída externa (PUT).
      travel_to(at.(1, 9))
      stepped_up!(admin)
      position = submission(day, "position")
      exits = submission(day, "exit")
      refuse(:nothing_to_retry, :post, "/pharmacy/bnafar/submissions/#{exits.id}/retry", {}, status: 409)
      req(:post, "/pharmacy/bnafar/submissions/#{position.id}/retry", {})
      original = in_city { exits.records.find_by!(stock_location_id: central.id, replaces_record_id: nil) }
      fix = { expected_version: 1, destination_kind: "cnes", destination_code: "2384299", reason: s::REASONS[:correction] }
      ids[:corrected] = req(:post, "/pharmacy/bnafar/records/#{original.id}/correct", fix)
      refuse(:stale_exit, :post, "/pharmacy/bnafar/records/#{original.id}/correct", fix, status: 409, sent: [ s::REASONS[:correction] ])
      run_deliver!(3)

      # D+1 10:00 — o estorno da dose aceita (preparo pelo razão).
      travel_to(at.(1, 10))
      in_city { Pharmacy::Ledger.record!(location: room.stock_location, lot: vaccine, kind: "immunization_reversal", quantity: 1, by: admin, document: dose) }

      # D+2 01:07 — fecha D (a posição recusada vira lost), monta D+1 e o DELETE da dose.
      travel_to(at.(2, 1, 7))
      run_daily!
      run_deliver!(3)

      # D+2 09:00 — homologação (sem TOTP, Q39) e o teste da credencial dela.
      travel_to(at.(2, 9))
      maintenance = maintenance_login!
      mutation_ok!(gql!(maintenance, s::ENV_MUTATION, citySlug: city.slug, environment: "homologation"), "setBnafarEnvironment")
      stepped_up!(admin)
      req(:get, "/integrations")
      ids[:hom_check] = req(:post, "/integrations/credentials/bnafar/check", {})
      stepped_up!(keeper)
      ids[:loan] = req(:post, "/pharmacy/external_exits", exit_body.(lot, exit_type: "S-E", destination_kind: "cnes", destination_code: "2384299",
                                                                     reason: s::REASONS[:loan], items: [ { lot_id: lot.id, quantity: 2 } ]))
      # D+2 10:00 — outra dose da paciente (preparo), para o DELETE em homologação.
      travel_to(at.(2, 10))
      hom_dose = in_city { create_immunization!(room, patient: patient, stock_lot: vaccine, immunobiological_code: "42", applied_at: Time.current) }
      in_city { Pharmacy::Ledger.record!(location: room.stock_location, lot: vaccine, kind: "immunization", quantity: 1, by: admin, document: hom_dose) }

      # D+3 01:07 — homologação: monta D+2 e envia com dois 401 (a credencial de
      # homologação recusada, o envio pausa), o teste a reabilita; aceite e RECUSA.
      # Cada chamada entra na evidência do lote (Q8).
      travel_to(at.(3, 1, 7))
      run_daily!
      in_city { Bnafar::Client.for(test_city, environment: "homologation").token! }
      fake.failures.push(401, nil, 401)
      run_deliver!
      ids[:hom_unauthorized] = in_city { IntegrationCredential.find_by!(kind: "bnafar", environment: "homologation").last_check_status }
      travel_to(at.(3, 1, 20))
      stepped_up!(admin)
      req(:post, "/integrations/credentials/bnafar/check", {})
      run_deliver!(3)

      # D+3 09:00 — correção (PUT) da saída de homologação; D+3 10:00 — o estorno da dose.
      travel_to(at.(3, 9))
      stepped_up!(admin)
      hom_original = in_city { submission(day + 2, "exit", "homologation").records.find_by!(stock_location_id: central.id, replaces_record_id: nil) }
      ids[:hom_corrected] = req(:post, "/pharmacy/bnafar/records/#{hom_original.id}/correct",
                                { expected_version: 1, destination_kind: "cnes", destination_code: "2384043", reason: s::REASONS[:correction] })
      run_deliver!(3)
      travel_to(at.(3, 10))
      in_city { Pharmacy::Ledger.record!(location: room.stock_location, lot: vaccine, kind: "immunization_reversal", quantity: 1, by: admin, document: hom_dose) }

      # D+4 01:07 — homologação: monta D+3 com o DELETE da dose; envia.
      travel_to(at.(4, 1, 7))
      run_daily!
      run_deliver!(3)

      # D+4 09:00 — volta a production: sem o TOTP certo, recusado; com ele, ok (Q39).
      travel_to(at.(4, 9))
      maintenance = maintenance_login!
      gql!(maintenance, s::STATUS_QUERY, citySlug: city.slug)
      @codes << "000000"
      ids[:wrong_code] = gql!(maintenance, s::ENV_MUTATION, citySlug: city.slug, environment: "production", code: "000000").dig("data", "setBnafarEnvironment")
      mutation_ok!(gql!(maintenance, s::ENV_MUTATION, citySlug: city.slug, environment: "production", code: fresh_totp!), "setBnafarEnvironment")
      stepped_up!(admin)
      req(:get, "/integrations")

      # D+5 01:07 — monta D+4 em produção; nunca envia. D+6 00:07 — o fechamento a perde.
      travel_to(at.(5, 1, 7))
      run_daily!
      travel_to(at.(6, 0, 7))
      run_daily!

      # D+6 09:00 — leituras de tudo; os payloads decifrados e o que o simulado recebeu.
      travel_to(at.(6, 9))
      stepped_up!(admin)
      req(:get, "/pharmacy/bnafar/status")
      req(:get, "/pharmacy/bnafar/submissions?limit=100")
      # Só as do ambiente em uso (Q35: as de homologação voltam 404 em production).
      in_city { BnafarSubmission.where(environment: "production").pluck(:id) }.each { |id| req(:get, "/pharmacy/bnafar/submissions/#{id}") }
      req(:get, "/pharmacy/bnafar/pendencies")
      ids[:payloads] = in_city { BnafarRecord.all.to_a.map { |record| [ record.id, record.payload ] } }
      ids[:received] = fake.received.map { |entry| entry[:body] }
      ids[:evidence] = in_city do
        BnafarBatch.joins(:bnafar_submission).pluck(:id, "bnafar_submissions.environment", :evidence, :operation)
      end
      ids[:dispensing] = in_city { StockMovement.where(kind: "dispensing").pluck(:id) }
      ids[:links] = in_city { BnafarMovementLink.pluck(:stock_movement_id) }
      ids[:submissions] = in_city { BnafarSubmission.pluck(:reference_on, :subject, :environment, :status) }
      ids[:records] = in_city { BnafarRecord.pluck(:status, :deleted_at, :replaces_record_id) }
      ids[:batches] = in_city { BnafarBatch.pluck(:operation, :status) }

      # O envio desligado: a rota de situação recusa (403 com `feature`); a purga segue (R19).
      Platform::Features.set!(city: city, key: Bnafar::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      refuse(:bnafar_off, :get, "/pharmacy/bnafar/status", nil, status: 403)

      # Q30: a purga pelo sent_at e, no nunca enviado, pelo created_at.
      purge_state = -> { in_city { BnafarRecord.pluck(:id, :status, :sent_at, :created_at, Arel.sql("payload IS NULL")) } }
      ids[:before_purge] = purge_state.call
      travel_to(at.(32, 12))
      run_daily!
      ids[:purge_at] = Time.current
      ids[:partial_purge] = purge_state.call
      travel_to(at.(40, 12))
      run_daily!
      ids[:full_purge] = purge_state.call
      ids[:file_data] = ids[:imports].map { |id| in_city { OpeningImport.find(id).file_data } }
    end

    { ids: ids, log: log, responses: @responses, refusals: @refusals, codes: @codes, started_at: started_at,
      tokens: fake.instance_variable_get(:@tokens).keys, fake_log: fake.log.dup, patient: patient, csvs: csvs, csv_lines: csv_lines,
      encoded: encoded + [ obm ], platform_events: PlatformEvent.where.not(id: platform_before).to_a, central: central }
  end

  describe "cenário" do
    # O cenário roda uma vez por arquivo (api#159). O before(type: :request)
    # do harness não roda aqui: o host vem à mão, e os dublês (ENV, YAML da
    # vacina) vivem num escopo temporário. O WebMock do simulado vale só aqui.
    seed_once do
      use_test_city_host!
      RSpec::Mocks.with_temporary_scope do
        allow(Ledi::DeliverJob).to receive(:perform_later)
        @scenario = secrecy_scenario!
      end
    ensure
      travel_back
      Bnafar::Client.reset_cache!
    end
    let(:scenario) { @scenario }
    let(:ids) { scenario[:ids] }
    let(:patient) { scenario[:patient] }
    let(:credentials) { [ secrecy::USERNAME, secrecy::PASSWORD, secrecy::HOM_USERNAME, secrecy::HOM_PASSWORD ] }
    let(:tokens) { scenario[:tokens] }
    let(:people) { [ secrecy::PATIENT[:full_name], secrecy::PATIENT[:mother_name], *secrecy::WORDS, patient.cns, *secrecy.cpf_forms(patient.cpf) ] }
    let(:reasons) { secrecy::REASONS.values + [ secrecy::SHORT_REASON ] }
    # O arquivo: o base64 enviado e as linhas de dados (o cabeçalho é o do modelo, template.csv).
    let(:csv_content) { scenario[:encoded] + scenario[:csv_lines] }
    let(:events) { DomainEvent.where(occurred_at: scenario[:started_at]..).order(:occurred_at, :created_at).to_a }
    let(:module_events) { events.select { |e| e.name.match?(secrecy::MODULE_EVENT) || secrecy::EXTRA_EVENTS.include?(e.name) } }
    let(:responses) { scenario[:responses] }

    it "percorreu o cenário inteiro (controle positivo)" do
      expect(patient.full_name).to eq(secrecy::PATIENT[:full_name])
      expect(patient.cpf).to be_present
      expect(patient.cns).to be_present
      expect(ids[:obm]).to include("ok" => true, "vmpLinked" => 2)
      expect(ids[:check]).to include("last_check_status" => "ok", "environment" => "production")
      expect(ids[:hom_check]).to include("last_check_status" => "ok", "environment" => "homologation")
      expect(ids[:unauthorized]).to eq("unauthorized")
      expect(ids[:hom_unauthorized]).to eq("unauthorized")
      expect(ids[:hom_corrected]["records"].sole).to include("status" => "pending", "subject" => "exit")
      expect(ids[:applied]).to include("status" => "applied")
      expect(ids[:reverted]).to include("status" => "reverted")
      expect(ids[:discarded]).to include("status" => "discarded")
      expect(ids[:corrected]["records"].sole).to include("status" => "pending", "subject" => "exit")
      expect(ids[:wrong_code]).to include("ok" => false)
      expect(BnafarSetting.current.environment).to eq("production")

      # As remessas: D (posição perdida pela recusa; saídas aceitas, corrigidas e com o DELETE),
      # D+1 em produção, D+2 em homologação e D+3 nunca enviada.
      expect(ids[:submissions].map { |row| row[2] }.uniq).to contain_exactly("production", "homologation")
      expect(ids[:submissions].select { |row| row[2] == "homologation" }.map { |row| row[3] }).to include("finished")
      expect(ids[:submissions].map { |row| row[3] }).to include("lost", "finished")
      expect(ids[:records].map(&:first)).to include("accepted", "rejected", "pending")
      expect(ids[:records].count { |_, deleted_at, _| deleted_at }).to eq(2) # as doses estornadas, uma por ambiente (Q14)
      expect(ids[:records].count { |_, _, replaces| replaces }).to eq(2) # as correções das saídas externas (PUT), uma por ambiente
      expect(ids[:batches].map(&:first).uniq).to contain_exactly("post", "put", "delete")
      expect(scenario[:fake_log].map(&:first).uniq).to include("POST", "PUT", "DELETE", "GET")
      expect(tokens.size).to be >= 4

      expect(scenario[:refusals].map { |r| r[:label] })
        .to eq(%i[blank_password latin1 required stale_lot short_reason nothing_to_retry stale_exit bnafar_off])
    end

    # §9 e R32: os eventos do módulo são exatamente os do catálogo, cada
    # payload só com as suas chaves (ids; `kind` e `environment` na credencial).
    it "os eventos do módulo = Bnafar::Catalog::DOMAIN_EVENTS (+ recebimento e credencial), só ids" do
      expect(secrecy::PAYLOAD_KEYS.keys - secrecy::EXTRA_EVENTS).to match_array(Bnafar::Catalog::DOMAIN_EVENTS)
      published = events.map(&:name).select { |name| name.match?(secrecy::MODULE_EVENT) }.uniq
      expect(published).to match_array(Bnafar::Catalog::DOMAIN_EVENTS)
      expect(events.map(&:name)).to include(*secrecy::EXTRA_EVENTS)

      module_events.each do |event|
        expect(event.payload.keys).to match_array(secrecy::PAYLOAD_KEYS.fetch(event.name)), "#{event.name} publica #{event.payload.keys}"
        event.payload.each do |key, value|
          case key
          when "kind" then expect(value).to eq("bnafar")
          when "environment" then expect(value).to be_in(Bnafar::Catalog::ENVIRONMENTS)
          else expect(value.to_s).to match(secrecy::UUID), "#{event.name}.#{key}"
          end
        end
      end
      expect(events.select { |e| e.name == "integration_credential.changed" }.map { |e| e.payload["environment"] })
        .to contain_exactly("production", "homologation")

      # Nenhum evento do cenário (nem a dispensação nem a vacina) leva segredo, pessoa, motivo ou o CSV.
      payloads = events.map { |e| [ e.name, e.payload ] }.to_json
      (credentials + tokens + people + reasons + csv_content).each do |secret|
        expect(secrecy.contains?(payloads, secret)).to be(false), "evento contém #{secret.inspect}"
      end
    end

    it "o log do cenário não tem usuário, senha, token, Basic/jwt, CPF, nome da paciente, motivo nem o arquivo" do
      log = scenario[:log]
      # Controle: a captura viu as rotas, os jobs e o filtro agiu.
      expect(log).to include("/integrations/credentials/bnafar", "/pharmacy/opening_imports", "/pharmacy/external_exits",
                             "/pharmacy/bnafar/records", "/pharmacy/dispensations", "/graphql", "bnafar_submissions", "[FILTERED]")
      (credentials + [ secrecy::MAINTAINER_PASSWORD ] + tokens + people + reasons + csv_content).each do |secret|
        expect(secrecy.contains?(log, secret)).to be(false), "log contém #{secret.inspect}"
      end
      expect(log).not_to match(/Basic\s+[A-Za-z0-9+\/=]{8,}/)
      expect(log).not_to match(/jwt\s+(?!<TOKEN>)[\w.\-]{8,}/i)
      # Q39: o TOTP do maintenance nunca como valor de `code`.
      scenario[:codes].uniq.each { |code| expect(log).not_to match(/code\W{1,8}#{code}\b/), "log contém o código #{code}" }

      logged = log.scan(/"(username|password|reason|file_base64|destination_code|variables|query)"\s*=>\s*("[^"]*"|\[FILTERED\])/)
      expect(logged.map(&:first).uniq).to include("username", "password", "reason", "file_base64", "destination_code", "variables")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    # Q8 e Q21: a evidência existe só em homologação, sem senha nem token real.
    it "bnafar_batches.evidence só em homologação, por operação (post, put, delete e o 401), sem usuário, senha nem token" do
      evidence = ids[:evidence].map { |id, environment, entries, operation| { id: id, environment: environment, entries: entries, operation: operation } }
      expect(evidence.select { |batch| batch[:entries].present? }.map { |batch| batch[:environment] }.uniq).to eq([ "homologation" ])
      expect(evidence.select { |batch| batch[:environment] == "production" }.map { |batch| batch[:entries] }).to all(be_nil)
      homologation = evidence.select { |batch| batch[:environment] == "homologation" }
      expect(homologation.map { |batch| batch[:entries] }).to all(be_present)
      # O ciclo inteiro passou pela homologação: POST, PUT e DELETE.
      expect(homologation.map { |batch| batch[:operation] }.uniq).to contain_exactly("post", "put", "delete")

      verbs = { "post" => "POST", "put" => "PUT", "delete" => "DELETE" }
      homologation.group_by { |batch| batch[:operation] }.each do |operation, batches|
        entries = batches.flat_map { |batch| batch[:entries] }
        curls = entries.map { |entry| entry["curl"] }.join("\n")
        expect(curls).to include("curl -X #{verbs.fetch(operation)} ", "Authorization: jwt <TOKEN>"), "#{operation}: #{curls[0, 200]}"
        expect(entries.map { |entry| entry["status"] }).to include(200), operation
        text = JSON.generate(entries)
        (credentials + tokens + people + reasons).each do |secret|
          expect(secrecy.contains?(text, secret)).to be(false), "evidência #{operation} contém #{secret.inspect}"
        end
        expect(text).not_to match(/jwt (?!<TOKEN>)/), operation
        expect(text).not_to match(/Basic\s+[A-Za-z0-9+\/=]{8,}/), operation
      end

      # A tentativa com os dois 401: o login (só os marcadores, sem corpo) e as duas chamadas 401, na evidência do lote.
      refused = homologation.select { |batch| batch[:entries].count { |entry| entry["status"] == 401 } >= 2 }
      expect(refused).not_to be_empty
      refused.each do |batch|
        logins = batch[:entries].select { |entry| entry["curl"].include?("jwtauth") }
        expect(logins).not_to be_empty
        expect(logins.map { |entry| entry["curl"] }).to all(include("-u '<USUARIO>:<SENHA>'"))
        expect(logins.map { |entry| entry["body"] }).to all(be_nil)
      end
      # A RECUSA da posição de homologação: o registro recusado tem a evidência do POST.
      expect(homologation.select { |batch| batch[:operation] == "post" }.flat_map { |batch| batch[:entries] }.map { |entry| entry["body"].to_s }.join)
        .to include("MSG09")
    end

    # §9: nenhum dado de pessoa vai à BNAFAR; a dispensação não entra e o S-PA fica fora.
    it "nenhum payload decifrado nem o recebido pelo simulado tem CPF, CNS, nome, motivo ou S-PA; a dispensação nunca sai" do
      payloads = ids[:payloads].map(&:last)
      expect(payloads).to all(be_present) # antes da purga
      sent = (payloads + ids[:received].map(&:to_json)).join("\n")
      expect(ids[:received].size).to be >= 6
      expect(sent).to include("S-D", "S-CA", secrecy::CENTRAL_CNES) # controle
      (people + credentials + tokens + reasons).each do |secret|
        expect(secrecy.contains?(sent, secret)).to be(false), "payload contém #{secret.inspect}"
      end
      expect(sent).not_to include("S-PA")
      expect(sent).not_to match(/\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/)

      # A dispensação nunca vira registro nem item: nenhum link e nenhum codigoOrigem dela.
      expect(ids[:dispensing]).not_to be_empty
      expect(ids[:links] & ids[:dispensing]).to be_empty
      origins = payloads.flat_map { |raw| [ JSON.parse(raw) ].flatten }.flat_map { |record| Array(record["itens"]).map { |item| item["codigoOrigem"] } }
      expect(origins & ids[:dispensing]).to be_empty
    end

    it "nenhuma resposta traz usuário, senha, token, payload ou o CSV; a paciente só na dispensação" do
      expect(responses.size).to be > 50
      expect(responses.map { |r| r[:route] }).to include("/graphql", "/integrations", "/pharmacy/bnafar/submissions/:id", "/pharmacy/opening_imports/:id",
                                                         "/pharmacy/bnafar/records/:id/correct", "/pharmacy/bnafar/submissions/:id/retry",
                                                         "/pharmacy/opening_imports/template.csv", "/pharmacy/external_exits/:id")
      responses.each do |r|
        (credentials + tokens + csv_content).each do |secret|
          expect(secrecy.contains?(r[:raw], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}"
        end
        %w[codigoOrigem caracterizacao dataPosicaoEstoque file_data file_sha256].each do |fragment|
          expect(r[:raw]).not_to include(fragment), "#{r[:verb]} #{r[:path]} traz #{fragment}"
        end
        next unless r[:media_type] == "application/json" && r[:raw].present?

        expect(secrecy.keys_of(JSON.parse(r[:raw])).grep(/\A(payload|evidence|secret|password|username|token|access_token)\z/)).to be_empty,
               "#{r[:verb]} #{r[:path]}"
      end
      others = responses.reject { |r| r[:route] == "/pharmacy/dispensations" && r[:verb] == "POST" }
      others.each do |r|
        (people + [ patient.id ]).each { |secret| expect(secrecy.contains?(r[:raw], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}" }
      end
    end

    # R15: toda recusa 4xx só com error, path, problems, feature, next_allowed_on e locations; sem o valor enviado.
    it "toda recusa 4xx só com as chaves do R15, sem o valor enviado" do
      expected = {
        blank_password: [ "invalid_credential", nil ], latin1: %w[invalid_file file_base64], required: %w[required items[0].unit_price_cents],
        stale_lot: [ "lot_bnafar_changed", nil ], short_reason: %w[invalid_request reason], nothing_to_retry: [ "nothing_to_retry", nil ],
        stale_exit: [ "external_exit_changed", nil ], bnafar_off: [ "feature_disabled", nil ]
      }
      scenario[:refusals].each do |refusal|
        expect(refusal[:json]["error"]).to eq(expected.fetch(refusal[:label]).first), "#{refusal[:label]}: #{refusal[:json]}"
        path = expected.fetch(refusal[:label]).last
        expect(refusal[:json]["path"]).to eq(path), "#{refusal[:label]}: #{refusal[:json]}" if path
        refusal[:sent].each { |sent| expect(secrecy.contains?(refusal[:raw], sent)).to be(false), "#{refusal[:label]} ecoa o valor enviado" }
      end
      expect(scenario[:refusals].find { |r| r[:label] == :bnafar_off }[:json]).to eq("error" => "feature_disabled", "feature" => "bnafar")
      expect(scenario[:refusals].find { |r| r[:label] == :required }[:json]["problems"]).to be_present

      failures = responses.select { |r| r[:status].between?(400, 499) }
      expect(failures.size).to eq(scenario[:refusals].size)
      failures.each do |r|
        expect(JSON.parse(r[:raw]).keys - secrecy::REFUSAL_KEYS).to be_empty, "#{r[:path]}: #{r[:raw]}"
        (credentials + tokens + people + reasons).each { |secret| expect(secrecy.contains?(r[:raw], secret)).to be(false), "#{r[:path]} contém #{secret.inspect}" }
      end
    end

    # §5 e §9: o CSV é cifrado e apagado — depois do apply e do discard.
    it "opening_imports.file_data preenchido depois do upload e NULL depois do apply e do discard" do
      expect(ids[:file_data_uploaded].map { |data| data.to_s.b }).to eq(scenario[:csvs].map(&:b)) # controle: o arquivo estava lá
      expect(ids[:file_data]).to eq([ nil, nil ])
    end

    # Q30: todo payload some 30 dias depois do sent_at, em qualquer situação;
    # o nunca enviado, 30 dias depois do created_at. Os metadados ficam.
    it "a purga apaga todo payload 30 dias depois do envio e o nunca enviado 30 dias depois da criação" do
      expect(ids[:before_purge].map(&:last)).to all(be(false))

      limit = ids[:purge_at] - Bnafar::Catalog::PAYLOAD_DAYS.days
      partial = ids[:partial_purge]
      partial.each do |id, status, sent_at, created_at, purged|
        expected = sent_at ? sent_at < limit : created_at < limit
        expect(purged).to eq(expected), "registro #{id} (#{status}, sent_at #{sent_at.inspect}, created_at #{created_at}) purged=#{purged}"
      end
      purged_by_sent = partial.select { |_, _, sent_at, _, purged| sent_at && purged }
      kept_by_sent = partial.select { |_, _, sent_at, _, purged| sent_at && !purged }
      kept_never_sent = partial.select { |_, _, sent_at, _, purged| sent_at.nil? && !purged }
      expect(purged_by_sent.map { |row| row[1] }.uniq).to include("accepted", "rejected") # não só o aceito
      expect(kept_by_sent).not_to be_empty   # homologação, enviada em D+3: ainda dentro dos 30 dias
      expect(kept_never_sent).not_to be_empty # D+3 nunca enviada: conta da criação

      full = ids[:full_purge]
      expect(full.map(&:last)).to all(be(true))
      expect(full.select { |row| row[2].nil? }).not_to be_empty
      expect(full.map { |row| row[1] }.uniq).to include("accepted", "rejected", "pending")
      expect(full.map { |row| [ row[0], row[1] ] }).to match_array(ids[:before_purge].map { |row| [ row[0], row[1] ] }) # os metadados ficam
    end

    # §9, R18, Q39: a auditoria da plataforma só com os nomes e campos do
    # contrato; nada de credencial, token, código TOTP ou arquivo.
    it "as auditorias do cenário não levam credencial, token, TOTP, arquivo nem campo com name" do
      audits = scenario[:platform_events]
      names = audits.map(&:name)
      expect(names).to include(*secrecy::R18_NAMES)
      expect(audits.select { |e| e.name == "bnafar.credential_set" }.map(&:payload))
        .to contain_exactly(include("environment" => "production"), include("environment" => "homologation"))
      expect(audits.select { |e| e.name == "bnafar.credential_set" }.map { |e| e.payload.keys.sort }.uniq).to eq([ %w[city_id environment] ])
      expect(audits.select { |e| e.name == "maintenance.bnafar.environment_changed" }.map { |e| e.payload["outcome"] }).to include("ok", "rejected")

      audits.each do |event|
        text = event.payload.to_json
        (credentials + tokens + people + reasons + csv_content + [ secrecy::MAINTAINER_PASSWORD ]).each do |secret|
          expect(secrecy.contains?(text, secret)).to be(false), "#{event.name} contém #{secret.inspect}"
        end
        leaves = secrecy.leaves_of(event.payload).map(&:to_s)
        expect(leaves & scenario[:codes]).to be_empty, "#{event.name} leva o código TOTP"
        next unless secrecy::R18_NAMES.include?(event.name)

        expect(secrecy.keys_of(event.payload).grep(/name/)).to be_empty, "#{event.name}: #{event.payload.keys}"
      end
    end
  end
end

# §9 e R18: a varredura de fonte (Prism). Platform.audit( é multilinha: o nó
# da chamada inteira, nunca a linha. Nos arquivos do módulo, só o
# obm_catalog.imported; na credencial (compartilhada), o bnafar.credential_set;
# os dois maintenance.* pela auditoria do maintenance (MaintenanceAudit::NAMES);
# os quatro no R18; nenhum campo auditado com `name`.
RSpec.describe "Sigilo do envio à BNAFAR (27b) — Platform.audit e DomainEvents.publish na fonte" do
  def walk(file, &block)
    visit = lambda do |node|
      block.call(node)
      node.compact_child_nodes.each { |child| visit.call(child) }
    end
    visit.call(Prism.parse_file(file).value)
  end

  def calls(file, method, receiver)
    found = []
    walk(file) do |node|
      found << node if node.is_a?(Prism::CallNode) && node.name == method && node.receiver.respond_to?(:full_name) &&
                       node.receiver.full_name.delete_prefix("::") == receiver
    end
    found
  end

  def name_of(call)
    arg = call.arguments&.arguments&.first
    arg.unescaped if arg.is_a?(Prism::StringNode)
  end

  def keys_of(call)
    call.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .map { |assoc| assoc.key.respond_to?(:unescaped) ? assoc.key.unescaped : assoc.key.slice }
  end

  def module_files = BnafarSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq.sort

  def shared_files = BnafarSecrecy::SHARED_FILES.map { |path| Rails.root.join(path).to_s }

  def where(file, call) = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"

  it "só obm_catalog.imported no módulo e bnafar.credential_set na credencial; os maintenance.* na auditoria do maintenance; os quatro no R18" do
    files = module_files
    expect(files.size).to be >= 60
    %w[app/services/bnafar/client.rb app/services/bnafar/delivery.rb app/jobs/bnafar/deliver_job.rb app/commands/opening_imports/apply.rb
       app/controllers/pharmacy/bnafar/records_controller.rb app/graphql/maintenance/mutations/set_bnafar_environment.rb
       app/services/medications/obm_import.rb lib/fake_bnafar/app.rb lib/tasks/medications.rake].each do |path|
      expect(files).to include(Rails.root.join(path).to_s), "#{path} fora das globs"
    end

    audits = files.flat_map { |file| calls(file, :audit, "Platform").map { |call| [ file, call ] } }
    expect(audits.map { |_, call| name_of(call) }).to eq([ "obm_catalog.imported" ])
    # A varredura de texto não acha chamada que o Prism não achou (nome partido, receptor com espaço).
    expect(files.sum { |file| File.read(file).scan(/Platform\s*\.\s*audit\b/).size }).to eq(audits.size)

    shared = shared_files.flat_map { |file| calls(file, :audit, "Platform").map { |call| [ file, call ] } }
    expect(shared.map { |_, call| name_of(call) }).to contain_exactly("rnds.credential_set", "bnafar.credential_set")
    bnafar = shared.select { |_, call| name_of(call) == "bnafar.credential_set" }

    (audits + bnafar).each do |file, call|
      keys = keys_of(call)
      expect(keys).not_to be_empty, where(file, call)
      expect(keys.grep(/name/)).to be_empty, "#{where(file, call)}: #{keys}"
      expect(call.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocSplatNode)).to be_empty
    end
    expect(keys_of(bnafar.sole.last)).to contain_exactly("city_id", "environment")
    expect(keys_of(audits.sole.last)).to contain_exactly("actor", "added", "changed", "deactivated", "unmatched")

    # Os dois do maintenance: pelo `audited`/`in_city` das mutations, nunca Platform.audit direto.
    mutations = %w[import_obm_catalog set_bnafar_environment].map { |name| Rails.root.join("app/graphql/maintenance/mutations/#{name}.rb").to_s }
    texts = mutations.map { |file| File.read(file) }
    expect(texts.join).to include('event: "maintenance.obm_catalog.imported"', 'event: "maintenance.bnafar.environment_changed"')
    expect(MaintenanceAudit::NAMES).to include("maintenance.obm_catalog.imported", "maintenance.bnafar.environment_changed")
    expect(texts.join).not_to match(/Platform\s*\.\s*audit/)

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include(*BnafarSecrecy::R18_NAMES)
    expect(r18.grep(/bnafar|obm|opening_import/)).to match_array(BnafarSecrecy::R18_NAMES)
  end

  it "nos arquivos do módulo, todo DomainEvents.publish é do catálogo (ou o recebimento) com as chaves exatas" do
    publishes = module_files.flat_map { |file| calls(file, :publish, "DomainEvents").map { |call| [ file, call ] } }
    expect(publishes.size).to be >= 10
    publishes.each do |file, call|
      name = name_of(call)
      expect(BnafarSecrecy::PAYLOAD_KEYS.keys).to include(name), "#{where(file, call)}: #{name.inspect}"
      expect(keys_of(call)).to match_array(BnafarSecrecy::PAYLOAD_KEYS.fetch(name)), "#{where(file, call)}: #{keys_of(call)}"
    end
    expect(publishes.map { |_, call| name_of(call) }.uniq).to match_array(Bnafar::Catalog::DOMAIN_EVENTS)
  end
end
