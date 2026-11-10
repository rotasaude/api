require "rails_helper"

# Módulo 32b (ADR 0050; contrato §1, §5 e §12 Q4/Q5): prescrição em versões,
# itens e administrações (checagem de medicação) da observação da UPA.
RSpec.describe "Esquema da prescrição e da checagem da UPA", type: :model do
  let!(:city) { urgency_city! }
  let(:upa) { create_unit("UPA Presc", kind: "upa") }
  let(:doctor) { upa_doctor!(upa) }
  let(:link) { ProfessionalLink.find_by!(professional: doctor.professional) }
  let!(:encounter) do
    e = arrived!(upa)
    classified!(e, color: "yellow", by: upa_nurse!(upa))
    called!(e, by: doctor)
    e.reload
  end

  def sp(&) = ApplicationRecord.transaction(requires_new: true, &)

  def raw(sql) = ApplicationRecord.connection.execute(sql)

  def prescription!(enc = encounter, **over)
    UrgencyPrescription.create!({ urgency_encounter: enc, version: 1, prescribed_by_user: doctor, professional_link: link,
                                  cbo_code: "225125", prescribed_at: Time.current }.merge(over))
  end

  def supersede!(prescription)
    prescription.update!(status: "superseded", status_changed_at: Time.current, status_changed_by_user: doctor)
  end

  def item!(prescription, **over)
    UrgencyPrescriptionItem.create!({ urgency_prescription: prescription, position: 1, catalog_item_id: SecureRandom.uuid,
                                      catmat_code: 268_856, controlled_list: nil, dose: "500", dose_unit: "mg", route: "oral",
                                      frequency_kind: "interval", interval_hours: 8, first_dose_at: Time.current,
                                      stock_quantity_per_dose: 1, stock_unit: "comprimido" }.merge(over))
  end

  def administration!(item, enc = encounter, **over)
    UrgencyAdministration.create!({ urgency_prescription_item: item, urgency_encounter: enc, scheduled_at: Time.current.change(usec: 0),
                                    status: "administered", administered_at: Time.current, recorded_by_user: doctor,
                                    professional_link: link, cbo_code: "225125", recorded_at: Time.current }.merge(over))
  end

  def lot!
    StockLot.create!(catalog_item_id: SecureRandom.uuid, catmat_code: 268_856, lot_number: "L#{SecureRandom.hex(3)}",
                     expires_on: Date.current + 200, dispensing_unit: "comprimido", created_by_user: doctor)
  end

  def refused(message, &block)
    expect { sp(&block) }.to raise_error(ActiveRecord::StatementInvalid, message)
  end

  describe "prescrição" do
    it "uma ativa por encontro (idx_urgency_prescriptions_active) e uma versão por número (idx_urgency_prescriptions_version)" do
      first = prescription!
      expect { sp { prescription!(version: 2, supersedes: first) } }.to raise_error(ActiveRecord::RecordNotUnique, /idx_urgency_prescriptions_active/)
      supersede!(first)
      second = prescription!(version: 2, supersedes: first)
      expect(second).to be_persisted
      supersede!(second)
      expect { sp { prescription!(version: 2, supersedes: first) } }.to raise_error(ActiveRecord::RecordNotUnique, /idx_urgency_prescriptions_version/)
    end

    it "o status só anda para frente: active -> superseded aceito, depois nada muda" do
      p1 = prescription!
      supersede!(p1)
      expect(p1.reload.status).to eq("superseded")
      refused(/urgency_prescriptions: status only moves forward/) { p1.update_columns(status: "active", status_changed_at: nil, status_changed_by_user_id: nil) }
      refused(/urgency_prescriptions: status only moves forward/) { p1.update_columns(status: "ended") }
      refused(/urgency_prescriptions: status only moves forward/) { p1.update_columns(updated_at: Time.current) }
    end

    it "uma ativa que não sai de active (UPDATE sem mudança de status) é recusada" do
      p1 = prescription!
      refused(/status only moves forward/) { p1.update_columns(updated_at: Time.current) }
    end

    it "só status, status_changed_at, status_changed_by_user_id, suspension_reason e updated_at mudam" do
      p1 = prescription!
      refused(/only the status change is accepted/) do
        p1.update_columns(status: "ended", status_changed_at: Time.current, status_changed_by_user_id: doctor.id, cbo_code: "225130")
      end
      refused(/only the status change is accepted/) do
        p1.update_columns(status: "ended", status_changed_at: Time.current, status_changed_by_user_id: doctor.id, version: 5)
      end
    end

    it "suspende com o motivo (cifrado) e a re-cifra regrava só o motivo" do
      p1 = prescription!
      p1.update!(status: "suspended", suspension_reason: "Alergia confirmada ao fármaco", status_changed_at: Time.current,
                 status_changed_by_user: doctor)
      stored = raw("SELECT suspension_reason FROM urgency_prescriptions WHERE id = '#{p1.id}'").first["suspension_reason"]
      expect(stored).not_to include("Alergia")
      refused(/status only moves forward/) { p1.update_columns(suspension_reason: "outro") }
      sp do
        raw("SET LOCAL rota.reencrypting = 'on'")
        expect { raw("UPDATE urgency_prescriptions SET suspension_reason = 'regravado' WHERE id = '#{p1.id}'") }.not_to raise_error
      end
      refused(/status only moves forward/) do
        raw("SET LOCAL rota.reencrypting = 'on'")
        raw("UPDATE urgency_prescriptions SET cbo_code = '225130' WHERE id = '#{p1.id}'")
      end
    end

    it "DELETE e TRUNCATE recusados" do
      p1 = prescription!
      refused(/urgency_prescriptions: DELETE refused/) { p1.delete }
      refused(/urgency_prescriptions is append-only: TRUNCATE refused/) { raw("TRUNCATE urgency_prescriptions CASCADE") }
    end

    it "não nasce em encontro fechado, nem fora de active, e a anterior é do mesmo encontro" do
      other = arrived!(upa)
      other_p = prescription!(other)
      supersede!(other_p)
      refused(/urgency_prescriptions: a prescription is born active/) do
        prescription!(status: "ended", status_changed_at: Time.current, status_changed_by_user: doctor)
      end
      refused(/urgency_prescriptions: supersedes a prescription of another encounter/) { prescription!(version: 2, supersedes: other_p) }
      encounter.update_columns(state: "closed")
      refused(/urgency_prescriptions: the encounter is closed/) { prescription!(encounter) }
    end

    it "CHECKs: status, versão, motivo da suspensão e o fechamento" do
      p1 = prescription!
      refused(/ck_urgency_prescriptions_status/) do
        p1.update_columns(status: "bogus", status_changed_at: Time.current, status_changed_by_user_id: doctor.id)
      end
      p1.reload # a escrita crua recusada deixa os atributos em memória
      refused(/ck_urgency_prescriptions_version/) { prescription!(version: 0) }
      refused(/ck_urgency_prescriptions_version/) { prescription!(version: 2) } # v2 sem supersedes
      supersede!(p1)
      refused(/ck_urgency_prescriptions_version/) { prescription!(version: 1, supersedes: p1) } # v1 com supersedes
      p2 = prescription!(version: 2, supersedes: p1)
      refused(/ck_urgency_prescriptions_suspended/) do
        p2.update_columns(status: "suspended", status_changed_at: Time.current, status_changed_by_user_id: doctor.id)
      end
      refused(/ck_urgency_prescriptions_suspended/) do
        raw("INSERT INTO urgency_prescriptions (urgency_encounter_id, version, status, suspension_reason, supersedes_id, prescribed_by_user_id, " \
            "professional_link_id, cbo_code, prescribed_at, created_at, updated_at) " \
            "VALUES ('#{encounter.id}', 3, 'active', 'x', '#{p2.id}', '#{doctor.id}', '#{link.id}', '225125', now(), now(), now())")
      end
      p2.reload
      refused(/ck_urgency_prescriptions_closing/) { p2.update_columns(status: "ended") }
      refused(/ck_urgency_prescriptions_closing/) { p2.update_columns(status: "ended", status_changed_at: Time.current) }
    end
  end

  describe "itens" do
    it "item novo só em prescrição ativa; update e delete recusados; re-cifra aceita só em instructions" do
      p1 = prescription!
      it1 = item!(p1, instructions: "Diluir em água")
      stored = raw("SELECT instructions FROM urgency_prescription_items WHERE id = '#{it1.id}'").first["instructions"]
      expect(stored).not_to include("Diluir")
      refused(/urgency_prescription_items is append-only: UPDATE refused/) { it1.update_column(:dose, 1) }
      refused(/urgency_prescription_items is append-only: UPDATE refused/) { it1.update_column(:instructions, "outro") }
      refused(/urgency_prescription_items is append-only: DELETE refused/) { it1.delete }
      refused(/urgency_prescription_items is append-only: UPDATE refused/) do
        raw("SET LOCAL rota.reencrypting = 'on'")
        raw("UPDATE urgency_prescription_items SET dose = 2 WHERE id = '#{it1.id}'")
      end
      sp do
        raw("SET LOCAL rota.reencrypting = 'on'")
        expect { raw("UPDATE urgency_prescription_items SET instructions = 'regravado' WHERE id = '#{it1.id}'") }.not_to raise_error
      end
      refused(/urgency_prescription_items is append-only: TRUNCATE refused/) { raw("TRUNCATE urgency_prescription_items CASCADE") }
      supersede!(p1)
      refused(/urgency_prescription_items: prescription is not active/) { item!(p1, position: 2) }
    end

    it "posição única por prescrição (1..20)" do
      p1 = prescription!
      item!(p1)
      expect { sp { item!(p1) } }.to raise_error(ActiveRecord::RecordNotUnique, /idx_urgency_prescription_items_position/)
      refused(/ck_urgency_prescription_items_position/) { item!(p1, position: 0) }
      refused(/ck_urgency_prescription_items_position/) { item!(p1, position: 21) }
    end

    it "CHECKs: dose, unidade, via, frequência, intervalo, máximo diário e estoque" do
      p1 = prescription!
      refused(/ck_urgency_prescription_items_dose/) { item!(p1, dose: "0") }
      refused(/ck_urgency_prescription_items_dose_unit/) { item!(p1, dose_unit: "kg") }
      refused(/ck_urgency_prescription_items_route/) { item!(p1, route: "bogus") }
      refused(/ck_urgency_prescription_items_frequency_kind/) { item!(p1, frequency_kind: "bogus", interval_hours: nil) }
      refused(/ck_urgency_prescription_items_interval_pair/) { item!(p1, interval_hours: nil) }
      refused(/ck_urgency_prescription_items_interval_pair/) { item!(p1, frequency_kind: "once") }
      refused(/ck_urgency_prescription_items_interval_range/) { item!(p1, interval_hours: 0) }
      refused(/ck_urgency_prescription_items_interval_range/) { item!(p1, interval_hours: 25) }
      refused(/ck_urgency_prescription_items_max_pair/) { item!(p1, frequency_kind: "if_needed", interval_hours: nil, max_per_day: nil) }
      refused(/ck_urgency_prescription_items_max_pair/) { item!(p1, max_per_day: 3) }
      refused(/ck_urgency_prescription_items_max_range/) { item!(p1, frequency_kind: "if_needed", interval_hours: nil, max_per_day: 0) }
      refused(/ck_urgency_prescription_items_max_range/) { item!(p1, frequency_kind: "if_needed", interval_hours: nil, max_per_day: 25) }
      refused(/ck_urgency_prescription_items_stock_quantity/) { item!(p1, stock_quantity_per_dose: 0) }
      refused(/ck_urgency_prescription_items_stock_quantity/) { item!(p1, stock_quantity_per_dose: "100000") }
      expect { sp { item!(p1, frequency_kind: "if_needed", interval_hours: nil, max_per_day: 4) } }.not_to raise_error
      expect { sp { item!(p1, position: 2, frequency_kind: "once", interval_hours: nil) } }.not_to raise_error
    end

    it "controlled? segue controlled_list" do
      p1 = prescription!
      expect(item!(p1).controlled?).to be(false)
      expect(item!(p1, position: 2, controlled_list: "B1").controlled?).to be(true)
    end
  end

  describe "administrações" do
    let!(:p1) { prescription! }
    let!(:it1) { item!(p1) }

    it "só acréscimo: update, delete e TRUNCATE recusados; re-cifra aceita só em reason" do
      adm = administration!(it1)
      refused(/urgency_administrations is append-only: UPDATE refused/) { adm.update_column(:status, "refused") }
      refused(/urgency_administrations is append-only: DELETE refused/) { adm.delete }
      refused(/urgency_administrations is append-only: TRUNCATE refused/) { raw("TRUNCATE urgency_administrations CASCADE") }
      refused(/urgency_administrations is append-only: UPDATE refused/) do
        raw("SET LOCAL rota.reencrypting = 'on'")
        raw("UPDATE urgency_administrations SET cbo_code = '225130' WHERE id = '#{adm.id}'")
      end
      refused = administration!(it1, scheduled_at: 1.hour.from_now.change(usec: 0), status: "refused", administered_at: nil,
                                     reason: "Paciente recusou a medicação")
      stored = raw("SELECT reason FROM urgency_administrations WHERE id = '#{refused.id}'").first["reason"]
      expect(stored).not_to include("recusou")
      sp do
        raw("SET LOCAL rota.reencrypting = 'on'")
        expect { raw("UPDATE urgency_administrations SET reason = 'regravado' WHERE id = '#{refused.id}'") }.not_to raise_error
      end
    end

    it "um registro por (item, horário): idx_urgency_administrations_slot; sem horário (se necessário) não conflita" do
      at = Time.current.change(usec: 0)
      administration!(it1, scheduled_at: at)
      expect { sp { administration!(it1, scheduled_at: at, status: "not_administered", administered_at: nil, reason: "Sem acesso venoso agora") } }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_urgency_administrations_slot/)
      expect { administration!(it1, scheduled_at: nil) }.not_to raise_error
      expect { administration!(it1, scheduled_at: nil) }.not_to raise_error
    end

    it "encontro fechado recusa; item de outra prescrição/encontro ou de prescrição inativa recusa" do
      other_enc = arrived!(upa)
      classified!(other_enc, color: "green", by: upa_nurse!(upa))
      other_item = item!(prescription!(other_enc))
      refused(/urgency_administrations: item of another encounter or of an inactive prescription/) do
        administration!(other_item, encounter)
      end
      supersede!(p1)
      refused(/urgency_administrations: item of another encounter or of an inactive prescription/) { administration!(it1) }
      active = prescription!(version: 2, supersedes: p1)
      active_item = item!(active)
      encounter.update_columns(state: "closed")
      refused(/urgency_administrations: the encounter is closed/) { administration!(active_item) }
    end

    it "CHECKs: status, administered_at, reason e o estoque" do
      refused(/ck_urgency_administrations_status/) do
        raw("INSERT INTO urgency_administrations (urgency_prescription_item_id, urgency_encounter_id, status, reason, recorded_by_user_id, professional_link_id, " \
            "cbo_code, recorded_at, created_at) VALUES ('#{it1.id}', '#{encounter.id}', 'bogus', 'x', '#{doctor.id}', '#{link.id}', '225125', now(), now())")
      end
      refused(/ck_urgency_administrations_administered_at/) { administration!(it1, administered_at: nil) }
      refused(/ck_urgency_administrations_administered_at/) do
        administration!(it1, status: "refused", reason: "Paciente recusou a medicação")
      end
      refused(/ck_urgency_administrations_reason/) { administration!(it1, status: "refused", administered_at: nil) }
      refused(/ck_urgency_administrations_reason/) { administration!(it1, reason: "Motivo indevido aqui") }
      lot = lot!
      refused(/ck_urgency_administrations_stock_pair/) { administration!(it1, stock_lot: lot) }
      refused(/ck_urgency_administrations_stock_pair/) { administration!(it1, stock_quantity: 1) }
      refused(/ck_urgency_administrations_stock_status/) do
        administration!(it1, status: "refused", administered_at: nil, reason: "Paciente recusou a medicação", stock_lot: lot, stock_quantity: 1)
      end
      refused(/ck_urgency_administrations_stock_quantity/) { administration!(it1, stock_lot: lot, stock_quantity: 0) }
      expect { sp { administration!(it1, stock_lot: lot, stock_quantity: 1) } }.not_to raise_error
    end
  end

  describe "associações" do
    it "UrgencyEncounter#prescriptions e #active_prescription; versões antigas ficam" do
      p1 = prescription!
      expect(encounter.reload.active_prescription).to eq(p1)
      supersede!(p1)
      p2 = prescription!(version: 2, supersedes: p1)
      expect(encounter.reload.prescriptions.to_a).to eq([ p1, p2 ])
      expect(encounter.active_prescription).to eq(p2)
      expect(UrgencyPrescription.active_versions.to_a).to eq([ p2 ])
      expect(p2.supersedes).to eq(p1)
      expect(p2.items.to_a).to eq([])
    end

    it "nunca vazam dado em inspect, to_s, as_json" do
      p1 = prescription!
      it1 = item!(p1, instructions: "segredo")
      adm = administration!(it1)
      [ p1, it1, adm ].each do |record|
        expect(record.inspect).to eq("#<#{record.class} id=#{record.id}>")
        expect(record.as_json).to eq({ "id" => record.id })
      end
    end
  end
end
