require "rails_helper"

# Fix round 1 (minor 6): só o índice do rótulo vira bed_label_taken; qualquer
# outra unicidade relança.
RSpec.describe Psychosocial::SaveBed do
  let!(:city) { psychosocial_city! }
  let(:night) { caps!(modality: "caps_iii") }

  it "rótulo repetido no CAPS → bed_label_taken; outra violação de unicidade relança" do
    described_class.call(attrs: { "health_unit_id" => night.id, "label" => "L1" }, by: psychosocial_admin!)
    result = described_class.call(attrs: { "health_unit_id" => night.id, "label" => "L1" }, by: psychosocial_admin!)
    expect(result.reason).to eq(:bed_label_taken)

    allow_any_instance_of(PsychosocialBed).to receive(:save!) # rubocop:disable RSpec/AnyInstance
      .and_raise(ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint \"other_index\"")
    expect { described_class.call(attrs: { "health_unit_id" => night.id, "label" => "L2" }, by: psychosocial_admin!) }
      .to raise_error(ActiveRecord::RecordNotUnique, /other_index/)
  end
end
