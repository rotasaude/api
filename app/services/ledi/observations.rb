# app/services/ledi/observations.rb
# O que a prova técnica observou no PEC (config/ledi/pec_observations.yml, Task 1
# do plano api-exporter). O exportador decide duplicidade, reenvio e sessão
# expirada por aqui, não por suposição.
module Ledi
  module Observations
    PATH = Rails.root.join("config/ledi/pec_observations.yml")

    module_function

    def data = @data ||= YAML.safe_load(File.read(PATH)) || {}

    def reload! = @data = nil

    def duplicate_marker = data.dig("duplicate_after_accept", "marker").presence

    def resend_uuid_policy = data.dig("resend_after_rejection", "same_uuid") == "accepted" ? :same : :new

    def session_expired_statuses = Array(data["session_expired_statuses"]).map(&:to_i)
  end
end
