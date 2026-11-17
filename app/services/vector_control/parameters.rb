# Parâmetros técnicos do controle vetorial (módulo 35a; contrato §11). A
# coordenação grava por versão (vector_parameter_versions, só acréscimo); a
# vigente é a maior. Sem linha (banco carregado do dump, cidade antes da
# semente): versão 0 com o padrão de fábrica de config/vector_control/defaults.yml
# (A-4). Genérico: as chaves são as do YAML, sem cópia aqui.
module VectorControl
  module Parameters
    DEFAULTS_PATH = Rails.root.join("config/vector_control/defaults.yml")

    Snapshot = Data.define(:version, :values)

    module_function

    def current
      row = VectorParameterVersion.order(version: :desc).first
      row ? Snapshot.new(version: row.version, values: row.values) : Snapshot.new(version: 0, values: defaults)
    end

    def defaults = YAML.load_file(DEFAULTS_PATH)
  end
end
