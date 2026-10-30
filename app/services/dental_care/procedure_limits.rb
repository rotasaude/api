# Local e quantidade máxima por SIGTAP na consulta (ADR 0046; Desvio 6;
# contrato §16 O5, O21): a "Lista de procedimentos por local e quantidade
# máxima permitida" do dicionário FAO, em config/ledi/dental_procedure_limits.yml
# (carregado uma vez por processo). Dente → tooth ou face; Sextante → sextant;
# Arcada → arch. Fora da lista: só mouth e 1; os códigos da tabela SIGTAP →
# situação aceitam também o local do efeito, sempre 1.
module DentalCare
  module ProcedureLimits
    PATH = Rails.root.join("config/ledi/dental_procedure_limits.yml")
    KINDS = { "tooth" => %w[tooth face], "sextant" => %w[sextant], "arch" => %w[arch] }.freeze
    OUTSIDE_MAX = 1

    module_function

    def data = (@data ||= YAML.load_file(PATH).fetch("procedures").freeze)

    def entry(code)
      row = data[code.to_s]
      row && { local: row.fetch("local"), max: row.fetch("max") }
    end

    def max(code) = entry(code)&.fetch(:max) || OUTSIDE_MAX

    # Os tipos de <location> aceitos para o código, na ordem da resposta da busca.
    def locations(code)
      row = entry(code)
      row ? KINDS.fetch(row[:local]) : [ "mouth", *SigtapSituations.locations(code) ]
    end

    # Soma das quantidades por SIGTAP: { código => total }, na ordem de chegada.
    # Recebe pares [SIGTAP, quantidade] (a finalização, a FAO e o cinto dela).
    def sums(pairs) = pairs.each_with_object(Hash.new(0)) { |(code, quantity), acc| acc[code] += quantity }

    def location_ok?(code, location_kind) = locations(code).include?(location_kind.to_s)
  end
end
