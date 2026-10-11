# spec/support/controlled_prescription_helpers.rb
# Helpers do 19d (receitas controladas). A Task 4 acrescenta os dela aqui.
module ControlledPrescriptionHelpers
  # Item de catálogo sintético (código fora do recorte de dev), com a lista de
  # controle dada; as marcas voltam a ser calculadas por apply_to_catalog!.
  def controlled_item!(code:, ingredient:, list: nil, strength: "200 mg", dosage_form: "COMPRIMIDO")
    release = MedicationCatalogRelease.current || raise("catálogo sem release: chame import_test_catalog! antes")
    MedicationCatalogItem.create!(catmat_code: code, active_ingredient: ingredient, strength: strength, dosage_form: dosage_form,
                                  source_description: "#{ingredient} #{strength}", search_text: ingredient.downcase,
                                  parse_status: "ok", first_release_id: release.id, last_release_id: release.id,
                                  controlled: list.present?, controlled_list: list.presence)
  end
end

RSpec.configure { |c| c.include ControlledPrescriptionHelpers }
