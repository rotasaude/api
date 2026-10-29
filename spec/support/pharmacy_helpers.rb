# Módulo 27a (ADR 0045): cidade com os documentos clínicos e a farmácia
# ligados, o catálogo de teste importado e os parâmetros padrão; locais,
# equipe com papel e vínculo ao local, itens do catálogo e lote com saldo.
# Tudo avaliado só na chamada.
module PharmacyHelpers
  def pharmacy_city!(enabled: true)
    city = documents_city!
    import_test_catalog!
    Platform::Features.set!(city: city, key: "pharmacy", enabled: enabled, maintainer: ledi_maintainer!)
    # O dump (db/city_schema.rb) não leva linha: os parâmetros padrão que a
    # migração insere entram aqui, como os prazos da regulação.
    PharmacySetting.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  def pharmacy_admin!
    User.joins(:memberships).merge(Membership.active.where(role: "municipal_admin")).first ||
      staff_with("admin-farmacia-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
  end

  def central_location!
    StockLocation.find_by(kind: "central") ||
      StockLocation.create!(kind: "central", name: "Central de Abastecimento Farmacêutico", updated_by_user: pharmacy_admin!)
  end

  def unit_location!(unit = create_unit("UBS Farmácia #{SecureRandom.hex(2)}"))
    unit.update!(dispenses: true)
    StockLocation.create!(kind: "unit", name: "Farmácia #{unit.name}", health_unit: unit, updated_by_user: pharmacy_admin!)
  end

  # Usuário com a Membership do papel e o vínculo ativo ao local. O
  # farmacêutico tem vínculo profissional com CBO 2234* (Desvio 3).
  def pharmacy_staff!(location, role)
    user = if role == "pharmacist"
             screener!(location.health_unit || create_unit("UBS Farmacêutico #{SecureRandom.hex(2)}"), cbo: "223405",
                       email: "farmaceutico-#{SecureRandom.hex(3)}@cidade.gov.br")
           else
             staff_with("#{role.tr('_', '-')}-#{SecureRandom.hex(3)}@cidade.gov.br")
           end
    Membership.create!(user: user, role: role, granted_at: Time.current)
    StockLocationStaff.create!(stock_location: location, user: user, role: role, granted_by_user: pharmacy_admin!, granted_at: Time.current)
    user
  end

  def losartana = catalog_item(268_856)
  def amoxicilina = catalog_item(271_089)
  def fluoxetina = controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1")
  def diazepam = controlled_item!(code: 9_900_002, ingredient: "DIAZEPAM", list: "B1", strength: "10 mg")

  # Lote com saldo no local, pelo caminho real (Pharmacy::RecordEntry): a
  # abertura quando o item ainda não tem abertura no local, senão uma nota. O
  # LOTE nasce aqui, com a unidade "comprimido" (a que os specs das Tasks 3 e 4
  # esperam, qualquer que seja a regra do YAML do item); o comando só o
  # reaproveita. Lote já vencido (testes de vencimento) entra com o relógio do
  # comando no dia da validade, que ainda vale: o movimento fica datado nele.
  def stocked_lot!(location, item:, quantity: "30", lot_number: "L#{SecureRandom.hex(3).upcase}", expires_on: Time.zone.today + 180, by: nil)
    by ||= pharmacy_admin!
    expires_on = expires_on.to_date
    lot = StockLot.find_by(catalog_item_id: item.id, lot_number: lot_number)
    if lot && lot.expires_on != expires_on
      raise ArgumentError, "stocked_lot!: lote #{lot_number} já gravado com outro expires_on (#{lot.expires_on})"
    end
    lot ||= StockLot.create!(catalog_item_id: item.id, catmat_code: item.catmat_code, lot_number: lot_number, expires_on: expires_on,
                             dispensing_unit: "comprimido", created_by_user: by)
    opening = !StockOpening.exists?(stock_location_id: location.id, catalog_item_id: item.id)
    result = Pharmacy::RecordEntry.call(
      location: location, kind: opening ? "opening" : "invoice",
      document: { "number" => "NF-#{SecureRandom.hex(3)}", "supplier" => "Distribuidora de Teste" },
      items: [ { "catalog_item_id" => item.id, "lot_number" => lot_number, "expires_on" => expires_on.iso8601, "quantity" => quantity.to_s } ],
      by: by, catalog: { item.id => item }, now: [ Time.current, expires_on.in_time_zone ].min
    )
    raise ArgumentError, "stocked_lot!: #{result.reason} #{result.details.inspect}" if result.failure?

    lot
  end

  def balance_of(location, lot) = StockMovement.where(stock_location_id: location.id, stock_lot_id: lot.id).sum(:quantity)
end

RSpec.configure { |c| c.include PharmacyHelpers }
