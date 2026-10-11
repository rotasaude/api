require "rails_helper"

# ADR 0034: o catálogo da plataforma ganha a marca de anticonvulsivante
# (Portaria 344, art. 59: até 6 meses), as listas Anvisa aceitam o tipo
# anticonvulsant, e a última conversa com o SNCR fica registrada por alvo.
RSpec.describe "Plataforma do 19d" do
  def savepoint(&) = PlatformRecord.transaction(requires_new: true, &)

  it "item do catálogo nasce sem a marca de anticonvulsivante" do
    item = import_test_catalog!.values.first
    expect(item.anticonvulsant).to be(false)
  end

  it "a lista aceita o tipo anticonvulsant, sem lista da Portaria" do
    release = AnvisaListRelease.create!(imported_by: "rspec", imported_at: Time.current, status: "importing",
                                        source_sha256: "a" * 64, sources: {})
    row = AnvisaListSubstance.create!(release_id: release.id, kind: "anticonvulsant", substance: "CARBAMAZEPINA",
                                      substance_key: "CARBAMAZEPINA", controlled_list: nil)
    expect(row).to be_persisted
    expect { savepoint { AnvisaListSubstance.create!(release_id: release.id, kind: "anticonvulsant", substance: "X", substance_key: "X", controlled_list: "C1") } }
      .to raise_error(ActiveRecord::CheckViolation)
    expect { savepoint { AnvisaListSubstance.create!(release_id: release.id, kind: "outro", substance: "Y", substance_key: "Y") } }
      .to raise_error(ActiveRecord::CheckViolation)
  end

  it "SncrCheck guarda a última conversa por alvo e nunca derruba quem chamou" do
    SncrCheck.where(target: %w[real simulated]).delete_all
    SncrCheck.record!("real", ok: false, at: 2.minutes.ago)
    SncrCheck.record!("real", ok: true)
    expect(SncrCheck.last("real")).to have_attributes(last_check_ok: true)
    expect(SncrCheck.last("simulated")).to be_nil
    expect { SncrCheck.record!("outro", ok: true) }.not_to raise_error
    expect(SncrCheck.last("outro")).to be_nil
  end
end
