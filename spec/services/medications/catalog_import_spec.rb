# spec/services/medications/catalog_import_spec.rb
require "rails_helper"

# ADR 0033 (spec §3, §9): release com diferença; item estável por código; a
# fonte que falha no meio nunca derruba o catálogo ativo (Review Focus 1).
RSpec.describe Medications::CatalogImport do
  before { Medications::AnvisaImport.call(by: "rspec", dir: anvisa_fixture_dir) }

  def import!(rows = catmat_rows, **stub)
    stub_catmat!(rows, **stub)
    described_class.call(by: "rspec", client: Medications::Catmat::Client.new(sleeper: ->(_) {}))
  end

  it "primeira importação: tudo entra, revisão escondida, marcas Anvisa, auditoria só com contagens" do
    result = import!
    expect(result.payload.slice(:added, :changed, :removed)).to eq(added: 17, changed: 0, removed: 0)
    release = result.payload[:release]
    expect(release).to have_attributes(status: "active", items_count: 17, hidden_count: 1, added_count: 17)
    expect(catalog_item(267_778)).to have_attributes(active_ingredient: "PARACETAMOL", strength: "500 MG", dosage_form: "comprimido",
                                                     parse_status: "ok", hidden: false, status: "active", obm_code: nil)
    expect(catalog_item(384_258)).to have_attributes(parse_status: "review", hidden: true, review_reason: "manipulated")
    expect(catalog_item(271_089)).to have_attributes(antimicrobial: true, controlled: false)
    expect(catalog_item(273_009)).to have_attributes(controlled: true, controlled_list: "C1")
    expect(catalog_item(267_778).search_text).to include("PARACETAMOL 500 MG COMPRIMIDO")
    expect(PlatformEvent.where(name: "medication_catalog.imported").last.payload)
      .to eq("release_id" => release.id, "added" => 17, "changed" => 0, "removed" => 0)
  end

  it "segunda importação: mudou, saiu e entrou; o id do item não muda; a anterior é substituída" do
    first = import!.payload[:release]
    losartana_id = catalog_item(268_856).id
    rows = catmat_rows.reject { |row| row["codigoItem"] == 267_772 }
    rows.find { |row| row["codigoItem"] == 268_856 }["descricaoItem"] = "LOSARTANA POTÁSSICA, CONCENTRAÇÃO: 50 MG, FORMA FARMACÊUTICA: COMPRIMIDO"
    rows << { "codigoItem" => 267_506, "codigoPdm" => 354, "nomePdm" => "ALBENDAZOL", "descricaoItem" => "ALBENDAZOL, DOSAGEM: 400 MG",
              "statusItem" => true, "dataHoraAtualizacao" => "2021-10-16T09:43:08.030221" }
    WebMock.reset!
    result = import!(rows)
    expect(result.payload.slice(:added, :changed, :removed)).to eq(added: 1, changed: 1, removed: 1)
    expect(first.reload.status).to eq("superseded")
    losartana = catalog_item(268_856)
    expect([ losartana.id, losartana.dosage_form, losartana.first_release_id ]).to eq([ losartana_id, "comprimido", first.id ])
    expect(catalog_item(267_772)).to have_attributes(status: "removed")
    expect(MedicationCatalogItem.prescribable.where(catmat_code: 267_772)).to be_empty
  end

  it "fonte cai no meio → falha inteira, release failed, catálogo ativo intacto (Review Focus 1)" do
    active = import!.payload[:release]
    WebMock.reset!
    result = import!(catmat_rows, pages: { 2 => { status: 503 } })
    expect(result.reason).to eq(:source_unavailable)
    expect(MedicationCatalogRelease.current).to eq(active)
    expect(MedicationCatalogRelease.order(:created_at).last.status).to eq("failed")
    expect(MedicationCatalogItem.where(status: "removed")).to be_empty
  end

  it "fonte encolhe (menos da metade do ativo) → suspicious_drop; total que muda → incomplete_source" do
    import!
    WebMock.reset!
    expect(import!(catmat_rows.first(5)).reason).to eq(:suspicious_drop)
    WebMock.reset!
    expect(import!(catmat_rows, pages: { 2 => { "resultado" => catmat_rows.last(8), "totalRegistros" => 99,
                                                 "totalPaginas" => 2, "paginasRestantes" => 0 } }).reason).to eq(:incomplete_source)
    expect(MedicationCatalogItem.where(status: "removed")).to be_empty
  end

  it "uma importação por vez: outra em andamento → import_in_progress; presa há mais de 1 h não trava" do
    running = MedicationCatalogRelease.create!(imported_by: "outra aba", imported_at: Time.current, status: "importing")
    expect(import!.reason).to eq(:import_in_progress)
    running.update_columns(imported_at: 2.hours.ago)
    WebMock.reset!
    expect(import!).to be_ok
    expect(running.reload.status).to eq("failed")
  end

  it "QUALQUER erro no meio marca a release failed e deixa o catálogo ativo intacto" do
    active = import!.payload[:release]
    WebMock.reset!
    boom = Class.new { def fetch_all = raise(NoMethodError, "undefined method 'x' for nil") }.new
    result = described_class.call(by: "rspec", client: boom)
    expect([ result.reason, result.message ]).to eq([ :import_failed, "NoMethodError" ])
    expect(MedicationCatalogRelease.where(status: "importing")).to be_empty
    expect(MedicationCatalogRelease.order(:created_at).last.status).to eq("failed")
    expect(MedicationCatalogRelease.current).to eq(active)
    expect(MedicationCatalogItem.where(status: "removed")).to be_empty
  end

  it "item malformado depois da leitura: failed, nada muda no catálogo" do
    active = import!.payload[:release]
    bad = Medications::Catmat::Row.new(catmat_code: 1, pdm_code: nil, pdm_name: "X", description: nil, updated_at: nil)
    client = Struct.new(:rows) { def fetch_all = rows }.new(Medications::Catmat::FixtureClient.new(Rails.root.join("db/seeds/medications/catmat-dev.json")).fetch_all + [ bad ])
    expect(described_class.call(by: "rspec", client: client).reason).to eq(:import_failed)
    expect(MedicationCatalogRelease.current).to eq(active)
    expect(MedicationCatalogItem.where(catmat_code: 1)).to be_empty
    expect(MedicationCatalogRelease.where(status: "importing")).to be_empty
  end

  it "o banco recusa duas releases importing ao mesmo tempo (índice único)" do
    MedicationCatalogRelease.create!(imported_by: "a", imported_at: Time.current, status: "importing")
    expect { MedicationCatalogRelease.create!(imported_by: "b", imported_at: Time.current, status: "importing") }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "o FixtureClient importa sem rede (a semente de dev)" do
    client = Medications::Catmat::FixtureClient.new(Rails.root.join("db/seeds/medications/catmat-dev.json"))
    expect(described_class.call(by: "db:seed", client: client)).to be_ok
    expect(WebMock).not_to have_requested(:get, MedicationHelpers::CATMAT_URL)
  end
end
