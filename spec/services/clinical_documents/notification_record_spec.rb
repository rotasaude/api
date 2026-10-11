require "rails_helper"

# Spec §5; contrato §3: o registro da Notificação de papel (talão da VISA) —
# tipo, número do talão, UF da numeração, uma substância das listas A/B do
# tipo certo, posologia e duração (A ≤ 30; B/B2 ≤ 60).
RSpec.describe ClinicalDocuments::Content::NotificationRecord do
  before { documents_city! }

  let(:items) do
    import_test_catalog!
    { morfina: controlled_item!(code: 9_900_010, ingredient: "MORFINA", list: "A1"),
      diazepam: controlled_item!(code: 9_900_003, ingredient: "DIAZEPAM", list: "B1"),
      sibutramina: controlled_item!(code: 9_900_011, ingredient: "SIBUTRAMINA", list: "B2"),
      fluoxetina: controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1") }
  end

  def input(type: "B", item: :diazepam, duration: 30, **over)
    { "notification_type" => type, "paper_number" => "PR-1234567", "numbering_uf" => "PR",
      "item" => { "catalog_item" => { "id" => items.fetch(item).id }, "quantity" => 30, "quantity_unit" => "comprimido",
                  "route" => "oral", "dosage_instructions" => "1 comprimido à noite", "duration_days" => duration } }
      .merge(over.stringify_keys)
  end

  def call(value, role: :physician) = described_class.call(value, role: role, catalog: items.values.index_by(&:id))

  it "grava o conteúdo do contrato §3" do
    content = call(input).payload[:content]
    expect(content).to include("notification_type" => "B", "paper_number" => "PR-1234567", "numbering_uf" => "PR")
    expect(content["item"]).to include("quantity" => 30, "route" => "oral", "duration_days" => 30,
                                       "catalog_item" => include("id" => items[:diazepam].id))
  end

  it "item fora das listas A/B, tipo errado, duração além do limite" do
    expect(call(input(item: :fluoxetina)).reason).to eq(:item_not_in_notification_list)
    expect(call(input(type: "A", item: :diazepam)).reason).to eq(:notification_type_mismatch)
    expect(call(input(type: "B", item: :morfina)).reason).to eq(:notification_type_mismatch)
    expect(call(input(type: "B2", item: :sibutramina, duration: 60))).to be_ok
    expect(call(input(type: "A", item: :morfina, duration: 31)).reason).to eq(:duration_exceeded)
    expect(call(input(type: "B", duration: 61)).reason).to eq(:duration_exceeded)
  end

  it "campos inválidos com o nome; só médico e dentista" do
    expect(call(input(type: "C")).details).to eq(field: "notification_type")
    expect(call(input(paper_number: "")).details).to eq(field: "paper_number")
    expect(call(input(paper_number: "x" * 31)).details).to eq(field: "paper_number")
    expect(call(input(numbering_uf: "XX")).details).to eq(field: "numbering_uf")
    expect(call(input(duration: nil)).details).to eq(field: "item.duration_days")
    expect(call(input, role: :nurse).reason).to eq(:cbo_not_allowed)
    expect(call(input, role: :dentist)).to be_ok
  end
end
