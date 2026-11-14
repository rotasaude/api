require "rails_helper"

# Módulo 24c (ADR 0053; contrato §4, Q40): prova técnica de que a IDL 8.7.0 e
# o dicionário vendorizado aceitam a coordenada do imóvel (ficha 3) e da visita
# (ficha 8) como o FieldLocation a valida.
RSpec.describe "Coordenada nas fichas 3 e 8 (LEDI 8.7.0)", type: :model do
  before { Ledi::Version.load! }

  def field(klass, id) = klass::FIELDS.fetch(id)

  it "ficha 3: latitude 17 e longitude 18, double opcional" do
    cd = Br::Gov::Saude::Esusab::Ras::Cadastrodomiciliar::CadastroDomiciliarThrift
    expect(field(cd, 17)).to include(name: "latitude", type: ::Thrift::Types::DOUBLE, optional: true)
    expect(field(cd, 18)).to include(name: "longitude", type: ::Thrift::Types::DOUBLE, optional: true)
  end

  it "ficha 8: latitude 20 e longitude 21 no filho, double opcional" do
    vd = Br::Gov::Saude::Esusab::Ras::Visitadomiciliar::FichaVisitaDomiciliarChildThrift
    expect(field(vd, 20)).to include(name: "latitude", type: ::Thrift::Types::DOUBLE, optional: true)
    expect(field(vd, 21)).to include(name: "longitude", type: ::Thrift::Types::DOUBLE, optional: true)
  end

  it "o dicionário vendorizado pede o par, as faixas e até 8 casas (fcd e fvd)" do
    %w[dicionario-fcd.html dicionario-fvd.html].each do |doc|
      text = Ledi::Version.root.join("docs", doc).read.gsub(/<[^>]+>/, " ").squish
      expect(text).to include("obrigatório se o campo longitude for preenchido")
      expect(text).to include("limitados por -90 a 90 e apresentam até 8 casas decimais")
      expect(text).to include("limitados por -180 a 180 e apresentam até 8 casas decimais")
    end
  end
end
