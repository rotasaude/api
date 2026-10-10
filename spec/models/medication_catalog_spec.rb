# spec/models/medication_catalog_spec.rb
require "rails_helper"

# Catálogo da plataforma (ADR 0033; spec §3): um item estável por código
# CATMAT, nunca apagado (receitas, REMUME e protocolos guardam o id); uma
# release ativa; listas Anvisa por release.
RSpec.describe "Catálogo de medicamentos (plataforma)" do
  # Cada recusa do banco aborta a transação do exemplo; o savepoint isola uma da outra
  # (sem ele o erro seguinte seria InFailedSqlTransaction, não o que se quer provar).
  def refused(&block) = PlatformRecord.transaction(requires_new: true, &block)

  def release!(status: "active")
    MedicationCatalogRelease.create!(source: "catmat_6505", imported_by: "rspec", imported_at: Time.current, status: status,
                                     activated_at: (Time.current if status == "active"))
  end

  def item!(release, code: 268_856, **over)
    MedicationCatalogItem.create!({ catmat_code: code, pdm_code: 8922, source_description: "LOSARTANA POTÁSSICA, DOSAGEM: 50 MG",
                                    active_ingredient: "LOSARTANA POTÁSSICA", strength: "50 MG", unit: "mg",
                                    parse_status: "ok", hidden: false, status: "active", search_text: "LOSARTANA POTASSICA 50 MG",
                                    first_release_id: release.id, last_release_id: release.id }.merge(over))
  end

  it "rótulo, ingredientes e o escopo prescritível" do
    release = release!
    item = item!(release, dosage_form: "comprimido")
    expect(item.label).to eq("LOSARTANA POTÁSSICA 50 MG comprimido")
    expect(item!(release, code: 287_471, active_ingredient: "LOSARTANA POTÁSSICA + HIDROCLOROTIAZIDA").ingredients)
      .to eq([ "LOSARTANA POTÁSSICA", "HIDROCLOROTIAZIDA" ])
    item!(release, code: 384_258, hidden: true, parse_status: "review", review_reason: "manipulated", strength: nil)
    item!(release, code: 999_999, status: "removed")
    expect(MedicationCatalogItem.prescribable.pluck(:catmat_code)).to contain_exactly(268_856, 287_471)
    expect(MedicationCatalogRelease.current).to eq(release)
  end

  it "o banco recusa apagar item, código repetido, obm_code preenchido e duas releases ativas" do
    release = release!
    item = item!(release)
    expect { refused { item.destroy } }.to raise_error(ActiveRecord::StatementInvalid, /never deleted/)
    expect { refused { item!(release) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { refused { item.update_columns(obm_code: "123") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_medication_catalog_items_obm_reserved/)
    expect { refused { release! } }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "release ativa ou substituída não volta; com falha não ativa" do
    failed = release!(status: "failed")
    expect { refused { failed.update!(status: "active", activated_at: Time.current) } }.to raise_error(ActiveRecord::StatementInvalid, /release/)
    active = release!
    expect { refused { active.update!(status: "importing") } }.to raise_error(ActiveRecord::StatementInvalid, /release/)
    active.update!(status: "superseded")
    expect { refused { active.update!(status: "active") } }.to raise_error(ActiveRecord::StatementInvalid, /release/)
  end

  it "listas Anvisa: uma release ativa, substâncias da release em importação" do
    list = AnvisaListRelease.create!(imported_by: "rspec", imported_at: Time.current, status: "importing",
                                     source_sha256: "a" * 64, sources: { "antimicrobials" => "RDC 471/2021" })
    AnvisaListSubstance.create!(release: list, kind: "controlled", substance: "DIAZEPAM", substance_key: "DIAZEPAM",
                                controlled_list: "B1")
    list.update!(status: "active", activated_at: Time.current, antimicrobials_count: 0, controlled_count: 1)
    expect(AnvisaListRelease.current).to eq(list)
    expect { refused { AnvisaListSubstance.create!(release: list, kind: "antimicrobial", substance: "X", substance_key: "X") } }
      .to raise_error(ActiveRecord::StatementInvalid, /being imported/)
  end
end
