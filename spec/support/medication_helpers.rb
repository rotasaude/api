# spec/support/medication_helpers.rb
# Catálogo de medicamentos (ADR 0033): a API do CATMAT servida por WebMock com
# o recorte REAL de dev (db/seeds/medications/catmat-dev.json), paginado como a
# API; as listas Anvisa de teste (spec/fixtures/medications/anvisa); e o
# catálogo importado pelo caminho real (Medications::AnvisaImport +
# Medications::CatalogImport).
module MedicationHelpers
  CATMAT_URL = %r{\Ahttps://dadosabertos\.compras\.gov\.br/modulo-material/4_consultarItemMaterial}

  def catmat_rows = JSON.parse(File.read(Rails.root.join("db/seeds/medications/catmat-dev.json")))

  # pages: substitui páginas inteiras ({ 2 => { status: 503 } } ou { 2 => body }).
  def stub_catmat!(rows = catmat_rows, per_page: 9, total: rows.size, pages: {})
    slices = rows.each_slice(per_page).to_a
    stub_request(:get, CATMAT_URL).to_return do |request|
      page = Integer(URI.decode_www_form(URI(request.uri.to_s).query).to_h.fetch("pagina"))
      override = pages[page]
      next override if override.is_a?(Hash) && override.key?(:status)

      body = override || { "resultado" => slices[page - 1] || [], "totalRegistros" => total,
                           "totalPaginas" => slices.size, "paginasRestantes" => [ slices.size - page, 0 ].max }
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  def anvisa_fixture_dir = Rails.root.join("spec/fixtures/medications/anvisa")

  # Listas de teste + o recorte de dev, pelo caminho real. Idempotente no exemplo.
  def import_test_catalog!
    unless AnvisaListRelease.current
      result = Medications::AnvisaImport.call(by: "rspec", dir: anvisa_fixture_dir)
      raise "listas não importadas: #{result.reason} #{result.message}" if result.failure?
    end
    unless MedicationCatalogRelease.current
      client = Medications::Catmat::FixtureClient.new(Rails.root.join("db/seeds/medications/catmat-dev.json"))
      result = Medications::CatalogImport.call(by: "rspec", client: client)
      raise "catálogo não importado: #{result.reason} #{result.message}" if result.failure?
    end
    MedicationCatalogItem.all.index_by(&:catmat_code)
  end

  def catalog_item(code) = MedicationCatalogItem.find_by!(catmat_code: code)
end

RSpec.configure { |c| c.include MedicationHelpers }
