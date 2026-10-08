# spec/commands/consultations/save_draft_spec.rb
require "rails_helper"

# ADR 0031 (spec §4): autosave só do autor e só do rascunho; só o que veio
# muda. Review Focus 3: entrada ruim não grava nada.
RSpec.describe Consultations::SaveDraft do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def save(params, by: doctor) = described_class.call(consultation: consultation, params: params, by: by)

  it "grava texto, sinais, tipo e itens; um autosave parcial não apaga o resto" do
    expect(save(draft_body)).to be_ok
    expect(save({ "plan" => "Metformina 850 mg" })).to be_ok
    consultation.reload
    expect(consultation.slice(:subjective, :plan, :systolic, :care_type))
      .to eq("subjective" => "Refere sede e poliúria há dois meses", "plan" => "Metformina 850 mg", "systolic" => 130, "care_type" => 5)
    expect(consultation.draft_items.keys).to match_array(%w[evaluated_problems conducts exam_requests])
    expect(save({ "conducts" => [ 9 ] })).to be_ok
    expect(consultation.reload.draft_items["conducts"]).to eq([ 9 ])
    expect(consultation.draft_items["evaluated_problems"].sole["code"]).to eq("T90")
  end

  it "entrada inválida não grava nada (nem o texto válido do mesmo corpo)" do
    save(draft_body)
    result = save({ "subjective" => "novo texto", "vitals" => { "systolic" => 120 } })
    expect([ result.reason, result.details ]).to eq([ :implausible_vital, { field: "diastolic" } ])
    expect(consultation.reload.subjective).to eq("Refere sede e poliúria há dois meses")
  end

  it "só o autor; só rascunho" do
    colleague = doctor!(unit, cbo: "223505")
    expect(save({ "plan" => "x" }, by: colleague).reason).to eq(:not_author)
    consultation.update!(status: "finalized", finalized_at: Time.current, care_type: 5, draft_items: {})
    expect(save({ "plan" => "depois" }).reason).to eq(:not_draft)
  end
end
