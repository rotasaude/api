require "rails_helper"

# ADR 0031 (spec §4): consulta finalizada, adendos em ordem, unidade,
# profissional (nome, conselho, CBO), paciente (nome de exibição, CPF,
# nascimento) e espaço para assinatura e carimbo. Review Focus 2: texto que a
# fonte não tem nunca derruba o impresso.
RSpec.describe Consultations::Print do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit("UBS Jardim das Flores") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1, social_name: "Mariana", age: 46) }

  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n").squeeze(" ")

  it "traz o registro, o paciente, o profissional, os adendos em ordem e a assinatura" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "primeiro adendo aqui", text: "Texto UM")
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "segundo adendo aqui", text: "Texto DOIS")
    text = text_of(described_class.call(consultation.reload))
    professional = doctor.professional
    cpf = citizen.cpf.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4')
    expect(text).to include("UBS Jardim das Flores", "Mariana", cpf, Date.iso8601(citizen.birth_date).strftime("%d/%m/%Y"),
                            professional.professional_name, "#{professional.council}-#{professional.council_state}",
                            "225125", "Refere sede e poliúria", "Diabetes mellitus tipo 2", "Metformina",
                            "T90", "Retorno para consulta agendada", "0202010503", "Assinatura e carimbo")
    expect(text.index("Texto UM")).to be < text.index("Texto DOIS")
    expect(text).not_to include("Maria Aparecida") # nome de exibição = social
  end

  it "caracteres fora da fonte, quebras e 20.000 caracteres não derrubam o impresso (Review Focus 2)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                           subjective: "PA ≥ 140 😷 “aspas” \r\nlinha nova", plan: "y" * 20_000)
    bytes = described_class.call(consultation)
    expect(bytes).to start_with("%PDF")
    expect(text_of(bytes)).to include("PA ? 140 ? \"aspas\"").or include("PA ? 140 ? “aspas”")
    expect(described_class.safe("ç ã é ≥ 🙂")).to eq("ç ã é ? ?")
  end

  it "rascunho ou paciente sem nome não imprime" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect { described_class.call(draft) }.to raise_error(described_class::NotPrintable)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    consultation.patient.update_columns(full_name: nil, social_name: nil)
    expect { described_class.call(consultation.reload) }.to raise_error(described_class::NotPrintable)
  end
end
