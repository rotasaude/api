require "rails_helper"

# Spec §6.2: a interface Ledi::Ficha e a ficha sintética (só dev/test), uma
# Ficha de Procedimentos com aferição de PA (SIGTAP 0301100039) de um cidadão
# fictício. Nenhuma ficha real nasce no módulo 16.
RSpec.describe Ledi::Fichas::Synthetic do
  let(:attended_at) { Time.zone.parse("2026-10-06 10:00") }
  let(:ficha) do
    described_class.new(cnes: "1234567", ine: "0000123456", professional_cns: "700000000000005", cbo: "225142",
                        attended_at: attended_at, source_id: "f0f0f0f0-0000-4000-8000-000000000001")
  end

  it "cumpre a interface Ledi::Ficha" do
    expect { Ledi::Ficha.assert!(ficha) }.not_to raise_error
    expect(ficha.type).to eq("procedimento")
    expect(ficha.competence).to eq("202610")
    expect(ficha.source).to eq(type: "synthetic", id: "f0f0f0f0-0000-4000-8000-000000000001")
  end

  it "monta a Ficha de Procedimentos com cabeçalho e um atendimento" do
    master = ficha.to_thrift(uuid: "1234567-u")
    expect(master.uuidFicha).to eq("1234567-u")
    expect(master.tpCdsOrigem).to eq(3)
    header = master.headerTransport
    expect([ header.profissionalCNS, header.cboCodigo_2002, header.cnes, header.ine ])
      .to eq(%w[700000000000005 225142 1234567 0000123456])
    expect(header.dataAtendimento).to eq((attended_at.to_f * 1000).to_i)
    child = master.atendProcedimentos.sole
    expect(child.procedimentos).to eq([ "0301100039" ])
    expect(child.cpfCidadao).to eq("12345678909")
    expect(CitizenIdentity::Cpf.normalize(child.cpfCidadao)).to eq("12345678909")
    expect { master.validate }.not_to raise_error
  end

  # Review Focus 4: a competência é a do fuso da cidade, não a de UTC.
  it "competência no fuso da cidade: 23h30 de 31/10 em Manaus é 202610" do
    Time.use_zone("America/Manaus") do
      late = Time.zone.parse("2026-10-31 23:30")
      expect(late.utc.month).to eq(11)
      expect(described_class.new(cnes: "1234567", ine: nil, professional_cns: "700000000000005", cbo: "225142",
                                 attended_at: late).competence).to eq("202610")
    end
  end

  it "fora de development/test: NotAllowed" do
    allow(Rails.env).to receive(:local?).and_return(false)
    expect { ficha }.to raise_error(described_class::NotAllowed)
  end

  it "Ledi::Ficha.assert! recusa objeto incompleto ou com identificador malformado" do
    expect { Ledi::Ficha.assert!(Object.new) }.to raise_error(Ledi::Ficha::Invalid, /type/)
    bad = described_class.new(cnes: "123", ine: nil, professional_cns: "700000000000005", cbo: "225142",
                              attended_at: attended_at)
    expect { Ledi::Ficha.assert!(bad) }.to raise_error(Ledi::Ficha::Invalid, /cnes/)
    bad_ine = described_class.new(cnes: "1234567", ine: "12", professional_cns: "700000000000005", cbo: "225142",
                                  attended_at: attended_at)
    expect { Ledi::Ficha.assert!(bad_ine) }.to raise_error(Ledi::Ficha::Invalid, /ine/)
  end
end
