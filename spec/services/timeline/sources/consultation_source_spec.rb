require "rails_helper"

# Módulo 28 (F-28.7; contrato §16 O12, api D9): a consulta odontológica na
# linha do tempo — título pronto, procedimentos só pelo nome SIGTAP (nunca
# dente, face nem quantidade) e `detail_ref.kind = "dental"`.
RSpec.describe Timeline::Sources::ConsultationSource do
  before do
    dental_city!
    timeline_city!(documents: true)
  end

  let(:unit) { create_unit("UBS Centro") }
  let(:citizen) { verified_citizen!(61) }
  let(:person) { Timeline::Person.for_cpf(citizen.cpf) }

  def entries(source) = source.entries(person: person, before: nil, limit: 50, from: nil, to: nil)

  it "consultation odontológica: título, procedimentos só pelo nome SIGTAP (sem dente nem face) e detail_ref com kind dental" do
    dentist = dentist!(unit)
    finalized_dental!(unit: unit, by: dentist, citizen: citizen)
    entry = entries(Timeline::Sources::ConsultationSource).sole
    expect(entry.title).to eq("Consulta odontológica")
    expect(entry.summary).to include("D82", DentalHelpers::SIGTAP.fetch("0307010031"))
    expect(entry.summary).not_to match(/\b11\b|\bM\b|quantidade/i)
    expect(entry.detail_ref).to eq(type: "consultation", id: entry.source_id, kind: "dental")
    expect(entry.citizen[:title]).to eq("Consulta odontológica com #{dentist.professional.professional_name}")
  end

  it "consultation odontológica: o registro inicial se chama Exame odontológico inicial" do
    dentist = dentist!(unit)
    first = dental_consultation!(unit: unit, by: dentist, citizen: citizen, baseline: true)
    Consultations::SaveDraft.call(consultation: first, by: dentist,
                                  params: { "dental" => { "findings" => [ { "tooth" => 16, "situation" => "caries" } ] } })
    expect(Consultations::Finalize.call(consultation: first.reload, outcome_params: { "outcome" => "discharged" }, by: dentist)).to be_ok
    entry = entries(Timeline::Sources::ConsultationSource).sole
    expect([ entry.title, entry.detail_ref[:kind] ]).to eq([ "Exame odontológico inicial", "dental" ])
  end
end
