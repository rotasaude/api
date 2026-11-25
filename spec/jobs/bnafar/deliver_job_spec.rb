require "rails_helper"
require "webmock/rspec"

# Módulo 27b, Task 11 (contrato §3; Q8, Q14, Q25; R10, R31): o envio das
# remessas montadas ao SI-BNAFAR simulado (FakeBnafar::App em processo, por
# WebMock#to_rack; nenhuma URL real). Claim com SKIP LOCKED e posse pelo
# `last_attempted_at`; POST/PUT/DELETE → `processing` com o protocolo; a consulta
# do protocolo decide aceite, aceite parcial (Q8), recusa (só códigos MSG) e a
# exclusão confirmada (Q14); backoff no transitório; credencial recusada pausa.
RSpec.describe Bnafar::DeliverJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let!(:fake) { fake_bnafar! }
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }
  let(:today) { Time.zone.today }

  before do
    bnafar_on!(city, since: 10.days.ago, mock: true)
    losartana.update_columns(vmp_code: "@brasil1000")
  end

  def run! = described_class.perform_now
  def lot!(quantity: "10", **over) = bnafar_complete!(stocked_lot!(central, item: losartana, quantity: quantity, **over), ampp_code: "@brasil20038375080")
  def build!(environment: "production") = Bnafar::Build.call(reference_on: today, environment: environment, domains: [ Stock::Domain::MEDICATION ], now: Time.current)
  def position = BnafarSubmission.find_by!(reference_on: today, subject: "position")
  def exits = BnafarSubmission.find_by!(reference_on: today, subject: "exit")
  def calls(verb, fragment) = fake.log.count { |method, path, _| method == verb && path.include?(fragment) }

  it "fluxo completo até finished com bnafar_code (posição e saída)" do
    lot = lot!
    loss = bnafar_loss!(central, lot, 2)
    build!
    3.times { run! } # envio (situação 1), consulta (2: espera), consulta (3)

    [ position, exits ].each do |submission|
      expect(submission).to have_attributes(status: "finished", finished_at: be_present, sent_at: be_present)
      batch = submission.batches.sole
      expect(batch).to have_attributes(operation: "post", status: "finished", protocol: be_positive, attempts: 1, evidence: nil)
      expect(submission.records.sole).to have_attributes(status: "accepted", bnafar_code: be_positive, accepted_at: be_present,
                                                         sent_at: be_present, rejected_items: 0, error_codes: [])
    end
    expect(exits.records.sole.movement_links.sole.stock_movement_id).to eq(loss.id)
    expect(calls("POST", "/posicao-estoque-lote")).to eq(1)
    expect(calls("GET", "/detalhar-processamento/")).to eq(4)
    expect(DomainEvent.where(name: "bnafar_submission.finished").map(&:payload))
      .to contain_exactly({ "bnafar_submission_id" => position.id }, { "bnafar_submission_id" => exits.id })
    requests = fake.log.size
    run! # nada mais a fazer
    expect(fake.log.size).to eq(requests)
  end

  it "lote RECUSA → registro rejected só com os códigos MSG, nunca o texto; evento só com ids" do
    lot!(lot_number: "RECUSA")
    build!
    3.times { run! }

    record = position.records.sole
    expect(record).to have_attributes(status: "rejected", bnafar_code: nil)
    expect(record.error_codes).to contain_exactly("MSG09", "MSG47")
    expect(record.error_codes).to all(match(Bnafar::Catalog::MSG_CODE))
    expect(BnafarRecord.where(id: record.id).pluck(Arel.sql("bnafar_records::text")).join).not_to include("Número do produto")
    expect(DomainEvent.where(name: "bnafar_record.rejected").map(&:payload))
      .to eq([ { "bnafar_record_id" => record.id, "bnafar_submission_id" => position.id } ])
    expect(position.batches.sole.status).to eq("finished")
    expect(position.status).to eq("finished")
  end

  it "posição com um item recusado → accepted, rejected_items: 1 (Q8)" do
    lot!
    lot!(lot_number: "RECUSA")
    build!
    3.times { run! }

    record = position.records.sole
    expect(record).to have_attributes(status: "accepted", bnafar_code: be_positive, rejected_items: 1, error_codes: [ "MSG09" ])
    expect(DomainEvent.where(name: "bnafar_record.rejected")).to be_empty
  end

  it "MSG15 (duplicado) conta como aceite, sem bnafar_code" do
    lot!
    build!
    run!
    allow_any_instance_of(Bnafar::Client).to receive(:detail).and_wrap_original do |original, **kwargs|
      response = original.call(**kwargs)
      next response unless response.situation.to_s.in?(%w[3 4])

      response.with(situation: "4", items: response.items.map { |item| item.merge(success: false, bnafar_code: nil) })
    end
    allow_any_instance_of(Bnafar::Client).to receive(:inconsistencies).and_return(
      Bnafar::Client::Response.new(status: :accepted, protocol: nil, situation: nil, error_codes: [ "MSG15" ], pages: 1,
                                   items: [ { origin_code: position.records.sole.origin_code, position: 0, codes: [ "MSG15" ], rejected_items: 0 } ])
    )
    2.times { run! }

    expect(position.records.sole).to have_attributes(status: "accepted", bnafar_code: nil, error_codes: [])
    expect(position.status).to eq("finished")
  end

  it "DELETE confirmado → deleted_at e bnafar_record.deleted (Q14); a remessa continua finished (R10)" do
    lot = lot!
    bnafar_loss!(central, lot, 2)
    build!
    3.times { run! }
    original = exits.records.sole
    deletion = BnafarBatch.create!(bnafar_submission: exits, operation: "delete", status: "queued", next_attempt_at: Time.current)
    original.update!(deletion_batch_id: deletion.id)

    3.times { run! }
    expect(fake.received.last).to include(method: "DELETE", query: { "codigos" => original.bnafar_code.to_s })
    expect(deletion.reload).to have_attributes(status: "finished", protocol: be_positive)
    expect(original.reload).to have_attributes(status: "accepted", deleted_at: be_present)
    expect(DomainEvent.where(name: "bnafar_record.deleted").map(&:payload))
      .to eq([ { "bnafar_record_id" => original.id, "bnafar_batch_id" => deletion.id } ])
    expect(exits.reload.status).to eq("finished")
  end

  it "DELETE recusado pelo prazo (MSG18) → lote failed com o código; o registro continua aceito, sem deleted_at" do
    lot = lot!
    bnafar_loss!(central, lot, 2)
    build!
    3.times { run! }
    original = exits.records.sole
    deletion = BnafarBatch.create!(bnafar_submission: exits, operation: "delete", status: "queued", next_attempt_at: Time.current)
    original.update!(deletion_batch_id: deletion.id)

    # Na nossa janela (sent_at de agora) a chamada sai; o relógio do fake já
    # passou dos 30 dias do POST que ele recebeu.
    fake.clock = -> { Time.now + 31.days }
    3.times { run! }
    expect(deletion.reload).to have_attributes(status: "failed", last_error: "MSG18")
    expect(original.reload.deleted_at).to be_nil
  end

  it "400 MSG62 → lote failed, registros rejected com o código, remessa failed" do
    stub_const("FakeBnafar::App::LOT_LIMIT", 0)
    lot!
    build!
    run!

    batch = position.batches.sole
    expect(batch).to have_attributes(status: "failed", last_error: "MSG62", attempts: 1, protocol: nil)
    expect(position.records.sole).to have_attributes(status: "rejected", error_codes: [ "MSG62" ])
    expect(position.status).to eq("failed")
  end

  it "timeout → lote queued com backoff de 1 min e a tentativa contada" do
    lot!
    stub_request(:post, %r{\A#{Regexp.escape(FAKE_BNAFAR_BASE)}/bnafar/produto/}).to_timeout
    freeze_time do
      build!
      run!
      expect(position.batches.sole).to have_attributes(status: "queued", attempts: 1, last_error: "bnafar_unavailable",
                                                       next_attempt_at: 1.minute.from_now)
      expect(position.records.sole).to have_attributes(status: "pending", sent_at: Time.current)
      expect(position.status).to eq("queued")
    end
  end

  it "2xx sem protocolo é transitório, não sucesso" do
    lot!
    stub_request(:post, %r{\A#{Regexp.escape(FAKE_BNAFAR_BASE)}/bnafar/produto/}).to_return(status: 200, body: "{}")
    freeze_time do
      build!
      run!
      expect(position.batches.sole).to have_attributes(status: "queued", protocol: nil, attempts: 1, next_attempt_at: 1.minute.from_now)
    end
  end

  it "dois 401 → credencial unauthorized e lote queued sem contar tentativa; o envio pausa" do
    lot!
    build!
    Bnafar::Client.for(city, environment: "production").token! # token guardado: o 401 repete uma vez com token novo
    fake.failures.push(401, nil, 401)
    run!

    expect(position.batches.sole).to have_attributes(status: "queued", attempts: 0)
    expect(IntegrationCredential.find_by!(kind: "bnafar", environment: "production").last_check_status).to eq("unauthorized")
    requests = fake.log.size
    run!
    expect(fake.log.size).to eq(requests)
  end

  it "homologação grava evidência com `jwt <TOKEN>` e o CNES da massa; o payload guardado é o original" do
    BnafarSetting.ensure_defaults!
    BnafarSetting.current.update!(environment: "homologation")
    bnafar_credential!(environment: "homologation")
    lot!
    build!(environment: "homologation")
    3.times { run! }

    submission = BnafarSubmission.find_by!(subject: "position", environment: "homologation")
    evidence = submission.batches.sole.evidence
    curls = evidence.map { |entry| entry["curl"] }
    expect(curls.join).to include("Authorization: jwt <TOKEN>", "2384043", "<USUARIO>:<SENHA>")
    expect(evidence.map { |entry| entry["status"] }).to include(200)
    expect(evidence.to_json).not_to include("usuario-bnafar", "senha-bnafar")
    expect(curls.join).not_to match(/jwt (?!<TOKEN>)/)
    expect(fake.received.first[:body].first.dig("estabelecimento", "cnes")).to eq("2384043")
    expect(JSON.parse(submission.records.sole.payload).dig("estabelecimento", "cnes")).to eq("1234567")
    expect(submission.records.sole.status).to eq("accepted")
  end

  it "produção não grava evidência" do
    lot!
    build!
    3.times { run! }
    expect(position.batches.sole.evidence).to be_nil
  end

  it "dois jobs ao mesmo tempo não enviam o mesmo lote; a execução que perdeu a posse não envia" do
    bnafar_loss!(central, lot!, 1)
    build!
    first = BnafarBatch.claim!(limit: 10, environment: "production")
    expect(first.size).to eq(2)
    expect(BnafarBatch.claim!(limit: 10, environment: "production")).to eq([])

    BnafarBatch.where(id: first.map(&:id)).update_all(updated_at: 11.minutes.ago)
    fresh = travel(1.second) do
      BnafarBatch.release_stale!(before: Bnafar::Limits::STALE_SENDING.ago)
      BnafarBatch.claim!(limit: 10, environment: "production")
    end
    expect(fresh.map(&:id)).to match_array(first.map(&:id))

    Bnafar::Delivery.new(city, environment: "production").run(first) # a execução antiga, atrasada
    expect(calls("POST", "/produto/")).to eq(0)
    Bnafar::Delivery.new(city, environment: "production").run(fresh)
    expect(calls("POST", "/produto/")).to eq(2)
  end

  it "`bnafar` desligado → nada sai; religado → sai (R31)" do
    lot!
    build!
    Platform::Features.set!(city: city, key: "bnafar", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    run!
    expect(fake.log).to be_empty
    expect(position.batches.sole.status).to eq("queued")

    Platform::Features.set!(city: city, key: "bnafar", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    run!
    expect(position.batches.sole.status).to eq("processing")
  end

  it "lote post fora da janela de reenvio (depois de R+1) não sai: failed com window_closed" do
    lot!
    build!
    travel_to((today + 2).in_time_zone.change(hour: 0, min: 3)) { run! }
    expect(fake.log).to be_empty
    expect(position.batches.sole).to have_attributes(status: "failed", last_error: "window_closed")
    expect(position.records.sole.status).to eq("pending")
  end

  it "é recorrente a cada 5 minutos e um envio por cidade de cada vez" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    expect(recurring.dig("production", "bnafar_deliver"))
      .to include("class" => "Bnafar::DeliverJob", "queue" => "default", "schedule" => "every 5 minutes")
    expect(described_class.concurrency_key).to be_present
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_duration).to eq(10.minutes)
  end
end
