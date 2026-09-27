require "rails_helper"

# Fechamento do módulo 07 (F-07.9; correções 02eb147/e007959): Current.city
# atribuído solto vaza a cidade para quem roda perform_now inline e cifra com a
# chave errada. O único lugar que atribui é a resolução por Host, no escopo da
# requisição; job e console usam CityConnection.with (Current.set com bloco).
RSpec.describe "Current.city só é atribuído na resolução por Host" do
  it "não tem atribuição de Current.city fora de CityResolution" do
    offenders = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}")].flat_map do |path|
      File.readlines(path).filter_map do |line|
        next if line.lstrip.start_with?("#")
        "#{Pathname(path).relative_path_from(Rails.root)}" if line.match?(/Current\.city\s*=(?!=)/)
      end
    end

    expect(offenders.uniq).to eq(["app/controllers/concerns/city_resolution.rb"])
  end
end
