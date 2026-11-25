require "csv"
require_relative "pharmacy_crew"
require_relative "vaccination_crew"
require_relative "vector_control_crew"

# Semente de dev do módulo 27b (envio à BNAFAR), para a prova contra o
# SI-BNAFAR simulado. Dev é fictício mas imita o real: em Curitiba (só nela),
# sobre o estoque que o PharmacyCrew, o VaccinationCrew, o VectorControlCrew e o
# ZoonosesCrew já deixaram, tudo pelos comandos do módulo:
#
#   o quê                                         onde / como
#   três apresentações do OBM (AMPP)              plataforma: duas com o VMP de LOSARTANA e
#                                                 METFORMINA (vmp_code gravado só se o item
#                                                 está em branco) e uma sem item (lista de revisão)
#   CNES fictício nos dois centrais               Pharmacy::SaveLocation e
#                                                 Vaccination::UpdateColdChainCentral (nunca o CNES
#                                                 de uma unidade; o da UVZ fica em branco de propósito)
#   credencial `bnafar`                           nos dois ambientes (homologation e production),
#                                                 com usuário e senha de dev; o simulado aceita
#                                                 qualquer Basic
#   interruptores                                 bnafar, bnafar_medications e bnafar_mock LIGADOS;
#                                                 bnafar_vaccines e bnafar_vector_supplies ficam como
#                                                 estão (desligados, para o `domain_off`)
#   metade dos lotes (medicamento e insumo)       Bnafar::CompleteLot (preço, fabricante, ANVISA,
#                                                 programa e o AMPP quando o item tem VMP); um deles
#                                                 com fabricante internacional; a outra metade fica
#                                                 incompleta (`lot_incomplete`)
#   `catmat_code` em um produto vetorial          o piriproxifeno (os demais ficam sem:
#                                                 `product_without_code`)
#   um lote de saldo fracionado                   uma nota de 12,5 g de piriproxifeno na UVZ
#                                                 (`fractional_balance`)
#   tmp/ok.csv                                    planilha de saldo inicial de exemplo (cabeçalho
#                                                 de OpeningImports::Reader::HEADER) cujas linhas
#                                                 passam na conferência da cidade semeada
#
# As vacinas ficam sem completar: o YAML de imunobiológicos de produção não traz
# CNPJ de fabricante nem VMP do OBM (o lote da vacina nunca fecha o envio).
#
# Pendências que a semente deixa (Bnafar::Pendencies.current): todos os códigos,
# salvo `exit_type_missing` e `lot_number_too_long`. Idempotente: cada peça é
# achada por chave estável antes de criar; semear de novo não grava nada. Roda
# depois do PharmacyCrew, do VaccinationCrew, do VectorControlCrew e do
# ZoonosesCrew. Só dev: nunca grava segredo de staging ou de produção.
class BnafarCrew
  DEV_MAINTAINER = "dev@local".freeze
  CSV_PATH = Rails.root.join("tmp/ok.csv")

  # Usuário e senha de dev da BNAFAR (o simulado aceita qualquer Basic). Os dois
  # ambientes levam a mesma credencial de dev.
  CREDENTIAL = { "username" => "bnafar-dev", "password" => "dev-bnafar-senha" }.freeze
  # Fictícios, com o formato certo e fora de qualquer unidade semeada.
  CENTRAL_CNES = "9100011".freeze
  COLD_CHAIN_CNES = "9100029".freeze
  FEATURES = %w[bnafar bnafar_medications bnafar_mock].freeze

  # AMPP e VMP fictícios (`[@0-9A-Za-z]{1,25}`); as duas primeiras são dos itens
  # LOSARTANA e METFORMINA do PharmacyCrew, a última tem um CATMAT que nenhum
  # item da plataforma usa.
  PRESENTATIONS = [
    { ampp_code: "DEVAMPP0000001", vmp_code: "DEVVMP0000001", catmat: PharmacyCrew::ITEMS.fetch(:losartana).fetch(:code),
      anvisa: "1000000000011", description: "LOSARTANA POTASSICA 50 MG COMPRIMIDO CAIXA COM 30 (DEV)" },
    { ampp_code: "DEVAMPP0000002", vmp_code: "DEVVMP0000002", catmat: PharmacyCrew::ITEMS.fetch(:metformina).fetch(:code),
      anvisa: "1000000000022", description: "CLORIDRATO DE METFORMINA 850 MG COMPRIMIDO CAIXA COM 30 (DEV)" },
    { ampp_code: "DEVAMPP0000003", vmp_code: "DEVVMP0000003", catmat: 999_901, anvisa: "1000000000033",
      description: "APRESENTACAO FICTICIA SEM ITEM NO CATALOGO (DEV)" }
  ].freeze

  VECTOR_CATMAT = 450_001
  PRICES = { medication: 85, vector_control: 1250 }.freeze
  PROGRAMS = { Stock::Domain::MEDICATION => "AFB", Stock::Domain::VECTOR_CONTROL => "END" }.freeze
  DEFAULT_ANVISA = { Stock::Domain::MEDICATION => "1000000000100", Stock::Domain::VECTOR_CONTROL => "30000000011" }.freeze
  INTERNATIONAL_NAME = "Pharma International Dev Ltd".freeze
  IUM = "BNFDEVIUM000001".freeze
  FRACTION = { number: "000874999", supplier: "Distribuidora de Insumos Sanitários Paraná Ltda.", lot: "PPF2611X", quantity: "12.5", months: 18 }.freeze

  # A planilha de exemplo: linhas de itens SEM abertura no local (a conferência
  # recusa `opening_exists`). valor em reais com vírgula.
  SHEET = [ { where: :unit, item: :losartana, lot: "OK2611-LOS", quantity: 120, price: "0,42", program: "HIPERTEN", ampp: 0 },
            { where: :unit, item: :metformina, lot: "OK2611-MET", quantity: 200, price: "0,31", program: "HIPERTEN", ampp: 1 },
            { where: :central, item: :free, lot: "OK2611-OUT", quantity: 80, price: "1,10", program: "AFB", ampp: nil } ].freeze

  class << self
    def seed_platform!
      guard_environment!
      created = PRESENTATIONS.count do |spec|
        item = MedicationCatalogItem.find_by(catmat_code: spec[:catmat], status: "active")
        vmp = item&.vmp_code.presence || spec[:vmp_code]
        next false if ObmPresentation.exists?(ampp_code: spec[:ampp_code])

        ObmPresentation.create!(ampp_code: spec[:ampp_code], vmp_code: vmp, catmat_code: spec[:catmat], anvisa_registration: spec[:anvisa],
                                description: spec[:description], active: true, imported_at: Time.current)
      end
      linked = PRESENTATIONS.first(2).count do |spec|
        MedicationCatalogItem.where(catmat_code: spec[:catmat], status: "active", vmp_code: nil).update_all(vmp_code: spec[:vmp_code]).positive?
      end
      { presentations: created, linked: linked }
    end

    def seed_current_city(slug:)
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] bnafar: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      place = prerequisites!(slug)
      city = City.find(Current.city.id)
      locations!(place)
      credentials!(place[:admin], city)
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      CityCatalog.reset_cache!
      vector_catmat!(place[:coordinator])
      fraction!(place)
      lots = complete_lots!(place[:admin])
      csv = sheet!(place)

      { switch: Bnafar::Gate.usable?(city) ? "ligado (#{Bnafar::Gate::KEY}, simulado)" : "ligado, não utilizável",
        central_cnes: place[:central].reload.cnes, cold_chain_cnes: place[:cold_chain].reload.cnes, lots: lots,
        presentations: ObmPresentation.where(ampp_code: PRESENTATIONS.map { |spec| spec[:ampp_code] }).count, csv: csv }
    end

    # Só dev: a credencial é a de dev (nunca a de staging nem a de produção).
    def summary_lines(result)
      head = "[seeds] bnafar #{result[:switch]}"
      return [ head ] unless result[:lots]

      lots = result[:lots]
      [ "#{head}; CNES central #{result[:central_cnes]}, rede de frio #{result[:cold_chain_cnes]}",
        "[seeds]               lotes: #{lots[:complete]} completos (#{lots[:international]} internacional), #{lots[:pending]} pendentes; " \
        "#{result[:presentations]} apresentações do OBM",
        "[seeds]               credencial bnafar (dev; homologation e production): #{CREDENTIAL['username']} / #{CREDENTIAL['password']}",
        "[seeds]               planilha de exemplo: #{result[:csv]}" ]
    end

    private

    def guard_environment!
      raise "semente do bnafar: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, central_cnes: nil, cold_chain_cnes: nil, lots: nil, presentations: 0, csv: nil }

    def check!(result, what)
      raise "semente do bnafar: #{what} recusado (#{result.reason} #{result.details})" if result.failure?

      result
    end

    # --- pré-requisitos -----------------------------------------------------------

    def prerequisites!(slug)
      central = StockLocation.find_by(kind: "central") || raise("semente do bnafar: sem o almoxarifado central — rode o PharmacyCrew (db:seed) antes")
      cold_chain = StockLocation.find_by(kind: "cold_chain_central") ||
                   raise("semente do bnafar: sem a rede de frio — rode o VaccinationCrew (db:seed) antes")
      unit = StockLocation.find_by!(kind: "unit", name: PharmacyCrew::PHARMACY)
      uvz = StockLocation.find_by(kind: "vector_control", name: VectorControlCrew::LOCATION_NAME)
      raise "semente do bnafar: sem o local de insumos da UVZ — rode o VectorControlCrew (db:seed) antes" unless uvz

      { central: central, cold_chain: cold_chain, unit: unit, uvz: uvz,
        admin: User.find_by!(email_address: "admin@#{slug}.demo"),
        coordinator: User.find_by!(email_address: "#{VectorControlCrew::STAFF.dig(:coordinator, :email_prefix)}@#{slug}.demo"),
        keeper: User.find_by!(email_address: "#{VectorControlCrew::STAFF.dig(:keeper, :email_prefix)}@#{slug}.demo") }
    end

    # --- CNES e credencial --------------------------------------------------------

    def locations!(place)
      if place[:central].cnes.blank?
        check!(Pharmacy::SaveLocation.call(attrs: { "cnes" => CENTRAL_CNES }, by: place[:admin], location: place[:central]), "CNES do central")
      end
      if place[:cold_chain].cnes.blank?
        check!(Vaccination::UpdateColdChainCentral.call(attrs: { "cnes" => COLD_CHAIN_CNES }, by: place[:admin]), "CNES da rede de frio")
      end
      place.values_at(:central, :cold_chain).each(&:reload)
    end

    # Uma por ambiente; a que já existe (trocada pela prova) fica como está.
    def credentials!(admin, city)
      Bnafar::Catalog::ENVIRONMENTS.each do |environment|
        next if IntegrationCredential.exists?(kind: "bnafar", environment: environment)

        check!(Integrations::SetCredential.call(kind: "bnafar", secret: CREDENTIAL, by: admin, city: city, environment: environment),
               "credencial bnafar (#{environment})")
      end
    end

    # --- catálogo e estoque -------------------------------------------------------

    # O CATMAT de um produto só; os demais ficam sem (`product_without_code`).
    def vector_catmat!(coordinator)
      product = VectorProduct.find_by("lower(code) = lower(?)", VectorControlCrew::PRODUCTS.dig(:pyriproxyfen, "code"))
      return if product.nil? || VectorProduct.where.not(catmat_code: nil).exists?

      check!(VectorControl::SaveProduct.call(params: { "catmat_code" => VECTOR_CATMAT }, by: coordinator, product: product), "CATMAT do produto")
    end

    # Um lote de saldo fracionado (12,5 g), que não fecha em unidade BNAFAR.
    def fraction!(place)
      return if StockEntry.exists?(stock_location_id: place[:uvz].id, kind: "invoice", document_number: FRACTION[:number])

      product = VectorProduct.find_by("lower(code) = lower(?)", VectorControlCrew::PRODUCTS.dig(:pyriproxyfen, "code"))
      return unless product

      today = Time.zone.today
      item = { "vector_product_id" => product.id, "lot_number" => FRACTION[:lot], "expires_on" => (today >> FRACTION[:months]).iso8601,
               "manufacturer" => "Fornecedor do Ministério da Saúde", "quantity" => FRACTION[:quantity] }
      document = { "number" => FRACTION[:number], "supplier" => FRACTION[:supplier] }
      check!(Pharmacy::RecordEntry.call(location: place[:uvz], kind: "invoice", document: document, items: [ item ], by: place[:keeper], catalog: {},
                                        now: Time.current - 1.minute), "nota fiscal #{FRACTION[:number]}")
    end

    # Metade dos lotes de cada domínio completável (de dois em dois, por número):
    # o primeiro de medicamento é o do fabricante internacional. A outra metade
    # fica incompleta. Lote já com preço fica como está. -> { complete:, pending:, international: }
    def complete_lots!(admin)
      completable = [ Stock::Domain::MEDICATION, Stock::Domain::VECTOR_CONTROL ]
      chosen = []
      completable.each do |domain|
        lots = StockLot.order(:lot_number, :id).select { |lot| Stock::Domain.of_lot(lot) == domain }
        chosen.concat(lots.each_slice(2).map(&:first))
      end
      chosen.each_with_index do |lot, index|
        next if lot.unit_price_cents

        complete!(lot, admin, international: index.zero?, sequence: index)
      end
      total = StockLot.all.count { |lot| completable.include?(Stock::Domain.of_lot(lot)) }
      done = StockLot.all.count { |lot| completable.include?(Stock::Domain.of_lot(lot)) && lot.unit_price_cents }
      { complete: done, pending: total - done, international: StockLot.where(manufacturer_international: true).count }
    end

    def complete!(lot, admin, international:, sequence:)
      domain = Stock::Domain.of_lot(lot)
      attrs = { "unit_price_cents" => PRICES.fetch(domain.to_sym), "health_program" => PROGRAMS.fetch(domain) }
      presentation = presentation_of(lot)
      attrs["anvisa_registration"] = presentation&.anvisa_registration || DEFAULT_ANVISA.fetch(domain)
      attrs["ampp_code"] = presentation.ampp_code if presentation
      if international
        attrs.merge!("manufacturer_international" => true, "manufacturer" => lot.manufacturer.presence || INTERNATIONAL_NAME)
      else
        attrs["manufacturer_cnpj"] = Cnpj.with_check_digits(format("9000%08d", sequence + 1))
      end
      attrs["ium"] = [ IUM ] if sequence == 1 && domain == Stock::Domain::MEDICATION
      check!(Bnafar::CompleteLot.call(lot: lot, attrs: attrs, expected_version: lot.bnafar_version, by: admin), "dados BNAFAR do lote #{lot.lot_number}")
    end

    # A apresentação da semente do VMP do item do lote (só medicamento com VMP).
    def presentation_of(lot)
      return nil unless Stock::Domain.of_lot(lot) == Stock::Domain::MEDICATION

      vmp = MedicationCatalogItem.where(id: lot.catalog_item_id).pick(:vmp_code)
      vmp && ObmPresentation.active.where(ampp_code: PRESENTATIONS.map { |spec| spec[:ampp_code] }).find_by(vmp_code: vmp)
    end

    # --- planilha de exemplo ------------------------------------------------------

    # Reescreve só se mudou. -> o caminho (String), ou nil se não há onde.
    def sheet!(place)
      today = Time.zone.today
      rows = SHEET.filter_map { |spec| sheet_row(spec, place, today) }
      return nil if rows.empty?

      text = CSV.generate(col_sep: ";", row_sep: "\n") do |csv|
        csv << OpeningImports::Reader::HEADER
        rows.each { |row| csv << row }
      end
      FileUtils.mkdir_p(File.dirname(CSV_PATH))
      File.write(CSV_PATH, text) unless File.exist?(CSV_PATH) && File.read(CSV_PATH) == text
      CSV_PATH.to_s
    end

    def sheet_row(spec, place, today)
      location = place.fetch(spec[:where])
      cnes = location.bnafar_cnes
      item = sheet_item(spec[:item])
      return nil if cnes.blank? || item.nil?

      presentation = spec[:ampp] && ObmPresentation.find_by(ampp_code: PRESENTATIONS.fetch(spec[:ampp])[:ampp_code])
      return nil if spec[:ampp] && presentation.nil?

      [ cnes, "medicamento", item.catmat_code, presentation&.ampp_code, spec[:lot], (today + 420).iso8601, spec[:quantity], spec[:price],
        Cnpj.with_check_digits(format("9100%08d", spec[:quantity])), presentation&.anvisa_registration || DEFAULT_ANVISA.fetch(Stock::Domain::MEDICATION),
        spec[:program] ]
    end

    # O item do catálogo da linha: os dois da semente do 27a (com VMP) ou um item
    # ativo sem VMP e sem abertura no central (não exige AMPP).
    def sheet_item(key)
      return MedicationCatalogItem.find_by(catmat_code: PharmacyCrew::ITEMS.fetch(key)[:code], status: "active") unless key == :free

      stocked = StockOpening.where.not(catalog_item_id: nil).pluck(:catalog_item_id)
      MedicationCatalogItem.where(status: "active", vmp_code: nil).where.not(id: stocked).where.not(catmat_code: nil).order(:catmat_code).first
    end
  end
end
