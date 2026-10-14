# Interruptores do módulo 21a (ADR 0036): LIGADO E UTILIZÁVEL, relido da
# plataforma a cada chamada (record_mode por id). fake_lab só existe fora de
# produção (Platform::Features::SIMULATION_ENVS).
module Exams
  module Gate
    KEY = "exam_tracking".freeze
    FHIR_KEY = "exam_fhir_inbound".freeze
    PEC_KEY = "exam_pec_bridge".freeze
    FAKE_LAB_KEY = "fake_lab".freeze

    module_function

    def usable?(city, env: Rails.env) = check(city, KEY, env)
    def fhir_usable?(city, env: Rails.env) = check(city, FHIR_KEY, env)
    def pec_usable?(city, env: Rails.env) = check(city, PEC_KEY, env)
    def fake_lab_usable?(city, env: Rails.env) = check(city, FAKE_LAB_KEY, env)

    def check(city, key, env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, key, env: env)
    end
    private_class_method :check
  end
end
