# spec/services/sncr/stock_spec.rb
require "rails_helper"

# ADR 0034 (spec §4; Desvios 4–6): estoque por prescritor e modo; o lote grava
# só números novos (Review Focus 2); o consumo é do modo corrente (Review
# Focus 4); used só com documento; voided não volta.
RSpec.describe Sncr::Stock do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:document) { raw_document!(consultation: finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))) }

  def block(first, last, quantity) = Sncr::Client::Block.new(first: first, last: last, quantity: quantity)

  it "grava o lote, o mês e o número do pedido; publica só a contagem" do
    received = described_class.record_batch!(user: doctor, kind: "rce", block: block("2610.1-41.0000001", "2610.1-41.0000010", 10),
                                             simulated: true)
    expect(received.received).to eq(10)
    expect(received.batch).to have_attributes(kind: "rce", quantity: 10, month_request: 1, month: Date.current.beginning_of_month)
    second = described_class.record_batch!(user: doctor, kind: "rce", block: block("2610.1-41.0000011", "2610.1-41.0000012", 2),
                                           simulated: true)
    expect(second.batch.month_request).to eq(2)
    expect(described_class.requests_this_month(user: doctor, kind: "rce")).to eq(2)
    expect(described_class.requests_this_month(user: doctor, kind: "ret")).to eq(0)
    event = DomainEvent.where(name: "sncr.numbers_requested").order(:created_at).last
    expect(event.payload).to eq("user_id" => doctor.id, "kind" => "rce", "count" => 2, "simulated" => true)
  end

  it "bloco com números repetidos: grava só os novos, sem erro (Review Focus 2)" do
    described_class.record_batch!(user: doctor, kind: "rce", block: block("2610.1-41.0000001", "2610.1-41.0000005", 5), simulated: true)
    other = doctor!(unit)
    received = nil
    log = capture_log do
      received = described_class.record_batch!(user: other, kind: "rce", block: block("2610.1-41.0000004", "2610.1-41.0000008", 5),
                                               simulated: true)
    end
    expect(received.received).to eq(3)
    expect(SncrNumber.where(kind: "rce").count).to eq(8)
    expect(SncrNumber.where(number: "2610.1-41.0000004").sole.user_id).to eq(doctor.id)
    expect(log).to include("2 número(s) já existente(s)")
    expect(log).not_to include("2610.1-41")
  end

  it "saldo e consumo do modo corrente; menor número primeiro; produção nunca tira simulado (Review Focus 4)" do
    sncr_stock!(doctor, kind: "rce", count: 2, simulated: true)
    described_class.record_batch!(user: doctor, kind: "rce", block: block("2610.1-41.0009001", "2610.1-41.0009001", 1), simulated: false)
    expect(described_class.summary(user: doctor, simulated: true)["rce"]).to include(free: 2, used: 0, voided: 0)
    expect(described_class.summary(user: doctor, simulated: false)["rce"]).to include(free: 1)
    expect(described_class.summary(user: doctor, simulated: true)["ret"]).to include(free: 0, requests_this_month: 0)

    ApplicationRecord.transaction do
      expect(described_class.take!(user: doctor, kind: "rce", simulated: false).number).to eq("2610.1-41.0009001")
      expect(described_class.take!(user: doctor, kind: "rce", simulated: true).number).to eq("2610.1-41.0000001")
      expect(described_class.take!(user: doctor, kind: "ret", simulated: true)).to be_nil
      expect(described_class.take!(user: doctor, kind: "rce", simulated: true, env: "production")).to be_nil
      expect(described_class.take!(user: doctor, kind: "rce", simulated: true, env: "staging").number).to eq("2610.1-41.0000001")
      expect(described_class.take!(user: doctor, kind: "rce", simulated: true, env: "test").number).to eq("2610.1-41.0000001")
      expect(described_class.take!(user: doctor!(unit), kind: "rce", simulated: true)).to be_nil # o estoque é do prescritor
    end
  end

  it "use! e void!: used com documento, voided não volta; eventos só com ids" do
    sncr_stock!(doctor, count: 1)
    number = ApplicationRecord.transaction { described_class.use!(described_class.take!(user: doctor, kind: "rce", simulated: true), document: document) }
    expect(number.reload).to have_attributes(status: "used", document_id: document.id)
    voided = described_class.void!(document: document)
    expect(voided.reload.status).to eq("voided")
    expect(described_class.void!(document: document)).to be_nil
    payloads = DomainEvent.where(name: %w[sncr.number_used sncr.number_voided]).pluck(:payload)
    expect(payloads).to all(eq("document_id" => document.id, "kind" => "rce"))
    expect(described_class.summary(user: doctor, simulated: true)["rce"]).to include(free: 0, used: 0, voided: 1)
  end

  it "rollback devolve o número (falha da emissão)" do
    sncr_stock!(doctor, count: 1)
    ApplicationRecord.transaction(requires_new: true) do
      described_class.use!(described_class.take!(user: doctor, kind: "rce", simulated: true), document: document)
      raise ActiveRecord::Rollback
    end
    expect(SncrNumber.where(user_id: doctor.id).pluck(:status)).to eq([ "free" ])
  end
end
