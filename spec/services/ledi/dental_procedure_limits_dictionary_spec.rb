require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 6): config/ledi/dental_procedure_limits.yml é a
# "Lista de procedimentos por local e quantidade máxima permitida" do
# dicionário FAO vendorizado (vendor/ledi/8.7.0/docs/dicionario-fao.html),
# linha a linha, nos dois sentidos.
RSpec.describe "Limites de procedimento da FAO (LEDI 8.7.0)" do
  let(:yaml) { YAML.load_file(Rails.root.join("config/ledi/dental_procedure_limits.yml")) }
  let(:html) { Ledi::Version.root.join("docs/dicionario-fao.html").read }

  def table_rows
    locals = { "Dente" => "tooth", "Sextante" => "sextant", "Arcada" => "arch" }
    start = html.index('id="lista-de-procedimentos-por-local-e-quantidade-m-xima-permitida"')
    table = html[start...html.index("</table>", start)]
    table.scan(%r{<tr>\s*<td>(.*?)</td>\s*<td>(.*?)</td>\s*<td>(.*?)</td>\s*<td>(.*?)</td>\s*</tr>}m).to_h do |code, name, local, max|
      [ code.delete("^0-9"), { "name" => name.strip, "local" => locals.fetch(local.strip), "max" => Integer(max) } ]
    end
  end

  it "o HTML vendorizado é o dicionário FAO da versão 8.7.0" do
    expect(html).to include("Modelo de Informação de Atendimento Odontológico Individual")
    expect(html).to include("Layout e-SUS APS de Dados e Interface Versão 8.7.0")
  end

  it "cada linha do YAML existe na tabela do HTML com o mesmo local e máximo, e vice-versa" do
    procedures = yaml.fetch("procedures")
    expect(yaml.fetch("version")).to eq(1)
    expect(procedures.keys).to all(match(/\A\d{10}\z/))
    expect(procedures.transform_values { |row| row.slice("name", "local", "max") }).to eq(table_rows)
    expect(procedures.values.map { |row| row["source"] }).to all(be_present)
    expect(table_rows.size).to eq(79)
  end

  it "os códigos da tabela SIGTAP → situação estão todos na lista (nenhum depende da exceção do O21), com o mesmo nome e local" do
    table = YAML.load_file(Rails.root.join("config/dental/sigtap_situations.yml")).fetch("procedures")
    limits = yaml.fetch("procedures")
    expect(table.keys - limits.keys).to eq([])
    table.each do |code, row|
      expect(row.fetch("name")).to eq(limits.fetch(code).fetch("name"))
      expect(row.fetch("locations")).to eq(DentalCare::ProcedureLimits.locations(code))
    end
  end
end
