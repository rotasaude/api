require "rails_helper"

# Módulo 27a (contrato H14): desativar a unidade de saúde com pendência na
# farmácia dela (transferência `sent` de ou para o local, ajuste `pending`) →
# 409 pharmacy_pending. Sem isso o recebimento ficaria preso em
# location_inactive, porque Ledger.lock_location! também trava a unidade.
RSpec.describe "Unidades de saúde — pendência da farmácia (H14)", type: :request do
  let!(:city) { pharmacy_city! }
  let(:admin) { pharmacy_admin! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let(:location) { unit_location!(unit) }
  let(:lot) { stocked_lot!(central_location!, item: losartana, quantity: "30") }

  def body = JSON.parse(response.body)
  def deactivate! = json_post("/attendance/units/#{unit.id}/deactivate")

  def sent_transfer!(from:, to:)
    transfer = StockTransfer.create!(from_location: from, to_location: to, sent_by_user: admin, status: "sent", sent_at: Time.current)
    StockTransferItem.create!(stock_transfer: transfer, stock_lot: lot, quantity_sent: 5)
    transfer
  end

  def pending_adjustment!
    StockAdjustment.create!(stock_location: location, stock_lot: lot, kind: "adjustment", status: "pending", quantity: 5,
                            counted_quantity: 5, balance_at_request: 0, reason: "Contagem do inventário de outubro",
                            requested_by_user: admin)
  end

  before { sign_in_as(admin) }

  it "transferência sent PARA a farmácia → 409 pharmacy_pending e a unidade segue ativa; recebida, desativa" do
    transfer = sent_transfer!(from: central_location!, to: location)

    deactivate!
    expect([ response.status, body ]).to eq([ 409, { "error" => "pharmacy_pending" } ])
    expect(unit.reload.active).to be(true)

    transfer.update!(status: "received", received_at: Time.current, received_by_user: admin)
    deactivate!
    expect(response).to have_http_status(:ok)
    expect(body["unit"]["active"]).to be(false)
    expect(unit.reload.active).to be(false)
  end

  # Pela API a origem é sempre o central (SendTransfer recusa outra); o banco
  # aceita a linha, e a regra compartilhada cobre os dois lados.
  it "transferência sent DA farmácia (origem, linha crua) → 409 pharmacy_pending" do
    other = unit_location!(create_unit("UBS Vizinha"))
    sent_transfer!(from: location, to: other)

    deactivate!
    expect([ response.status, body ]).to eq([ 409, { "error" => "pharmacy_pending" } ])
    expect(unit.reload.active).to be(true)
  end

  it "ajuste pending da farmácia → 409 pharmacy_pending; decidido, desativa" do
    adjustment = pending_adjustment!

    deactivate!
    expect([ response.status, body ]).to eq([ 409, { "error" => "pharmacy_pending" } ])
    expect(unit.reload.active).to be(true)

    adjustment.update!(status: "rejected", decided_by_user: pharmacy_staff!(location, "stock_keeper"), decided_at: Time.current,
                       decision_reason: "Contagem errada")
    deactivate!
    expect(response).to have_http_status(:ok)
    expect(unit.reload.active).to be(false)
  end

  it "pendência de OUTRA farmácia não prende a unidade" do
    location
    sent_transfer!(from: central_location!, to: unit_location!(create_unit("UBS Vizinha")))

    deactivate!
    expect(response).to have_http_status(:ok)
    expect(unit.reload.active).to be(false)
  end

  it "unidade sem farmácia desativa normalmente" do
    deactivate!
    expect(response).to have_http_status(:ok)
    expect(unit.reload.active).to be(false)
  end

  it "com o interruptor pharmacy desligado o 09 se comporta como antes: desativa" do
    sent_transfer!(from: central_location!, to: location)
    Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)

    deactivate!
    expect(response).to have_http_status(:ok)
    expect(unit.reload.active).to be(false)
  end

  it "a conferência é só leitura sob a trava da unidade: nenhum lote é travado depois dela" do
    sent_transfer!(from: central_location!, to: location)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      deactivate!
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    expect(response).to have_http_status(:conflict)
    unit_lock = statements.index { |sql| sql.include?('FROM "health_units"') && sql.include?("FOR UPDATE") }
    expect(unit_lock).to be_present
    expect(statements[unit_lock..].grep(/FROM "stock_lots"/).grep(/FOR (UPDATE|SHARE)/)).to be_empty
  end

  # Revisão final: o interruptor (Platform::Features, outra conexão, credenciais
  # e perfil) é lido ANTES do FOR UPDATE da unidade. Um StatementInvalid
  # resgatado lá dentro abortaria a transação da unidade e o deactivate viraria
  # 500 em qualquer cidade.
  it "o interruptor pharmacy é lido antes da trava da unidade, nunca com ela presa" do
    sent_transfer!(from: central_location!, to: location)
    statements = []
    gate_at = []
    allow(Pharmacy::Gate).to receive(:usable?).and_wrap_original do |original, *args|
      gate_at << statements.size
      original.call(*args)
    end
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      deactivate!
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    expect([ response.status, body ]).to eq([ 409, { "error" => "pharmacy_pending" } ])
    unit_lock = statements.index { |sql| sql.include?('FROM "health_units"') && sql.include?("FOR UPDATE") }
    expect(unit_lock).to be_present
    expect(gate_at).to be_present
    expect(gate_at).to all(be <= unit_lock)
  end
end
