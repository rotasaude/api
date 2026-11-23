# Parâmetros técnicos do centro de zoonoses (módulo 35b; contrato §9; molde do
# VectorControl::Parameters). A coordenação grava por versão
# (zoonoses_parameter_versions, só acréscimo); a vigente é a maior. Sem linha
# (banco carregado do dump, cidade antes da primeira edição): versão 0 com o
# padrão de fábrica de config/zoonoses/defaults.yml e created_at nil. A linha
# gravada antes de uma chave existir é completada pelo defaults.yml. A
# validação do PUT (faixas, a tabela da amostra) entra com o comando
# Zoonoses::SaveParameters (Task 16).
module Zoonoses
  module Parameters
    DEFAULTS_PATH = Rails.root.join("config/zoonoses/defaults.yml")

    Snapshot = Data.define(:version, :values, :created_at) do
      def initialize(version:, values:, created_at: nil) = super
    end

    module_function

    def current
      snapshot(ZoonosesParameterVersion.order(version: :desc).first)
    end

    # A versão gravada (o inquérito lê a da sua criação); 0, nil ou sem linha
    # → o padrão de fábrica.
    def at(version)
      snapshot(version.to_i.positive? && ZoonosesParameterVersion.find_by(version: version))
    end

    def defaults = YAML.load_file(DEFAULTS_PATH)

    def snapshot(row)
      return Snapshot.new(version: 0, values: defaults) unless row

      Snapshot.new(version: row.version, values: defaults.merge(row.values), created_at: row.created_at)
    end
    private_class_method :snapshot
  end
end
