require "rails_helper"

# Spec da API de manutenção §4: staging é ensaio de produção. Cada arquivo de
# config com stanza por ambiente declara staging IGUAL a production — uma stanza
# esquecida só apareceria no boot de staging (AdapterNotSpecified, cidade sem
# worker, recorrência que não roda), longe da suíte, que roda em test.
#
# Fix wave (Important #2): a lista de arquivos era hardcoded (seis nomes) — um
# YAML novo com stanza production e sem staging passaria em silêncio, fora da
# lista fixa. Agora ela é derivada de config/*.yml: todo arquivo cuja stanza de
# topo tem "production" precisa também ter "staging" igual.
#
# Minor #6: staging sendo alias YAML de production (`staging: *production`) faz
# a comparação abaixo nunca poder falhar de verdade — estes exemplos provam que
# a stanza existe, não detectam divergência real entre os dois ambientes.
RSpec.describe "Staging environment parity" do
  def parsed(path)
    ActiveSupport::ConfigurationFile.parse(path)
  end

  files_with_production_stanza = Dir.chdir(Rails.root) { Dir.glob("config/*.yml") }
    .select { |file| ActiveSupport::ConfigurationFile.parse(Rails.root.join(file)).key?("production") }
    .sort

  files_with_production_stanza.each do |file|
    it "declares #{file} staging exactly as production" do
      config = parsed(Rails.root.join(file))

      expect(config).to have_key("staging"), "#{file}: sem stanza staging"
      expect(config["staging"]).to eq(config["production"])
    end
  end

  it "derives a non-empty list of files to check, including config/database.yml" do
    # Um glob que não casa com nada faria o `each` acima passar vazio, em
    # silêncio — esta guarda impede isso.
    expect(files_with_production_stanza).not_to be_empty
    expect(files_with_production_stanza).to include("config/database.yml")
  end

  it "builds config/environments/staging.rb on top of production.rb" do
    code = Rails.root.join("config/environments/staging.rb").read

    expect(code).to match(/^require_relative "production"$/)
  end
end
