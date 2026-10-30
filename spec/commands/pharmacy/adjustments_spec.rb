require "rails_helper"

# Módulo 27a, Task 7 (ADR 0045; plano do api, Desvio 7; F-27.4; emendas H4/H8/
# H12): ajuste de contagem, perda e vencimento, com segundo responsável acima do
# limite. Só o ajuste de contagem acima de `adjustment_approval_percent` do saldo
# (saldo zero conta como acima) vai para `pending`; perda e vencimento são
# aplicados na hora. Todas as recusas voltam de uma vez (`problems`), inclusive
# as de saldo.
RSpec.describe "Ajustes, perdas e vencimentos do estoque" do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:paracetamol) { catalog_item(267_778) }
  let(:author) { pharmacy_staff!(central, "stock_keeper") }
  let(:other) { pharmacy_staff!(central, "stock_keeper") }
  let(:pharmacist) { pharmacy_staff!(central, "pharmacist") }
  let(:today) { Time.zone.today }
  let(:now) { Time.zone.local(today.year, today.month, today.day, 10, 0) }
  let(:reason) { "Contagem do inventário de outubro" }
  let(:settings) { Pharmacy::Settings.current }
  let!(:lot) { stocked_lot!(central, item: paracetamol, quantity: "100", lot_number: "AJ-A") }

  def request!(kind: "adjustment", counted: nil, quantity: nil, lot_record: lot, by: author, why: reason, location: central, with: settings, at: now)
    Pharmacy::RequestAdjustment.call(location: location, lot: lot_record, kind: kind, counted_quantity: counted, quantity: quantity,
                                     reason: why, by: by, settings: with, now: at)
  end

  def counted!(value, **opts) = request!(counted: value, **opts)

  def pending!(counted = "85")
    result = counted!(counted)
    raise result.inspect unless result.ok? && result.payload.fetch(:adjustment).status == "pending"

    result.payload.fetch(:adjustment)
  end

  def decide!(adjustment, decision = "approve", by: other, why: nil, at: now + 1.hour)
    Pharmacy::DecideAdjustment.call(adjustment: adjustment, decision: decision, reason: why, by: by, now: at)
  end

  def balance(location = central, lot_record = lot) = Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot_record.id)
  def movements(kind) = StockMovement.where(stock_lot_id: lot.id, kind: kind).order(:recorded_at, :id)
  def problems_of(result) = result.details[:problems]
  def events(name) = DomainEvent.where(name: name).order(:occurred_at, :id).map(&:payload)

  describe "RequestAdjustment — contagem" do
    it "saldo 100, contado \"95\" (5%): applied, saldo 95 e um movimento adjustment de -5" do
      result = counted!("95")
      expect(result).to be_ok
      adjustment = result.payload.fetch(:adjustment)
      expect(adjustment).to have_attributes(kind: "adjustment", status: "applied", quantity: -5, counted_quantity: 95, balance_at_request: 100,
                                            requested_by_user_id: author.id, decided_by_user_id: nil)
      expect(adjustment.reason).to eq(reason)
      expect(balance).to eq(95)
      movement = movements("adjustment").sole
      expect(movement).to have_attributes(quantity: -5, stock_adjustment_id: adjustment.id, recorded_by_user_id: author.id, stock_location_id: central.id)
      expect(result.payload.fetch(:movement)).to eq(movement)
    end

    it "contado maior que o saldo, dentro do limite: applied com movimento positivo" do
      result = counted!("105")
      expect(result.payload.fetch(:adjustment)).to have_attributes(status: "applied", quantity: 5)
      expect(balance).to eq(105)
    end

    it "contado \"85\" (15%): pending, sem movimento, saldo 100, delta guardado" do
      result = counted!("85")
      expect(result).to be_ok
      adjustment = result.payload.fetch(:adjustment)
      expect(adjustment).to have_attributes(status: "pending", quantity: -15, counted_quantity: 85, balance_at_request: 100)
      expect(result.payload.fetch(:movement)).to be_nil
      expect(balance).to eq(100)
      expect(movements("adjustment")).to be_empty
    end

    it "exatamente no limite de 10% (contado \"90\"): applied; um centavo além (\"89.99\"): pending" do
      expect(counted!("89.99").payload.fetch(:adjustment).status).to eq("pending")
      expect(counted!("90").payload.fetch(:adjustment).status).to eq("applied")
      expect(balance).to eq(90)
    end

    it "saldo 0 e contado \"3\": pending (saldo zero conta como acima do limite)" do
      empty = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "AJ-ZERO")
      expect(request!(kind: "loss", quantity: "10", lot_record: empty)).to be_ok
      expect(balance(central, empty)).to eq(0)
      result = counted!("3", lot_record: empty)
      expect(result.payload.fetch(:adjustment)).to have_attributes(status: "pending", quantity: 3, balance_at_request: 0)
      expect(balance(central, empty)).to eq(0)
    end

    it "contado igual ao saldo: no_difference com path e problems; nada gravado" do
      result = counted!("100")
      expect([ result.reason, result.details[:path], problems_of(result) ]).to eq([ :no_difference, "counted_quantity",
                                                                                 [ { path: "counted_quantity", error: "no_difference" } ] ])
      expect(StockAdjustment.count).to eq(0)
      expect(events("stock_adjustment.recorded")).to be_empty
    end

    it "contado \"0\" é uma contagem válida (zera o lote): 100% do saldo, pending" do
      result = counted!("0")
      expect(result.payload.fetch(:adjustment)).to have_attributes(status: "pending", quantity: -100, counted_quantity: 0)
    end

    it "com adjustment_approval_percent 0 todo ajuste é pending, até o menor" do
      PharmacySetting.current.update!(adjustment_approval_percent: 0)
      result = counted!("99.99", with: Pharmacy::Settings.current)
      expect(result.payload.fetch(:adjustment).status).to eq("pending")
    end

    it "com adjustment_approval_percent 100 só o saldo zero vai para aprovação" do
      PharmacySetting.current.update!(adjustment_approval_percent: 100)
      expect(counted!("1", with: Pharmacy::Settings.current).payload.fetch(:adjustment).status).to eq("applied")
      expect(counted!("2", with: Pharmacy::Settings.current).payload.fetch(:adjustment).status).to eq("applied")
    end

    it "farmacêutico também ajusta (a comando não exige papel: o controlador confere); o pedido guarda quem pediu" do
      result = counted!("95", by: pharmacist)
      expect(result.payload.fetch(:adjustment).requested_by_user_id).to eq(pharmacist.id)
    end

    it "counted_quantity é SALDO: aceita até numeric(14,2); o delta passa de 99999.99 → invalid_quantity" do
      expect(counted!("100099.99").payload.fetch(:adjustment)).to have_attributes(status: "pending", quantity: BigDecimal("99999.99"))

      %w[100100 200000.00 99999999999.99].each do |value|
        result = counted!(value)
        expect([ result.reason, result.details[:path], problems_of(result) ]).to eq([ :invalid_quantity, "counted_quantity",
                                                                                    [ { path: "counted_quantity", error: "invalid_quantity" } ] ])
      end
      # 13 inteiros não cabem em numeric(14,2).
      expect(counted!("1000000000000").reason).to eq(:invalid_quantity)
      expect(StockAdjustment.where(counted_quantity: 100_099.99).count).to eq(1)
    end

    it "saldo de lote acima de 99999.99 (várias notas) também se ajusta: o teto é do delta, não do saldo" do
      big = stocked_lot!(central, item: paracetamol, quantity: "99999", lot_number: "AJ-BIG")
      stocked_lot!(central, item: paracetamol, quantity: "99999", lot_number: "AJ-BIG")
      expect(balance(central, big)).to eq(199_998)
      result = counted!("199990", lot_record: big)
      expect(result.payload.fetch(:adjustment)).to have_attributes(status: "applied", quantity: -8, balance_at_request: 199_998, counted_quantity: 199_990)
    end

    it "counted_quantity ausente, número JSON, vírgula, 3 casas, sinal → invalid_quantity" do
      [ nil, 95, 95.5, "95,5", "95.555", "-5", " 95", "" ].each do |value|
        result = counted!(value)
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_quantity, "counted_quantity" ]), "esperava recusar #{value.inspect}"
      end
      expect(StockAdjustment.count).to eq(0)
    end
  end

  describe "RequestAdjustment — perda e vencimento" do
    it "loss: aplicada na hora (nunca pending), saldo cai, movimento loss e efeito negativo" do
      result = request!(kind: "loss", quantity: "40")
      adjustment = result.payload.fetch(:adjustment)
      expect(adjustment).to have_attributes(kind: "loss", status: "applied", quantity: -40, counted_quantity: nil, balance_at_request: 100)
      expect(balance).to eq(60)
      expect(movements("loss").sole).to have_attributes(quantity: -40, stock_adjustment_id: adjustment.id)
    end

    it "loss de 100% do saldo continua aplicada na hora" do
      expect(request!(kind: "loss", quantity: "100").payload.fetch(:adjustment).status).to eq("applied")
      expect(balance).to eq(0)
    end

    it "loss de \"200\" com saldo 100 → insufficient_balance (path quantity); nada gravado" do
      result = request!(kind: "loss", quantity: "200")
      expect([ result.reason, result.details[:path], problems_of(result) ]).to eq([ :insufficient_balance, "quantity",
                                                                                 [ { path: "quantity", error: "insufficient_balance" } ] ])
      expect([ StockAdjustment.count, movements("loss").count, balance ]).to eq([ 0, 0, 100 ])
    end

    it "expiry de lote não vencido → lot_not_expired; loss de lote vencido → lot_expired" do
      result = request!(kind: "expiry", quantity: "10")
      expect([ result.reason, result.details[:path] ]).to eq([ :lot_not_expired, "lot_id" ])
      expired = stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "AJ-OLD", expires_on: today - 3)
      result = request!(kind: "loss", quantity: "10", lot_record: expired)
      expect([ result.reason, result.details[:path] ]).to eq([ :lot_expired, "lot_id" ])
      expect([ StockAdjustment.count, balance(central, expired) ]).to eq([ 0, 50 ])
    end

    it "expiry de lote vencido: aplicada na hora, movimento expiry" do
      expired = stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "AJ-OLD2", expires_on: today - 1)
      result = request!(kind: "expiry", quantity: "50", lot_record: expired)
      expect(result.payload.fetch(:adjustment)).to have_attributes(kind: "expiry", status: "applied", quantity: -50)
      expect(StockMovement.where(stock_lot_id: expired.id, kind: "expiry").sole.quantity).to eq(-50)
      expect(balance(central, expired)).to eq(0)
    end

    it "o dia da validade ainda vale: perda é aceita e vencimento é recusado; no dia seguinte, o inverso" do
      lot_today = stocked_lot!(central, item: paracetamol, quantity: "20", lot_number: "AJ-DAY", expires_on: today)
      expect(request!(kind: "loss", quantity: "5", lot_record: lot_today)).to be_ok
      expect(request!(kind: "expiry", quantity: "5", lot_record: lot_today).reason).to eq(:lot_not_expired)

      tomorrow = now + 1.day
      expect(request!(kind: "expiry", quantity: "5", lot_record: lot_today, at: tomorrow)).to be_ok
      expect(request!(kind: "loss", quantity: "5", lot_record: lot_today, at: tomorrow).reason).to eq(:lot_expired)
    end

    it "quantity de perda mantém o teto de 99999.99 e as regras de quantidade" do
      [ nil, 5, "5,5", "0", "0.00", "-1", "100000", "1.234", "" ].each do |value|
        result = request!(kind: "loss", quantity: value)
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_quantity, "quantity" ]), "esperava recusar #{value.inspect}"
      end
    end
  end

  describe "RequestAdjustment — recusas juntas (H8/H12)" do
    it "lote vencido em perda, quantidade inválida e motivo curto: três problemas na ordem dos campos" do
      expired = stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "AJ-OLD3", expires_on: today - 2)
      result = request!(kind: "loss", quantity: "abc", lot_record: expired, why: "curto")
      expect(problems_of(result)).to eq([ { path: "lot_id", error: "lot_expired" }, { path: "quantity", error: "invalid_quantity" },
                                          { path: "reason", error: "invalid_reason" } ])
      expect([ result.reason, result.details[:path] ]).to eq([ :lot_expired, "lot_id" ])
    end

    it "saldo insuficiente junto do motivo curto (a recusa de saldo apurada sem trava entra)" do
      result = request!(kind: "loss", quantity: "200", why: "curto")
      expect(problems_of(result)).to eq([ { path: "quantity", error: "insufficient_balance" }, { path: "reason", error: "invalid_reason" } ])
    end

    it "no_difference junto do motivo ausente" do
      result = counted!("100", why: nil)
      expect(problems_of(result)).to eq([ { path: "counted_quantity", error: "no_difference" }, { path: "reason", error: "invalid_reason" } ])
    end

    it "lote inexistente (nil), kind inválido e motivo longo demais" do
      result = request!(kind: "refund", lot_record: nil, quantity: "5", why: "x" * 501)
      expect(problems_of(result)).to eq([ { path: "lot_id", error: "invalid_request" }, { path: "kind", error: "invalid_request" },
                                          { path: "reason", error: "invalid_reason" } ])
    end

    it "motivo de 9 caracteres → invalid_reason; de 10 a 500, aceito (aparado)" do
      result = counted!("95", why: "123456789")
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_reason, "reason" ])
      expect(counted!("95", why: "  1234567890  ").payload.fetch(:adjustment).reason).to eq("1234567890")
      expect(counted!("94", why: "x" * 500)).to be_ok
    end

    it "local inativo → location_inactive, sozinho, sem gravar" do
      central.update!(active: false)
      result = counted!("95")
      expect([ result.reason, result.details ]).to eq([ :location_inactive, { path: "location_id" } ])
      expect(StockAdjustment.count).to eq(0)
    end
  end

  describe "DecideAdjustment" do
    it "aprovado por outro responsável: approved, saldo 85, movimento adjustment de -15 e quem decidiu" do
      adjustment = pending!
      result = decide!(adjustment, why: "Conferi a contagem no armário")
      expect(result).to be_ok
      decided = result.payload.fetch(:adjustment)
      expect(decided).to have_attributes(status: "approved", decided_by_user_id: other.id, decision_reason: "Conferi a contagem no armário")
      expect(decided.decided_at).to be_within(1.second).of(now + 1.hour)
      expect(balance).to eq(85)
      expect(movements("adjustment").sole).to have_attributes(quantity: -15, stock_adjustment_id: adjustment.id, recorded_by_user_id: other.id)
      expect(result.payload.fetch(:movement)).to be_a(StockMovement)
    end

    it "o farmacêutico do local também aprova; o motivo da aprovação é opcional" do
      adjustment = pending!
      result = decide!(adjustment, by: pharmacist)
      expect(result.payload.fetch(:adjustment)).to have_attributes(status: "approved", decision_reason: nil)
    end

    it "pelo próprio autor → same_user, sozinho; continua pending" do
      adjustment = pending!
      result = decide!(adjustment, by: author)
      expect([ result.reason, result.details ]).to eq([ :same_user, {} ])
      expect(adjustment.reload.status).to eq("pending")
      expect(balance).to eq(100)
    end

    it "quem não é stock_keeper nem pharmacist do local → missing_role (auxiliar, almoxarife de outro local, sem papel)" do
      adjustment = pending!
      farmacia = unit_location!
      [ pharmacy_staff!(central, "pharmacy_assistant"), pharmacy_staff!(farmacia, "stock_keeper"), staff_with("sem-papel@cidade.gov.br") ].each do |user|
        result = decide!(adjustment, by: user)
        expect([ result.reason, result.details ]).to eq([ :missing_role, {} ])
      end
      expect(adjustment.reload.status).to eq("pending")
    end

    it "papel só pelo vínculo (Membership revogada) → missing_role" do
      adjustment = pending!
      other.memberships.find_by!(role: "stock_keeper").revoke!
      expect(decide!(adjustment).reason).to eq(:missing_role)
    end

    it "aprovar duas vezes → not_pending; saldo muda uma vez só" do
      adjustment = pending!
      expect(decide!(adjustment)).to be_ok
      result = decide!(adjustment, by: pharmacist)
      expect([ result.reason, result.details ]).to eq([ :not_pending, {} ])
      expect(balance).to eq(85)
      expect(movements("adjustment").count).to eq(1)
    end

    it "decidir um ajuste já aplicado ou rejeitado → not_pending" do
      applied = counted!("95").payload.fetch(:adjustment)
      expect(decide!(applied).reason).to eq(:not_pending)
      rejected = pending!
      decide!(rejected, "reject", why: "Contagem refeita, valor estava certo")
      expect(decide!(rejected).reason).to eq(:not_pending)
    end

    it "saem 90 entre o pedido e a aprovação: aprovar → insufficient_balance (422 com problems) e o ajuste continua pending" do
      adjustment = pending!("85") # delta guardado: -15
      expect(request!(kind: "loss", quantity: "90", by: pharmacist)).to be_ok
      expect(balance).to eq(10)

      result = decide!(adjustment)
      expect([ result.reason, result.details[:path], problems_of(result) ]).to eq([ :insufficient_balance, "id",
                                                                                 [ { path: "id", error: "insufficient_balance" } ] ])
      expect(adjustment.reload).to have_attributes(status: "pending", decided_by_user_id: nil, decided_at: nil)
      expect(balance).to eq(10)
      expect(movements("adjustment")).to be_empty
      expect(events("stock_adjustment.approved")).to be_empty
    end

    it "aprova o DELTA guardado sobre o saldo atual, não a contagem: depois de entrarem 50, 100 - 15 + 50 = 135" do
      adjustment = pending!("85")
      stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "AJ-A")
      expect(balance).to eq(150)
      expect(decide!(adjustment)).to be_ok
      expect(balance).to eq(135)
    end

    it "rejeitar exige motivo de 10 a 500 (reason_required, path reason); rejeitar sem movimento e com o motivo gravado" do
      adjustment = pending!
      [ nil, "", "curto", "x" * 9, 5 ].each do |value|
        result = decide!(adjustment, "reject", why: value)
        expect([ result.reason, result.details[:path], problems_of(result) ]).to eq([ :reason_required, "reason",
                                                                                   [ { path: "reason", error: "reason_required" } ] ])
      end
      expect(adjustment.reload.status).to eq("pending")

      result = decide!(adjustment, "reject", why: "Contagem refeita, o saldo estava certo")
      expect(result.payload.fetch(:adjustment)).to have_attributes(status: "rejected", decided_by_user_id: other.id,
                                                                   decision_reason: "Contagem refeita, o saldo estava certo")
      expect(result.payload.fetch(:movement)).to be_nil
      expect([ balance, movements("adjustment").count ]).to eq([ 100, 0 ])
    end

    it "motivo opcional da aprovação, quando vem, precisa ter de 10 a 500 caracteres (invalid_reason)" do
      adjustment = pending!
      result = decide!(adjustment, why: "curto")
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_reason, "reason" ])
      expect(adjustment.reload.status).to eq("pending")
    end

    it "decisão fora de approve/reject é erro de programação" do
      expect { decide!(pending!, "cancel") }.to raise_error(ArgumentError)
    end
  end

  describe "eventos, logs e dados sensíveis" do
    it "stock_adjustment.recorded leva só ids e o booleano pending; approved e rejected, só ids" do
      applied = counted!("95").payload.fetch(:adjustment)
      pending = pending!("70")
      decide!(pending)
      rejected = pending!("30")
      decide!(rejected, "reject", why: "Contagem refeita, o saldo estava certo")

      expect(events("stock_adjustment.recorded").first(2)).to eq([ { "stock_adjustment_id" => applied.id, "user_id" => author.id, "pending" => false },
                                                                     { "stock_adjustment_id" => pending.id, "user_id" => author.id, "pending" => true } ])
      expect(events("stock_adjustment.approved")).to eq([ { "stock_adjustment_id" => pending.id, "user_id" => other.id } ])
      expect(events("stock_adjustment.rejected")).to eq([ { "stock_adjustment_id" => rejected.id, "user_id" => other.id } ])
    end

    it "o motivo não sai em inspect, to_s nem as_json do ajuste (modelo da Task 2) e fica cifrado no banco" do
      adjustment = pending!
      expect(adjustment.inspect + adjustment.to_s + adjustment.as_json.to_s).not_to include(reason)
      raw = ApplicationRecord.connection.select_value("SELECT reason FROM stock_adjustments WHERE id = '#{adjustment.id}'")
      expect(raw).not_to include(reason)
    end
  end
end
