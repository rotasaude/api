require "rails_helper"

# Módulo 27a, Task 11 (ADR 0045; contrato §7, H3, H6, H8, H12): a dispensação
# pela receita do 19c EMITIDA pelo caminho real (ClinicalDocuments::Issue numa
# consulta finalizada) e pela receita externa, e a devolução. Saldo pela soma
# por lote; retenção do controlado e do antimicrobiano; uso contínuo; recusas
# todas de uma vez, inclusive as apuradas sob trava; 403 de papel sozinho.
RSpec.describe Pharmacy::Dispense do
  include ActiveSupport::Testing::TimeHelpers

  before do
    pharmacy_city!
    controlled_city!(mock: true)
    ciap2_release!
    cid10_release!
    sigtap_release!
    city_profile!
  end

  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:farmacia) { unit_location!(unit) }
  let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }
  let(:assistant) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:doctor) { doctor!(unit) }
  let(:settings) { Pharmacy::Settings.current }
  let(:today) { Time.zone.today }

  def signer! = signer_doctor!(unit).tap { |user| prescriber_contact!(user) && linked_certificate!(user) }

  def consultation!(by = doctor, n = registry_seq!)
    finalized_consultation!(unit: unit, doctor: by, citizen: verified_citizen!(n % 30 + 1, full_name: "Paciente da Farmácia #{n}"))
  end

  def rx_line(catalog, **over)
    { "catalog_item" => { "id" => catalog.id }, "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
      "dosage_instructions" => "1 comprimido ao dia", "duration_days" => 30 }.merge(over.transform_keys(&:to_s))
  end

  def issue!(items, by: doctor, extra: {})
    result = ClinicalDocuments::Issue.call(kind: "prescription", by: by, consultation: consultation!(by), content: { "items" => items }.merge(extra))
    raise "emissão recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:document)
  end

  def item_of(document, position = 1) = document.prescription_items.find_by!(position: position).id
  def find(record, kind = "digital") = Pharmacy::Prescription.find(kind: kind, id: record.id, settings: settings)

  def dispense(record, lines, by: pharmacist, role: "pharmacist", retention: nil, kind: "digital", prescription: nil, now: Time.current)
    prescription ||= find(record, kind)
    catalog = Pharmacy::Json.catalog_for(prescription.items.filter_map(&:catalog_item_id) + lines.filter_map { |line| line["catalog_item_id"] })
    described_class.call(location: farmacia, prescription: prescription, items: lines, retention: retention, by: by, role: role, catalog: catalog,
                         settings: settings, now: now)
  end

  def line(item_id, lot, quantity = "30", **over) = { "prescription_item_id" => item_id, "lot_id" => lot.id, "quantity" => quantity }.merge(over.transform_keys(&:to_s))
  def refusal(result) = [ result.reason, result.details[:path], result.details[:problems] ]
  def view_item(record, kind = "digital")
    prescription = find(record, kind)
    Pharmacy::Json.prescription_view(prescription, patient: Patient.find(prescription.patient_id), summary: Pharmacy::Dispensed.summary(prescription),
                                                   settings: settings, today: Time.zone.today)[:items].first
  end
  def written = [ Dispensation.count, DispensationItem.count, StockMovement.where(kind: "dispensing").count ]

  describe "uso contínuo (LOSARTANA)" do
    it "dispensa 30, o saldo cai 30; no 24º dia é too_early com next_allowed_on no 25º; no 25º passa" do
      lot = stocked_lot!(farmacia, item: losartana, quantity: "100")
      document = issue!([ rx_line(losartana, continuous: true) ])
      result = dispense(document, [ line(item_of(document), lot) ])
      expect(result).to be_ok
      dispensation = result.payload.fetch(:dispensation)
      expect(dispensation).to have_attributes(stock_location_id: farmacia.id, patient_id: document.patient_id, clinical_document_id: document.id,
                                              external_prescription_id: nil, dispensed_by_user_id: pharmacist.id, dispensed_by_role: "pharmacist",
                                              retained: false, notification_number: nil)
      expect(dispensation.items.sole).to have_attributes(prescription_item_id: item_of(document), catalog_item_id: losartana.id, stock_lot_id: lot.id,
                                                         quantity: BigDecimal("30"), completes_item: false, mapped_from_free_text: false)
      expect(balance_of(farmacia, lot)).to eq(70)
      expect(StockMovement.where(kind: "dispensing").sole).to have_attributes(quantity: BigDecimal("-30"), dispensation_item_id: dispensation.items.sole.id)
      expect(view_item(document)).to include(dispensed_total: "30.00", last_dispensed_on: today.iso8601, next_allowed_on: (today + 25).iso8601)
      expect(DomainEvent.where(name: "dispensation.recorded").sole.payload).to eq("dispensation_id" => dispensation.id, "user_id" => pharmacist.id)

      travel_to(Time.current + 24.days) do
        early = dispense(document, [ line(item_of(document), lot) ])
        expect(refusal(early)).to eq([ :too_early, "items[0]", [ { path: "items[0]", error: "too_early", next_allowed_on: (today + 25).iso8601 } ] ])
        expect(early.details[:next_allowed_on]).to eq((today + 25).iso8601)
      end
      travel_to(Time.current + 25.days) { expect(dispense(document, [ line(item_of(document), lot) ])).to be_ok }
      expect(balance_of(farmacia, lot)).to eq(40)
    end
  end

  describe "item comum (AMOXICILINA sem marca de antimicrobiano)" do
    before { amoxicilina.update!(antimicrobial: false) }

    it "duas parciais, a segunda com complete: true; a terceira é item_completed" do
      lot = stocked_lot!(farmacia, item: amoxicilina, quantity: "100")
      document = issue!([ rx_line(amoxicilina) ])
      expect(dispense(document, [ line(item_of(document), lot, "10") ])).to be_ok
      expect(dispense(document, [ line(item_of(document), lot, "10.50", complete: true) ])).to be_ok
      expect(view_item(document)).to include(dispensed_total: "20.50", completed: true)
      third = dispense(document, [ line(item_of(document), lot, "5") ])
      expect(refusal(third)).to eq([ :item_completed, "items[0]", [ { path: "items[0]", error: "item_completed" } ] ])
      expect(balance_of(farmacia, lot)).to eq(BigDecimal("79.50"))
    end

    it "complete não booleano é recusado" do
      lot = stocked_lot!(farmacia, item: amoxicilina)
      document = issue!([ rx_line(amoxicilina) ])
      result = dispense(document, [ line(item_of(document), lot, "1", complete: "sim") ])
      expect(refusal(result)).to eq([ :invalid_request, "items[0].complete", [ { path: "items[0].complete", error: "invalid_request" } ] ])
    end
  end

  describe "validade e lote" do
    it "receita vencida → prescription_expired no item; nada gravado" do
      lot = stocked_lot!(farmacia, item: losartana, expires_on: today + 365)
      document = issue!([ rx_line(losartana) ])
      travel_to(Time.current + 31.days) do
        result = dispense(document, [ line(item_of(document), lot) ])
        expect(refusal(result)).to eq([ :prescription_expired, "items[0]", [ { path: "items[0]", error: "prescription_expired" } ] ])
      end
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "lote vencido → lot_expired; lote de outro item → invalid_item no lot_id" do
      expired = stocked_lot!(farmacia, item: losartana, expires_on: today - 1)
      other = stocked_lot!(farmacia, item: amoxicilina)
      document = issue!([ rx_line(losartana) ])
      result = dispense(document, [ line(item_of(document), expired) ])
      expect(refusal(result)).to eq([ :lot_expired, "items[0].lot_id", [ { path: "items[0].lot_id", error: "lot_expired" } ] ])
      result = dispense(document, [ line(item_of(document), other) ])
      expect(refusal(result)).to eq([ :invalid_item, "items[0].lot_id", [ { path: "items[0].lot_id", error: "invalid_item" } ] ])
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "item que não é da receita e catalog_item_id trocado → invalid_item com o path" do
      lot = stocked_lot!(farmacia, item: losartana)
      document = issue!([ rx_line(losartana) ])
      result = dispense(document, [ line(SecureRandom.uuid, lot), line(item_of(document), lot, "1", catalog_item_id: amoxicilina.id) ])
      expect(refusal(result)).to eq([ :invalid_item, "items[0].prescription_item_id",
                                      [ { path: "items[0].prescription_item_id", error: "invalid_item" },
                                        { path: "items[1].catalog_item_id", error: "invalid_item" } ] ])
    end

    it "local de unidade desativada → location_inactive; nada gravado" do
      lot = stocked_lot!(farmacia, item: losartana)
      document = issue!([ rx_line(losartana) ])
      prescription = find(document)
      unit.update!(active: false)
      result = dispense(document, [ line(item_of(document), lot) ], prescription: prescription)
      expect([ result.reason, result.details ]).to eq([ :location_inactive, { path: "location_id" } ])
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "items vazio ou com mais de 20 linhas → invalid_request em items" do
      lot = stocked_lot!(farmacia, item: losartana)
      document = issue!([ rx_line(losartana) ])
      expect(refusal(dispense(document, []))).to eq([ :invalid_request, "items", [ { path: "items", error: "invalid_request" } ] ])
      lines = Array.new(21) { line(item_of(document), lot, "1") }
      expect(refusal(dispense(document, lines))).to eq([ :invalid_request, "items", [ { path: "items", error: "invalid_request" } ] ])
    end
  end

  describe "texto livre" do
    it "auxiliar → 403 free_text_requires_pharmacist (sozinho); farmacêutica escolhe o item e grava mapped_from_free_text" do
      lot = stocked_lot!(farmacia, item: losartana)
      document = issue!([ { "free_text" => "Losartana 50 mg da farmácia popular", "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
                            "dosage_instructions" => "1 comprimido ao dia", "duration_days" => 30 } ])
      result = dispense(document, [ line(item_of(document), lot, "1,5"), line(SecureRandom.uuid, lot) ], by: assistant, role: "pharmacy_assistant")
      expect([ result.reason, result.details ]).to eq([ :free_text_requires_pharmacist, {} ])

      missing = dispense(document, [ line(item_of(document), lot) ])
      expect(refusal(missing)).to eq([ :invalid_item, "items[0].catalog_item_id", [ { path: "items[0].catalog_item_id", error: "invalid_item" } ] ])

      result = dispense(document, [ line(item_of(document), lot, "30", catalog_item_id: losartana.id) ])
      expect(result).to be_ok
      expect(result.payload.fetch(:dispensation).items.sole).to have_attributes(mapped_from_free_text: true, catalog_item_id: losartana.id)
    end

    it "texto livre mapeado para um controlado: retention_required recalculado pelo catálogo escolhido" do
      lot = stocked_lot!(farmacia, item: fluoxetina)
      document = issue!([ { "free_text" => "Cápsula manipulada conforme a fórmula anexa", "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral",
                            "dosage_instructions" => "1 cápsula ao dia", "duration_days" => 30 } ])
      expect(find(document).items.sole.retention_required).to be(false)
      result = dispense(document, [ line(item_of(document), lot, "30", catalog_item_id: fluoxetina.id) ])
      expect(refusal(result)).to eq([ :retention_required, "retention", [ { path: "retention", error: "retention_required" } ] ])
      result = dispense(document, [ line(item_of(document), lot, "30", catalog_item_id: fluoxetina.id) ], retention: {})
      expect(result).to be_ok
      expect(result.payload.fetch(:dispensation)).to have_attributes(retained: true, notification_number: nil)
    end
  end

  describe "controlado (FLUOXETINA C1, receita de controle especial digital com SNCR simulado)" do
    let(:signer) { signer! }
    let(:document) do
      sncr_stock!(signer, kind: "rce", count: 1)
      issue!([ rx_line(fluoxetina) ], by: signer, extra: { "patient_identification" => patient_identification })
    end
    let!(:lot) { stocked_lot!(farmacia, item: fluoxetina, quantity: "100") }

    it "auxiliar → 403 controlled_requires_pharmacist, sozinho mesmo com outras recusas" do
      expect(document).to be_digital
      result = dispense(document, [ line(item_of(document), lot, "1,5"), line(SecureRandom.uuid, lot) ], by: assistant, role: "pharmacy_assistant")
      expect([ result.reason, result.details ]).to eq([ :controlled_requires_pharmacist, {} ])
      expect(written).to eq([ 0, 0, 0 ])
    end

    it "farmacêutica: dois itens inválidos e a retenção ausente vêm juntos" do
      result = dispense(document, [ line(item_of(document), lot, "1,5"), line(item_of(document), stocked_lot!(farmacia, item: losartana)) ])
      expect(refusal(result)).to eq([ :invalid_quantity, "items[0].quantity", [ { path: "items[0].quantity", error: "invalid_quantity" },
                                                                                { path: "items[1].lot_id", error: "invalid_item" },
                                                                                { path: "retention", error: "retention_required" } ] ])
    end

    it "farmacêutica: sem retention → retention_required; com {} grava o número SNCR do documento; número diferente → invalid_request" do
      number = document.content_data.dig("sncr", "number")
      expect(number).to be_present
      expect(refusal(dispense(document, [ line(item_of(document), lot) ]))).to eq([ :retention_required, "retention",
                                                                                     [ { path: "retention", error: "retention_required" } ] ])
      wrong = dispense(document, [ line(item_of(document), lot) ], retention: { "notification_number" => "2610.1-41.9999999" })
      expect(refusal(wrong)).to eq([ :invalid_request, "retention.notification_number",
                                     [ { path: "retention.notification_number", error: "invalid_request" } ] ])
      expect(written).to eq([ 0, 0, 0 ])

      result = dispense(document, [ line(item_of(document), lot) ], retention: {})
      expect(result).to be_ok
      expect(result.payload.fetch(:dispensation)).to have_attributes(retained: true, notification_number: number, dispensed_by_role: "pharmacist")
      expect(dispense(document, [ line(item_of(document), lot, "1") ], retention: { "notification_number" => number })).to be_ok
    end
  end

  describe "antimicrobiano não controlado (H6/H12)" do
    it "o auxiliar dispensa com retention; sem ela, retention_required; o número do documento NÃO é gravado (null)" do
      amoxicilina.update!(antimicrobial: true)
      signer = signer!
      sncr_stock!(signer, kind: "ret", count: 1)
      document = issue!([ rx_line(amoxicilina, duration_days: 7) ], by: signer)
      expect(document.content_data.dig("sncr", "number")).to be_present
      lot = stocked_lot!(farmacia, item: amoxicilina)
      result = dispense(document, [ line(item_of(document), lot, "21") ], by: assistant, role: "pharmacy_assistant")
      expect(refusal(result)).to eq([ :retention_required, "retention", [ { path: "retention", error: "retention_required" } ] ])
      result = dispense(document, [ line(item_of(document), lot, "21") ], by: assistant, role: "pharmacy_assistant", retention: {})
      expect(result).to be_ok
      expect(result.payload.fetch(:dispensation)).to have_attributes(retained: true, notification_number: nil, dispensed_by_role: "pharmacy_assistant")
    end
  end

  describe "receita externa (DIAZEPAM B1)" do
    it "farmacêutica com retention: {} grava o número da notificação da receita externa" do
      patient = registry_patient!
      recorded = Pharmacy::RecordExternalPrescription.call(
        location: farmacia, patient_id: patient.id, new_patient: nil, notification_number: "PR-2026-000123", by: pharmacist, role: "pharmacist",
        prescriber: { "name" => "Dra. Beltrana Souza", "council" => "CRM", "council_state" => "PR", "council_number" => "54321" },
        issued_on: today.iso8601, catalog: { diazepam.id => diazepam }, today: today, settings: settings,
        items: [ { "catalog_item_id" => diazepam.id, "quantity" => "10", "quantity_unit" => "comprimido", "dosage_instructions" => "1 à noite",
                   "continuous" => false } ]
      )
      record = recorded.payload.fetch(:external_prescription)
      lot = stocked_lot!(farmacia, item: diazepam)
      item_id = record.items.sole.id
      expect(refusal(dispense(record, [ line(item_id, lot, "10") ], kind: "external"))).to eq([ :retention_required, "retention",
                                                                                                 [ { path: "retention", error: "retention_required" } ] ])
      expect(dispense(record, [ line(item_id, lot, "10") ], kind: "external", by: assistant, role: "pharmacy_assistant").reason)
        .to eq(:controlled_requires_pharmacist)
      result = dispense(record, [ line(item_id, lot, "10") ], kind: "external", retention: {})
      expect(result).to be_ok
      saved = result.payload.fetch(:dispensation)
      expect(saved).to have_attributes(external_prescription_id: record.id, clinical_document_id: nil, patient_id: patient.id, retained: true,
                                       notification_number: "PR-2026-000123")
      expect(saved.items.sole).to have_attributes(external_prescription_item_id: item_id, prescription_item_id: nil)
    end
  end

  describe "Review Focus 3: o mesmo lote em duas linhas" do
    it "lote com 10, linhas de 6 e 5 → insufficient_balance no items[1].quantity; nenhum movimento nem dispensação" do
      lot = stocked_lot!(farmacia, item: losartana, quantity: "10")
      document = issue!([ rx_line(losartana) ])
      result = dispense(document, [ line(item_of(document), lot, "6"), line(item_of(document), lot, "5") ])
      expect(refusal(result)).to eq([ :insufficient_balance, "items[1].quantity", [ { path: "items[1].quantity", error: "insufficient_balance" } ] ])
      expect(written).to eq([ 0, 0, 0 ])
      expect(balance_of(farmacia, lot)).to eq(10)
      expect(dispense(document, [ line(item_of(document), lot, "6"), line(item_of(document), lot, "4") ])).to be_ok
      expect(balance_of(farmacia, lot)).to eq(0)
    end
  end

  describe "todas as recusas de uma vez (H8/H12)" do
    it "dois itens inválidos, um cedo demais e um sem saldo (apurados sem trava, para virem juntos): todos, na ordem das linhas" do
      amoxicilina.update!(antimicrobial: false)
      losartana_lot = stocked_lot!(farmacia, item: losartana, quantity: "100")
      amoxicilina_lot = stocked_lot!(farmacia, item: amoxicilina, quantity: "5")
      document = issue!([ rx_line(losartana, continuous: true), rx_line(amoxicilina) ])
      expect(dispense(document, [ line(item_of(document), losartana_lot) ])).to be_ok
      result = dispense(document, [ line(item_of(document, 1), losartana_lot, "1"), line(item_of(document, 2), amoxicilina_lot, "6"),
                                    line(item_of(document, 2), losartana_lot, "1.5"), line(item_of(document, 2), amoxicilina_lot, "1,5") ])
      expect(refusal(result)).to eq([ :too_early, "items[0]", [
        { path: "items[0]", error: "too_early", next_allowed_on: (today + 25).iso8601 },
        { path: "items[1].quantity", error: "insufficient_balance" },
        { path: "items[2].lot_id", error: "invalid_item" },
        { path: "items[3].quantity", error: "invalid_quantity" }
      ] ])
      expect(result.details[:next_allowed_on]).to eq((today + 25).iso8601)
      expect(written).to eq([ 1, 1, 1 ])
    end

    it "sem recusa antes da trava, as apuradas sob trava vêm juntas (saldo e cedo demais)" do
      losartana_lot = stocked_lot!(farmacia, item: losartana, quantity: "40")
      document = issue!([ rx_line(losartana, continuous: true), rx_line(losartana) ])
      expect(dispense(document, [ line(item_of(document, 1), losartana_lot) ])).to be_ok
      result = dispense(document, [ line(item_of(document, 1), losartana_lot, "1"), line(item_of(document, 2), losartana_lot, "10") ])
      expect(refusal(result)).to eq([ :too_early, "items[0]", [ { path: "items[0]", error: "too_early", next_allowed_on: (today + 25).iso8601 },
                                                                { path: "items[1].quantity", error: "insufficient_balance" } ] ])
    end
  end

  describe "Review Focus 2: receita cancelada entre a busca e a dispensação" do
    it "lida antes do Cancel, dispensada depois → prescription_cancelled, saldo intacto, nada gravado" do
      lot = stocked_lot!(farmacia, item: losartana, quantity: "30")
      document = issue!([ rx_line(losartana) ])
      prescription = find(document)
      expect(prescription.cancelled).to be(false)
      expect(ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "Prescrição trocada pela médica")).to be_ok
      result = dispense(document, [ line(item_of(document), lot) ], prescription: prescription)
      expect(refusal(result)).to eq([ :prescription_cancelled, "prescription", [ { path: "prescription", error: "prescription_cancelled" } ] ])
      expect(balance_of(farmacia, lot)).to eq(30)
      expect(written).to eq([ 0, 0, 0 ])
      expect(refusal(dispense(document, [ line(item_of(document), lot) ])).first).to eq(:prescription_cancelled)
    end
  end

  describe "devolução (Pharmacy::RecordReturn)" do
    def give_back(item, quantity, reason: "Paciente trouxe de volta, lacrado", location: farmacia)
      Pharmacy::RecordReturn.call(location: location, dispensation_item: item.reload, quantity: quantity, reason: reason, by: assistant)
    end

    it "devolver tudo libera nova retirada do contínuo; devolução parcial não; dispensed_total é líquido" do
      lot = stocked_lot!(farmacia, item: losartana, quantity: "100")
      document = issue!([ rx_line(losartana, continuous: true) ])
      first = dispense(document, [ line(item_of(document), lot) ]).payload.fetch(:dispensation).items.sole
      expect(give_back(first, "5")).to be_ok
      expect(view_item(document)).to include(dispensed_total: "25.00", last_dispensed_on: today.iso8601)
      expect(dispense(document, [ line(item_of(document), lot) ]).reason).to eq(:too_early)
      returned = give_back(first, "25")
      expect(returned).to be_ok
      expect(returned.payload.fetch(:movement)).to have_attributes(kind: "return", quantity: BigDecimal("25"), dispensation_item_id: first.id,
                                                                   stock_lot_id: lot.id, stock_location_id: farmacia.id)
      expect(view_item(document)).to include(dispensed_total: "0.00", last_dispensed_on: nil, next_allowed_on: nil)
      expect(balance_of(farmacia, lot)).to eq(100)
      expect(dispense(document, [ line(item_of(document), lot) ])).to be_ok
      expect(DomainEvent.where(name: "dispensation.returned").map(&:payload).uniq).to eq([ { "dispensation_id" => first.dispensation_id,
                                                                                                "user_id" => assistant.id } ])
    end

    it "devolver tudo do item completo reabre o item; mais que o restante → return_exceeds; motivo curto e quantidade juntos" do
      amoxicilina.update!(antimicrobial: false)
      lot = stocked_lot!(farmacia, item: amoxicilina, quantity: "100")
      document = issue!([ rx_line(amoxicilina) ])
      item = dispense(document, [ line(item_of(document), lot, "10", complete: true) ]).payload.fetch(:dispensation).items.sole
      expect(refusal(give_back(item, "10.01"))).to eq([ :return_exceeds, "quantity", [ { path: "quantity", error: "return_exceeds" } ] ])
      expect(refusal(give_back(item, "1,5", reason: "curto"))).to eq([ :invalid_quantity, "quantity", [ { path: "quantity", error: "invalid_quantity" },
                                                                                                         { path: "reason", error: "invalid_reason" } ] ])
      expect(give_back(item, "10")).to be_ok
      expect(refusal(give_back(item, "1"))).to eq([ :return_exceeds, "quantity", [ { path: "quantity", error: "return_exceeds" } ] ])
      expect(view_item(document)).to include(dispensed_total: "0.00", completed: false)
      expect(dispense(document, [ line(item_of(document), lot, "5") ])).to be_ok
    end

    it "lote vencido não volta: lot_expired" do
      lot = stocked_lot!(farmacia, item: losartana, quantity: "30", expires_on: today + 2)
      document = issue!([ rx_line(losartana) ])
      item = dispense(document, [ line(item_of(document), lot, "10") ]).payload.fetch(:dispensation).items.sole
      travel_to(Time.current + 3.days) do
        expect(refusal(give_back(item, "5"))).to eq([ :lot_expired, "dispensation_item_id", [ { path: "dispensation_item_id", error: "lot_expired" } ] ])
      end
      expect(StockMovement.where(kind: "return").count).to eq(0)
    end
  end
end
