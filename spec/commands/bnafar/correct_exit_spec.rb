require "rails_helper"
require "webmock/rspec"

# Módulo 27b, Task 12 (contrato §3, §4; Q8, Q25; R12): a correção da saída
# externa já aceita. Vale para a saída inteira: um registro novo
# (`replaces_record_id`) por registro aceito dela, num lote `put`, até 30 dias do
# `sent_at` mais antigo (Q25). A saída sobe de versão; só a saída externa.
RSpec.describe Bnafar::CorrectExit, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:admin) { pharmacy_admin! }
  let(:today) { Time.zone.today }
  let(:fixed) { { "destination_kind" => "cnes", "destination_code" => "2384299", "reason" => "Destino corrigido após a conferência" } }

  before do
    losartana.update_columns(vmp_code: "@brasil1000")
    amoxicilina.update_columns(vmp_code: "@brasil2000")
  end

  let!(:lots) do
    [ losartana, amoxicilina ].map { |item| bnafar_complete!(stocked_lot!(central, item: item, quantity: "20"), ampp_code: "@brasil20038375080") }
  end
  let!(:external) do
    items = lots.map { |lot| { "lot_id" => lot.id, "quantity" => 3 } }
    attrs = { "exit_type" => "S-D", "destination_kind" => "cnpj", "destination_code" => "12ABC34501DE35",
              "reason" => "Doação de excedente à entidade", "items" => items }
    Pharmacy::RecordExternalExit.call(location: central, attrs: attrs, by: keeper).payload.fetch(:exit)
  end
  let(:submission) { BnafarSubmission.find_by!(reference_on: today, subject: "exit", environment: "production") }

  before { Bnafar::Build.call(reference_on: today, environment: "production", domains: [ Stock::Domain::MEDICATION ], now: Time.current) }

  def originals = submission.records.order(:created_at, :id).to_a

  def accept!(records = originals, sent_at: 29.days.ago)
    records.each_with_index do |record, index|
      record.update_columns(status: "accepted", accepted_at: sent_at + 1.hour, bnafar_code: rand(7_000..9_000_000) + index, sent_at: sent_at)
    end
  end

  def correct(record = originals.first, attrs: fixed, version: external.reload.version)
    described_class.call(record: record, attrs: attrs, expected_version: version, by: admin, now: Time.current)
  end

  it "doação de dois itens aceita há 29 dias, destino corrigido → dois registros com replaces_record_id num lote put" do
    accept!(sent_at: 29.days.ago)
    before_originals = originals

    result = correct
    expect(result).to be_ok
    news = result.payload.fetch(:records)
    expect(news.map(&:replaces_record_id)).to match_array(before_originals.map(&:id))
    expect(news).to all(have_attributes(status: "pending", subject: "exit", stock_external_exit_id: external.id, bnafar_submission_id: submission.id))
    expect(news.map(&:origin_code).uniq.size).to eq(2)
    expect(news.map(&:origin_code) & before_originals.map(&:origin_code)).to be_empty
    batch = BnafarBatch.where(operation: "put").sole
    expect(batch).to have_attributes(status: "queued", bnafar_submission_id: submission.id)
    expect(news.map(&:bnafar_batch_id).uniq).to eq([ batch.id ])
    news.each do |record|
      original = before_originals.find { |row| row.id == record.replaces_record_id }
      body = JSON.parse(record.payload)
      expect(body).to include("codigo" => original.bnafar_code)
      expect(body.fetch("caracterizacao")).to include("estabelecimentoDestino" => "2384299", "tipoSaida" => "S-D", "codigoOrigem" => record.origin_code)
      expect(body.fetch("itens").sole).to include("quantidade" => 3)
    end
    expect(external.reload).to have_attributes(version: 2, destination_kind: "cnes", destination_code: "2384299", exit_type: "S-D",
                                               reason: "Destino corrigido após a conferência")
    expect(before_originals.map { |row| row.reload.status }).to eq(%w[accepted accepted])
    expect(DomainEvent.where(name: "bnafar_record.corrected").map(&:payload))
      .to match_array(news.map { |record| { "bnafar_record_id" => record.id, "replaces_record_id" => record.replaces_record_id, "user_id" => admin.id } })
    expect(BnafarMovementLink.count).to eq(2)
  end

  it "a janela é a do sent_at mais antigo: há 31 dias → correction_window_closed; um de 29 e outro de 31 também" do
    accept!(sent_at: 31.days.ago)
    result = correct
    expect([ result.failure?, result.reason ]).to eq([ true, :correction_window_closed ])

    accept_one = originals.first
    expect(external.reload.version).to eq(1)
    expect(BnafarBatch.where(operation: "put")).to be_empty
    expect(accept_one.reload.status).to eq("accepted")
  end

  it "um registro recente e outro velho → vale o mais antigo" do
    accept!([ originals.first ], sent_at: 5.days.ago)
    accept!([ originals.last ], sent_at: 31.days.ago)

    expect(correct.reason).to eq(:correction_window_closed)
  end

  it "posição, saída que não é externa e registro não aceito → not_correctable" do
    position = bnafar_record!(bnafar_submission!(reference_on: today - 5, subject: "position", status: "finished"), status: "accepted", sent_at: 1.day.ago)
    loss = bnafar_loss!(central, lots.first, 1)
    plain = bnafar_record!(bnafar_submission!(reference_on: today - 3, subject: "exit", status: "finished"), status: "accepted", sent_at: 1.day.ago)
    BnafarMovementLink.create!(stock_movement: loss, bnafar_record: plain, kind: "exit")

    expect(correct(position).reason).to eq(:not_correctable)
    expect(correct(plain).reason).to eq(:not_correctable)
    expect(correct(originals.first).reason).to eq(:not_correctable) # ainda pending
    expect(BnafarBatch.where(operation: "put")).to be_empty
  end

  it "versão velha → external_exit_changed e nada muda" do
    accept!

    result = correct(version: 0)
    expect([ result.failure?, result.reason ]).to eq([ true, :external_exit_changed ])
    expect(external.reload.version).to eq(1)
    expect(BnafarRecord.where.not(replaces_record_id: nil)).to be_empty
  end

  it "corpo malformado → invalid_request com o path; sem versão → expected_version_required" do
    accept!

    short = correct(attrs: fixed.merge("reason" => "curto"))
    expect([ short.reason, short.details[:path] ]).to eq([ :invalid_request, "reason" ])
    unknown = correct(attrs: fixed.merge("cpf" => "1"))
    expect([ unknown.reason, unknown.details[:path] ]).to eq([ :invalid_request, "cpf" ])
    bad_code = correct(attrs: fixed.merge("destination_code" => "123"))
    expect([ bad_code.reason, bad_code.details[:path] ]).to eq([ :invalid_request, "destination_code" ])
    type = correct(attrs: fixed.merge("exit_type" => "S-PE"))
    expect([ type.reason, type.details[:path] ]).to eq([ :invalid_request, "exit_type" ])
    noop = correct(attrs: { "reason" => "Doação de excedente à entidade" })
    expect(noop.reason).to eq(:invalid_request)
    none = correct(version: nil)
    expect([ none.reason, none.details[:path] ]).to eq([ :expected_version_required, "expected_version" ])
    expect(external.reload.version).to eq(1)
  end

  it "segunda correção: a janela segue a do registro original; o já substituído não é corrigível" do
    accept!(sent_at: 20.days.ago)
    first = originals.first
    news = correct.payload.fetch(:records)
    expect(correct(first, version: 2).reason).to eq(:not_correctable) # substituído por um pendente: aguarde

    accept!(news, sent_at: 1.hour.ago) # a BNAFAR aceitou a correção
    expect(correct(first, version: 2).reason).to eq(:not_correctable) # o original foi substituído
    again = correct(news.first, attrs: fixed.merge("exit_type" => "S-E"), version: 2)
    expect(again).to be_ok
    expect(again.payload.fetch(:records).map(&:replaces_record_id)).to match_array(news.map(&:id))
    expect(external.reload).to have_attributes(version: 3, exit_type: "S-E")
  end

  it "a janela da segunda correção conta do sent_at do registro original, não do da correção" do
    accept!(sent_at: 31.days.ago)
    news = originals.map { |record| bnafar_record!(submission, status: "pending", stock_external_exit_id: external.id, replaces_record_id: record.id) }
    accept!(news, sent_at: 1.hour.ago)

    expect(correct(news.first).reason).to eq(:correction_window_closed)
  end

  describe "contra o SI-BNAFAR simulado" do
    let!(:fake) { fake_bnafar! }

    before { bnafar_on!(city, since: 10.days.ago, mock: true) }

    it "o PUT leva o codigo do registro aceito e a BNAFAR mantém o mesmo bnafar_code" do
      3.times { Bnafar::DeliverJob.perform_now }
      expect(originals.map(&:status).uniq).to eq([ "accepted" ])

      codes = originals.map(&:bnafar_code)
      news = correct.payload.fetch(:records)
      3.times { Bnafar::DeliverJob.perform_now }

      put = fake.received.find { |call| call[:method] == "PUT" }
      expect(put[:body].map { |record| record["codigo"] }).to match_array(codes)
      expect(news.map { |record| record.reload.status }).to eq(%w[accepted accepted])
      expect(news.map(&:bnafar_code)).to match_array(codes)
      expect(BnafarBatch.where(operation: "put").sole).to have_attributes(status: "finished", protocol: be_positive)
      expect(submission.reload.status).to eq("finished")
    end
  end
end
