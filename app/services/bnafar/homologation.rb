# Massa de dados da homologação do SI-BNAFAR (módulo 27b, Task 8). Troca, no
# payload montado, o CNES de origem e de destino, o produto (número, AMPP, VMP e
# registro) e o programa pelos da massa de `config/bnafar/homologation.yml`, que
# é o que o ambiente de homologação conhece. Só para a homologação: nunca toca
# o original (devolve cópia).
module Bnafar
  module Homologation
    PATH = Rails.root.join("config/bnafar/homologation.yml")

    module_function

    def mapping = YAML.safe_load_file(PATH)

    # `payload`: um registro (Hash) ou a lista de registros.
    def apply(payload, mapping:)
      copy = payload.deep_dup
      copy.is_a?(Array) ? copy.map { |record| swap(record, mapping) } : swap(copy, mapping)
    end

    def swap(record, mapping)
      record["estabelecimento"]["cnes"] = mapping["cnes"] if record["estabelecimento"].is_a?(Hash)
      characterization = record["caracterizacao"]
      characterization["estabelecimentoDestino"] = mapping["cnes"] if characterization.is_a?(Hash) && characterization.key?("estabelecimentoDestino")
      products = Array(mapping["products"])
      Array(record["itens"]).each_with_index do |item, index|
        product = products[index % products.size] if products.any?
        item.merge!(product_fields(product)) if product
        item["siglaProgramaSaude"] = mapping["program"]
      end
      record
    end

    def product_fields(product)
      { "numero" => product["numero"], "codigoAmpp" => product["codigo_ampp"], "codigoVmp" => product["codigo_vmp"],
        "registroAnvisa" => product["registro_anvisa"], "tipoProduto" => product["tipo_produto"] }.compact
    end
    private_class_method :swap, :product_fields
  end
end
