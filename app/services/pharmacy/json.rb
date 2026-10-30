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

    # Entrada gravada (nota, doação ou abertura): `{ id, kind, location, items, at }`,
    # sem envelope. Um item por movimento, na ordem do pedido, com a quantidade
    # em duas casas. `movements` carrega o lote (`stock_lot`).
    def entry(entry, movements:, catalog:)
      { id: entry.id, kind: entry.kind, location: location(entry.stock_location),
        items: movements.map { |movement| { lot: lot(movement.stock_lot, catalog: catalog), quantity: Quantity.dump(movement.quantity) } },
        at: entry.created_at.iso8601 }
    end

    # Transferência (contrato §5/H2): `{ id, from, to, status, sent_at, received_at,
    # items: [ { lot, quantity_sent, quantity_received|null, difference|null } ] }`,
    # sem envelope. `difference` = enviado - recebido (duas casas), nulo enquanto
    # não foi recebida. O motivo da diferença só vai com `reasons: true` (o
    # detalhe, para quem pode receber no destino): é texto livre, nunca na lista.
    # `transfer` carrega itens (com o lote) e os dois locais (com a unidade).
    # Itens em ordem estável: número do lote, id.
    def transfer(transfer, catalog:, reasons: false)
      items = transfer.items.sort_by { |item| [ item.stock_lot.lot_number, item.stock_lot_id ] }.map do |item|
        received = item.quantity_received
        row = { lot: lot(item.stock_lot, catalog: catalog), quantity_sent: Quantity.dump(item.quantity_sent),
                quantity_received: received && Quantity.dump(received),
                difference: received && Quantity.dump(item.quantity_sent - received) }
        reasons ? row.merge(reason: item.difference_reason) : row
      end
      { id: transfer.id, from: location(transfer.from_location), to: location(transfer.to_location), status: transfer.status,
        sent_at: transfer.sent_at.iso8601, received_at: transfer.received_at&.iso8601, items: items }
    end

    # Ajuste (contrato §6/H2/H12): `{ id, location, lot, kind, status, quantity,
    # counted_quantity|null, balance_at_request, reason, requested_by: { user_id,
    # name }, decided_by: { user_id, name }|null, decision_reason|null, created_at }`,
    # sem envelope. `quantity` é o EFEITO no estoque, com sinal (o delta da
    # contagem; perda e vencimento saem negativos, como o movimento). O motivo é
    # texto livre: só no corpo. `adjustment` carrega o local (com a unidade), o
    # lote e os dois usuários (com o perfil, para o nome).
    def adjustment(adjustment, catalog:)
      decider = adjustment.decided_by_user
      { id: adjustment.id, location: location(adjustment.stock_location), lot: lot(adjustment.stock_lot, catalog: catalog),
        kind: adjustment.kind, status: adjustment.status, quantity: Quantity.dump(adjustment.quantity),
        counted_quantity: adjustment.counted_quantity && Quantity.dump(adjustment.counted_quantity),
        balance_at_request: Quantity.dump(adjustment.balance_at_request), reason: adjustment.reason,
        requested_by: person(adjustment.requested_by_user), decided_by: decider && person(decider),
        decision_reason: adjustment.decision_reason, created_at: adjustment.created_at.iso8601 }
    end

    # { user_id, name } (o nome é o do perfil profissional; sem perfil, null).
    def person(user) = { user_id: user.id, name: user.professional&.professional_name }

    # Os cinco parâmetros da cidade, como o contrato §3.
    def settings(setting) = Catalog::SETTING_RANGES.keys.index_with { |key| setting.public_send(key) }

    # Itens do catálogo da plataforma por id, numa consulta só.
    def catalog_for(ids) = MedicationCatalogItem.where(id: ids.compact.uniq).index_by(&:id)
  end
end
