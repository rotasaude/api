module Regulation
  # Perfil RIRA 1.0.0 confirmado pelo pacote oficial (config/rnds/rira_1_0.yml).
  # Os construtores do documento leem canônicos e sistemas só daqui.
  RiraProfile = Data.define(
    :package, :profiles, :code_systems, :identifiers, :priority_system,
    :appointment_status_system, :service_request_status_system,
    :participation_status_system, :date_fields, :doc_type, :confirmed
  ) do
    PATH = Rails.root.join("config/rnds/rira_1_0.yml")

    def self.current
      @current ||= load_file
    end

    def self.reset!
      @current = nil
    end

    def self.load_file
      raw = YAML.safe_load_file(PATH, symbolize_names: true)
      new(**members.index_with { |m| deep_freeze(raw.fetch(m)) })
    end

    def self.deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end
    private_class_method :load_file, :deep_freeze
  end
end
