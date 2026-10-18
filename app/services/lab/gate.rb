# Interruptores dos módulos 21b (ADR 0037) e 21c (ADR 0038): LIGADO E
# UTILIZÁVEL, relido da plataforma a cada chamada. Leia FORA de transação
# (Platform::Features engole StatementInvalid). fake_middleware só fora de
# produção. lab_quality_control e lab_inventory: independentes, sobre municipal_lab.
module Lab
  module Gate
    KEY = "municipal_lab".freeze
    HL7_KEY = "lab_hl7_inbound".freeze
    FAKE_KEY = "fake_middleware".freeze
    QC_KEY = "lab_quality_control".freeze
    INVENTORY_KEY = "lab_inventory".freeze

    module_function

    def usable?(city, env: Rails.env) = check(city, KEY, env)
    def hl7_usable?(city, env: Rails.env) = check(city, HL7_KEY, env)
    def fake_middleware_usable?(city, env: Rails.env) = check(city, FAKE_KEY, env)
    def qc_usable?(city, env: Rails.env) = check(city, QC_KEY, env)
    def inventory_usable?(city, env: Rails.env) = check(city, INVENTORY_KEY, env)
    # C13: aparelhos servem ao CIQ e ao estoque; basta um dos dois.
    def instruments_usable?(city, env: Rails.env) = qc_usable?(city, env: env) || inventory_usable?(city, env: env)

    def check(city, key, env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, key, env: env)
    end
    private_class_method :check
  end
end
