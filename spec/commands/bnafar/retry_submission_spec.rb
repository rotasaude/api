require "rails_helper"
require "webmock/rspec"

# Módulo 27b, Task 12 (contrato §3; Q25; R10, R11, R12; Review Focus 3): o
# reenvio dos registros recusados, só em R+1. Remonta pelo Build (mesmo
# `origin_code`, dado de hoje e a fotografia de R) num lote `post` novo; a
# remessa fechada volta a `queued` só com esse lote (R10) e o registro
# `rejected` vira `pending` trocando payload, lote e códigos juntos (R11).
RSpec.describe Bnafar::RetrySubmission, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let!(:fake) { fake_bnafar! }
  let(:med) { Stock::Domain::MEDICATION }
  let(:today) { Time.zone.today }
  let(:yesterday_at) { (today - 1).in_time_zone.change(hour: 8) }
  # O simulado recusa o CNES 0000000 (MSG06): o dado errado que se corrige depois.
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "0000000") } }
  let(:admin) { pharmacy_admin! }

  before do
    bnafar_on!(city, since: 10.days.ago, mock: true)
    losartana.update_columns(vmp_code: "@brasil1000")
  end

  let!(:lot) do
    travel_to(yesterday_at) { bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "10"), ampp_code: "@brasil20038375080") }
  end

  def deliver! = 3.times { Bnafar::DeliverJob.perform_now }
  def submission(subject = "position") = BnafarSubmission.find_by!(reference_on: today - 1, subject: subject, environment: "production")
  def retry!(subject = "position", on: today) = described_class.call(submission: submission(subject), by: admin, today: on, domains: [ med ])
  def build_and_send!
    Bnafar::Build.call(reference_on: today - 1, environment: "production", domains: [ med ], now: Time.current)
    deliver!
  end

  describe "posição recusada pelo CNES do local" do
    before { build_and_send! }

    let(:record) { submission.records.sole }

    it "em R+1, o lote completado é reenviado com o mesmo origin_code, o CNES novo e o dado de hoje" do
      expect(record).to have_attributes(status: "rejected", error_codes: [ "MSG06" ])
      origin = record.origin_code
      central.update_columns(cnes: "1234567")
      lot.update_columns(unit_price_cents: 2500, bnafar_version: lot.reload.bnafar_version + 1)

      result = retry!
      expect(result).to be_ok
      batch = result.payload[:batch]
      expect(batch).to have_attributes(operation: "post", status: "queued", bnafar_submission_id: submission.id)
      expect(record.reload).to have_attributes(status: "pending", origin_code: origin, bnafar_batch_id: batch.id, error_codes: [], rejected_items: 0)
      body = JSON.parse(record.payload)
      expect(body.fetch("estabelecimento")).to include("cnes" => "1234567")
      expect(body.dig("caracterizacao", "codigoOrigem")).to eq(origin)
      expect(body.dig("caracterizacao", "dataPosicaoEstoque")).to eq((today - 1).iso8601)
      expect(body.fetch("itens").sole).to include("codigoOrigem" => lot.id, "valorUnitario" => 25.0, "quantidade" => 10)
      expect(submission).to have_attributes(status: "queued")
      expect(DomainEvent.where(name: "bnafar_submission.queued").map(&:payload).last).to eq({ "bnafar_submission_id" => submission.id })

      deliver!
      expect(record.reload).to have_attributes(status: "accepted", bnafar_code: be_positive, origin_code: origin)
      expect(submission.reload).to have_attributes(status: "finished")
      expect(submission.batches.pluck(:operation, :status)).to contain_exactly(%w[post finished], %w[post finished])
      expect(fake.log.count { |method, path, _| method == "POST" && path.include?("/posicao-estoque-lote") }).to eq(2)
    end

    it "em R+2 → retry_window_closed e nada muda" do
      central.update_columns(cnes: "1234567")

      result = retry!("position", on: today + 1)
      expect([ result.failure?, result.reason ]).to eq([ true, :retry_window_closed ])
      expect(record.reload).to have_attributes(status: "rejected", error_codes: [ "MSG06" ])
      expect(submission.batches.count).to eq(1)
    end

    it "remessa já lost → retry_window_closed" do
      submission.update!(status: "lost")

      expect(retry!.reason).to eq(:retry_window_closed)
    end

    it "o dado ainda com pendência (sem CNES) fica de fora → nothing_to_retry" do
      central.update_columns(cnes: nil)

      result = retry!
      expect([ result.failure?, result.reason ]).to eq([ true, :nothing_to_retry ])
      expect(record.reload.status).to eq("rejected")
      expect(submission.batches.count).to eq(1)
    end
  end

  it "sem registro recusado → nothing_to_retry" do
    central.update_columns(cnes: "1234567")
    build_and_send!
    expect(submission.records.sole.status).to eq("accepted")

    expect(retry!.reason).to eq(:nothing_to_retry)
    expect(submission.reload.batches.count).to eq(1)
  end

  it "saída recusada volta com o mesmo origin_code e o tipo de saída" do
    movement = travel_to((today - 1).in_time_zone.change(hour: 9)) { bnafar_loss!(central, lot, 2) }
    build_and_send!
    record = submission("exit").records.sole
    expect(record.status).to eq("rejected")
    origin = record.origin_code
    central.update_columns(cnes: "1234567")

    expect(retry!("exit")).to be_ok
    body = JSON.parse(record.reload.payload)
    expect(record).to have_attributes(status: "pending", origin_code: origin)
    expect(body.dig("caracterizacao", "tipoSaida")).to eq("S-PE")
    expect(body.dig("caracterizacao", "codigoOrigem")).to eq(origin)
    expect(body.fetch("itens").sole).to include("codigoOrigem" => movement.id, "quantidade" => 2)
    deliver!
    expect(record.reload).to have_attributes(status: "accepted", bnafar_code: be_positive)
    expect(record.movement_links.pluck(:kind)).to eq([ "exit" ])
  end

  describe "item com mais de 20 lotes (várias partes)" do
    let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }
    let(:ampp) { "@brasil20038375080" }

    # A00 fica incompleto (fora da remessa de R) e ordena antes de todos.
    let!(:late_lot) do
      travel_to(yesterday_at) { stocked_lot!(central, item: losartana, quantity: "10", lot_number: "A00") }
    end
    let!(:lots) do
      travel_to(yesterday_at) do
        (1..25).map { |n| bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "10", lot_number: format("A%02d", n)), ampp_code: ampp) }
      end
    end

    before do
      Bnafar::Build.call(reference_on: today - 1, environment: "production", domains: [ med ], now: Time.current)
    end

    def parts = submission.records.to_a.sort_by { |record| JSON.parse(record.payload).fetch("itens").size }.reverse
    def lot_ids(record) = JSON.parse(record.payload).fetch("itens").map { |item| item["codigoOrigem"] }

    it "completar em R+1 um lote que ordena antes não desloca as fatias: o reenvio leva os 20 lotes que o registro levou" do
      big, small = parts
      expect(lot_ids(big)).to match_array(lots.first(20).map(&:id))
      carried = lot_ids(big)
      big.update_columns(status: "rejected", error_codes: [ "MSG06" ])
      small.update_columns(status: "accepted", accepted_at: Time.current, bnafar_code: 77, sent_at: Time.current)
      small_payload = small.payload
      bnafar_complete!(late_lot, ampp_code: ampp) # A00 passa a ter dados e ordenaria antes de A01

      result = retry!
      expect(result).to be_ok
      expect(big.reload).to have_attributes(status: "pending", origin_code: big.origin_code)
      expect(lot_ids(big)).to match_array(carried)
      expect(lot_ids(big)).not_to include(late_lot.id)
      expect(small.reload).to have_attributes(status: "accepted", bnafar_code: 77)
      expect(small.payload).to eq(small_payload)
    end

    it "lote que ganhou pendência sai do registro; nada mais entra" do
      big, = parts
      big.update_columns(status: "rejected", error_codes: [ "MSG06" ])
      gone = lots.first
      allow(Bnafar::LotFields).to receive(:missing).and_wrap_original do |original, lot, **kwargs|
        lot.id == gone.id ? [ "unit_price_cents" ] : original.call(lot, **kwargs)
      end

      expect(retry!).to be_ok
      expect(lot_ids(big.reload)).to match_array(lots.first(20).map(&:id) - [ gone.id ])
    end

    it "payload já purgado → o registro fica de fora (nothing_to_retry)" do
      big, = parts
      big.update_columns(status: "rejected", error_codes: [ "MSG06" ], payload: nil)

      expect(retry!.reason).to eq(:nothing_to_retry)
    end
  end
end
