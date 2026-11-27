require "rails_helper"
require "prism"
require "webmock/rspec"

# Módulo 26c (contrato §9; Q17, Q25; pré-voo I5, M11, M23; plano, Task 16): o
# sigilo do envio da regulação à RNDS de ponta a ponta, contra o simulado
# (FakeRnds::App por WebMock#to_rack em http://fake-rnds.test:8094; nenhuma URL
# real). Um cenário só, pelas rotas e pelos jobs reais, com os pedidos da 26a
# andando pelos comandos dela:
# - D: credencial gravada (PUT com step-up; duas recusas) e testada; as
#   configurações (leitura, duas recusas, gravação); pedido promovido e aceito,
#   autorizado, agendado, com falta (sai `absence` e depois o estado final);
#   pedido recusado (`RECUSA`) e reenviado pela rota; pedido com `TIMEOUT` e a
#   reconciliação; recusa sem código da RNDS; pedido parado (unidade sem CNES)
#   que a troca do CNES solta; carga inicial; pedido regulado pelo estado
#   enviado e depois excluído (o envio desligado nas configurações); leituras
#   (situação, lista com filtros e cursor) e as recusas forçadas;
# - D+10: mais duas remessas (uma aceita, uma recusada);
# - D+31: a purga com o interruptor LIGADO (as de D somem; as de D+10 ficam);
# - D+41: a purga com o interruptor DESLIGADO (as de D+10 somem); a situação
#   recusa (403) e as configurações seguem abertas.
# Depois, as provas de ausência: log, eventos, URLs de saída, linhas gravadas,
# payload (cifrado e purgado), respostas, recusas 4xx, `inspect` e a varredura
# de Platform.audit e DomainEvents.publish.
#
# Constantes num módulo próprio (dentro de um bloco do RSpec cairiam em Object).
# Tudo ASCII, palavras únicas: a varredura compara bytes sem caixa.
module RegulationRndsSecrecy
  PFX_PASSWORD = "SenhaPfxSigiloAmetista91".freeze
  # O formato é só dígitos (1 a 20): o marcador é um número improvável.
  REQUESTER_ID = "73905128467031".freeze
  # O CNES do solicitante da credencial (7 dígitos): também é segredo da credencial.
  REQUESTER_CNES = "8306142".freeze
  BAD_REQUESTER = "Req Sigilo Opala".freeze
  BAD_CNS = "987654321098765".freeze
  PEOPLE = [
    { full_name: "Gumercinda Xavantina Pomperella", mother_name: "Hermenegilda Ostrogoda Pomperella" },
    { full_name: "Anacleto Timbiras Quimerinho", mother_name: "Eufrasia Tapuias Quimerinho" }
  ].freeze
  WORDS = %w[Gumercinda Xavantina Pomperella Hermenegilda Ostrogoda Anacleto Timbiras Quimerinho Eufrasia Tapuias].freeze
  # Os CID-10 da semente de teste que não são hexadecimais (nada de acaso num uuid).
  CIDS = %w[N185 N390].freeze
  JUSTIFICATIONS = [
    "Reservado RG1: doenca renal avancada com perda de funcao e edema persistente",
    "Reservado RG2: infeccao urinaria de repeticao sem resposta ao esquema inicial",
    "Reservado RG3: segue sem resposta ao tratamento clinico da atencao basica",
    "Reservado RG4: acompanhamento especializado pedido pela equipe da unidade"
  ].freeze
  UNKNOWN_REASON = "NaoExisteSigiloTopazio".freeze
  # O texto que a RNDS (o simulado) devolve: nunca gravado, só o código.
  RNDS_TEXTS = [ "recusado pelo simulado", "Erro simulado", "ja foi substituido", "nao esta no estado final", "inexistente" ].freeze
  CREDENTIAL_PATH = "/integrations/credentials/rnds_regulation".freeze
  SETTINGS_PATH = "/regulation/admin/rnds_settings".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  UUID_IN_PATH = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  # §9: as chaves exatas de cada evento (ids e user_id).
  SYNC_KEYS = %w[regulation_rnds_sync_id regulation_request_id].freeze
  PAYLOAD_KEYS = {
    "regulation_rnds.queued" => SYNC_KEYS,
    "regulation_rnds.accepted" => SYNC_KEYS,
    "regulation_rnds.blocked" => SYNC_KEYS,
    "regulation_rnds.rejected" => SYNC_KEYS,
    "regulation_rnds.excluded" => SYNC_KEYS,
    "regulation_rnds.settings_changed" => %w[user_id],
    "integration_credential.changed" => %w[kind user_id],
    "health_unit.changed" => %w[health_unit_id]
  }.freeze
  EXTRA_EVENTS = %w[integration_credential.changed health_unit.changed].freeze
  # As únicas chaves de uma recusa 4xx (path nos campos inválidos, feature no interruptor).
  REFUSAL_KEYS = %w[error path feature].freeze
  FORBIDDEN_KEYS = /\A(payload|patient|patient_id|patient_name|cpf|cns|cid10|ciap2|justification|target_code|pfx_base64|pfx_password|
                       requester_id|requester_cnes|responsible_cns|secret|retry_window_started_at|unanswered_closed_at|bundle_identifier|
                       digest|desired_digest|sent_digest|access_token|token)\z/x
  # Os arquivos do módulo (varredura de fonte); a credencial é de todas as integrações.
  MODULE_GLOBS = %w[
    app/services/regulation/rnds_*.rb app/services/regulation/rira_*.rb app/jobs/regulation/rnds_*.rb
    app/commands/regulation/retry_rnds_sync.rb app/commands/regulation/save_rnds_settings.rb
    app/controllers/care_regulation/rnds_*.rb app/controllers/care_regulation/admin/rnds_settings_controller.rb
    app/controllers/concerns/regulation_rnds_gate.rb app/models/regulation_rnds_*.rb
    app/services/rnds/client.rb app/services/rnds/config.rb lib/regulation_rnds_crew.rb lib/fake_rnds/*.rb
  ].freeze
  SHARED_FILES = %w[app/commands/integrations/set_credential.rb].freeze

  def self.cpf_forms(cpf) = [ cpf, "#{cpf[0, 3]}.#{cpf[3, 3]}.#{cpf[6, 3]}-#{cpf[9, 2]}" ]

  def self.route(path) = path.gsub(UUID_IN_PATH, ":id").sub(/\?.*\z/, "")

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

RSpec.describe "Sigilo do envio da regulação à RNDS (26c)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Método, e não let: o cenário roda no seed_once (before(:context)).
  def secrecy = RegulationRndsSecrecy

  def test_city = City.find_by!(slug: TEST_CITY_A.slug)

  # A cidade no Current, com bloco (nunca Current.city solto).
  def in_city(&) = Current.set(city: test_city, &)

  def json_headers = { "CONTENT_TYPE" => "application/json" }

  # Toda resposta do cenário: rota, status e corpo.
  def keep!
    @responses << { verb: request.request_method, path: request.fullpath, route: secrecy.route(request.fullpath),
                    status: response.status, raw: response.body.dup, media_type: response.media_type }
  end

  def call_city(verb, path, body)
    verb == :get ? get(path) : public_send(verb, path, params: (body || {}).to_json, headers: json_headers)
    keep!
  end

  def req(verb, path, body = nil)
    call_city(verb, path, body)
    raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

    response.body.present? ? JSON.parse(response.body) : nil
  end

  def refuse(label, verb, path, body = nil, status:, sent: [])
    call_city(verb, path, body)
    raise "#{label}: #{verb} #{path} → #{response.status} #{response.body}" unless response.status == status

    @refusals << { label: label, status: response.status, raw: response.body.dup, json: JSON.parse(response.body), sent: Array(sent) }
  end

  # --- O envio (os pedidos nascem e andam pelos comandos da 26a) ----------
  def run_deliver! = Regulation::RndsDeliverJob.perform_now

  # O que o RndsSyncJob faz a cada evento do pedido (o adaptador de teste só enfileira).
  def sync!(request) = Regulation::RndsSync.recompute!(request.reload, create: true, now: Time.current)

  def mark!(sync, marker)
    sync.update_columns(bundle_identifier: "#{marker}-#{SecureRandom.hex(8)}")
    sync.reload
  end

  def municipal_request!(index, **over)
    unit = over.delete(:unit) || create_unit("UBS Sigilo #{SecureRandom.hex(3)}", cnes: regulation_cnes)
    person = secrecy::PEOPLE[index % secrecy::PEOPLE.size]
    patient, = regulation_patient!(exam_seq!, **person)
    @seq = (@seq || 0) + 1
    patient.update!(cns: valid_cns(700 + @seq)) if patient.cns.blank?
    @patients << patient
    regulation_request!(unit: unit, citizen: patient.citizens.first, cid10: secrecy::CIDS[index % secrecy::CIDS.size],
                        justification: secrecy::JUSTIFICATIONS[@seq % secrecy::JUSTIFICATIONS.size], **over)
  end

  def schedule!(request, offer, regulator, at: Time.current + 3.days)
    result = CareRegulation::ScheduleExternal.call(request: request.reload, at: at.iso8601, place: "Hospital Regional", notes: nil,
                                                   version: request.version, by: regulator, care_provider_id: offer.care_provider_id)
    raise "agendamento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  def miss!(request, regulator)
    ApplicationRecord.transaction do
      request.lock!(CareRegulation::Decide::LOCK)
      CareRegulation::Misses.apply!(request: request, by: regulator)
    end
    request.reload
  end

  def warm_token!
    Rnds::Client.for(Current.city, kind: "rnds_regulation", settings: Rnds::Config.simulated).token!
  end

  def settings_body(version, **over)
    { expected_version: version, priority_by_color: { red: "urgent", yellow: "routine", green: "routine", blue: "routine" },
      specialty_sigtap: {}, send_external: false }.merge(over)
  end

  def secrecy_scenario!
    s = secrecy
    city = regulation_city!
    city_profile!.update!(ibge_code: "4106902", uf: "PR")
    RegulationRndsSetting.ensure_defaults!
    maintainer = ledi_maintainer!
    admin = regulation_admin!
    regulator = regulation_regulator!
    offer = offer!(provider: external_provider!)
    @responses = []
    @refusals = []
    @patients = []
    ids = {}
    base = Time.zone.local(2026, 11, 20, 9, 0)
    travel_to base
    tick_regulation_events!
    fake = fake_rnds!
    started_at = Time.current
    platform_before = PlatformEvent.pluck(:id)
    encoded = Base64.strict_encode64(self_signed_pfx(password: s::PFX_PASSWORD, not_after: 1.year.from_now))
    ids[:pfx_slice] = encoded[200, 60]
    credential = { pfx_base64: encoded, pfx_password: s::PFX_PASSWORD, requester_cnes: s::REQUESTER_CNES, requester_id: s::REQUESTER_ID,
                   responsible_cns: valid_cns(901) }
    ids[:responsible_cns] = credential[:responsible_cns]

    log = capture_log do
      # D 09:00 — a credencial (duas recusas), os interruptores e o teste.
      stepped_up!(admin)
      refuse(:bad_requester, :put, s::CREDENTIAL_PATH, credential.merge(requester_id: s::BAD_REQUESTER), status: 422, sent: [ s::BAD_REQUESTER ])
      refuse(:bad_cns, :put, s::CREDENTIAL_PATH, credential.merge(responsible_cns: s::BAD_CNS), status: 422, sent: [ s::BAD_CNS ])
      req(:put, s::CREDENTIAL_PATH, credential)
      [ Regulation::RndsGate::KEY, Rnds::Mock::KEY ].each do |key|
        Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer)
      end
      CityCatalog.reset_cache!
      ids[:check] = req(:post, "#{s::CREDENTIAL_PATH}/check", {})
      req(:get, "/integrations")

      # As configurações: leitura, duas recusas (sem versão, versão velha), uma do regulador e a gravação.
      req(:get, s::SETTINGS_PATH)
      refuse(:settings_without_version, :put, s::SETTINGS_PATH, settings_body(1).except(:expected_version), status: 422)
      refuse(:settings_stale, :put, s::SETTINGS_PATH, settings_body(99), status: 409)
      sign_in_as(regulator)
      refuse(:settings_regulator, :put, s::SETTINGS_PATH, settings_body(1), status: 403)
      req(:get, s::SETTINGS_PATH)
      stepped_up!(admin)
      ids[:settings] = req(:put, s::SETTINGS_PATH, settings_body(1, send_external: true))

      # Pedido A: aceito, autorizado, agendado, com falta (absence e depois o estado final).
      a = municipal_request!(0)
      sync_a = sync!(a)
      run_deliver!
      a = reauthorize!(a, offer: offer)
      sync!(a)
      run_deliver!
      schedule!(a, offer, regulator)
      sync!(a)
      run_deliver!
      miss!(a, regulator)
      reauthorize!(a.reload, offer: offer)
      sync!(a)
      2.times { run_deliver! }
      ids[:sync_a] = sync_a.id

      # Pedido B: recusado (RECUSA) e reenviado pela rota (recusado de novo).
      b = municipal_request!(1)
      sync_b = mark!(sync!(b), "RECUSA")
      run_deliver!
      ids[:sync_b] = sync_b.id
      travel(1.minute)
      stepped_up!(admin)
      req(:post, "/regulation/rnds/syncs/#{sync_b.id}/retry", {})
      run_deliver!

      # Pedido C: o POST chega e a resposta não (TIMEOUT); a rodada seguinte reconcilia pelo GET /identifier.
      c = municipal_request!(0)
      sync_c = mark!(sync!(c), "TIMEOUT")
      run_deliver!
      travel(1.minute)
      run_deliver!
      ids[:sync_c] = sync_c.id

      # Pedido D: a RNDS recusa sem código (422 "Erro simulado"): só o rejected, sem texto gravado.
      d = municipal_request!(1)
      sync_d = sync!(d)
      warm_token!
      fake.failures.push(422)
      run_deliver!
      ids[:sync_d] = sync_d.id

      # Pedido E: unidade solicitante sem CNES (parado); o CNES novo (health_unit.changed) o solta.
      e = municipal_request!(0, unit: create_unit("UBS Sigilo Sem CNES #{SecureRandom.hex(3)}"))
      sync_e = sync!(e)
      run_deliver!
      e.requester_unit.update!(cnes: regulation_cnes)
      sync!(e)
      run_deliver!
      ids[:sync_e] = sync_e.id

      # Pedidos F e G: a carga inicial (nasceram antes de existir linha).
      f = municipal_request!(1)
      g = municipal_request!(0)
      RegulationRndsSync.where(regulation_request_id: [ f.id, g.id ]).delete_all
      Regulation::RndsInitialLoadJob.perform_now
      run_deliver!
      ids[:initial] = RegulationRndsSync.where(initial_load: true).pluck(:id)

      # Pedido H: regulado pelo estado (enviado com send_external ligado) e depois excluído.
      h = municipal_request!(1, status: "external")
      sync_h = sync!(h)
      run_deliver!
      stepped_up!(admin)
      req(:put, s::SETTINGS_PATH, settings_body(ids[:settings]["version"], send_external: false))
      sync!(h)
      run_deliver!
      ids[:sync_h] = sync_h.id

      # Leituras: situação e lista (filtros, página e cursor) pelo regulador e pelo admin.
      sign_in_as(regulator)
      ids[:status] = req(:get, "/regulation/rnds/status")
      ids[:list] = req(:get, "/regulation/rnds/syncs")
      first_page = req(:get, "/regulation/rnds/syncs?limit=2")
      req(:get, "/regulation/rnds/syncs?limit=2&before=#{CGI.escape(first_page['next_before'])}") if first_page["next_before"]
      req(:get, "/regulation/rnds/syncs?status=rejected")
      req(:get, "/regulation/rnds/syncs?reason=EHR-ERR999")
      req(:get, "/regulation/rnds/syncs?reason=missing_diagnosis")
      req(:get, "/regulation/rnds/syncs?reason=skeleton")
      sign_in_as(admin)
      req(:get, "/regulation/rnds/status")
      req(:get, "/regulation/rnds/syncs?status=idle")

      # As recusas forçadas (R15): sem step-up, regulador, não reenviável, desconhecido, filtro fora do catálogo.
      refuse(:retry_without_step_up, :post, "/regulation/rnds/syncs/#{sync_b.id}/retry", {}, status: 401)
      sign_in_as(regulator)
      refuse(:retry_regulator, :post, "/regulation/rnds/syncs/#{sync_b.id}/retry", {}, status: 403)
      stepped_up!(admin)
      refuse(:retry_not_retryable, :post, "/regulation/rnds/syncs/#{sync_a.id}/retry", {}, status: 409)
      refuse(:retry_unknown, :post, "/regulation/rnds/syncs/#{SecureRandom.uuid}/retry", {}, status: 404)
      refuse(:filter_reason, :get, "/regulation/rnds/syncs?reason=#{s::UNKNOWN_REASON}", nil, status: 422, sent: [ s::UNKNOWN_REASON ])
      refuse(:filter_status, :get, "/regulation/rnds/syncs?status=#{s::UNKNOWN_REASON}", nil, status: 422, sent: [ s::UNKNOWN_REASON ])
      ids[:deliveries_before] = in_city { RegulationRndsDelivery.count }

      # D+10 — mais duas remessas: uma aceita e uma recusada.
      travel_to(base + 10.days)
      stepped_up!(admin)
      j = municipal_request!(0)
      k = municipal_request!(1)
      sync_j = sync!(j)
      sync_k = mark!(sync!(k), "RECUSA")
      run_deliver!
      ids[:sync_late] = [ sync_j.id, sync_k.id ]

      # Antes da purga: o que está no banco (o cru e o decifrado), com o conteúdo de cada remessa.
      ids[:raw_payloads] = in_city { RegulationRndsDelivery.connection.select_values("SELECT payload FROM regulation_rnds_deliveries WHERE payload IS NOT NULL") }
      ids[:payloads] = in_city { RegulationRndsDelivery.where.not(payload: nil).map { |row| [ row.id, row.http_status, row.payload ] } }
      # Os objetos com o payload ainda carregado: inspect, to_s, as_json.
      ids[:inspects] = in_city do
        sync = RegulationRndsSync.first
        delivery = RegulationRndsDelivery.where.not(payload: nil).first
        [ sync.inspect, sync.to_s, delivery.inspect, delivery.to_s, delivery.as_json.to_json, delivery.pretty_inspect,
          IntegrationCredential.find_by!(kind: "rnds_regulation").inspect, IntegrationCredential.find_by!(kind: "rnds_regulation").as_json.to_json,
          Rnds::Client.for(Current.city, kind: "rnds_regulation").inspect,
          Regulation::RiraFacts.for(request: RegulationRequest.first, settings: RegulationRndsSetting.current,
                                    credential: IntegrationCredential.find_by!(kind: "rnds_regulation")).then { |facts| [ facts.inspect, facts.to_s, facts.as_json.to_json ] }
        ].flatten
      end

      ids[:credential_raw] = in_city { IntegrationCredential.connection.select_values("SELECT secret FROM integration_credentials WHERE kind = 'rnds_regulation'") }
      ids[:setting_raw] = in_city { RegulationRndsSetting.connection.select_rows("SELECT * FROM regulation_rnds_settings") }.flatten.map(&:to_s)

      # D+31 — a purga com o interruptor LIGADO: as de D somem; as de D+10 (21 dias) ficam.
      purge_state = -> { in_city { RegulationRndsDelivery.pluck(:id, :http_status, :sent_at, :accepted_at, Arel.sql("payload IS NULL")) } }
      ids[:purge_before] = purge_state.call
      travel_to(base + 31.days)
      run_deliver!
      ids[:purge_on_at] = Time.current
      ids[:purge_on] = purge_state.call
      ids[:rows_on] = in_city { RegulationRndsSync.pluck(:id, :status) }
      sign_in_as(regulator)
      req(:get, "/regulation/rnds/status")
      req(:get, "/regulation/rnds/syncs")

      # D+41 — a purga com o interruptor DESLIGADO (Q17): as de D+10 (31 dias) somem.
      travel_to(base + 41.days)
      Platform::Features.set!(city: city, key: Regulation::RndsGate::KEY, enabled: false, maintainer: maintainer)
      CityCatalog.reset_cache!
      run_deliver!
      ids[:purge_off_at] = Time.current
      ids[:purge_off] = purge_state.call
      refuse(:status_off, :get, "/regulation/rnds/status", nil, status: 403)
      refuse(:syncs_off, :get, "/regulation/rnds/syncs", nil, status: 403)
      req(:get, s::SETTINGS_PATH)
    end

    ids[:urls] = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map do |signature|
      { verb: signature.method.to_s.upcase, url: signature.uri.to_s, body: signature.body.to_s }
    end
    ids[:rows] = in_city do
      { syncs: RegulationRndsSync.all.map { |row| row.attributes.to_json },
        deliveries: RegulationRndsDelivery.all.map { |row| row.attributes.except("payload").to_json },
        sync_codes: RegulationRndsSync.pluck(:last_error_codes).flatten,
        delivery_codes: RegulationRndsDelivery.pluck(:error_codes).flatten }
    end
    { ids: ids, log: log, responses: @responses, refusals: @refusals, started_at: started_at, fake: fake, patients: @patients,
      tokens: fake.issued_tokens, platform_events: PlatformEvent.where.not(id: platform_before).to_a, city: city,
      accepted: fake.accepted.map { |entry| entry[:bundle].to_json }, fake_log: fake.log.dup }
  end

  describe "cenário" do
    # O cenário roda uma vez por arquivo (api#159). O before(type: :request)
    # do harness não roda aqui: o host vem à mão, e os dublês (ENV, WebMock) vivem
    # num escopo temporário.
    seed_once do
      use_test_city_host!
      RSpec::Mocks.with_temporary_scope do
        @scenario = secrecy_scenario!
      end
    ensure
      travel_back
      Rnds::Client.reset_cache!
    end
    let(:scenario) { @scenario }
    let(:ids) { scenario[:ids] }
    let(:patients) { scenario[:patients] }
    let(:credentials) { [ secrecy::PFX_PASSWORD, secrecy::REQUESTER_ID, secrecy::REQUESTER_CNES, ids[:responsible_cns], ids[:pfx_slice] ] }
    let(:tokens) { scenario[:tokens] }
    let(:people) do
      secrecy::PEOPLE.flat_map(&:values) + secrecy::WORDS + patients.flat_map { |patient| [ patient.cns, *secrecy.cpf_forms(patient.cpf) ] }
    end
    let(:clinical) { secrecy::CIDS + secrecy::JUSTIFICATIONS }
    let(:events) { DomainEvent.where(occurred_at: scenario[:started_at]..).order(:occurred_at, :created_at).to_a }
    let(:module_events) { events.select { |e| e.name.start_with?("regulation_rnds.") || secrecy::EXTRA_EVENTS.include?(e.name) } }
    let(:responses) { scenario[:responses] }

    it "percorreu o cenário inteiro (controle positivo)" do
      expect(patients.map(&:cpf)).to all(be_present)
      expect(patients.map(&:cns)).to all(be_present)
      expect(ids[:check]).to include("kind" => "rnds_regulation", "last_check_status" => "ok")
      expect(ids[:settings]).to include("version" => 2, "send_external" => true)
      expect(ids[:status]).to include("usable" => true)
      expect(ids[:list]["items"].size).to be >= 8
      expect(scenario[:tokens]).not_to be_empty

      # A cadeia de A: create, replace(s) e absence; o recusado duas vezes; o timeout adotado; o sem código; o parado solto.
      kinds = in_city { RegulationRndsSync.find(ids[:sync_a]).deliveries.order(:sent_at).pluck(:kind, :mira_status) }
      expect(kinds.map(&:first)).to start_with("create", "replace")
      expect(kinds.map(&:last)).to include("pending", "booked", "absence")
      in_city do
        expect(RegulationRndsSync.find(ids[:sync_b])).to have_attributes(status: "rejected", last_error_codes: [ "EHR-ERR999" ])
        expect(RegulationRndsSync.find(ids[:sync_b]).deliveries.where(http_status: 422).count).to eq(2)
        expect(RegulationRndsSync.find(ids[:sync_c])).to have_attributes(status: "idle")
        expect(RegulationRndsSync.find(ids[:sync_d])).to have_attributes(status: "rejected", last_error_codes: [])
        expect(RegulationRndsSync.find(ids[:sync_e])).to have_attributes(status: "idle")
        expect(RegulationRndsSync.find(ids[:sync_h])).to have_attributes(status: "excluded")
        expect(ids[:initial].size).to eq(2)
        expect(RegulationRndsSync.where(id: ids[:initial]).pluck(:status).uniq).to eq([ "idle" ])
      end
      expect(scenario[:fake_log].map(&:first)).to include("POST", "GET")

      expect(scenario[:refusals].map { |r| r[:label] }).to eq(
        %i[bad_requester bad_cns settings_without_version settings_stale settings_regulator retry_without_step_up retry_regulator
           retry_not_retryable retry_unknown filter_reason filter_status status_off syncs_off]
      )
    end

    # §9: os eventos do módulo são os do catálogo (mais a credencial e a unidade), só ids.
    it "os eventos do módulo = RndsCatalog::DOMAIN_EVENTS (+ credencial e unidade), só ids" do
      expect(secrecy::PAYLOAD_KEYS.keys - secrecy::EXTRA_EVENTS).to match_array(Regulation::RndsCatalog::DOMAIN_EVENTS)
      published = events.map(&:name).select { |name| name.start_with?("regulation_rnds.") }.uniq
      expect(published).to match_array(Regulation::RndsCatalog::DOMAIN_EVENTS)
      expect(events.map(&:name)).to include(*secrecy::EXTRA_EVENTS)

      module_events.each do |event|
        expect(event.payload.keys).to match_array(secrecy::PAYLOAD_KEYS.fetch(event.name)), "#{event.name} publica #{event.payload.keys}"
        event.payload.each do |key, value|
          if key == "kind" then expect(value).to eq("rnds_regulation")
          else expect(value.to_s).to match(secrecy::UUID), "#{event.name}.#{key}"
          end
        end
      end

      # Nenhum evento do cenário (nem os da 26a) leva segredo, paciente, CID ou justificativa.
      payloads = events.map { |e| [ e.name, e.payload ] }.to_json
      (credentials + tokens + people + clinical + secrecy::RNDS_TEXTS).each do |secret|
        expect(secrecy.contains?(payloads, secret)).to be(false), "evento contém #{secret.inspect}"
      end
    end

    it "o log do cenário não tem marca, texto da RNDS nem Bearer com token real" do
      log = scenario[:log]
      # Controle: a captura viu as rotas, os jobs e o filtro agiu.
      expect(log).to include("/integrations/credentials/rnds_regulation", "/regulation/admin/rnds_settings", "/regulation/rnds/status",
                             "/regulation/rnds/syncs", "regulation_rnds_syncs", "regulation_rnds_deliveries", "[FILTERED]")
      (credentials + tokens + people + clinical + secrecy::RNDS_TEXTS).each do |secret|
        expect(secrecy.contains?(log, secret)).to be(false), "log contém #{secret.inspect}"
      end
      expect(log).not_to match(/Bearer\s+(?!\[FILTERED\]|<)[\w.\-]{16,}/)
      expect(tokens).not_to be_empty

      logged = log.scan(/"(pfx_password|pfx_base64|requester_id|responsible_cns|requester_cnes)"\s*=>\s*("[^"]*"|\[FILTERED\])/)
      expect(logged.map(&:first).uniq).to include("pfx_password", "pfx_base64", "requester_id", "responsible_cns", "requester_cnes")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    # M11: a marca do requester_id vai à RNDS só no `system` do GET /identifier (o IG manda); CPF, CNS e CID nunca.
    it "nenhuma URL chamada leva CPF, CNS ou CID: só system, value e docType, e o requester_id só no system" do
      urls = ids[:urls]
      identifiers = urls.select { |entry| entry[:url].include?("/identifier") }
      expect(identifiers).not_to be_empty
      expect(urls.map { |entry| entry[:verb] }.uniq).to include("GET", "POST")

      urls.each do |entry|
        (people + clinical + [ secrecy::PFX_PASSWORD, ids[:responsible_cns] ] + tokens).each do |secret|
          expect(secrecy.contains?(entry[:url], secret)).to be(false), "#{entry[:verb]} #{entry[:url]} contém #{secret.inspect}"
        end
      end
      identifiers.each do |entry|
        query = Addressable::URI.parse(entry[:url]).query_values
        expect(query.keys).to match_array(%w[system value docType]), entry[:url]
        expect(query["system"]).to end_with("BRRNDS-#{secrecy::REQUESTER_ID}")
        expect(query["value"]).to match(/\A[A-Za-z0-9_-]{1,64}\z/)
      end
      with_marker = urls.select { |entry| secrecy.contains?(entry[:url], secrecy::REQUESTER_ID) }
      expect(with_marker).not_to be_empty
      expect(with_marker).to all(satisfy { |entry| entry[:url].include?("/identifier") })
    end

    # O texto da RNDS nunca é gravado (só o código); nada de paciente nem credencial nas linhas.
    it "regulation_rnds_syncs e regulation_rnds_deliveries sem texto da RNDS (só ERROR_CODE) e sem marca" do
      rows = ids[:rows]
      expect(rows[:syncs].size).to be >= 10
      expect(rows[:deliveries].size).to be >= 10
      expect(rows[:sync_codes] + rows[:delivery_codes]).to include("EHR-ERR999")
      expect(rows[:sync_codes] + rows[:delivery_codes]).to all(match(Rnds::Errors::CODE))
      expect(rows[:sync_codes] + rows[:delivery_codes]).to all(match(Regulation::RndsLimits::ERROR_CODE))
      text = (rows[:syncs] + rows[:deliveries]).join("\n")
      (credentials + people + clinical + secrecy::RNDS_TEXTS + tokens).each do |secret|
        expect(secrecy.contains?(text, secret)).to be(false), "linha contém #{secret.inspect}"
      end
    end

    # §9: o payload só cifrado no banco; NULL 30 dias depois do aceite ou do envio (Q17, I5), com o interruptor ligado ou não.
    it "o payload está cifrado no banco e o conteúdo (CPF e CID) só aparece decifrado" do
      expect(ids[:raw_payloads].size).to be >= 10
      raw = ids[:raw_payloads].join("\n")
      (people + clinical + [ secrecy::REQUESTER_ID, "Bundle", "Composition", "ServiceRequest" ]).each do |secret|
        expect(secrecy.contains?(raw, secret)).to be(false), "payload cru contém #{secret.inspect}"
      end
      decrypted = ids[:payloads]
      expect(decrypted.map(&:last)).to all(include("Composition"))
      expect(decrypted.map(&:last).join).to include(*secrecy::CIDS)
      expect(decrypted.select { |_, status, _| status == 422 }).not_to be_empty # a recusada também tem payload antes da purga
      expect(decrypted.map(&:last).join).to include(*patients.map(&:cpf)) # controle: o CPF vai no documento
      sent = (scenario[:accepted] + ids[:urls].map { |entry| entry[:body] }).join("\n")
      expect(sent).to include(secrecy::REQUESTER_ID) # o `system` do identificador, por exigência do IG
    end

    it "a credencial e as configurações gravadas não deixam a marca no banco" do
      raw = (ids[:credential_raw] + ids[:setting_raw]).join("\n")
      expect(ids[:credential_raw]).not_to be_empty
      credentials.each { |secret| expect(secrecy.contains?(raw, secret)).to be(false), "banco contém #{secret.inspect}" }
    end

    it "a purga apaga o payload 30 dias depois, aceito ou recusado, com o interruptor ligado (D+31) e desligado (D+41)" do
      before = ids[:purge_before]
      expect(before.map(&:last)).to all(be(false))
      expect(before.map { |row| row[1] }).to include(201, 422)

      limit_on = ids[:purge_on_at] - Regulation::RndsLimits::PAYLOAD_DAYS.days
      ids[:purge_on].each do |id, http_status, sent_at, accepted_at, purged|
        expect(purged).to eq((accepted_at || sent_at) < limit_on), "remessa #{id} (#{http_status}) com o interruptor ligado: purged=#{purged}"
      end
      expect(ids[:purge_on].count { |row| row.last }).to be_positive
      expect(ids[:purge_on].count { |row| !row.last }).to be_positive # as de D+10 ficam (21 dias)
      expect(ids[:purge_on].select { |row| row[1] == 422 }.map(&:last).uniq).to include(true, false) # a recusada de D some, a de D+10 fica

      expect(ids[:purge_off].map(&:last)).to all(be(true)) # a de D+10, 31 dias depois, com o envio desligado
      expect(ids[:purge_off].size).to eq(before.size)
      expect(ids[:purge_off].map(&:first)).to match_array(before.map(&:first)) # os metadados ficam
    end

    it "nenhuma resposta traz marca, payload nem paciente" do
      expect(responses.size).to be > 25
      expect(responses.map { |r| r[:route] }).to include("/integrations", "/integrations/credentials/rnds_regulation",
                                                         "/integrations/credentials/rnds_regulation/check", "/regulation/admin/rnds_settings",
                                                         "/regulation/rnds/status", "/regulation/rnds/syncs", "/regulation/rnds/syncs/:id/retry")
      responses.each do |r|
        (credentials + people + clinical + secrecy::RNDS_TEXTS + tokens).each do |secret|
          expect(secrecy.contains?(r[:raw], secret)).to be(false), "#{r[:verb]} #{r[:path]} contém #{secret.inspect}"
        end
        next unless r[:media_type] == "application/json" && r[:raw].present?

        body = JSON.parse(r[:raw])
        expect(secrecy.keys_of(body).grep(secrecy::FORBIDDEN_KEYS)).to be_empty, "#{r[:verb]} #{r[:path]}: #{secrecy.keys_of(body)}"
        # Q25: só códigos da RNDS; nunca o texto.
        codes = secrecy.leaves_of(body.is_a?(Hash) ? body.slice("items") : {}).grep(/EHR-|EDS-/)
        expect(codes).to all(match(Regulation::RndsLimits::ERROR_CODE))
        expect(Array(body.is_a?(Hash) ? body["items"] : nil).flat_map { |item| item["last_error_codes"] }).to all(match(Regulation::RndsLimits::ERROR_CODE))
      end
      # A lista não traz o que a coluna guarda para o alarme interno.
      expect(responses.map { |r| r[:raw] }.join).not_to include("retry_window_started_at", "unanswered_closed_at")
    end

    # R15: toda recusa 4xx só com error, path e feature; sem o valor enviado.
    it "toda recusa 4xx só com error, path e feature, sem o valor enviado" do
      expected = {
        bad_requester: "invalid_requester_id", bad_cns: "invalid_responsible_cns", settings_without_version: "expected_version_required",
        settings_stale: "rnds_settings_changed", settings_regulator: "missing_role", retry_without_step_up: "mfa_required",
        retry_regulator: "missing_role", retry_not_retryable: "not_retryable", retry_unknown: "not_found",
        filter_reason: "invalid_request", filter_status: "invalid_request", status_off: "feature_disabled", syncs_off: "feature_disabled"
      }
      scenario[:refusals].each do |refusal|
        expect(refusal[:json]["error"]).to eq(expected.fetch(refusal[:label])), "#{refusal[:label]}: #{refusal[:json]}"
        expect(refusal[:json].keys - secrecy::REFUSAL_KEYS).to be_empty, "#{refusal[:label]}: #{refusal[:json]}"
        refusal[:sent].each { |sent| expect(secrecy.contains?(refusal[:raw], sent)).to be(false), "#{refusal[:label]} ecoa o valor enviado" }
      end
      expect(scenario[:refusals].find { |r| r[:label] == :status_off }[:json]).to eq("error" => "feature_disabled", "feature" => "rnds_regulation")
      expect(scenario[:refusals].find { |r| r[:label] == :filter_reason }[:json]).to eq("error" => "invalid_request", "path" => "reason")

      failures = responses.select { |r| r[:status].between?(400, 499) }
      expect(failures.size).to eq(scenario[:refusals].size)
      failures.each do |r|
        expect(JSON.parse(r[:raw]).keys - secrecy::REFUSAL_KEYS).to be_empty, "#{r[:path]}: #{r[:raw]}"
      end
    end

    it "inspect, to_s e as_json dos modelos, do cliente e dos fatos não trazem paciente, CID nem credencial" do
      text = ids[:inspects].join("\n")
      expect(ids[:inspects].size).to be >= 12
      (credentials + people + clinical + tokens).each do |secret|
        expect(secrecy.contains?(text, secret)).to be(false), "inspect contém #{secret.inspect}"
      end
    end

    # §9 e R18: a auditoria da plataforma do cenário só com o nome e os campos do contrato.
    it "a auditoria do cenário é só rnds_regulation.credential_set com city_id; nada de campo com name" do
      audits = scenario[:platform_events]
      expect(audits.map(&:name)).to include("rnds_regulation.credential_set")
      expect(audits.select { |e| e.name == "rnds_regulation.credential_set" }.map(&:payload)).to eq([ { "city_id" => scenario[:city].id } ])
      audits.each do |event|
        text = event.payload.to_json
        (credentials + people + clinical + tokens).each do |secret|
          expect(secrecy.contains?(text, secret)).to be(false), "#{event.name} contém #{secret.inspect}"
        end
        next unless event.name.start_with?("rnds_regulation.")

        expect(secrecy.keys_of(event.payload).grep(/name/)).to be_empty, "#{event.name}: #{event.payload.keys}"
      end
    end
  end
end

# §9 e R18: a varredura de fonte (Prism). Platform.audit( e DomainEvents.publish(
# são multilinha: o nó da chamada inteira, nunca a linha.
RSpec.describe "Sigilo do envio da regulação à RNDS (26c) — Platform.audit e DomainEvents.publish na fonte" do
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

  def module_files = RegulationRndsSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq.sort

  def where(file, call) = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"

  it "nos arquivos do módulo nenhum Platform.audit; na credencial só rnds_regulation.credential_set, só com city_id, e no R18" do
    files = module_files
    expect(files.size).to be >= 25
    %w[app/services/regulation/rnds_delivery.rb app/jobs/regulation/rnds_deliver_job.rb app/commands/regulation/save_rnds_settings.rb
       app/controllers/care_regulation/rnds_syncs_controller.rb app/services/regulation/rira_bundle.rb app/models/regulation_rnds_delivery.rb
       app/services/rnds/client.rb lib/fake_rnds/app.rb].each do |path|
      expect(files).to include(Rails.root.join(path).to_s), "#{path} fora das globs"
    end

    audits = files.flat_map { |file| calls(file, :audit, "Platform").map { |call| [ file, call ] } }
    expect(audits.map { |file, call| where(file, call) }).to eq([])
    # A varredura de texto não acha chamada que o Prism não achou (nome partido, receptor com espaço).
    expect(files.sum { |file| File.read(file).scan(/Platform\s*\.\s*audit\b/).size }).to eq(0)

    shared = RegulationRndsSecrecy::SHARED_FILES.flat_map do |path|
      file = Rails.root.join(path).to_s
      calls(file, :audit, "Platform").map { |call| [ file, call ] }
    end
    expect(shared.map { |_, call| name_of(call) }).to include("rnds_regulation.credential_set")
    mine = shared.select { |_, call| name_of(call) == "rnds_regulation.credential_set" }
    expect(mine.size).to eq(1)
    keys = keys_of(mine.sole.last)
    expect(keys).to eq([ "city_id" ])
    expect(keys.grep(/name/)).to be_empty
    expect(mine.sole.last.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocSplatNode)).to be_empty

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include("rnds_regulation.credential_set")
    expect(r18.grep(/regulation_rnds|rnds_regulation/)).to eq([ "rnds_regulation.credential_set" ])
  end

  it "nos arquivos do módulo, todo DomainEvents.publish é do catálogo com as chaves exatas (só ids e user_id)" do
    secrecy = RegulationRndsSecrecy
    publishes = module_files.flat_map { |file| calls(file, :publish, "DomainEvents").map { |call| [ file, call ] } }
    expect(publishes.size).to be >= 4

    literal, dynamic = publishes.partition { |_, call| name_of(call) }
    literal.each do |file, call|
      name = name_of(call)
      expect(secrecy::PAYLOAD_KEYS.keys).to include(name), "#{where(file, call)}: #{name.inspect}"
      expect(keys_of(call)).to match_array(secrecy::PAYLOAD_KEYS.fetch(name)), "#{where(file, call)}: #{keys_of(call)}"
    end
    # O `event!` do envio publica pelo nome que recebe: as chaves são as dos ids da remessa e os nomes, os do catálogo.
    dynamic.each do |file, call|
      expect(file).to end_with("app/services/regulation/rnds_delivery.rb"), where(file, call)
      expect(keys_of(call)).to match_array(secrecy::SYNC_KEYS), "#{where(file, call)}: #{keys_of(call)}"
    end
    delivery = Rails.root.join("app/services/regulation/rnds_delivery.rb").to_s
    event_names = []
    walk(delivery) do |node|
      event_names << name_of(node) if node.is_a?(Prism::CallNode) && node.name == :event! && node.receiver.nil?
    end
    expect(event_names.compact.uniq).not_to be_empty
    expect(event_names.compact - Regulation::RndsCatalog::DOMAIN_EVENTS).to be_empty

    published = literal.map { |_, call| name_of(call) }.uniq + event_names.compact
    expect(published.uniq).to match_array(Regulation::RndsCatalog::DOMAIN_EVENTS)
  end
end
