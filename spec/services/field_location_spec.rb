require "rails_helper"

# Módulo 24c (ADR 0053; contrato §4, Q3): a coordenada do imóvel e da visita
# validada num lugar só, sem arredondar e sem devolver o valor recusado.
RSpec.describe FieldLocation, type: :model do
  let(:gps) { { "latitude" => -25.42847123, "longitude" => -49.27325411, "accuracy_m" => 8.5, "source" => "gps" } }

  def parse(raw, sources: FieldLocation::SOURCES) = described_class.parse(raw, sources: sources)

  def refused_at(raw, sources: FieldLocation::SOURCES)
    result = parse(raw, sources: sources)
    expect(result).to be_failure
    expect(result.reason).to eq(:invalid_location)
    result.details.fetch(:path)
  end

  describe ".parse" do
    it "aceita o par com 8 casas e devolve só as chaves do contrato, em Float" do
      result = parse(gps)
      expect(result).to be_ok
      expect(result.payload[:location]).to eq("latitude" => -25.42847123, "longitude" => -49.27325411,
                                              "accuracy_m" => 8.5, "source" => "gps")
    end

    it "aceita inteiros e os extremos das faixas" do
      [ [ -90, -180 ], [ 90, 180 ], [ 0, 0 ] ].each do |latitude, longitude|
        result = parse(gps.merge("latitude" => latitude, "longitude" => longitude, "accuracy_m" => 0))
        expect(result).to be_ok
        expect(result.payload[:location]).to include("latitude" => latitude.to_f, "longitude" => longitude.to_f, "accuracy_m" => 0.0)
        expect(result.payload[:location].values_at("latitude", "longitude", "accuracy_m")).to all(be_a(Float))
      end
      expect(parse(gps.merge("accuracy_m" => 10_000))).to be_ok
    end

    it "nil é sem coordenada" do
      result = parse(nil)
      expect(result).to be_ok
      expect(result.payload).to eq(location: nil)
    end

    it "ponto do mapa sem accuracy_m é aceito, sem a chave no resultado (Q3)" do
      result = parse(gps.except("accuracy_m").merge("source" => "map"))
      expect(result).to be_ok
      expect(result.payload[:location].keys).to eq(%w[latitude longitude source])
    end

    it "recusa mais de 8 casas sem arredondar" do
      expect(refused_at(gps.merge("latitude" => -25.428471234))).to eq("location.latitude")
      expect(refused_at(gps.merge("latitude" => 1.0e-09))).to eq("location.latitude")
      expect(refused_at(gps.merge("longitude" => -49.273254112))).to eq("location.longitude")
    end

    it "recusa fora da faixa" do
      expect(refused_at(gps.merge("latitude" => 90.00000001))).to eq("location.latitude")
      expect(refused_at(gps.merge("latitude" => -91))).to eq("location.latitude")
      expect(refused_at(gps.merge("longitude" => 180.5))).to eq("location.longitude")
    end

    it "recusa o que não é número" do
      expect(refused_at(gps.merge("latitude" => "-25.4"))).to eq("location.latitude")
      expect(refused_at(gps.merge("latitude" => true))).to eq("location.latitude")
      expect(refused_at(gps.merge("longitude" => nil))).to eq("location.longitude")
      expect(refused_at(gps.merge("latitude" => Float::NAN))).to eq("location.latitude")
      expect(refused_at(gps.merge("longitude" => Float::INFINITY))).to eq("location.longitude")
    end

    it "recusa o par incompleto e a origem ausente ou desconhecida" do
      expect(refused_at(gps.except("longitude"))).to eq("location.longitude")
      expect(refused_at(gps.except("latitude"))).to eq("location.latitude")
      expect(refused_at(gps.except("source"))).to eq("location.source")
      expect(refused_at(gps.merge("source" => "wifi"))).to eq("location.source")
    end

    it "accuracy_m é obrigatório com gps e limitado a 0..10000 com 1 casa (Q3)" do
      expect(refused_at(gps.except("accuracy_m"))).to eq("location.accuracy_m")
      expect(refused_at(gps.merge("accuracy_m" => 10_000.05))).to eq("location.accuracy_m")
      expect(refused_at(gps.merge("accuracy_m" => 8.55))).to eq("location.accuracy_m")
      expect(refused_at(gps.merge("accuracy_m" => -1))).to eq("location.accuracy_m")
      expect(refused_at(gps.merge("accuracy_m" => "8"))).to eq("location.accuracy_m")
    end

    it "a visita só aceita gps" do
      map = gps.except("accuracy_m").merge("source" => "map")
      expect(refused_at(map, sources: FieldLocation::VISIT_SOURCES)).to eq("location.source")
      expect(parse(gps, sources: FieldLocation::VISIT_SOURCES)).to be_ok
    end

    it "recusa chave a mais e o que não é objeto, com o path do objeto" do
      expect(refused_at(gps.merge("altitude" => 934))).to eq("location")
      expect(refused_at([])).to eq("location")
      expect(refused_at("-25.4,-49.2")).to eq("location")
    end

    it "usa o prefixo pedido no path" do
      result = described_class.parse(gps.merge("latitude" => 91), sources: FieldLocation::SOURCES, prefix: "household.location")
      expect(result.details).to eq(path: "household.location.latitude")
    end

    it "a recusa nunca traz o valor" do
      [ gps.merge("latitude" => -25.428471234), gps.merge("latitude" => "-25.4"), gps.merge("accuracy_m" => 8.55),
        gps.merge("altitude" => 934.25) ].each do |raw|
        result = parse(raw)
        expect(result.to_h.to_s).not_to include("25.4")
        expect(result.to_h.to_s).not_to include("8.55")
        expect(result.to_h.to_s).not_to include("934")
        expect(result.message).to be_nil
      end
    end
  end

  describe ".decimals" do
    it "conta as casas da forma mais curta que volta ao mesmo número" do
      expect(described_class.decimals(-25.42847123)).to eq(8)
      expect(described_class.decimals(-25.428471234)).to eq(9)
      expect(described_class.decimals(1.0e-09)).to eq(9)
      expect(described_class.decimals(8.5)).to eq(1)
      expect(described_class.decimals(90)).to eq(0)
      expect(described_class.decimals(90.0)).to eq(0)
    end
  end

  describe ".ledi" do
    it "devolve o par para a ficha, e nada sem coordenada" do
      expect(described_class.ledi("latitude" => -25.42847123, "longitude" => -49.27325411, "source" => "map")).to eq(
        latitude: -25.42847123, longitude: -49.27325411
      )
      expect(described_class.ledi(nil)).to eq({})
    end
  end
end
