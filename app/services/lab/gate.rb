# Interruptores do módulo 21b (ADR 0037): LIGADO E UTILIZÁVEL, relido da
# plataforma a cada chamada. Leia FORA de transação (Platform::Features
# engole StatementInvalid). fake_middleware só fora de produção.
module Lab
  module Gate
    KEY = "municipal_lab".freeze
    HL7_KEY = "lab_hl7_inbound".freeze
    FAKE_KEY = "fake_middleware".freeze

    module_function

    def usable?(city, env: Rails.env) = check(city, KEY, env)
    def hl7_usable?(city, env: Rails.env) = check(city, HL7_KEY, env)
    def fake_middleware_usable?(city, env: Rails.env) = check(city, FAKE_KEY, env)

    def check(city, key, env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, key, env: env)
    end
    private_class_method :check
  end
end
