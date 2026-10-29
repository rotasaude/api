# Formas JSON da farmácia (ADR 0045; contrato §2 e H1): `<item>`, `<lot>` e
# `<location>`. Só estoque e catálogo: nenhum dado de paciente passa por aqui.
#
# `item.unit` é a unidade da CONCENTRAÇÃO ("mg", a do catálogo); a unidade de
# dispensação ("comprimido") vai em `item.dispensing_unit`: a gravada no lote
# quando há lote, a da regra (Pharmacy::DispensingUnit.for) quando não há.
module Pharmacy
  module Json
    module_function

    # { id, name, kind, health_unit: { id, name } | nil, active }
    def location(location)
      unit = location.health_unit
      { id: location.id, name: location.name, kind: location.kind,
        health_unit: unit && { id: unit.id, name: unit.name }, active: location.active }
    end

    # Locais para a administração (contrato §3): <location> + `staff` ativo
    # `[ { user_id, name, role } ]`, sem e-mail. O nome vem do perfil
    # profissional (quem não tem perfil, como o almoxarife, vai com `name: null`).
    def admin_locations(locations)
      locations = locations.to_a
      links = StockLocationStaff.active.includes(user: :professional).where(stock_location_id: locations.map(&:id)).group_by(&:stock_location_id)
      locations.map do |row|
        staff = (links[row.id] || []).map do |link|
          { user_id: link.user_id, name: link.user.professional&.professional_name, role: link.role }
        end
        location(row).merge(staff: staff.sort_by { |member| [ member[:name].to_s, member[:role], member[:user_id] ] })
      end
    end

    # <item>: `dispensing_unit` é obrigatório (lote, busca, mínimos, posição…).
    def item(catalog_item, dispensing_unit:)
      { catalog_item_id: catalog_item.id, catmat_code: catalog_item.catmat_code, name: catalog_item.label, unit: catalog_item.unit,
        dispensing_unit: dispensing_unit, controlled: catalog_item.controlled, controlled_list: catalog_item.controlled_list }
    end

    # <item> pela regra do YAML (fora de lote).
    def catalog_item(catalog_item) = item(catalog_item, dispensing_unit: DispensingUnit.for(catalog_item))

    # <lot>: `catalog` é { catalog_item_id => MedicationCatalogItem } (veja
    # `catalog_for`). A unidade de dispensação é a do LOTE, gravada na primeira
    # entrada; `item.unit` continua sendo a da concentração.
    def lot(lot, catalog:)
      { id: lot.id, item: item(catalog.fetch(lot.catalog_item_id), dispensing_unit: lot.dispensing_unit),
        lot_number: lot.lot_number, expires_on: lot.expires_on.iso8601, manufacturer: lot.manufacturer }
    end

    # Os cinco parâmetros da cidade, como o contrato §3.
    def settings(setting) = Catalog::SETTING_RANGES.keys.index_with { |key| setting.public_send(key) }

    # Itens do catálogo da plataforma por id, numa consulta só.
    def catalog_for(ids) = MedicationCatalogItem.where(id: ids.compact.uniq).index_by(&:id)
  end
end
