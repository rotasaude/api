# spec/services/ledi/contract_spec.rb
require "rails_helper"

# Spec §9 "Contrato LEDI": as classes geradas em vendor/ledi/8.7.0 batem campo a
# campo (id, required/optional, tipo, nome) com os IDLs oficiais copiados ao lado
# delas, e os IDLs batem com o sha256 gravado em SOURCE. Um vendor editado à mão
# ou gerado de outro commit fica vermelho aqui.
RSpec.describe "Contrato LEDI 8.7.0" do
  before(:all) { Ledi::Version.load! }

  def thrift_types
    { "string" => :STRING, "binary" => :STRING, "i32" => :I32, "i64" => :I64, "bool" => :BOOL, "double" => :DOUBLE }
  end

  def idl_fields(file, struct)
    text = Ledi::Version.root.join("idl", file).read
    body = text[/struct\s+#{struct}\s*\{(.*?)\n\}/m, 1] or raise "#{struct} não está em #{file}"
    body.scan(/^\s*(\d+):\s*(required|optional)\s+([\w.<>]+)\s+(\w+)/).to_h do |id, _req, type, name|
      [ id.to_i, [ name, type ] ]
    end
  end

  def generated_fields(klass)
    klass::FIELDS.to_h { |id, spec| [ id, spec[:name] ] }
  end

  {
    [ "transport/dado_transporte.thrift", "DadoTransporteThrift" ] => "Br::Gov::Saude::Esusab::Dadotransp::DadoTransporteThrift",
    [ "transport/dado_transporte.thrift", "DadoInstalacaoThrift" ] => "Br::Gov::Saude::Esusab::Dadotransp::DadoInstalacaoThrift",
    [ "transport/dado_transporte.thrift", "VersaoThrift" ] => "Br::Gov::Saude::Esusab::Dadotransp::VersaoThrift",
    [ "ras/ficha_atendimento_procedimento.thrift", "FichaProcedimentoMasterThrift" ] =>
      "Br::Gov::Saude::Esusab::Ras::Atendprocedimentos::FichaProcedimentoMasterThrift",
    [ "ras/ficha_atendimento_procedimento.thrift", "FichaProcedimentoChildThrift" ] =>
      "Br::Gov::Saude::Esusab::Ras::Atendprocedimentos::FichaProcedimentoChildThrift",
    [ "ras/common.thrift", "UnicaLotacaoHeaderThrift" ] => "Br::Gov::Saude::Esusab::Ras::Common::UnicaLotacaoHeaderThrift"
  }.each do |(file, struct), class_name|
    it "#{class_name.demodulize} tem os mesmos ids e nomes de campo do IDL" do
      expected = idl_fields(file, struct)
      expect(generated_fields(class_name.constantize)).to eq(expected.transform_values(&:first))
      expected.each do |id, (name, type)|
        next unless thrift_types.key?(type)
        expect(class_name.constantize::FIELDS[id][:type]).to eq(Thrift::Types.const_get(thrift_types[type])), name
      end
    end
  end

  it "os IDLs batem com o sha256 de SOURCE" do
    recorded = Ledi::Version.root.join("SOURCE").read.scan(%r{^\s+\./(\S+\.thrift): (\h{64})$}).to_h
    expect(recorded).not_to be_empty
    recorded.each do |path, sha|
      expect(Digest::SHA256.file(Ledi::Version.root.join("idl", path)).hexdigest).to eq(sha), path
    end
  end

  it "serializa e lê de volta em TBinaryProtocol, com a versão 8.7.0" do
    versao = Ledi::Version.thrift
    expect([ versao.major, versao.minor, versao.revision ]).to eq([ 8, 7, 0 ])
    bytes = Ledi::Version.serialize(versao)
    expect(bytes.encoding).to eq(Encoding::BINARY)
    expect(Ledi::Version.deserialize(versao.class, bytes)).to eq(versao)
  end
end
