# A ficha de notificação individual do Sinan (módulo 25; contrato §14): os
# campos de config/surveillance/sinan-form.yml (Task 0), carregados uma vez e
# congelados. Só a definição dos campos; a validação da ficha enviada é da
# Task 11.
module Surveillance
  module Form
    FILE = Rails.root.join("config/surveillance/sinan-form.yml")
    FIELDS = YAML.load_file(FILE).fetch("fields").transform_values { |spec| spec.deep_dup.each_value(&:freeze).freeze }.freeze
    KEYS = FIELDS.keys.freeze

    module_function

    def fields = FIELDS
    def keys = KEYS
  end
end
