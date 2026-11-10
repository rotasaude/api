# Forma JSON da prescrição interna da UPA (ADR 0050; contrato §5; módulo 32b,
# Task 7). `catalog` é { catalog_item_id => MedicationCatalogItem } (da
# plataforma, lido fora da transação da cidade: Pharmacy::Json.catalog_for) — o
# nome do medicamento não é gravado, sai do catálogo na leitura. É clínico: só
# o médico que prescreve (e as leituras clínicas das próximas tasks) o recebe.
module Urgency
  module PrescriptionJson
    module_function

    def call(prescription, catalog:)
      {
        id: prescription.id, encounter_id: prescription.urgency_encounter_id, version: prescription.version,
        status: prescription.status, supersedes_id: prescription.supersedes_id, prescribed_at: prescription.prescribed_at.iso8601,
        prescribed_by: { name: Screenings::Json.staff_name(prescription.prescribed_by_user), cbo_code: prescription.cbo_code },
        status_changed_at: prescription.status_changed_at&.iso8601, suspension_reason: prescription.suspension_reason,
        items: prescription.items.map { |row| item(row, catalog: catalog) }
      }
    end

    def item(row, catalog:)
      found = catalog[row.catalog_item_id]
      {
        id: row.id, position: row.position, catalog_item: found && Pharmacy::Json.catalog_item(found),
        controlled: row.controlled?, controlled_list: row.controlled_list, dose: dose(row.dose), dose_unit: row.dose_unit,
        route: row.route, frequency: { kind: row.frequency_kind, interval_hours: row.interval_hours, max_per_day: row.max_per_day },
        first_dose_at: row.first_dose_at.iso8601, instructions: row.instructions,
        stock_quantity_per_dose: Pharmacy::Quantity.dump(row.stock_quantity_per_dose), stock_unit: row.stock_unit
      }
    end

    # A dose como foi digitada, sem zeros à direita ("50", "2.5"): String decimal (Q6).
    def dose(value) = value.to_d.to_s("F").sub(/\.0\z/, "")

    # Os ids de catálogo dos itens, para ler o catálogo de uma vez.
    def catalog_for(prescriptions)
      Pharmacy::Json.catalog_for(Array(prescriptions).flat_map { |p| p.items.map(&:catalog_item_id) })
    end
  end
end
