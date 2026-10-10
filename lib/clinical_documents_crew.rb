# Semente de dev do 19c (ADR 0033). Dev é fictício mas imita o real: o
# catálogo vem do RECORTE REAL do CATMAT em db/seeds/medications/catmat-dev.json
# pelo FixtureClient (nunca chama a API externa na semente); as listas Anvisa
# vêm do repositório. Em Curitiba: liga clinical_documents (mantenedor de dev),
# CNPJ fictício com DV válido, REMUME e um protocolo de enfermagem. Idempotente.
# Roda depois do DigitalSignatureCrew.
require_relative "digital_signature_crew"

module ClinicalDocumentsCrew
  DEV_MAINTAINER = DigitalSignatureCrew::DEV_MAINTAINER
  CATALOG = Rails.root.join("db/seeds/medications/catmat-dev.json")
  CNPJ = Cnpj.with_check_digits("760012340001") # 76.001.234/0001-15, fictício
  REMUME = [ 268_856, 267_674, 267_690, 267_747, 271_089, 267_778, 267_203, 267_503, 268_162, 294_887, 267_712, 267_671, 267_772 ].freeze
  PROTOCOL = { "title" => "Saúde da mulher na APS", "number" => "PE-01", "year" => 2026, "valid_from" => "2026-01-01" }.freeze
  PROTOCOL_ITEMS = { 267_503 => [ 30, "comprimido" ], 268_162 => nil, 267_778 => [ 20, "comprimido" ], 267_203 => [ 20, "comprimido" ] }.freeze

  module_function

  def seed_platform!
    anvisa = if AnvisaListRelease.current then "já ativas"
             else Medications::AnvisaImport.call(by: "db:seed").then { |r| r.ok? ? "importadas" : "falhou: #{r.reason}" }
             end
    catalog = if MedicationCatalogRelease.current then "já ativo"
              else Medications::CatalogImport.call(by: "db:seed", client: Medications::Catmat::FixtureClient.new(CATALOG))
                                             .then { |r| r.ok? ? "importado (recorte de dev)" : "falhou: #{r.reason}" }
              end
    { anvisa: anvisa, catalog: catalog }
  end

  def seed_current_city(slug:)
    return { switch: "desligado (só Curitiba liga)" } unless slug == "curitiba"

    maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
    switch = if maintainer
               Platform::Features.set!(city: City.find(Current.city.id), key: "clinical_documents", enabled: true, maintainer: maintainer)
               missing = Platform::Features.missing(City.find(Current.city.id), "clinical_documents")
               missing.empty? ? "ligado" : "ligado, falta: #{missing.join(', ')}"
             else
               "desligado (sem mantenedor)"
             end
    CityProfile.current&.update!(cnpj: CNPJ)
    admin = User.joins(:memberships).merge(Membership.active.where(role: "municipal_admin")).order(:created_at).first
    items = MedicationCatalogItem.where(catmat_code: REMUME + PROTOCOL_ITEMS.keys).index_by(&:catmat_code)
    REMUME.each do |code|
      next unless items[code]

      CityMedication.find_or_create_by!(catalog_item_id: items[code].id) { |row| row.added_by_user = admin }
    end
    unless NursingProtocol.exists?(number: PROTOCOL["number"], year: PROTOCOL["year"])
      params = PROTOCOL.merge("items" => PROTOCOL_ITEMS.filter_map do |code, max|
        items[code] && { "catalog_item_id" => items[code].id, "max_dose" => max && { "quantity" => max[0], "unit" => max[1] } }.compact
      end)
      NursingProtocols::Save.create(params: params, by: admin, catalog: items.values.index_by(&:id))
    end
    { switch: switch, cnpj: CNPJ, remume: CityMedication.count, protocol: NursingProtocol.count }
  end
end
