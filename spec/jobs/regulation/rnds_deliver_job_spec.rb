require "rails_helper"

# Módulo 26c, Task 12 (contrato §3, §9, Q10, Q16, Q17, Q23; pré-voo B5, B6,
# I1–I5, I15, M14; Review Focus 1–4): o envio contínuo dos documentos RIRA à
# RNDS de ponta a ponta, com o FakeRnds::App em processo (WebMock#to_rack). A
# cadeia de substituição por `Bundle.identifier.value`, a reconciliação pelo
# `GET /identifier` (timeout, duplicado, EDS-MSG009), a pausa em 401/403, o
# backoff e a desistência, a purga do payload e a posse do claim. Os pedidos
# nascem e andam pelos comandos reais da 26a; o consumidor dos eventos
# (RndsSyncJob) é chamado à mão (`sync!`), porque o adaptador de teste só
# enfileira.
RSpec.describe Regulation::RndsDeliverJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }
  let(:regulator) { regulation_regulator! }
  let(:offer) { offer!(provider: external_provider!) }
  let(:fake) { fake_rnds! }

  before do
    travel_to now
    rnds_regulation_city!(mock: true)
    tick_regulation_events!
    fake
  end

  def settings = RegulationRndsSetting.current
  def run! = described_class.perform_now
  def credential = IntegrationCredential.find_by!(kind: "rnds_regulation")
  def events(name) = DomainEvent.where(name: "regulation_rnds.#{name}")

  # O que o RndsSyncJob faz a cada evento do pedido (com o interruptor ligado).
  def sync!(request) = Regulation::RndsSync.recompute!(request.reload, create: true, now: Time.current)

  def municipal_request!(**over) = regulation_request!(unit: create_unit("UBS #{SecureRandom.hex(3)}", cnes: regulation_cnes), **over)

  # Marcador do simulado no identificador fixo do Bundle (RECUSA, TIMEOUT, DUPLICADO).
  def mark!(sync, marker)
    sync.update_columns(bundle_identifier: "#{marker}-#{SecureRandom.hex(8)}")
    sync.reload
  end

  def posts = fake.log.select { |verb, path, _| verb == "POST" && path.end_with?("/Bundle") }
  def lookups = fake.log.select { |verb, path, _| verb == "GET" && path.end_with?("/identifier") }
  def deletes = fake.log.select { |verb, _path, _| verb == "DELETE" }
  def composition(bundle) = bundle["entry"].first["resource"]

  def client = Rnds::Client.for(Current.city, kind: "rnds_regulation", settings: Rnds::Config.simulated)
  def warm_token! = client.token!

  # A cadeia do identificador no simulado: [[id, status, replaces], ...].
  def chain(sync)
    system = "#{Regulation::RiraProfile.current.identifiers[:requester_prefix]}#{credential.requester_id}"
    client.identifier_chain(system: system, value: sync.reload.bundle_identifier, doc_type: "RIRA").documents
  end

  def schedule!(request, at: Time.current + 3.days)
    result = CareRegulation::ScheduleExternal.call(request: request.reload, at: at.iso8601, place: "Hospital Regional", notes: nil,
                                                   version: request.version, by: regulator, care_provider_id: offer.care_provider_id)
    raise "agendamento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  def miss!(request)
    ApplicationRecord.transaction do
      request.lock!(CareRegulation::Decide::LOCK)
      CareRegulation::Misses.apply!(request: request, by: regulator)
    end
    request.reload
  end

  def decide!(request, decision)
    result = CareRegulation::Decide.call(request: request.reload, decision: decision, reason: "Motivo da decisão de teste",
                                         version: request.version, by: regulator)
    raise "decisão recusada: #{result.reason}" if result.failure?

    request.reload
  end

  def complement!(request, by:, **attrs)
    body = { "justification" => "Complemento com os exames anexados" }.merge(attrs.transform_keys(&:to_s))
    result = CareRegulation::Complement.call(request: request.reload, attrs: body, version: request.version, by: by)
    raise "complemento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  describe "envio e cadeia de substituição" do
    it "pedido pendente → POST sem relatesTo, 201, idle com last_rnds_id do Location, payload cifrado e evento só com ids" do
      request = municipal_request!
      sync = sync!(request)
      run!

      sync.reload
      expect(posts.size).to eq(1)
      expect(posts.last[2]["authorization"]).to eq(credential.responsible_cns) # carry 1: o CNS do responsável
      bundle = fake.accepted.last[:bundle]
      expect(composition(bundle)).not_to have_key("relatesTo")
      expect(bundle.dig("identifier", "value")).to eq(sync.bundle_identifier)
      expect(sync).to have_attributes(status: "idle", last_rnds_id: fake.accepted.last[:id], sent_status: "pending",
                                      sent_digest: sync.desired_digest, attempts: 0, next_attempt_at: nil, last_error_codes: [])
      delivery = sync.deliveries.sole
      expect(delivery).to have_attributes(kind: "create", mira_status: "pending", digest: sync.desired_digest, http_status: 201,
                                          rnds_id: sync.last_rnds_id, error_codes: [])
      expect(delivery.accepted_at).to eq(Time.current)
      expect(JSON.parse(delivery.payload)).to eq(bundle)
      raw = RegulationRndsDelivery.connection.select_value(
        "SELECT payload FROM regulation_rnds_deliveries WHERE id = #{RegulationRndsDelivery.connection.quote(delivery.id)}"
      )
      identity = request.patient.cpf.presence || request.patient.cns
      expect(raw).not_to include(identity)
      expect(raw).not_to include("Bundle")
      expect(events("accepted").sole.payload).to eq("regulation_rnds_sync_id" => sync.id, "regulation_request_id" => request.id)
      expect(delivery.inspect + sync.inspect).not_to include(identity)
    end

    it "agendado depois → substituição com relatesTo Composition/<id> e o mesmo Bundle.identifier.value" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = sync!(request)
      run!
      first_id = sync.reload.last_rnds_id

      schedule!(request)
      expect(sync!(request)).to have_attributes(status: "queued", desired_status: "booked")
      run!

      sync.reload
      replacement = fake.accepted.last[:bundle]
      expect(composition(replacement)["relatesTo"]).to eq([ { "code" => "replaces", "targetReference" => { "reference" => "Composition/#{first_id}" } } ])
      expect(replacement.dig("identifier", "value")).to eq(sync.bundle_identifier)
      expect(sync).to have_attributes(status: "idle", sent_status: "booked", last_rnds_id: fake.accepted.last[:id])
      expect(sync.deliveries.map(&:kind)).to eq(%w[create replace])
      expect(chain(sync).map { |d| [ d.id, d.status, d.replaces ] })
        .to contain_exactly([ first_id, "entered-in-error", nil ], [ sync.last_rnds_id, "final", first_id ])
    end

    # Review Focus 2: autorizado → agendado → 1ª falta → pendente →
    # reautorizado antes do job: sai `absence` e depois só o estado final,
    # cada um substituindo o anterior, um por execução (nunca dois em voo).
    it "1ª falta → dois envios em duas execuções: absence e depois pending, cada um substituindo o anterior" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = sync!(request)
      run!
      first_id = sync.reload.last_rnds_id

      schedule!(request)
      miss!(request)
      reauthorize!(request.reload, offer: offer)
      sync = sync!(request)
      expect(sync).to have_attributes(status: "queued", desired_status: "pending")
      expect(sync.pending_steps.map { |step| step["status"] }).to eq(%w[absence])

      run!
      sync.reload
      expect(posts.size).to eq(2)
      absence = fake.accepted.last
      expect(composition(absence[:bundle]).dig("event", 0, "code", 0, "coding", 0, "code")).to eq("absence")
      expect(composition(absence[:bundle])["relatesTo"].sole.dig("targetReference", "reference")).to eq("Composition/#{first_id}")
      expect(sync).to have_attributes(status: "queued", sent_status: "absence", pending_steps: [], last_rnds_id: absence[:id])

      run!
      sync.reload
      expect(posts.size).to eq(3)
      final = fake.accepted.last
      expect(composition(final[:bundle]).dig("event", 0, "code", 0, "coding", 0, "code")).to eq("pending")
      expect(composition(final[:bundle])["relatesTo"].sole.dig("targetReference", "reference")).to eq("Composition/#{absence[:id]}")
      expect(sync).to have_attributes(status: "idle", sent_status: "pending", sent_digest: sync.desired_digest, last_rnds_id: final[:id])
      expect(chain(sync).select { |d| d.status == "final" }.map(&:id)).to eq([ final[:id] ])

      run!
      expect(posts.size).to eq(3)
    end

    it "aceito e depois desligado o envio dos regulados pelo estado → substituição excluded, linha excluded, eventos accepted e excluded" do
      rnds_settings!(send_external: true)
      request = municipal_request!(status: "external")
      sync = sync!(request)
      run!
      first_id = sync.reload.last_rnds_id

      rnds_settings!(send_external: false)
      expect(sync!(request)).to have_attributes(status: "queued", desired_status: "excluded")
      run!

      sent = fake.accepted.last[:bundle]
      expect(composition(sent).dig("event", 0, "code", 0, "coding", 0, "code")).to eq("excluded")
      expect(composition(sent)["relatesTo"].sole.dig("targetReference", "reference")).to eq("Composition/#{first_id}")
      expect(sync.reload).to have_attributes(status: "excluded", sent_status: "excluded", next_attempt_at: nil)
      expect(events("accepted").count).to eq(2)
      expect(events("excluded").sole.payload).to eq("regulation_rnds_sync_id" => sync.id, "regulation_request_id" => request.id)
      run!
      expect(posts.size).to eq(2)
    end

    it "dois pedidos, um parado e um ok, na mesma execução → só o ok sai" do
      ok = municipal_request!
      stopped = regulation_request! # unidade solicitante sem CNES
      [ ok, stopped ].each { |request| sync!(request) }
      run!

      expect(posts.size).to eq(1)
      blocked = RegulationRndsSync.find_by!(regulation_request_id: stopped.id)
      expect(blocked).to have_attributes(status: "blocked", blocked_reasons: [ "requester_unit_without_cnes" ],
                                         next_attempt_at: Time.current + 1.hour, attempts: 0)
      expect(blocked.deliveries).to be_empty
      expect(events("blocked").sole.payload).to eq("regulation_rnds_sync_id" => blocked.id, "regulation_request_id" => stopped.id)
      expect(RegulationRndsSync.find_by!(regulation_request_id: ok.id).status).to eq("idle")
    end

    it "parado → 1 h depois revalida e sai quando o CNES aparece" do
      request = regulation_request!
      sync = sync!(request)
      run!
      expect(sync.reload.status).to eq("blocked")

      request.requester_unit.update!(cnes: regulation_cnes) # o consumidor não rodou: só a revalidação de hora em hora
      travel 59.minutes
      run!
      expect(posts).to be_empty
      expect(sync.reload.status).to eq("blocked")

      travel 1.minute
      run!
      expect(posts.size).to eq(1)
      expect(sync.reload).to have_attributes(status: "idle", blocked_reasons: [], sent_status: "pending")
      expect(events("blocked").count).to eq(1)
    end

    it "esqueleto com problema (Q23) → parado com skeleton:<caminho>, nada sai" do
      sync = sync!(municipal_request!)
      allow(Regulation::RiraSkeleton).to receive(:problems).and_return([ "Composition.title" ])
      run!

      expect(posts).to be_empty
      expect(sync.reload).to have_attributes(status: "blocked", blocked_reasons: [ "skeleton:Composition.title" ])
    end

    it "pedido aceito que perde CPF e CNS antes do envio → erased, nada sai" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = sync!(request)
      run!
      schedule!(request)
      sync!(request)
      allow(Regulation::RiraFacts).to receive(:for).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).with(patient_cpf: nil, patient_cns: nil)
      end
      run!

      expect(posts.size).to eq(1)
      expect(sync.reload).to have_attributes(status: "erased", next_attempt_at: nil)
    end
  end

  describe "recusa (422)" do
    it "RECUSA → rejected com EHR-ERR999; mudar o CID → volta a queued e sai com o conteúdo novo (recusado de novo, M14)" do
      unit = create_unit("UBS #{SecureRandom.hex(3)}", cnes: regulation_cnes)
      physician = doctor!(unit)
      request = regulation_request!(unit: unit, doctor: physician)
      sync = mark!(sync!(request), "RECUSA")
      run!

      sync.reload
      expect(sync).to have_attributes(status: "rejected", last_error_codes: [ "EHR-ERR999" ], last_rnds_id: nil)
      expect(sync.deliveries.sole).to have_attributes(http_status: 422, error_codes: [ "EHR-ERR999" ], accepted_at: nil, rnds_id: nil)
      expect(events("rejected").sole.payload).to eq("regulation_rnds_sync_id" => sync.id, "regulation_request_id" => request.id)
      run!
      expect(posts.size).to eq(1) # recusado não é reivindicado

      decide!(request, "return")
      complement!(request, by: physician, cid10: "E119")
      expect(sync!(request)).to have_attributes(status: "queued")
      run!

      expect(posts.size).to eq(2)
      sent = JSON.parse(sync.reload.deliveries.last.payload)
      condition = sent["entry"].map { |entry| entry["resource"] }.find { |resource| resource["resourceType"] == "Condition" }
      expect(condition.dig("code", "coding", 0, "code")).to eq("E119")
      expect(a_request(:post, %r{fake-rnds\.test:8094/api/fhir/r4/Bundle\z}).with { |req| req.body.include?("E119") }).to have_been_made.once
      expect(sync).to have_attributes(status: "rejected", last_error_codes: [ "EHR-ERR999" ])
      expect(sync.deliveries.size).to eq(2)
    end

    it "422 sem código da RNDS → rejected sem códigos gravados (Q25: só ERROR_CODE)" do
      sync = sync!(municipal_request!)
      warm_token!
      fake.failures.push(422) # OperationOutcome "Erro simulado", sem código
      run!
      expect(sync.reload).to have_attributes(status: "rejected", last_error_codes: [])
      expect(sync.deliveries.sole).to have_attributes(http_status: 422, error_codes: [])
    end
  end

  describe "reconciliação pelo GET /identifier" do
    # Review Focus 1: o POST chegou e a resposta não.
    it "TIMEOUT → attempts 1; a próxima execução consulta GET /identifier, adota sem novo POST e fica idle; o mesmo na substituição" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = mark!(sync!(request), "TIMEOUT")
      run!

      sync.reload
      expect(sync).to have_attributes(status: "queued", attempts: 1, next_attempt_at: Time.current + 1.minute, last_rnds_id: nil)
      delivery = sync.deliveries.sole
      expect(delivery).to have_attributes(http_status: nil, accepted_at: nil)
      expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(true)
      stored = chain(sync).sole
      expect([ stored.status, stored.replaces ]).to eq([ "final", nil ])

      travel 1.minute
      expect { run! }.not_to(change { posts.size })
      expect(lookups.size).to eq(2) # o do teste (chain) e o da reconciliação
      sync.reload
      expect(sync).to have_attributes(status: "idle", last_rnds_id: stored.id, sent_status: "pending", sent_digest: sync.desired_digest,
                                      attempts: 0, next_attempt_at: nil)
      expect(delivery.reload).to have_attributes(rnds_id: stored.id, http_status: nil)
      expect(delivery.accepted_at).to eq(Time.current)
      expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(false)
      expect(events("accepted").count).to eq(1)

      # a substituição também estoura: grava (o anterior vira entered-in-error) e não responde
      schedule!(request)
      sync!(request)
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 1, last_rnds_id: stored.id)

      travel 1.minute
      expect { run! }.not_to(change { posts.size })
      sync.reload
      head = chain(sync).find { |d| d.status == "final" }
      expect(head.replaces).to eq(stored.id)
      expect(sync).to have_attributes(status: "idle", last_rnds_id: head.id, sent_status: "booked", attempts: 0)
      expect(chain(sync).map(&:id)).to contain_exactly(stored.id, head.id) # nunca um segundo documento "novo"
    end

    it "carry 3: o gatilho é a remessa sem resposta, não o attempts" do
      sync = mark!(sync!(municipal_request!), "TIMEOUT")
      run!
      sync.update_columns(attempts: 0) # o recálculo zera ao reenfileirar
      travel 1.minute
      run!
      expect(lookups.size).to eq(1)
      expect(sync.reload.status).to eq("idle")
    end

    it "DUPLICADO → a reconciliação adota o mais antigo, apaga o mais novo (204) e segue" do
      sync = mark!(sync!(municipal_request!), "DUPLICADO")
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 1)
      older, newer = chain(sync).sort_by { |d| Time.iso8601(d.date) }
      expect([ older.status, newer.status ]).to eq(%w[final final])

      travel 1.minute
      expect { run! }.not_to(change { posts.size })
      sync.reload
      expect(deletes.map { |_, path, _| path }).to eq([ "/api/fhir/r4/Bundle/#{newer.id}" ])
      expect(sync).to have_attributes(status: "idle", last_rnds_id: older.id, sent_status: "pending")
      removal = sync.deliveries.find_by!(kind: "delete")
      expect(removal).to have_attributes(rnds_id: newer.id, http_status: 204, payload: nil, accepted_at: nil)
      expect(chain(sync).map { |d| [ d.id, d.status ] }).to contain_exactly([ older.id, "final" ], [ newer.id, "entered-in-error" ])
    end

    it "DUPLICADO com o DELETE recusado (4xx que não é EHR-ERR825) → não adota, códigos visíveis, tenta de novo com espera e termina" do
      sync = mark!(sync!(municipal_request!), "DUPLICADO")
      run!
      older, newer = chain(sync).sort_by { |d| Time.iso8601(d.date) }
      body = JSON.generate({ resourceType: "OperationOutcome", issue: [ { severity: "error", diagnostics: "(EHR-ERR123) Recusado" } ] })
      stub_request(:delete, %r{\Ahttp://fake-rnds\.test:8094/api/fhir/r4/Bundle/}).to_return(status: 422, body: body).then.to_rack(fake)

      travel 1.minute
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 2, last_rnds_id: nil, last_error_codes: [ "EHR-ERR123" ],
                                             next_attempt_at: Time.current + 2.minutes)
      expect(chain(sync).map(&:status)).to eq(%w[final final])

      travel 2.minutes
      expect { run! }.not_to(change { posts.size })
      expect(sync.reload).to have_attributes(status: "idle", last_rnds_id: older.id, last_error_codes: [])
      expect(chain(sync).map { |d| [ d.id, d.status ] }).to contain_exactly([ older.id, "final" ], [ newer.id, "entered-in-error" ])
    end

    # Review Focus 3: o last_rnds_id gravado já foi substituído por uma
    # tentativa anterior sem resposta (aqui, por fora).
    it "EDS-MSG009 (o last_rnds_id apontando para um já substituído) → adota a cabeça da cadeia, não fica rejected" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = sync!(request)
      run!
      first_id = sync.reload.last_rnds_id
      outside = Regulation::RiraBundle.for(request: request.reload, sync: sync, status: Regulation::RndsSync.target(request, settings: settings),
                                           now: Time.current)
      other_id = client.post_bundle(outside, practitioner_cns: credential.responsible_cns).rnds_id

      schedule!(request)
      sync!(request)
      run!

      sync.reload
      refused = sync.deliveries.last
      expect(refused).to have_attributes(kind: "replace", http_status: 422, error_codes: [ "EDS-MSG009" ])
      expect(sync).to have_attributes(status: "queued", last_rnds_id: other_id, sent_digest: nil, last_error_codes: [])
      expect(events("rejected")).to be_empty

      run!
      sync.reload
      expect(sync).to have_attributes(status: "idle", sent_status: "booked")
      expect(composition(fake.accepted.last[:bundle])["relatesTo"].sole.dig("targetReference", "reference")).to eq("Composition/#{other_id}")
      expect(chain(sync).map { |d| [ d.id, d.status ] })
        .to contain_exactly([ first_id, "entered-in-error" ], [ other_id, "entered-in-error" ], [ sync.last_rnds_id, "final" ])
    end

    it "EDS-MSG009 sem cabeça achada (:none, I3) → rejected com EDS-MSG009, sem laço" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = sync!(request)
      run!
      outside = Regulation::RiraBundle.for(request: request.reload, sync: sync.reload, status: Regulation::RndsSync.target(request, settings: settings),
                                           now: Time.current)
      client.post_bundle(outside, practitioner_cns: credential.responsible_cns)
      schedule!(request)
      sync!(request)
      allow_any_instance_of(Rnds::Client).to receive(:identifier_chain).and_return(Rnds::Client::IdentifierChain.new(status: :ok, documents: []))
      run!

      expect(sync.reload).to have_attributes(status: "rejected", last_error_codes: [ "EDS-MSG009" ])
      expect(events("rejected").count).to eq(1)
      run!
      expect(posts.size).to eq(3) # o create, o de fora e a substituição recusada; nada mais
    end

    it "carry 5: desejado excluded, nunca aceito, remessa sem resposta que não chegou → GET, nada achado, excluded sem POST" do
      rnds_settings!(send_external: true)
      request = municipal_request!(status: "external")
      sync = sync!(request)
      lost = RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: "pending", digest: sync.desired_digest,
                                            sent_at: Time.current)
      rnds_settings!(send_external: false)
      expect(sync!(request)).to have_attributes(status: "queued", desired_status: "excluded")
      run!

      expect(posts).to be_empty
      expect(lookups.size).to eq(1)
      sync.reload
      expect(sync).to have_attributes(status: "excluded", last_rnds_id: nil, next_attempt_at: nil)
      expect(lost.reload).to have_attributes(unanswered_closed_at: Time.current, error_codes: [], http_status: nil, accepted_at: nil)
      expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(false)
      expect(sync!(request)).to have_attributes(status: "excluded")
    end
  end

  describe "remessa sem resposta que não chegou (Q25)" do
    it "GET sem documento → a remessa fecha (unanswered_closed_at) e a linha segue: envia na mesma rodada" do
      sync = sync!(municipal_request!)
      lost = RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: "pending", digest: sync.desired_digest,
                                            sent_at: Time.current)
      travel 1.second
      run!

      expect(lookups.size).to eq(1)
      expect(posts.size).to eq(1)
      expect(lost.reload).to have_attributes(unanswered_closed_at: Time.current, error_codes: [], accepted_at: nil, http_status: nil)
      expect(sync.reload).to have_attributes(status: "idle", last_rnds_id: fake.accepted.last[:id])
      expect(sync.deliveries.last).to have_attributes(kind: "create", http_status: 201)
    end
  end

  describe "credencial recusada (Review Focus 4)" do
    it "401 duas vezes no meio do lote → credencial unauthorized, linhas queued sem tentativa, RndsGate.usable? falso" do
      requests = Array.new(3) { municipal_request! }
      requests.each { |request| sync!(request) }
      warm_token!
      fake.failures.push(nil, 401, 401) # o 1º POST passa; o 2º e o token novo recusam
      run!

      expect(RegulationRndsSync.order(:enqueued_at).pluck(:status, :attempts)).to contain_exactly([ "idle", 0 ], [ "queued", 0 ], [ "queued", 0 ])
      expect(credential.last_check_status).to eq("unauthorized")
      expect(Regulation::RndsGate.usable?(Current.city)).to be(false)
      expect(Regulation::RndsGate.enabled?(Current.city)).to be(true) # a tela de situação segue respondendo (Q10)
      refused = RegulationRndsDelivery.where(http_status: 401).sole
      expect(Regulation::RndsSync.unanswered_delivery?(refused.regulation_rnds_sync)).to be(false)

      seen = fake.log.size
      run!
      expect(fake.log.size).to eq(seen)
    end
  end

  describe "falha transitória e desistência (Q16)" do
    it "5xx → backoff; a 5xx respondida não é sem resposta (carry 6): a próxima sai sem GET" do
      sync = sync!(municipal_request!)
      warm_token!
      fake.failures.push(503)
      run!

      sync.reload
      expect(sync).to have_attributes(status: "queued", attempts: 1, next_attempt_at: Time.current + 1.minute)
      expect(sync.deliveries.sole).to have_attributes(http_status: 503, accepted_at: nil)
      expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(false)

      run! # antes da espera: nada
      expect(posts.size).to eq(1)
      travel 1.minute
      run!
      expect(lookups).to be_empty
      expect(sync.reload).to have_attributes(status: "idle", attempts: 0)
    end

    it "conta da 1ª remessa sem aceite (retry_window_started_at): 16 dias depois → failed; enqueued_at antigo não conta; o Reenviar reabre" do
      sync = sync!(municipal_request!)
      sync.update_columns(enqueued_at: 20.days.ago) # esperou parado: não conta (I4)
      warm_token!
      fake.failures.push(503)
      run!
      first = sync.deliveries.sole
      expect(sync.reload).to have_attributes(status: "queued", attempts: 1, retry_window_started_at: first.sent_at)

      travel 16.days
      fake.failures.push(503)
      expect { run! }.not_to raise_error
      expect(sync.reload).to have_attributes(status: "failed", attempts: 2, retry_window_started_at: first.sent_at)
      expect(RegulationRndsDelivery.pluck(:error_codes).uniq).to eq([ [] ]) # só códigos da RNDS (Q25)
      run!
      expect(posts.size).to eq(2) # failed não é reivindicado

      # O "Reenviar" da Task 14: reopen_retry_window! + queued, attempts 0, agora (conteúdo e enqueued_at intactos).
      sync.reopen_retry_window!
      sync.update!(status: "queued", attempts: 0, next_attempt_at: Time.current)
      fake.failures.push(503)
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 1, retry_window_started_at: sync.deliveries.last.sent_at)
    end

    it "com o trigger endurecido, a 503 que esgota o prazo vira failed sem levantar e o resto do lote segue" do
      stale = sync!(municipal_request!)
      warm_token!
      fake.failures.push(503)
      run!
      travel 16.days
      fresh = sync!(municipal_request!)
      reported = []
      allow(Rails.error).to receive(:report) { |error, **| reported << error.message }
      fake.failures.push(503) # a primeira do lote: a linha vencida
      expect { run! }.not_to raise_error

      expect(stale.reload).to have_attributes(status: "failed", attempts: 2)
      expect(stale.deliveries.last).to have_attributes(http_status: 503, error_codes: [])
      expect(fresh.reload).to have_attributes(status: "idle", attempts: 0)
      expect(reported).to be_empty
    end

    # Nota da Q25: a recusa é parada não transitória; a janela recomeça no próximo envio.
    it "rejected corrigido 15 dias depois → uma 5xx não vira failed" do
      unit = create_unit("UBS #{SecureRandom.hex(3)}", cnes: regulation_cnes)
      physician = doctor!(unit)
      request = regulation_request!(unit: unit, doctor: physician)
      sync = sync!(request)
      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload.retry_window_started_at).to be_present
      travel 1.minute
      fake.failures.push(422)
      run!
      expect(sync.reload).to have_attributes(status: "rejected", retry_window_started_at: nil)

      travel 15.days
      decide!(request, "return")
      complement!(request, by: physician, cid10: "E119")
      expect(sync!(request)).to have_attributes(status: "queued")
      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 1, retry_window_started_at: sync.deliveries.last.sent_at)
    end

    # Nota da Q25: o bloqueio com motivo e a pausa por 401/403 também são paradas.
    it "parado com motivo e pausa por 401 zeram a janela; ela recomeça no próximo envio" do
      unit = create_unit("UBS #{SecureRandom.hex(3)}", cnes: regulation_cnes)
      blocked = sync!(regulation_request!(unit: unit))
      paused = sync!(municipal_request!)
      warm_token!
      fake.failures.push(503, 503)
      run!
      expect([ blocked, paused ].map { |sync| sync.reload.retry_window_started_at }).to all(be_present)

      unit.update_columns(cnes: nil)
      travel 1.minute
      fake.failures.push(401, 401) # o POST da segunda e o token novo recusam
      run!
      expect(blocked.reload).to have_attributes(status: "blocked", blocked_reasons: [ "requester_unit_without_cnes" ], retry_window_started_at: nil)
      expect(paused.reload).to have_attributes(status: "queued", retry_window_started_at: nil)
    end

    # Task 12, Minor: a linha reaberta com a remessa sem resposta e o GET sempre 5xx desiste.
    it "Reenviar com remessa sem resposta e GET /identifier sempre 5xx → a janela abre no transitório e desiste em 15 dias" do
      sync = mark!(sync!(municipal_request!), "TIMEOUT")
      run!
      expect(Regulation::RndsSync.unanswered_delivery?(sync.reload)).to be(true)
      sync.reopen_retry_window!
      sync.update!(status: "queued", attempts: 0, next_attempt_at: Time.current)

      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 1, retry_window_started_at: Time.current)

      travel 16.days
      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload).to have_attributes(status: "failed", attempts: 2)
      expect(posts.size).to eq(1)
    end

    # I3 (Q16): desligado ou sem credencial, o tempo parado não conta.
    it "credencial ausente 20 dias com janela aberta → religa → uma 5xx não vira failed" do
      sync = sync!(municipal_request!)
      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload.retry_window_started_at).to be_present

      IntegrationCredential.where(kind: "rnds_regulation").delete_all
      travel 1.minute
      run!
      expect(sync.reload).to have_attributes(status: "queued", retry_window_started_at: nil)

      travel 20.days
      run!
      rnds_regulation_credential!
      Rnds::Client.reset_cache!
      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload).to have_attributes(status: "queued", attempts: 2, retry_window_started_at: sync.deliveries.last.sent_at)
    end

    it "aceite zera retry_window_started_at" do
      sync = sync!(municipal_request!)
      warm_token!
      fake.failures.push(503)
      run!
      expect(sync.reload.retry_window_started_at).to be_present
      travel 1.minute
      run!
      expect(sync.reload).to have_attributes(status: "idle", retry_window_started_at: nil)
    end
  end

  describe "interruptores, alvo e purga" do
    it "sem credencial → nada sai e as linhas ficam" do
      sync = sync!(municipal_request!)
      IntegrationCredential.where(kind: "rnds_regulation").delete_all
      run!
      expect(fake.log).to be_empty
      expect(sync.reload).to have_attributes(status: "queued", attempts: 0)
    end

    it "desligado → nada sai" do
      sync = sync!(municipal_request!)
      Platform::Features.set!(city: Current.city, key: Regulation::RndsGate::KEY, enabled: false, maintainer: ledi_maintainer!)
      run!
      expect(fake.log).to be_empty
      expect(sync.reload.status).to eq("queued")
    end

    it "rnds_mock ligado → vai ao simulado; desligado e sem URL da plataforma → NotConfigured resgatado, nada sai, linhas devolvidas (I15)" do
      first = sync!(municipal_request!)
      run!
      expect(posts.size).to eq(1)
      expect(first.reload.status).to eq("idle")

      Platform::Features.set!(city: Current.city, key: Rnds::Mock::KEY, enabled: false, maintainer: ledi_maintainer!)
      allow(Rnds::Config).to receive(:credentials).and_return({})
      second = sync!(municipal_request!)
      logged = []
      allow(Rails.logger).to receive(:warn) { |message| logged << message }
      expect { run! }.not_to raise_error
      expect(posts.size).to eq(1)
      expect(second.reload).to have_attributes(status: "queued", attempts: 0)
      expect(logged).to include("[Regulation::RndsDeliverJob] city=#{Current.city.slug} Rnds::Errors::NotConfigured")
    end

    it "payload de 31 dias → NULL (aceito ou não, com o interruptor desligado, Q17); metadados ficam" do
      sync = sync!(municipal_request!)
      old_accepted = RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: "pending", digest: "a" * 64,
                                                    payload: "{}", sent_at: 31.days.ago, accepted_at: 31.days.ago, rnds_id: "old-1", http_status: 201)
      old_refused = RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "replace", mira_status: "booked", digest: "b" * 64,
                                                   payload: "{}", sent_at: 31.days.ago, http_status: 422, error_codes: [ "EHR-ERR999" ])
      recent = RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "replace", mira_status: "booked", digest: "c" * 64,
                                              payload: "{}", sent_at: 29.days.ago, accepted_at: 29.days.ago, rnds_id: "old-2", http_status: 201)
      Platform::Features.set!(city: Current.city, key: Regulation::RndsGate::KEY, enabled: false, maintainer: ledi_maintainer!)
      run!

      expect(old_accepted.reload).to have_attributes(payload: nil, rnds_id: "old-1", http_status: 201, mira_status: "pending")
      expect(old_refused.reload).to have_attributes(payload: nil, http_status: 422, error_codes: [ "EHR-ERR999" ])
      expect(recent.reload.payload).to eq("{}")
    end
  end

  describe "posse do claim e concorrência" do
    it "duas execuções simultâneas nunca enviam o mesmo pedido: o claim é disjunto e a execução que perdeu a linha não envia (I2)" do
      2.times { sync!(municipal_request!) }
      first = RegulationRndsSync.claim!(limit: 20, initial_limit: 60)
      expect(first.size).to eq(2)
      expect(RegulationRndsSync.claim!(limit: 20, initial_limit: 60)).to be_empty

      RegulationRndsSync.where(id: first.map(&:id)).update_all(claimed_at: 11.minutes.ago, updated_at: Time.current)
      stale = RegulationRndsSync.where(id: first.map(&:id)).to_a
      fresh = travel(1.second) do
        RegulationRndsSync.release_stale!(before: 10.minutes.ago) # pela posse (claimed_at), não pelo updated_at
        RegulationRndsSync.claim!(limit: 20, initial_limit: 60)
      end
      expect(fresh.map(&:id)).to match_array(stale.map(&:id))

      expect(Regulation::RndsDelivery.new(Current.city).run(stale)).to eq(:done) # a execução antiga, atrasada
      expect(posts).to be_empty
      RegulationRndsSync.release!(stale.map(&:id), token: stale.first.claimed_at) # o ensure dela
      expect(RegulationRndsSync.pluck(:status).uniq).to eq([ "sending" ])

      Regulation::RndsDelivery.new(Current.city).run(fresh)
      expect(posts.size).to eq(2)
      expect(RegulationRndsSync.pluck(:status).uniq).to eq([ "idle" ])
    end

    it "claim: primeiro os sem initial_load até limit, depois os initial_load até initial_limit; só queued/blocked vencidos" do
      rows = Array.new(5) { sync!(municipal_request!) }
      rows[0..1].each { |row| row.update_columns(initial_load: true) }
      rows[4].update_columns(next_attempt_at: 1.minute.from_now)
      picked = RegulationRndsSync.claim!(limit: 1, initial_limit: 1)
      expect(picked.map(&:initial_load)).to eq([ false, true ])
      expect(picked.map(&:status).uniq).to eq([ "sending" ])
      expect(picked.map(&:claimed_at).uniq).to eq([ Time.current ])
      expect(picked.map(&:id)).not_to include(rows[4].id)
    end

    # I1: o RndsSyncJob recalcula a linha `sending` durante o HTTP.
    it "evento durante o POST → depois do 201 a linha fica queued com o conteúdo novo" do
      request = reauthorize!(municipal_request!, offer: offer)
      sync = sync!(request)
      changed = false
      allow_any_instance_of(Rnds::Client).to receive(:post_bundle).and_wrap_original do |original, *args, **kwargs|
        unless changed
          changed = true
          schedule!(request)
          expect(sync!(request)).to have_attributes(status: "sending", desired_status: "booked")
        end
        original.call(*args, **kwargs)
      end
      run!

      expect(sync.reload).to have_attributes(status: "queued", sent_status: "pending", desired_status: "booked")
      expect(sync.next_attempt_at).to be <= Time.current
      run!
      expect(sync.reload).to have_attributes(status: "idle", sent_status: "booked")
    end

    it "orçamento esgotado: o resto volta a queued sem tentativa e sai na rodada seguinte" do
      2.times { sync!(municipal_request!) }
      ticks = [ 0.0, 0.0, Regulation::RndsLimits::BUDGET.to_f + 1 ]
      clock = -> { ticks.size > 1 ? ticks.shift : ticks.first }
      syncs = RegulationRndsSync.claim!(limit: 20, initial_limit: 60)
      expect(Regulation::RndsDelivery.new(Current.city, clock: clock).run(syncs)).to eq(:done)
      expect(RegulationRndsSync.pluck(:status, :attempts)).to contain_exactly([ "idle", 0 ], [ "queued", 0 ])
      expect(posts.size).to eq(1)
      run!
      expect(RegulationRndsSync.pluck(:status).uniq).to eq([ "idle" ])
      expect(Regulation::RndsLimits::BUDGET).to be < Regulation::RndsLimits::STALE_SENDING / 2
    end

    it "erro inesperado numa linha: ela volta a queued com espera e o resto do lote segue; o log só tem a classe" do
      bad, good = Array.new(2) { municipal_request! }.map { |request| sync!(request) }
      allow(Regulation::RiraBundle).to receive(:build).and_wrap_original do |original, **kwargs|
        raise ArgumentError, "CPF 12345678901 vazou" if kwargs[:sync].id == bad.id && kwargs[:facts].requester_id

        original.call(**kwargs)
      end
      reported = []
      allow(Rails.error).to receive(:report) { |error, **| reported << error.message }
      run!

      expect(bad.reload).to have_attributes(status: "queued", attempts: 1)
      expect(good.reload.status).to eq("idle")
      expect(reported).to eq([ "regulation rnds delivery: ArgumentError" ])
    end

    it "é recorrente a cada minuto e um lote por cidade de cada vez" do
      recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
      expect(recurring.values.filter_map { |tasks| tasks.is_a?(Hash) && tasks["rnds_regulation_deliver"] }.first)
        .to include("class" => "Regulation::RndsDeliverJob", "schedule" => "every minute", "queue" => "default")
      expect(described_class.concurrency_key).to be_present
      expect(described_class.concurrency_limit).to eq(1)
      expect(described_class.concurrency_duration).to eq(Regulation::RndsLimits::STALE_SENDING)
    end
  end
end
