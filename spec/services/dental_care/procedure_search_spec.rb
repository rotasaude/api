require "rails_helper"

# Módulo 28 (ADR 0046; dicionário FAO, #12 procedimentosRealizados): o que a
# FAO aceita — grupos 01 a 04, o subgrupo 08.04 e os do grupo 07 da lista de
# local e quantidade —, sem a escuta inicial (03.01.04.007-9).
RSpec.describe DentalCare::ProcedureSearch do
  it "searchable?: grupos 01–04, subgrupo 0804 e os 07 da lista; nunca o proibido" do
    expect(described_class.searchable?("0101020074")).to be(true)
    expect(described_class.searchable?("0414020138")).to be(true)
    expect(described_class.searchable?("0804010012")).to be(true)
    expect(described_class.searchable?("0701070110")).to be(true)
    expect(described_class.searchable?("0701070153")).to be(true)
    expect(described_class.searchable?("0701010010")).to be(false)
    expect(described_class.searchable?("0801010010")).to be(false)
    expect(described_class.searchable?("0501010010")).to be(false)
    expect(described_class.searchable?("0301040079")).to be(false)
  end
end
