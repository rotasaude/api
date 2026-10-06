# app/services/protocols/scheduling_targets.rb
# Aviso do gate que precisa de banco (ADR 0029; contratos §1, §9): tipo de
# atendimento que não existe, ou está desativado, na cidade. Avisa, nunca
# bloqueia — o pedido nasce com a chave mesmo assim (Triages::Schedule).
module Protocols
  module SchedulingTargets
    module_function

    def warnings(definition)
      return [] unless definition.is_a?(Hash) && definition["scheduling"].is_a?(Array)

      keys = definition["scheduling"].filter_map { |r| r["appointment_type"].to_s.presence if r.is_a?(Hash) }.uniq
      return [] if keys.empty?

      active = AppointmentType.where(key: keys).pluck(:key, :active).to_h
      keys.filter_map do |key|
        if !active.key?(key) then "scheduling appointment_type '#{key}' does not exist in this city"
        elsif !active[key] then "scheduling appointment_type '#{key}' is inactive in this city"
        end
      end
    end
  end
end
