# Aprazamento da prescrição ativa, calculado na leitura (ADR 0050; contrato §5
# e §12 Q5; plano, Desvios 5 e 11): nenhuma tabela de horários.
#
# - `once`: um horário, `first_dose_at`. `interval`: `first_dose_at + k ×
#   interval_hours`, k ≥ 0, até `now + 24 h` (os já passados ficam, para checar
#   com o encontro aberto). `if_needed`: sem horários; `remaining = max_per_day
#   − administered nas últimas 24 h` (só `administered` conta, Q5); `recent`
#   = as últimas checagens do medicamento (qualquer versão).
# - O `first_dose_at` é gravado truncado ao minuto: os horários têm segundos
#   zerados e se comparam por igualdade exata.
# - `last_administration`: a mais recente do MESMO `catalog_item_id` no
#   encontro, de qualquer versão da prescrição. `lots`: FEFO (Urgency::Fefo) do
#   local `unit` da UPA, só com `stock:` ligado.
module Urgency
  module Schedule
    module_function

    # -> [Time]
    def slots(item, now:)
      first = item.first_dose_at
      case item.frequency_kind
      when "once" then [ first ]
      when "interval"
        step = item.interval_hours.hours
        limit = now + Catalog::SCHEDULE_AHEAD
        Array.new(((limit - first) / step).floor + 1) { |k| first + (k * step) }.select { |at| at <= limit }
      else []
      end
    end

    def slot?(item, at, now:) = slots(item, now: now).any? { |slot| slot.to_i == at.to_i }

    # Administradas (status administered) do medicamento do item, no encontro,
    # nas 24 h até `at`. -> Integer
    def if_needed_used(item, at:)
      administered_scope(item).where(administered_at: (at - Catalog::IF_NEEDED_WINDOW)..at).count
    end

    # `catalog`: { catalog_item_id => MedicationCatalogItem }; `stock`: nil
    # (desligado) ou { location: StockLocation | nil, today: Date }.
    def call(encounter, now:, catalog:, stock: nil)
      prescription = encounter.active_prescription
      return { prescription_id: nil, items: [] } unless prescription

      items = prescription.items.order(:position).to_a
      admins = UrgencyAdministration.where(urgency_encounter_id: encounter.id).includes(:stock_lot, recorded_by_user: :professional)
      by_item = admins.where(urgency_prescription_item_id: items.map(&:id)).group_by(&:urgency_prescription_item_id)
      by_drug = admins.joins(:urgency_prescription_item).where(urgency_prescription_items: { catalog_item_id: items.map(&:catalog_item_id) })
                      .order(Arel.sql("COALESCE(urgency_administrations.administered_at, urgency_administrations.recorded_at) DESC, urgency_administrations.id DESC"))
                      .to_a.group_by { |a| a.urgency_prescription_item.catalog_item_id }
      {
        prescription_id: prescription.id, version: prescription.version,
        items: items.map { |row| item_json(row, now: now, catalog: catalog, own: by_item.fetch(row.id, []), drug: by_drug.fetch(row.catalog_item_id, []), stock: stock) }
      }
    end

    def item_json(row, now:, catalog:, own:, drug:, stock:)
      base = PrescriptionJson.item(row, catalog: catalog).merge(item_id: row.id)
      by_slot = own.select(&:scheduled_at).index_by { |a| a.scheduled_at.to_i }
      json = base.merge(
        slots: slots(row, now: now).map { |at| { scheduled_at: at.iso8601, administration: (found = by_slot[at.to_i]) && administration(found) } },
        recent: nil, remaining: nil,
        last_administration: drug.first && administration(drug.first)
      )
      if row.frequency_kind == "if_needed"
        used = drug.select { |a| a.status == "administered" && a.administered_at > now - Catalog::IF_NEEDED_WINDOW && a.administered_at <= now }
        json[:recent] = drug.first(10).map { |a| administration(a) }
        json[:remaining] = [ row.max_per_day - used.size, 0 ].max
      end
      json[:lots] = lots(row, stock) if stock
      json
    end
    private_class_method :item_json

    # <adm> (contrato §5): o motivo é clínico e só sai para quem lê o aprazamento.
    def administration(adm)
      lot = adm.stock_lot
      {
        id: adm.id, status: adm.status, scheduled_at: adm.scheduled_at&.iso8601, administered_at: adm.administered_at&.iso8601,
        reason: adm.reason, stock_lot: lot && { id: lot.id, lot_number: lot.lot_number, expires_on: lot.expires_on.iso8601 },
        stock_quantity: adm.stock_quantity && Pharmacy::Quantity.dump(adm.stock_quantity), recorded_at: adm.recorded_at.iso8601,
        by: { name: Screenings::Json.staff_name(adm.recorded_by_user), cbo_code: adm.cbo_code }
      }
    end

    def lots(row, stock)
      Fefo.lots(catalog_item_id: row.catalog_item_id, stock_unit: row.stock_unit, location: stock[:location], today: stock[:today]).map do |entry|
        { id: entry.lot.id, lot_number: entry.lot.lot_number, expires_on: entry.lot.expires_on.iso8601, balance: Pharmacy::Quantity.dump(entry.balance) }
      end
    end
    private_class_method :lots

    def administered_scope(item)
      UrgencyAdministration.joins(:urgency_prescription_item)
                           .where(status: "administered", urgency_prescription_items: { catalog_item_id: item.catalog_item_id })
                           .where(urgency_encounter_id: item.urgency_prescription.urgency_encounter_id)
    end
    private_class_method :administered_scope
  end
end
