# app/services/clinical_documents/json.rb
# Formas do contrato do 19c (§2, §5, §6). Este arquivo cresce nas Tasks 11,
# 15 e 16 (protocolo, documento, medicamento).
module ClinicalDocuments
  module Json
    module_function

    # <item> da busca (contrato §5) e da REMUME (§6).
    def catalog_item(item, in_network: nil)
      json = catalog_ref(item).merge(antimicrobial: item.antimicrobial, controlled: item.controlled)
      in_network.nil? ? json : json.merge(in_network: in_network)
    end

    # `catalog_item` dentro do <item> da receita e do <medication> (§2).
    def catalog_ref(item)
      { id: item.id, catmat_code: item.catmat_code, label: item.label, active_ingredient: item.active_ingredient,
        strength: item.strength, dosage_form: item.dosage_form }
    end

    # Número do JSON: inteiro quando não tem casas (30, não 30.0).
    def number(decimal)
      return nil if decimal.nil?

      value = BigDecimal(decimal.to_s)
      value.frac.zero? ? value.to_i : value.to_f
    end

    # Protocolo de enfermagem (contrato §6) com a versão vigente na data.
    def protocol(protocol, catalog:, on: Time.zone.today)
      version = protocol.current_version(on: on)
      { id: protocol.id, title: protocol.title, number: protocol.number, year: protocol.year,
        current_version: version && {
          id: version.id, version: version.version, valid_from: version.valid_from.iso8601,
          valid_until: version.valid_until&.iso8601,
          items: version.items.order(:created_at, :id).filter_map do |item|
            entry = catalog[item.catalog_item_id]
            entry && { catalog_item: catalog_ref(entry),
                       max_dose: item.max_quantity && { quantity: number(item.max_quantity), unit: item.max_quantity_unit } }
          end
        } }
    end
  end
end
