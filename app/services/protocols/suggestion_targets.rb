# Aviso do gate que precisa de banco (ADR 0027; spec 2026-10-05 §4.3): fica
# fora de app/protocols/, que é o motor puro. "Não existe" = nenhuma versão com
# esse name na cidade; o próprio protocolo já é erro do gate.
module Protocols
  module SuggestionTargets
    module_function

    def warnings(definition)
      return [] unless definition.is_a?(Hash) && definition["suggestions"].is_a?(Array)

      names = definition["suggestions"].filter_map { |s| s["protocol"].to_s.presence if s.is_a?(Hash) }.uniq
      names -= [definition["name"].to_s]
      return [] if names.empty?

      existing = ProtocolDefinition.where(name: names).distinct.pluck(:name)
      (names - existing).map { |name| "suggestion protocol '#{name}' does not exist in this city" }
    end
  end
end
