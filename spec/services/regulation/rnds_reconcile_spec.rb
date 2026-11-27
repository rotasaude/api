require "rails_helper"

# Módulo 26c, Task 12 (contrato §3; pré-voo B5, B6; carry 4): a reconciliação
# de uma linha pelo `GET /identifier`, contra o FakeRnds::App. Os resultados:
# `:adopted` (a cabeça da cadeia vira o `last_rnds_id`, a remessa sem resposta
# é adotada), `:none` (nada chegou: a remessa sem resposta fecha com
# `unanswered_closed_at`, Q25), `:deduplicated` (dois `final` sem relação: o mais novo é apagado),
# `:transient` e `:unauthorized` (nada muda). A situação da linha depois disso
# é do envio (RndsDelivery).
RSpec.describe Regulation::RndsReconcile, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }
  let(:fake) { fake_rnds! }
  let(:client) { Rnds::Client.for(Current.city, kind: "rnds_regulation", settings: Rnds::Config.simulated) }
  let(:credential) { IntegrationCredential.find_by!(kind: "rnds_regulation") }
  let(:request) { regulation_request!(unit: create_unit("UBS #{SecureRandom.hex(3)}", cnes: regulation_cnes)) }
  let(:sync) { Regulation::RndsSync.recompute!(request, create: true, now: Time.current) }

  before do
    travel_to now
    rnds_regulation_city!(mock: true)
    fake
  end

  def call = described_class.call(sync: sync.reload, client: client, now: Time.current)

  def document(relates_to: nil)
    status = Regulation::RndsSync.target(request.reload, settings: RegulationRndsSetting.current)
    bundle = Regulation::RiraBundle.for(request: request, sync: sync.reload, status: status, now: Time.current)
    composition = bundle["entry"].first["resource"]
    composition.delete("relatesTo")
    composition["relatesTo"] = [ { "code" => "replaces", "targetReference" => { "reference" => "Composition/#{relates_to}" } } ] if relates_to
    bundle
  end

  def post!(**opts) = client.post_bundle(document(**opts), practitioner_cns: credential.responsible_cns).rnds_id

  # A remessa que saiu e não teve resposta (timeout).
  def unanswered!(mira_status: "pending", kind: "create")
    RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: kind, mira_status: mira_status, digest: sync.desired_digest,
                                   payload: "{}", sent_at: Time.current)
  end

  def chain
    system = "#{Regulation::RiraProfile.current.identifiers[:requester_prefix]}#{credential.requester_id}"
    client.identifier_chain(system: system, value: sync.bundle_identifier, doc_type: "RIRA").documents
  end

  it ":adopted — sem last_rnds_id, o final sem relatesTo; a remessa sem resposta vira aceita com o que ela levou" do
    delivery = unanswered!
    id = post!
    expect(call).to eq(:adopted)

    expect(delivery.reload).to have_attributes(rnds_id: id, http_status: nil, accepted_at: Time.current)
    expect(sync.reload).to have_attributes(last_rnds_id: id, last_accepted_at: Time.current, sent_status: "pending",
                                           sent_digest: sync.desired_digest, attempts: 0)
    expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(false)
    expect(fake.log.map { |verb, path, _| [ verb, path ] }.last).to eq([ "GET", "/api/identifier" ])
  end

  it ":adopted — com last_rnds_id, segue a cadeia até a cabeça (B6)" do
    first = post!
    sync.update_columns(last_rnds_id: first, sent_status: "pending", sent_digest: sync.desired_digest)
    second = post!(relates_to: first)
    third = post!(relates_to: second)
    delivery = unanswered!(kind: "replace", mira_status: "booked")

    expect(call).to eq(:adopted)
    expect(sync.reload).to have_attributes(last_rnds_id: third, sent_status: "booked")
    expect(delivery.reload.rnds_id).to eq(third)
  end

  it ":adopted sem remessa sem resposta (o caminho do EDS-MSG009): só o rnds_id, sent_digest nulo" do
    first = post!
    sync.update_columns(last_rnds_id: first, sent_status: "pending", sent_digest: sync.desired_digest)
    head = post!(relates_to: first)

    expect(call).to eq(:adopted)
    expect(sync.reload).to have_attributes(last_rnds_id: head, sent_digest: nil, sent_status: nil)
    expect(RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id)).to be_empty
  end

  it ":none — nada chegou: a remessa sem resposta fecha (unanswered_closed_at); a linha não muda" do
    delivery = unanswered!
    expect(call).to eq(:none)
    expect(delivery.reload).to have_attributes(unanswered_closed_at: Time.current, error_codes: [], http_status: nil, accepted_at: nil,
                                               rnds_id: nil)
    expect(sync.reload).to have_attributes(last_rnds_id: nil, sent_digest: nil)
    expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(false)
  end

  it ":none — com last_rnds_id e nada que o substitua" do
    first = post!
    sync.update_columns(last_rnds_id: first, sent_status: "pending", sent_digest: sync.desired_digest)
    unanswered!(kind: "replace", mira_status: "booked")
    expect(call).to eq(:none)
    expect(sync.reload.last_rnds_id).to eq(first)
  end

  it ":deduplicated — dois final sem relação: apaga o mais novo (remessa delete), fica o mais antigo" do
    delivery = unanswered!
    older = post!
    travel 1.second
    newer = post!

    expect(call).to eq(:deduplicated)
    expect(sync.reload.last_rnds_id).to eq(older)
    expect(delivery.reload.rnds_id).to eq(older)
    removal = RegulationRndsDelivery.find_by!(regulation_rnds_sync_id: sync.id, kind: "delete")
    expect(removal).to have_attributes(rnds_id: newer, http_status: 204, payload: nil, mira_status: nil, digest: nil, accepted_at: nil)
    expect(chain.map { |d| [ d.id, d.status ] }).to contain_exactly([ older, "final" ], [ newer, "entered-in-error" ])
    expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(false)
  end

  # Fix round 1 (revisão, Important 2): só o 204 e o EHR-ERR825 (já não é
  # final) contam como apagado.
  def refuse_delete!(text, status: 422)
    body = JSON.generate({ resourceType: "OperationOutcome", issue: [ { severity: "error", code: "processing", diagnostics: text } ] })
    stub_request(:delete, %r{\Ahttp://fake-rnds\.test:8094/api/fhir/r4/Bundle/}).to_return(status: status, body: body).then.to_rack(fake)
  end

  it "DELETE recusado com EHR-ERR825 (já não é final) → conta como apagado: :deduplicated" do
    unanswered!
    older = post!
    travel 1.second
    newer = post!
    refuse_delete!("(EHR-ERR825) O documento #{newer} não está no estado final.")

    expect(call).to eq(:deduplicated)
    expect(sync.reload).to have_attributes(last_rnds_id: older, last_error_codes: [])
    expect(RegulationRndsDelivery.find_by!(regulation_rnds_sync_id: sync.id, kind: "delete"))
      .to have_attributes(rnds_id: newer, http_status: 422, error_codes: [ "EHR-ERR825" ])
  end

  it "DELETE recusado com outro 4xx → não conta: :transient, códigos em last_error_codes, Rails.error sem dado; nada adotado" do
    delivery = unanswered!
    older = post!
    travel 1.second
    newer = post!
    refuse_delete!("(EHR-ERR123) Recusado para o CPF 12345678901")
    reported = []
    allow(Rails.error).to receive(:report) { |error, **| reported << error.message }

    expect(call).to eq(:transient)
    expect(sync.reload).to have_attributes(last_rnds_id: nil, last_error_codes: [ "EHR-ERR123" ])
    expect(delivery.reload).to have_attributes(accepted_at: nil, rnds_id: nil)
    expect(Regulation::RndsSync.unanswered_delivery?(sync)).to be(true) # a reconciliação fica por terminar
    expect(RegulationRndsDelivery.find_by!(regulation_rnds_sync_id: sync.id, kind: "delete"))
      .to have_attributes(rnds_id: newer, http_status: 422, error_codes: [ "EHR-ERR123" ])
    expect(reported).to eq([ "Regulation::RndsReconcile: delete refused regulation_rnds_sync_id=#{sync.id}" ])
    expect(chain.map { |d| [ d.id, d.status ] }).to contain_exactly([ older, "final" ], [ newer, "final" ])

    expect(call).to eq(:deduplicated) # a próxima tentativa: o simulado aceita
    expect(sync.reload).to have_attributes(last_rnds_id: older, last_error_codes: [])
    expect(chain.map { |d| [ d.id, d.status ] }).to contain_exactly([ older, "final" ], [ newer, "entered-in-error" ])
  end

  it ":transient — a RNDS fora do ar: nada muda e o GET não vira remessa" do
    delivery = unanswered!
    client.token!
    fake.failures.push(503)
    expect(call).to eq(:transient)
    expect(delivery.reload).to have_attributes(error_codes: [], accepted_at: nil, http_status: nil)
    expect(RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id).count).to eq(1)
  end

  it ":unauthorized — 401 no GET: nada muda (o envio pausa)" do
    delivery = unanswered!
    client.token!
    fake.failures.push(401, 401)
    expect(call).to eq(:unauthorized)
    expect(delivery.reload).to have_attributes(error_codes: [], accepted_at: nil)
  end

  it "com o token do claim, a linha de outra execução → LostClaim e nada é gravado" do
    delivery = unanswered!
    post!
    sync.update_columns(status: "sending", claimed_at: Time.current)
    expect do
      described_class.call(sync: sync.reload, client: client, now: Time.current, token: 1.minute.ago)
    end.to raise_error(RegulationRndsSync::LostClaim)
    expect(delivery.reload.accepted_at).to be_nil
  end
end
